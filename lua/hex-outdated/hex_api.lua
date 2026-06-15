local M = {}

-- name -> { versions = {...}, latest = "x.y.z", time = epoch } | { error = msg, not_found = bool }
local cache = {}

function M.clear_cache()
	cache = {}
end

local function fresh(entry, ttl)
	return entry and not entry.error and (os.time() - (entry.time or 0)) < ttl
end

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
	local base = opts.base_url or "https://hex.pm/api"
	local timeout_s = math.max(1, math.floor((opts.timeout_ms or 5000) / 1000))
	local url = string.format("%s/packages/%s", base, name)
	local cmd = {
		"curl",
		"-sSL",
		"--max-time",
		tostring(timeout_s),
		"-w",
		"\n%{http_code}",
		url,
	}

	vim.system(cmd, { text = true }, function(obj)
		local result
		if obj.code ~= 0 then
			result = { error = "request failed" }
		else
			local body, status = (obj.stdout or ""):match("^(.*)\n(%d+)%s*$")
			status = tonumber(status)
			if not status then
				result = { error = "malformed response (no http_code trailer)" }
			elseif status == 404 then
				result = { error = "package not found", not_found = true }
			elseif status ~= 200 then
				result = { error = "http " .. tostring(status) }
			else
				local ok, data = pcall(vim.json.decode, body)
				if not ok or type(data) ~= "table" then
					result = { error = "invalid response" }
				else
					local versions = {}
					for _, rel in ipairs(data.releases or {}) do
						if rel.version then
							versions[#versions + 1] = rel.version
						end
					end
					result = {
						versions = versions,
						latest = data.latest_stable_version or data.latest_version,
						time = os.time(),
					}
				end
			end
		end
		cache[name] = result
		vim.schedule(function()
			callback(result)
		end)
	end)
end

return M
