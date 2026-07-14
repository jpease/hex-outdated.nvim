local M = {}

-- A dep tuple where the element right after the name atom is a string literal,
-- e.g. {:phoenix, "~> 1.6"} or {:jason, "~> 1.4", only: :test}.
-- Deps whose second element is a keyword (github:/path:/git:) have no quote
-- immediately after the comma and are intentionally skipped here.
local DEP_PATTERN = '{%s*:([%w_]+)%s*,%s*"'

-- A dep tuple whose name+comma appear at the end of a line, with the
-- requirement string wrapped onto the next line (e.g. `mix format`-wrapped
-- long package names). Matched against the unconsumed tail of a line after
-- all inline DEP_PATTERN matches on it have been exhausted.
local PENDING_DEP_PATTERN = "{%s*:([%w_]+)%s*,%s*$"

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

-- Count block-opening keywords ("do" starting a do/end block, and "fn" for an
-- anonymous function) in `code`, as whole words. Used to track nested-block
-- depth so a bare "end" line only closes the dep function when it isn't
-- closing an inner if/case/cond/unless/with/for/receive/try/fn block —
-- Elixir's indentation is not semantically significant, so indentation alone
-- can't tell them apart. Heuristic: doesn't mask string-literal contents, but
-- dep requirement strings and option atoms in a real mix.exs deps list won't
-- contain bare "do"/"fn" as whole words.
local function count_openers(code)
	local count = 0
	local pos = 1
	while true do
		local s, e = code:find("%f[%w]do%f[%W]", pos)
		if not s then
			break
		end
		if code:sub(e + 1, e + 1) ~= ":" then
			count = count + 1
		end
		pos = e + 1
	end
	pos = 1
	while true do
		local s, e = code:find("%f[%w]fn%f[%W]", pos)
		if not s then
			break
		end
		count = count + 1
		pos = e + 1
	end
	return count
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

