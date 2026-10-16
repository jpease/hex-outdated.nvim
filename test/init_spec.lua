-- Plugin entry: user command registration and per-buffer state lifecycle.
local hex = require("hex-outdated")
local core = require("hex-outdated.core")
local lock = require("hex-outdated.lock")
local hex_api = require("hex-outdated.hex_api")
local config = require("hex-outdated.config")

describe("setup", function()
	hex.setup({ enabled = false }) -- disabled: no network fetch on attach

	it("registers the :HexOutdated user command", function()
		-- exists(":cmd") returns 2 for an exact, unambiguous command match.
		eq(2, vim.fn.exists(":HexOutdated"), ":HexOutdated defined")
	end)
end)

describe("is_mixexs buffer name matching", function()
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

	it("renders an unanalyzed buffer without a scheduled error", function()
		local original_get_package = hex_api.get_package
		hex_api.get_package = function() end -- no network for any attached mix.exs
		hex.setup({})
		hex_api.get_package = original_get_package
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/notes.txt")
		vim.api.nvim_set_current_buf(buf)
		is_nil(core.state[buf], "buffer never analyzed")

		local scheduled = {}
		local original_schedule = vim.schedule
		vim.schedule = function(fn)
			scheduled[#scheduled + 1] = fn
		end
		local cmd_ok, cmd_err = pcall(vim.cmd, "HexOutdated lock")
		vim.schedule = original_schedule
		is_true(cmd_ok, tostring(cmd_err))
		eq(1, #scheduled, "lock schedules one render")
		local ok, err = pcall(scheduled[1])
		is_true(ok, tostring(err))

		eq(not config.options.lock.lens, core.state[buf].lock_lens, "lens flips from the default")
		local ns = vim.api.nvim_get_namespaces().hex_outdated_virt
		eq({}, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), "no annotations")
		vim.api.nvim_buf_delete(buf, { force = true })
	end)
end)

describe("state seeding", function()
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
	local normalized = vim.api.nvim_replace_termcodes(lhs, true, true, true)
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
		if m.lhs == normalized then
			return true
		end
	end
	return false
end

describe("repeated setup removes stale keymaps", function()
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
		local normalized = vim.api.nvim_replace_termcodes(lhs, true, true, true)
		for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
			if m.lhs == normalized then
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

	it("removes a <leader>-based keymap action that is later cleared", function()
		local old_mapleader = vim.g.mapleader
		vim.g.mapleader = " "

		hex.setup({ enabled = false, keymaps = { upgrade = "<leader>u" } })
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		truthy(has_keymap(buf, "<leader>u"), "<leader>u mapped after first setup")

		hex.setup({ enabled = false, keymaps = {} })
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		eq(false, has_keymap(buf, "<leader>u"), "<leader>u removed after keymaps cleared")

		vim.g.mapleader = old_mapleader
	end)

	it("does not delete a user mapping that replaced a plugin leader mapping", function()
		local old_mapleader = vim.g.mapleader
		vim.g.mapleader = " "

		hex.setup({ enabled = false, keymaps = { upgrade = "<leader>u" } })
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		truthy(has_keymap(buf, "<leader>u"), "<leader>u mapped after first setup")

		-- The user re-binds the same lhs to their own action after setup.
		vim.keymap.set("n", "<leader>u", "<Nop>", { buffer = buf, desc = "user mapping" })

		hex.setup({ enabled = false, keymaps = {} })
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		truthy(has_keymap(buf, "<leader>u"), "user mapping on <leader>u preserved")
		eq("user mapping", keymap_desc(buf, "<leader>u"), "user mapping not overwritten or deleted")

		vim.g.mapleader = old_mapleader
	end)
end)

describe("auto_update debounce", function()
	local function with_stubbed_analyze(fn)
		local original_analyze = core.analyze
		local analyze_calls = 0
		core.analyze = function(...)
			analyze_calls = analyze_calls + 1
			return original_analyze(...)
		end
		local ok, err = pcall(fn, function()
			return analyze_calls
		end)
		core.analyze = original_analyze
		if not ok then
			error(err)
		end
	end

	it("does not fire a stale timer left over from a previous attach", function()
		with_stubbed_analyze(function(get_calls)
			hex.setup({ enabled = false, auto_update = true, debounce_ms = 30 })
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
			vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

			-- Starts a debounce timer under the OLD attach()'s closure.
			vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })

			-- Reconfigure with auto_update disabled before the old timer fires,
			-- then reattach the same buffer under the new config.
			hex.setup({ enabled = false, auto_update = false })
			vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

			-- Wait comfortably past the original debounce window.
			vim.wait(150)

			eq(0, get_calls(), "stale timer from previous attach must not call core.analyze")

			vim.api.nvim_buf_delete(buf, { force = true })
		end)
	end)

	it("analyzes once after a debounced edit when auto_update is enabled", function()
		with_stubbed_analyze(function(get_calls)
			hex.setup({ enabled = false, auto_update = true, debounce_ms = 30 })
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
			vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

			vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })

			vim.wait(150)

			eq(1, get_calls(), "debounced timer should call core.analyze exactly once")

			vim.api.nvim_buf_delete(buf, { force = true })
		end)
	end)

	it("cancels the pending timer when the buffer is deleted", function()
		with_stubbed_analyze(function(get_calls)
			hex.setup({ enabled = false, auto_update = true, debounce_ms = 30 })
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
			vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

			vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })

			vim.api.nvim_buf_delete(buf, { force = true })

			vim.wait(150)

			eq(0, get_calls(), "deleted buffer's pending timer must not call core.analyze")
		end)
	end)
