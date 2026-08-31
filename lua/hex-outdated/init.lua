local config = require("hex-outdated.config")
local core = require("hex-outdated.core")
local actions = require("hex-outdated.actions")
local render = require("hex-outdated.render")
local hex_api = require("hex-outdated.hex_api")

local M = {}

-- Ordered, documented `:HexOutdated` subcommands. This array is the single
-- source of truth: COMMANDS below (built once all M.<action> handlers exist)
-- derives both the completion candidates and the dispatch table from it, so
-- the two cannot drift apart. Any other function on M (e.g. M.setup) stays a
-- legitimate exported Lua API but is never reachable as a subcommand (#78).
local SUBCOMMANDS = { "refresh", "toggle", "upgrade", "versions", "open", "info", "lock" }

local function is_mixexs(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	return name:match("[/\\]mix%.exs$") ~= nil or name == "mix.exs"
end

local function current_deps()
	local bufnr = vim.api.nvim_get_current_buf()
	local st = core.state[bufnr]
	return bufnr, st and st.deps or {}
end

function M.refresh()
	core.analyze(vim.api.nvim_get_current_buf(), { force = true })
end

function M.toggle()
	local bufnr = vim.api.nvim_get_current_buf()
	local st = core.ensure_state(bufnr)
	st.enabled = not st.enabled
	if st.enabled then
		core.analyze(bufnr)
	else
		render.clear(bufnr)
	end
end

function M.upgrade()
	local bufnr, deps = current_deps()
	actions.upgrade(bufnr, actions.dep_at_cursor(deps))
end

function M.open()
	local bufnr, deps = current_deps()
	actions.open(bufnr, actions.dep_at_cursor(deps))
end

function M.versions()
	local bufnr, deps = current_deps()
	actions.versions(bufnr, actions.dep_at_cursor(deps), function(name, cb)
		hex_api.get_package(name, core.api_opts(), cb)
	end)
end

function M.info(dep)
	local bufnr, deps = current_deps()
	if not dep then
		dep = actions.dep_at_cursor(deps)
	end
	actions.info(bufnr, dep, function(name, cb)
		hex_api.get_package(name, core.api_opts(), cb)
	end)
end

function M.lock()
	if not config.options.lock.enabled then
		vim.notify(
			"hex-outdated: lock context is disabled (lock.enabled = false)",
			vim.log.levels.INFO
		)
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local st = core.ensure_state(bufnr)
	st.lock_lens = not st.lock_lens
	core.refresh_render(bufnr)
end

-- Subcommand-to-handler lookup, built from SUBCOMMANDS once every M.<action>
-- above is defined. This is the same table the :HexOutdated command below
-- uses for both completion (its keys, in SUBCOMMANDS order) and dispatch
-- (looking up the handler to call) — one explicit table, not two lists that
-- could drift apart.
local COMMANDS = {}
for _, name in ipairs(SUBCOMMANDS) do
	COMMANDS[name] = M[name]
end

-- Plugin-owned keymaps per buffer, so they can be removed before re-installing
-- on a subsequent setup() call.
local buf_keymaps = {}

-- All plugin-installed mappings carry a "hex-outdated:" desc; we use it as an
-- ownership marker so we never delete a mapping the user has since put on the lhs.
local KEYMAP_OWNER = "^hex%-outdated:"

local function plugin_owns_mapping(bufnr, lhs)
	local normalized = vim.api.nvim_replace_termcodes(lhs, true, true, true)
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
		if m.lhs == normalized then
			return type(m.desc) == "string" and m.desc:match(KEYMAP_OWNER) ~= nil
		end
	end
	return false
end

local function clear_buf_keymaps(bufnr)
	for _, lhs in ipairs(buf_keymaps[bufnr] or {}) do
		if plugin_owns_mapping(bufnr, lhs) then
			pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
		end
	end
	buf_keymaps[bufnr] = nil
end

-- Plugin-owned per-buffer auto-update debounce timer, tracked across attach()
-- calls the same way buf_keymaps is: clearing the per-buffer augroup only
-- stops FUTURE TextChanged triggers, it does not cancel a vim.defer_fn timer
-- already in flight from a previous attach()'s closure.
local buf_timers = {}

local function stop_buf_timer(bufnr)
	local timer = buf_timers[bufnr]
	if timer then
		buf_timers[bufnr] = nil
		-- vim.defer_fn closes its own timer handle just before invoking the
		-- deferred callback (see $VIMRUNTIME/lua/vim/_core/editor.lua), so a
		-- timer that already fired naturally is closing (or closed) by the
		-- time anything else can observe it here; guard against closing it
		-- again, which libuv raises an error for.
		if not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end
end

local function attach(bufnr)
	if not is_mixexs(bufnr) then
		return
	end
	-- Remove keymaps installed by a previous setup() call before adding new ones.
	clear_buf_keymaps(bufnr)
	-- Cancel any timer left over from a previous attach() of this buffer.
	stop_buf_timer(bufnr)
	local installed = {}
	buf_keymaps[bufnr] = installed

	-- Per-buffer augroup: clearing it on each attach ensures repeated setup()
	-- calls replace rather than accumulate buffer-local autocmds.
	local buf_group = vim.api.nvim_create_augroup("HexOutdated_" .. bufnr, { clear = true })
	core.ensure_state(bufnr)
	-- Drop per-buffer state when the buffer goes away so state does not accumulate
	-- across a long session of opening and closing mix.exs files.
	vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		group = buf_group,
		buffer = bufnr,
		once = true,
		callback = function()
			core.state[bufnr] = nil
			buf_keymaps[bufnr] = nil
			stop_buf_timer(bufnr)
		end,
	})
	for action, lhs in pairs(config.options.keymaps or {}) do
		if lhs and type(M[action]) == "function" then
			vim.keymap.set(
				"n",
				lhs,
				M[action],
				{ buffer = bufnr, desc = "hex-outdated: " .. action }
			)
			installed[#installed + 1] = lhs
		end
	end
	if config.options.enabled then
		core.analyze(bufnr)
	end
	if config.options.auto_update then
		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
			group = buf_group,
			buffer = bufnr,
			callback = function()
				stop_buf_timer(bufnr)
				buf_timers[bufnr] = vim.defer_fn(function()
					buf_timers[bufnr] = nil
					if vim.api.nvim_buf_is_valid(bufnr) then
						core.analyze(bufnr)
					end
				end, config.options.debounce_ms)
			end,
		})
	end
	local hover = config.options.popup.hover_key
	if hover then
		vim.keymap.set("n", hover, function()
			local b = vim.api.nvim_get_current_buf()
			local st = core.state[b]
			local dep = actions.dep_at_cursor(st and st.deps or {})
			if dep then
				M.info(dep)
			elseif #vim.lsp.get_clients({ bufnr = b }) > 0 then
				vim.lsp.buf.hover()
			else
				vim.cmd("normal! K")
			end
		end, { buffer = bufnr, desc = "hex-outdated: info / hover" })
		installed[#installed + 1] = hover
	end
end

function M.setup(opts)
	config.setup(opts)
	render.setup_highlights()
	local group = vim.api.nvim_create_augroup("HexOutdated", { clear = true })
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
		group = group,
		pattern = "mix.exs",
		callback = function(args)
			attach(args.buf)
		end,
	})
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and is_mixexs(b) then
			attach(b)
		end
	end
	vim.api.nvim_create_user_command("HexOutdated", function(a)
		local sub = (a.args ~= "" and a.args) or "refresh"
		local fn = COMMANDS[sub]
		if fn then
			fn()
		else
			vim.notify("hex-outdated: unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
		end
	end, {
		nargs = "?",
		complete = function(arglead)
			return vim.tbl_filter(function(c)
				return c:find(arglead, 1, true) == 1
			end, SUBCOMMANDS)
		end,
	})
end

return M
