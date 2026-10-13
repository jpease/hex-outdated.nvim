-- Elixir surface syntax shared by the line scanner: comments, literals
-- (strings, charlists, sigils, char literals), heredocs, and block keywords.
-- Pure Lua; no Neovim APIs.

local SIGIL_CLOSE = { ["("] = ")", ["["] = "]", ["{"] = "}", ["<"] = ">" }
local SIGIL_SAME = { ['"'] = true, ["'"] = true, ["|"] = true, ["/"] = true }

-- Characters that can start a literal, plus the comment marker.
local SPECIAL = "[\"'~?#]"

-- For a sigil starting at `i` ("~", letters, delimiter): the delimiter's index,
-- its closing character, whether the pair nests, and whether it interpolates.
local function sigil_delim(code, i)
	local j = i + 1
	while code:sub(j, j):match("%a") do
		j = j + 1
	end
	if j == i + 1 then
		return nil
	end
	local d = code:sub(j, j)
	local interpolates = code:sub(i + 1, i + 1):match("%l") ~= nil
	if SIGIL_CLOSE[d] then
		return j, SIGIL_CLOSE[d], true, interpolates
	elseif SIGIL_SAME[d] then
		return j, d, false, interpolates
	end
	return nil
end

local literal_end

-- Index of the "}" closing the interpolation whose "#{" starts at `i`.
local function interpolation_end(code, i)
	local depth = 1
	local k = i + 2
	while k <= #code do
		local stop = literal_end(code, k)
		if stop then
			k = stop + 1
		else
			local c = code:sub(k, k)
			if c == "{" then
				depth = depth + 1
			elseif c == "}" then
				depth = depth - 1
				if depth == 0 then
					return k
				end
			end
			k = k + 1
		end
	end
	return #code
end

-- Index of the delimiter closing the literal opened at `open_idx`.
local function delimited_end(code, open_idx, close, nests, interpolates)
	local open = code:sub(open_idx, open_idx)
	local depth = 1
	local k = open_idx + 1
	while k <= #code do
		local c = code:sub(k, k)
		if c == "\\" then
			k = k + 2
		elseif interpolates and c == "#" and code:sub(k + 1, k + 1) == "{" then
			k = interpolation_end(code, k) + 1
		else
			if nests and c == open then
				depth = depth + 1
			elseif c == close then
				depth = depth - 1
				if depth == 0 then
					return k
				end
			end
			k = k + 1
		end
	end
	return #code
end

-- Index of the last character of the literal starting at `i`, or nil when no
-- literal starts there. A literal left open on this line runs to its end.
function literal_end(code, i)
	local c = code:sub(i, i)
	if c == '"' or c == "'" then
		return delimited_end(code, i, c, false, true)
	elseif c == "~" then
		local open_idx, close, nests, interpolates = sigil_delim(code, i)
		return open_idx and delimited_end(code, open_idx, close, nests, interpolates) or nil
	elseif c == "?" and i < #code and not code:sub(i - 1, i - 1):match("[%w_]") then
		-- Char literal (`?#`, `?"`, `?\n`); a `?` ending an identifier is not one.
		return code:sub(i + 1, i + 1) == "\\" and math.min(i + 2, #code) or i + 1
	end
	return nil
end

local function strip_comment(line)
	local i = 1
	while true do
		i = line:find(SPECIAL, i)
		if not i then
			return line
		end
		local stop = literal_end(line, i)
		if stop then
			i = stop + 1
		elseif line:sub(i, i) == "#" then
			return line:sub(1, i - 1)
		else
			i = i + 1
		end
	end
end

-- `code` with every literal replaced by `"` characters of the same length, so
-- columns line up and nothing inside a literal reads as code.
local function mask_literals(code)
	local out = {}
	local i, last = 1, 1
	while true do
		i = code:find(SPECIAL, i)
		if not i then
			break
		end
		local stop = literal_end(code, i)
		if stop then
			out[#out + 1] = code:sub(last, i - 1)
			out[#out + 1] = string.rep('"', stop - i + 1)
			i, last = stop + 1, stop + 1
		else
			i = i + 1
		end
	end
	out[#out + 1] = code:sub(last)
	return table.concat(out)
end

-- The heredoc delimiter (`"""` or `'''`) opened on this line, or nil. An opener
-- is a delimiter in code position followed by nothing but whitespace.
local function heredoc_opener(code)
	local i = 1
	while true do
		i = code:find(SPECIAL, i)
		if not i then
			return nil
		end
		local c = code:sub(i, i)
		if c == "#" then
			return nil
		end
		local open = c == "~" and sigil_delim(code, i) or i
		local delim = code:sub(open, open + 2)
		if (delim == '"""' or delim == "'''") and code:find("^%s*$", open + 3) then
			return delim
		end
		i = (literal_end(code, i) or i) + 1
	end
end

-- A copy of `lines` (same length) with heredoc bodies blanked and closing
-- delimiters replaced by spaces; opener lines and anything after a closer stay.
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

-- Counts `word` as a whole token; "_" is part of an Elixir identifier.
local function count_keyword(masked, word, guard)
	local pattern = "%f[%w_]" .. word .. "%f[^%w_]"
	local count = 0
	local pos = 1
	while true do
		local s, e = masked:find(pattern, pos)
		if not s then
			return count
		end
		if guard(masked, s, e) then
			count = count + 1
		end
		pos = e + 1
	end
end

-- Excludes atoms (`:do`).
local function not_atom(masked, s)
	return masked:sub(s - 1, s - 1) ~= ":"
end

-- Excludes atoms and keyword keys (`do:`, `end:`).
local function not_atom_or_key(masked, s, e)
	return not_atom(masked, s) and masked:sub(e + 1, e + 1) ~= ":"
end

-- Net block depth change of one `mask_literals` line: `do`/`fn` openers minus
-- `end` closers.
local function block_delta(masked)
	return count_keyword(masked, "do", not_atom_or_key)
		+ count_keyword(masked, "fn", not_atom)
		- count_keyword(masked, "end", not_atom_or_key)
end

return {
	strip_comment = strip_comment,
	mask_literals = mask_literals,
	mask_heredocs = mask_heredocs,
	block_delta = block_delta,
}
