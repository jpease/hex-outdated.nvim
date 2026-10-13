-- The dependency record both parser backends emit. Pure Lua; no Neovim APIs.

-- The `hex: :name` option a dep is published under, if any.
local function package_alias(text)
	return text:match("%f[%w_]hex%s*:%s*:([%w_]+)")
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
