-- Buffer actions against real Neovim: in-place requirement rewriting and the
-- published-versions floating window.
local actions = require("hex-outdated.actions")
local config = require("hex-outdated.config")

config.setup({})

local function mix_buf(line)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
	return buf
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
end)

describe("actions.versions float", function()
	it("opens a wiped, filetyped float listing the versions", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		local dep = { name = "jason", row = 0, col_start = 16, col_end = 22, op = "~>" }
		local fetch = function(_, cb)
			cb({ versions = { "1.4.5", "1.4.4", "1.0.0" } })
		end
		actions.versions(buf, dep, fetch)

		-- The window is created inside vim.schedule; wait for it to appear.
		local function float_win()
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_get_config(w).relative ~= "" then
					return w
				end
			end
		end
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
end)

describe("actions.info float", function()
	it("opens a non-focusing float with the detail rows", function()
		local buf = mix_buf('      {:jason, "~> 1.0"},')
		vim.api.nvim_set_current_buf(buf)
		local dep = {
			name = "jason",
			requirement = "~> 1.0",
			status = "upgradable",
			latest = "1.4.5",
			locked = "1.2.0",
		}
		actions.info(dep, function(_, cb)
			cb({ latest = "1.4.5", versions = { "1.4.5" } })
		end)

		local function float_win()
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_get_config(w).relative ~= "" then
					return w
				end
			end
		end
		vim.wait(500, function()
			return float_win() ~= nil
		end, 5)

		local win = float_win()
		truthy(win, "float opened")
		local fbuf = vim.api.nvim_win_get_buf(win)
		local lines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
		eq("jason", lines[1])
		eq("hex-outdated-info", vim.bo[fbuf].filetype)
		vim.api.nvim_win_close(win, true)
	end)
end)
