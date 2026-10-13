local config = require("hex-outdated.config")
local util = require("hex-outdated.util")

local M = {}

-- Blocking is acceptable here: :checkhealth is explicit and interactive.
-- Returns the curl exit code.
local function probe(api)
	local null = vim.fn.has("win32") == 1 and "NUL" or "/dev/null"
	local cmd = {
		"curl",
		"-sS",
		"-o",
		null,
		"--max-time",
		string.format("%.15g", api.timeout_ms / 1000),
		api.base_url,
	}
	return vim.system(cmd, { text = true }):wait().code
end

--- `:checkhealth hex-outdated` — verify the runtime dependencies the plugin needs.
function M.check()
	local health = vim.health
	health.start("hex-outdated")

	if vim.fn.has("nvim-0.10") == 1 then
		health.ok("Neovim " .. tostring(vim.version()) .. " (>= 0.10)")
	else
		health.error("Neovim 0.10+ is required (uses vim.system, vim.ui.open, vim.diagnostic)")
	end

	if vim.fn.executable("curl") == 1 then
		health.ok("`curl` found on PATH")
		local api = config.options.api
		local host = util.url_host(api.base_url)
		local code = probe(api)
		-- Unreachable is only a warning: cached results still work offline.
		if code == 0 then
			health.ok(host .. " is reachable")
		else
			health.warn(host .. " is not reachable (curl exit " .. tostring(code) .. ")")
		end
	else
		health.error(
			"`curl` not found on PATH",
			"Install curl; package requests are made via curl."
		)
	end

	-- `language.add` returns `nil, err` on newer Neovim and raises on older ones.
	local added_ok, added = pcall(vim.treesitter.language.add, "elixir")
	if added_ok and added then
		health.ok("`elixir` Treesitter parser available")
	else
		health.warn(
			"`elixir` Treesitter parser not found",
			"Run :TSInstall elixir for accurate parsing. A Lua-pattern fallback is used otherwise."
		)
	end
end

return M
