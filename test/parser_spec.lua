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

	for _, case in ipairs(CASES) do
		it("agrees on " .. case.desc, function()
			local b = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(b, 0, -1, false, case.lines)
			vim.bo[b].filetype = "elixir"
			local ts = shape(parser.parse_buffer(b))
			local fallback = shape(parser.parse_lines(case.lines))
			eq(ts, fallback, "treesitter vs fallback for: " .. case.desc)
		end)
	end
end)
