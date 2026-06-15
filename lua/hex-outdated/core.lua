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
		error_ttl_seconds = o.cache.error_ttl_seconds,
	}
	for k, v in pairs(extra or {}) do
		opts[k] = v
	end
	return opts
end

local function render_items_for_deps(deps)
	local items = {}
	for _, dep in ipairs(deps or {}) do
		-- "unknown" = a requirement we can't analyze (e.g. combined `and`/`or`
		-- clauses); render nothing for it rather than a misleading indicator.
		if dep.kind == "hex" and dep.status ~= "unknown" then
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
	return items
end

local function package_result_patch(dep, res)
	if res.error then
		return { status = res.not_found and "invalid" or "error" }
	end
	local c = version.classify(dep.requirement, res.versions or {})
	return {
		status = c.status,
		latest = c.latest,
		suggested = c.suggested,
		op = c.op,
	}
end

M._render_items_for_deps = render_items_for_deps
M._package_result_patch = package_result_patch

-- Buffers with a render scheduled for the next tick. A single analyze can request
-- many renders in one tick (every cached dep resolves synchronously, and bursts of
-- responses arrive close together); coalescing collapses N full re-renders into one.
local render_pending = {}

-- Rebuild render items from current dep state (hex deps only). Renders are
-- coalesced onto the next event-loop tick rather than running inline.
function M.refresh_render(bufnr)
	local st = M.state[bufnr]
	if not st or not st.enabled then
		return
	end
	if render_pending[bufnr] then
		return
	end
	render_pending[bufnr] = true
	vim.schedule(function()
		render_pending[bufnr] = nil
		local cur = M.state[bufnr]
		if cur and cur.enabled and vim.api.nvim_buf_is_valid(bufnr) then
			render.render(bufnr, render_items_for_deps(cur.deps))
		end
	end)
end

--- Parse the buffer, render loading state, then fetch + classify each hex dep.
function M.analyze(bufnr, opts)
	opts = opts or {}
	-- Per-buffer `enabled` persists across calls; it is seeded from the global
	-- config on first analyze and thereafter owned by the buffer (see toggle).
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
				local patch = package_result_patch(dep, res)
				dep.status = patch.status -- terminal, incl. "unknown" (rendered as nothing)
				if not res.error then
					dep.latest = patch.latest
					dep.suggested = patch.suggested
					dep.op = patch.op
				end
				M.refresh_render(bufnr)
			end)
		end
	end
end

return M
