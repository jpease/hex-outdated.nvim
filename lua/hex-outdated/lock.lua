local version = require("hex-outdated.version")

local M = {}

--- Parse mix.lock contents into { [name] = version_string }. Only :hex entries
--- ("name": {:hex, :atom, "ver", ...}) are kept; git/path entries have no
--- semver and are skipped. Pure; no Neovim APIs.
function M.parse(text)
	local locks = {}
	if type(text) ~= "string" then
		return locks
	end
	for name, ver in text:gmatch('"([%w_]+)"%s*:%s*{:hex,%s*:[%w_]+,%s*"([^"]+)"') do
		locks[name] = ver
	end
	return locks
end

--- True when locked < latest. False if either version is unparseable.
function M.behind(locked_str, latest_str)
	local l = version.parse(locked_str)
	local r = version.parse(latest_str)
	if not l or not r then
		return false
	end
	return version.compare(l, r) < 0
end

--- True when `locked_str` does NOT satisfy a parseable single-clause
--- requirement. False when the requirement is unparseable (combined and/or) or
--- the locked version is unparseable — we do not guess.
function M.out_of_range(requirement_str, locked_str)
	local req = version.parse_requirement(requirement_str)
	local locked = version.parse(locked_str)
	if not req or not locked then
		return false
	end
	return not version.satisfies(req, locked)
end

-- Strip the last "/component" from a POSIX-style path.
local function dirname(path)
	return (path:gsub("/[^/]*$", ""))
end

--- Locate the mix.lock governing `mix_exs_path`: sibling first, then the nearest
--- ancestor directory (umbrella apps share one root lock). `exists` defaults to
--- a vim.uv stat check and is injectable for tests. Returns the path or nil.
function M.find_lock_path(mix_exs_path, exists)
	exists = exists or function(p)
		return vim.uv.fs_stat(p) ~= nil
	end
	if type(mix_exs_path) ~= "string" or mix_exs_path == "" then
		return nil
	end
	local dir = dirname(mix_exs_path)
	while true do
		local candidate = dir .. "/mix.lock"
		if exists(candidate) then
			return candidate
		end
		local parent = dirname(dir)
		if parent == dir or parent == "" then
			return nil
		end
		dir = parent
	end
end

-- path -> { mtime = seconds, map = table }. A debounced analyze calls load() on
-- every cycle; memoizing by mtime avoids re-reading an unchanged file.
local cache = {}

--- Reset the load cache (used by tests).
function M.clear_cache()
	cache = {}
end

--- Read + parse the lock file at `path`, memoized by mtime. Returns the
--- name -> version map, or {} when the file is missing or unreadable.
function M.load(path)
	if type(path) ~= "string" then
		return {}
	end
	local stat = vim.uv.fs_stat(path)
	if not stat then
		return {}
	end
	local mtime = stat.mtime.sec
	local entry = cache[path]
	if entry and entry.mtime == mtime then
		return entry.map
	end
	local fd = io.open(path, "r")
	if not fd then
		return {}
	end
	local text = fd:read("*a")
	fd:close()
	local map = M.parse(text)
	cache[path] = { mtime = mtime, map = map }
	return map
end

return M
