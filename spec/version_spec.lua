local version = require("hex-outdated.version")

describe("version.parse", function()
	it("parses a full semver", function()
		local v = version.parse("1.7.14")
		assert.are.equal(1, v.major)
		assert.are.equal(7, v.minor)
		assert.are.equal(14, v.patch)
		assert.are.equal(3, v.precision)
		assert.is_nil(v.pre)
	end)

	it("records lower precision and defaults missing parts to 0", function()
		local v = version.parse("1.6")
		assert.are.equal(6, v.minor)
		assert.are.equal(0, v.patch)
		assert.are.equal(2, v.precision)
	end)

	it("captures pre-release and strips build metadata", function()
		local v = version.parse("2.0.0-rc.1+build5")
		assert.are.equal("rc.1", v.pre)
		assert.are.equal(2, v.major)
	end)

	it("returns nil for garbage", function()
		assert.is_nil(version.parse("not-a-version"))
	end)

	it("returns nil for trailing/empty dot groups", function()
		assert.is_nil(version.parse("1.."))
		assert.is_nil(version.parse("1.2."))
	end)

	it("rejects versions with more than three numeric core components", function()
		assert.is_nil(version.parse("1.2.3.4"))
		assert.is_nil(version.parse("1.0.0.0"))
	end)
end)

describe("version.parse numeric identifier digit limit", function()
	-- Elixir 1.20.3 (OTP 29), verified 2026-08-12:
	--   Version.parse("99999999999999.0.0")       -> {:ok, _}  (14 digits, accepted)
	--   Version.parse("100000000000000.0.0")      -> :error    (15 digits, rejected)
	--   Version.parse("1.0.0-99999999999999")     -> {:ok, _}  (14 digits, accepted)
	--   Version.parse("1.0.0-100000000000000")    -> :error    (15 digits, rejected)
	--   Version.parse("1.0.0+100000000000000")    -> {:ok, _}  (build metadata not numeric, unlimited)
	--   Version.parse("1.0.0-abc100000000000000") -> {:ok, _}  (non-numeric prerelease id, unlimited)
	it("accepts a 14-digit core numeric identifier (the exact boundary)", function()
		assert.is_not_nil(version.parse("99999999999999.0.0"))
	end)

	it("rejects a 15-digit core numeric identifier", function()
		assert.is_nil(version.parse("100000000000000.0.0"))
	end)

	it("accepts a 14-digit numeric prerelease identifier (the exact boundary)", function()
		assert.is_not_nil(version.parse("1.0.0-99999999999999"))
	end)

	it("rejects a 15-digit numeric prerelease identifier", function()
		assert.is_nil(version.parse("1.0.0-100000000000000"))
	end)

	it("does not apply the digit limit to build metadata (negative control)", function()
		assert.is_not_nil(version.parse("1.0.0+100000000000000"))
	end)

	it(
		"does not apply the digit limit to a non-numeric prerelease identifier (negative control)",
		function()
			assert.is_not_nil(version.parse("1.0.0-abc100000000000000"))
		end
	)
end)

describe("version.is_stable / tostring", function()
	local p = version.parse
	it("flags pre-releases as unstable", function()
		assert.is_true(version.is_stable(p("1.0.0")))
		assert.is_false(version.is_stable(p("1.0.0-rc.1")))
	end)
	it("round-trips to a string", function()
		assert.are.equal("1.7.14", version.tostring(p("1.7.14")))
		assert.are.equal("2.0.0-rc.1", version.tostring(p("2.0.0-rc.1")))
	end)
end)

describe("version.parse_requirement", function()
	it("defaults a bare version to ==", function()
		assert.are.equal("==", version.parse_requirement("1.2.3").op)
	end)
	it("returns nil for combined clauses and garbage", function()
		assert.is_nil(version.parse_requirement(">= 1.0.0 and < 2.0.0"))
		assert.is_nil(version.parse_requirement("~> nonsense"))
	end)

	it(
		"fails the whole requirement (not a silently-dropped operand) for an over-limit operand",
		function()
			-- 15-digit core identifier: Elixir rejects it (see the digit-limit tests
			-- above), so M.parse returns nil for the operand and parse_requirement
			-- must propagate that as a full failure rather than returning a
			-- requirement with a missing/garbage version.
			assert.is_nil(version.parse_requirement("~> 100000000000000.0.0"))
			assert.is_nil(version.parse_requirement("== 1.0.0-100000000000000"))
		end
	)
end)

