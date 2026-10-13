local parser = require("hex-outdated.parser")
local hex_api = require("hex-outdated.hex_api")
local version = require("hex-outdated.version")
local render = require("hex-outdated.render")
local config = require("hex-outdated.config")
local lock = require("hex-outdated.lock")

local M = {}

-- bufnr -> { deps = {...}, enabled = bool, lock_lens = bool }
M.state = {}

--- Return the buffer's state, seeding `enabled`/`lock_lens` from config on first
--- touch (with no deps until analyzed); afterwards the buffer owns them (see
--- toggle/lock).
function M.ensure_state(bufnr)
	local st = M.state[bufnr]
	if not st then
		st = { deps = {}, enabled = config.options.enabled, lock_lens = config.options.lock.lens }
		M.state[bufnr] = st
	end
	return st
end

function M.api_opts()
	local o = config.options
	return {
		base_url = o.api.base_url,
		timeout_ms = o.api.timeout_ms,
		max_concurrent = o.api.max_concurrent,
		ttl_seconds = o.cache.ttl_seconds,
		error_ttl_seconds = o.cache.error_ttl_seconds,
	}
end

--- Fetch `dep`'s Hex package, honouring a `hex:` alias.
function M.fetch_package(dep, cb, force)
	local opts = M.api_opts()
	opts.force = force
	hex_api.get_package(dep.package or dep.name, opts, cb)
end

--- Classify a hex_api result onto `dep` (status/latest/suggested/op). A failure
--- with no usable versions is terminal; a stale result is classified from the
--- versions it still carries.
function M.apply_package_result(dep, res)
	local versions = res.versions
	if res.error and not (versions and #versions > 0) then
		dep.status = res.not_found and "invalid" or "error"
		dep.latest, dep.suggested, dep.op = nil, nil, nil
		return
	end
	local c = version.classify(dep.requirement, versions)
	dep.status, dep.latest, dep.suggested, dep.op = c.status, c.latest, c.suggested, c.op
end

local function render_items_for_deps(deps)
	local items = {}
	for _, dep in ipairs(deps) do
		-- "unknown" requirements (e.g. combined clauses) render nothing.
		if dep.kind == "hex" and dep.status ~= "unknown" then
			items[#items + 1] = {
				row = dep.row,
				col_start = dep.col_start,
				col_end = dep.col_end,
				name = dep.name,
				requirement = dep.requirement,
				status = dep.status or "loading",
				latest = dep.latest,
				locked = dep.locked,
				lock_behind = dep.locked
					and dep.latest
					and version.is_behind(dep.locked, dep.latest),
				lock_out_of_range = dep.lock_out_of_range,
			}
		end
	end
	return items
end

-- Buffers with a render scheduled for the next tick; many refresh requests in
-- one tick collapse into a single render.
local render_pending = {}

--- Schedule a render of the buffer's current dep state on the next tick.
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
			render.render(bufnr, render_items_for_deps(cur.deps), { lens = cur.lock_lens })
		end
	end)
end

--- Parse the buffer, render loading state, then fetch + classify each hex dep.
function M.analyze(bufnr, opts)
	opts = opts or {}
	local st = M.ensure_state(bufnr)
	st.deps = parser.parse_buffer(bufnr)
	local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
	local lockmap = {}
	if config.options.lock.enabled then
		local path = lock.find_lock_path(vim.api.nvim_buf_get_name(bufnr))
		if path then
			lockmap = lock.load(path)
		end
	end
	for _, dep in ipairs(st.deps) do
		if dep.kind == "hex" then
			dep.changedtick = changedtick
			dep.locked = lockmap[dep.name]
			dep.lock_out_of_range = config.options.lock.stale_diagnostic
				and dep.requirement
				and dep.locked
				and version.out_of_range(dep.requirement, dep.locked)
		end
	end
	if not st.enabled then
		return
	end
	for _, dep in ipairs(st.deps) do
		dep.status = (dep.kind == "hex" and dep.requirement) and "loading" or nil
	end
	M.refresh_render(bufnr)

	for _, dep in ipairs(st.deps) do
		if dep.kind == "hex" and dep.requirement then
			M.fetch_package(dep, function(res)
				if not vim.api.nvim_buf_is_valid(bufnr) then
					return
				end
				local cur = M.state[bufnr]
				if not cur or not cur.enabled then
					return
				end
				M.apply_package_result(dep, res)
				M.refresh_render(bufnr)
			end, opts.force)
		end
	end
end

return M
