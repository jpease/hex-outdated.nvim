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

	it("ignores commented and unrelated tuples", function()
		local deps = parser.parse_lines({
			'def project, do: [example: {:not_a_dep, "1.0.0"}]',
			"defp deps do",
			'  # {:commented, "~> 1.0"}',
			'  [{:real_dep, "~> 2.0"}]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real_dep", deps[1].name)
	end)

	it("uses the dependency function referenced by project and records Hex aliases", function()
		local deps = parser.parse_lines({
			"def project do",
			"  [deps: project_deps()]",
			"end",
			"defp project_deps do",
			'  [{:local_app, "~> 2.0", hex: :actual_package}]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("local_app", deps[1].name)
		assert.are.equal("actual_package", deps[1].package)
	end)

	it("does not leak out of a one-line dependency function", function()
		local deps = parser.parse_lines({
			'defp deps, do: [{:real_dep, "~> 2.0"}]',
			'example = {:not_a_dep, "1.0.0"}',
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real_dep", deps[1].name)
	end)

	it("parses every dependency in a compact one-line declaration", function()
		local deps = parser.parse_lines({
			'defp deps, do: [{:jason, "~> 1.4"}, {:plug, "~> 1.15"}]',
		})

		assert.are.equal(2, #deps)
		assert.are.equal("jason", deps[1].name)
		assert.are.equal("~> 1.4", deps[1].requirement)
		assert.are.equal("plug", deps[2].name)
		assert.are.equal("~> 1.15", deps[2].requirement)
	end)

	it("scopes hex alias extraction to each tuple in a multi-dep line", function()
		local deps = parser.parse_lines({
			'defp deps, do: [{:dep_a, "~> 1.0"}, {:dep_b, "~> 2.0", hex: :actual_b}]',
		})

		assert.are.equal(2, #deps)
		assert.is_nil(deps[1].package)
		assert.are.equal("actual_b", deps[2].package)
	end)

	it("finds a dep whose requirement string wraps to the next line (issue #41)", function()
		local wrapped_lines = {
			"defp deps do",
			"  [",
			'    {:short_dep, "~> 1.0"},',
			"    {:a_very_long_package_name_here,",
			'     "~> 2.3", only: [:dev, :test], runtime: false}',
			"  ]",
			"end",
		}
		local deps = parser.parse_lines(wrapped_lines)
		assert.are.equal(2, #deps)

		assert.are.equal("short_dep", deps[1].name)
		assert.are.equal("~> 1.0", deps[1].requirement)
		assert.are.equal(2, deps[1].row) -- 0-indexed line 3
		local short_line = wrapped_lines[deps[1].row + 1]
		assert.are.equal("~> 1.0", short_line:sub(deps[1].col_start + 1, deps[1].col_end))

		assert.are.equal("a_very_long_package_name_here", deps[2].name)
		assert.are.equal("~> 2.3", deps[2].requirement)
		assert.are.equal(4, deps[2].row) -- 0-indexed line 5, the continuation line
		local wrapped_req_line = wrapped_lines[deps[2].row + 1]
		assert.are.equal("~> 2.3", wrapped_req_line:sub(deps[2].col_start + 1, deps[2].col_end))
	end)

	it("excludes nested list literals inside a multi-line assignment (issue #31)", function()
		local deps = parser.parse_lines({
			"defp deps do",
			"  metadata =",
			"    if true do",
			'      [{:ok, "not-a-dep"}]',
			"    end",
			"",
			'  [{:jason, "~> 1.0"}]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
		assert.are.equal("~> 1.0", deps[1].requirement)
	end)

	it("finds the dep list after a flush-left nested block end (issue #47)", function()
		local deps = parser.parse_lines({
			"defp deps do",
			"if true do",
			"  ignored = :ok",
			"end",
			'[{:jason, "~> 1.0"}]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
		assert.are.equal("~> 1.0", deps[1].requirement)
	end)

	it("resumes dep-scanning after deeply nested flush-left blocks (issue #47)", function()
		local deps = parser.parse_lines({
			"defp deps do",
			"if true do",
			"if false do",
			"  ignored = :ok",
			"end",
			"end",
			'[{:jason, "~> 1.0"}]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
		assert.are.equal("~> 1.0", deps[1].requirement)
	end)

	it("selects deps/0 when a multi-line deps/1 appears first (issue #51)", function()
		local deps = parser.parse_lines({
			"defp deps(",
			"  env",
			") do",
			'  [{:wrong, "~> 1.0"}]',
			"end",
			"",
			"defp deps do",
			'  [{:correct, "~> 2.0"}]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("correct", deps[1].name)
	end)

	it("finds deps inlined directly in project() with no deps/0 function (issue #42)", function()
		local deps = parser.parse_lines({
			"defmodule Demo.MixProject do",
			"  use Mix.Project",
			"  def project do",
			"    [",
			"      app: :demo,",
			'      version: "0.1.0",',
			'      deps: [{:jason, "~> 1.4"}, {:plug, "~> 1.15"}]',
			"    ]",
			"  end",
			"end",
		})

		assert.are.equal(2, #deps)
		assert.are.equal("jason", deps[1].name)
		assert.are.equal("~> 1.4", deps[1].requirement)
		assert.are.equal("plug", deps[2].name)
		assert.are.equal("~> 1.15", deps[2].requirement)
	end)

	it("treats a multi-line empty deps() head as arity 0 (issue #51)", function()
		local deps = parser.parse_lines({
			"defp deps(",
			") do",
			'  [{:only_dep, "~> 1.0"}]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("only_dep", deps[1].name)
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
