local fallback = require("hex-outdated.parser.fallback")

describe("parser.fallback.parse_lines", function()
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
		local deps = fallback.parse_lines(lines)
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
		local deps = fallback.parse_lines(lines)
		assert.are.equal("jason", deps[2].name)
		assert.are.equal("~> 1.4", deps[2].requirement)
		local line = lines[deps[2].row + 1]
		assert.are.equal("~> 1.4", line:sub(deps[2].col_start + 1, deps[2].col_end))
	end)

	it("skips scm deps with no positional version string", function()
		local deps = fallback.parse_lines(lines)
		for _, d in ipairs(deps) do
			assert.are_not.equal("my_dep", d.name)
		end
	end)

	it("ignores commented and unrelated tuples", function()
		local deps = fallback.parse_lines({
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
		local deps = fallback.parse_lines({
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
		local deps = fallback.parse_lines({
			'defp deps, do: [{:real_dep, "~> 2.0"}]',
			'example = {:not_a_dep, "1.0.0"}',
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real_dep", deps[1].name)
	end)

	it("parses every dependency in a compact one-line declaration", function()
		local deps = fallback.parse_lines({
			'defp deps, do: [{:jason, "~> 1.4"}, {:plug, "~> 1.15"}]',
		})

		assert.are.equal(2, #deps)
		assert.are.equal("jason", deps[1].name)
		assert.are.equal("~> 1.4", deps[1].requirement)
		assert.are.equal("plug", deps[2].name)
		assert.are.equal("~> 1.15", deps[2].requirement)
	end)

	it("scopes hex alias extraction to each tuple in a multi-dep line", function()
		local deps = fallback.parse_lines({
			'defp deps, do: [{:dep_a, "~> 1.0"}, {:dep_b, "~> 2.0", hex: :actual_b}]',
		})

		assert.are.equal(2, #deps)
		assert.is_nil(deps[1].package)
		assert.are.equal("actual_b", deps[2].package)
	end)

	it("finds a dep whose requirement string wraps to the next line", function()
		local wrapped_lines = {
			"defp deps do",
			"  [",
			'    {:short_dep, "~> 1.0"},',
			"    {:a_very_long_package_name_here,",
			'     "~> 2.3", only: [:dev, :test], runtime: false}',
			"  ]",
			"end",
		}
		local deps = fallback.parse_lines(wrapped_lines)
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

	it("recognizes 'do:' on the line after a zero-arity 'name(),' head", function()
		local deps = fallback.parse_lines({
			"defp deps(),",
			'  do: [{:jason, "~> 1.4"}]',
			"",
			"defp unrelated,",
			'  do: [{:poison, "~> 5.0"}]',
		})

		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("recognizes 'do:' on the line after a zero-arity 'name,' head", function()
		local deps = fallback.parse_lines({
			"defp deps,",
			'  do: [{:jason, "~> 1.4"}]',
			"",
			"defp unrelated,",
			'  do: [{:poison, "~> 5.0"}]',
		})

		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("stops at a wrapped keyword-form body, excluding a later function", function()
		local deps = fallback.parse_lines({
			"def project, do: [deps: deps()]",
			"",
			"defp deps(),",
			'  do: [{:jason, "~> 1.4"}]',
			"",
			"defp unrelated,",
			'  do: [{:poison, "~> 5.0"}]',
		})

		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("keeps a nonzero-arity wrapped head excluded with a trailing comma", function()
		local deps = fallback.parse_lines({
			"defp deps(x),",
			'  do: [{:wrong, "~> 1.0"}]',
		})

		assert.are.equal(0, #deps)
	end)

	it("keeps a wrapped nonzero-arity multi-line head excluded", function()
		local deps = fallback.parse_lines({
			"defp deps(",
			"  x",
			"),",
			'  do: [{:wrong, "~> 1.0"}]',
		})

		assert.are.equal(0, #deps)
	end)

	it("resolves 'do:' after a wrapped empty-parens multi-line signature", function()
		local deps = fallback.parse_lines({
			"defp deps(",
			"),",
			'  do: [{:jason, "~> 1.4"}]',
			"",
			"defp unrelated,",
			'  do: [{:poison, "~> 5.0"}]',
		})

		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("excludes nested list literals inside a multi-line assignment", function()
		local deps = fallback.parse_lines({
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

	it("finds the dep list after a flush-left nested block end", function()
		local deps = fallback.parse_lines({
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

	it("resumes dep-scanning after deeply nested flush-left blocks", function()
		local deps = fallback.parse_lines({
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

	it("selects deps/0 when a multi-line deps/1 appears first", function()
		local deps = fallback.parse_lines({
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

	it("finds deps inlined directly in project() with no deps/0 function", function()
		local deps = fallback.parse_lines({
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

	it("treats a multi-line empty deps() head as arity 0", function()
		local deps = fallback.parse_lines({
			"defp deps(",
			") do",
			'  [{:only_dep, "~> 1.0"}]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("only_dep", deps[1].name)
	end)

	it("resolves a custom dependency function whose call wraps onto the next line", function()
		local deps = fallback.parse_lines({
			"defmodule My.MixProject do",
			"  use Mix.Project",
			"  def project do",
			"    [deps:",
			"      project_deps()]",
			"  end",
			"  defp project_deps do",
			'    [{:jason, "~> 1.4"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
		assert.are.equal("~> 1.4", deps[1].requirement)
	end)

	it("resolves an inline deps list wrapped onto the next line, not a deps/0 function", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  use Mix.Project",
			"  def project do",
			"    [",
			"      deps:",
			'      [{:jason, "~> 1.4"}]',
			"    ]",
			"  end",
			'  defp deps, do: [{:wrong, "~> 1.0"}]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("does not mistake a nonzero-arity call for the dependency function", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  def project do",
			"    [deps: filter_deps(:prod)]",
			"  end",
			"  defp filter_deps(_env) do",
			'    [{:jason, "~> 1.4"}]',
			"  end",
			"end",
		})

		assert.are.equal(0, #deps)
	end)

	it("does not treat a 'do' inside a string requirement as a block opener", function()
		local deps = fallback.parse_lines({
			"defmodule A.MixProject do",
			"  defp deps do",
			'    [{:real, "== 1.0.0-do"}]',
			"  end",
			"  defp unrelated do",
			'    [{:wrong, "~> 2.0"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("does not treat a 'fn' inside a string requirement as a block opener", function()
		local deps = fallback.parse_lines({
			"defmodule A.MixProject do",
			"  defp deps do",
			'    [{:real, "== 1.0.0-fn"}]',
			"  end",
			"  defp unrelated do",
			'    [{:wrong, "~> 2.0"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("does not treat a ':do' option atom as a block opener", function()
		local deps = fallback.parse_lines({
			"defmodule A.MixProject do",
			"  defp deps do",
			'    [{:real, "~> 1.0", only: :do}]',
			"  end",
			"  defp unrelated do",
			'    [{:wrong, "~> 2.0"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("does not treat a ':fn' option atom as a block opener", function()
		local deps = fallback.parse_lines({
			"defmodule A.MixProject do",
			"  defp deps do",
			'    [{:real, "~> 1.0", only: :fn}]',
			"  end",
			"  defp unrelated do",
			'    [{:wrong, "~> 2.0"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it(
		"does not leak past a nested if/do/else/end inside a real block, with an unrelated"
			.. " sibling function",
		function()
			local deps = fallback.parse_lines({
				"defmodule A.MixProject do",
				"  defp deps do",
				"    if Mix.env() == :test do",
				'      [{:real, "~> 1.0"}]',
				"    else",
				"      []",
				"    end",
				"  end",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			})

			assert.are.equal(1, #deps)
			assert.are.equal("real", deps[1].name)
		end
	)

	it("does not treat 'run_do:' as a block opener", function()
		local deps = fallback.parse_lines({
			"defmodule A.MixProject do",
			"  defp deps do",
			'    [{:real, "~> 1.0", run_do: true}]',
			"  end",
			"  defp unrelated do",
			'    [{:wrong, "~> 2.0"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("does not treat '_do_' as a block opener", function()
		local deps = fallback.parse_lines({
			"defmodule A.MixProject do",
			"  defp deps do",
			"    x = a_do_b",
			'    [{:real, "~> 1.0"}]',
			"  end",
			"  defp unrelated do",
			'    [{:wrong, "~> 2.0"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("does not treat '_fn_' as a block opener", function()
		local deps = fallback.parse_lines({
			"defmodule A.MixProject do",
			"  defp deps do",
			"    x = a_fn_b",
			'    [{:real, "~> 1.0"}]',
			"  end",
			"  defp unrelated do",
			'    [{:wrong, "~> 2.0"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("ignores a colliding dep function in an earlier module", function()
		local deps = fallback.parse_lines({
			"defmodule Helper do",
			'  def deps, do: [{:wrong, "~> 1.0"}]',
			"end",
			"",
			"defmodule Demo.MixProject do",
			"  def project, do: [deps: deps()]",
			'  defp deps, do: [{:real, "~> 2.0"}]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
		assert.are.equal("~> 2.0", deps[1].requirement)
	end)

	it("ignores a colliding dep function in a later module", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  def project do",
			"    [deps: deps()]",
			"  end",
			"  defp deps do",
			'    [{:real, "~> 2.0"}]',
			"  end",
			"end",
			"",
			"defmodule Helper do",
			"  def deps do",
			'    [{:wrong, "~> 1.0"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("ignores a colliding dep function in a nested module", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  defmodule Inner do",
			"    def deps do",
			'      [{:wrong, "~> 1.0"}]',
			"    end",
			"  end",
			"  def project do",
			"    [deps: deps()]",
			"  end",
			"  defp deps do",
			'    [{:real, "~> 2.0"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("ignores a 'deps: name()' fragment inside a string literal", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			'  @doc "example deps: fake()"',
			"  def project, do: [deps: deps()]",
			'  defp deps, do: [{:real, "~> 2.0"}]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("ignores a 'deps: name()' fragment in a sibling function's string", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  def project do",
			"    [deps: project_deps()]",
			"  end",
			"  defp docs do",
			'    [note: "configure with deps: fake()"]',
			"  end",
			"  defp project_deps do",
			'    [{:real, "~> 2.0"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("ignores an inline deps list in another module", function()
		local deps = fallback.parse_lines({
			"defmodule Helper do",
			'  def config, do: [deps: [{:wrong, "~> 1.0"}]]',
			"end",
			"",
			"defmodule Demo.MixProject do",
			'  def project, do: [deps: [{:real, "~> 2.0"}]]',
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("keeps a returned-variable dep list scoped to project's module", function()
		local deps = fallback.parse_lines({
			"defmodule Helper do",
			"  def deps do",
			"    deps = [",
			'      {:wrong, "~> 1.0"}',
			"    ]",
			"    deps",
			"  end",
			"end",
			"",
			"defmodule Demo.MixProject do",
			"  def project do",
			"    [deps: deps()]",
			"  end",
			"  defp deps do",
			"    deps = [",
			'      {:real, "~> 2.0"}',
			"    ]",
			"    deps",
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("still resolves the dep function by whole-file search with no project/0", function()
		local deps = fallback.parse_lines({
			"defmodule App.MixProject do",
			"  def config do",
			"    [deps: project_deps()]",
			"  end",
			"  defp project_deps do",
			'    [{:jason, "~> 1.4"}]',
			"  end",
			"end",
		})

		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("does not treat 'end_of_list' as a block closer", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			"  end_of_list = :marker",
			"  _ = end_of_list",
			"",
			'  [{:real, "~> 1.0"}]',
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("does not treat 'the_end' as a block closer", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			"  the_end = true",
			"  _ = the_end",
			"",
			'  [{:real, "~> 1.0"}]',
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("does not treat a bare ':end' atom as a block closer", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			"  status = :end",
			"  _ = status",
			"",
			'  [{:real, "~> 1.0"}]',
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("does not treat an 'end:' keyword-list key as a block closer", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			"  opts = [end: 1]",
			"  _ = opts",
			"",
			'  [{:real, "~> 1.0"}]',
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("balances a nested 'fn ... end)' before the returned variable", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			"  deps = [",
			'    {:real, "~> 1.0"}',
			"  ]",
			"",
			"  _ = Enum.map([], fn x ->",
			"    x",
			"  end)",
			"",
			"  deps",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("does not open heredoc mode for a single-line triple-quoted string", function()
		local deps = fallback.parse_lines({
			"defmodule A.MixProject do",
			"  defp deps do",
			'    _doc = """a"""',
			'    [{:real, "~> 1.0"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("treats a '\\'\\'\\'' charlist heredoc body as inert", function()
		local deps = fallback.parse_lines({
			"defmodule A.MixProject do",
			"  defp deps do",
			"    _doc = '''",
			"    case x do",
			"    '''",
			'    [{:real, "~> 1.0"}]',
			"  end",
			"",
			"  defp unrelated do",
			'    [{:wrong, "~> 2.0"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it('treats a \'~s"""\' sigil-prefixed heredoc opener as a heredoc', function()
		local deps = fallback.parse_lines({
			"defmodule A.MixProject do",
			"  defp deps do",
			'    _doc = ~s"""',
			"    case x do",
			'    """',
			'    [{:real, "~> 1.0"}]',
			"  end",
			"",
			"  defp unrelated do",
			'    [{:wrong, "~> 2.0"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it('treats a \'~S"""\' sigil-prefixed heredoc opener as a heredoc', function()
		local deps = fallback.parse_lines({
			"defmodule A.MixProject do",
			"  defp deps do",
			'    _doc = ~S"""',
			"    end",
			'    """',
			'    [{:real, "~> 1.0"}]',
			"  end",
			"",
			"  defp unrelated do",
			'    [{:wrong, "~> 2.0"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("does not let a heredoc body confuse the returned-variable scan", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			"  deps = [",
			'    {:jason, "~> 1.0"}',
			"  ]",
			'  _doc = """',
			"  case x do",
			'  """',
			"  deps",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("does not treat a charlist's 'do' as a block opener", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  def project, do: [deps: deps()]",
			"",
			"  defp deps do",
			"    marker = ['do']",
			'    [{:jason, "~> 1.4"}]',
			"  end",
			"",
			"  defp unrelated do",
			'    [{:poison, "~> 5.0"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("does not treat an inline sigil's 'do' as a block opener", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  def project, do: [deps: deps()]",
			"",
			"  defp deps do",
			"    marker = ~w(do)a",
			'    [{:jason, "~> 1.4"}]',
			"  end",
			"",
			"  defp unrelated do",
			'    [{:poison, "~> 5.0"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("does not treat a '#' inside a charlist as a comment starter", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			"  _ = '#'; [{:jason, \"~> 1.4\"}]",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("does not treat a '#' inside an inline sigil as a comment starter", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			'  _ = ~s(#); [{:jason, "~> 1.4"}]',
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("does not treat a stray '[' inside a charlist as real bracket syntax", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  def project, do: [deps: deps()]",
			"",
			"  defp deps do",
			"    x = '=['",
			'    [{:jason, "~> 1.4"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("does not treat a stray '[' inside an inline sigil as real bracket syntax", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  def project, do: [deps: deps()]",
			"",
			"  defp deps do",
			"    x = ~s(=[)",
			'    [{:jason, "~> 1.4"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("nests a paired sigil delimiter rather than closing at the first match", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  def project, do: [deps: deps()]",
			"",
			"  defp deps do",
			"    x = ~s(a (b) do c)",
			'    [{:jason, "~> 1.4"}]',
			"  end",
			"",
			"  defp unrelated do",
			'    [{:poison, "~> 5.0"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("respects backslash-escaping inside a charlist", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  def project, do: [deps: deps()]",
			"",
			"  defp deps do",
			"    x = 'abc\\'do'",
			'    [{:jason, "~> 1.4"}]',
			"  end",
			"",
			"  defp unrelated do",
			'    [{:poison, "~> 5.0"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("respects backslash-escaping inside a same-character sigil delimiter", function()
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  def project, do: [deps: deps()]",
			"",
			"  defp deps do",
			"    x = ~r/abc\\/end/",
			'    [{:jason, "~> 1.4"}]',
			"  end",
			"",
			"  defp unrelated do",
			'    [{:poison, "~> 5.0"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("ignores non-dep tuples in assignment context", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			'  metadata = {:ok, "not-a-dep"}',
			'  statuses = [{:ok, "not-a-dep"}]',
			'  [{:jason, "~> 1.0"}]',
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("selects deps/0 when deps/1 appears first", function()
		local deps = fallback.parse_lines({
			"defp deps(env) do",
			'  [{:wrong, "~> 1.0"}]',
			"end",
			"defp deps do",
			'  [{:correct, "~> 2.0"}]',
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("correct", deps[1].name)
	end)

	it("treats deps() with explicit empty parens as arity 0", function()
		local deps = fallback.parse_lines({
			'defp deps(), do: [{:jason, "~> 1.0"}]',
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("keeps the list assigned to the returned variable and excludes other assignments", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			'  statuses = [{:ok, "not-a-dep"}]',
			"  deps = [",
			'    {:jason, "~> 1.0"}',
			"  ]",
			"  deps",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
		assert.are.equal("~> 1.0", deps[1].requirement)
	end)

	it("bounds project/0's body at a decorated 'end)' closer", function()
		-- project/0 has no deps: key, so deps/0 is used; an over-long project
		-- range would pick up `other`'s `deps: other_deps()` instead.
		local deps = fallback.parse_lines({
			"defmodule Demo.MixProject do",
			"  def project do",
			"    _ = Enum.map([], fn x ->",
			"      x",
			"    end)",
			"",
			"    [app: :demo]",
			"  end",
			"",
			"  defp other, do: [deps: other_deps()]",
			"",
			"  defp deps do",
			'    [{:real, "~> 1.0"}]',
			"  end",
			"",
			"  defp other_deps do",
			'    [{:wrong, "~> 2.0"}]',
			"  end",
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("reads every tuple of a keyword-form body whose list spans lines", function()
		local deps = fallback.parse_lines({
			"defp deps, do: [",
			'  {:jason, "~> 1.4"},',
			'  {:plug, "~> 1.15"}',
			"]",
			'example = [{:not_a_dep, "1.0.0"}]',
		})
		assert.are.same({ "jason", "plug" }, { deps[1].name, deps[2].name })
		assert.are.equal(2, #deps)
	end)

	it("reads a wrapped keyword-form body whose list spans lines", function()
		local deps = fallback.parse_lines({
			"defp deps,",
			"  do: [",
			'    {:jason, "~> 1.4"},',
			'    {:plug, "~> 1.15"}',
			"  ]",
		})
		assert.are.same({ "jason", "plug" }, { deps[1].name, deps[2].name })
		assert.are.equal(2, #deps)
	end)

	it("records a hex alias given on a wrapped tuple line", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			"  [",
			'    {:my_plug, "~> 1.0",',
			"     hex: :plug},",
			'    {:jason, "~> 1.4"}',
			"  ]",
			"end",
		})
		assert.are.equal(2, #deps)
		assert.are.equal("plug", deps[1].package)
		assert.is_nil(deps[2].package)
	end)

	it("records no alias for option keys that merely end in 'hex'", function()
		local deps = fallback.parse_lines({
			'defp deps, do: [{:a, "~> 1.0", no_hex: :x}, {:b, "~> 1.0", xhex: :y}]',
		})
		assert.are.equal(2, #deps)
		assert.is_nil(deps[1].package)
		assert.is_nil(deps[2].package)
	end)

	it("finds a tuple whose name atom starts on the line after '{'", function()
		local source = {
			"defp deps do",
			"  [",
			"    {",
			'      :jason, "~> 1.4"}',
			"  ]",
			"end",
		}
		local deps = fallback.parse_lines(source)
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
		assert.are.equal(3, deps[1].row)
		assert.are.equal("~> 1.4", source[4]:sub(deps[1].col_start + 1, deps[1].col_end))
	end)

	it("accepts a quoted atom name", function()
		local deps = fallback.parse_lines({
			'defp deps, do: [{:"jason", "~> 1.4"}]',
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("skips a tuple whose second element is not the requirement", function()
		local deps = fallback.parse_lines({
			'defp deps, do: [{:a, :b, "x"}, {:jason, "~> 1.4", "extra"}]',
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
		assert.are.equal("~> 1.4", deps[1].requirement)
	end)

	it("ignores a dep-shaped tuple inside a string", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			'  [{:jason, "~> 1.4", note: "{:fake, \\"1.0\\"}"}]',
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("does not read a key ending in 'deps' as the deps: key", function()
		local deps = fallback.parse_lines({
			"def project do",
			"  [my_deps: other(), app: :demo]",
			"end",
			'defp other, do: [{:wrong, "~> 1.0"}]',
			'defp deps, do: [{:real, "~> 1.0"}]',
		})
		assert.are.equal(1, #deps)
		assert.are.equal("real", deps[1].name)
	end)

	it("does not treat '?#' or '?\"' char literals as a comment or string", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			'  _ = {?#, ?"}; [{:jason, "~> 1.4"}]',
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it("skips quotes nested in string interpolation", function()
		local deps = fallback.parse_lines({
			"defp deps do",
			'  _ = "a#{"#"}b"; [{:jason, "~> 1.4"}]',
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)

	it('does not open a heredoc on \'"""\' inside a charlist', function()
		local deps = fallback.parse_lines({
			"defp deps do",
			'  _ = \'a """',
			"  b'",
			'  [{:jason, "~> 1.4"}]',
			"end",
		})
		assert.are.equal(1, #deps)
		assert.are.equal("jason", deps[1].name)
	end)
end)
