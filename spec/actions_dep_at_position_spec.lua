local actions = require("hex-outdated.actions")

describe("actions.dep_at_position", function()
	it("selects each dependency by exact span on a compact line with multiple deps", function()
		local deps = {
			{ name = "first", row = 0, col_start = 5, col_end = 10 },
			{ name = "second", row = 0, col_start = 15, col_end = 20 },
		}
		assert.are.equal("first", actions.dep_at_position(deps, 0, 7).name)
		assert.are.equal("second", actions.dep_at_position(deps, 0, 17).name)
		-- span is half-open: col_start is inside, col_end is not
		assert.are.equal("first", actions.dep_at_position(deps, 0, 5).name)
		assert.are.equal("second", actions.dep_at_position(deps, 0, 19).name)
	end)

	it("selects the nearest dependency when the cursor sits between two spans", function()
		local deps = {
			{ name = "left", row = 0, col_start = 5, col_end = 10 },
			{ name = "right", row = 0, col_start = 20, col_end = 25 },
		}
		-- cursor after "left"'s span, closer to it than to "right"
		assert.are.equal("left", actions.dep_at_position(deps, 0, 12).name)
		-- cursor before "right"'s span, closer to it than to "left"
		assert.are.equal("right", actions.dep_at_position(deps, 0, 18).name)
	end)

	it("on an exact tie, keeps the first dependency encountered in iteration order", function()
		-- current algorithm uses strict `<` when comparing distances, so an
		-- equidistant cursor never overwrites the first candidate found.
		local deps = {
			{ name = "left", row = 0, col_start = 5, col_end = 10 },
			{ name = "right", row = 0, col_start = 20, col_end = 25 },
		}
		-- col 15 is 5 away from both spans (15-10 == 20-15)
		assert.are.equal("left", actions.dep_at_position(deps, 0, 15).name)
	end)

	it("selects a span-less dependency on the matching row regardless of column", function()
		local deps = { { name = "spanless", row = 3 } }
		assert.are.equal("spanless", actions.dep_at_position(deps, 3, 0).name)
		assert.are.equal("spanless", actions.dep_at_position(deps, 3, 999).name)
	end)

	it("prefers the first span-less dependency on the row when several lack spans", function()
		local deps = {
			{ name = "one", row = 3 },
			{ name = "two", row = 3 },
		}
		assert.are.equal("one", actions.dep_at_position(deps, 3, 0).name)
	end)

	it("returns nil when no dependency matches the row", function()
		local deps = { { name = "first", row = 0, col_start = 5, col_end = 10 } }
		assert.is_nil(actions.dep_at_position(deps, 1, 0))
	end)

	it("returns nil for an empty or nil dependency list", function()
		assert.is_nil(actions.dep_at_position({}, 0, 0))
		assert.is_nil(actions.dep_at_position(nil, 0, 0))
	end)
end)
