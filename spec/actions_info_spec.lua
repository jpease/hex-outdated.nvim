-- actions loads render (via core), which creates namespaces at load.
local old_vim = rawget(_G, "vim")
_G.vim = { api = { nvim_create_namespace = function() end } }
local actions = require("hex-outdated.actions")
_G.vim = old_vim

describe("actions._info_lines", function()
	local function info(dep)
		local lines = actions._info_lines(dep)
		return { name = lines[1], requirement = lines[2], locked = lines[3], latest = lines[4] }
	end

	local base = { name = "jason", requirement = "~> 1.0", status = "upgradable", latest = "1.4.5" }
	local function with(fields)
		local dep = {}
		for k, v in pairs(base) do
			dep[k] = v
		end
		for k, v in pairs(fields) do
			dep[k] = v
		end
		return dep
	end

	it("shows the name, requirement, locked and latest versions", function()
		local lines = info(with({ locked = "1.2.0" }))
		assert.are.equal("jason", lines.name)
		assert.is_truthy(lines.requirement:find("~> 1.0", 1, true))
		assert.is_truthy(lines.locked:find("1.2.0", 1, true))
		assert.is_truthy(lines.latest:find("1.4.5", 1, true))
	end)

	it("distinguishes behind, current, out-of-range and unknown-latest lock notes", function()
		local notes = {
			info(with({ locked = "1.2.0" })).locked,
			info(with({ locked = "1.2.0", latest = "1.2.0" })).locked,
			info(with({ locked = "1.2.0", requirement = "~> 2.0" })).locked,
			info(with({ locked = "1.2.0", latest = false })).locked,
			info(with({})).locked,
		}
		for i = 1, #notes do
			for j = i + 1, #notes do
				assert.are_not.equal(notes[i], notes[j])
			end
		end
	end)

	it("distinguishes a failed fetch from one still loading", function()
		local loading = info({ name = "phoenix", requirement = "~> 1.7", status = "loading" })
		local failed = info({ name = "phoenix", requirement = "~> 1.7", status = "error" })
		assert.are_not.equal(loading.requirement, failed.requirement)
		assert.are_not.equal(loading.latest, failed.latest)
	end)
end)
