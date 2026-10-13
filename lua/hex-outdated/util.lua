local M = {}

--- Recursively merge `override` onto a deep copy of `base`. Pure: the result
--- shares no tables with either argument.
function M.deep_merge(base, override)
	local out = {}
	for k, v in pairs(base) do
		out[k] = type(v) == "table" and M.deep_merge(v, {}) or v
	end
	for k, v in pairs(override) do
		if type(v) == "table" then
			out[k] = M.deep_merge(type(out[k]) == "table" and out[k] or {}, v)
		else
			out[k] = v
		end
	end
	return out
end

--- Host (with port) of a URL such as "https://hex.pm/api"; the input itself
--- when it has no scheme.
function M.url_host(url)
	return url:match("^%a[%w+.-]*://([^/?#]+)") or url
end

return M
