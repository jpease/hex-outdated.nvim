-- Buffer actions against real Neovim: in-place requirement rewriting and the
-- published-versions floating window.
local actions = require("hex-outdated.actions")
local config = require("hex-outdated.config")
local hex_api = require("hex-outdated.hex_api")
local fallback = require("hex-outdated.parser.fallback")
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

-- Run `fn` with hex_api.get_package answered by `fetch(name, cb)`.
local function with_fetch(fetch, fn)
	local original = hex_api.get_package
	hex_api.get_package = function(name, _, cb)
		fetch(name, cb)
	end
	local ok, err = pcall(fn)
	hex_api.get_package = original
	if not ok then
		error(err, 0)
	end
end

local function versions(buf, dep, fetch)
	with_fetch(fetch, function()
		actions.versions(buf, dep)
	end)
end

local function info(buf, dep, fetch)
	with_fetch(fetch, function()
		actions.info(buf, dep)
	end)
end

local function select_first_version(buf, dep, list)
	vim.api.nvim_set_current_buf(buf)
	versions(buf, dep, function(_, cb)
		cb({ versions = list })
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

	it(
		"explains a missing rewrite for a non-rewritable operator apart from nothing-newer",
		function()
			local line = '      {:jason, "< 2.0.0"},'
			local buf = mix_buf(line)
			local notified = {}
			local original_notify = vim.notify
			vim.notify = function(msg, level)
				notified[#notified + 1] = { msg = msg, level = level }
			end

			actions.upgrade(buf, {
				row = 0,
				col_start = 16,
				col_end = 25,
				requirement = "< 2.0.0",
				op = "<",
				status = "upgradable",
			})
			actions.upgrade(buf, { row = 0, col_start = 16, col_end = 25, status = "up_to_date" })

			vim.notify = original_notify
			eq(2, #notified)
			eq(vim.log.levels.INFO, notified[1].level)
			eq(vim.log.levels.INFO, notified[2].level)
			truthy(notified[1].msg ~= notified[2].msg, "upgradable dep gets its own explanation")
			eq(line, vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "line unchanged")
		end
	)

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
		versions(buf, dep, fetch)
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
		local level
		local original_notify = vim.notify
		vim.notify = function(_, l)
			level = l
		end

		versions(buf, { name = "jason" }, function(_, cb)
			cb({ versions = {}, all_retired = true })
		end)

		vim.notify = original_notify
		eq(vim.log.levels.WARN, level)
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

		versions(origin, { name = "jason" }, function(_, cb)
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

		versions(origin, { name = "jason" }, function(_, cb)
			callback = cb
		end)
		vim.api.nvim_win_set_cursor(0, { 1, 4 })
		callback({ versions = { "1.4.5" } })

		local ok, err = pcall(scheduled)
		vim.schedule = original_schedule
		is_true(ok, tostring(err))
		is_nil(float_win(), "no stale float opened")
	end)

	it("refuses a stale dependency snapshot rather than fetch the old package", function()
		local buf = mix_buf('      {:jason, "~> 1.4"},')
		vim.api.nvim_set_current_buf(buf)
		local dep = {
			name = "jason",
			changedtick = vim.api.nvim_buf_get_changedtick(buf),
		}
		-- Simulate an edit landing after analysis but before the action runs.
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '      {:phoenix, "~> 1.7"},' })

		local fetched
		versions(buf, dep, function(name, cb)
			fetched = name
			cb({ versions = { "1.4.5" } })
		end)

		is_nil(fetched, "must not fetch a package from a stale dependency snapshot")
		is_nil(float_win(), "no float opened from a stale dependency snapshot")
	end)

	it("discards a fetch result invalidated by an edit that leaves the cursor in place", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local dep = {
			name = "jason",
			changedtick = vim.api.nvim_buf_get_changedtick(buf),
		}
		local callback
		versions(buf, dep, function(_, cb)
			callback = cb
		end)

		-- Edit the dependency's own line without moving the cursor off it.
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '      {:phoenix, "~> 1.7"},' })
		truthy(callback, "fetch was started before the edit")
		callback({ versions = { "1.4.5" } })

		vim.wait(100, function()
			return float_win() ~= nil
		end, 5)

		is_nil(float_win(), "no stale float opened for the invalidated fetch")
	end)
