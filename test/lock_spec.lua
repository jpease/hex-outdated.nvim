local lock = require("hex-outdated.lock")
local core = require("hex-outdated.core")
local config = require("hex-outdated.config")

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

describe("core.analyze lock attachment", function()
	it("attaches locked + lock_out_of_range from the sibling mix.lock", function()
		config.setup({})
		lock.clear_cache()
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		local fd = assert(io.open(dir .. "/mix.lock", "w"))
		fd:write('%{\n  "jason": {:hex, :jason, "1.2.0", "x", [:mix], [], "hexpm", "y"},\n}\n')
		fd:close()

		local buf = vim.api.nvim_create_buf(false, false)
		vim.api.nvim_buf_set_name(buf, dir .. "/mix.exs")
		vim.bo[buf].filetype = "elixir"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"defp deps do",
			'  [{:jason, "~> 2.0"}]', -- requirement the locked 1.2.0 violates
			"end",
		})

		core.state[buf] = { enabled = false } -- disable async fetch on analyze
		core.analyze(buf)

		local jason
		for _, d in ipairs(core.state[buf].deps) do
			if d.name == "jason" then
				jason = d
			end
		end
		truthy(jason, "jason parsed")
		eq("1.2.0", jason.locked)
		is_true(jason.lock_out_of_range, "1.2.0 does not satisfy ~> 2.0")
	end)
end)
