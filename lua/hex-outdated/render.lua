local config = require("hex-outdated.config")

local M = {}

local ns = vim.api.nvim_create_namespace("hex_outdated_virt")
local diag_ns = vim.api.nvim_create_namespace("hex_outdated_diag")

function M.clear(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	vim.diagnostic.reset(diag_ns, bufnr)
end

local function label_for(item, cfg)
	if item.status == "invalid" then
		return cfg.text.invalid
	elseif item.status == "loading" then
		return cfg.text.loading
	elseif item.status == "error" then
		return cfg.text.error
	end
	local tpl = cfg.text[item.status] or "%s"
	return string.format(tpl, item.latest or "")
end

-- Build the lens virt-line text + highlight for a locked dep.
local function lens_label(item, cfg)
	if item.latest and item.lock_behind then
		return string.format(cfg.text.lock_behind, item.locked, item.latest),
			cfg.highlight.lock_behind or "DiagnosticHint"
	elseif item.latest then
		return string.format(cfg.text.lock_current, item.locked), cfg.highlight.lock or "Comment"
	end
	return "locked " .. item.locked, cfg.highlight.lock or "Comment"
end

--- Pure: build the extmark + diagnostic plan for `items` against `cfg`,
--- `line_count`, and `opts`. No Neovim APIs are referenced here — every
--- input is a plain value/table, so this is safe to unit test without a
--- running Neovim instance.
---
--- items: list of { row, col_start, col_end, name, status, latest, suggested,
---                  locked?, lock_behind?, lock_out_of_range?, requirement? }
--- cfg: a config.options-shaped table (text/highlight sections)
--- line_count: number of lines in the target buffer
--- opts: optional table, e.g. { lens = true }
---
--- Returns { extmarks = { { row, col, opts }, ... }, diagnostics = { ... } },
--- where each `extmarks` entry's `opts` is exactly the third-argument table
--- nvim_buf_set_extmark expects, and `diagnostics` entries use the real
--- diagnostic field names with a symbolic `severity` ("error"/"warn") that
--- M.render translates when applying the plan.
function M.build_plan(items, cfg, line_count, opts)
	opts = opts or {}
	local extmarks = {}
	local diagnostics = {}
	for _, item in ipairs(items) do
		-- Skip stale items pointing past the buffer end (e.g. the file shrank
		-- between parse and render); set_extmark/diagnostics would otherwise throw.
		if item.row < line_count then
			-- Primary eol indicator (items reaching render are already non-"unknown").
			local hl = cfg.highlight[item.status] or "Comment"
			extmarks[#extmarks + 1] = {
				row = item.row,
				col = 0,
				opts = {
					virt_text = { { "  " .. label_for(item, cfg), hl } },
					virt_text_pos = "eol",
				},
			}
			if item.status == "invalid" then
				diagnostics[#diagnostics + 1] = {
					lnum = item.row,
					col = item.col_start or 0,
					end_col = item.col_end or (item.col_start or 0),
					severity = "error",
					message = string.format(
						"No published version of '%s' matches this requirement (latest: %s)",
						item.name or "?",
						item.latest or "unknown"
					),
					source = "hex-outdated",
				}
			end

			-- Lens virt-line (opt-in, only for deps with a lock entry).
			if opts.lens and item.locked then
				local text, lens_hl = lens_label(item, cfg)
				extmarks[#extmarks + 1] = {
					row = item.row,
					col = 0,
					opts = {
						virt_lines = { { { "  ↳ " .. text, lens_hl } } },
					},
				}
			end

			-- Stale-lock diagnostic.
			if item.lock_out_of_range then
				diagnostics[#diagnostics + 1] = {
					lnum = item.row,
					col = item.col_start or 0,
					end_col = item.col_end or (item.col_start or 0),
					severity = "warn",
					message = string.format(
						"mix.lock has %s %s, which no longer satisfies %q (run `mix deps.get`)",
						item.name or "?",
						item.locked or "?",
						item.requirement or "?"
					),
					source = "hex-outdated",
				}
			end
		end
	end
	return { extmarks = extmarks, diagnostics = diagnostics }
end

--- Draw virtual text + diagnostics for a buffer.
--- items: list of { row, col_start, col_end, name, status, latest, suggested,
---                  locked?, lock_behind?, lock_out_of_range?, requirement? }
--- opts: optional table, e.g. { lens = true }
function M.render(bufnr, items, opts)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	M.clear(bufnr)
	local cfg = config.options
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local plan = M.build_plan(items, cfg, line_count, opts)
	for _, mark in ipairs(plan.extmarks) do
		vim.api.nvim_buf_set_extmark(bufnr, ns, mark.row, mark.col, mark.opts)
	end
	-- Translate the plan's symbolic severity ("error"/"warn") to the real
	-- vim.diagnostic.severity constant here, at apply time — the pure
	-- builder never touches vim.* directly.
	local severity = {
		error = vim.diagnostic.severity.ERROR,
		warn = vim.diagnostic.severity.WARN,
	}
	local diagnostics = {}
	for i, diag in ipairs(plan.diagnostics) do
		diagnostics[i] = vim.tbl_extend("force", diag, { severity = severity[diag.severity] })
	end
	vim.diagnostic.set(diag_ns, bufnr, diagnostics, {})
end

--- Register default highlight links (only if not already defined by the user/theme).
function M.setup_highlights()
	local links = {
		HexOutdatedUpToDate = "DiagnosticOk",
		HexOutdatedUpgradable = "DiagnosticWarn",
		HexOutdatedOutdated = "DiagnosticWarn",
		HexOutdatedInvalid = "DiagnosticError",
		HexOutdatedLoading = "Comment",
		HexOutdatedError = "Comment",
		HexOutdatedLock = "Comment",
		HexOutdatedLockBehind = "DiagnosticHint",
	}
	for name, target in pairs(links) do
		vim.api.nvim_set_hl(0, name, { link = target, default = true })
	end
end

return M
