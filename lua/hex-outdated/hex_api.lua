local config = require("hex-outdated.config")
local util = require("hex-outdated.util")
local version = require("hex-outdated.version")

local M = {}

-- All mutable request state:
--   cache      -- "base_url|name" -> package result (see get_package)
--   pending    -- "base_url|name" -> callbacks waiting on the running request
--   queue      -- FIFO of { name, opts } waiting for a slot
--   active     -- curl processes running now; never exceeds max_concurrent
--   generation -- bumped by clear_cache; completions from an older generation
--                 never touch the state that replaced theirs
local scheduler = {
	cache = {},
	pending = {},
	queue = {},
	active = 0,
	max_concurrent = config.defaults.api.max_concurrent,
	generation = 0,
}

local pump

local function cache_key(name, base_url)
	return base_url .. "|" .. name
end

--- Drop cached results and queued work. The concurrency limit is kept.
function M.clear_cache()
	scheduler.cache = {}
	scheduler.pending = {}
	scheduler.queue = {}
	scheduler.active = 0
	scheduler.generation = scheduler.generation + 1
end

local function fresh(entry, ttl, error_ttl)
	if not entry then
		return false
	end
	local age = os.time() - entry.time
	-- Failures expire sooner so an unreachable host is retried at a bounded rate.
	if entry.error then
		return age < error_ttl
	end
	return age < ttl
end

local function curl_command(name, opts)
	return {
		"curl",
		"-sSL",
		"--max-time",
		string.format("%.15g", opts.timeout_ms / 1000),
		"-w",
		"\n%{http_code}",
		string.format("%s/packages/%s", opts.base_url, name),
	}
end

local function latest_active_version(versions)
	local latest, latest_parsed
	local latest_stable, latest_stable_parsed
	for _, raw in ipairs(versions) do
		local parsed = version.parse(raw)
		if parsed then
			if not latest_parsed or version.compare(parsed, latest_parsed) > 0 then
				latest = raw
				latest_parsed = parsed
			end
			if
				version.is_stable(parsed)
				and (not latest_stable_parsed or version.compare(parsed, latest_stable_parsed) > 0)
			then
				latest_stable = raw
				latest_stable_parsed = parsed
			end
		end
	end
	return latest_stable or latest or versions[1]
end

local function curl_error(code, base_url)
	local host = util.url_host(base_url)
	if code == 6 then
		return "could not resolve " .. host
	elseif code == 7 then
		return "could not connect to " .. host
	elseif code == 28 then
		return "request timed out"
	end
	return "request failed (curl " .. tostring(code) .. ")"
end

local function parse_package_response(obj, base_url)
	if obj.code ~= 0 then
		return { error = curl_error(obj.code, base_url) }
	end
	local body, status = (obj.stdout or ""):match("^(.*)\n(%d+)%s*$")
	status = tonumber(status)
	if not status then
		return { error = "malformed response (no http_code trailer)" }
	elseif status == 404 then
		return { error = "package not found", not_found = true }
	elseif status ~= 200 then
		return { error = "http " .. tostring(status) }
	end

	local ok, data = pcall(vim.json.decode, body)
	if not ok or type(data) ~= "table" then
		return { error = "invalid response" }
	end
	if data.releases ~= nil and type(data.releases) ~= "table" then
		return { error = "invalid response" }
	end
	local retirements = type(data.retirements) == "table" and data.retirements or {}
	local versions = {}
	local active = {}
	local saw_release = false
	for _, rel in ipairs(data.releases or {}) do
		if type(rel) ~= "table" then
			return { error = "invalid response" }
		end
		if rel.version ~= nil and type(rel.version) ~= "string" then
			return { error = "invalid response" }
		end
		if rel.version then
			saw_release = true
			if retirements[rel.version] == nil then
				versions[#versions + 1] = rel.version
				active[rel.version] = true
			end
		end
	end
	local latest = data.latest_stable_version or data.latest_version
	if saw_release and (not latest or not active[latest]) then
		latest = latest_active_version(versions)
	end
	return {
		versions = versions,
		latest = latest,
		all_retired = (saw_release and #versions == 0) or nil,
	}
end

-- Callbacks always run on the event loop, never inside the process callback.
local function schedule_delivery(waiters, result)
	vim.schedule(function()
		for _, cb in ipairs(waiters) do
			cb(result)
		end
	end)
end

local function spawn(name, opts)
	local key = cache_key(name, opts.base_url)
	-- Captured at spawn time: late waiters append to this same list, and a
	-- clear_cache in between must not hand deliver a different (or nil) list.
	local waiters = scheduler.pending[key]
	local generation = scheduler.generation
	local settled = false
	scheduler.active = scheduler.active + 1

	local function deliver(result)
		-- A process can report completion twice; one request releases one slot.
		if settled then
			return
		end
		settled = true
		result.time = os.time()
		if generation ~= scheduler.generation then
			-- Retired by clear_cache: answer the original waiters, touch no state.
			schedule_delivery(waiters, result)
			return
		end
		if result.error and not result.not_found then
			-- A transient failure keeps the last good versions; a 404 never does.
			local prev = scheduler.cache[key]
			if prev and prev.versions and #prev.versions > 0 then
				result.versions = prev.versions
				result.latest = prev.latest
			end
		end
		scheduler.cache[key] = result
		if scheduler.pending[key] == waiters then
			scheduler.pending[key] = nil
		end
		scheduler.active = scheduler.active - 1
		pump()
		schedule_delivery(waiters, result)
	end

	-- vim.system raises when curl can't be spawned; that must still settle the request.
	local ok, err = pcall(vim.system, curl_command(name, opts), { text = true }, function(obj)
		local parse_ok, result = pcall(parse_package_response, obj, opts.base_url)
		deliver(parse_ok and result or { error = "invalid response" })
	end)
	if not ok then
		deliver({ error = "could not run curl: " .. tostring(err) })
	end
end

function pump()
	while scheduler.active < scheduler.max_concurrent and #scheduler.queue > 0 do
		local item = table.remove(scheduler.queue, 1)
		spawn(item.name, item.opts)
	end
end

--- Fetch package release info.
--- opts: core.api_opts() plus optional `force`. `max_concurrent` sets the shared
--- scheduler limit for every request from here on, queued ones included.
--- callback receives { versions, latest, all_retired?, time } on success, or
--- { error, not_found?, time } on failure; a transient failure also carries the
--- last good `versions`/`latest`.
function M.get_package(name, opts, callback)
	local key = cache_key(name, opts.base_url)
	scheduler.max_concurrent = opts.max_concurrent
	pump()
	if not opts.force and fresh(scheduler.cache[key], opts.ttl_seconds, opts.error_ttl_seconds) then
		callback(scheduler.cache[key])
		return
	end
	local waiters = scheduler.pending[key]
	if waiters then
		waiters[#waiters + 1] = callback
		return
	end
	scheduler.pending[key] = { callback }
	if scheduler.active < scheduler.max_concurrent then
		spawn(name, opts)
	else
		scheduler.queue[#scheduler.queue + 1] = { name = name, opts = opts }
	end
end

return M
