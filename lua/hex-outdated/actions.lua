local config = require("hex-outdated.config")
local lock = require("hex-outdated.lock")
local version = require("hex-outdated.version")

local M = {}

local function package_name(dep)
	return dep.package or dep.name
end

local function context_is_current(win, bufnr, cursor)
	if
		not (
			vim.api.nvim_win_is_valid(win)
			and vim.api.nvim_buf_is_valid(bufnr)
			and vim.api.nvim_get_current_win() == win
			and vim.api.nvim_get_current_buf() == bufnr
			and vim.api.nvim_win_get_buf(win) == bufnr
		)
	then
		return false
	end
	local current = vim.api.nvim_win_get_cursor(win)
	return not cursor or (current[1] == cursor[1] and current[2] == cursor[2])
end

local function replace_requirement(bufnr, dep, replacement)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	if dep.changedtick and vim.api.nvim_buf_get_changedtick(bufnr) ~= dep.changedtick then
		vim.notify(
			"hex-outdated: dependency changed since it was analyzed; refresh and try again",
			vim.log.levels.WARN
		)
		return false
	end
	local ok, current =
		pcall(vim.api.nvim_buf_get_text, bufnr, dep.row, dep.col_start, dep.row, dep.col_end, {})
	if not ok or (dep.requirement and current[1] ~= dep.requirement) then
		vim.notify(
			"hex-outdated: dependency position is stale; refresh and try again",
			vim.log.levels.WARN
		)
		return false
	end
	vim.api.nvim_buf_set_text(bufnr, dep.row, dep.col_start, dep.row, dep.col_end, { replacement })
	return true
end

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
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1] - 1
	local col = cursor[2]
	local nearest
	local nearest_distance
	for _, dep in ipairs(deps or {}) do
		if dep.row == row then
			if dep.col_start and dep.col_end then
				if col >= dep.col_start and col < dep.col_end then
					return dep
				end
				local distance
				if col < dep.col_start then
					distance = dep.col_start - col
				else
					distance = col - dep.col_end
				end
				if nearest_distance == nil or distance < nearest_distance then
					nearest = dep
					nearest_distance = distance
				end
			elseif not nearest then
				nearest = dep
			end
		end
	end
	return nearest
end

--- Replace the requirement under the cursor with its suggested upgrade.
function M.upgrade(bufnr, dep)
	if not dep or not dep.suggested then
		if dep and (dep.status == "upgradable" or dep.status == "outdated") then
			local op = dep_op(dep)
			vim.notify(
				string.format(
					"hex-outdated: no automatic rewrite for '%s' requirements; "
						.. "use :HexOutdated versions to choose one",
					op or "?"
				),
				vim.log.levels.INFO
			)
			return
		end
		vim.notify("hex-outdated: nothing to upgrade on this line", vim.log.levels.INFO)
		return
	end
	replace_requirement(bufnr, dep, dep.suggested)
end

--- Open the package's hex.pm page in a browser.
function M.open(dep)
	if not dep then
		vim.notify("hex-outdated: no dependency on this line", vim.log.levels.INFO)
		return
	end
	vim.ui.open("https://hex.pm/packages/" .. package_name(dep))
end

-- Build a requirement string for an inserted version, preserving the operator style.
-- Prerelease versions always keep the full version string under ~> so the operand
-- actually selects the chosen release (a stable ~> x.y operand would not match it).
local function format_operator(dep, op, operand)
	local raw = dep.requirement or ""
	local leading, _, spacing = raw:match("^(%s*)([~><=!]+)(%s*)")
	local trailing = raw:match("(%s*)$") or ""
	if not leading then
		leading, spacing = "", " "
	end
	return leading .. op .. spacing .. operand .. trailing
end

