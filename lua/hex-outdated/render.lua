local config = require("hex-outdated.config")

local M = {}

local ns = vim.api.nvim_create_namespace("hex_outdated_virt")
local diag_ns = vim.api.nvim_create_namespace("hex_outdated_diag")

-- Highlight-group key in config.defaults.highlight -> default link target.
local HIGHLIGHT_LINKS = {
	up_to_date = "DiagnosticOk",
	upgradable = "DiagnosticWarn",
	outdated = "DiagnosticWarn",
	invalid = "DiagnosticError",
	loading = "Comment",
	error = "Comment",
	lock = "Comment",
	lock_behind = "DiagnosticHint",
}

-- Statuses whose label is fixed text rather than a template over `latest`.
local FIXED_LABELS = { invalid = true, loading = true, error = true }

function M.clear(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	vim.diagnostic.reset(diag_ns, bufnr)
end

local function label_for(item, cfg)
	if FIXED_LABELS[item.status] then
		return cfg.text[item.status]
	end
	return string.format(cfg.text[item.status], item.latest)
end

-- Lens virt-line text + highlight for a locked dep.
local function lens_label(item, cfg)
	if item.latest and item.lock_behind then
		return string.format(cfg.text.lock_behind, item.locked, item.latest),
			cfg.highlight.lock_behind
	elseif item.latest then
		return string.format(cfg.text.lock_current, item.locked), cfg.highlight.lock
	end
	return "locked " .. item.locked, cfg.highlight.lock
end

--- Build the extmark + diagnostic plan for `items` against `cfg` (a
--- config.options-shaped table), `line_count`, and `opts` ({ lens = bool }).
---
--- items: list of { row, col_start, col_end, name, status, latest?, requirement?,
---                  locked?, lock_behind?, lock_out_of_range? }
---
--- Returns { extmarks = { { row, col, opts }, ... }, diagnostics = { ... } },
--- where `opts` is the nvim_buf_set_extmark opts table and `diagnostics` are
--- ready for vim.diagnostic.set.
function M.build_plan(items, cfg, line_count, opts)
	opts = opts or {}
	local extmarks = {}
	local diagnostics = {}
	for _, item in ipairs(items) do
		-- Items past the buffer end (the file shrank since parse) would make the
		-- extmark/diagnostic APIs throw.
		if item.row < line_count then
			extmarks[#extmarks + 1] = {
				row = item.row,
				col = 0,
				opts = {
					virt_text = { { "  " .. label_for(item, cfg), cfg.highlight[item.status] } },
					virt_text_pos = "eol",
				},
			}
			if item.status == "invalid" then
				diagnostics[#diagnostics + 1] = {
					lnum = item.row,
					col = item.col_start,
					end_col = item.col_end,
					severity = vim.diagnostic.severity.ERROR,
					message = string.format(
						"No published version of '%s' matches this requirement (latest: %s)",
						item.name,
						item.latest or "unknown"
					),
					source = "hex-outdated",
				}
			end

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

			if item.lock_out_of_range then
				diagnostics[#diagnostics + 1] = {
					lnum = item.row,
					col = item.col_start,
					end_col = item.col_end,
					severity = vim.diagnostic.severity.WARN,
					message = string.format(
						"mix.lock has %s %s, which no longer satisfies %q (run `mix deps.get`)",
						item.name,
						item.locked,
						item.requirement
					),
					source = "hex-outdated",
				}
			end
		end
	end
	return { extmarks = extmarks, diagnostics = diagnostics }
end

--- Draw virtual text + diagnostics for a buffer (items/opts as in build_plan).
function M.render(bufnr, items, opts)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	M.clear(bufnr)
	local plan = M.build_plan(items, config.options, vim.api.nvim_buf_line_count(bufnr), opts)
	for _, mark in ipairs(plan.extmarks) do
		vim.api.nvim_buf_set_extmark(bufnr, ns, mark.row, mark.col, mark.opts)
	end
	vim.diagnostic.set(diag_ns, bufnr, plan.diagnostics, {})
end

--- Register default highlight links (only if not already defined by the user/theme).
function M.setup_highlights()
	for key, target in pairs(HIGHLIGHT_LINKS) do
		vim.api.nvim_set_hl(0, config.defaults.highlight[key], { link = target, default = true })
	end
end

return M
