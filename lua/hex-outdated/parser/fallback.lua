-- The pattern-matching fallback backend: finds dependency tuples in raw source
-- lines, with no Neovim APIs and no Tree-sitter. Used when the Elixir
-- Tree-sitter parser is unavailable, and directly by `parser.parse_lines`.
--
-- Every judgment about what is code and what is literal text comes from
-- `parser.lexer`. This module contributes the structure layered on top --
-- module ranges, function heads, block scoping, bracket and assignment
-- tracking -- and emits records through `parser.dep`.
--
-- The one character scanner that stays here is `advance_brackets`, which must
-- be resumable across several calls within a single line and so cannot use
-- `literal_span`'s look-ahead. It opens literals with the shared
-- `lexer.sigil_delim` primitive and applies the same nesting and escaping rules
-- documented alongside it.
--
-- Pure Lua: no Neovim APIs, no module-level state.

local lexer = require("hex-outdated.parser.lexer")
local dep = require("hex-outdated.parser.dep")

local strip_comment = lexer.strip_comment
local mask_heredocs = lexer.mask_heredocs
local count_openers = lexer.count_openers
local count_closers = lexer.count_closers
local block_delta = lexer.block_delta
local sigil_delim = lexer.sigil_delim
local configured_dep_function = dep.configured_dep_function
local new_record = dep.new_record

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

