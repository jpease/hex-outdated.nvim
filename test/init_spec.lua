-- Plugin entry: user command registration and per-buffer state lifecycle.
local hex = require("hex-outdated")
local core = require("hex-outdated.core")

describe("setup", function()
	hex.setup({ enabled = false }) -- disabled: no network fetch on attach

	it("registers the :HexOutdated user command", function()
		-- exists(":cmd") returns 2 for an exact, unambiguous command match.
		eq(2, vim.fn.exists(":HexOutdated"), ":HexOutdated defined")
	end)
end)

describe("per-buffer state lifecycle", function()
	it("drops core.state when a mix.exs buffer is wiped", function()
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		-- Trigger attach by firing the autocmd the plugin listens on.
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		truthy(core.state[buf], "state created on attach")

		vim.api.nvim_buf_delete(buf, { force = true })
		vim.wait(200, function()
			return core.state[buf] == nil
		end, 5)
		is_nil(core.state[buf], "state cleared after buffer delete")
	end)
end)

describe("lock lens toggle", function()
	it("toggles st.lock_lens for the buffer", function()
		hex.setup({ enabled = false })
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

		local before = core.state[buf] and core.state[buf].lock_lens or false
		hex.lock()
		eq(not before, core.state[buf].lock_lens, "lens flips")
	end)
end)

describe("repeated setup does not duplicate autocmds", function()
	it("leaves exactly one set of buffer-local autocmds after two setup calls", function()
		hex.setup({ enabled = false })
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

		local after_first = #vim.api.nvim_get_autocmds({ buffer = buf })
		truthy(after_first > 0, "at least one autocmd after first setup")

		hex.setup({ enabled = false })
		local after_second = #vim.api.nvim_get_autocmds({ buffer = buf })

		eq(after_first, after_second, "autocmd count unchanged after second setup")
	end)
end)
