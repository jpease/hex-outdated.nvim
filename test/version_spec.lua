local version = require("hex-outdated.version")

describe("version prerelease classification", function()
	it("uses Hex prerelease matching semantics", function()
		local explicit = version.classify("== 2.0.0-rc.2", { "1.9.0", "2.0.0-rc.2" })
		eq("up_to_date", explicit.status)
		eq("2.0.0-rc.2", explicit.latest)

		local stable = version.classify(">= 1.0.0", { "1.1.0-rc.1" })
		eq("invalid", stable.status)
	end)

	it("preserves prerelease identifiers in suggestions", function()
		local result = version.classify("== 2.0.0-rc.1", { "2.0.0-rc.1", "2.0.0-rc.2" })
		eq("outdated", result.status)
		eq("== 2.0.0-rc.2", result.suggested)
	end)
end)
