local config = require("hex-outdated.config")

-- README.md and doc/hex-outdated.txt each carry a full copy of the defaults
-- table, and between them hold the only prose explanation of what each option
-- does -- `config.lua` itself carries one comment. Three copies drift silently:
-- both docs described `lens = false` as "show the locked-version lens by
-- default" from 4af3d61 (2026-06-15), the commit that first documented the
-- option, and no code comment existed to contradict them. These tests fail the
-- suite on any value or key divergence.

--- Pull the multi-line `require("hex-outdated").setup({ ... })` block out of a
--- doc file. Matches on the trimmed line so the vimdoc's 4-space indent works,
--- and on the bare `setup({` opener so the single-line `setup({})` calls in the
--- install sections are never picked up. Returns the block's inner lines.
local function extract_setup_block(path)
	local fd = assert(io.open(path, "r"), path .. " not readable")
	local text = fd:read("*a")
	fd:close()

	local inner = {}
	local inside, closed = false, false
	for line in text:gmatch("([^\n]*)\n?") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if not inside then
			inside = trimmed == 'require("hex-outdated").setup({'
		elseif trimmed == "})" then
			closed = true
			break
		else
			inner[#inner + 1] = line
		end
	end

	assert(inside, "no multi-line setup block found in " .. path)
	assert(closed, "unterminated setup block in " .. path)
	return inner
end

--- Evaluate an extracted block as a table literal. The block is all literals,
--- so it needs no environment; loading it in an empty one means a doc example
--- that grew a function call fails here rather than running anything.
local function eval_block(path)
	local src = "return {\n" .. table.concat(extract_setup_block(path), "\n") .. "\n}"
	local chunk, err = load(src, path .. " setup block", "t", {})
	assert(chunk, err)
	return chunk()
end

local function note(out, path, message)
	out[#out + 1] = path .. ": " .. message
end

--- Collect every path where `documented` and `actual` disagree: a key one has
--- and the other lacks, or a leaf whose value differs. Reporting dotted paths
--- beats a whole-table diff, since a single wrong value inside `api` or `text`
--- would otherwise print every sibling alongside it.
local function divergences(documented, actual, prefix, out)
	out = out or {}
	prefix = prefix or ""

	for key, want in pairs(actual) do
		local path = prefix .. tostring(key)
		local got = documented[key]
		if got == nil then
			note(out, path, "missing from the docs; config.lua has " .. tostring(want))
		elseif type(want) == "table" and type(got) == "table" then
			divergences(got, want, path .. ".", out)
		elseif type(want) ~= type(got) or want ~= got then
			note(out, path, "docs say " .. tostring(got) .. ", config.lua has " .. tostring(want))
		end
	end

	for key in pairs(documented) do
		if actual[key] == nil then
			note(out, prefix .. tostring(key), "documented but not in config.lua")
		end
	end

	return out
end

for _, doc in ipairs({
	{ name = "README.md", path = "README.md" },
	{ name = "doc/hex-outdated.txt", path = "doc/hex-outdated.txt" },
}) do
	describe(doc.name .. " config block", function()
		it("matches config.defaults exactly", function()
			local found = divergences(eval_block(doc.path), config.defaults)
			assert.are.equal("", table.concat(found, "\n"))
		end)
	end)
end