-- Stateful multi-line function-head matcher for `name`. Feed it each source
-- line (comment-stripped) in call order; each call returns either nil (no
-- decision — not a `name` head, or a multi-line signature still awaiting its
-- closing paren) or `indent, one_line` once a zero-arity `name` head is
-- confirmed. A signature with any non-whitespace between its parens (nonzero
-- arity, e.g. `deps/1`) resolves to nil once its closing paren is found —
-- never a match. Must be constructed once per top-level scan (one instance
-- per `parse_lines` call, one per `returned_variable` call) so `pending`
-- persists correctly across the lines of a wrapped signature.
local function new_head_matcher(name)
	local pending -- { indent = ..., parts = { accumulated pre-")" text } }
	return function(line)
		if pending then
			local before, after = line:match("^(.-)%)(.*)$")
			if not before then
				pending.parts[#pending.parts + 1] = line
				return nil
			end
			pending.parts[#pending.parts + 1] = before
			local params = table.concat(pending.parts)
			local indent = pending.indent
			pending = nil
			if params:match("%S") then
				return nil
			end
			return indent, after:find(",%s*do%s*:") ~= nil
		end
		local indent, rest = line:match("^(%s*)defp?%s+(.*)")
		if not rest then
			return nil
		end
		local declared, after = rest:match("^([%w_!?]+)(.*)")
		if declared ~= name then
			return nil
		end
		local paren_rest = after:match("^%s*%((.*)$")
		if not paren_rest then
			return indent, line:find(",%s*do%s*:") ~= nil
		end
		local before, tail = paren_rest:match("^(.-)%)(.*)$")
		if not before then
			pending = { indent = indent, parts = { paren_rest } }
			return nil
		end
		if before:match("%S") then
			return nil
		end
		return indent, tail:find(",%s*do%s*:") ~= nil
	end
end

local function package_alias(text)
	return text:match("hex%s*:%s*:([%w_]+)")
end

-- The bare-identifier expression returned by a function body, e.g. the final
-- `deps` in `defp deps do\n  deps = [...]\n  deps\nend`. When present, the list
-- assigned to that variable IS the dependency list and must not be excluded as a
-- plain assignment RHS. Returns nil when the body's last expression is not a bare
-- variable (e.g. a list literal or a composed `base() ++ [...]`).
local function returned_variable(lines, dep_function)
	local active = false
	local last_expr
	local block_depth
	local match_head = new_head_matcher(dep_function)
	for _, line in ipairs(lines) do
		local code = strip_comment(line)
		if not active then
			local indent, one_line = match_head(code)
			if indent ~= nil and not one_line then
				active, last_expr, block_depth = true, nil, 0
			end
		elseif code:match("^%s*end%s*$") then
			if block_depth == 0 then
				return last_expr and last_expr:match("^%s*([%a_][%w_]*)%s*$") or nil
			end
			block_depth = block_depth - 1
		else
			block_depth = block_depth + count_openers(code)
			if code:match("%S") then
				last_expr = code
			end
		end
	end
	return nil
end

-- Bracket/assignment tracker for the fallback parser. A dep tuple only counts
-- when it sits inside a list literal that is NOT the right-hand side of an
-- assignment, so `statuses = [{:ok, "x"}]` is excluded while the returned
-- `[{:jason, "~> 1.0"}]` is kept. The one exception is a list assigned to the
-- variable the function returns (`deps = [...]; deps`): `returned_var` names it so
-- that assignment is treated as a real dep list. `stack` holds one boolean per
-- open `[` (is it an excluded assignment list); `assign` counts the open excluded
-- assignment lists. `last_sig` / `prev_sig` persist across lines so a `[` opened
-- on the line after `x =` is still recognized as an assignment RHS; `last_ident` /
-- `cur_ident` track the identifier preceding `=` to match `returned_var`.
-- `assign_scope` is the indent of a statement whose RHS spans following lines (a
-- line ending in a bare `=`); those more-indented lines are that RHS and excluded
-- until indentation returns to the assignment's level. See `parse_lines`.
local function new_bracket_state(returned_var)
	return {
		stack = {},
		assign = 0,
		last_sig = "",
		prev_sig = "",
		last_ident = "",
		cur_ident = "",
		returned_var = returned_var,
		assign_scope = nil,
		col = 1,
		in_string = false,
		escaped = false,
	}
end

-- Advance the tracker through `code` up to (but excluding) column `to`,
-- continuing the per-line string scan from `state.col`. Brackets and quotes
-- inside string literals are ignored.
local function advance_brackets(state, code, to)
	while state.col < to do
		local ch = code:sub(state.col, state.col)
		if state.in_string then
			if state.escaped then
				state.escaped = false
			elseif ch == "\\" then
				state.escaped = true
			elseif ch == '"' then
				state.in_string = false
				state.prev_sig, state.last_sig = state.last_sig, '"'
			end
		elseif ch == '"' then
			state.in_string = true
			state.last_ident, state.cur_ident =
				state.cur_ident ~= "" and state.cur_ident or state.last_ident, ""
		elseif ch:match("[%w_]") then
			-- Accumulate identifier characters; the completed word preceding a `=`
			-- is the assignment target, compared against `returned_var` below.
			state.cur_ident = state.cur_ident .. ch
			state.prev_sig, state.last_sig = state.last_sig, ch
		elseif not ch:match("%s") then
			if state.cur_ident ~= "" then
				state.last_ident, state.cur_ident = state.cur_ident, ""
			end
			if ch == "[" then
				-- A single `=` (not `==`, `>=`, `<=`, `!=`, `~=`) before the list
				-- marks it as an assignment RHS.
				local p = state.prev_sig
				local is_assign = state.last_sig == "="
					and p ~= ">"
					and p ~= "<"
					and p ~= "!"
					and p ~= "~"
					and p ~= "="
				-- The list assigned to the variable the function returns is the dep
				-- list itself, so keep it rather than excluding it.
				if is_assign and state.returned_var and state.last_ident == state.returned_var then
					is_assign = false
				end
				state.stack[#state.stack + 1] = is_assign
				if is_assign then
					state.assign = state.assign + 1
				end
			elseif ch == "]" then
				local popped = state.stack[#state.stack]
				if popped ~= nil then
					state.stack[#state.stack] = nil
					if popped then
						state.assign = state.assign - 1
					end
				end
			end
			state.prev_sig, state.last_sig = state.last_sig, ch
		elseif state.cur_ident ~= "" then
			-- Whitespace ends an identifier without being a significant signal.
			state.last_ident, state.cur_ident = state.cur_ident, ""
		end
		state.col = state.col + 1
	end
end

-- Fallback for a mix.exs that inlines its deps list directly in project()
-- (no separate deps/0 function for the primary scan above to find), e.g.
-- `def project do [app: :demo, deps: [...]] end`. Activates the moment a
-- `deps:` keyword is directly followed by `[` (not a function call, which
-- `configured_dep_function` already routes to the primary path above), and
-- stays active until that list's own closing `]` — tracked with the same
-- bracket-depth bookkeeping `advance_brackets` uses elsewhere in this file —
-- rather than a def/defp `end`. Used only when the primary scan in
-- `M.parse_lines` finds no deps at all.
local function parse_inline_deps(lines)
	local deps = {}
	local active = false
	local brackets
	local pending
	for i, line in ipairs(lines) do
		local code = strip_comment(line)
		local search_pos = 1
		if not active then
			local match_start, open_end = code:find("deps%s*:%s*%[")
			if match_start then
				active = true
				brackets = new_bracket_state(nil)
				brackets.col = open_end + 1
				brackets.stack = { false }
				pending = nil
				search_pos = open_end + 1
			end
		else
			brackets.col = 1
			brackets.in_string = false
			brackets.escaped = false
		end
		if active then
			if pending then
				local lead, content = code:match('^(%s*)"([^"]*)"')
				if content then
					local quote_pos = #lead + 1
					local next_brace = code:find("{", quote_pos + #content + 2)
					local tuple_text = code:sub(1, next_brace and (next_brace - 1) or #code)
					deps[#deps + 1] = {
						name = pending.name,
						package = package_alias(tuple_text),
						requirement = content,
						kind = "hex",
						row = i - 1,
						col_start = quote_pos,
						col_end = quote_pos + #content,
					}
					search_pos = quote_pos + #content + 2
				end
				pending = nil
			end
			while true do
				local match_start, quote_pos, name = code:find(DEP_PATTERN, search_pos)
				if not name then
					break
				end
				advance_brackets(brackets, code, match_start)
				local in_dep_list = #brackets.stack > 0 and brackets.assign == 0
				if in_dep_list then
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
							col_start = quote_pos,
							col_end = quote_pos + #content,
						}
						search_pos = quote_pos + #content + 2
					else
						search_pos = quote_pos + 1
					end
				else
					search_pos = match_start + 1
				end
			end
			local pending_start, _, pending_name = code:find(PENDING_DEP_PATTERN, search_pos)
			if pending_name then
				advance_brackets(brackets, code, pending_start)
				local in_dep_list = #brackets.stack > 0 and brackets.assign == 0
				if in_dep_list then
					pending = { name = pending_name }
				end
			end
			advance_brackets(brackets, code, #code + 1)
			if #brackets.stack == 0 then
				active = false
			end
		end
	end
	return deps
end

--- Parse dependency tuples out of a list of lines (pure; no Neovim APIs).
--- Returns a list of dep tables with 0-indexed `row`, `col_start`, `col_end`.
function M.parse_lines(lines)
	local deps = {}
	local dep_function = configured_dep_function(lines)
	local returned_var = returned_variable(lines, dep_function)
	local active = false
	local function_indent
	local one_line = false
	local brackets
	local pending
	local block_depth
	local match_head = new_head_matcher(dep_function)
	for i, line in ipairs(lines) do
		local code = strip_comment(line)
		local just_activated = false
		if not active then
			function_indent, one_line = match_head(code)
			active = function_indent ~= nil
			if active then
				brackets = new_bracket_state(returned_var)
				pending = nil
				block_depth = 0
				just_activated = true
			end
		elseif code:match("^%s*end%s*$") then
			if block_depth == 0 then
				active = false
			else
				block_depth = block_depth - 1
			end
		end
		if active and not just_activated then
			block_depth = block_depth + count_openers(code)
		end
		if active then
			-- Per-line reset of the string scan; the bracket stack and last_sig
			-- persist across lines so multi-line lists are tracked correctly.
			brackets.col = 1
			brackets.in_string = false
			brackets.escaped = false
			-- Multi-line assignment scope. The per-token `=`-before-`[` check only sees
			-- the `=` when it is the most recent significant token, so a block-valued
			-- assignment whose list sits past intervening tokens
			-- (`meta =\n  if true do\n    [..]\n  end`) is missed. Track such an
			-- assignment by the indent of its `x =` line: more-indented lines are its
			-- RHS and excluded, until indentation returns to that level (a new
			-- statement). Blank lines neither end nor belong to the scope.
			local indent = #code:match("^%s*")
			if code:match("%S") and brackets.assign_scope and indent <= brackets.assign_scope then
				brackets.assign_scope = nil
			end
			local in_assign_scope = brackets.assign_scope ~= nil
			-- Scan the entire line for dep tuples: a single line may hold multiple
			-- entries (e.g. compact `do:` form). For each match we extract the
			-- requirement from that specific tuple and scope the alias search to the
			-- text between this tuple's `{` and the next one.
			local search_pos = 1
			-- A dep tuple opened on a previous line (name + comma, then the
			-- requirement string wrapped to this line). If this line's leading
			-- (possibly indented) text is a quoted string, it's that requirement;
			-- otherwise give up on the pending tuple without emitting anything.
			if pending then
				local lead, content = code:match('^(%s*)"([^"]*)"')
				if content then
					local quote_pos = #lead + 1
					local next_brace = code:find("{", quote_pos + #content + 2)
					local tuple_text = code:sub(1, next_brace and (next_brace - 1) or #code)
					deps[#deps + 1] = {
						name = pending.name,
						package = package_alias(tuple_text),
						requirement = content,
						kind = "hex",
						row = i - 1,
						col_start = quote_pos,
						col_end = quote_pos + #content,
					}
					search_pos = quote_pos + #content + 2
				end
				pending = nil
			end
			while true do
				local match_start, quote_pos, name = code:find(DEP_PATTERN, search_pos)
				if not name then
					break
				end
				-- A tuple counts only when it sits inside a non-assignment list, so
				-- `meta = {:ok, "v"}` and `statuses = [{:ok, "v"}]` are both excluded.
				advance_brackets(brackets, code, match_start)
				local in_dep_list = #brackets.stack > 0
					and brackets.assign == 0
					and not in_assign_scope
				if in_dep_list then
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
			-- A dep tuple whose name+comma end the line, with its requirement string
			-- wrapped to the next line (e.g. a long package name `mix format` wraps).
			-- Sync the bracket state up to the match and check dep-list membership the
			-- same way the inline-match branch above does, then remember the name so
			-- the next line's leading quoted string can be paired with it.
			local pending_start, _, pending_name = code:find(PENDING_DEP_PATTERN, search_pos)
			if pending_name then
				advance_brackets(brackets, code, pending_start)
				local in_dep_list = #brackets.stack > 0
					and brackets.assign == 0
					and not in_assign_scope
				if in_dep_list then
					pending = { name = pending_name }
				end
			end
			-- Finish scanning the line so closing brackets are accounted for before
			-- the next line continues the bracket stack.
			advance_brackets(brackets, code, #code + 1)
			-- A line ending in a bare `=` opens a multi-line assignment RHS. Record its
			-- indent so following, more-indented lines are excluded — unless the target
			-- is the variable the function returns, whose assigned list IS the dep list
			-- (handled by the per-token `returned_var` check) or unless a scope is
			-- already open (keep the outermost so nested assignments stay excluded).
			if not in_assign_scope and brackets.assign_scope == nil then
				local target = code:match("([%a_][%w_!?]*)%s*=%s*$")
				if target and target ~= returned_var then
					brackets.assign_scope = indent
				end
			end
			if one_line then
				active = false
			end
		end
	end
	if #deps == 0 then
		local inline = parse_inline_deps(lines)
		if #inline > 0 then
			return inline
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
	local keywords = child_of_type(list_node, "keywords")
	if not keywords then
		return nil
	end
	for i = 0, keywords:named_child_count() - 1 do
		local pair = keywords:named_child(i)
		if pair:type() == "pair" then
			local key = pair:named_child(0)
			local value = pair:named_child(1)
			if key and value and node_text(key, bufnr):match("^deps%s*:%s*$") then
				return value
			end
		end
	end
	return nil
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
		local project_body = find_definition(tree:root(), bufnr, "project")
		if project_body then
			local project_list = return_expression(project_body, bufnr)
			local deps_value = find_deps_pair_value(project_list, bufnr)
			if deps_value and deps_value:type() == "list" then
				body = deps_value
			end
		end
	end
	if not body then
		return {}
	end
	local deps = {}
	local current
	-- iter_captures(node, source, start_row, end_row): yields capture id + node in
	-- document order, so each @name precedes its sibling @req within a tuple.
	for id, node in query:iter_captures(return_expression(body, bufnr), bufnr, 0, -1) do
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
