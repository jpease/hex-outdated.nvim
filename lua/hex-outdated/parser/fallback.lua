-- Line-scanning backend used when the Tree-sitter elixir parser is missing or
-- the tree has errors. Pure Lua; no Neovim APIs.

local lexer = require("hex-outdated.parser.lexer")
local new_record = require("hex-outdated.parser.dep").new_record

-- `{:name, "` (or a quoted `:"name"`): a name atom immediately followed by a string.
local DEP_PATTERN = '{%s*:(["\']?)([%w_]+)%1%s*,%s*"'

-- A tuple must open on the scanned line but may wrap onto this many more.
local TUPLE_LOOKAHEAD = 2

-- Index-aligned views of the source: `code` has heredoc bodies blanked and
-- comments stripped, `masked` is `code` with literals masked, `net` is each
-- line's block depth change.
local function prepare(lines)
	local src = { code = {}, masked = {}, net = {} }
	for i, line in ipairs(lexer.mask_heredocs(lines)) do
		local code = lexer.strip_comment(line)
		local masked = lexer.mask_literals(code)
		src.code[i], src.masked[i], src.net[i] = code, masked, lexer.block_delta(masked)
	end
	return src
end

-- Converts an offset into the "\n"-join of `src.code` starting at line `i`
-- into a line number and column.
local function locate(src, i, pos)
	while pos > #src.code[i] + 1 do
		pos = pos - #src.code[i] - 1
		i = i + 1
	end
	return i, pos
end

-- Line and column of the bracket closing the one opened at line `i`, column
-- `s` (or of the first unmatched closer); the end of the source if none.
local function bracket_close(src, i, s)
	local depth = 0
	for j = i, #src.masked do
		local masked = src.masked[j]
		local k = j == i and s or 1
		while true do
			k = masked:find("[%[%]{}()]", k)
			if not k then
				break
			end
			depth = depth + (masked:sub(k, k):match("[%[{(]") and 1 or -1)
			if depth <= 0 then
				return j, k
			end
			k = k + 1
		end
	end
	return #src.masked, #src.masked[#src.masked]
end

