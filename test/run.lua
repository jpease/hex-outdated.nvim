-- Headless-Neovim integration test runner.
--
-- Run with:  nvim --headless -u NONE -l test/run.lua
-- (`-u NONE` skips your config for a hermetic run while keeping installed
-- Treesitter parsers on the default runtimepath.)
--
-- These specs exercise the Neovim-coupled modules (Treesitter parsing, extmark
-- and diagnostic rendering, the curl queue, buffer actions) against a real
-- Neovim, which the busted suite under `spec/` cannot do because it stubs `vim`.
-- The runner is intentionally dependency-free: no busted, no luarocks, no nlua,
-- so CI only needs a Neovim binary on PATH.

local root = vim.fn.getcwd()
vim.opt.runtimepath:append(root)

local results = { pass = 0, fail = 0, skip = 0, failures = {} }
local stack = {}

local function label(name)
	local parts = {}
	for _, s in ipairs(stack) do
		parts[#parts + 1] = s
	end
	parts[#parts + 1] = name
	return table.concat(parts, " › ")
end

-- A skipped test raises this sentinel so `it` can tell it apart from a failure.
local SKIP = {}

function _G.describe(name, fn)
	stack[#stack + 1] = name
	local ok, err = pcall(fn)
	stack[#stack] = nil
	if not ok then
		error(err) -- a failure while *registering* tests is a real error
	end
end

function _G.it(name, fn)
	local full = label(name)
	local ok, err = pcall(fn)
	if ok then
		results.pass = results.pass + 1
		io.write("  ok   " .. full .. "\n")
	elseif type(err) == "table" and err.sentinel == SKIP then
		results.skip = results.skip + 1
		io.write("  skip " .. full .. " (" .. tostring(err.reason) .. ")\n")
	else
		results.fail = results.fail + 1
		results.failures[#results.failures + 1] = { name = full, err = err }
		io.write("  FAIL " .. full .. "\n")
	end
end

function _G.skip(reason)
	error({ sentinel = SKIP, reason = reason })
end

-- Minimal assertion helpers. They raise a string so the failure line is readable.
local function fail(msg)
	error(msg, 2)
end

function _G.eq(expected, got, ctx)
	if not vim.deep_equal(expected, got) then
		fail(
			(ctx and (ctx .. ": ") or "")
				.. "expected "
				.. vim.inspect(expected)
				.. " but got "
				.. vim.inspect(got)
		)
	end
end

function _G.is_true(x, ctx)
	if x ~= true then
		fail((ctx and (ctx .. ": ") or "") .. "expected true, got " .. vim.inspect(x))
	end
end

function _G.is_nil(x, ctx)
	if x ~= nil then
		fail((ctx and (ctx .. ": ") or "") .. "expected nil, got " .. vim.inspect(x))
	end
end

function _G.truthy(x, ctx)
	if not x then
		fail((ctx and (ctx .. ": ") or "") .. "expected truthy, got " .. vim.inspect(x))
	end
end

function _G.contains(haystack, needle)
	if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
		fail("expected " .. vim.inspect(haystack) .. " to contain " .. vim.inspect(needle))
	end
end

local files = vim.fn.glob(root .. "/test/*_spec.lua", false, true)
table.sort(files)
for _, file in ipairs(files) do
	io.write("\n" .. vim.fn.fnamemodify(file, ":t") .. "\n")
	dofile(file)
end

io.write(
	string.format("\n%d passed, %d failed, %d skipped\n", results.pass, results.fail, results.skip)
)
for _, f in ipairs(results.failures) do
	io.write("\nFAIL: " .. f.name .. "\n  " .. tostring(f.err) .. "\n")
end

if results.fail > 0 then
	os.exit(1)
end
