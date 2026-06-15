-- Render layer against real Neovim: extmarks + diagnostics.
local config = require("hex-outdated.config")
local render = require("hex-outdated.render")

local function fresh_buf(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	return buf
end

-- The virtual-text namespace is created with this exact name in render.lua.
local virt_ns = vim.api.nvim_create_namespace("hex_outdated_virt")

describe("render", function()
	config.setup({})
	render.setup_highlights()

	it("draws eol virtual text for an upgradable dep", function()
		local buf = fresh_buf({ '{:jason, "~> 1.0"},' })
		render.render(buf, {
			{
				row = 0,
				col_start = 9,
				col_end = 16,
				name = "jason",
				status = "upgradable",
				latest = "1.4.5",
			},
		})
		local marks = vim.api.nvim_buf_get_extmarks(buf, virt_ns, 0, -1, { details = true })
		eq(1, #marks, "one extmark")
		local vt = marks[1][4].virt_text
		truthy(vt, "has virt_text")
		contains(vt[1][1], "1.4.5")
		eq("HexOutdatedUpgradable", vt[1][2], "uses the status highlight")
	end)

	it("emits a diagnostic for an invalid requirement", function()
		local buf = fresh_buf({ '{:nope, "~> 9.9"},' })
		render.render(buf, {
			{
				row = 0,
				col_start = 8,
				col_end = 15,
				name = "nope",
				status = "invalid",
				latest = "1.0.0",
			},
		})
		local diags = vim.diagnostic.get(buf)
		eq(1, #diags, "one diagnostic")
		eq(vim.diagnostic.severity.ERROR, diags[1].severity)
		contains(diags[1].message, "nope")
		eq("hex-outdated", diags[1].source)
	end)

	it("skips items whose row is past the end of the buffer", function()
		local buf = fresh_buf({ '{:jason, "~> 1.0"},' })
		render.render(buf, {
			{
				row = 5,
				col_start = 9,
				col_end = 16,
				name = "jason",
				status = "upgradable",
				latest = "1.4.5",
			},
		})
		eq(
			0,
			#vim.api.nvim_buf_get_extmarks(buf, virt_ns, 0, -1, {}),
			"no extmark for out-of-range row"
		)
	end)

	it("clear removes virtual text and diagnostics", function()
		local buf = fresh_buf({ '{:nope, "~> 9.9"},' })
		render.render(buf, {
			{
				row = 0,
				col_start = 8,
				col_end = 15,
				name = "nope",
				status = "invalid",
				latest = "1.0.0",
			},
		})
		render.clear(buf)
		eq(0, #vim.api.nvim_buf_get_extmarks(buf, virt_ns, 0, -1, {}), "extmarks cleared")
		eq(0, #vim.diagnostic.get(buf), "diagnostics cleared")
	end)
end)

describe("render lock context", function()
	config.setup({})
	render.setup_highlights()

	local lock_ns = vim.api.nvim_create_namespace("hex_outdated_virt")

	local function lock_fresh_buf(lines)
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		return buf
	end

	it("draws a lens virt_line below a locked dep when lens is on", function()
		local buf = lock_fresh_buf({ '{:jason, "~> 1.0"},' })
		render.render(buf, {
			{
				row = 0,
				col_start = 9,
				col_end = 15,
				name = "jason",
				requirement = "~> 1.0",
				status = "upgradable",
				latest = "1.4.5",
				locked = "1.2.0",
				lock_behind = true,
			},
		}, { lens = true })
		local marks = vim.api.nvim_buf_get_extmarks(buf, lock_ns, 0, -1, { details = true })
		local found
		for _, m in ipairs(marks) do
			if m[4].virt_lines then
				found = m[4].virt_lines[1][1][1]
			end
		end
		truthy(found, "a virt_line was drawn")
		contains(found, "locked 1.2.0")
		contains(found, "1.4.5")
	end)

	it("does not draw a lens line when lens is off", function()
		local buf = lock_fresh_buf({ '{:jason, "~> 1.0"},' })
		render.render(buf, {
			{
				row = 0,
				name = "jason",
				requirement = "~> 1.0",
				status = "upgradable",
				latest = "1.4.5",
				locked = "1.2.0",
				lock_behind = true,
			},
		}, { lens = false })
		local marks = vim.api.nvim_buf_get_extmarks(buf, lock_ns, 0, -1, { details = true })
		for _, m in ipairs(marks) do
			is_nil(m[4].virt_lines, "no virt_lines")
		end
	end)

	it("emits a WARN diagnostic for an out-of-range lock", function()
		local buf = lock_fresh_buf({ '{:jason, "~> 2.0"},' })
		render.render(buf, {
			{
				row = 0,
				col_start = 9,
				col_end = 15,
				name = "jason",
				requirement = "~> 2.0",
				status = "upgradable",
				latest = "2.1.0",
				locked = "1.2.0",
				lock_out_of_range = true,
			},
		}, {})
		local diags = vim.diagnostic.get(buf)
		eq(1, #diags)
		eq(vim.diagnostic.severity.WARN, diags[1].severity)
		contains(diags[1].message, "1.2.0")
		contains(diags[1].message, "mix deps.get")
	end)
end)
