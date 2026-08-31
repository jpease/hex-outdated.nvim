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

-- Top-level sections that must remain a table shape. A non-table override for
-- any of these (not just `api`, which #70/#72's own reproduction happens to
-- use) previously crashed downstream code indexing into it — see #72.
local TABLE_SECTIONS = { "api", "lock", "cache", "text", "highlight", "popup", "keymaps" }

-- Runtime-sensitive numeric fields and the single shared contract each is
-- checked against (util.normalize_number). `fallback` is what a field
-- resets to when the merged value is invalid; it is intentionally NOT always
-- `defaults[section][field]` — api.max_concurrent's safe fallback is the
-- conservative floor of 1, not its default of 8, matching the pre-existing
-- (and still-tested) #35/#70 clamp behavior and hex_api's own clamp.
local NUMERIC_RULES = {
	{
		section = "api",
		field = "max_concurrent",
		fallback = 1,
		kind = "a positive integer",
		opts = { integer = true, min = 1 },
	},
	{
		section = "api",
		field = "timeout_ms",
		fallback = 5000,
		kind = "a positive number",
		opts = { min = 0, min_exclusive = true },
	},
	{
		field = "debounce_ms",
		fallback = 500,
		kind = "a non-negative integer",
		opts = { integer = true, min = 0 },
	},
	{
		section = "cache",
		field = "ttl_seconds",
		fallback = 3600,
		kind = "a non-negative number",
		opts = { min = 0 },
	},
	{
		section = "cache",
		field = "error_ttl_seconds",
		fallback = 60,
		kind = "a non-negative number",
		opts = { min = 0 },
	},
	{
		section = "popup",
		field = "max_height",
		fallback = 20,
		kind = "a positive integer",
		opts = { integer = true, min = 1 },
	},
}

-- String-leaf sections: every leaf must stay a string (formatting templates
-- and highlight-group names are `string.format`'d / used as group names
-- downstream); a non-string leaf falls back to its own default, not the
-- whole section, so one bad key doesn't discard sibling keys.
local STRING_LEAF_SECTIONS = { "text", "highlight" }

local function warn(warnings, fmt, ...)
	warnings[#warnings + 1] = string.format(fmt, ...)
end

-- Reject a non-table `opts` outright (setup({ ... }) called with something
-- else entirely), then drop any top-level section override whose shape isn't
-- a table so a later deep_merge can't let it wholesale-replace the default
-- table (util.deep_merge's scalar-replaces-table behavior is itself
-- intentional and separately tested — see spec/util_spec.lua issue #37 — so
-- the fix has to happen here, before the merge, not inside deep_merge).
local function sanitize_top_level(opts, warnings)
	if type(opts) ~= "table" then
		if opts ~= nil then
			warn(
				warnings,
				"hex-outdated: setup() options must be a table (got %s); using defaults",
				type(opts)
			)
		end
		return {}
	end
	local sanitized = {}
	for k, v in pairs(opts) do
		sanitized[k] = v
	end
	for _, section in ipairs(TABLE_SECTIONS) do
		if sanitized[section] ~= nil and type(sanitized[section]) ~= "table" then
			warn(
				warnings,
				"hex-outdated: %s must be a table (got %s); using defaults",
				section,
				type(sanitized[section])
			)
			sanitized[section] = nil
		end
	end
	return sanitized
end

local function apply_numeric_rules(merged, warnings)
	for _, rule in ipairs(NUMERIC_RULES) do
		local container = rule.section and merged[rule.section] or merged
		local label = rule.section and (rule.section .. "." .. rule.field) or rule.field
		local original = container[rule.field]
		local value, ok = util.normalize_number(original, {
			default = rule.fallback,
			min = rule.opts.min,
			min_exclusive = rule.opts.min_exclusive,
			integer = rule.opts.integer,
		})
		container[rule.field] = value
		if not ok then
			warn(
				warnings,
				"hex-outdated: %s must be %s (got %s); using %s",
				label,
				rule.kind,
				tostring(original),
				tostring(value)
			)
		end
	end
end

local function apply_string_leaf_rules(merged, defaults, warnings)
	for _, section in ipairs(STRING_LEAF_SECTIONS) do
		for field, default in pairs(defaults[section]) do
			local value = merged[section][field]
			if type(value) ~= "string" then
				warn(
					warnings,
					"hex-outdated: %s.%s must be a string (got %s); using default",
					section,
					field,
					type(value)
				)
				merged[section][field] = default
			end
		end
	end
	for _, field in ipairs({ "border", "hover_key" }) do
		local value = merged.popup[field]
		if type(value) ~= "string" then
			warn(
				warnings,
				"hex-outdated: popup.%s must be a string (got %s); using default",
				field,
				type(value)
			)
			merged.popup[field] = defaults.popup[field]
		end
	end
end

--- Pure configuration normalization pass (#72). Accepts arbitrary user input
--- (any type — not just a well-shaped table) and `defaults`, and returns a
--- complete, correctly-shaped, correctly-typed options table plus a plain
--- array of warning strings. Never reads or writes `vim` state: the
--- Neovim-facing `M.setup` below is the only place that calls `vim.notify`,
--- and it does so exactly once per warning per `setup()` call — not once per
--- dependency or request, which is what hex_api's own defensive clamps (via
--- the same util.normalize_number contract) exist to avoid re-triggering.
function M.normalize(defaults, opts)
	local warnings = {}
	local sanitized = sanitize_top_level(opts, warnings)
	local merged = util.deep_merge(defaults, sanitized)
	apply_numeric_rules(merged, warnings)
	apply_string_leaf_rules(merged, defaults, warnings)
	return merged, warnings
end

function M.setup(opts)
	local normalized, warnings = M.normalize(M.defaults, opts)
	M.options = normalized
	for _, w in ipairs(warnings) do
		vim.notify(w, vim.log.levels.WARN)
	end
end

return M
