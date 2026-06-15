local lock = require("hex-outdated.lock")

local function write(path, text)
	local fd = assert(io.open(path, "w"))
	fd:write(text)
	fd:close()
end

describe("lock.load", function()
	it("reads and parses a lock file, and re-reads after it changes", function()
		lock.clear_cache()
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		local path = dir .. "/mix.lock"

		write(path, '%{\n  "jason": {:hex, :jason, "1.2.0", "x", [:mix], [], "hexpm", "y"},\n}\n')
		eq("1.2.0", lock.load(path).jason, "first load")

		-- Write the updated file, then nudge mtime forward so it differs from the
		-- cached value regardless of sub-second scheduling.
		write(path, '%{\n  "jason": {:hex, :jason, "1.4.5", "x", [:mix], [], "hexpm", "y"},\n}\n')
		vim.uv.fs_utime(path, os.time() + 5, os.time() + 5)
		eq("1.4.5", lock.load(path).jason, "reloaded after change")
	end)

	it("returns an empty table for a missing file", function()
		eq({}, lock.load(vim.fn.tempname() .. "/nope/mix.lock"))
	end)
end)
