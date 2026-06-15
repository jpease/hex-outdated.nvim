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

-- Direct-child (atom) then (string) inside a tuple. Because the string must be a
-- *direct* child of the tuple, keyword values like github: "owner/repo" (nested in
-- a keywords node) are not matched.
local TS_QUERY = "(tuple (atom) @name (string) @req)"

local warned = false
local function warn_once(msg)
	if not warned then
		warned = true
		vim.schedule(function()
			vim.notify("hex-outdated: " .. msg, vim.log.levels.WARN)
		end)
	end
end

local function parse_treesitter(bufnr)
	local ok, lang_tree = pcall(vim.treesitter.get_parser, bufnr, "elixir")
	if not ok or not lang_tree then
		return nil
	end
	local tree = lang_tree:parse()[1]
	if not tree then
		return nil
	end
	local query_ok, query = pcall(vim.treesitter.query.parse, "elixir", TS_QUERY)
	if not query_ok then
		return nil
	end
	local deps = {}
	local current
	-- iter_captures(node, source, start_row, end_row): yields capture id + node in
	-- document order, so each @name precedes its sibling @req within a tuple.
	for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
		local capture = query.captures[id]
		local text = vim.treesitter.get_node_text(node, bufnr)
		if capture == "name" then
			current = { name = (text:gsub("^:", "")), kind = "hex" }
		elseif capture == "req" and current then
			local srow, scol, _, ecol = node:range()
			current.requirement = text:gsub('^"', ""):gsub('"$', "")
			current.row = srow
			current.col_start = scol + 1 -- inside opening quote
			current.col_end = ecol - 1 -- before closing quote
			deps[#deps + 1] = current
			current = nil
		end
	end
	return deps
end

--- Parse deps from a buffer. Uses Treesitter when the elixir parser is available,
--- otherwise falls back to the pure line parser.
function M.parse_buffer(bufnr)
	local deps = parse_treesitter(bufnr)
	if deps == nil then
		warn_once("Treesitter elixir parser unavailable; using pattern fallback")
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		return M.parse_lines(lines)
	end
	return deps
end

return M
