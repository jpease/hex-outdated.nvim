-- Public parser entry points, plus the Tree-sitter backend.
--
-- `require("hex-outdated.parser")` resolves to this file and returns the same
-- two functions it always has: `parse_lines` (pure, line-based) and
-- `parse_buffer` (Tree-sitter, falling back to `parse_lines`).
--
-- The parser is split four ways, with dependencies pointing in one direction:
--
--   lexer     pure lexical core -- comments, strings, charlists, sigils,
--             heredocs, delimiters, block keywords. Depends on nothing.
--   dep       dependency normalization shared by both backends: the record
--             shape and the dep-function name guess. Depends on lexer.
--   fallback  the line-scanning backend. Depends on lexer and dep.
--   init      this file: the Tree-sitter backend and the public API.
--
-- This is the only file in `parser/` that touches Neovim APIs, and the only one
-- holding module-level state (`compiled_query`, `warned`). `lexer`, `dep`, and
-- `fallback` are pure and stateless, so dropping this module from
-- `package.loaded` and re-requiring it resets everything there is to reset.

local M = {}

local lexer = require("hex-outdated.parser.lexer")
local dep = require("hex-outdated.parser.dep")
local fallback = require("hex-outdated.parser.fallback")

local mask_heredocs = lexer.mask_heredocs
local configured_dep_function = dep.configured_dep_function
local new_record = dep.new_record

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

-- The value node of the `name:` pair inside a `keywords` node, or nil. Verified
-- against tree-sitter-elixir's grammar: a `keywords` node holds `pair` children,
-- each with a `keyword` node (whose text includes the trailing ":") and a value.
local function keyword_pair_value(keywords, name, bufnr)
	if not keywords then
		return nil
	end
	for i = 0, keywords:named_child_count() - 1 do
		local pair = keywords:named_child(i)
		if pair:type() == "pair" then
			local key = pair:named_child(0)
			local value = pair:named_child(1)
			-- The keyword's text spans its own trailing whitespace, which may be a
			-- newline when the value wraps onto the next line.
			if key and value and node_text(key, bufnr):match("^" .. name .. "%s*:%s*$") then
				return value
			end
		end
	end
	return nil
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

-- The body of a `def`/`defp` definition: its `do_block` for the block form, or
-- the value of the `do:` keyword for the one-line `def name, do: expr` form,
-- which tree-sitter-elixir represents as `call → arguments → keywords →
-- pair(keyword "do:") → value` with no `do_block` child at all. Falls back to the
-- whole node when neither shape matches, which is also what a test double gets.
local function definition_body(node, bufnr)
	if type(node.type) ~= "function" then
		return node -- test doubles that only exercise query compilation
	end
	local block = child_of_type(node, "do_block")
	if block then
		return block
	end
	local arguments = child_of_type(node, "arguments")
	local keywords = arguments and child_of_type(arguments, "keywords")
	return keyword_pair_value(keywords, "do", bufnr) or node
end

local function is_defmodule(node, bufnr)
	if node:type() ~= "call" then
		return false
	end
	local target = node:field("target")[1]
	return target ~= nil and node_text(target, bufnr) == "defmodule"
end

-- The `do_block` of the nearest `defmodule` enclosing `node`, or nil when there
-- is none. Restricting a definition lookup to this subtree is what anchors
-- dependency discovery to `project/0`'s own module.
local function enclosing_module_body(node, bufnr)
	local current = node:parent()
	while current do
		if is_defmodule(current, bufnr) then
			return child_of_type(current, "do_block")
		end
		current = current:parent()
	end
	return nil
end

-- The name of a zero-arity call expression, e.g. `deps` in `deps: deps()`.
-- Returns nil for a call that takes arguments (`filter_deps(:prod)`), for a
-- qualified call (`Deps.all()`), and for any other node type.
local function zero_arity_call_name(node, bufnr)
	if node:type() ~= "call" then
		return nil
	end
	local target = node:field("target")[1]
	if not target or target:type() ~= "identifier" then
		return nil
	end
	local arguments = child_of_type(node, "arguments")
	if arguments and arguments:named_child_count() > 0 then
		return nil
	end
	return node_text(target, bufnr)
end

-- Locate the `deps:` pair's value node within a `[key: val, ...]` keyword
-- list (e.g. project()'s returned list when it inlines `deps: [...]`
-- directly instead of delegating to a separate deps/0 function). Verified
-- against tree-sitter-elixir's actual grammar: a keyword list literal is a
-- `list` node whose sole named child is a `keywords` node containing `pair`
-- children, each with a `keyword` node (its text includes the trailing ":")
-- and a value node.
local function find_deps_pair_value(list_node, bufnr)
	if type(list_node.type) ~= "function" or list_node:type() ~= "list" then
		return nil
	end
	return keyword_pair_value(child_of_type(list_node, "keywords"), "deps", bufnr)
end

-- The dependency list is the function's return value, i.e. the last expression
-- of its do-block (or the whole keyword `do:` body when there is no block).
-- Restricting the query to this subtree excludes intermediate statements such as
-- `statuses = [{:ok, "x"}]` while keeping composed returns like `base() ++ [...]`.
-- When the body returns a bare variable (`deps = [...]; deps`), resolve it to the
-- list assigned to that variable earlier in the block.
local function return_expression(body, bufnr)
	-- Guard against test doubles that only exercise query compilation.
	if type(body.type) ~= "function" or body:type() ~= "do_block" then
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
	-- Returned a bare variable: find its assignment (`var = ...`) in the block and
	-- use the right-hand side. Scan backward so the nearest binding wins.
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

