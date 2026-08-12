-- Treesitter parsing path against real Neovim. Falls back to skip when the
-- elixir parser is not installed (the pure pattern parser is covered in spec/).
local parser = require("hex-outdated.parser")

describe("parser fallback", function()
	it("scopes parsing to the configured dependency function and records aliases", function()
		local deps = parser.parse_lines({
			"def project do",
			'  [deps: project_deps(), example: {:not_a_dep, "1.0.0"}]',
			"end",
			"defp project_deps do",
			'  # {:commented, "~> 1.0"}',
			'  [{:local_app, "~> 2.0", hex: :actual_package}]',
			"end",
		})

		eq(1, #deps)
		eq("local_app", deps[1].name)
		eq("actual_package", deps[1].package)
	end)

	it("ignores non-dep tuples in assignment context (issue #25)", function()
		local deps = parser.parse_lines({
			"defp deps do",
			'  metadata = {:ok, "not-a-dep"}',
			'  [{:jason, "~> 1.0"}]',
			"end",
		})
		eq(1, #deps)
		eq("jason", deps[1].name)
	end)

	it("selects deps/0 when deps/1 appears first (issue #27)", function()
		local deps = parser.parse_lines({
			"defp deps(env) do",
			'  [{:wrong, "~> 1.0"}]',
			"end",
			"defp deps do",
			'  [{:correct, "~> 2.0"}]',
			"end",
		})
		eq(1, #deps)
		eq("correct", deps[1].name)
	end)

	it("ignores a tuple inside an assignment-context list (issue #25)", function()
		local deps = parser.parse_lines({
			"defp deps do",
			'  statuses = [{:ok, "not-a-dep"}]',
			'  [{:jason, "~> 1.0"}]',
			"end",
		})
		eq(1, #deps)
		eq("jason", deps[1].name)
	end)

	it("treats deps() with explicit empty parens as arity 0 (issue #27)", function()
		local deps = parser.parse_lines({
			'defp deps(), do: [{:jason, "~> 1.0"}]',
		})
		eq(1, #deps)
		eq("jason", deps[1].name)
	end)

	it("parses a dep list assigned to a returned variable (issue #30)", function()
		local deps = parser.parse_lines({
			"defp deps do",
			"  deps = [",
			'    {:jason, "~> 1.0"}',
			"  ]",
			"  deps",
			"end",
		})
		eq(1, #deps)
		eq("jason", deps[1].name)
		eq("~> 1.0", deps[1].requirement)
	end)

	it("excludes an assignment list that is not the returned variable (issue #30)", function()
		local deps = parser.parse_lines({
			"defp deps do",
			'  statuses = [{:ok, "not-a-dep"}]',
			'  deps = [{:jason, "~> 1.0"}]',
			"  deps",
			"end",
		})
		eq(1, #deps)
		eq("jason", deps[1].name)
	end)

	it("excludes a nested list inside a multi-line assignment (issue #31)", function()
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
		eq(1, #deps)
		eq("jason", deps[1].name)
		eq("~> 1.0", deps[1].requirement)
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
		eq(1, #deps)
		eq("jason", deps[1].name)
		eq("~> 1.0", deps[1].requirement)
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
		eq(1, #deps)
		eq("jason", deps[1].name)
		eq("~> 1.0", deps[1].requirement)
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
		eq(1, #deps)
		eq("correct", deps[1].name)
	end)

	it("treats a multi-line empty deps() head as arity 0 (issue #51)", function()
		local deps = parser.parse_lines({
			"defp deps(",
			") do",
			'  [{:only_dep, "~> 1.0"}]',
			"end",
		})
		eq(1, #deps)
		eq("only_dep", deps[1].name)
	end)

	-- `locate_project` (added by #61) carried the identical whole-line-close
	-- asymmetry the other two sites had: its close test was also the
	-- `^%s*end%s*$` whole-line match. Here `project/0`'s body over-extended
	-- past its own `end)`, swallowing `defp other`, whose `deps:
	-- other_deps()` then hijacked `configured_dep_function`'s narrowed
	-- search window -- even though `project/0` has no `deps:` key of its own
	-- and the correct dep function is the default `deps/0`.
	--
	-- This is fallback-only rather than a treesitter/fallback parity case:
	-- `locate_project` is a fallback-parser-only function (`parse_treesitter`
	-- never calls it), and this exact input also happens to trip an
	-- unrelated, pre-existing scoping gap in `parse_treesitter`'s own
	-- `configured_dep_function(lines)` call (it searches the whole file for
	-- `deps: name()` text with no first/last narrowing, unlike the fallback's
	-- call), so treesitter independently returns "wrong" for reasons
	-- unconnected to any of #63's three call sites. See the report to the
	-- issue author.
	it("does not let 'end)' desync locate_project's body range (issue #63)", function()
		local deps = parser.parse_lines({
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
		eq(1, #deps)
		eq("real", deps[1].name)
	end)
end)

local MIX = {
	"defmodule App.MixProject do",
	"  def project do",
	'    [deps: project_deps(), example: {:not_a_dep, "1.0.0"}]',
	"  end",
	"  defp project_deps do",
	"    [",
	'      {:jason, "~> 1.0"},',
	'      {:phoenix, "~> 1.8", only: :prod},',
	'      {:local_app, "~> 2.0", hex: :actual_package},',
	'      {:local_dep, path: "../local_dep"},',
	'      {:from_git, github: "owner/repo"},',
	"    ]",
	"  end",
	"end",
}

describe("parser (treesitter)", function()
	-- `language.add` returns nil (not an error) when the parser is missing, so a
	-- bare pcall is not enough — require a truthy return before exercising the path.
	local added_ok, added = pcall(vim.treesitter.language.add, "elixir")
	if not (added_ok and added) then
		it("treesitter elixir path", function()
			skip("elixir parser not installed")
		end)
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, MIX)
	vim.bo[buf].filetype = "elixir"
	local deps = parser.parse_buffer(buf)

	local by_name = {}
	for _, d in ipairs(deps) do
		by_name[d.name] = d
	end

	it("finds hex deps with string requirements", function()
		truthy(by_name.jason, "jason found")
		truthy(by_name.phoenix, "phoenix found")
		eq("~> 1.0", by_name.jason.requirement)
		eq("~> 1.8", by_name.phoenix.requirement)
	end)

	it("skips unrelated, path, and git tuples", function()
		is_nil(by_name.not_a_dep, "tuple outside the configured deps function skipped")
		is_nil(by_name.local_dep, "path dep skipped")
		is_nil(by_name.from_git, "github dep skipped")
	end)

	it("records the effective Hex package for aliased dependencies", function()
		truthy(by_name.local_app, "aliased dependency found")
		eq("actual_package", by_name.local_app.package)
	end)

	it("reports the requirement span inside the quotes", function()
		local d = by_name.jason
		eq(6, d.row, "0-indexed row of the jason line")
		-- col_start sits just inside the opening quote; the slice is the requirement.
		local line = MIX[d.row + 1]
		eq("~> 1.0", line:sub(d.col_start + 1, d.col_end))
	end)

	it("ignores assignment-context tuples inside deps function (issue #25)", function()
		local mix_nondep = {
			"defmodule App.MixProject do",
			"  defp deps do",
			'    metadata = {:ok, "not-a-dep"}',
			'    [{:jason, "~> 1.0"}]',
			"  end",
			"end",
		}
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_nondep)
		vim.bo[b].filetype = "elixir"
		local result = parser.parse_buffer(b)
		eq(1, #result)
		eq("jason", result[1].name)
	end)

	it("selects deps/0 when deps/1 appears first (issue #27)", function()
		local mix_arity = {
			"defmodule App.MixProject do",
			"  defp deps(env) do",
			'    [{:wrong, "~> 1.0"}]',
			"  end",
			"  defp deps do",
			'    [{:correct, "~> 2.0"}]',
			"  end",
			"end",
		}
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_arity)
		vim.bo[b].filetype = "elixir"
		local result = parser.parse_buffer(b)
		eq(1, #result)
		eq("correct", result[1].name)
	end)

	it("ignores a tuple inside an assignment-context list (issue #25)", function()
		local mix_assign = {
			"defmodule App.MixProject do",
			"  defp deps do",
			'    statuses = [{:ok, "not-a-dep"}]',
			'    [{:jason, "~> 1.0"}]',
			"  end",
			"end",
		}
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_assign)
		vim.bo[b].filetype = "elixir"
		local result = parser.parse_buffer(b)
		eq(1, #result)
		eq("jason", result[1].name)
	end)

	it("treats deps() with explicit empty parens as arity 0 (issue #27)", function()
		local mix_empty_parens = {
			"defmodule App.MixProject do",
			'  defp deps(), do: [{:jason, "~> 1.0"}]',
			"end",
		}
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_empty_parens)
		vim.bo[b].filetype = "elixir"
		local result = parser.parse_buffer(b)
		eq(1, #result)
		eq("jason", result[1].name)
	end)

	it("parses a dep list assigned to a returned variable (issue #30)", function()
		local mix_returned_var = {
			"defmodule App.MixProject do",
			"  defp deps do",
			"    deps = [",
			'      {:jason, "~> 1.0"}',
			"    ]",
			"    deps",
			"  end",
			"end",
		}
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_returned_var)
		vim.bo[b].filetype = "elixir"
		local result = parser.parse_buffer(b)
		eq(1, #result)
		eq("jason", result[1].name)
		eq("~> 1.0", result[1].requirement)
	end)

	it("excludes a nested list inside a multi-line assignment (issue #31)", function()
		local mix_nested_assign = {
			"defmodule App.MixProject do",
			"  defp deps do",
			"    metadata =",
			"      if true do",
			'        [{:ok, "not-a-dep"}]',
			"      end",
			"",
			'    [{:jason, "~> 1.0"}]',
			"  end",
			"end",
		}
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_nested_assign)
		vim.bo[b].filetype = "elixir"
		local result = parser.parse_buffer(b)
		eq(1, #result)
		eq("jason", result[1].name)
		eq("~> 1.0", result[1].requirement)
	end)

	it("finds deps inlined directly in project() with no deps/0 function (issue #42)", function()
		local mix_inline_deps = {
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
		}
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_inline_deps)
		vim.bo[b].filetype = "elixir"
		local result = parser.parse_buffer(b)
		eq(2, #result)
		eq("jason", result[1].name)
		eq("~> 1.4", result[1].requirement)
		eq("plug", result[2].name)
		eq("~> 1.15", result[2].requirement)
	end)

	it(
		"resolves a custom dependency function whose call wraps onto the next line (issue #55)",
		function()
			local mix_multiline_deps_value = {
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
			}
			local b = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_multiline_deps_value)
			vim.bo[b].filetype = "elixir"
			local result = parser.parse_buffer(b)
			eq(1, #result)
			eq("jason", result[1].name)
			eq("~> 1.4", result[1].requirement)
		end
	)

	it(
		"resolves an inline deps list wrapped onto the next line via the AST"
			.. " (issue #55, no custom-function match needed)",
		function()
			local mix_wrapped_inline_list = {
				"defmodule Demo.MixProject do",
				"  use Mix.Project",
				"  def project do",
				"    [",
				"      deps:",
				'      [{:jason, "~> 1.4"}]',
				"    ]",
				"  end",
				"end",
			}
			local b = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_wrapped_inline_list)
			vim.bo[b].filetype = "elixir"
			local result = parser.parse_buffer(b)
			eq(1, #result)
			eq("jason", result[1].name)
		end
	)

	it("resolves a one-line project/0 with an inline deps list (issue #61)", function()
		local mix_one_line_inline = {
			"defmodule Demo.MixProject do",
			'  def project, do: [deps: [{:real, "~> 1.0"}]]',
			"end",
		}
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_one_line_inline)
		vim.bo[b].filetype = "elixir"
		local result = parser.parse_buffer(b)
		eq(1, #result)
		eq("real", result[1].name)
		eq("~> 1.0", result[1].requirement)
	end)

	it("resolves a one-line project/0 delegating to a dep function (issue #61)", function()
		local mix_one_line_delegating = {
			"defmodule Demo.MixProject do",
			"  def project, do: [deps: custom_deps()]",
			'  defp custom_deps, do: [{:real, "~> 2.0"}]',
			"end",
		}
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_one_line_delegating)
		vim.bo[b].filetype = "elixir"
		local result = parser.parse_buffer(b)
		eq(1, #result)
		eq("real", result[1].name)
		eq("~> 2.0", result[1].requirement)
	end)

	it("ignores a colliding dep function in a nested module (issue #61)", function()
		local mix_nested_module = {
			"defmodule Demo.MixProject do",
			"  defmodule Inner do",
			'    def deps, do: [{:wrong, "~> 1.0"}]',
			"  end",
			"  def project do",
			"    [deps: deps()]",
			"  end",
			"  defp deps do",
			'    [{:real, "~> 2.0"}]',
			"  end",
			"end",
		}
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_nested_module)
		vim.bo[b].filetype = "elixir"
		local result = parser.parse_buffer(b)
		eq(1, #result)
		eq("real", result[1].name)
	end)

	it(
		"does not let a sibling function's 'deps:' fragment redirect the dep-function guess (issue #65)",
		function()
			local mix_sibling_deps_fragment = {
				"defmodule Demo.MixProject do",
				"  def project do",
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
			}
			local b = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_sibling_deps_fragment)
			vim.bo[b].filetype = "elixir"
			local result = parser.parse_buffer(b)
			eq(1, #result)
			eq("real", result[1].name)
		end
	)

	it(
		"does not let a 'deps:' fragment in a @doc string / attribute redirect the guess (issue #65)",
		function()
			local mix_doc_string_fragment = {
				"defmodule Demo.MixProject do",
				'  @source_url "deps: fake()"',
				"",
				"  def project do",
				"    [app: :demo]",
				"  end",
				"",
				'  @doc "deps: fake()"',
				"  defp other, do: :ok",
				"",
				"  defp deps do",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"end",
			}
			local b = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(b, 0, -1, false, mix_doc_string_fragment)
			vim.bo[b].filetype = "elixir"
			local result = parser.parse_buffer(b)
			eq(1, #result)
			eq("real", result[1].name)
		end
	)
end)

-- Parity contract: the Treesitter path (parse_buffer) and the Lua-pattern fallback
-- (parse_lines) independently implement the same dependency-extraction rules —
-- arity-0 selection, assignment-RHS exclusion, alias resolution, and dep-list
-- scoping. They must agree on well-formed mix.exs input. These cases pin that
-- invariant so a rule added to one path cannot silently drift from the other.
-- (parse_lines is pure Lua, so it runs in this headless suite alongside real
-- Treesitter, letting us cross-check both parsers in one process.)
describe("parser parity: treesitter vs fallback", function()
	local added_ok, added = pcall(vim.treesitter.language.add, "elixir")
	if not (added_ok and added) then
		it("treesitter elixir path", function()
			skip("elixir parser not installed")
		end)
		return
	end

	-- Each case is a complete, valid mix.exs snippet exercising one shared rule.
	-- `expect`, when present, is the exact list of dep names both paths must
	-- return. Cases without it assert agreement only; a case whose bug makes both
	-- paths agree on the *wrong* answer (e.g. both returning nothing) must set it,
	-- or the parity assertion alone would pass vacuously.
	local CASES = {
		{
			desc = "hex deps with scm tuples skipped",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				"    [",
				'      {:phoenix, "~> 1.6"},',
				'      {:jason, "~> 1.4", only: :test},',
				'      {:my_dep, github: "owner/repo"},',
				"    ]",
				"  end",
				"end",
			},
		},
		{
			desc = "aliased package via custom deps function",
			lines = {
				"defmodule App.MixProject do",
				"  def project do",
				"    [deps: project_deps()]",
				"  end",
				"  defp project_deps do",
				'    [{:local_app, "~> 2.0", hex: :actual_package}]',
				"  end",
				"end",
			},
		},
		{
			desc = "assignment-RHS tuple excluded (issue #25)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				'    metadata = {:ok, "not-a-dep"}',
				'    [{:jason, "~> 1.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "assignment-RHS list excluded (issue #25)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				'    statuses = [{:ok, "not-a-dep"}]',
				'    [{:jason, "~> 1.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "deps/0 selected over deps/1 (issue #27)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps(env) do",
				'    [{:wrong, "~> 1.0"}]',
				"  end",
				"  defp deps do",
				'    [{:correct, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "dep list assigned to a returned variable (issue #30)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				"    deps = [",
				'      {:jason, "~> 1.0"}',
				"    ]",
				"    deps",
				"  end",
				"end",
			},
		},
		{
			desc = "assignment list excluded while returned variable kept (issue #30)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				'    statuses = [{:ok, "not-a-dep"}]',
				'    deps = [{:jason, "~> 1.0"}]',
				"    deps",
				"  end",
				"end",
			},
		},
		{
			desc = "nested list inside a multi-line assignment excluded (issue #31)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				"    metadata =",
				"      if true do",
				'        [{:ok, "not-a-dep"}]',
				"      end",
				"",
				'    [{:jason, "~> 1.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "dep requirement string wrapped to the next line (issue #41)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				"    [",
				'      {:short_dep, "~> 1.0"},',
				"      {:a_very_long_package_name_here,",
				'       "~> 2.3", only: [:dev, :test], runtime: false}',
				"    ]",
				"  end",
				"end",
			},
		},
		{
			desc = "dep list found after a flush-left nested block end (issue #47)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				"    if true do",
				"      ignored = :ok",
				"    end",
				'    [{:jason, "~> 1.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "deps/0 selected over a multi-line deps/1 (issue #51)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps(",
				"    env",
				"  ) do",
				'    [{:wrong, "~> 1.0"}]',
				"  end",
				"  defp deps do",
				'    [{:correct, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "multi-line empty deps() head treated as arity 0 (issue #51)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps(",
				"  ) do",
				'    [{:only_dep, "~> 1.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "deps inlined directly in project() with no deps/0 function (issue #42)",
			lines = {
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
			},
		},
		{
			desc = "custom dependency function call wraps onto the next line (issue #55)",
			lines = {
				"defmodule App.MixProject do",
				"  def project do",
				"    [deps:",
				"      project_deps()]",
				"  end",
				"  defp project_deps do",
				'    [{:jason, "~> 1.4"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "'do' inside a string requirement not treated as a block opener (issue #57)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				'    [{:real, "== 1.0.0-do"}]',
				"  end",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "'fn' inside a string requirement not treated as a block opener (issue #57)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				'    [{:real, "== 1.0.0-fn"}]',
				"  end",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "':do' option atom not treated as a block opener (issue #57)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				'    [{:real, "~> 1.0", only: :do}]',
				"  end",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "':fn' option atom not treated as a block opener (issue #57)",
			lines = {
				"defmodule App.MixProject do",
				"  defp deps do",
				'    [{:real, "~> 1.0", only: :fn}]',
				"  end",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "colliding deps/0 in an earlier module ignored (issue #61, repro A)",
			expect = { "real" },
			lines = {
				"defmodule Helper do",
				'  def deps, do: [{:wrong, "~> 1.0"}]',
				"end",
				"",
				"defmodule Demo.MixProject do",
				"  def project, do: [deps: deps()]",
				'  defp deps, do: [{:real, "~> 2.0"}]',
				"end",
			},
		},
		{
			desc = "colliding deps/0 in a later module ignored (issue #61)",
			expect = { "real" },
			lines = {
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
			},
		},
		{
			desc = "colliding deps/0 in a nested module ignored (issue #61)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  defmodule Inner do",
				'    def deps, do: [{:wrong, "~> 1.0"}]',
				"  end",
				"  def project do",
				"    [deps: deps()]",
				"  end",
				"  defp deps do",
				'    [{:real, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "'deps: name()' text inside a string literal ignored (issue #61, repro B)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				'  @doc "example deps: fake()"',
				"  def project, do: [deps: deps()]",
				'  defp deps, do: [{:real, "~> 2.0"}]',
				"end",
			},
		},
		{
			desc = "one-line project/0 with an inline deps list (issue #61, repro C)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				'  def project, do: [deps: [{:real, "~> 1.0"}]]',
				"end",
			},
		},
		{
			desc = "one-line project/0 delegating to a custom dep function (issue #61)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project, do: [deps: custom_deps()]",
				'  defp custom_deps, do: [{:real, "~> 2.0"}]',
				"end",
			},
		},
		{
			desc = "inline deps list in another module ignored (issue #61)",
			expect = { "real" },
			lines = {
				"defmodule Helper do",
				'  def config, do: [deps: [{:wrong, "~> 1.0"}]]',
				"end",
				"",
				"defmodule Demo.MixProject do",
				'  def project, do: [deps: [{:real, "~> 2.0"}]]',
				"end",
			},
		},
		{
			-- Criterion: a file with no locatable project/0 must keep resolving via
			-- the whole-file dep-function search rather than returning nothing.
			desc = "dep function found with no project/0 in the file (issue #61)",
			expect = { "jason" },
			lines = {
				"defmodule App.MixProject do",
				"  def config do",
				"    [deps: project_deps()]",
				"  end",
				"  defp project_deps do",
				'    [{:jason, "~> 1.4"}]',
				"  end",
				"end",
			},
		},
		{
			-- The Treesitter path's whole-file text guess for the dep-function name
			-- (used when project/0's returned list has no resolvable `deps:` key)
			-- must be scoped to project/0's own body, exactly like the fallback path
			-- already is. Before the fix, this fragment inside a sibling function's
			-- own `deps:` pair hijacked the guess and both paths disagreed.
			desc = "sibling function's 'deps:' fragment does not redirect the guess (issue #65)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project do",
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
			},
		},
		{
			desc = "'deps:' fragment in a @doc string does not redirect the guess (issue #65)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project do",
				"    [app: :demo]",
				"  end",
				"",
				'  @doc "deps: fake()"',
				"  defp other, do: :ok",
				"",
				"  defp deps do",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "'deps:' fragment in a module attribute does not redirect the guess (issue #65)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				'  @source_url "deps: fake()"',
				"",
				"  def project do",
				"    [app: :demo]",
				"  end",
				"",
				"  defp deps do",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"end",
			},
		},
		{
			-- `_` is not in Lua's `%w` class, so the old `%f[%w]do%f[%W]` frontier
			-- fired across it: an atom value merely *containing* `_fn` (here
			-- `only: :my_fn`) was miscounted as an `fn` block opener, `block_depth`
			-- never returned to zero, and `unrelated`'s tuple leaked in.
			desc = "atom value ending in '_fn' not treated as a block opener (issue #58, repro A)",
			expect = { "real" },
			lines = {
				"defmodule A.MixProject do",
				"  defp deps do",
				'    [{:real, "~> 1.0", only: :my_fn}]',
				"  end",
				"",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "bare identifier ending in '_do' not treated as a block opener (issue #58, repro B)",
			expect = { "real" },
			lines = {
				"defmodule A.MixProject do",
				"  defp deps do",
				"    x = fetch_do",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			-- Prefix form: the closing frontier `%f[%W]` fired on the trailing `_`
			-- just as the opening one fired on a leading `_`, so `do_`-prefixed
			-- identifiers (a common recursive-helper naming convention in Elixir)
			-- reproduced identically to the suffix forms above.
			desc = "identifier starting with 'do_' not treated as a block opener (issue #58, repro C)",
			expect = { "real" },
			lines = {
				"defmodule A.MixProject do",
				"  defp deps do",
				"    x = do_thing(1)",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			-- #61's `count_closers` scans for `end` with the identical `_`-boundary
			-- bug: `end_of_list` was miscounted as a block closer, popping the
			-- `defmodule` entry in `module_ranges` early so `module_scope` truncated
			-- before `deps/0`, which then fell outside the scope `configured_dep_function`
			-- and the head matcher are restricted to.
			desc = "identifier containing 'end_' not treated as a block closer (issue #58)",
			expect = { "real" },
			lines = {
				"defmodule A.MixProject do",
				"  def project do",
				"    x = end_of_list",
				"    [deps: deps()]",
				"  end",
				"",
				"  defp deps do",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"end",
			},
		},
		{
			-- Genuine block openers named in the issue's acceptance criteria must
			-- still count once the frontier is underscore-aware: each pairs a
			-- keyword-adjacent `do`/`fn` with a bare `end` on its own line, so the
			-- fallback's block-depth accounting must stay balanced through all of
			-- them and still reach the trailing dep list.
			desc = "genuine if/case/cond/with/receive/try/for/fn block openers still counted (issue #58)",
			expect = { "real" },
			lines = {
				"defmodule A.MixProject do",
				"  defp deps do",
				"    if Mix.env() == :test do",
				"      :ok",
				"    end",
				"",
				"    case Mix.env() do",
				"      :test -> :ok",
				"      _ -> :ok",
				"    end",
				"",
				"    cond do",
				"      true -> :ok",
				"    end",
				"",
				"    with {:ok, _} <- {:ok, 1} do",
				"      :ok",
				"    end",
				"",
				"    receive do",
				"      _ -> :ok",
				"    after",
				"      0 -> :ok",
				"    end",
				"",
				"    try do",
				"      :ok",
				"    rescue",
				"      _ -> :ok",
				"    end",
				"",
				"    for _ <- [1, 2] do",
				"      :ok",
				"    end",
				"",
				"    fn ->",
				"      :ok",
				"    end",
				"",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"end",
			},
		},
		{
			-- The issue's own reproduction: a nested anonymous function passed to a
			-- call closes as `end)`, which the old whole-line `^%s*end%s*$` close
			-- test never recognized. The opener stayed on the books, so the dep
			-- function's own closing `end` merely decremented a phantom depth
			-- instead of ending the scan, and extraction leaked into `unrelated`.
			desc = "nested 'fn ... end)' inside the dep function body balances (issue #63)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  defp deps do",
				"    _ = Enum.map([], fn x ->",
				"      x",
				"    end)",
				"",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			-- A closer followed by a delimiter other than `)`: an `if ... do` block
			-- as a list element, closed by `end,` ahead of the next element. The old
			-- whole-line close test missed this exactly as it missed `end)`.
			desc = "closer followed by a delimiter ('end,') balances (issue #63)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  defp deps do",
				"    _ = [",
				"      if Mix.env() == :test do",
				"        :ok",
				"      end,",
				"      :ready",
				"    ]",
				"",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			-- Same-line opener/closer form, net-neutral: `fn x -> x end` opens and
			-- closes on one line inside a call. The old scheme counted the opener
			-- (anywhere-on-line) but never the closer (whole-line only), so the net
			-- effect was a phantom +1 instead of the correct 0.
			desc = "same-line 'fn x -> x end' inside a call is net-neutral (issue #63)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  defp deps do",
				"    _ = Enum.map([], fn x -> x end)",
				"",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			-- Same-line opener/closer form inside a keyword list: `fn -> :ok end`
			-- as a keyword value, followed by a sibling key on the same line. As
			-- with the call form above, this must be net-neutral.
			desc = "keyword list with inline 'fn -> ... end' is net-neutral (issue #63)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  defp deps do",
				"    opts = [callback: fn -> :ok end, timeout: 5]",
				"    _ = opts",
				"",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
		{
			-- Multiple closers on one line: two nested anonymous functions closing
			-- back to back (`end) end)`). Both must be counted, not just one.
			desc = "multiple closers on one line are all counted (issue #63)",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  defp deps do",
				"    _ = Enum.map([[1]], fn a -> Enum.map(a, fn b -> b end) end)",
				"",
				'    [{:real, "~> 1.0"}]',
				"  end",
				"",
				"  defp unrelated do",
				'    [{:wrong, "~> 2.0"}]',
				"  end",
				"end",
			},
		},
	}

	-- Project a dep list to the fields both parsers populate, so a deep-compare is
	-- not tripped by incidental field differences.
	local function shape(deps)
		local out = {}
		for i, d in ipairs(deps) do
			out[i] = {
				name = d.name,
				requirement = d.requirement,
				package = d.package,
				row = d.row,
				col_start = d.col_start,
				col_end = d.col_end,
			}
		end
		return out
	end

	local function names(shaped)
		local out = {}
		for i, d in ipairs(shaped) do
			out[i] = d.name
		end
		return out
	end

	for _, case in ipairs(CASES) do
		it("agrees on " .. case.desc, function()
			local b = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(b, 0, -1, false, case.lines)
			vim.bo[b].filetype = "elixir"
			local ts = shape(parser.parse_buffer(b))
			local fallback = shape(parser.parse_lines(case.lines))
			eq(ts, fallback, "treesitter vs fallback for: " .. case.desc)
			if case.expect then
				eq(case.expect, names(ts), "treesitter dep names for: " .. case.desc)
				eq(case.expect, names(fallback), "fallback dep names for: " .. case.desc)
			end
		end)
	end
end)
