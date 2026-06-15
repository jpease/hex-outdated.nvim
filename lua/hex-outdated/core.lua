local parser = require("hex-outdated.parser")
local hex_api = require("hex-outdated.hex_api")
local version = require("hex-outdated.version")
local render = require("hex-outdated.render")
local config = require("hex-outdated.config")

local M = {}

-- bufnr -> { deps = {...}, enabled = bool }
M.state = {}

function M.api_opts(extra)
	local o = config.options
	local opts = {
		base_url = o.api.base_url,
		timeout_ms = o.api.timeout_ms,
		ttl_seconds = o.cache.ttl_seconds,
	}
	for k, v in pairs(extra or {}) do
		opts[k] = v
	end
	return opts
end

-- Rebuild render items from current dep state (hex deps only).
function M.refresh_render(bufnr)
	local st = M.state[bufnr]
	if not st or not st.enabled then
		return
	end
	local items = {}
	for _, dep in ipairs(st.deps or {}) do
		if dep.kind == "hex" then
			items[#items + 1] = {
				row = dep.row,
				col_start = dep.col_start,
				col_end = dep.col_end,
				name = dep.name,
				status = dep.status or "loading",
				latest = dep.latest,
				suggested = dep.suggested,
			}
		end
	end
	render.render(bufnr, items)
end

--- Parse the buffer, render loading state, then fetch + classify each hex dep.
function M.analyze(bufnr, opts)
	opts = opts or {}
	local st = M.state[bufnr] or { enabled = config.options.enabled }
	M.state[bufnr] = st
	st.deps = parser.parse_buffer(bufnr)
	if not st.enabled then
		return
	end
	for _, dep in ipairs(st.deps) do
		dep.status = (dep.kind == "hex" and dep.requirement) and "loading" or nil
	end
	M.refresh_render(bufnr)

	for _, dep in ipairs(st.deps) do
		if dep.kind == "hex" and dep.requirement then
			hex_api.get_package(dep.name, M.api_opts({ force = opts.force }), function(res)
				if not vim.api.nvim_buf_is_valid(bufnr) then
					return
				end
				local cur = M.state[bufnr]
				if not cur or not cur.enabled then
					return
				end
				if res.error then
					dep.status = res.not_found and "invalid" or "error"
					dep.latest = res.latest
				else
					local c = version.classify(dep.requirement, res.versions or {})
					dep.status = c.status == "unknown" and "loading" or c.status
					dep.latest = c.latest
					dep.suggested = c.suggested
					dep.op = c.op
				end
				M.refresh_render(bufnr)
			end)
		end
	end
end

return M
