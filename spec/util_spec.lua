local util = require("hex-outdated.util")

describe("util.deep_merge", function()
	it("returns a deep clone when override is empty", function()
		local base = { a = 1, nested = { b = 2 } }
		local out = util.deep_merge(base, {})
		assert.are.same({ a = 1, nested = { b = 2 } }, out)
		out.nested.b = 99
		assert.are.equal(2, base.nested.b)
	end)

	it("recursively merges nested tables", function()
		local base = { api = { url = "x", timeout = 1 }, on = true }
		local out = util.deep_merge(base, { api = { timeout = 5 }, on = false })
		assert.are.same({ api = { url = "x", timeout = 5 }, on = false }, out)
	end)

	it("copies override tables instead of aliasing them", function()
		local override = { a = { x = 1 }, extra = { y = 1 } }
		local out = util.deep_merge({ a = 1 }, override)
		override.a.x = 99
		override.extra.y = 99
		assert.are.same({ a = { x = 1 }, extra = { y = 1 } }, out)
	end)
end)

describe("util.url_host", function()
	it("extracts the host and port of a URL", function()
		assert.are.equal("hex.pm", util.url_host("https://hex.pm/api"))
		assert.are.equal("mirror.test:8080", util.url_host("http://mirror.test:8080/api?x=1"))
	end)

	it("returns a scheme-less input unchanged", function()
		assert.are.equal("localhost/api", util.url_host("localhost/api"))
	end)
end)
