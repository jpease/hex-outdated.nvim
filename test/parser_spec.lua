-- Tree-sitter backend and its parity with the line scanner, in real Neovim.
-- With HEX_OUTDATED_REQUIRE_TS=1 a missing elixir parser fails instead of skipping.
local parser = require("hex-outdated.parser")
local fallback = require("hex-outdated.parser.fallback")

-- True when the elixir parser is installed; otherwise registers a test that
-- skips, or fails when HEX_OUTDATED_REQUIRE_TS=1.
local function elixir_parser_available()
	-- `language.add` returns nil rather than erroring when the parser is missing.
	local ok, added = pcall(vim.treesitter.language.add, "elixir")
	if ok and added then
		return true
	end
	it("has the elixir Treesitter parser", function()
		if vim.env.HEX_OUTDATED_REQUIRE_TS == "1" then
			error("elixir parser not installed but HEX_OUTDATED_REQUIRE_TS=1")
		end
		skip("elixir parser not installed")
	end)
	return false
end

local function parse_buffer(lines)
	local b = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
	vim.bo[b].filetype = "elixir"
	return parser.parse_buffer(b)
end

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
	if not elixir_parser_available() then
		return
	end

	local by_name = {}
	for _, d in ipairs(parse_buffer(MIX)) do
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
		local line = MIX[d.row + 1]
		eq("~> 1.0", line:sub(d.col_start + 1, d.col_end))
	end)

	it("pairs a name only with the string directly after it", function()
		local result = parse_buffer({
			"defmodule App.MixProject do",
			'  defp deps, do: [{:a, :b, "x"}, {:jason, "~> 1.4", "extra"}]',
			"end",
		})
		eq(1, #result)
		eq("jason", result[1].name)
		eq("~> 1.4", result[1].requirement)
	end)
end)

