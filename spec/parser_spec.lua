local parser = require("hex-outdated.parser")

describe("parser.parse_lines (fallback)", function()
	local lines = {
		"defp deps do",
		"  [",
		'    {:phoenix, "~> 1.6"},',
		'    {:jason, "~> 1.4", only: :test},',
		'    {:my_dep, github: "owner/repo"},',
		"  ]",
		"end",
	}

	it("extracts hex deps with name, requirement, and 0-indexed ranges", function()
		local deps = parser.parse_lines(lines)
		assert.are.equal(2, #deps)

		assert.are.equal("phoenix", deps[1].name)
		assert.are.equal("~> 1.6", deps[1].requirement)
		assert.are.equal("hex", deps[1].kind)
		assert.are.equal(2, deps[1].row) -- 0-indexed line 3
		-- the requirement content is between the quotes
		local line = lines[deps[1].row + 1]
		assert.are.equal("~> 1.6", line:sub(deps[1].col_start + 1, deps[1].col_end))
	end)

	it("keeps deps that have version + options, with correct ranges", function()
		local deps = parser.parse_lines(lines)
		assert.are.equal("jason", deps[2].name)
		assert.are.equal("~> 1.4", deps[2].requirement)
		local line = lines[deps[2].row + 1]
		assert.are.equal("~> 1.4", line:sub(deps[2].col_start + 1, deps[2].col_end))
	end)

	it("skips scm deps with no positional version string", function()
		local deps = parser.parse_lines(lines)
		for _, d in ipairs(deps) do
			assert.are_not.equal("my_dep", d.name)
		end
	end)

	it("reads the tuple's quote even if an earlier quote precedes it", function()
		local deps = parser.parse_lines({ '  # "note" {:phoenix, "~> 1.6"},' })
		assert.are.equal(1, #deps)
		assert.are.equal("phoenix", deps[1].name)
		assert.are.equal("~> 1.6", deps[1].requirement)
		local line = '  # "note" {:phoenix, "~> 1.6"},'
		assert.are.equal("~> 1.6", line:sub(deps[1].col_start + 1, deps[1].col_end))
	end)
end)

describe("parser.parse_buffer treesitter query caching", function()
	local old_vim
	local ts_parser
	local query_parse_calls

	before_each(function()
		old_vim = rawget(_G, "vim")
		query_parse_calls = 0
		local fake_query = {
			captures = {},
			-- empty iterator: no deps, keeps the test focused on compile count
			iter_captures = function()
				return function()
					return nil
				end
			end,
		}
		local fake_tree = {
			root = function()
				return {}
			end,
		}
		local lang_tree = {
			parse = function()
				return { fake_tree }
			end,
		}
		_G.vim = {
			treesitter = {
				get_parser = function()
					return lang_tree
				end,
				query = {
					parse = function()
						query_parse_calls = query_parse_calls + 1
						return fake_query
					end,
				},
				get_node_text = function()
					return ""
				end,
			},
		}
		package.loaded["hex-outdated.parser"] = nil
		ts_parser = require("hex-outdated.parser")
	end)

	after_each(function()
		package.loaded["hex-outdated.parser"] = nil
		_G.vim = old_vim
	end)

	it("compiles the query only once across repeated parses", function()
		assert.are.same({}, ts_parser.parse_buffer(1))
		assert.are.same({}, ts_parser.parse_buffer(1))
		assert.are.same({}, ts_parser.parse_buffer(2))

		assert.are.equal(1, query_parse_calls)
	end)
end)
