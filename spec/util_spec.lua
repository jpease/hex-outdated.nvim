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
end)