describe("version.compare", function()
	local p = version.parse
	it("orders by major/minor/patch", function()
		assert.are.equal(-1, version.compare(p("1.2.3"), p("1.3.0")))
		assert.are.equal(1, version.compare(p("2.0.0"), p("1.9.9")))
		assert.are.equal(0, version.compare(p("1.0.0"), p("1.0.0")))
	end)
	it("treats a pre-release as lower than its release", function()
		assert.are.equal(-1, version.compare(p("1.0.0-rc.1"), p("1.0.0")))
	end)
	it("orders numeric pre-release identifiers numerically, not lexically", function()
		-- The lexical trap: "rc.10" must rank above "rc.2".
		assert.are.equal(1, version.compare(p("1.0.0-rc.10"), p("1.0.0-rc.2")))
		assert.are.equal(-1, version.compare(p("1.0.0-alpha.2"), p("1.0.0-alpha.10")))
	end)
	it("ranks numeric identifiers below alphanumeric ones", function()
		assert.are.equal(-1, version.compare(p("1.0.0-1"), p("1.0.0-alpha")))
	end)
	it("ranks a longer identifier list higher when the prefix is equal", function()
		-- semver §11: 1.0.0-alpha < 1.0.0-alpha.1
		assert.are.equal(-1, version.compare(p("1.0.0-alpha"), p("1.0.0-alpha.1")))
		assert.are.equal(1, version.compare(p("1.0.0-alpha.beta"), p("1.0.0-alpha")))
	end)
	it("follows the semver §11 precedence chain", function()
		local chain = {
			"1.0.0-alpha",
			"1.0.0-alpha.1",
			"1.0.0-alpha.beta",
			"1.0.0-beta",
			"1.0.0-beta.2",
			"1.0.0-beta.11",
			"1.0.0-rc.1",
			"1.0.0",
		}
		for i = 1, #chain - 1 do
			assert.are.equal(
				-1,
				version.compare(p(chain[i]), p(chain[i + 1])),
				chain[i] .. " < " .. chain[i + 1]
			)
		end
	end)
end)

describe("version.satisfies", function()
	local p = version.parse
	local req = version.parse_requirement
	it("handles ~> two-component upper bound", function()
		assert.is_true(version.satisfies(req("~> 1.6"), p("1.7.14"))) -- < 2.0.0
		assert.is_false(version.satisfies(req("~> 1.6"), p("2.0.0")))
		assert.is_false(version.satisfies(req("~> 1.6"), p("1.5.0")))
	end)
	it("handles ~> three-component upper bound", function()
		assert.is_true(version.satisfies(req("~> 1.6.2"), p("1.6.9"))) -- < 1.7.0
		assert.is_false(version.satisfies(req("~> 1.6.2"), p("1.7.0")))
	end)
	it("handles comparison operators and bare exact", function()
		assert.is_true(version.satisfies(req(">= 1.0.0"), p("2.5.0")))
		assert.is_true(version.satisfies(req("== 1.2.3"), p("1.2.3")))
		assert.is_false(version.satisfies(req("1.2.3"), p("1.2.4")))
	end)

	it("allows a prerelease below a stable upper bound with <", function()
		assert.is_true(version.satisfies(req("< 1.2.3"), p("1.2.3-alpha")))
	end)

	it("allows a prerelease below a stable upper bound with <=", function()
		assert.is_true(version.satisfies(req("<= 1.2.3"), p("1.2.3-alpha")))
	end)

	it("allows a prerelease not equal to a stable operand with !=", function()
		assert.is_true(version.satisfies(req("!= 1.2.3"), p("1.2.3-alpha")))
	end)

	it("still excludes a prerelease against a stable operand with >= (lower bound)", function()
		assert.is_false(version.satisfies(req(">= 1.2.3"), p("1.2.3-alpha")))
	end)

	it(
		"still excludes a prerelease against a stable operand with > even when numerically above",
		function()
			assert.is_false(version.satisfies(req("> 1.0.0"), p("1.2.3-alpha")))
		end
	)

	it("still excludes a prerelease against a stable operand with ==", function()
		assert.is_false(version.satisfies(req("== 1.2.3"), p("1.2.3-alpha")))
	end)

	it("excludes a prerelease of the ~> exclusive upper bound itself", function()
		-- tilde_upper("2.0-rc") is the plain release 3.0.0; a prerelease *of* that
		-- bound (3.0.0-rc.1) must not satisfy, even though req.version has a pre.
		assert.is_false(version.satisfies(req("~> 2.0-rc"), p("3.0.0-rc.1")))
	end)

	it("still allows a prerelease strictly below the ~> upper bound", function()
		assert.is_true(version.satisfies(req("~> 2.0-rc"), p("2.1.0-rc.1")))
	end)

	it("still allows a prerelease of the requirement's own major.minor.patch for ~>", function()
		assert.is_true(version.satisfies(req("~> 2.0-rc"), p("2.0.0-rc.2")))
	end)

	it("leaves >= unaffected by the ~> upper-bound-prerelease fix", function()
		assert.is_true(version.satisfies(req(">= 2.0.0-rc"), p("3.0.0-rc.1")))
	end)

	it("still allows a prerelease strictly below a three-component ~> upper bound", function()
		assert.is_true(version.satisfies(req("~> 2.0.0-rc"), p("2.0.1-rc.1")))
	end)
end)
