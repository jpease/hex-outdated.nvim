local util = require("hex-outdated.util")
local version = require("hex-outdated.version")

local M = {}

-- Effect boundaries: process spawn, event-loop scheduling, clock, JSON decode.
-- A nil field means "use the Neovim/stdlib default", resolved at call time so a
-- caller that swaps `vim.system` after this module was required (the headless
-- suite does) still takes effect. Injecting them keeps the scheduler's queue and
-- reset behavior testable without replacing the `vim` global wholesale (#74).
local boundaries = {}

--- Test seam: replace the effect boundaries with `overrides`
--- ({ system, schedule, now, decode_json }); pass nil to restore the defaults.
--- Returns the previous table so a caller can put it back.
function M._set_boundaries(overrides)
	local previous = boundaries
	boundaries = overrides or {}
	return previous
end

local function clock()
	return (boundaries.now or os.time)()
end

-- One owner for every piece of mutable request state (#74):
--   cache      -- "endpoint|name" -> { versions = {...}, latest = "x.y.z", time = epoch }
--                 or { error = msg, not_found = bool }
--   pending    -- "endpoint|name" -> list of callbacks waiting on a running request.
--                 A debounced analyze re-fires while earlier fetches are still
--                 running; without this, each cycle would spawn a duplicate curl
--                 for every not-yet-cached dep.
--   queue      -- FIFO of { name, opts } waiting for a slot
--   active     -- curl processes running right now
--   max_concurrent -- bounds `active`; a mix.exs with many deps would otherwise
--                 spawn one process per dep at once, which is heavy and
--                 amplifies a retry storm against a failing upstream.
--                 Unlimited until a caller configures it.
--   generation -- bumped by clear_cache; a completion from an earlier generation
--                 is retired instead of mutating the state that replaced it.
local scheduler = {
	cache = {},
	pending = {},
	queue = {},
	active = 0,
	max_concurrent = math.huge,
	generation = 0,
}

local pump -- forward declaration: a completion (or a raised limit) drains the queue

local function cache_key(name, base_url)
	return (base_url or "https://hex.pm/api") .. "|" .. name
end

-- Defensive normalization for caller-supplied TTLs: config.setup already
-- warns once for an invalid cache.ttl_seconds/error_ttl_seconds at startup,
-- but get_package must not let a bad value reach `fresh`'s numeric comparison
-- regardless of caller (tests, other integrations, or config.setup being
-- bypassed entirely) — mirrors the existing max_concurrent clamp below.
-- Goes through the same util.normalize_number contract config.lua's
-- normalization pass uses, rather than a lookalike copy of it (#72).
local function safe_ttl(v, default)
	local value = util.normalize_number(v, { default = default, min = 0 })
	return value
end

-- The concurrency limit is a property of the scheduler, not of any one request.
-- Callers still pass `max_concurrent` per request (config.api_opts fans the one
-- configured value out to every dependency), but every change goes through this
-- setter rather than assigning a bare module-level variable from anywhere (#74).
-- A raised limit re-drains the queue here, so work already waiting starts now
-- instead of sitting parked until the next completion happens to pump.
local function set_max_concurrent(value)
	-- Config-level validation (config.setup) already warns once for invalid
	-- values; this is a silent defensive clamp for callers that bypass it.
	-- Same util.normalize_number contract as config.lua's api.max_concurrent
	-- rule (fallback of 1, not the default of 8 — see config.lua's
	-- NUMERIC_RULES comment), not a divergent copy of it (#72).
	scheduler.max_concurrent =
		util.normalize_number(value, { default = 1, integer = true, min = 1 })
	pump()
end

-- Reset all scheduler state, not just the cache: a lingering `pending`/`queue`
-- entry or a non-zero active count from a previous run would otherwise leak
-- across a clear and silently throttle or stall the next fetch. (Used by tests.)
--
-- Bumping the generation is what makes this safe while requests are running: a
-- curl spawned before the reset can still complete afterwards, and it must not
-- write into the cache that replaced its own, clear a waiter list it no longer
-- owns, or decrement a counter that was already zeroed. The concurrency limit
-- survives a reset — it is configuration, not per-run state.
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
	local age = clock() - (entry.time or 0)
	-- A cached failure is fresh for a shorter window so a failing/unreachable
	-- hex.pm is retried at a bounded rate instead of on every debounce cycle.
	if entry.error then
		return age < (error_ttl or 0)
	end
	return age < ttl
end

local function curl_command(name, opts)
	local base = opts.base_url or "https://hex.pm/api"
	local timeout_s = util.timeout_seconds(opts.timeout_ms, 5000)
	local url = string.format("%s/packages/%s", base, name)
	return {
		"curl",
		"-sSL",
		"--max-time",
		string.format("%.15g", timeout_s),
		"-w",
		"\n%{http_code}",
		url,
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
	local result = {
		versions = versions,
		latest = latest,
		retirements = retirements,
		time = now(),
	}
	if saw_release and #versions == 0 then
		result.all_retired = true
	end
	return result
end

M._curl_command = curl_command
M._parse_package_response = parse_package_response

-- Callbacks always run on the event loop, never inline in the process's
-- completion callback.
local function schedule_delivery(waiters, result)
	local schedule = boundaries.schedule or vim.schedule
	schedule(function()
		for _, cb in ipairs(waiters) do
			cb(result)
		end
	end)
end

local function spawn(name, opts)
	local cmd = curl_command(name, opts)
	local key = cache_key(name, opts.base_url)
	-- Capture the waiter list by identity and the generation by value, both at
	-- spawn time. get_package appends to this same table while the request runs
	-- (in-flight coalescing), so late waiters are still served; re-reading
	-- `scheduler.pending` at completion time is what let a reset hand `deliver`
	-- a nil list to iterate (#74).
	local waiters = scheduler.pending[key] or {}
	local generation = scheduler.generation
	local settled = false
	scheduler.active = scheduler.active + 1

	local function deliver(result)
		-- One request releases one slot. A process can report completion twice —
		-- a spawn that raises after its exit callback already fired, or a
		-- double-fired libuv exit — and the later report is ignored.
		if settled then
			return
		end
		settled = true
		if result.error then
			-- Errors carry no time of their own; stamp one so negative caching can age them.
			result.time = result.time or clock()
		end
		if generation ~= scheduler.generation then
			-- Retired: clear_cache reset the scheduler after this request was
			-- spawned, so the slot, waiter list, and cache entry it belonged to
			-- are gone. Mutating the state that replaced them is exactly what
			-- drove the active count negative and crashed on a nil waiter list.
			-- The waiters captured at spawn time still get their answer: it is an
			-- honest reply to the request they made, and a caller that never
			-- heard back would hold a "loading" indicator forever. The result is
			-- not cached — the cache it was fetched for no longer exists.
			schedule_delivery(waiters, result)
			return
		end
		if result.error and not result.not_found then
			-- Serve stale-but-good data through a transient failure rather than
			-- flipping the dep to an error indicator. A definitive 404 means the
			-- package doesn't exist (or was renamed) — never inherit stale data for
			-- that case, only for a transient failure (network error, 5xx). The
			-- cached failure still ages out via negative caching, so we retry once
			-- the window passes.
			local prev = scheduler.cache[key]
			if prev and prev.versions and #prev.versions > 0 then
				result.versions = prev.versions
				result.latest = prev.latest
				result.stale = true
			end
		end
		scheduler.cache[key] = result
		if scheduler.pending[key] == waiters then
			scheduler.pending[key] = nil
		end
		-- The generation check above already keeps a retired completion away from
		-- this decrement; the floor is belt-and-braces so the count can never go
		-- negative and silently lift the concurrency cap.
		scheduler.active = math.max(0, scheduler.active - 1)
		pump()
		schedule_delivery(waiters, result)
	end

	-- vim.system raises if the process can't be spawned (e.g. curl missing). Without
	-- this guard the error escapes analyze and the pending entry is never cleared, so
	-- the package stays "loading" forever and future fetches ride a request that
	-- never resolves.
	local ok, err = pcall(boundaries.system or vim.system, cmd, { text = true }, function(obj)
		local decode = boundaries.decode_json or vim.json.decode
		local parse_ok, result = pcall(parse_package_response, obj, decode, clock)
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

--- Fetch package release info from hex.pm.
--- opts: { base_url, timeout_ms, ttl_seconds, error_ttl_seconds, max_concurrent, force }
--- `max_concurrent` configures the shared scheduler rather than this one request:
--- it applies to every request from here on, queued ones included.
--- callback receives { versions = {strings}, latest = string, time = epoch }
--- or { error = msg, not_found? }.
function M.get_package(name, opts, callback)
	opts = opts or {}
	local key = cache_key(name, opts.base_url)
	local ttl = safe_ttl(opts.ttl_seconds, 3600)
	local error_ttl = safe_ttl(opts.error_ttl_seconds, 0)
	if opts.max_concurrent ~= nil then
		set_max_concurrent(opts.max_concurrent)
	end
	if not opts.force and fresh(scheduler.cache[key], ttl, error_ttl) then
		callback(scheduler.cache[key])
		return
	end
	-- Already fetching this package on this endpoint: ride the in-flight request
	-- rather than spawning another curl.
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
