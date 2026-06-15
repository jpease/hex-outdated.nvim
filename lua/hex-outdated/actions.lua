local config = require("hex-outdated.config")
local lock = require("hex-outdated.lock")
local version = require("hex-outdated.version")

local M = {}

-- The operator to preserve when inserting a version: prefer the classified
-- `dep.op`, but fall back to parsing the raw requirement so the popup works
-- even on deps that were never classified (e.g. a fetch failed).
local function dep_op(dep)
	if dep.op then
		return dep.op
	end
	local req = dep.requirement and version.parse_requirement(dep.requirement)
	return req and req.op
end

-- Note describing where the requirement sits relative to the latest release.
local function requirement_note(status)
	if status == "up_to_date" then
		return "allows latest"
	elseif status == "upgradable" or status == "outdated" then
		return "below latest"
	elseif status == "invalid" then
		return "no published match"
	end
	return "checking…"
end

--- Build the detail-float rows for a dep (pure; no Neovim APIs).
function M._info_lines(dep)
	local lines = { dep.name or "?" }
	local req_note = requirement_note(dep.status)
	lines[#lines + 1] = string.format("requirement  %s   %s", dep.requirement or "?", req_note)
	if dep.locked then
		local note
		if dep.requirement and lock.out_of_range(dep.requirement, dep.locked) then
			note = "not satisfied by requirement"
		elseif dep.latest and lock.behind(dep.locked, dep.latest) then
			note = "behind latest"
		elseif dep.latest then
			note = "up to date"
		else
			note = ""
		end
		lines[#lines + 1] = string.format("locked       %s   %s", dep.locked, note)
	else
		lines[#lines + 1] = "locked       (not in mix.lock)"
	end
	local latest_str = dep.latest or (dep.status == "invalid" and "—" or "loading")
	lines[#lines + 1] = string.format("latest       %s", latest_str)
	return lines
end

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
			if buf == 0 then
				return
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.bo[buf].modifiable = false
			-- Wipe the scratch buffer when its window closes so it does not linger,
			-- and give it a filetype so colorschemes/statusline can target it.
			vim.bo[buf].bufhidden = "wipe"
			vim.bo[buf].filetype = "hex-outdated-versions"
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
			-- Highlight the active row so the selection target is obvious.
			vim.wo[win].cursorline = true
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
						{ requirement_for(dep_op(dep), selected) }
					)
				end
			end, { buffer = buf, nowait = true })
		end)
	end)
end

--- Open a read-only detail float for `dep` (requirement / locked / latest).
--- `fetch(name, cb)` is injected to resolve `latest` when it is not yet known.
function M.info(dep, fetch)
	if not dep then
		vim.notify("hex-outdated: no dependency on this line", vim.log.levels.INFO)
		return
	end
	local origin = vim.api.nvim_get_current_buf()

	local function open()
		vim.schedule(function()
			local lines = M._info_lines(dep)
			local buf = vim.api.nvim_create_buf(false, true)
			if buf == 0 then
				return
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.bo[buf].modifiable = false
			vim.bo[buf].bufhidden = "wipe"
			vim.bo[buf].filetype = "hex-outdated-info"
			local width = 24
			for _, l in ipairs(lines) do
				width = math.max(width, #l + 2)
			end
			local win = vim.api.nvim_open_win(buf, false, {
				relative = "cursor",
				row = 1,
				col = 0,
				width = width,
				height = #lines,
				border = config.options.popup.border,
				style = "minimal",
			})
			-- Hover-style: close as soon as the user moves or leaves.
			vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "InsertEnter" }, {
				buffer = origin,
				once = true,
				callback = function()
					if vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_win_close(win, true)
					end
				end,
			})
		end)
	end

	if dep.latest or dep.status == "invalid" then
		open()
	else
		fetch(dep.name, function(res)
			if res and res.latest then
				dep.latest = res.latest
			end
			open()
		end)
	end
end

return M
