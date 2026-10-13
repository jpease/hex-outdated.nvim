-- The dependency record both parser backends emit. Pure Lua; no Neovim APIs.

local lexer = require("hex-outdated.parser.lexer")

-- The `hex: :name` option a dep is published under, if any. Only text at the
-- tuple's own bracket depth counts (literals and comments masked), so neither a
-- nested option value nor a sibling tuple that an unfinished tuple runs into
-- mid-edit (`{:a, "~> 1.0",` then `{:b, "~> 2.0", hex: :c}`) supplies it.
local function package_alias(text)
	local masked = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		masked[#masked + 1] = lexer.mask_literals(lexer.strip_comment(line))
	end
	local depth = 0
	local own = table.concat(masked, "\n"):gsub(".", function(c)
		if c:find("[%[{(]") then
			depth = depth + 1
		elseif c:find("[%]})]") then
			depth = depth - 1
		end
		return depth == 1 and c or " "
	end)
	return own:match("%f[%w_]hex%s*:%s*:([%w_]+)")
end

-- `fields.tuple_text` is the full source text of the dep tuple. Positions are
-- 0-indexed; `col_start`/`col_end` bound the requirement text inside its quotes.
local function new_record(fields)
	return {
		name = fields.name,
		package = package_alias(fields.tuple_text),
		requirement = fields.requirement,
		kind = "hex",
		row = fields.row,
		col_start = fields.col_start,
		col_end = fields.col_end,
	}
end

return {
	new_record = new_record,
}
