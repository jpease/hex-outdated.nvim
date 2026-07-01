-- Buffer actions against real Neovim: in-place requirement rewriting and the
-- published-versions floating window.
local actions = require("hex-outdated.actions")
local config = require("hex-outdated.config")
local parser = require("hex-outdated.parser")

config.setup({})

local function mix_buf(line)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
	return buf
end

local function float_win()
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(w).relative ~= "" then
			return w
		end
	end
end

local function select_first_version(buf, dep, versions)
	vim.api.nvim_set_current_buf(buf)
	actions.versions(buf, dep, function(_, cb)
		cb({ versions = versions })
	end)
	vim.wait(500, function()
		return float_win() ~= nil
	end, 5)
	local win = float_win()
	truthy(win, "versions float opened")
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<cr>", true, false, true), "x", false)
end

describe("actions.upgrade", function()
	it("replaces the requirement span with the suggested string", function()
		local line = '      {:jason, "~> 1.0"},'
		local buf = mix_buf(line)
		-- col_start/col_end bracket the requirement text inside the quotes.
		local s = line:find('"') -- 1-indexed opening quote
		local dep = {
			row = 0,
			col_start = s, -- 0-indexed position just inside the opening quote
			col_end = s + #"~> 1.0",
			requirement = "~> 1.0",
			changedtick = vim.api.nvim_buf_get_changedtick(buf),
			suggested = "~> 1.4",
		}
		actions.upgrade(buf, dep)
		eq('      {:jason, "~> 1.4"},', vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
	end)

	it("does nothing when there is no suggestion", function()
		local line = '      {:jason, "~> 1.4"},'
		local buf = mix_buf(line)
		actions.upgrade(buf, { row = 0, col_start = 16, col_end = 22 })
		eq(line, vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "line unchanged")
	end)

	it("does not edit when the buffer changed after parsing", function()
		local line = '      {:jason, "~> 1.0"},'
		local buf = mix_buf(line)
		local s = line:find('"')
		local dep = {
			row = 0,
			col_start = s,
			col_end = s + #"~> 1.0",
			requirement = "~> 1.0",
			changedtick = vim.api.nvim_buf_get_changedtick(buf),
			suggested = "~> 1.4",
		}
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "XX" .. line })

		actions.upgrade(buf, dep)

		eq("XX" .. line, vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
	end)
end)

describe("actions.versions float", function()
	it("opens a wiped, filetyped float listing the versions", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local dep = {
			name = "local_app",
			package = "jason",
			row = 0,
			col_start = 16,
			col_end = 22,
			op = "~>",
		}
		local requested
		local fetch = function(name, cb)
			requested = name
			cb({ versions = { "1.4.5", "1.4.4", "1.0.0" } })
		end
		actions.versions(buf, dep, fetch)
		eq("jason", requested, "Hex alias used for version lookup")

		-- The window is created inside vim.schedule; wait for it to appear.
		vim.wait(500, function()
			return float_win() ~= nil
		end, 5)

		local win = float_win()
		truthy(win, "a floating window opened")
		local fbuf = vim.api.nvim_win_get_buf(win)
		eq({ "1.4.5", "1.4.4", "1.0.0" }, vim.api.nvim_buf_get_lines(fbuf, 0, -1, false))
		eq("wipe", vim.bo[fbuf].bufhidden, "scratch buffer is wiped on close")
		eq("hex-outdated-versions", vim.bo[fbuf].filetype)
		is_true(vim.wo[win].cursorline, "cursorline on for selection")
		vim.api.nvim_win_close(win, true)
	end)

	it("does not offer a popup when every release is retired", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local notified
		local original_notify = vim.notify
		vim.notify = function(msg)
			notified = msg
		end

		actions.versions(buf, { name = "jason" }, function(_, cb)
			cb({ versions = {}, all_retired = true })
		end)

		vim.notify = original_notify
		contains(notified, "all releases are retired")
		is_nil(float_win(), "no versions float opened")
	end)

	it("cancels cleanly when the origin buffer closes before fetch completion", function()
		local origin = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(origin)
		local callback
		local scheduled
		local original_schedule = vim.schedule
		vim.schedule = function(fn)
			scheduled = fn
		end

		actions.versions(origin, { name = "jason" }, function(_, cb)
			callback = cb
		end)
		vim.api.nvim_buf_delete(origin, { force = true })
		callback({ versions = { "1.4.5" } })

		local ok, err = pcall(scheduled)
		vim.schedule = original_schedule
		is_true(ok, tostring(err))
		is_nil(float_win(), "no stale float opened")
	end)

	it("cancels cleanly when the cursor moves before fetch completion", function()
		local origin = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(origin)
		local callback
		local scheduled
		local original_schedule = vim.schedule
		vim.schedule = function(fn)
			scheduled = fn
		end

		actions.versions(origin, { name = "jason" }, function(_, cb)
			callback = cb
		end)
		vim.api.nvim_win_set_cursor(0, { 1, 4 })
		callback({ versions = { "1.4.5" } })

		local ok, err = pcall(scheduled)
		vim.schedule = original_schedule
		is_true(ok, tostring(err))
		is_nil(float_win(), "no stale float opened")
	end)
end)

