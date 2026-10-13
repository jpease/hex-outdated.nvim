local config = require("hex-outdated.config")
local core = require("hex-outdated.core")
local actions = require("hex-outdated.actions")
local render = require("hex-outdated.render")

local M = {}

-- `:HexOutdated` subcommands, in completion order. Only these are dispatchable
-- or bindable via `keymaps`; other functions on M (e.g. setup) are Lua API only.
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
	actions.versions(bufnr, actions.dep_at_cursor(deps))
end

function M.info(dep)
	local bufnr, deps = current_deps()
	actions.info(bufnr, dep or actions.dep_at_cursor(deps))
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

-- Subcommand name -> handler; drives :HexOutdated dispatch and `keymaps`.
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

-- Per-buffer auto-update debounce timer. Clearing the augroup on reattach does
-- not cancel a vim.defer_fn timer already in flight, so it is tracked here.
local buf_timers = {}

local function stop_buf_timer(bufnr)
	local timer = buf_timers[bufnr]
	if timer then
		buf_timers[bufnr] = nil
		-- vim.defer_fn closes its handle before firing; closing twice errors.
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
	for action, lhs in pairs(config.options.keymaps) do
		local fn = COMMANDS[action]
		if fn then
			vim.keymap.set("n", lhs, fn, { buffer = bufnr, desc = "hex-outdated: " .. action })
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
			local b, deps = current_deps()
			local dep = actions.dep_at_cursor(deps)
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
