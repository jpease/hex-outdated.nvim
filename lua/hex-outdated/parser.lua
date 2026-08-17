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

-- Cross-line state that lets the per-line scanners below (`strip_comment`,
-- `mask_strings`, `advance_brackets`, and the block-depth accounting built on
-- top of them) treat a heredoc's entire body as inert, rather than as
-- executable code. `mask_heredocs` is the single place that decides what is
-- and is not inside a heredoc; `M.parse_lines` computes it once and threads
-- the result through every scanner that would otherwise see raw `lines`, so
-- they cannot drift out of sync the way three independent block-depth
-- trackers did before #63.

-- True when `text`, scanned with the same in_string/escaped double-quote
-- convention `strip_comment` uses, ends inside an open ordinary string
-- literal. Used by `heredoc_opener` below so a triple-quote that is actually
-- part of an ordinary string's escaped text (`x = "say \"\"\" here"`) is never
-- mistaken for a heredoc opener. Only tracks `"`, matching every other
-- per-line scanner in this file; unbalanced single-quote text ahead of a
-- `'''` opener is not specially guarded against, since charlists are not
-- string-scanned anywhere else in this file either.
local function ends_inside_string(text)
	local in_string, escaped = false, false
	for i = 1, #text do
		local char = text:sub(i, i)
		if escaped then
			escaped = false
		elseif char == "\\" and in_string then
			escaped = true
		elseif char == '"' then
			in_string = not in_string
		end
	end
	return in_string
end

-- The heredoc delimiter opened by `code`, or nil. `"""` opens a string
-- heredoc and `'''` opens a charlist heredoc; both remain valid Elixir syntax
-- through at least 1.20. A candidate delimiter opens a heredoc only when
-- nothing but whitespace follows it to end of line (the real Elixir rule) and
-- it is not itself sitting inside an ordinary double-quoted string opened
-- earlier on the same line (`ends_inside_string`). Together these also
-- correctly reject a single-line `"""a"""`: its first `"""` has trailing
-- non-whitespace text (`a"""`), and its second `"""` sits inside the "string"
-- the first one opened. A sigil prefix (`~s"""`, `~S"""`, or any other
-- `~<letter>"""`) needs no special-casing: the sigil is just ordinary text
-- ahead of the delimiter and does not affect either check, so every
-- sigil-prefixed heredoc opener is already covered by this same rule.
local function heredoc_opener(code)
	for _, delim in ipairs({ '"""', "'''" }) do
		local pos = 1
		while true do
			local s, e = code:find(delim, pos, true)
			if not s then
				break
			end
			if code:sub(e + 1):match("^%s*$") and not ends_inside_string(code:sub(1, s - 1)) then
				return delim
			end
			pos = s + 1
		end
	end
	return nil
end

