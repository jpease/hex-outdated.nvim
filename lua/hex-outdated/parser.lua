local M = {}

-- A dep tuple where the element right after the name atom is a string literal,
-- e.g. {:phoenix, "~> 1.6"} or {:jason, "~> 1.4", only: :test}.
-- Deps whose second element is a keyword (github:/path:/git:) have no quote
-- immediately after the comma and are intentionally skipped here.
local DEP_PATTERN = '{%s*:([%w_]+)%s*,%s*"'

--- Parse dependency tuples out of a list of lines (pure; no Neovim APIs).
--- Returns a list of dep tables with 0-indexed `row`, `col_start`, `col_end`.
function M.parse_lines(lines)
	local deps = {}
	for i, line in ipairs(lines) do
		-- `quote_pos` is the 1-indexed position of the opening quote that DEP_PATTERN
		-- ends on, so we read the requirement from exactly that tuple (not the first
		-- quote on the line, which could belong to a comment or earlier text).
		local _, quote_pos, name = line:find(DEP_PATTERN)
		if name then
			local content = line:match('([^"]*)"', quote_pos + 1)
			if content then
				deps[#deps + 1] = {
					name = name,
					requirement = content,
					kind = "hex",
					row = i - 1,
					col_start = quote_pos, -- 0-indexed position just inside the opening quote
					col_end = quote_pos + #content, -- 0-indexed, exclusive end (the closing quote)
				}
			end
		end
	end
	return deps
end

return M