-- Line ranges of every `defmodule ... do ... end` block in the file, as
-- { first = the `defmodule` line, last = its matching `end` line }, both
-- 1-indexed and inclusive. Nesting is tracked by the net opener/closer count per
-- line, so a block whose keywords do not balance (an unterminated module, say)
-- is simply never recorded and callers degrade to whole-file scanning. Blocks
-- are appended as they close, so inner modules always precede their parents.
local function module_ranges(lines)
	local stack = {}
	local ranges = {}
	for i, line in ipairs(lines) do
		local code = strip_comment(line)
		local net = count_openers(code) - count_closers(code)
		if net > 0 then
			-- The first opener on a `defmodule` line is the module's own `do`; any
			-- others (a trailing `fn`, say) nest inside it.
			local is_module = code:match("^%s*defmodule%f[%W]") ~= nil
			for k = 1, net do
				stack[#stack + 1] = { first = i, module = is_module and k == 1 }
			end
		elseif net < 0 then
			for _ = 1, -net do
				local top = table.remove(stack)
				if not top then
					break
				end
				if top.module then
					ranges[#ranges + 1] = { first = top.first, last = i }
				end
			end
		end
	end
	return ranges
end

-- The set of line numbers belonging to the module that defines `project/0`
-- (`project_line` is that definition's head line), excluding any module nested
-- inside it. Dependency-function lookup is restricted to these lines so a
-- same-named zero-arity function in some other module — earlier, later, or
-- nested — never wins. Returns nil when no enclosing `defmodule` block can be
-- identified, in which case callers scan the whole file as they did before.
local function module_scope(lines, project_line)
	local ranges = module_ranges(lines)
	local owner
	for _, range in ipairs(ranges) do
		if range.first <= project_line and project_line <= range.last then
			owner = range -- innermost, since inner modules are recorded first
			break
		end
	end
	if not owner then
		return nil
	end
	local scope = {}
	for i = owner.first, owner.last do
		scope[i] = true
	end
	for _, range in ipairs(ranges) do
		if range ~= owner and owner.first < range.first and range.last <= owner.last then
			for i = range.first, range.last do
				scope[i] = nil
			end
		end
	end
	return scope
end

-- A nil scope means "no module restriction" (see `module_scope`).
local function in_scope(scope, i)
	return scope == nil or scope[i] == true
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
	-- A zero-arity head whose signature closed with nothing but a trailing
	-- comma (no `do:` yet on that same line) -- e.g. `defp deps(),` or
	-- `defp deps,`, wrapped so the keyword-form body's `do:` starts on the
	-- next line. Only that next line can resolve this: a leading `do:`
	-- confirms the keyword-form match; anything else gives up rather than
	-- guessing block form. Kept separate from `pending`, which accumulates a
	-- still-open multi-line signature -- this instead awaits the line after
	-- an already-closed one.
	local pending_do -- { indent = ... }
	return function(line)
		if pending_do then
			local indent = pending_do.indent
			pending_do = nil
			if line:match("^%s*do%s*:") then
				return indent, true
			end
			return nil
		end
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
			if after:find(",%s*do%s*:") then
				return indent, true
			end
			if after:match("^%s*,%s*$") then
				pending_do = { indent = indent }
				return nil
			end
			return indent, false
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
			if line:find(",%s*do%s*:") then
				return indent, true
			end
			if after:match("^%s*,%s*$") then
				pending_do = { indent = indent }
				return nil
			end
			return indent, false
		end
		local before, tail = paren_rest:match("^(.-)%)(.*)$")
		if not before then
			pending = { indent = indent, parts = { paren_rest } }
			return nil
		end
		if before:match("%S") then
			return nil
		end
		if tail:find(",%s*do%s*:") then
			return indent, true
		end
		if tail:match("^%s*,%s*$") then
			pending_do = { indent = indent }
			return nil
		end
		return indent, false
	end
end

-- Locate the file's zero-arity `project/0` definition — the anchor for all
-- dependency discovery, since the dep list is whatever `project/0` names.
-- Returns the head line plus the inclusive line range of its body, all
-- 1-indexed, or nil when no `project/0` head can be found. For the one-line
-- `def project, do: ...` form the head line *is* the body. For the block form
-- the body runs to the matching `end`, found with the same nested-block
-- accounting the dep-function scanners use.
local function locate_project(lines)
	local match_head = new_head_matcher("project")
	for i, line in ipairs(lines) do
		local indent, one_line = match_head(strip_comment(line))
		if indent ~= nil then
			if one_line then
				return i, i, i
			end
			local block_depth = 0
			for j = i + 1, #lines do
				local code = strip_comment(lines[j])
				local new_depth, closed = block_delta(block_depth, code)
				if closed then
					-- The body excludes the line carrying the closing token, even when
					-- that token is decorated (`end)`) rather than a bare `end` line.
					return i, i + 1, j - 1
				end
				block_depth = new_depth
			end
			return i, i + 1, #lines
		end
	end
	return nil
end

-- The bare-identifier expression returned by a function body, e.g. the final
-- `deps` in `defp deps do\n  deps = [...]\n  deps\nend`. When present, the list
-- assigned to that variable IS the dependency list and must not be excluded as a
-- plain assignment RHS. Returns nil when the body's last expression is not a bare
-- variable (e.g. a list literal or a composed `base() ++ [...]`).
--
-- `scope` restricts which lines may start a `dep_function` definition, exactly as
-- in `parse_lines`, so a same-named function in another module is not inspected.
local function returned_variable(lines, dep_function, scope)
	local active = false
	local last_expr
	local block_depth
	local match_head = new_head_matcher(dep_function)
	for i, line in ipairs(lines) do
		local code = strip_comment(line)
		if not active then
			if in_scope(scope, i) then
				local indent, one_line = match_head(code)
				if indent ~= nil and not one_line then
					active, last_expr, block_depth = true, nil, 0
				end
			end
		else
			local new_depth, closed = block_delta(block_depth, code)
			if closed then
				return last_expr and last_expr:match("^%s*([%a_][%w_]*)%s*$") or nil
			end
			block_depth = new_depth
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
		-- Charlist/sigil tracking (issue #69): while `in_literal` is true,
		-- `literal_open`/`literal_close` name the delimiter pair (equal for a
		-- charlist and a same-character sigil form; different for a paired
		-- sigil form), `literal_nests` says whether a nested `literal_open`
		-- increases `literal_depth` rather than being ordinary text, and
		-- `literal_depth` is the current nesting depth (closes at 0).
		in_literal = false,
		literal_open = nil,
		literal_close = nil,
		literal_nests = false,
		literal_depth = 0,
	}
end

-- Advance the tracker through `code` up to (but excluding) column `to`,
-- continuing the per-line string scan from `state.col`. Brackets, quotes, and
-- keywords inside string literals, charlists, and single-line sigils are
-- ignored (issue #69 added the latter two; see `new_bracket_state`'s literal
-- fields). A charlist/sigil is detected the same way `literal_span` (used by
-- `strip_comment`/`mask_strings` in `parser.lexer`) detects one, via the shared
-- `lexer.sigil_delim` primitive, but its close is tracked char-by-char in
-- `state` rather than found by scanning ahead, since this function must remain
-- resumable across multiple calls within one line -- exactly how
-- `state.in_string` already works for `"..."`.
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
		elseif state.in_literal then
			if state.escaped then
				state.escaped = false
			elseif ch == "\\" then
				state.escaped = true
			elseif state.literal_nests and ch == state.literal_open then
				state.literal_depth = state.literal_depth + 1
			elseif ch == state.literal_close then
				state.literal_depth = state.literal_depth - 1
				if state.literal_depth == 0 then
					state.in_literal = false
					state.prev_sig, state.last_sig = state.last_sig, ch
				end
			end
		elseif ch == '"' then
			state.in_string = true
			state.last_ident, state.cur_ident =
				state.cur_ident ~= "" and state.cur_ident or state.last_ident, ""
		elseif ch == "'" then
			state.in_literal = true
			state.literal_open, state.literal_close, state.literal_nests, state.literal_depth =
				"'", "'", false, 1
			state.last_ident, state.cur_ident =
				state.cur_ident ~= "" and state.cur_ident or state.last_ident, ""
		elseif ch == "~" then
			local open_idx, close_char, nests = sigil_delim(code, state.col)
			if open_idx then
				-- Jump straight to the opening delimiter: the "~" and the
				-- sigil-name letters between it and `open_idx` need no
				-- per-character handling, matching how the `"` branch above
				-- moves straight into string mode on the quote itself.
				state.col = open_idx
				state.in_literal = true
				state.literal_open, state.literal_close, state.literal_nests, state.literal_depth =
					code:sub(open_idx, open_idx), close_char, nests, 1
				state.last_ident, state.cur_ident =
					state.cur_ident ~= "" and state.cur_ident or state.last_ident, ""
			else
				-- Not a sigil prefix; treat "~" as ordinary significant
				-- punctuation, same as the generic branch below.
				if state.cur_ident ~= "" then
					state.last_ident, state.cur_ident = state.cur_ident, ""
				end
				state.prev_sig, state.last_sig = state.last_sig, ch
			end
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
-- `parse_lines` finds no deps at all. `scope` restricts which lines may open
-- such a list, so an inline `deps: [...]` belonging to some other module is not
-- mistaken for the project's dependencies.
local function parse_inline_deps(lines, scope)
	local deps = {}
	local active = false
	local brackets
	local pending
	for i, line in ipairs(lines) do
		local code = strip_comment(line)
		local search_pos = 1
		if not active then
			local match_start, open_end
			if in_scope(scope, i) then
				match_start, open_end = code:find("deps%s*:%s*%[")
			end
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
			brackets.in_literal = false
			brackets.literal_depth = 0
		end
		if active then
			if pending then
				local lead, content = code:match('^(%s*)"([^"]*)"')
				if content then
					local quote_pos = #lead + 1
					local next_brace = code:find("{", quote_pos + #content + 2)
					local tuple_text = code:sub(1, next_brace and (next_brace - 1) or #code)
					deps[#deps + 1] = new_record({
						name = pending.name,
						tuple_text = tuple_text,
						requirement = content,
						row = i - 1,
						col_start = quote_pos,
						col_end = quote_pos + #content,
					})
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
						deps[#deps + 1] = new_record({
							name = name,
							tuple_text = tuple_text,
							requirement = content,
							row = i - 1,
							col_start = quote_pos,
							col_end = quote_pos + #content,
						})
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
local function parse_lines(lines)
	local deps = {}
	-- Neutralise heredoc bodies once, up front, and scan `masked` (not `lines`)
	-- from here on. `masked` has the same length and line indices as `lines`
	-- (see `mask_heredocs`), so every `row`/line-range value computed below
	-- still refers to the correct original line.
	local masked = mask_heredocs(lines)
	-- Anchor discovery on `project/0`: its body names the dep function, and its
	-- module bounds where that function may be defined. When `project/0` cannot be
	-- located both narrowings fall away and the scan behaves exactly as before.
	local project_line, project_first, project_last = locate_project(masked)
	local dep_function = configured_dep_function(masked, project_first, project_last)
	local scope = project_line and module_scope(masked, project_line) or nil
	local returned_var = returned_variable(masked, dep_function, scope)
	local active = false
	local function_indent
	local one_line = false
	local brackets
	local pending
	local block_depth
	local match_head = new_head_matcher(dep_function)
	for i, line in ipairs(masked) do
		local code = strip_comment(line)
		if not active then
			if in_scope(scope, i) then
				function_indent, one_line = match_head(code)
				active = function_indent ~= nil
			end
			if active then
				brackets = new_bracket_state(returned_var)
				pending = nil
				block_depth = 0
			end
		else
			local new_depth, closed = block_delta(block_depth, code)
			if closed then
				active = false
			else
				block_depth = new_depth
			end
		end
		if active then
			-- Per-line reset of the string scan; the bracket stack and last_sig
			-- persist across lines so multi-line lists are tracked correctly.
			-- Charlists and sigils are single-line-only for this parser (issue
			-- #69), so `in_literal` resets here too, exactly like `in_string`.
			brackets.col = 1
			brackets.in_string = false
			brackets.escaped = false
			brackets.in_literal = false
			brackets.literal_depth = 0
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
					deps[#deps + 1] = new_record({
						name = pending.name,
						tuple_text = tuple_text,
						requirement = content,
						row = i - 1,
						col_start = quote_pos,
						col_end = quote_pos + #content,
					})
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
						deps[#deps + 1] = new_record({
							name = name,
							tuple_text = tuple_text,
							requirement = content,
							row = i - 1,
							col_start = quote_pos, -- 0-indexed position just inside the opening quote
							col_end = quote_pos + #content, -- 0-indexed, exclusive end (the closing quote)
						})
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
		local inline = parse_inline_deps(masked, scope)
		if #inline > 0 then
			return inline
		end
	end
	return deps
end

return {
	parse_lines = parse_lines,
}
