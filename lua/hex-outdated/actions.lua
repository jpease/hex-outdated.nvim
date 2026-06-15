local config = require("hex-outdated.config")

local M = {}

--- Return the dep whose row matches the cursor, or nil.
function M.dep_at_cursor(deps)
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	for _, dep in ipairs(deps or {}) do
		if dep.row == row then
			return dep
		end
	end
	return nil
end

--- Replace the requirement under the cursor with its suggested upgrade.
function M.upgrade(bufnr, dep)
	if not dep or not dep.suggested then
		vim.notify("hex-outdated: nothing to upgrade on this line", vim.log.levels.INFO)
		return
	end
	vim.api.nvim_buf_set_text(
		bufnr,
		dep.row,
		dep.col_start,
		dep.row,
		dep.col_end,
		{ dep.suggested }
	)
end

--- Open the package's hex.pm page in a browser.
function M.open(dep)
	if not dep then
		vim.notify("hex-outdated: no dependency on this line", vim.log.levels.INFO)
		return
	end
	vim.ui.open("https://hex.pm/packages/" .. dep.name)
end

-- Build a requirement string for an inserted version, preserving the operator style.
local function requirement_for(op, version_str)
	if op == "~>" then
		local major, minor = version_str:match("^(%d+)%.(%d+)")
		if major and minor then
			return string.format("~> %s.%s", major, minor)
		end
	end
	return string.format("== %s", version_str)
end

--- Open a floating window listing published versions for the dep; selecting one
--- (Enter) inserts it into the requirement; `q`/<Esc> closes.
--- `fetch(name, cb)` is injected by the caller (wraps hex_api.get_package).
function M.versions(bufnr, dep, fetch)
	if not dep then
		vim.notify("hex-outdated: no dependency on this line", vim.log.levels.INFO)
		return
	end
	fetch(dep.name, function(res)
		if res.error or not res.versions or #res.versions == 0 then
			vim.notify("hex-outdated: " .. (res.error or "no versions found"), vim.log.levels.WARN)
			return
		end
		vim.schedule(function()
			local lines = res.versions -- newest-first per hex.pm ordering
			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.bo[buf].modifiable = false
			local width = 20
			for _, l in ipairs(lines) do
				width = math.max(width, #l + 2)
			end
			local height = math.min(#lines, config.options.popup.max_height)
			local win = vim.api.nvim_open_win(buf, true, {
				relative = "cursor",
				row = 1,
				col = 0,
				width = width,
				height = height,
				border = config.options.popup.border,
				style = "minimal",
			})
			local function close()
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_win_close(win, true)
				end
			end
			vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
			vim.keymap.set("n", "<esc>", close, { buffer = buf, nowait = true })
			vim.keymap.set("n", "<cr>", function()
				local selected = vim.api.nvim_get_current_line()
				close()
				if vim.api.nvim_buf_is_valid(bufnr) then
					vim.api.nvim_buf_set_text(
						bufnr,
						dep.row,
						dep.col_start,
						dep.row,
						dep.col_end,
						{ requirement_for(dep.op, selected) }
					)
				end
			end, { buffer = buf, nowait = true })
		end)
	end)
end

return M
