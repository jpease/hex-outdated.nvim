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
		else
			out[k] = v
		end
	end
	return out
end

--- Convert a positive millisecond timeout to curl-compatible seconds.
--- Invalid values use `fallback_ms` (5000 when omitted).
function M.timeout_seconds(timeout_ms, fallback_ms)
	local function positive_finite(value)
		return type(value) == "number" and value > 0 and value < math.huge
	end
	fallback_ms = positive_finite(fallback_ms) and fallback_ms or 5000
	if not positive_finite(timeout_ms) then
		timeout_ms = fallback_ms
	end
	return timeout_ms / 1000
end

return M
