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

describe("lock.behind", function()
	it("is true when locked < latest", function()
		assert.is_true(lock.behind("1.2.0", "1.4.5"))
	end)
	it("is false when locked == latest or ahead", function()
		assert.is_false(lock.behind("1.4.5", "1.4.5"))
		assert.is_false(lock.behind("1.5.0", "1.4.5"))
	end)
	it("is false when either version is unparseable", function()
		assert.is_false(lock.behind("garbage", "1.4.5"))
		assert.is_false(lock.behind("1.2.0", nil))
	end)
end)

describe("lock.out_of_range", function()
	it("is true when locked does not satisfy the requirement", function()
		assert.is_true(lock.out_of_range("~> 2.0", "1.2.0"))
		assert.is_true(lock.out_of_range("== 3.0.0", "3.1.0"))
	end)
	it("is false when locked satisfies the requirement", function()
		assert.is_false(lock.out_of_range("~> 1.0", "1.2.0"))
	end)
	it("is false for an unparseable (combined) requirement", function()
		assert.is_false(lock.out_of_range(">= 1.0.0 and < 2.0.0", "0.9.0"))
	end)
end)

describe("lock.find_lock_path", function()
	-- exists predicate over a fixed set of present files.
	local function present(set)
		return function(p)
			return set[p] == true
		end
	end

	it("finds mix.lock next to mix.exs", function()
		local exists = present({ ["/proj/mix.lock"] = true })
		assert.are.equal("/proj/mix.lock", lock.find_lock_path("/proj/mix.exs", exists))
	end)

	it("walks up to a parent lock (umbrella apps)", function()
		local exists = present({ ["/proj/mix.lock"] = true })
		assert.are.equal("/proj/mix.lock", lock.find_lock_path("/proj/apps/web/mix.exs", exists))
	end)

	it("returns nil when no lock exists in any ancestor", function()
		assert.is_nil(lock.find_lock_path("/proj/apps/web/mix.exs", present({})))
	end)

	it("returns nil for empty/non-string input", function()
		assert.is_nil(lock.find_lock_path("", present({})))
		assert.is_nil(lock.find_lock_path(nil, present({})))
	end)
end)
