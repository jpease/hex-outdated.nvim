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

return M