-- Source text of the tuple whose `{` is at line `i`, column `s`.
local function tuple_text(src, i, s)
	local j, k = bracket_close(src, i, s)
	local text = table.concat(src.code, "\n", i, j)
	return text:sub(s, #text - #src.code[j] + k)
end

-- Last line of a `, do:` body starting on line `i`: where its brackets balance.
local function keyword_body_end(src, i)
	local depth = 0
	for j = i, #src.masked do
		local _, opens = src.masked[j]:gsub("[%[{(]", "")
		local _, closes = src.masked[j]:gsub("[%]})]", "")
		depth = depth + opens - closes
		if depth <= 0 then
			return j
		end
	end
	return #src.masked
end

-- Line ranges ({ first, last }) of every `defmodule` block, inner modules
-- before their parents. Unbalanced blocks are not recorded.
local function module_ranges(src)
	local stack = {}
	local ranges = {}
	for i, net in ipairs(src.net) do
		if net > 0 then
			-- A `defmodule` line's first opener is the module's own `do`.
			local is_module = src.masked[i]:match("^%s*defmodule%f[%W]") ~= nil
			for k = 1, net do
				stack[#stack + 1] = { first = i, module = is_module and k == 1 }
			end
		else
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

-- Set of lines in the innermost module containing line `head`, minus modules
-- nested in it; nil when no module encloses it.
local function module_scope(src, head)
	local ranges = module_ranges(src)
	local owner
	for _, range in ipairs(ranges) do
		if range.first <= head and head <= range.last then
			owner = range
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

-- Matcher fed consecutive masked lines; returns "block" or "keyword" on the
-- line that completes a zero-arity `def`/`defp name` head, else nil.
local function head_matcher(name)
	local params -- parameter text of a head still awaiting its ")"
	local awaiting_do = false -- head ended in ","; its `do:` must open the next line

	local function classify(tail)
		if tail:find("^%s*,%s*do%s*:") then
			return "keyword"
		elseif tail:match("^%s*,%s*$") then
			awaiting_do = true
			return nil
		end
		return "block"
	end

	return function(line)
		if awaiting_do then
			awaiting_do = false
			return line:match("^%s*do%s*:") and "keyword" or nil
		end
		local before, tail
		if params then
			before, tail = line:match("^(.-)%)(.*)$")
			if not before then
				params[#params + 1] = line
				return nil
			end
			params[#params + 1] = before
			before, params = table.concat(params), nil
		else
			local declared, after = line:match("^%s*defp?%s+([%w_!?]+)(.*)")
			if declared ~= name then
				return nil
			end
			local inner = after:match("^%s*%((.*)$")
			if not inner then
				return classify(after)
			end
			before, tail = inner:match("^(.-)%)(.*)$")
			if not before then
				params = { inner }
				return nil
			end
		end
		if before:match("%S") then
			return nil
		end
		return classify(tail)
	end
end

-- The first zero-arity `name` definition whose head is in `scope` (nil: whole
-- file): its head line, the last line of its body, and its form.
local function find_definition(src, name, scope)
	local match_head = head_matcher(name)
	for i, masked in ipairs(src.masked) do
		if scope == nil or scope[i] then
			local kind = match_head(masked)
			if kind == "keyword" then
				return i, keyword_body_end(src, i), kind
			elseif kind == "block" then
				local depth = src.net[i] - 1
				if depth < 0 then
					return i, i, kind
				end
				for j = i + 1, #src.net do
					depth = depth + src.net[j]
					if depth < 0 then
						return i, j - 1, kind
					end
				end
				return i, #src.net, kind
			end
		end
	end
	return nil
end

-- Where the dep list lives, judged from the first `deps:` key in lines
-- first..last: `{ name = fn }` for `deps: fn()`, `{ line, col }` of an inline
-- `[`, nil for any other value, and the `deps/0` function when there is no key.
-- A value composed with `++` resolves through its leading operand.
local function deps_source(src, first, last)
	local text = table.concat(src.masked, "\n", first, last)
	local _, key_end = text:find("%f[%w_]deps%s*:")
	if not key_end then
		return { name = "deps" }
	end
	local name, rest = text:match("^%s*([%l_][%w_!?]*)%s*%(%s*%)()", key_end + 1)
	if
		name
		and (
			text:find("^%s*[,%])]", rest)
			or text:find("^%s*$", rest)
			or text:find("^%s*%+%+", rest)
		)
	then
		return { name = name }
	end
	local bracket = text:match("^%s*()%[", key_end + 1)
	if bracket then
		local line, col = locate(src, first, bracket)
		return { line = line, col = col }
	end
	return nil
end

-- The variable a block body returns when its last expression is a bare name.
local function returned_variable(src, head, last)
	for j = last, head + 1, -1 do
		if src.code[j]:match("%S") then
			return src.code[j]:match("^%s*([%a_][%w_]*)%s*$")
		end
	end
	return nil
end

-- Bracket/assignment tracker. A tuple counts only inside a list that is not
-- an assignment RHS (`statuses = [...]`), except a list assigned to the
-- variable the body returns. `stack` holds one "is assignment" flag per open
-- `[`; `assign` counts the true ones. `assign_scope` is the indent of a line
-- ending in a bare `=`: more-indented lines are its RHS and excluded.
local function new_state(returned_var)
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
	}
end

-- Feeds masked columns `state.col` .. `to - 1` to the tracker.
local function advance_brackets(state, masked, to)
	for k = state.col, to - 1 do
		local ch = masked:sub(k, k)
		if ch:match("[%w_]") then
			state.cur_ident = state.cur_ident .. ch
			state.prev_sig, state.last_sig = state.last_sig, ch
		else
			if state.cur_ident ~= "" then
				state.last_ident, state.cur_ident = state.cur_ident, ""
			end
			if ch == "[" then
				-- A lone `=` (not `==`, `>=`, `<=`, `!=`, `~=`) marks an assignment.
				local p = state.prev_sig
				local is_assign = state.last_sig == "="
					and p ~= ">"
					and p ~= "<"
					and p ~= "!"
					and p ~= "~"
					and p ~= "="
					and state.last_ident ~= state.returned_var
				state.stack[#state.stack + 1] = is_assign
				if is_assign then
					state.assign = state.assign + 1
				end
			elseif ch == "]" then
				local popped = table.remove(state.stack)
				if popped then
					state.assign = state.assign - 1
				end
			end
			if not ch:match("%s") then
				state.prev_sig, state.last_sig = state.last_sig, ch
			end
		end
	end
	state.col = math.max(state.col, to)
end

-- Emits every dep tuple opening on lines first..last (from column `col` on
-- `first`) that sits directly in a dep list.
local function scan(src, first, col, last, state, deps)
	for i = first, last do
		local code, masked = src.code[i], src.masked[i]
		local indent = #code:match("^%s*")
		if state.assign_scope and code:match("%S") and indent <= state.assign_scope then
			state.assign_scope = nil
		end
		local excluded = state.assign_scope ~= nil
		state.col = i == first and col or 1
		local window = table.concat(src.code, "\n", i, math.min(i + TUPLE_LOOKAHEAD, #src.code))
		local pos = state.col
		while true do
			local s, quote, _, name = window:find(DEP_PATTERN, pos)
			if not s or s > #code then
				break
			end
			advance_brackets(state, masked, s)
			if
				masked:sub(s, s) == "{"
				and not excluded
				and #state.stack > 0
				and state.assign == 0
			then
				local row, at = locate(src, i, quote)
				local requirement = src.code[row]:match('^([^"]*)"', at + 1)
				if requirement then
					deps[#deps + 1] = new_record({
						name = name,
						tuple_text = tuple_text(src, i, s),
						requirement = requirement,
						row = row - 1,
						col_start = at,
						col_end = at + #requirement,
					})
				end
			end
			pos = s + 1
		end
		advance_brackets(state, masked, #masked + 1)
		if not excluded and state.assign_scope == nil then
			local target = code:match("([%a_][%w_!?]*)%s*=%s*$")
			if target and target ~= state.returned_var then
				state.assign_scope = indent
			end
		end
	end
end

--- Parse dependency tuples out of mix.exs lines. Returns dep records with
--- 0-indexed `row`, `col_start`, `col_end`.
local function parse_lines(lines)
	local deps = {}
	if #lines == 0 then
		return deps
	end
	local src = prepare(lines)
	-- project/0 names the dep list and its module bounds where the dep
	-- function may live; without it, the whole file is searched.
	local project, project_last = find_definition(src, "project")
	local scope = project and module_scope(src, project)
	local source = deps_source(src, project or 1, project_last or #src.masked)
	if not source then
		return deps
	end
	if source.line then
		local last = bracket_close(src, source.line, source.col)
		scan(src, source.line, source.col, last, new_state(nil), deps)
		return deps
	end
	local head, last, kind = find_definition(src, source.name, scope)
	if head then
		local returned = kind == "block" and returned_variable(src, head, last) or nil
		scan(src, head, 1, last, new_state(returned), deps)
	end
	return deps
end

return {
	parse_lines = parse_lines,
}
