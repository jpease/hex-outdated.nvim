-- Dependency normalization shared by both parser backends.
--
-- The fallback line scanner and the Tree-sitter traversal locate dep tuples by
-- entirely different means, but a dependency record means the same thing either
-- way, and so does the question "which function holds the dep list?". Both
-- answers live here. Before this module, `package_alias` and
-- `configured_dep_function` sat in the middle of the fallback-only region and
-- were reached into by the Tree-sitter path, and each backend spelled the
-- record shape out by hand at every construction site -- five of them.
--
-- Pure Lua: no Neovim APIs, no module-level state.

local lexer = require("hex-outdated.parser.lexer")

local strip_comment = lexer.strip_comment

-- The `hex: :name` alias inside a dep tuple's options, e.g. the `plug` in
-- `{:my_plug, "~> 1.0", hex: :plug}`, which is the name the package is actually
-- published under. Local to this module: both backends reach it only through
-- `new_record`, so neither can extract an alias by some other rule.
local function package_alias(text)
	return text:match("hex%s*:%s*:([%w_]+)")
end

-- Build one dependency record. This is the only place the record shape is
-- written down, so `name`, `package`, `requirement`, `kind`, `row`,
-- `col_start`, and `col_end` are identical between the two backends by
-- construction rather than by convention.
--
-- Positions are 0-indexed and arrive already converted, because the backends
-- derive them differently: the fallback works from 1-indexed line numbers and
-- Lua string offsets, the Tree-sitter path from node ranges that are 0-indexed
-- to begin with. Normalizing them here would mean teaching this function which
-- backend called it.
--
-- `tuple_text` is the source text of the tuple the record came from, from its
-- `{` up to the next tuple's `{` (or end of line), or nil when the caller has
-- no tuple text to offer -- in which case the record simply carries no alias.
local function new_record(fields)
	local package
	if fields.tuple_text then
		package = package_alias(fields.tuple_text)
	end
	return {
		name = fields.name,
		package = package,
		requirement = fields.requirement,
		kind = "hex",
		row = fields.row,
		col_start = fields.col_start,
		col_end = fields.col_end,
	}
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
--
-- Shared by both backends, which is the point: the Tree-sitter path falls back
-- to this same text guess when project/0 declares no `deps:` key at all, and the
-- two must guess identically. Both pass lines already run through
-- `lexer.mask_heredocs`.
local function configured_dep_function(lines, first, last)
	local stripped = {}
	for i = first or 1, last or #lines do
		stripped[#stripped + 1] = strip_comment(lines[i])
	end
	local name = table.concat(stripped, "\n"):match("deps%s*:%s*([%a_][%w_!?]*)%s*%(")
	return name or "deps"
end

return {
	new_record = new_record,
	configured_dep_function = configured_dep_function,
}
