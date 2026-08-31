local M = {}

--- Recursively merge `override` onto a deep copy of `base`. Pure; mutates nothing.
function M.deep_merge(base, override)
	local out = {}
	for k, v in pairs(base or {}) do
		if type(v) == "table" then
			out[k] = M.deep_merge(v, {})
		else
			out[k] = v
		end
	end
	for k, v in pairs(override or {}) do
		if type(v) == "table" and type(out[k]) == "table" then
			out[k] = M.deep_merge(out[k], v)
		elseif type(v) == "table" then
			out[k] = M.deep_merge(v, {})
		else
			out[k] = v
		end
	end
	return out
end

--- Convert a positive millisecond timeout to curl-compatible seconds.
--- Invalid values use `fallback_ms` (5000 when omitted).
function M.timeout_seconds(timeout_ms, fallback_ms)
	local fb = M.normalize_number(fallback_ms, { default = 5000, min = 0, min_exclusive = true })
	local ms = M.normalize_number(timeout_ms, { default = fb, min = 0, min_exclusive = true })
	return ms / 1000
end

--- Shared scalar-normalization contract for runtime-sensitive numeric config:
--- reject any non-number, NaN, or +/-infinity outright, optionally floor to an
--- integer, then enforce an optional lower bound. Every caller in this plugin
--- (config.setup's validation pass and hex_api's defensive per-call clamps)
--- goes through this one function so the two never drift apart again (#72).
---
--- opts:
---   default (required) — substituted whenever `value` fails validation
---   min (optional) — lower bound, checked after any `integer` flooring
---   min_exclusive (optional bool) — when true, `value == min` is also rejected
---   integer (optional bool) — floor `value` before the bound check
---
--- Returns `normalized_value, ok` where `ok` is false whenever `default` was
--- substituted, so callers that need to warn can detect that without
--- re-deriving the validity check themselves.
function M.normalize_number(value, opts)
	opts = opts or {}
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return opts.default, false
	end
	if opts.integer then
		value = math.floor(value)
	end
	if opts.min ~= nil then
		if opts.min_exclusive then
			if value <= opts.min then
				return opts.default, false
			end
		elseif value < opts.min then
			return opts.default, false
		end
	end
	return value, true
end

return M
