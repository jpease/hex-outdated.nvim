local lock = require("hex-outdated.lock")

describe("lock.parse", function()
	it("extracts hex name -> version, ignoring git/path entries", function()
		local text = [[
%{
  "jason": {:hex, :jason, "1.4.1", "abc", [:mix], [], "hexpm", "def"},
  "phoenix": {:hex, :phoenix, "1.7.10", "abc", [:mix], [], "hexpm", "def"},
  "my_fork": {:git, "https://example.com/x.git", "deadbeef", []},
  "local_dep": {:path, "../local_dep"},
}
]]
		local map = lock.parse(text)
		assert.are.equal("1.4.1", map.jason)
		assert.are.equal("1.7.10", map.phoenix)
		assert.is_nil(map.my_fork)
		assert.is_nil(map.local_dep)
	end)

	it("handles a renamed package (key differs from hex atom)", function()
		local map = lock.parse(
			'  "local_name": {:hex, :actual_pkg, "2.0.0", "x", [:mix], [], "hexpm", "y"},'
		)
		assert.are.equal("2.0.0", map.local_name)
	end)

	it("returns an empty table for empty or non-string input", function()
		assert.are.same({}, lock.parse(""))
		assert.are.same({}, lock.parse(nil))
	end)
end)
