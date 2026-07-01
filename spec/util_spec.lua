local util = require("hex-outdated.util")

describe("util.deep_merge", function()
	it("returns a deep clone when override is empty", function()
		local base = { a = 1, nested = { b = 2 } }
		local out = util.deep_merge(base, {})
		assert.are.same({ a = 1, nested = { b = 2 } }, out)
		out.nested.b = 99
		assert.are.equal(2, base.nested.b) -- original not mutated
	end)

	it("recursively merges nested tables", function()
		local base = { api = { url = "x", timeout = 1 }, on = true }
		local out = util.deep_merge(base, { api = { timeout = 5 }, on = false })
		assert.are.same({ api = { url = "x", timeout = 5 }, on = false }, out)
	end)

	it("override scalar replaces a table", function()
		local out = util.deep_merge({ a = { x = 1 } }, { a = 7 })
		assert.are.equal(7, out.a)
	end)

	it("override table replaces a scalar", function()
		local out = util.deep_merge({ a = 1 }, { a = { x = 1 } })
		assert.are.same({ x = 1 }, out.a)
	end)

	it("does not alias an override table that replaces a scalar (issue #37)", function()
		local override = { a = { x = 1 } }
		local out = util.deep_merge({ a = 1 }, override)
		override.a.x = 99
		assert.are.equal(1, out.a.x, "mutating the override after merge must not affect the result")
	end)

	it("does not alias an override table under a key absent from base (issue #37)", function()
		local override = { my_extra = { a = 1 } }
		local out = util.deep_merge({}, override)
		override.my_extra.a = 2
		assert.are.equal(
			1,
			out.my_extra.a,
			"mutating the override after merge must not affect the result"
		)
	end)
end)

describe("util.timeout_seconds", function()
	it("converts milliseconds without truncating fractional seconds", function()
		assert.are.equal(0.25, util.timeout_seconds(250))
		assert.are.equal(5.2, util.timeout_seconds(5200))
	end)

	it("uses the supplied fallback for invalid values", function()
		assert.are.equal(5, util.timeout_seconds(nil, 5000))
		assert.are.equal(5, util.timeout_seconds("5000", 5000))
		assert.are.equal(5, util.timeout_seconds(0, 5000))
		assert.are.equal(5, util.timeout_seconds(-1, 5000))
		assert.are.equal(5, util.timeout_seconds(math.huge, 5000))
	end)
end)
