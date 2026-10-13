-- Dependency extraction from a mix.exs buffer: Tree-sitter when the elixir
-- parser is installed and the tree is error-free, else `parser.fallback`.

local M = {}

local new_record = require("hex-outdated.parser.dep").new_record
local fallback = require("hex-outdated.parser.fallback")

-- A list element tuple whose first two elements are a name atom and a string.
local TS_QUERY = "(list (tuple . [(atom) (quoted_atom)] @name . (string) @req))"

local compiled_query

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

-- The value of the `name:` pair in a `keywords` node.
local function keyword_value(keywords, name, bufnr)
	for i = 0, keywords:named_child_count() - 1 do
		local pair = keywords:named_child(i)
		local key, value = pair:named_child(0), pair:named_child(1)
		-- Keyword text includes its ":" and any whitespace up to the value.
		if key and value and node_text(key, bufnr):match("^" .. name .. "%s*:%s*$") then
			return value
		end
	end
end

-- For a call with an identifier target: that name and its arguments node.
local function call_head(node, bufnr)
	if node:type() ~= "call" then
		return nil
	end
	local target = node:field("target")[1]
	if not target or target:type() ~= "identifier" then
		return nil
	end
	return node_text(target, bufnr), child_of_type(node, "arguments")
end

-- `name` for a local call without arguments (`deps()`), else nil.
local function zero_arity_call(node, bufnr)
	local name, args = call_head(node, bufnr)
	if name and (not args or args:named_child_count() == 0) then
		return name
	end
end

-- The name defined by a zero-arity `def`/`defp`, else nil.
local function zero_arity_def(node, bufnr)
	local keyword, args = call_head(node, bufnr)
	if (keyword ~= "def" and keyword ~= "defp") or not args then
		return nil
	end
	local head = args:named_child(0)
	if head and head:type() == "identifier" then
		return node_text(head, bufnr)
	end
	return head and zero_arity_call(head, bufnr)
end

-- A definition's `do_block`, or its `, do:` value.
local function definition_body(def, bufnr)
	local block = child_of_type(def, "do_block")
	if block then
		return block
	end
	local keywords = child_of_type(child_of_type(def, "arguments"), "keywords")
	return keywords and keyword_value(keywords, "do", bufnr)
end

-- The first `name/0` definition under `node` in document order; with
-- `skip_modules`, nested `defmodule`s are not searched.
local function find_definition(node, bufnr, name, skip_modules)
	if zero_arity_def(node, bufnr) == name then
		return node
	end
	for i = 0, node:named_child_count() - 1 do
		local child = node:named_child(i)
		if not (skip_modules and call_head(child, bufnr) == "defmodule") then
			local found = find_definition(child, bufnr, name, skip_modules)
			if found then
				return found
			end
		end
	end
end

-- The `do_block` of the nearest `defmodule` enclosing `node`.
local function enclosing_module_body(node, bufnr)
	local current = node:parent()
	while current do
		if call_head(current, bufnr) == "defmodule" then
			return child_of_type(current, "do_block")
		end
		current = current:parent()
	end
end

-- The value a body returns: its last expression, with a returned bare variable
-- resolved to the nearest preceding `var = value`.
local function return_expression(body, bufnr)
	if body:type() ~= "do_block" then
		return body
	end
	local count = body:named_child_count()
	if count == 0 then
		return body
	end
	local last = body:named_child(count - 1)
	if last:type() ~= "identifier" then
		return last
	end
	local var = node_text(last, bufnr)
	for i = count - 2, 0, -1 do
		local child = body:named_child(i)
		if child:type() == "binary_operator" then
			local operator = child:field("operator")[1]
			local left = child:field("left")[1]
			if
				operator
				and node_text(operator, bufnr) == "="
				and left
				and node_text(left, bufnr) == var
			then
				return child:field("right")[1] or last
			end
		end
	end
	return last
end

-- The value of the first `deps:` pair under `node`; a keyword list's own pairs
-- are checked before their values.
local function find_deps_value(node, bufnr)
	if node:type() == "keywords" then
		local value = keyword_value(node, "deps", bufnr)
		if value then
			return value
		end
	end
	for i = 0, node:named_child_count() - 1 do
		local found = find_deps_value(node:named_child(i), bufnr)
		if found then
			return found
		end
	end
end

-- The node holding the dep list: the `deps:` value of project/0's returned
-- keyword list (anywhere in the file when there is no project/0), resolving
-- `deps: name()` to `name/0` in project/0's module; `deps/0` without a key.
local function dep_list(root, bufnr)
	local project = find_definition(root, bufnr, "project")
	local scope, scoped = root, false
	local search = root
	if project then
		local module_body = enclosing_module_body(project, bufnr)
		if module_body then
			scope, scoped = module_body, true
		end
		local body = definition_body(project, bufnr)
		search = body and return_expression(body, bufnr)
	end
	local name = "deps"
	local value = search and find_deps_value(search, bufnr)
	if value then
		if value:type() == "list" then
			return value
		end
		name = zero_arity_call(value, bufnr)
		if not name then
			return nil
		end
	end
	local def = find_definition(scope, bufnr, name, scoped)
	local body = def and definition_body(def, bufnr)
	return body and return_expression(body, bufnr)
end

-- nil when the elixir parser is unavailable.
local function parse_treesitter(bufnr)
	local ok, lang_tree = pcall(vim.treesitter.get_parser, bufnr, "elixir")
	if not ok or not lang_tree then
		return nil
	end
	local root = lang_tree:parse()[1]:root()
	-- An ERROR node can swallow dep tuples; the line scanner has no such failure.
	if root:has_error() then
		return fallback.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
	end
	local list = dep_list(root, bufnr)
	if not list then
		return {}
	end
	compiled_query = compiled_query or vim.treesitter.query.parse("elixir", TS_QUERY)
	local deps = {}
	local name
	-- Captures arrive in document order: each @name directly precedes its @req.
	for id, node in compiled_query:iter_captures(list, bufnr, 0, -1) do
		local text = node_text(node, bufnr)
		if compiled_query.captures[id] == "name" then
			name = text:gsub("^:[\"']?", ""):gsub("[\"']$", "")
		else
			local row, col_start, _, col_end = node:range()
			deps[#deps + 1] = new_record({
				name = name,
				tuple_text = node_text(node:parent(), bufnr),
				requirement = text:sub(2, -2),
				row = row,
				col_start = col_start + 1,
				col_end = col_end - 1,
			})
		end
	end
	return deps
end

--- Parse deps from a buffer. Returns dep records with 0-indexed `row`,
--- `col_start`, `col_end`.
function M.parse_buffer(bufnr)
	local deps = parse_treesitter(bufnr)
	if deps == nil then
		warn_once("Treesitter elixir parser unavailable; using pattern fallback")
		return fallback.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
	end
	return deps
end

return M
