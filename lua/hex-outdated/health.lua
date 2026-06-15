local M = {}

local health = vim.health

--- `:checkhealth hex-outdated` — verify the runtime dependencies the plugin needs.
function M.check()
	health.start("hex-outdated")

	if vim.fn.has("nvim-0.10") == 1 then
		health.ok("Neovim " .. tostring(vim.version()) .. " (>= 0.10)")
	else
		health.error("Neovim 0.10+ is required (uses vim.system, vim.ui.open, vim.diagnostic)")
	end

	if vim.fn.executable("curl") == 1 then
		health.ok("`curl` found on PATH")
	else
		health.error("`curl` not found on PATH", "Install curl; hex.pm requests are made via curl.")
	end

	if pcall(vim.treesitter.language.add, "elixir") then
		health.ok("`elixir` Treesitter parser available")
	else
		health.warn(
			"`elixir` Treesitter parser not found",
			"Run :TSInstall elixir for accurate parsing. A Lua-pattern fallback is used otherwise."
		)
	end
end

return M