end)

describe("auto_update debounce timer handle leak", function()
	-- vim.uv.walk visits every libuv handle in the process, including handles
	-- owned by Neovim itself or by other tests. A stopped-but-unclosed timer
	-- still shows up here (that is exactly the leak), while a closed one does
	-- not count against `is_closing()`. We snapshot a baseline immediately
	-- before the plugin activity under test and assert on the delta, so
	-- unrelated pre-existing timer handles never make this test flaky.
	local function count_open_timers()
		local n = 0
		vim.uv.walk(function(h)
			if h:get_type() == "timer" and not h:is_closing() then
				n = n + 1
			end
		end)
		return n
	end

	it("closes a replaced debounce timer's handle instead of leaking it", function()
		-- A huge debounce so nothing fires during the test; only handle
		-- accounting is under test here, not callback behavior.
		hex.setup({ enabled = false, auto_update = true, debounce_ms = 60000 })
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

		local before = count_open_timers()
		for _ = 1, 50 do
			vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
		end
		collectgarbage()
		collectgarbage()
		local after_replacements = count_open_timers()
		eq(
			1,
			after_replacements - before,
			"50 rapid replacements must leave exactly one open plugin timer"
		)

		vim.api.nvim_buf_delete(buf, { force = true })
		collectgarbage()
		collectgarbage()
		local after_teardown = count_open_timers()
		eq(before, after_teardown, "buffer teardown must close the remaining pending timer")
	end)

	it("closes the stale timer's handle when setup() reattaches the buffer", function()
		hex.setup({ enabled = false, auto_update = true, debounce_ms = 60000 })
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

		local before = count_open_timers()
		-- Starts a pending debounce timer under the OLD attach()'s closure.
		vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })

		-- Reattach twice without ever firing another TextChanged: the only
		-- timer that ever existed is the stale one above, so if reattaching
		-- truly closes it (rather than merely stopping it), the open-timer
		-- count must return to baseline exactly, not baseline+1.
		for _ = 1, 2 do
			hex.setup({ enabled = false, auto_update = true, debounce_ms = 60000 })
			vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
		end
		collectgarbage()
		collectgarbage()
		local after = count_open_timers()
		eq(
			before,
			after,
			"repeated setup() must close the stale timer handle from the prior attachment,"
				.. " leaving none pending"
		)

		vim.api.nvim_buf_delete(buf, { force = true })
	end)
end)

