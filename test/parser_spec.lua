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
end)
