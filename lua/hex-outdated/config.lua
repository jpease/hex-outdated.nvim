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

-- Top-level sections whose override must be a table; anything else is dropped
-- before the merge so it cannot replace the default section.
local TABLE_SECTIONS = { "api", "lock", "cache", "text", "highlight", "popup", "keymaps" }

-- Numeric fields; an invalid value falls back to its default.
-- `opts` is passed to normalize_number alongside that default.
local NUMERIC_RULES = {
	{
		section = "api",
		field = "max_concurrent",
		kind = "a positive integer",
		opts = { integer = true, min = 1 },
	},
	{
		section = "api",
		field = "timeout_ms",
		kind = "a positive number",
		opts = { min = 0, min_exclusive = true },
	},
	{ field = "debounce_ms", kind = "a non-negative integer", opts = { integer = true, min = 0 } },
	{
		section = "cache",
		field = "ttl_seconds",
		kind = "a non-negative number",
		opts = { min = 0 },
	},
	{
		section = "cache",
		field = "error_ttl_seconds",
		kind = "a non-negative number",
		opts = { min = 0 },
	},
	{
		section = "popup",
		field = "max_height",
		kind = "a positive integer",
		opts = { integer = true, min = 1 },
	},
}

-- String fields; an invalid value falls back to its own default so one bad key
-- doesn't discard its siblings. `allow_false` fields also accept `false`.
local STRING_RULES = {
	{ section = "api", field = "base_url" },
	{ section = "popup", field = "border" },
	{ section = "popup", field = "hover_key", allow_false = true },
}

-- Every leaf of these sections must be a string.
local STRING_LEAF_SECTIONS = { "text", "highlight" }

local function warn(warnings, fmt, ...)
	warnings[#warnings + 1] = string.format(fmt, ...)
end

--- Returns `value` when it is a finite number (floored when `opts.integer`)
--- of at least `opts.min` (above it when `opts.min_exclusive`); otherwise
--- `default`. The second result reports whether `value` was accepted.
local function normalize_number(value, default, opts)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return default, false
	end
	if opts.integer then
		value = math.floor(value)
	end
	if value < opts.min or (opts.min_exclusive and value == opts.min) then
		return default, false
	end
	return value, true
end

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

local function apply_numeric_rules(merged, defaults, warnings)
	for _, rule in ipairs(NUMERIC_RULES) do
		local container = rule.section and merged[rule.section] or merged
		local default = (rule.section and defaults[rule.section] or defaults)[rule.field]
		local original = container[rule.field]
		local value, ok = normalize_number(original, default, rule.opts)
		container[rule.field] = value
		if not ok then
			warn(
				warnings,
				"hex-outdated: %s must be %s (got %s); using %s",
				rule.section and (rule.section .. "." .. rule.field) or rule.field,
				rule.kind,
				tostring(original),
				tostring(value)
			)
		end
	end
end

local function apply_string_rules(merged, defaults, warnings)
	for _, rule in ipairs(STRING_RULES) do
		local value = merged[rule.section][rule.field]
		if type(value) ~= "string" and not (rule.allow_false and value == false) then
			warn(
				warnings,
				"hex-outdated: %s.%s must be a string (got %s); using default",
				rule.section,
				rule.field,
				type(value)
			)
			merged[rule.section][rule.field] = defaults[rule.section][rule.field]
		end
	end
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
	for action, lhs in pairs(merged.keymaps) do
		if type(lhs) ~= "string" then
			warn(
				warnings,
				"hex-outdated: keymaps.%s must be a string (got %s); ignoring it",
				tostring(action),
				type(lhs)
			)
			merged.keymaps[action] = nil
		end
	end
end

--- Merge `opts` (any value) over `defaults` and validate the result. Pure: never
--- touches `vim`. Returns the options table and a list of warning strings.
function M.normalize(defaults, opts)
	local warnings = {}
	local merged = util.deep_merge(defaults, sanitize_top_level(opts, warnings))
	apply_numeric_rules(merged, defaults, warnings)
	apply_string_rules(merged, defaults, warnings)
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
