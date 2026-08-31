-- The single source of truth for how this plugin reads Elixir surface syntax:
-- comments, double-quoted strings, charlists, sigils, heredocs, delimiters, and
-- the `do`/`fn`/`end` block keywords. Every scanner that has to decide "is this
-- character code, or is it literal text?" lives in this file, so no backend can
-- grow a second interpretation of the same syntax -- the drift behind issues
-- #58 (underscore-adjacent keywords), #63 (three independent block-depth
-- trackers), and #69 (charlists and sigils).
--
-- Pure Lua: no Neovim APIs, no module-level state.
--
-- The functions compose in one direction. `mask_heredocs` neutralises
-- multi-line literals across the whole file first; the per-line scanners
-- (`strip_comment`, `mask_strings`, and through them `count_openers`,
-- `count_closers`, and `block_delta`) then run on that output, so no caller
-- scans raw source a heredoc body could poison.
--
-- `sigil_delim` is exported for `fallback.advance_brackets`, which needs the
-- open-detection step on its own: it is resumable one character at a time and
-- so cannot look ahead the way `literal_span` does. It tracks the matching
-- close itself, under the same nesting and escaping rules documented here.

-- Standard Elixir sigil delimiter pairs (issue #69). The four paired forms
-- nest -- `~s(a (b) c)` is one sigil literal, so a nested open delimiter
-- pushes the depth back up rather than being treated as ordinary text. The
-- four same-character forms do not nest -- the literal ends at the first
-- matching, non-escaped closer, exactly like an ordinary string.
local SIGIL_CLOSE = { ["("] = ")", ["["] = "]", ["{"] = "}", ["<"] = ">" }
local SIGIL_SAME = { ['"'] = true, ["'"] = true, ["|"] = true, ["/"] = true }

-- If `code:sub(i, i)` is "~" and a sigil opens there (one or more letters
-- immediately followed, no whitespace, by one of the 8 standard delimiters),
-- return the index of the opening delimiter character itself, the character
-- that closes it, and whether that pair nests. Returns nil for a bare "~"
-- that isn't a sigil prefix (not a token this file needs to give any other
-- meaning to), in which case the caller treats it as ordinary text. Shared by
-- `literal_span` below (for `strip_comment`/`mask_strings`, which can look
-- ahead across the whole line) and `advance_brackets` (which cannot -- it is
-- a resumable, one-character-at-a-time scanner -- so it uses only this
-- open-detection step and tracks the matching close itself, the same way it
-- already tracks an open double-quoted string).
local function sigil_delim(code, i)
	local j = i + 1
	while code:sub(j, j):match("%a") do
		j = j + 1
	end
	if j == i + 1 then
		return nil
	end
	local d = code:sub(j, j)
	if SIGIL_CLOSE[d] then
		return j, SIGIL_CLOSE[d], true
	elseif SIGIL_SAME[d] then
		return j, d, false
	end
	return nil
end

