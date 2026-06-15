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

return M
