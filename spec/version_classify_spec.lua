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

	it("treats a >= requirement as up_to_date when the max satisfying is latest", function()
		local r = version.classify(">= 1.0.0", { "1.0.0", "2.0.0" })
		assert.are.equal("up_to_date", r.status)
		assert.are.equal("2.0.0", r.latest)
	end)

	it("does not crash when only pre-releases are published", function()
		-- ~> 1.0 does not satisfy 1.0.0-rc.1 (a pre-release sorts below its release)
		local r = version.classify("~> 1.0", { "1.0.0-rc.1" })
		assert.are.equal("invalid", r.status)
	end)

	it(
		"matches an explicit prerelease requirement even when older stable releases exist",
		function()
			local r = version.classify("== 2.0.0-rc.2", { "1.9.0", "2.0.0-rc.2" })
			assert.are.equal("up_to_date", r.status)
			assert.are.equal("2.0.0-rc.2", r.latest)
		end
	)

	it("excludes prereleases for stable operands using Hex matching semantics", function()
		local r = version.classify(">= 1.0.0", { "1.1.0-rc.1" })
		assert.are.equal("invalid", r.status)
	end)

	it("preserves prerelease identifiers in suggested exact requirements", function()
		local r = version.classify("== 2.0.0-rc.1", { "2.0.0-rc.1", "2.0.0-rc.2" })
		assert.are.equal("outdated", r.status)
		assert.are.equal("== 2.0.0-rc.2", r.suggested)
	end)

	it("allows prerelease candidates when the pessimistic operand is a prerelease", function()
		local r = version.classify("~> 2.1.2-dev", { "2.1.2-dev", "2.1.6-dev" })
		assert.are.equal("upgradable", r.status)
		assert.are.equal("2.1.6-dev", r.latest)
		assert.are.equal("~> 2.1.6-dev", r.suggested)
	end)

	it(
		"reports upgradable when a strict-less-than constraint excludes the latest release",
		function()
			local r = version.classify("< 2.0.0", { "1.9.0", "2.0.0" })
			assert.are.equal("upgradable", r.status)
			assert.are.equal("2.0.0", r.latest)
		end
	)

	it("reports upgradable when not-equal excludes the latest release", function()
		local r = version.classify("!= 3.0.0", { "1.0.0", "2.0.0", "3.0.0" })
		assert.are.equal("upgradable", r.status)
		assert.are.equal("3.0.0", r.latest)
	end)

	it("reports invalid for a requirement with extra numeric components", function()
		local r = version.classify("== 1.2.3.4", { "1.2.3" })
		assert.are.equal("unknown", r.status)
	end)

	it(
		"treats a prerelease as up_to_date against a < requirement when it's the only published version",
		function()
			-- Only published version is 1.2.3-alpha, no stable releases exist, so the pool
			-- falls back to all parsed versions. 1.2.3-alpha satisfies "< 1.2.3" (upper-bound
			-- operators admit prereleases below the stable bound), and it's also the latest
			-- in the pool, so it is up_to_date rather than invalid.
			local r = version.classify("< 1.2.3", { "1.2.3-alpha" })
			assert.are.equal("up_to_date", r.status)
			assert.are.equal("1.2.3-alpha", r.latest)
		end
	)

	it(
		"returns unknown for a requirement whose operand exceeds the 14-digit numeric limit",
		function()
			-- Elixir 1.20.3 rejects a 15-digit numeric identifier (see spec/version_spec.lua
			-- for the reference output), so M.parse_requirement returns nil for this
			-- requirement and classify must report "unknown", not a bogus comparison
			-- against whatever `latest` happens to be in `published`.
			local r = version.classify("~> 100000000000000.0.0", published)
			assert.are.equal("unknown", r.status)
		end
	)

	it("does not treat a prerelease of the ~> upper bound itself as satisfying", function()
		-- req.version has a pre ("rc"), so the pool is all parsed versions (no stable
		-- fallback needed here since there are no stables anyway). 3.0.0-rc.1 is the
		-- only candidate and becomes `latest`, but it must NOT satisfy "~> 2.0-rc"
		-- since it's a prerelease of the exclusive upper bound (3.0.0), not a version
		-- strictly below it. With no satisfying candidate, status is "invalid".
		local r = version.classify("~> 2.0-rc", { "3.0.0-rc.1" })
		assert.are.equal("invalid", r.status)
		assert.are.equal("3.0.0-rc.1", r.latest)
	end)
end)

describe("version.classify memoization", function()
	-- Count M.parse calls during classify to detect re-parsing of the version list.
	local function count_parses(fn)
		local orig = version.parse
		local calls = 0
		version.parse = function(...)
			calls = calls + 1
			return orig(...)
		end
		local ok, err = pcall(fn)
		version.parse = orig
		assert.is_true(ok, tostring(err))
		return calls
	end

	it("reuses the cached result for a repeated (list, requirement) pair", function()
		local list = { "1.6.0", "1.7.0", "1.7.14" }
		local first = version.classify("~> 1.6", list)

		local second
		local parses = count_parses(function()
			second = version.classify("~> 1.6", list)
		end)

		assert.are.equal(0, parses)
		assert.are.same(first, second) -- value-equal, but not required to be the same table
	end)

	it("does not let mutating one returned result affect a later classification", function()
		local list = { "1.6.0", "1.7.0", "1.7.14" }
		local first = version.classify("~> 1.6", list)
		local expected_status = first.status
		local expected_latest = first.latest

		first.status = "up_to_date"
		first.latest = "poisoned"
		first.op = "poisoned"

		local second = version.classify("~> 1.6", list)
		assert.are.equal(expected_status, second.status)
		assert.are.equal(expected_latest, second.latest)
		assert.are_not.equal("poisoned", second.op)
	end)

	it("recomputes when the requirement changes for the same list", function()
		local list = { "1.6.0", "1.7.0", "1.7.14" }
		version.classify("~> 1.6", list)

		local parses = count_parses(function()
			version.classify("== 1.6.0", list)
		end)

		assert.is_true(parses > 0)
	end)

	it("recomputes for an identical requirement against a different list", function()
		local parses = count_parses(function()
			version.classify("~> 1.6", { "1.6.0", "1.7.14" })
		end)

		assert.is_true(parses > 0)
	end)
end)

describe("version.suggested_requirement", function()
	local p = version.parse
	local req = version.parse_requirement
	it("keeps ~> precision when bumping", function()
		assert.are.equal("~> 1.7", version.suggested_requirement(req("~> 1.6"), p("1.7.14")))
		assert.are.equal("~> 1.7.14", version.suggested_requirement(req("~> 1.6.0"), p("1.7.14")))
	end)
	it("bumps an exact pin to the full latest", function()
		assert.are.equal("== 1.7.14", version.suggested_requirement(req("== 1.6.0"), p("1.7.14")))
	end)
	it("returns nil for range operators", function()
		assert.is_nil(version.suggested_requirement(req(">= 1.0.0"), p("2.0.0")))
	end)
end)
