local version = require("hex-outdated.version")

local published = { "1.4.0", "1.4.4", "1.6.0", "1.6.16", "1.7.0", "1.7.14", "1.8.0-rc.0" }

describe("version.classify", function()
	it("flags a ~> requirement behind the latest minor as upgradable", function()
		local r = version.classify("~> 1.6", published)
		assert.are.equal("upgradable", r.status)
		assert.are.equal("1.7.14", r.latest)
		assert.are.equal("~> 1.7", r.suggested)
	end)

	it("treats a ~> requirement matching the latest minor as up to date", function()
		local r = version.classify("~> 1.7", published)
		assert.are.equal("up_to_date", r.status)
	end)

	it("ignores pre-releases when choosing the latest stable", function()
		local r = version.classify("~> 1.7", published)
		assert.are.equal("1.7.14", r.latest)
	end)

	it("flags an exact pin below latest as outdated", function()
		local r = version.classify("== 1.6.0", published)
		assert.are.equal("outdated", r.status)
		assert.are.equal("== 1.7.14", r.suggested)
	end)

	it("flags a requirement that matches no published version as invalid", function()
		local r = version.classify("~> 9.9", published)
		assert.are.equal("invalid", r.status)
	end)

	it("returns unknown for unparseable/combined requirements", function()
		local r = version.classify(">= 1.0.0 and < 2.0.0", published)
		assert.are.equal("unknown", r.status)
	end)
end)
