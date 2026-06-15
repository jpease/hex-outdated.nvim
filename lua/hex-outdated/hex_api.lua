local M = {}

-- name -> { versions = {...}, latest = "x.y.z", time = epoch } | { error = msg, not_found = bool }
local cache = {}

-- name -> list of callbacks waiting on an in-flight request for that package.
-- A debounced analyze re-fires while earlier fetches are still running; without
-- this, each cycle would spawn a duplicate curl for every not-yet-cached dep.
local pending = {}

-- Concurrency state. `max_concurrent` bounds simultaneously running curl
-- processes: a mix.exs with many deps would otherwise spawn one process per dep
-- at once, which is heavy and amplifies a retry storm against a failing upstream.
-- Set from opts; unlimited until configured.
local in_flight = 0
local max_concurrent = math.huge
local queue = {} -- FIFO of { name, opts } waiting for a slot

-- Reset all module state, not just the cache: a lingering `pending`/`queue`
-- entry or a non-zero `in_flight` from a previous run would otherwise leak across
-- a clear and silently throttle or stall the next fetch. (Used by tests.)
function M.clear_cache()
	cache = {}
	pending = {}
	queue = {}
	in_flight = 0
end

local function fresh(entry, ttl, error_ttl)
	if not entry then
		return false
	end
	local age = os.time() - (entry.time or 0)
	-- A cached failure is fresh for a shorter window so a failing/unreachable
	-- hex.pm is retried at a bounded rate instead of on every debounce cycle.
	if entry.error then
		return age < (error_ttl or 0)
	end
	return age < ttl
end

local function curl_command(name, opts)
	local base = opts.base_url or "https://hex.pm/api"
	local timeout_s = math.max(1, math.floor((opts.timeout_ms or 5000) / 1000))
	local url = string.format("%s/packages/%s", base, name)
	return {
		"curl",
		"-sSL",
		"--max-time",
		tostring(timeout_s),
		"-w",
		"\n%{http_code}",
		url,
	}
end

-- Common curl exit codes, mapped to messages a user can act on. Anything else
-- keeps the numeric code so it can be looked up.
local curl_errors = {
	[6] = "could not resolve hex.pm",
	[7] = "could not connect to hex.pm",
	[28] = "request timed out",
}

local function parse_package_response(obj, decode_json, now)
	if obj.code ~= 0 then
		return {
			error = curl_errors[obj.code] or ("request failed (curl " .. tostring(obj.code) .. ")"),
		}
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

	local ok, data = pcall(decode_json, body)
	if not ok or type(data) ~= "table" then
		return { error = "invalid response" }
	end
	local versions = {}
	for _, rel in ipairs(data.releases or {}) do
		if rel.version then
			versions[#versions + 1] = rel.version
		end
	end
	return {
		versions = versions,
		latest = data.latest_stable_version or data.latest_version,
		time = now(),
	}
end

M._curl_command = curl_command
M._parse_package_response = parse_package_response

local pump -- forward declaration

local function spawn(name, opts)
	in_flight = in_flight + 1
	local cmd = curl_command(name, opts)

	local function deliver(result)
		if result.error then
			-- Errors carry no time of their own; stamp one so negative caching can age them.
			result.time = result.time or os.time()
			-- Serve stale-but-good data through a transient failure rather than
			-- flipping the dep to an error indicator. The cached failure still ages
			-- out via negative caching, so we retry once the window passes.
			local prev = cache[name]
			if prev and prev.versions and #prev.versions > 0 then
				result.versions = prev.versions
				result.latest = prev.latest
				result.stale = true
			end
		end
		cache[name] = result
		local callbacks = pending[name]
		pending[name] = nil
		in_flight = in_flight - 1
		pump()
		vim.schedule(function()
			for _, cb in ipairs(callbacks) do
				cb(result)
			end
		end)
	end

	-- vim.system raises if the process can't be spawned (e.g. curl missing). Without
	-- this guard the error escapes analyze and `pending[name]` is never cleared, so
	-- the package stays "loading" forever and future fetches ride a request that
	-- never resolves.
	local ok, err = pcall(vim.system, cmd, { text = true }, function(obj)
		deliver(parse_package_response(obj, vim.json.decode, os.time))
	end)
	if not ok then
		deliver({ error = "could not run curl: " .. tostring(err) })
	end
end

function pump()
	while in_flight < max_concurrent and #queue > 0 do
		local item = table.remove(queue, 1)
		spawn(item.name, item.opts)
	end
end

--- Fetch package release info from hex.pm.
--- opts: { base_url, timeout_ms, ttl_seconds, error_ttl_seconds, max_concurrent, force }
--- callback receives { versions = {strings}, latest = string, time = epoch }
--- or { error = msg, not_found? }.
function M.get_package(name, opts, callback)
	opts = opts or {}
	local ttl = opts.ttl_seconds or 3600
	local error_ttl = opts.error_ttl_seconds or 0
	if opts.max_concurrent then
		max_concurrent = opts.max_concurrent
	end
	if not opts.force and fresh(cache[name], ttl, error_ttl) then
		callback(cache[name])
		return
	end
	-- Already fetching this package: ride the in-flight request rather than
	-- spawning another curl. The running request is hitting the network now, so
	-- its result is fresh enough to satisfy a concurrent force as well.
	local waiters = pending[name]
	if waiters then
		waiters[#waiters + 1] = callback
		return
	end
	pending[name] = { callback }
	if in_flight < max_concurrent then
		spawn(name, opts)
	else
		queue[#queue + 1] = { name = name, opts = opts }
	end
end

return M
