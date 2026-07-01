-- Plugin entry: user command registration and per-buffer state lifecycle.
local hex = require("hex-outdated")
local core = require("hex-outdated.core")
local lock = require("hex-outdated.lock")
local hex_api = require("hex-outdated.hex_api")

describe("setup", function()
	hex.setup({ enabled = false }) -- disabled: no network fetch on attach

	it("registers the :HexOutdated user command", function()
		-- exists(":cmd") returns 2 for an exact, unambiguous command match.
		eq(2, vim.fn.exists(":HexOutdated"), ":HexOutdated defined")
	end)
end)

describe("is_mixexs buffer name matching (issue #34)", function()
	it("does not attach to an already-loaded buffer whose name merely ends in mix.exs", function()
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/remix.exs")

		hex.setup({ enabled = false })

		is_nil(core.state[buf], "remix.exs buffer must not be attached")
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("attaches to an already-loaded buffer named exactly mix.exs", function()
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")

		hex.setup({ enabled = false })

		truthy(core.state[buf], "mix.exs buffer must be attached")
		vim.api.nvim_buf_delete(buf, { force = true })
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

describe("state seeding drift (issue #36)", function()
	it("keeps the configured lock.lens default when toggle seeds state first", function()
		lock.clear_cache()
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		local fd = assert(io.open(dir .. "/mix.lock", "w"))
		fd:write('%{\n  "jason": {:hex, :jason, "1.2.0", "x", [:mix], [], "hexpm", "y"},\n}\n')
		fd:close()

		-- Named so is_mixexs() is false: attach() never seeds core.state for this
		-- buffer, so toggle() is the first thing to touch it (e.g. via the
		-- :HexOutdated command on a buffer that was never attached).
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, dir .. "/other.exs")
		vim.bo[buf].filetype = "elixir"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"defp deps do",
			'  [{:jason, "~> 1.0"}]',
			"end",
		})

		local original_get_package = hex_api.get_package
		hex_api.get_package = function(_, _, callback)
			callback({ versions = { "1.2.0", "1.4.5" } })
		end

		hex.setup({ enabled = true, lock = { lens = true } })
		is_nil(core.state[buf], "buffer state not seeded by attach")

		vim.api.nvim_set_current_buf(buf)
		hex.toggle() -- off: seeds state for the first time
		eq(false, core.state[buf].enabled, "toggle turns analysis off")
		eq(true, core.state[buf].lock_lens, "lock_lens seeded from config on first touch")

		hex.toggle() -- on: re-analyzes and renders with the seeded lock_lens
		vim.wait(200, function()
			return core.state[buf].deps ~= nil and core.state[buf].deps[1] ~= nil
		end, 5)

		hex_api.get_package = original_get_package

		local virt_ns = vim.api.nvim_create_namespace("hex_outdated_virt")
		local lens_text
		vim.wait(200, function()
			local marks = vim.api.nvim_buf_get_extmarks(buf, virt_ns, 0, -1, { details = true })
			for _, m in ipairs(marks) do
				if m[4].virt_lines then
					lens_text = m[4].virt_lines[1][1][1]
				end
			end
			return lens_text ~= nil
		end, 5)
		truthy(lens_text, "lens virt_line rendered after toggle seeded state")
		contains(lens_text, "1.2.0")

		vim.api.nvim_buf_delete(buf, { force = true })
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

local function has_keymap(bufnr, lhs)
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
		if m.lhs == lhs then
			return true
		end
	end
	return false
end

describe("repeated setup removes stale keymaps (issue #28)", function()
	it("removes a hover key that is later disabled", function()
		hex.setup({ enabled = false, popup = { hover_key = "gK" } })
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		truthy(has_keymap(buf, "gK"), "gK mapped after first setup")

		hex.setup({ enabled = false, popup = { hover_key = false } })
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		eq(false, has_keymap(buf, "gK"), "gK removed after hover_key disabled")
	end)

	it("removes a keymap action that is later cleared", function()
		hex.setup({ enabled = false, keymaps = { upgrade = "gU" } })
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		truthy(has_keymap(buf, "gU"), "gU mapped after first setup")

		hex.setup({ enabled = false, keymaps = {} })
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		eq(false, has_keymap(buf, "gU"), "gU removed after keymaps cleared")
	end)

	local function keymap_desc(bufnr, lhs)
		for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
			if m.lhs == lhs then
				return m.desc
			end
		end
		return nil
	end

	it("does not delete a user mapping that replaced a plugin mapping", function()
		hex.setup({ enabled = false, keymaps = { upgrade = "gU" } })
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		truthy(has_keymap(buf, "gU"), "gU mapped after first setup")

		-- The user re-binds the same lhs to their own action after setup.
		vim.keymap.set("n", "gU", "<Nop>", { buffer = buf, desc = "user mapping" })

		hex.setup({ enabled = false, keymaps = {} })
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		truthy(has_keymap(buf, "gU"), "user mapping on gU preserved")
		eq("user mapping", keymap_desc(buf, "gU"), "user mapping not overwritten or deleted")
	end)
end)