describe("read-only actions reject a stale dependency snapshot", function()
	-- Analyze a real mix.exs buffer holding jason with fetches left unresolved
	-- (only the changedtick stamping matters; each action must refuse before
	-- ever fetching), then apply `edit` and run `fn` with vim.ui.open and
	-- WARN notifications captured. Returns the opened URL and the warning count.
	local function after_stale_edit(edit, fn)
		local original_get_package = hex_api.get_package
		hex_api.get_package = function() end

		hex.setup({ enabled = true, auto_update = false })
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.bo[buf].filetype = "elixir"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"defp deps do",
			'  [{:jason, "~> 1.4"}]',
			"end",
		})
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

		local st = core.state[buf]
		truthy(
			st and st.deps and st.deps[1] and st.deps[1].changedtick,
			"dep analyzed with a changedtick"
		)

		vim.api.nvim_win_set_cursor(0, { 2, 4 })
		-- An edit lands (e.g. during the debounce window) after analysis but
		-- before anything re-analyzes; core.state[buf].deps still holds jason.
		edit(buf)

		local original_open, original_notify = vim.ui.open, vim.notify
		local opened, warned = nil, 0
		vim.ui.open = function(url)
			opened = url
		end
		vim.notify = function(_, level)
			if level == vim.log.levels.WARN then
				warned = warned + 1
			end
		end
		local ok, err = pcall(fn)
		vim.ui.open, vim.notify = original_open, original_notify
		hex_api.get_package = original_get_package
		vim.api.nvim_buf_delete(buf, { force = true })
		is_true(ok, tostring(err))
		return opened, warned
	end

	it("open/info/versions ignore a dep renamed on its own row after analysis", function()
		local opened, warned = after_stale_edit(function(buf)
			vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '  [{:decimal, "~> 2.0"}]' })
		end, function()
			hex.open()
			hex.versions()
			hex.info()
		end)

		is_nil(opened, "open must not launch a package from the stale snapshot")
		eq(3, warned, "open, versions, and info each warn instead of using the stale snapshot")
	end)

	it("open ignores old row metadata after an edit shifts dependency rows", function()
		local opened, warned = after_stale_edit(function(buf)
			-- Insert decimal above jason: the cursor row now holds decimal while
			-- the stale metadata still places jason there.
			vim.api.nvim_buf_set_lines(buf, 1, 2, false, {
				'  [{:decimal, "~> 2.0"},',
				'   {:jason, "~> 1.4"}]',
			})
			vim.api.nvim_win_set_cursor(0, { 2, 4 })
		end, function()
			hex.open()
		end)

		is_nil(opened, "open must not launch a package from old row metadata")
		eq(1, warned, "open warns instead of using old row metadata")
	end)
end)

describe("subcommand dispatch restricted to documented commands", function()
	it("dispatches a documented subcommand (toggle) via :HexOutdated", function()
		hex.setup({ enabled = false })
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

		local before = core.state[buf].enabled
		vim.cmd("HexOutdated toggle")
		eq(not before, core.state[buf].enabled, "toggle dispatched through :HexOutdated")

		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("defaults bare :HexOutdated (no args) to refresh", function()
		local original_analyze = core.analyze
		local analyze_calls = 0
		core.analyze = function(...)
			analyze_calls = analyze_calls + 1
			return original_analyze(...)
		end

		local ok, err = pcall(function()
			hex.setup({ enabled = false })
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
			vim.api.nvim_set_current_buf(buf)
			vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

			vim.cmd("HexOutdated")
			eq(1, analyze_calls, "bare :HexOutdated dispatches to refresh")

			vim.api.nvim_buf_delete(buf, { force = true })
		end)
		core.analyze = original_analyze
		if not ok then
			error(err)
		end
	end)

	it("rejects an unknown subcommand through the existing error path", function()
		hex.setup({ enabled = false })
		local original_notify = vim.notify
		local errors = {}
		vim.notify = function(msg, level)
			if level == vim.log.levels.ERROR then
				errors[#errors + 1] = msg
			end
		end
		vim.cmd("HexOutdated bogus")
		vim.notify = original_notify

		eq(1, #errors, "unknown subcommand notifies exactly once")
	end)

	it(
		"does not dispatch 'setup' as a subcommand even though it is an exported function",
		function()
			hex.setup({ enabled = false })
			local original_config_setup = config.setup
			local setup_calls = 0
			config.setup = function(...)
				setup_calls = setup_calls + 1
				return original_config_setup(...)
			end

			local original_notify = vim.notify
			local errors = {}
			vim.notify = function(msg, level)
				if level == vim.log.levels.ERROR then
					errors[#errors + 1] = msg
				end
			end

			vim.cmd("HexOutdated setup")

			vim.notify = original_notify
			config.setup = original_config_setup

			eq(0, setup_calls, ":HexOutdated setup must not re-invoke M.setup/config.setup")
			eq(1, #errors, "'setup' hits the unknown-subcommand error path")
		end
	)
end)

describe("keymaps", function()
	it("binds subcommand actions and ignores other exported functions", function()
		local original_notify = vim.notify
		vim.notify = function() end
		hex.setup({ enabled = false, keymaps = { setup = "gS", toggle = "gT" } })
		vim.notify = original_notify
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/mix.exs")
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

		eq(false, has_keymap(buf, "gS"), "setup is not a bindable action")
		truthy(has_keymap(buf, "gT"), "toggle is bound")

		local before = core.state[buf].enabled
		vim.api.nvim_feedkeys("gT", "x", false)
		eq(not before, core.state[buf].enabled, "gT dispatches toggle")

		vim.api.nvim_buf_delete(buf, { force = true })
	end)
end)
