local M = {}

-- name -> { versions = {...}, latest = "x.y.z", time = epoch } | { error = msg, not_found = bool }
local cache = {}

function M.clear_cache()
	cache = {}
end

local function fresh(entry, ttl)
	return entry and not entry.error and (os.time() - (entry.time or 0)) < ttl
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

local function parse_package_response(obj, decode_json, now)
	if obj.code ~= 0 then
		return { error = "request failed" }
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

--- Fetch package release info from hex.pm.
--- opts: { base_url, timeout_ms, ttl_seconds, force }
--- callback receives { versions = {strings}, latest = string, time = epoch }
--- or { error = msg, not_found? }.
function M.get_package(name, opts, callback)
	opts = opts or {}
	local ttl = opts.ttl_seconds or 3600
	if not opts.force and fresh(cache[name], ttl) then
		callback(cache[name])
		return
	end
	local cmd = curl_command(name, opts)

	vim.system(cmd, { text = true }, function(obj)
		local result = parse_package_response(obj, vim.json.decode, os.time)
		cache[name] = result
		vim.schedule(function()
			callback(result)
		end)
	end)
end

return M
