describe("core pure helpers", function()
	local old_vim
	local core

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
		package.loaded["hex-outdated.core"] = nil
		core = require("hex-outdated.core")
	end)

	after_each(function()
		package.loaded["hex-outdated.render"] = nil
		package.loaded["hex-outdated.core"] = nil
		_G.vim = old_vim
	end)

	describe("_render_items_for_deps", function()
		it("filters unknown deps and maps render fields", function()
			local items = core._render_items_for_deps({
				{
					kind = "hex",
					row = 1,
					col_start = 12,
					col_end = 18,
					name = "phoenix",
				},
				{
					kind = "hex",
					status = "unknown",
					row = 2,
					name = "ecto",
				},
				{
					kind = "path",
					row = 3,
					name = "local_dep",
				},
				{
					kind = "hex",
					status = "upgradable",
					row = 4,
					col_start = 10,
					col_end = 16,
					name = "jason",
					latest = "1.4.4",
					suggested = "~> 1.4",
				},
			})

			assert.are.same({
				{
					row = 1,
					col_start = 12,
					col_end = 18,
					name = "phoenix",
					status = "loading",
				},
				{
					row = 4,
					col_start = 10,
					col_end = 16,
					name = "jason",
					status = "upgradable",
					latest = "1.4.4",
					suggested = "~> 1.4",
				},
			}, items)
		end)
	end)

	describe("_package_result_patch", function()
		it("maps fetch errors to terminal statuses", function()
			assert.are.same(
				{ status = "invalid" },
				core._package_result_patch({ requirement = "~> 1.6" }, {
					error = "package not found",
					not_found = true,
				})
			)
			assert.are.same(
				{ status = "error" },
				core._package_result_patch({ requirement = "~> 1.6" }, { error = "http 500" })
			)
		end)

		it("classifies successful package results", function()
			local patch = core._package_result_patch({ requirement = "~> 1.6" }, {
				versions = { "1.6.0", "1.6.16", "1.7.14" },
			})

			assert.are.equal("upgradable", patch.status)
			assert.are.equal("1.7.14", patch.latest)
			assert.are.equal("~> 1.7", patch.suggested)
			assert.are.equal("~>", patch.op)
		end)
	end)
end)

describe("core.refresh_render coalescing", function()
	local old_vim
	local core
	local scheduled
	local render_calls

	before_each(function()
		old_vim = rawget(_G, "vim")
		scheduled = {}
		render_calls = 0
		package.loaded["hex-outdated.render"] = {
			render = function()
				render_calls = render_calls + 1
			end,
			clear = function() end,
			setup_highlights = function() end,
		}
		_G.vim = {
			api = {
				nvim_create_namespace = function()
					return 1
				end,
				nvim_buf_is_valid = function()
					return true
				end,
			},
			schedule = function(fn)
				scheduled[#scheduled + 1] = fn
			end,
		}
		package.loaded["hex-outdated.core"] = nil
		core = require("hex-outdated.core")
	end)

	after_each(function()
		package.loaded["hex-outdated.render"] = nil
		package.loaded["hex-outdated.core"] = nil
		_G.vim = old_vim
	end)

	it("renders nothing inline and schedules a single tick for many calls", function()
		core.state[1] = { enabled = true, deps = {} }
		core.refresh_render(1)
		core.refresh_render(1)
		core.refresh_render(1)

		assert.are.equal(0, render_calls)
		assert.are.equal(1, #scheduled)

		scheduled[1]()
		assert.are.equal(1, render_calls)
	end)

	it("schedules a fresh render once the previous tick has flushed", function()
		core.state[1] = { enabled = true, deps = {} }
		core.refresh_render(1)
		scheduled[1]()
		core.refresh_render(1)

		assert.are.equal(2, #scheduled)
		scheduled[2]()
		assert.are.equal(2, render_calls)
	end)

	it("skips the render if the buffer was disabled before the tick ran", function()
		core.state[1] = { enabled = true, deps = {} }
		core.refresh_render(1)
		core.state[1].enabled = false

		scheduled[1]()
		assert.are.equal(0, render_calls)
	end)

	it("does nothing for an unknown or disabled buffer", function()
		core.refresh_render(99)
		core.state[2] = { enabled = false, deps = {} }
		core.refresh_render(2)

		assert.are.equal(0, #scheduled)
	end)
end)
