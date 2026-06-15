-- Treesitter parsing path against real Neovim. Falls back to skip when the
-- elixir parser is not installed (the pure pattern parser is covered in spec/).
local parser = require("hex-outdated.parser")

local MIX = {
	"defmodule App.MixProject do",
	"  defp deps do",
	"    [",
	'      {:jason, "~> 1.0"},',
	'      {:phoenix, "~> 1.8", only: :prod},',
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

	it("skips path and git deps (keyword second element)", function()
		is_nil(by_name.local_dep, "path dep skipped")
		is_nil(by_name.from_git, "github dep skipped")
	end)

	it("reports the requirement span inside the quotes", function()
		local d = by_name.jason
		eq(3, d.row, "0-indexed row of the jason line")
		-- col_start sits just inside the opening quote; the slice is the requirement.
		local line = MIX[d.row + 1]
		eq("~> 1.0", line:sub(d.col_start + 1, d.col_end))
	end)
end)
