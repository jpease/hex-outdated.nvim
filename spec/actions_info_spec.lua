local actions = require("hex-outdated.actions")

describe("actions._info_lines", function()
	it("shows requirement/locked/latest with a behind note", function()
		local lines = actions._info_lines({
			name = "jason",
			requirement = "~> 1.0",
			status = "upgradable",
			latest = "1.4.5",
			locked = "1.2.0",
		})
		assert.are.equal("jason", lines[1])
		assert.is_truthy(lines[2]:find("~> 1.0", 1, true))
		assert.is_truthy(lines[3]:find("locked", 1, true))
		assert.is_truthy(lines[3]:find("1.2.0", 1, true))
		assert.is_truthy(lines[3]:find("behind latest", 1, true))
		assert.is_truthy(lines[4]:find("1.4.5", 1, true))
	end)

	it("notes when the locked version is not in mix.lock", function()
		local lines =
			actions._info_lines({ name = "x", requirement = "~> 1.0", status = "loading" })
		assert.is_truthy(lines[3]:find("not in mix.lock", 1, true))
	end)

	it("notes an out-of-range lock", function()
		local lines = actions._info_lines({
			name = "x",
			requirement = "~> 2.0",
			status = "upgradable",
			latest = "2.1.0",
			locked = "1.0.0",
		})
		assert.is_truthy(lines[3]:find("not satisfied by requirement", 1, true))
	end)
end)