-- Neutralise heredoc bodies across the whole file in one pass, returning a NEW
-- array of the same length as `lines` (so every line's index — and every
-- `row`/line-range value derived from it downstream — is unaffected).
--
--   - The opener line is returned unchanged. Everything up to the opening
--     delimiter is ordinary code (kept verbatim, so a dep tuple sharing the
--     line keeps its exact columns), and everything after it is, by
--     `heredoc_opener`'s own rule, pure trailing whitespace — masking it
--     would be a no-op.
--   - Body lines become empty strings. A heredoc body can never legitimately
--     contain a dep tuple, so blanking it cannot lose a real dependency, and
--     an empty line is inert to every scanner below: no `do`/`fn`/`end`, no
--     `#`, no unmatched `"`, no `[`/`]`.
--   - The closing line has its leading whitespace and the delimiter itself
--     replaced with spaces of the same length, preserving the column
--     positions of whatever legitimately follows on the same physical line
--     (Elixir resumes ordinary tokenizing immediately after a heredoc's
--     closing delimiter, e.g. `""" <> "y"` or `""")`).
--
-- An unterminated heredoc (no matching closer before end of file) masks every
-- remaining line to end of file; real Elixir would fail to compile such a
-- file at all, so there is no "real" behavior to preserve past that point.
local function mask_heredocs(lines)
	local masked = {}
	local delim
	for i, line in ipairs(lines) do
		if delim then
			local prefix, tail = line:match("^(%s*" .. delim .. ")(.*)$")
			if prefix then
				masked[i] = string.rep(" ", #prefix) .. tail
				delim = nil
			else
				masked[i] = ""
			end
		else
			masked[i] = line
			delim = heredoc_opener(line)
		end
	end
	return masked
end

-- Replace the contents of double-quoted string literals in `code` with spaces,
-- preserving length (and the quotes themselves) so column offsets elsewhere
-- stay meaningful. Used by `count_openers` below so a "do" or "fn" inside a
-- string's text (e.g. a SemVer pre-release tag like "== 1.0.0-do") is never
-- mistaken for a block-opening keyword. Uses the same in_string/escaped
-- string-scan convention as `strip_comment` and `advance_brackets`. Like both
-- of those, this scans one physical line at a time; multi-line heredocs are
-- handled upstream by `mask_heredocs`, whose output is what every caller in
-- this file actually scans, so a line reaching this function either isn't
-- part of a heredoc or has already been neutralized to whitespace / an empty
-- string.
local function mask_strings(code)
	local out = {}
	local in_string = false
	local escaped = false
	for i = 1, #code do
		local char = code:sub(i, i)
		if escaped then
			out[i] = " "
			escaped = false
		elseif char == "\\" and in_string then
			out[i] = " "
			escaped = true
		elseif char == '"' then
			in_string = not in_string
			out[i] = char
		elseif in_string then
			out[i] = " "
		else
			out[i] = char
		end
	end
	return table.concat(out)
end

-- Frontier pair for scanning a bare keyword ("do", "fn", "end") as a whole
-- token. Elixir identifiers may contain "_", but Lua's `%w` class does not,
-- so a plain `%f[%w]...%f[%W]` frontier fires *across* an underscore: both
-- `do_thing` (prefix) and `fetch_do` (suffix) would present a boundary at the
-- "do" they merely contain. Treating "_" as a word character in both
-- directions closes that gap (issue #58) while leaving every other boundary
-- — whitespace, punctuation, start/end of line — unaffected.
local KEYWORD_OPEN = "%f[%w_]"
local KEYWORD_CLOSE = "%f[^%w_]"

-- Count occurrences of `word` as a whole token in already string-masked
-- `masked` text (see `mask_strings`), calling `guard(masked, s, e)` for each
-- match (1-indexed, inclusive `s`/`e`) and counting it only when `guard`
-- returns true or is omitted. Shared by `count_openers` and `count_closers`
-- below so the underscore-aware frontier pair is defined once rather than
-- repeated across the `do`, `fn`, and `end` scans.
local function count_keyword(masked, word, guard)
	local pattern = KEYWORD_OPEN .. word .. KEYWORD_CLOSE
	local count = 0
	local pos = 1
	while true do
		local s, e = masked:find(pattern, pos)
		if not s then
			break
		end
		if not guard or guard(masked, s, e) then
			count = count + 1
		end
		pos = e + 1
	end
	return count
end

-- A keyword immediately preceded by ":" (no space) is a bare atom literal
-- (e.g. `only: :do`), not a keyword, and is excluded; a quoted atom
-- (`:"do"`) is already handled by the string mask in `mask_strings`.
local function not_bare_atom(masked, s)
	return masked:sub(s - 1, s - 1) ~= ":"
end

-- As `not_bare_atom`, but also excludes a keyword immediately followed by
-- ":" — the `do:`/`end:` keyword-list form (e.g. one-line `do:` syntax).
-- Only "do" and "end" have such a form; "fn" does not, so it uses
-- `not_bare_atom` alone.
local function not_bare_atom_or_keyword_form(masked, s, e)
	return not_bare_atom(masked, s) and masked:sub(e + 1, e + 1) ~= ":"
end

-- Count block-opening keywords ("do" starting a do/end block, and "fn" for an
-- anonymous function) in `code`, as whole tokens. Used to track nested-block
-- depth so a bare "end" line only closes the dep function when it isn't
-- closing an inner if/case/cond/unless/with/for/receive/try/fn block —
-- Elixir's indentation is not semantically significant, so indentation alone
-- can't tell them apart. String-literal contents are masked first (see
-- `mask_strings`) so a "do"/"fn" inside a requirement string never counts.
local function count_openers(code)
	local masked = mask_strings(code)
	return count_keyword(masked, "do", not_bare_atom_or_keyword_form)
		+ count_keyword(masked, "fn", not_bare_atom)
end

-- Count block-closing `end` keywords in `code`, as whole tokens, applying the
-- same string masking and bare-atom (`:end` / `end:`) exclusions `count_openers`
-- applies to `do`. Paired with `count_openers` by `module_ranges` below, and by
-- `block_delta` below that, to track nested-block depth via each line's net
-- opener/closer delta.
local function count_closers(code)
	local masked = mask_strings(code)
	return count_keyword(masked, "end", not_bare_atom_or_keyword_form)
end

-- Apply one line's net opener/closer delta (`count_openers` minus `count_closers`)
-- to `depth`, the running nesting depth inside a block being scanned line-by-line,
-- where 0 means "directly in the block's own body" (the block's own head line,
-- e.g. `defp deps do`, is never passed here — see each caller's own
-- "just activated" guard). Returns the updated depth and whether this line's
-- delta would drive it below zero, i.e. this line carries the tracked block's
-- own closing `end`, however it is decorated: `end)`, `end,`, a same-line
-- `fn ... end` (net zero, so not a close), multiple closers on one line, or a
-- bare `end` line (net -1).
--
-- Net-per-line, not token-order-aware within the line: a line that both closes
-- and opens (`end) |> case do`) is resolved by summing, not by the order the
-- tokens appear in. This is sound for real mix.exs input because nothing
-- meaningful can follow a def's own closing `end` on the same physical line in
-- valid Elixir — that `end` closes the def itself, so no further token can be
-- attached to it as a continuation of the same statement. Order therefore only
-- matters for contrived, not realistic, same-line mixes, and is intentionally
-- left unhandled (see issue #63's discussion of this tradeoff).
--
-- Shared by `locate_project`, `returned_variable`, and `M.parse_lines` so the
-- three scanners cannot drift out of sync with each other again (#63); each
-- keeps its own action on close, since a returned range, a returned value, and
-- a flag flip are not interchangeable.
local function block_delta(depth, code)
	local net = count_openers(code) - count_closers(code)
	local new_depth = depth + net
	return new_depth, new_depth < 0
end

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

-- Scan for a custom dependency function referenced as `deps: name(...)`. The
-- keyword's value can wrap onto a following line (e.g. `[deps:\n  project_deps()]`,
-- valid Elixir), so the search runs against all lines joined with "\n" rather than
-- one physical line at a time — `%s` in a Lua pattern already matches "\n", so the
-- existing pattern needs no change beyond having the newlines available to match
-- against. The pattern still anchors immediately to the text following `deps:`:
-- it requires a bare identifier directly (modulo whitespace only) followed by an
-- opening paren, so an inline list value wrapped onto the next line
-- (`deps:\n  [...]`) never matches here (`[` cannot start the identifier class)
-- and continues to route to `parse_inline_deps` / the Treesitter
-- `find_deps_pair_value` path instead.
--
-- `first`/`last` narrow the search to `project/0`'s own body when that body can
-- be located (see `locate_project` for the fallback path; `parse_treesitter`
-- derives the same window from the `project` node's own range), so
-- `deps: name()` text anywhere else in the file — most importantly inside a
-- string or docstring — can never redirect the lookup. They default to the
-- whole file, which is what callers pass when no `project/0` is available to
-- anchor on.
local function configured_dep_function(lines, first, last)
	local stripped = {}
	for i = first or 1, last or #lines do
		stripped[#stripped + 1] = strip_comment(lines[i])
	end
	local name = table.concat(stripped, "\n"):match("deps%s*:%s*([%a_][%w_!?]*)%s*%(")
	return name or "deps"
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

local function package_alias(text)
	return text:match("hex%s*:%s*:([%w_]+)")
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
-- `M.parse_lines` finds no deps at all. `scope` restricts which lines may open
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
		local inline = parse_inline_deps(masked, scope)
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
		-- `M.parse_lines` narrows via `locate_project`'s line range — otherwise a
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