-- If a charlist ('...') or single-line sigil opens at `code:sub(i, i)` (i.e.
-- `code:sub(i,i)` is "'" or a "~" that `sigil_delim` confirms), return the
-- index of its opening delimiter character and the index of its closing
-- delimiter -- or `#code + 1` when the literal is unterminated on this line,
-- meaning it runs inert to the end of the line, matching how an unterminated
-- `"..."` string is already treated by `mask_strings` below. Backslash
-- escaping works exactly as it does inside `"..."` elsewhere in this file.
-- Returns nil when no literal opens at `i` at all (a "~" that isn't a valid
-- sigil prefix), in which case the character at `i` is ordinary text.
--
-- Used by `strip_comment` and `mask_strings`, which both scan one whole
-- physical line at a time and so can look ahead freely; `advance_brackets`
-- cannot use this directly (see `sigil_delim`'s doc comment) but applies the
-- same nesting/escaping rules through its own resumable state.
local function literal_span(code, i)
	local ch = code:sub(i, i)
	local open_idx, close_char, nests
	if ch == "'" then
		open_idx, close_char, nests = i, "'", false
	elseif ch == "~" then
		open_idx, close_char, nests = sigil_delim(code, i)
		if not open_idx then
			return nil
		end
	else
		return nil
	end
	local open_delim = code:sub(open_idx, open_idx)
	local depth = 1
	local escaped = false
	local k = open_idx + 1
	while k <= #code do
		local c = code:sub(k, k)
		if escaped then
			escaped = false
		elseif c == "\\" then
			escaped = true
		elseif nests and c == open_delim then
			depth = depth + 1
		elseif c == close_char then
			depth = depth - 1
			if depth == 0 then
				return open_idx, k
			end
		end
		k = k + 1
	end
	return open_idx, #code + 1
end

local function strip_comment(line)
	local in_string = false
	local escaped = false
	local i = 1
	while i <= #line do
		local char = line:sub(i, i)
		if escaped then
			escaped = false
			i = i + 1
		elseif char == "\\" and in_string then
			escaped = true
			i = i + 1
		elseif char == '"' then
			in_string = not in_string
			i = i + 1
		elseif char == "#" and not in_string then
			return line:sub(1, i - 1)
		elseif not in_string and (char == "'" or char == "~") then
			-- A charlist or sigil literal may itself contain a "#" (or, for a
			-- sigil, may simply fail to open at all for a bare "~"); either way
			-- this is not a real comment start, so skip past whatever literal
			-- span (if any) is here rather than scanning its characters one at
			-- a time (issue #69).
			local _, close = literal_span(line, i)
			i = close and (close + 1) or (i + 1)
		else
			i = i + 1
		end
	end
	return line
end

-- Cross-line state that lets the per-line scanners below (`strip_comment`,
-- `mask_strings`, `advance_brackets`, and the block-depth accounting built on
-- top of them) treat a heredoc's entire body as inert, rather than as
-- executable code. `mask_heredocs` is the single place that decides what is
-- and is not inside a heredoc; `parse_lines` computes it once and threads
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

-- Replace the contents of double-quoted string literals, charlists, and
-- single-line sigils in `code` with spaces, preserving length (and the
-- delimiter characters themselves) so column offsets elsewhere stay
-- meaningful. Used by `count_openers` below so a "do" or "fn" inside a
-- string's text (e.g. a SemVer pre-release tag like "== 1.0.0-do"), inside a
-- charlist (`'do'`), or inside a sigil (`~w(do)a`) is never mistaken for a
-- block-opening keyword (issue #69 for the latter two). Uses the same
-- in_string/escaped string-scan convention as `strip_comment` and
-- `advance_brackets` for `"..."`, and `literal_span` for charlists/sigils.
-- Like both of those, this scans one physical line at a time; multi-line
-- heredocs are handled upstream by `mask_heredocs`, whose output is what
-- every caller in this file actually scans, so a line reaching this function
-- either isn't part of a heredoc or has already been neutralized to
-- whitespace / an empty string.
local function mask_strings(code)
	local out = {}
	local in_string = false
	local escaped = false
	local i = 1
	while i <= #code do
		local char = code:sub(i, i)
		if escaped then
			out[i] = " "
			escaped = false
			i = i + 1
		elseif char == "\\" and in_string then
			out[i] = " "
			escaped = true
			i = i + 1
		elseif char == '"' then
			in_string = not in_string
			out[i] = char
			i = i + 1
		elseif in_string then
			out[i] = " "
			i = i + 1
		elseif char == "'" or char == "~" then
			local open_idx, close_idx = literal_span(code, i)
			if not open_idx then
				out[i] = char
				i = i + 1
			else
				for k = i, open_idx do
					out[k] = code:sub(k, k)
				end
				local interior_end = math.min(close_idx - 1, #code)
				for k = open_idx + 1, interior_end do
					out[k] = " "
				end
				if close_idx <= #code then
					out[close_idx] = code:sub(close_idx, close_idx)
				end
				i = close_idx + 1
			end
		else
			out[i] = char
			i = i + 1
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
-- applies to `do`. Paired with `count_openers` by `module_ranges` in the
-- fallback backend, and by `block_delta` below, to track nested-block depth via
-- each line's net opener/closer delta.
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
-- Shared by `locate_project`, `returned_variable`, and `parse_lines` in the
-- fallback backend so the three scanners cannot drift out of sync with each
-- other again (#63); each keeps its own action on close, since a returned
-- range, a returned value, and a flag flip are not interchangeable.
local function block_delta(depth, code)
	local net = count_openers(code) - count_closers(code)
	local new_depth = depth + net
	return new_depth, new_depth < 0
end

-- Exported surface is deliberately narrow: only what another module in
-- `parser/` actually consumes. `literal_span`, `heredoc_opener`,
-- `ends_inside_string`, `mask_strings`, `count_keyword`, and the two bare-atom
-- guards stay local, so the lexical rules they encode are reachable only
-- through the functions below.
return {
	sigil_delim = sigil_delim,
	strip_comment = strip_comment,
	mask_heredocs = mask_heredocs,
	count_openers = count_openers,
	count_closers = count_closers,
	block_delta = block_delta,
}