local function requirement_for(dep, version_str)
	local op = dep_op(dep)
	if op == "~>" then
		if version_str:find("-", 1, true) then
			return format_operator(dep, op, version_str)
		end
		local req = dep.requirement and version.parse_requirement(dep.requirement)
		if req and req.version.precision >= 3 then
			local major, minor, patch = version_str:match("^(%d+)%.(%d+)%.(%d+)")
			if major and minor and patch then
				return format_operator(dep, op, string.format("%s.%s.%s", major, minor, patch))
			end
		end
		local major, minor = version_str:match("^(%d+)%.(%d+)")
		if major and minor then
			return format_operator(dep, op, string.format("%s.%s", major, minor))
		end
	end
	if op == "==" and dep.requirement and dep.requirement:match("^%s*%d") then
		local leading = dep.requirement:match("^(%s*)") or ""
		local trailing = dep.requirement:match("(%s*)$") or ""
		return leading .. version_str .. trailing
	end
	if op then
		return format_operator(dep, op, version_str)
	end
	return "== " .. version_str
end

-- Open a small scratch float at the cursor showing `lines`. Shared scaffold for
-- the versions picker and the info popup. The buffer is non-modifiable and wiped
-- when its window hides so it does not linger; the filetype lets colorschemes and
-- statuslines target it. Width fits the content (>= opts.min_width); height fits
-- the line count, capped at opts.max_height when given. Returns win, buf — or nil
-- when buffer creation fails. opts: { filetype, enter, min_width, max_height? }.
local function open_cursor_float(lines, opts)
	local buf = vim.api.nvim_create_buf(false, true)
	if buf == 0 then
		return nil
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = opts.filetype
	local width = opts.min_width
	for _, l in ipairs(lines) do
		width = math.max(width, #l + 2)
	end
	local height = opts.max_height and math.min(#lines, opts.max_height) or #lines
	local win = vim.api.nvim_open_win(buf, opts.enter or false, {
		relative = "cursor",
		row = 1,
		col = 0,
		width = width,
		height = height,
		border = config.options.popup.border,
		style = "minimal",
	})
	return win, buf
end

--- Open a floating window listing published versions for the dep; selecting one
--- (Enter) inserts it into the requirement; `q`/<Esc> closes.
--- `fetch(name, cb)` is injected by the caller (wraps hex_api.get_package).
function M.versions(bufnr, dep, fetch)
	if not dep then
		vim.notify("hex-outdated: no dependency on this line", vim.log.levels.INFO)
		return
	end
	local origin_win = vim.api.nvim_get_current_win()
	local origin_cursor = vim.api.nvim_win_get_cursor(origin_win)
	fetch(package_name(dep), function(res)
		if res.error or not res.versions or #res.versions == 0 then
			local msg = res.error
				or (res.all_retired and "no active versions found (all releases are retired)")
				or "no versions found"
			vim.notify("hex-outdated: " .. msg, vim.log.levels.WARN)
			return
		end
		vim.schedule(function()
			if not context_is_current(origin_win, bufnr, origin_cursor) then
				return
			end
			local lines = res.versions -- newest-first per hex.pm ordering
			local win, buf = open_cursor_float(lines, {
				filetype = "hex-outdated-versions",
				enter = true, -- focus the picker so the user can move + select
				min_width = 20,
				max_height = config.options.popup.max_height,
			})
			if not win then
				return
			end
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
					replace_requirement(bufnr, dep, requirement_for(dep, selected))
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
	local origin_win = vim.api.nvim_get_current_win()
	local origin_cursor = vim.api.nvim_win_get_cursor(origin_win)

	local function open()
		vim.schedule(function()
			if not context_is_current(origin_win, origin, origin_cursor) then
				return
			end
			local lines = M._info_lines(dep)
			local win = open_cursor_float(lines, {
				filetype = "hex-outdated-info",
				enter = false, -- read-only hover: keep focus in the source buffer
				min_width = 24,
			})
			if not win then
				return
			end
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
		fetch(package_name(dep), function(res)
			if res and res.latest then
				dep.latest = res.latest
			end
			open()
		end)
	end
end

return M