describe("actions.versions prerelease selection", function()
	it("inserts the full prerelease version string under a pessimistic operator", function()
		local line = '      {:dep, "~> 1.0"},'
		local buf = mix_buf(line)
		local s = line:find('"')
		local dep = {
			name = "dep",
			row = 0,
			col_start = s,
			col_end = s + #"~> 1.0",
			requirement = "~> 1.0",
			changedtick = vim.api.nvim_buf_get_changedtick(buf),
			op = "~>",
		}
		local fetch = function(_, cb)
			cb({ versions = { "2.0.0-rc.1", "1.9.0" } })
		end
		vim.api.nvim_set_current_buf(buf)
		actions.versions(buf, dep, fetch)

		vim.wait(500, function()
			return float_win() ~= nil
		end, 5)

		local win = float_win()
		truthy(win, "float opened")
		-- select the first line (2.0.0-rc.1) and press Enter
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<cr>", true, false, true), "x", false)

		local result = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
		eq('      {:dep, "~> 2.0.0-rc.1"},', result)
	end)

	it("preserves comparison operators when inserting a selected version", function()
		for _, case in ipairs({
			{ requirement = ">= 1.0.0", expected = ">= 2.0.0" },
			{ requirement = "< 3.0.0", expected = "< 2.0.0" },
			{ requirement = "!= 1.5.0", expected = "!= 2.0.0" },
			{ requirement = "1.0.0", expected = "2.0.0" },
		}) do
			local line = string.format('      {:dep, "%s"},', case.requirement)
			local buf = mix_buf(line)
			local s = line:find('"')
			select_first_version(buf, {
				name = "dep",
				row = 0,
				col_start = s,
				col_end = s + #case.requirement,
				requirement = case.requirement,
				changedtick = vim.api.nvim_buf_get_changedtick(buf),
			}, { "2.0.0" })

			eq(
				string.format('      {:dep, "%s"},', case.expected),
				vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1],
				case.requirement
			)
		end
	end)

	it(
		"preserves the requirement's precision when inserting a selected version under ~>",
		function()
			for _, case in ipairs({
				{ requirement = "~> 1.6.2", selected = "1.6.5", expected = "~> 1.6.5" },
				{ requirement = "~> 1.0", selected = "1.4.2", expected = "~> 1.4" },
			}) do
				local line = string.format('      {:dep, "%s"},', case.requirement)
				local buf = mix_buf(line)
				local s = line:find('"')
				select_first_version(buf, {
					name = "dep",
					row = 0,
					col_start = s,
					col_end = s + #case.requirement,
					requirement = case.requirement,
					changedtick = vim.api.nvim_buf_get_changedtick(buf),
				}, { case.selected })

				eq(
					string.format('      {:dep, "%s"},', case.expected),
					vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1],
					case.requirement
				)
			end
		end
	)
end)

describe("actions.dep_at_cursor", function()
	it("selects each dependency by requirement column on a compact fallback line", function()
		local line = 'defp deps, do: [{:first, "~> 1.0"}, {:second, "~> 2.0"}]'
		local buf = mix_buf(line)
		vim.api.nvim_set_current_buf(buf)
		local deps = parser.parse_lines({ line })

		vim.api.nvim_win_set_cursor(0, { 1, line:find("~> 1.0", 1, true) - 1 })
		eq("first", actions.dep_at_cursor(deps).name)

		vim.api.nvim_win_set_cursor(0, { 1, line:find("~> 2.0", 1, true) - 1 })
		eq("second", actions.dep_at_cursor(deps).name)
	end)

	it("selects each dependency by requirement column on a compact Treesitter line", function()
		local added_ok, added = pcall(vim.treesitter.language.add, "elixir")
		if not (added_ok and added) then
			skip("elixir parser not installed")
		end
		local line = '  defp deps, do: [{:first, "~> 1.0"}, {:second, "~> 2.0"}]'
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"defmodule Compact.MixProject do",
			line,
			"end",
		})
		vim.bo[buf].filetype = "elixir"
		vim.api.nvim_set_current_buf(buf)
		local deps = parser.parse_buffer(buf)

		vim.api.nvim_win_set_cursor(0, { 2, line:find("~> 1.0", 1, true) - 1 })
		eq("first", actions.dep_at_cursor(deps).name)

		vim.api.nvim_win_set_cursor(0, { 2, line:find("~> 2.0", 1, true) - 1 })
		eq("second", actions.dep_at_cursor(deps).name)
	end)
end)

describe("actions.open", function()
	it("opens the effective Hex package for an aliased dependency", function()
		local original = vim.ui.open
		local opened
		vim.ui.open = function(url)
			opened = url
		end

		actions.open({ name = "local_app", package = "actual_package" })

		vim.ui.open = original
		eq("https://hex.pm/packages/actual_package", opened)
	end)
end)

describe("actions.info float", function()
	it("opens a non-focusing float with the detail rows", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local dep = {
			name = "local_app",
			package = "jason",
			requirement = "~> 1.0",
			status = "upgradable",
			locked = "1.2.0",
		}
		local requested
		actions.info(dep, function(name, cb)
			requested = name
			cb({ latest = "1.4.5", versions = { "1.4.5" } })
		end)
		eq("jason", requested, "Hex alias used for detail lookup")

		vim.wait(500, function()
			return float_win() ~= nil
		end, 5)

		local win = float_win()
		truthy(win, "float opened")
		local fbuf = vim.api.nvim_win_get_buf(win)
		local lines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
		eq("local_app", lines[1])
		eq("hex-outdated-info", vim.bo[fbuf].filetype)
		vim.api.nvim_win_close(win, true)
	end)

	it("cancels cleanly when the origin buffer closes before fetch completion", function()
		local origin = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(origin)
		local callback
		local scheduled
		local original_schedule = vim.schedule
		vim.schedule = function(fn)
			scheduled = fn
		end

		actions.info({ name = "jason", requirement = "~> 1.0", status = "loading" }, function(_, cb)
			callback = cb
		end)
		vim.api.nvim_buf_delete(origin, { force = true })
		callback({ latest = "1.4.5", versions = { "1.4.5" } })

		local ok, err = pcall(scheduled)
		vim.schedule = original_schedule
		is_true(ok, tostring(err))
		is_nil(float_win(), "no stale float opened")
	end)
end)