-- Both backends must agree on well-formed mix.exs input.
describe("parser parity: treesitter vs fallback", function()
	if not elixir_parser_available() then
		return
	end

	-- `expect` is the exact dep name list both backends must return.
	local CASES = {
		{
			desc = "hex deps with scm tuples skipped",
			expect = { "phoenix", "jason" },
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
			expect = { "local_app" },
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
			desc = "assignment-RHS tuple excluded",
			expect = { "jason" },
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
			desc = "assignment-RHS list excluded",
			expect = { "jason" },
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
			desc = "deps/0 selected over deps/1",
			expect = { "correct" },
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
			desc = "dep list assigned to a returned variable",
			expect = { "jason" },
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
			desc = "assignment list excluded while returned variable kept",
			expect = { "jason" },
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
			desc = "nested list inside a multi-line assignment excluded",
			expect = { "jason" },
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
			desc = "dep requirement string wrapped to the next line",
			expect = { "short_dep", "a_very_long_package_name_here" },
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
			desc = "dep list found after a flush-left nested block end",
			expect = { "jason" },
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
			desc = "deps/0 selected over a multi-line deps/1",
			expect = { "correct" },
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
			desc = "multi-line empty deps() head treated as arity 0",
			expect = { "only_dep" },
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
			desc = "deps inlined directly in project() with no deps/0 function",
			expect = { "jason", "plug" },
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
			desc = "custom dependency function call wraps onto the next line",
			expect = { "jason" },
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
			desc = "'do' inside a string requirement not treated as a block opener",
			expect = { "real" },
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
			desc = "'fn' inside a string requirement not treated as a block opener",
			expect = { "real" },
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
			desc = "':do' option atom not treated as a block opener",
			expect = { "real" },
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
			desc = "':fn' option atom not treated as a block opener",
			expect = { "real" },
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
			desc = "colliding deps/0 in an earlier module ignored",
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
			desc = "colliding deps/0 in a later module ignored",
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
			desc = "colliding deps/0 in a nested module ignored",
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
			desc = "'deps: name()' text inside a string literal ignored",
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
			desc = "one-line project/0 with an inline deps list",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				'  def project, do: [deps: [{:real, "~> 1.0"}]]',
				"end",
			},
		},
		{
			desc = "one-line project/0 delegating to a custom dep function",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project, do: [deps: custom_deps()]",
				'  defp custom_deps, do: [{:real, "~> 2.0"}]',
				"end",
			},
		},
		{
			desc = "inline deps list in another module ignored",
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
			desc = "dep function found with no project/0 in the file",
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
			desc = "sibling function's 'deps:' fragment does not redirect the default",
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
			desc = "'deps:' fragment in a @doc string does not redirect the default",
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
			desc = "'deps:' fragment in a module attribute does not redirect the default",
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
			desc = "atom value ending in '_fn' not treated as a block opener",
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
			desc = "bare identifier ending in '_do' not treated as a block opener",
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
			desc = "identifier starting with 'do_' not treated as a block opener",
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
			desc = "identifier containing 'end_' not treated as a block closer",
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
			desc = "genuine if/case/cond/with/receive/try/for/fn block openers still counted",
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
			desc = "nested 'fn ... end)' inside the dep function body balances",
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
			desc = "closer followed by a delimiter ('end,') balances",
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
			desc = "same-line 'fn x -> x end' inside a call is net-neutral",
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
			desc = "keyword list with inline 'fn -> ... end' is net-neutral",
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
			desc = "multiple closers on one line are all counted",
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
		{
			desc = "block keyword inside a heredoc body is inert",
			expect = { "real" },
			lines = {
				"defmodule A.MixProject do",
				"  defp deps do",
				'    _doc = """',
				"    case x do",
				'    """',
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
			desc = "'deps:' fragment inside a module-level heredoc ignored",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				'  @moduledoc """',
				"  example deps: fake()",
				'  """',
				"  def project, do: [deps: deps()]",
				'  defp deps, do: [{:real, "~> 2.0"}]',
				"end",
			},
		},
		{
			desc = "'end' inside a heredoc body is inert",
			expect = { "real" },
			lines = {
				"defmodule A.MixProject do",
				"  defp deps do",
				'    _doc = """',
				"    end",
				'    """',
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
			desc = "'#' inside a heredoc body is inert",
			expect = { "real" },
			lines = {
				"defmodule A.MixProject do",
				"  defp deps do",
				'    _doc = """',
				"    # not a comment",
				'    """',
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
			desc = "unmatched '\"' inside a heredoc body is inert",
			expect = { "real" },
			lines = {
				"defmodule A.MixProject do",
				"  defp deps do",
				'    _doc = """',
				'    say " here',
				'    """',
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
			desc = "'[' inside a heredoc body is inert",
			expect = { "real" },
			lines = {
				"defmodule A.MixProject do",
				"  defp deps do",
				'    _doc = """',
				"    x = [",
				'    """',
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
			desc = "heredoc inside project/0's own body does not defeat dep-function scoping",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project do",
				'    _doc = """',
				"    example deps: fake()",
				'    """',
				"    [deps: deps()]",
				"  end",
				'  defp deps, do: [{:real, "~> 2.0"}]',
				"end",
			},
		},
		{
			desc = "heredoc inside project/0's body does not hijack the default deps/0",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project do",
				'    _doc = """',
				"    example deps: fake()",
				'    """',
				"    [app: :demo]",
				"  end",
				'  defp deps, do: [{:real, "~> 2.0"}]',
				"end",
			},
		},
		{
			desc = "wrapped 'do:' after a zero-arity head does not leak into the next function",
			expect = { "jason" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project, do: [deps: deps()]",
				"",
				"  defp deps(),",
				'    do: [{:jason, "~> 1.4"}]',
				"",
				"  defp unrelated,",
				'    do: [{:poison, "~> 5.0"}]',
				"end",
			},
		},
		{
			desc = "charlist contents do not affect block depth",
			expect = { "jason" },
			lines = {
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
			},
		},
		{
			desc = "inline sigil contents do not affect block depth",
			expect = { "jason" },
			lines = {
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
			},
		},
		{
			-- The grammar yields an ERROR node here, so parse_buffer defers to the line scanner.
			desc = "nested paired sigil delimiter does not drop the sibling dep",
			expect = { "jason" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project, do: [deps: deps()]",
				"",
				"  defp deps do",
				"    x = ~s(a (b) do c)",
				'    [{:jason, "~> 1.4"}]',
				"  end",
				"end",
			},
		},
		{
			desc = "empty-parens zero-arity keyword-form head",
			expect = { "jason" },
			lines = {
				"defmodule App.MixProject do",
				'  defp deps(), do: [{:jason, "~> 1.0"}]',
				"end",
			},
		},
		{
			desc = "inline deps list wrapped onto the line after 'deps:'",
			expect = { "jason" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project do",
				"    [",
				"      deps:",
				'      [{:jason, "~> 1.4"}]',
				"    ]",
				"  end",
				"end",
			},
		},
		{
			desc = "keyword-form body whose list spans lines",
			expect = { "jason", "plug" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project, do: [deps: deps()]",
				"  defp deps, do: [",
				'    {:jason, "~> 1.4"},',
				'    {:plug, "~> 1.15"}',
				"  ]",
				'  defp other, do: [{:wrong, "~> 1.0"}]',
				"end",
			},
		},
		{
			desc = "wrapped keyword-form body whose list spans lines",
			expect = { "jason", "plug" },
			lines = {
				"defmodule Demo.MixProject do",
				"  defp deps,",
				"    do: [",
				'      {:jason, "~> 1.4"},',
				'      {:plug, "~> 1.15"}',
				"    ]",
				"end",
			},
		},
		{
			desc = "hex alias on a wrapped tuple line",
			expect = { "my_plug", "jason" },
			lines = {
				"defmodule Demo.MixProject do",
				"  defp deps do",
				"    [",
				'      {:my_plug, "~> 1.0",',
				"       hex: :plug},",
				'      {:jason, "~> 1.4", no_hex: :x}',
				"    ]",
				"  end",
				"end",
			},
		},
		{
			desc = "tuple whose name atom starts on the line after '{'",
			expect = { "jason" },
			lines = {
				"defmodule Demo.MixProject do",
				"  defp deps do",
				"    [",
				"      {",
				'        :jason, "~> 1.4"}',
				"    ]",
				"  end",
				"end",
			},
		},
		{
			desc = "quoted atom name",
			expect = { "jason" },
			lines = {
				"defmodule Demo.MixProject do",
				'  defp deps, do: [{:"jason", "~> 1.4"}]',
				"end",
			},
		},
		{
			desc = "name paired only with the string directly after it",
			expect = { "jason" },
			lines = {
				"defmodule Demo.MixProject do",
				'  defp deps, do: [{:a, :b, "x"}, {:jason, "~> 1.4", "extra"}]',
				"end",
			},
		},
		{
			desc = "deps: key inside a Keyword.merge call",
			expect = { "jason" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project do",
				"    Keyword.merge(base(), deps: project_deps())",
				"  end",
				"  defp base, do: [app: :demo]",
				'  defp project_deps, do: [{:jason, "~> 1.4"}]',
				"end",
			},
		},
		{
			desc = "key merely ending in 'deps' is not the deps: key",
			expect = { "real" },
			lines = {
				"defmodule Demo.MixProject do",
				"  def project do",
				"    [my_deps: other(), app: :demo]",
				"  end",
				'  defp other, do: [{:wrong, "~> 1.0"}]',
				'  defp deps, do: [{:real, "~> 1.0"}]',
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
			local ts = shape(parse_buffer(case.lines))
			local scanned = shape(fallback.parse_lines(case.lines))
			eq(ts, scanned, "treesitter vs fallback for: " .. case.desc)
			eq(case.expect, names(ts), "dep names for: " .. case.desc)
		end)
	end
end)
