local util = require("hex-outdated.util")

local M = {}

M.defaults = {
	enabled = true,
	auto_update = true,
	debounce_ms = 500,
	api = {
		base_url = "https://hex.pm/api",
		timeout_ms = 5000,
		max_concurrent = 8,
	},
	lock = {
		enabled = true,
		lens = false,
		stale_diagnostic = true,
	},
	cache = { ttl_seconds = 3600, error_ttl_seconds = 60 },
	text = {
		up_to_date = "✓ %s",
		upgradable = "↑ %s",
		outdated = "↓ %s",
		invalid = "✗ no such version",
		loading = "…",
		error = "fetch error",
		lock_behind = "locked %s · latest %s",
		lock_current = "locked %s · up to date",
	},
	highlight = {
		up_to_date = "HexOutdatedUpToDate",
		upgradable = "HexOutdatedUpgradable",
		outdated = "HexOutdatedOutdated",
		invalid = "HexOutdatedInvalid",
		loading = "HexOutdatedLoading",
		error = "HexOutdatedError",
		lock = "HexOutdatedLock",
		lock_behind = "HexOutdatedLockBehind",
	},
	popup = { border = "rounded", max_height = 20, hover_key = "K" },
	-- opt-in buffer-local keymaps, e.g. { upgrade = "<leader>cu", versions = "<leader>cv" }
	keymaps = {},
}

M.options = util.deep_merge(M.defaults, {})

local function validate_max_concurrent(o)
	local mc = o.api.max_concurrent
	if type(mc) ~= "number" or math.floor(mc) < 1 then
		vim.notify(
			string.format(
				"hex-outdated: api.max_concurrent must be a positive integer (got %s); using 1",
				tostring(mc)
			),
			vim.log.levels.WARN
		)
		o.api.max_concurrent = 1
	else
		o.api.max_concurrent = math.floor(mc)
	end
end

function M.setup(opts)
	M.options = util.deep_merge(M.defaults, opts or {})
	validate_max_concurrent(M.options)
end

return M
