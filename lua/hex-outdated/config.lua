local util = require("hex-outdated.util")

local M = {}

M.defaults = {
	enabled = true,
	auto_update = true,
	debounce_ms = 500,
	api = {
		base_url = "https://hex.pm/api",
		timeout_ms = 5000,
	},
	cache = { ttl_seconds = 3600 },
	text = {
		up_to_date = "✓ %s",
		upgradable = "↑ %s",
		outdated = "↓ %s",
		invalid = "✗ no such version",
		loading = "…",
		error = "fetch error",
	},
	highlight = {
		up_to_date = "HexOutdatedUpToDate",
		upgradable = "HexOutdatedUpgradable",
		outdated = "HexOutdatedOutdated",
		invalid = "HexOutdatedInvalid",
		loading = "HexOutdatedLoading",
		error = "HexOutdatedError",
	},
	popup = { border = "rounded", max_height = 20 },
	-- opt-in buffer-local keymaps, e.g. { upgrade = "<leader>cu", versions = "<leader>cv" }
	keymaps = {},
}

M.options = util.deep_merge(M.defaults, {})

function M.setup(opts)
	M.options = util.deep_merge(M.defaults, opts or {})
end

return M
