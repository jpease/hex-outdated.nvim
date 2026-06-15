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
