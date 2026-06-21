local config = require("hex-outdated.config")
local util = require("hex-outdated.util")

local M = {}

-- Translate a curl exit code from the reachability probe into a health verdict.
-- Exit 0 means hex.pm answered (DNS + connect + response); anything else is a
-- warning rather than an error since the plugin still works from cache offline.
local function reachability_verdict(code)
	if code == 0 then
		return "ok", "hex.pm is reachable"
	end
	return "warn", "hex.pm is not reachable (curl exit " .. tostring(code) .. ")"
end

M._reachability_verdict = reachability_verdict

local function probe_command(base, timeout_ms)
	return {
		"curl",
		"-sS",
		"-o",
		"/dev/null",
		"--max-time",
		string.format("%.15g", util.timeout_seconds(timeout_ms, 5000)),
		base,
	}
end

M._probe_command = probe_command

-- Probe the configured API host, blocking briefly. Safe to block here because
-- :checkhealth is an explicit, interactive command.
local function probe_hex()
	local base = config.options.api.base_url
	local out = vim.system(probe_command(base, config.options.api.timeout_ms), { text = true })
		:wait()
	return out.code
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
		local level, msg = reachability_verdict(probe_hex())
		health[level](msg)
	else
		health.error("`curl` not found on PATH", "Install curl; hex.pm requests are made via curl.")
	end

	-- `language.add` signals "not found" by returning `nil, err` (without raising)
	-- on modern Neovim, and by raising on older versions; require a truthy return,
	-- not merely a successful pcall, or a missing parser is reported as present.
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
