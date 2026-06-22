local config = require("hex-outdated.config")
local core = require("hex-outdated.core")
local actions = require("hex-outdated.actions")
local render = require("hex-outdated.render")
local hex_api = require("hex-outdated.hex_api")

local M = {}

local SUBCOMMANDS = { "refresh", "toggle", "upgrade", "versions", "open", "info", "lock" }

local function is_mixexs(bufnr)
	return vim.api.nvim_buf_get_name(bufnr):match("mix%.exs$") ~= nil
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
	local st = core.state[bufnr] or { enabled = config.options.enabled }
	st.enabled = not st.enabled
	core.state[bufnr] = st
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
	local _, deps = current_deps()
	actions.open(actions.dep_at_cursor(deps))
end

function M.versions()
	local bufnr, deps = current_deps()
	actions.versions(bufnr, actions.dep_at_cursor(deps), function(name, cb)
		hex_api.get_package(name, core.api_opts(), cb)
	end)
end

function M.info(dep)
	if not dep then
		local _, deps = current_deps()
		dep = actions.dep_at_cursor(deps)
	end
	actions.info(dep, function(name, cb)
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
	local st = core.state[bufnr] or { enabled = config.options.enabled }
	st.lock_lens = not st.lock_lens
	core.state[bufnr] = st
	core.refresh_render(bufnr)
end

-- Plugin-owned keymaps per buffer, so they can be removed before re-installing
-- on a subsequent setup() call.
local buf_keymaps = {}

local function clear_buf_keymaps(bufnr)
	for _, lhs in ipairs(buf_keymaps[bufnr] or {}) do
		pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
	end
	buf_keymaps[bufnr] = nil
end

local function attach(bufnr)
	if not is_mixexs(bufnr) then
		return
	end
	-- Remove keymaps installed by a previous setup() call before adding new ones.
	clear_buf_keymaps(bufnr)
	local installed = {}
	buf_keymaps[bufnr] = installed

	-- Per-buffer augroup: clearing it on each attach ensures repeated setup()
	-- calls replace rather than accumulate buffer-local autocmds.
	local buf_group = vim.api.nvim_create_augroup("HexOutdated_" .. bufnr, { clear = true })
	core.state[bufnr] = core.state[bufnr]
		or { enabled = config.options.enabled, lock_lens = config.options.lock.lens }
	-- Drop per-buffer state when the buffer goes away so state does not accumulate
	-- across a long session of opening and closing mix.exs files.
	vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		group = buf_group,
		buffer = bufnr,
		once = true,
		callback = function()
			core.state[bufnr] = nil
			buf_keymaps[bufnr] = nil
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
		local timer
		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
			group = buf_group,
			buffer = bufnr,
			callback = function()
				if timer then
					timer:stop()
				end
				timer = vim.defer_fn(function()
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
		if type(M[sub]) == "function" then
			M[sub]()
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
