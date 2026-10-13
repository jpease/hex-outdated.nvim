local M = {}

--- Parse mix.lock contents into { [name] = version_string }. Keeps only :hex
--- entries ("name": {:hex, :atom, "ver", ...}) and skips git/path entries,
--- which carry no semver. Pure; no Neovim APIs.
function M.parse(text)
	local locks = {}
	for name, ver in text:gmatch('"([%w_]+)"%s*:%s*{:hex,%s*:[%w_]+,%s*"([^"]+)"') do
		locks[name] = ver
	end
	return locks
end

--- Locate the mix.lock governing `mix_exs_path`: sibling first, then the nearest
--- ancestor directory (umbrella apps share one root lock). Returns the path or nil.
function M.find_lock_path(mix_exs_path)
	if mix_exs_path == "" then
		return nil
	end
	return vim.fs.find("mix.lock", { upward = true, path = vim.fs.dirname(mix_exs_path) })[1]
end

-- path -> { identity = metadata signature, map = table }. Keyed by mtime, ctime
-- and size so same-second rewrites are still detected.
local cache = {}

--- Reset the load cache (used by tests).
function M.clear_cache()
	cache = {}
end

local function stat_identity(stat)
	return table.concat({
		stat.mtime.sec,
		stat.mtime.nsec,
		stat.ctime.sec,
		stat.ctime.nsec,
		stat.size,
	}, ":")
end

--- Read + parse the lock file at `path`, memoized by file metadata. Returns the
--- name -> version map, or {} when the file is missing or unreadable.
function M.load(path)
	local stat = vim.uv.fs_stat(path)
	if not stat then
		return {}
	end
	local identity = stat_identity(stat)
	local entry = cache[path]
	if entry and entry.identity == identity then
		return entry.map
	end
	local fd = io.open(path, "r")
	if not fd then
		return {}
	end
	local text = fd:read("*a")
	fd:close()
	local map = M.parse(text)
	cache[path] = { identity = identity, map = map }
	return map
end

return M
