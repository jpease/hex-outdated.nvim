local M = {}

-- A dep tuple where the element right after the name atom is a string literal,
-- e.g. {:phoenix, "~> 1.6"} or {:jason, "~> 1.4", only: :test}.
-- Deps whose second element is a keyword (github:/path:/git:) have no quote
-- immediately after the comma and are intentionally skipped here.
local DEP_PATTERN = '{%s*:([%w_]+)%s*,%s*"'

local function strip_comment(line)
	local in_string = false
	local escaped = false
	for i = 1, #line do
		local char = line:sub(i, i)
		if escaped then
			escaped = false
		elseif char == "\\" and in_string then
			escaped = true
		elseif char == '"' then
			in_string = not in_string
		elseif char == "#" and not in_string then
			return line:sub(1, i - 1)
		end
	end
	return line
end

local function configured_dep_function(lines)
	for _, line in ipairs(lines) do
		local name = strip_comment(line):match("deps%s*:%s*([%a_][%w_!?]*)%s*%(")
		if name then
			return name
		end
	end
	return "deps"
end

local function function_start(line, name)
	local indent, rest = line:match("^(%s*)defp?%s+(.*)")
	if not rest then
		return
	end
	local declared, after = rest:match("^([%w_!?]+)(.*)")
	if declared ~= name then
		return
	end
	-- Skip arity > 0 definitions: function name immediately followed by '('
	if after:match("^%s*%(") then
		return
	end
	return indent, line:find(",%s*do%s*:") ~= nil
end

local function package_alias(text)
	return text:match("hex%s*:%s*:([%w_]+)")
end

--- Parse dependency tuples out of a list of lines (pure; no Neovim APIs).
--- Returns a list of dep tables with 0-indexed `row`, `col_start`, `col_end`.
function M.parse_lines(lines)
	local deps = {}
	local dep_function = configured_dep_function(lines)
	local active = false
	local function_indent
	local one_line = false
	for i, line in ipairs(lines) do
		local code = strip_comment(line)
		if not active then
			function_indent, one_line = function_start(code, dep_function)
			active = function_indent ~= nil
		elseif code:match("^" .. function_indent .. "end%s*$") then
			active = false
		end
		if active then
			-- Scan the entire line for dep tuples: a single line may hold multiple
			-- entries (e.g. compact `do:` form). For each match we extract the
			-- requirement from that specific tuple and scope the alias search to the
			-- text between this tuple's `{` and the next one.
			local search_pos = 1
			while true do
				local match_start, quote_pos, name = code:find(DEP_PATTERN, search_pos)
				if not name then
					break
				end
				-- Skip tuples on the RHS of an assignment (e.g. `meta = {:ok, "val"}`).
				-- Check the non-whitespace character immediately before the '{'.
				local before = code:sub(1, match_start - 1):match("^(.-)%s*$")
				local lc = before:sub(-1)
				local pc = #before > 1 and before:sub(-2, -2) or ""
				local in_list = lc ~= "=" or pc == ">" or pc == "<" or pc == "!" or pc == "~"
				if in_list then
					local content = code:match('([^"]*)"', quote_pos + 1)
					if content then
						local next_brace = code:find("{", quote_pos + #content + 2)
						local tuple_text =
							code:sub(match_start, next_brace and (next_brace - 1) or #code)
						deps[#deps + 1] = {
							name = name,
							package = package_alias(tuple_text),
							requirement = content,
							kind = "hex",
							row = i - 1,
							col_start = quote_pos, -- 0-indexed position just inside the opening quote
							col_end = quote_pos + #content, -- 0-indexed, exclusive end (the closing quote)
						}
						search_pos = quote_pos + #content + 2
					else
						search_pos = quote_pos + 1
					end
				else
					search_pos = match_start + 1
				end
			end
			if one_line then
				active = false
			end
		end
	end
	return deps
end

-- Tuples with a direct-child atom then string, inside a list. The list constraint
-- excludes assignment-RHS tuples like `meta = {:ok, "val"}`; the direct-child
-- constraint excludes keyword values like `github: "owner/repo"` (nested in a
-- keywords node).
local TS_QUERY = "(list (tuple (atom) @name (string) @req))"

-- The query is a constant, but `parse_buffer` runs on every (debounced) edit.
-- Compile it once and reuse; `query.parse` is not free per call.
local compiled_query
local function get_query()
	if compiled_query == nil then
		local ok, query = pcall(vim.treesitter.query.parse, "elixir", TS_QUERY)
		compiled_query = ok and query or false
	end
	return compiled_query or nil
end

local warned = false
local function warn_once(msg)
	if not warned then
		warned = true
		vim.schedule(function()
			vim.notify("hex-outdated: " .. msg, vim.log.levels.WARN)
		end)
	end
end

local function node_text(node, bufnr)
	return vim.treesitter.get_node_text(node, bufnr)
end

local function child_of_type(node, node_type)
	for i = 0, node:named_child_count() - 1 do
		local child = node:named_child(i)
		if child:type() == node_type then
			return child
		end
	end
end

local function definition_name(node, bufnr)
	if node:type() ~= "call" then
		return nil
	end
	local target = node:field("target")[1]
	local target_text = target and node_text(target, bufnr)
	if target_text ~= "def" and target_text ~= "defp" then
		return nil
	end
	local arguments = child_of_type(node, "arguments")
	local head = arguments and arguments:named_child(0)
	if not head then
		return nil
	elseif head:type() == "identifier" then
		return node_text(head, bufnr)
	elseif head:type() == "call" then
		local function_target = head:field("target")[1]
		return function_target and node_text(function_target, bufnr)
	end
end

local function definition_body(node)
	return child_of_type(node, "do_block") or node
end

-- True when the definition head is a bare identifier (no parameter list), i.e. arity 0.
local function is_def_arity_zero(node)
	local arguments = child_of_type(node, "arguments")
	local head = arguments and arguments:named_child(0)
	return head ~= nil and head:type() == "identifier"
end

local function find_definition(node, bufnr, name)
	if type(node.type) ~= "function" then
		return node -- test doubles that only exercise query compilation
	end
	if definition_name(node, bufnr) == name and is_def_arity_zero(node) then
		return definition_body(node)
	end
	for i = 0, node:named_child_count() - 1 do
		local found = find_definition(node:named_child(i), bufnr, name)
		if found then
			return found
		end
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
	local query = get_query()
	if not query then
		return nil
	end
	local lines = vim.api
			and vim.api.nvim_buf_get_lines
			and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		or {}
	local body = find_definition(tree:root(), bufnr, configured_dep_function(lines))
	if not body then
		return {}
	end
	local deps = {}
	local current
	-- iter_captures(node, source, start_row, end_row): yields capture id + node in
	-- document order, so each @name precedes its sibling @req within a tuple.
	for id, node in query:iter_captures(body, bufnr, 0, -1) do
		local capture = query.captures[id]
		local text = node_text(node, bufnr)
		if capture == "name" then
			current = { name = (text:gsub("^:", "")), kind = "hex" }
		elseif capture == "req" and current then
			local srow, scol, _, ecol = node:range()
			local tuple = node:parent()
			current.requirement = text:gsub('^"', ""):gsub('"$', "")
			current.package = tuple and package_alias(node_text(tuple, bufnr))
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
