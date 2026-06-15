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

local function label_for(item, opts)
	if item.status == "invalid" then
		return opts.text.invalid
	elseif item.status == "loading" then
		return opts.text.loading
	elseif item.status == "error" then
		return opts.text.error
	end
	local tpl = opts.text[item.status] or "%s"
	return string.format(tpl, item.latest or "")
end

--- Draw virtual text + diagnostics for a buffer.
--- items: list of { row, col_start, col_end, name, status, latest, suggested }
function M.render(bufnr, items)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	M.clear(bufnr)
	local opts = config.options
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local diagnostics = {}
	for _, item in ipairs(items) do
		-- Skip stale items pointing past the buffer end (e.g. the file shrank
		-- between parse and render); set_extmark/diagnostics would otherwise throw.
		if item.row < line_count then
			local hl = opts.highlight[item.status] or "Comment"
			vim.api.nvim_buf_set_extmark(bufnr, ns, item.row, 0, {
				virt_text = { { "  " .. label_for(item, opts), hl } },
				virt_text_pos = "eol",
			})
			if item.status == "invalid" then
				diagnostics[#diagnostics + 1] = {
					lnum = item.row,
					col = item.col_start or 0,
					end_col = item.col_end or (item.col_start or 0),
					severity = vim.diagnostic.severity.ERROR,
					message = string.format(
						"No published version of '%s' matches this requirement (latest: %s)",
						item.name or "?",
						item.latest or "unknown"
					),
					source = "hex-outdated",
				}
			end
		end
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
	}
	for name, target in pairs(links) do
		vim.api.nvim_set_hl(0, name, { link = target, default = true })
	end
end

return M
