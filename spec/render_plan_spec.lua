-- Pure specs for render.build_plan: no Neovim required. render.lua's module
-- load touches vim.api.nvim_create_namespace, so stub the minimum vim needs
-- to require it, mirroring spec/core_spec.lua.
local config = require("hex-outdated.config")

describe("render.build_plan", function()
	local old_vim
	local render
	local cfg = config.defaults

	before_each(function()
		old_vim = rawget(_G, "vim")
		_G.vim = {
			api = {
				nvim_create_namespace = function()
					return 1
				end,
			},
		}
		package.loaded["hex-outdated.render"] = nil
		render = require("hex-outdated.render")
	end)

	after_each(function()
		package.loaded["hex-outdated.render"] = nil
		_G.vim = old_vim
	end)

	local function extmark_texts(plan)
		local out = {}
		for _, mark in ipairs(plan.extmarks) do
			if mark.opts.virt_text then
				out[#out + 1] = mark.opts.virt_text[1][1]
			end
		end
		return out
	end

	describe("label text", function()
		it("formats up_to_date with the %s template", function()
			local plan = render.build_plan({
				{ row = 0, name = "jason", status = "up_to_date", latest = "1.4.5" },
			}, cfg, 10, {})
			assert.are.equal("  ✓ 1.4.5", extmark_texts(plan)[1])
		end)

		it("formats upgradable with the %s template", function()
			local plan = render.build_plan({
				{ row = 0, name = "jason", status = "upgradable", latest = "1.4.5" },
			}, cfg, 10, {})
			assert.are.equal("  ↑ 1.4.5", extmark_texts(plan)[1])
		end)

		it("formats outdated with the %s template", function()
			local plan = render.build_plan({
				{ row = 0, name = "jason", status = "outdated", latest = "2.0.0" },
			}, cfg, 10, {})
			assert.are.equal("  ↓ 2.0.0", extmark_texts(plan)[1])
		end)

		it("uses the fixed invalid text regardless of latest", function()
			local plan = render.build_plan({
				{ row = 0, name = "nope", status = "invalid", latest = "1.0.0" },
			}, cfg, 10, {})
			assert.are.equal("  ✗ no such version", extmark_texts(plan)[1])
		end)

		it("uses the fixed loading text", function()
			local plan = render.build_plan({
				{ row = 0, name = "jason", status = "loading" },
			}, cfg, 10, {})
			assert.are.equal("  …", extmark_texts(plan)[1])
		end)

		it("uses the fixed error text", function()
			local plan = render.build_plan({
				{ row = 0, name = "jason", status = "error" },
			}, cfg, 10, {})
			assert.are.equal("  fetch error", extmark_texts(plan)[1])
		end)
	end)

	describe("highlight selection", function()
		it("uses the status's configured highlight", function()
			local plan = render.build_plan({
				{ row = 0, name = "jason", status = "upgradable", latest = "1.4.5" },
			}, cfg, 10, {})
			assert.are.equal("HexOutdatedUpgradable", plan.extmarks[1].opts.virt_text[1][2])
		end)

		it("falls back to Comment when the status has no configured highlight", function()
			local plan = render.build_plan({
				{ row = 0, name = "jason", status = "totally_unknown_status" },
			}, cfg, 10, {})
			assert.are.equal("Comment", plan.extmarks[1].opts.virt_text[1][2])
		end)
	end)

	describe("invalid-version diagnostic", function()
		it("has the exact fields and message", function()
			local plan = render.build_plan({
				{
					row = 3,
					col_start = 8,
					col_end = 15,
					name = "nope",
					status = "invalid",
					latest = "1.0.0",
				},
			}, cfg, 10, {})
			assert.are.equal(1, #plan.diagnostics)
			local d = plan.diagnostics[1]
			assert.are.equal(3, d.lnum)
			assert.are.equal(8, d.col)
			assert.are.equal(15, d.end_col)
			assert.are.equal("error", d.severity)
			assert.are.equal(
				"No published version of 'nope' matches this requirement (latest: 1.0.0)",
				d.message
			)
			assert.are.equal("hex-outdated", d.source)
		end)
	end)

	describe("stale-lock diagnostic", function()
		it("has the exact fields and %q-quoted requirement in the message", function()
			local plan = render.build_plan({
				{
					row = 4,
					col_start = 9,
					col_end = 15,
					name = "jason",
					status = "upgradable",
					latest = "2.1.0",
					locked = "1.2.0",
					lock_out_of_range = true,
					requirement = "~> 2.0",
				},
			}, cfg, 10, {})
			assert.are.equal(1, #plan.diagnostics)
			local d = plan.diagnostics[1]
			assert.are.equal(4, d.lnum)
			assert.are.equal(9, d.col)
			assert.are.equal(15, d.end_col)
			assert.are.equal("warn", d.severity)
			assert.are.equal(
				'mix.lock has jason 1.2.0, which no longer satisfies "~> 2.0" (run `mix deps.get`)',
				d.message
			)
			assert.are.equal("hex-outdated", d.source)
		end)
	end)

	describe("lens output", function()
		local function lens_marks(plan)
			local out = {}
			for _, mark in ipairs(plan.extmarks) do
				if mark.opts.virt_lines then
					out[#out + 1] = mark.opts.virt_lines[1][1]
				end
			end
			return out
		end

		it("shows the lock_behind text + highlight when locked is behind latest", function()
			local plan = render.build_plan({
				{
					row = 0,
					name = "jason",
					status = "upgradable",
					latest = "1.4.5",
					locked = "1.2.0",
					lock_behind = true,
				},
			}, cfg, 10, { lens = true })
			local marks = lens_marks(plan)
			assert.are.equal(1, #marks)
			assert.are.equal("  ↳ locked 1.2.0 · latest 1.4.5", marks[1][1])
			assert.are.equal("HexOutdatedLockBehind", marks[1][2])
		end)

		it("shows the lock_current text + highlight when locked equals latest", function()
			local plan = render.build_plan({
				{
					row = 0,
					name = "jason",
					status = "up_to_date",
					latest = "1.4.5",
					locked = "1.4.5",
					lock_behind = false,
				},
			}, cfg, 10, { lens = true })
			local marks = lens_marks(plan)
			assert.are.equal(1, #marks)
			assert.are.equal("  ↳ locked 1.4.5 · up to date", marks[1][1])
			assert.are.equal("HexOutdatedLock", marks[1][2])
		end)

		it("shows only the locked version while latest is not yet known", function()
			local plan = render.build_plan({
				{ row = 0, name = "jason", status = "loading", locked = "1.2.0" },
			}, cfg, 10, { lens = true })
			local marks = lens_marks(plan)
			assert.are.equal(1, #marks)
			assert.are.equal("  ↳ locked 1.2.0", marks[1][1])
			assert.are.equal("HexOutdatedLock", marks[1][2])
		end)

		it("omits the lens when opts.lens is false", function()
			local plan = render.build_plan({
				{
					row = 0,
					name = "jason",
					status = "upgradable",
					latest = "1.4.5",
					locked = "1.2.0",
					lock_behind = true,
				},
			}, cfg, 10, { lens = false })
			assert.are.equal(0, #lens_marks(plan))
		end)

		it("omits the lens when the item has no locked entry", function()
			local plan = render.build_plan({
				{ row = 0, name = "jason", status = "upgradable", latest = "1.4.5" },
			}, cfg, 10, { lens = true })
			assert.are.equal(0, #lens_marks(plan))
		end)
	end)

	describe("out-of-range row filtering", function()
		it("drops an item whose row is >= line_count without affecting others", function()
			local plan = render.build_plan({
				{ row = 0, name = "kept", status = "upgradable", latest = "1.4.5" },
				{ row = 5, name = "dropped", status = "upgradable", latest = "1.4.5" },
			}, cfg, 5, {})
			assert.are.equal(1, #plan.extmarks)
			assert.are.equal(0, plan.extmarks[1].row)
		end)

		it("drops diagnostics for an out-of-range item too", function()
			local plan = render.build_plan({
				{ row = 5, col_start = 0, col_end = 3, name = "dropped", status = "invalid" },
			}, cfg, 5, {})
			assert.are.equal(0, #plan.extmarks)
			assert.are.equal(0, #plan.diagnostics)
		end)
	end)
end)