-- True when the definition head takes no parameters (arity 0). That is either a
-- bare identifier (`def deps`) or a call with an empty argument list (`def deps()`).
local function is_def_arity_zero(node)
	local arguments = child_of_type(node, "arguments")
	local head = arguments and arguments:named_child(0)
	if head == nil then
		return false
	end
	if head:type() == "identifier" then
		return true
	end
	if head:type() == "call" then
		local call_args = child_of_type(head, "arguments")
		return call_args == nil or call_args:named_child_count() == 0
	end
	return false
end

-- The `def`/`defp` node defining `name/0` within `node`'s subtree, in document
-- order. With `skip_nested_modules`, `defmodule` children are not descended
-- into, so a search scoped to one module's body ignores modules nested in it.
local function find_definition_node(node, bufnr, name, skip_nested_modules)
	if type(node.type) ~= "function" then
		return node -- test doubles that only exercise query compilation
	end
	if definition_name(node, bufnr) == name and is_def_arity_zero(node) then
		return node
	end
	for i = 0, node:named_child_count() - 1 do
		local child = node:named_child(i)
		if not (skip_nested_modules and is_defmodule(child, bufnr)) then
			local found = find_definition_node(child, bufnr, name, skip_nested_modules)
			if found then
				return found
			end
		end
	end
end

local function find_definition(node, bufnr, name, skip_nested_modules)
	local def = find_definition_node(node, bufnr, name, skip_nested_modules)
	return def and definition_body(def, bufnr) or nil
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
	-- Resolve through `project/0` first: the dependency list is whatever the
	-- `deps:` key of the list it returns names, resolved inside `project/0`'s own
	-- module. Guessing a name from file text and searching the whole tree is only
	-- a fallback for files where that chain cannot be followed.
	local root = tree:root()
	local project = find_definition_node(root, bufnr, "project")
	if project and type(project.type) ~= "function" then
		project = nil -- test double; nothing to scope against
	end
	local scope, scoped = root, false
	local body
	if project then
		local module_body = enclosing_module_body(project, bufnr)
		if module_body then
			scope, scoped = module_body, true
		end
		local returned = return_expression(definition_body(project, bufnr), bufnr)
		local deps_value = find_deps_pair_value(returned, bufnr)
		if deps_value then
			if deps_value:type() == "list" then
				body = deps_value
			else
				local name = zero_arity_call_name(deps_value, bufnr)
				body = name and find_definition(scope, bufnr, name, scoped) or nil
			end
		end
	end
	if not body then
		-- Narrow the text-based name guess to project/0's own body, exactly like
		-- `parse_lines` narrows via `locate_project`'s line range — otherwise a
		-- `deps: name()` fragment anywhere else in the file (a sibling function, a
		-- @doc string, a module attribute) could hijack the guess. `project`'s own
		-- node range is used rather than the unwrapped body: it is available
		-- whether or not project/0 has a `do_block` (the one-line `def project,
		-- do: ...` form has none), and including the `def project do` / `end`
		-- lines is harmless since neither ever carries a `deps:` fragment.
		local first, last
		if project then
			local start_row, _, end_row = project:range()
			first, last = start_row + 1, end_row + 1
		end
		-- This branch is a raw-line regex text guess, not AST navigation, so it
		-- has no more concept of a heredoc than the fallback parser's own
		-- `configured_dep_function` call does -- and it is reachable on
		-- well-formed input: whenever project/0 declares no `deps:` key at all
		-- (so the AST chain above never runs), a heredoc anywhere in
		-- project/0's body (e.g. a `@doc`-style example containing literal
		-- `deps: fake()` text) can hijack this text search exactly as it can
		-- hijack the fallback's, and the fallback path is masked. Mask `lines`
		-- here too so the two paths cannot disagree; `lines` is used nowhere
		-- else in this function, so the change is contained to this one call.
		body = find_definition(
			scope,
			bufnr,
			configured_dep_function(mask_heredocs(lines), first, last),
			scoped
		)
	end
	if not body then
		return {}
	end
	local deps = {}
	local pending_name
	-- iter_captures(node, source, start_row, end_row): yields capture id + node in
	-- document order, so each @name precedes its sibling @req within a tuple.
	for id, node in query:iter_captures(return_expression(body, bufnr), bufnr, 0, -1) do
		local capture = query.captures[id]
		local text = node_text(node, bufnr)
		if capture == "name" then
			pending_name = (text:gsub("^:", ""))
		elseif capture == "req" and pending_name then
			local srow, scol, _, ecol = node:range()
			local tuple = node:parent()
			deps[#deps + 1] = new_record({
				name = pending_name,
				tuple_text = tuple and node_text(tuple, bufnr),
				requirement = text:gsub('^"', ""):gsub('"$', ""),
				row = srow,
				col_start = scol + 1, -- inside opening quote
				col_end = ecol - 1, -- before closing quote
			})
			pending_name = nil
		end
	end
	return deps
end

--- Parse dependency tuples out of a list of lines (pure; no Neovim APIs).
--- Returns a list of dep tables with 0-indexed `row`, `col_start`, `col_end`.
M.parse_lines = fallback.parse_lines

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
