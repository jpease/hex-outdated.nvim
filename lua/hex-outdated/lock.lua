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

return M