end)

describe("actions.versions stale results", function()
	it("opens the picker from stale cached versions on a transient error", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local dep =
			{ name = "jason", package = "jason", row = 0, col_start = 16, col_end = 22, op = "~>" }
		versions(buf, dep, function(_, cb)
			cb({ error = "request timed out", versions = { "2.0.0", "1.0.0" } })
		end)

		vim.wait(500, function()
			return float_win() ~= nil
		end, 5)

		local win = float_win()
		truthy(win, "versions float opened despite the transient error")
		local fbuf = vim.api.nvim_win_get_buf(win)
		local lines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
		eq(3, #lines, "header line plus the two cached versions")
		eq(
			{ "2.0.0", "1.0.0" },
			{ lines[2], lines[3] },
			"cached versions preserved after the header"
		)
		is_true(
			lines[1] ~= "2.0.0" and lines[1] ~= "1.0.0",
			"header row does not read as a version"
		)
		eq({ 2, 0 }, vim.api.nvim_win_get_cursor(win), "cursor starts on the first version row")
		vim.api.nvim_win_close(win, true)
	end)

	it("notifies and opens no picker on an error with no usable versions", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local notified
		local original_notify = vim.notify
		vim.notify = function(msg)
			notified = msg
		end

		versions(buf, { name = "jason" }, function(_, cb)
			cb({ error = "request timed out" })
		end)

		vim.notify = original_notify
		contains(notified, "request timed out")
		is_nil(float_win(), "no versions float opened")
	end)

	it("never reuses stale versions for a not_found (404) result", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local notified
		local original_notify = vim.notify
		vim.notify = function(msg)
			notified = msg
		end

		versions(buf, { name = "jason" }, function(_, cb)
			cb({ error = "not found", not_found = true })
		end)

		vim.notify = original_notify
		contains(notified, "not found")
		is_nil(float_win(), "no versions float opened for a 404")
	end)

	it(
		"rewrites the requirement from the stale list's first version row exactly as a fresh list would",
		function()
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
			vim.api.nvim_set_current_buf(buf)
			versions(buf, dep, function(_, cb)
				cb({ error = "request timed out", versions = { "2.0.0", "1.0.0" } })
			end)

			vim.wait(500, function()
				return float_win() ~= nil
			end, 5)
			local win = float_win()
			truthy(win, "versions float opened")
			-- Cursor already parked on the first version row; select it directly.
			vim.api.nvim_feedkeys(
				vim.api.nvim_replace_termcodes("<cr>", true, false, true),
				"x",
				false
			)

			eq('      {:dep, "~> 2.0"},', vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
		end
	)

	it("does nothing when <CR> is pressed on the stale header row", function()
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
		vim.api.nvim_set_current_buf(buf)
		versions(buf, dep, function(_, cb)
			cb({ error = "request timed out", versions = { "2.0.0", "1.0.0" } })
		end)

		vim.wait(500, function()
			return float_win() ~= nil
		end, 5)
		local win = float_win()
		truthy(win, "versions float opened")
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<cr>", true, false, true), "x", false)

		truthy(vim.api.nvim_win_is_valid(win), "float stays open when <CR> hits the header")
		eq(line, vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "buffer unchanged")
		vim.api.nvim_win_close(win, true)
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
		versions(buf, dep, fetch)

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
		local deps = fallback.parse_lines({ line })

		vim.api.nvim_win_set_cursor(0, { 1, line:find("~> 1.0", 1, true) - 1 })
		eq("first", actions.dep_at_cursor(deps).name)

		vim.api.nvim_win_set_cursor(0, { 1, line:find("~> 2.0", 1, true) - 1 })
		eq("second", actions.dep_at_cursor(deps).name)
	end)

	it("selects each dependency by requirement column on a compact Treesitter line", function()
		local added_ok, added = pcall(vim.treesitter.language.add, "elixir")
		if not (added_ok and added) then
			if vim.env.HEX_OUTDATED_REQUIRE_TS == "1" then
				error("elixir parser not installed but HEX_OUTDATED_REQUIRE_TS=1")
			end
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
		info(buf, dep, function(name, cb)
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

	it("classifies the dep once the fetch resolves", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local dep = { name = "jason", requirement = "~> 1.0", status = "loading" }
		local loading_lines = actions._info_lines(dep)
		info(buf, dep, function(_, cb)
			cb({ latest = "1.4.5", versions = { "1.0.0", "1.4.5" } })
		end)

		vim.wait(500, function()
			return float_win() ~= nil
		end, 5)

		local win = float_win()
		truthy(win, "float opened")
		local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
		eq("upgradable", dep.status, "dep classified from the fetch result")
		eq("1.4.5", dep.latest)
		eq(actions._info_lines(dep), lines, "float shows the classified dep")
		truthy(lines[2] ~= loading_lines[2], "requirement note no longer pending")
		vim.api.nvim_win_close(win, true)
	end)

	it("shows a failed fetch as failed rather than still loading", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local dep = { name = "jason", requirement = "~> 1.0", status = "loading" }
		local loading_lines = actions._info_lines(dep)
		info(buf, dep, function(_, cb)
			cb({ error = "http 500" })
		end)

		vim.wait(500, function()
			return float_win() ~= nil
		end, 5)

		local win = float_win()
		truthy(win, "float opened")
		local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
		eq("error", dep.status, "fetch failure is terminal")
		is_nil(dep.latest)
		truthy(lines[2] ~= loading_lines[2], "requirement note no longer pending")
		truthy(lines[4] ~= loading_lines[4], "latest row no longer loading")
		vim.api.nvim_win_close(win, true)
	end)

	it("reports a missing package as invalid", function()
		local buf = mix_buf('      {:nope, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local dep = { name = "nope", requirement = "~> 1.0", status = "loading" }
		info(buf, dep, function(_, cb)
			cb({ error = "package not found", not_found = true })
		end)

		vim.wait(500, function()
			return float_win() ~= nil
		end, 5)

		local win = float_win()
		truthy(win, "float opened")
		eq("invalid", dep.status)
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

		info(origin, { name = "jason", requirement = "~> 1.0", status = "loading" }, function(_, cb)
			callback = cb
		end)
		vim.api.nvim_buf_delete(origin, { force = true })

		local ok, err = pcall(function()
			callback({ latest = "1.4.5", versions = { "1.4.5" } })
			if scheduled then
				scheduled()
			end
		end)
		vim.schedule = original_schedule
		is_true(ok, tostring(err))
		is_nil(float_win(), "no stale float opened")
	end)

	it("refuses a stale dependency snapshot rather than fetch the old package", function()
		local buf = mix_buf('      {:jason, "~> 1.4"},')
		vim.api.nvim_set_current_buf(buf)
		local dep = {
			name = "jason",
			requirement = "~> 1.0",
			changedtick = vim.api.nvim_buf_get_changedtick(buf),
		}
		-- Simulate an edit landing after analysis but before the action runs.
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '      {:phoenix, "~> 1.7"},' })

		local fetched
		info(buf, dep, function(name, cb)
			fetched = name
			cb({ latest = "1.4.5", versions = { "1.4.5" } })
		end)

		is_nil(fetched, "must not fetch a package from a stale dependency snapshot")
		is_nil(float_win(), "no float opened from a stale dependency snapshot")
	end)

	it("discards a fetch result invalidated by an edit that leaves the cursor in place", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local dep = {
			name = "jason",
			requirement = "~> 1.0",
			status = "loading",
			changedtick = vim.api.nvim_buf_get_changedtick(buf),
		}
		local callback
		info(buf, dep, function(_, cb)
			callback = cb
		end)

		-- Edit the dependency's own line without moving the cursor off it.
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '      {:phoenix, "~> 1.7"},' })
		truthy(callback, "fetch was started before the edit")
		callback({ latest = "1.4.5", versions = { "1.0.0", "1.4.5" } })

		vim.wait(100, function()
			return float_win() ~= nil
		end, 5)

		eq("loading", dep.status, "dep not mutated by a fetch invalidated during the request")
		is_nil(dep.latest, "dep.latest not mutated by a fetch invalidated during the request")
		is_nil(float_win(), "no stale float opened for the invalidated fetch")
	end)
end)
