local version = require("hex-outdated.version")

describe("version parse: leading zeros and invalid prerelease", function()
	it("rejects leading zeros in core version components", function()
		is_nil(version.parse("01.2.3"), "leading zero in major")
		is_nil(version.parse("1.02.3"), "leading zero in minor")
		is_nil(version.parse("1.2.03"), "leading zero in patch")
		truthy(version.parse("1.0.0"), "1.0.0 accepted")
		truthy(version.parse("10.2.3"), "10.2.3 accepted")
	end)

	it("rejects invalid prerelease identifiers", function()
		is_nil(version.parse("1.0.0-rc..1"), "empty prerelease component")
		is_nil(version.parse("1.0.0-01"), "numeric prerelease with leading zero")
		is_nil(version.parse("1.0.0-alpha_beta"), "underscore not allowed in prerelease")
		truthy(version.parse("1.0.0-rc.1"), "rc.1 accepted")
		truthy(version.parse("1.0.0-alpha"), "alpha accepted")
		truthy(version.parse("1.0.0-10"), "multi-digit numeric prerelease accepted")
	end)

	it("validates build metadata syntax (issue #29)", function()
		is_nil(version.parse("1.0.0+"), "empty build metadata rejected")
		is_nil(version.parse("1.0.0+bad_meta"), "underscore in build metadata rejected")
		is_nil(version.parse("1.0.0-alpha+bad_meta"), "invalid build after prerelease rejected")
		is_nil(version.parse("1.0.0+a..b"), "empty build identifier rejected")
		truthy(version.parse("1.0.0+bad"), "1.0.0+bad accepted")
		truthy(version.parse("1.0.0+bad.meta"), "dotted build metadata accepted")
		truthy(version.parse("1.0.0-alpha+001"), "leading-zero build identifier accepted")
	end)

	it("ignores build metadata for comparison precedence (issue #29)", function()
		eq(0, version.compare(version.parse("1.0.0+build"), version.parse("1.0.0")))
		eq(0, version.compare(version.parse("1.0.0+a"), version.parse("1.0.0+b")))
	end)

	it("validates build metadata in parse_requirement (issue #29)", function()
		is_nil(
			version.parse_requirement("== 1.0.0+bad_meta"),
			"invalid build in requirement rejected"
		)
		truthy(
			version.parse_requirement("== 1.0.0+bad.meta"),
			"valid build in requirement accepted"
		)
	end)
end)

describe("version parse_requirement: precision rules", function()
	it("rejects bare versions with fewer than 3 components", function()
		is_nil(version.parse_requirement("1.2"), "bare 1.2 rejected")
		truthy(version.parse_requirement("1.2.3"), "bare 1.2.3 accepted")
	end)

	it("rejects == and >= with fewer than 3 components", function()
		is_nil(version.parse_requirement("== 1.2"), "== 1.2 rejected")
		truthy(version.parse_requirement("== 1.2.3"), "== 1.2.3 accepted")
		is_nil(version.parse_requirement(">= 1.2"), ">= 1.2 rejected")
		truthy(version.parse_requirement(">= 1.2.3"), ">= 1.2.3 accepted")
	end)

	it("accepts ~> with 2 or 3 components", function()
		truthy(version.parse_requirement("~> 1.2"), "~> 1.2 accepted")
		truthy(version.parse_requirement("~> 1.2.3"), "~> 1.2.3 accepted")
	end)

	it("rejects ~> with a single component (issue #26)", function()
		-- Elixir Version.parse_requirement("~> 1") returns :error.
		is_nil(version.parse_requirement("~> 1"), "~> 1 rejected")
		eq("unknown", version.classify("~> 1", { "1.2.3" }).status)
	end)

	it("classifies invalid version syntax as unknown", function()
		local result = version.classify("== 01.2.3", { "1.2.3" })
		eq("unknown", result.status)
	end)
end)

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
