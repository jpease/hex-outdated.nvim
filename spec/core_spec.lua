describe("core", function()
	local old_vim
	local core
	local scheduled
	local rendered

	before_each(function()
		old_vim = rawget(_G, "vim")
		scheduled = {}
		rendered = {}
		package.loaded["hex-outdated.render"] = {
			render = function(_, items)
				rendered[#rendered + 1] = items
			end,
		}
		_G.vim = {
			api = {
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

	-- Render `deps` for buffer 1 and return the items handed to render.render.
	local function render_deps(deps)
		core.state[1] = { enabled = true, deps = deps }
		core.refresh_render(1)
		scheduled[#scheduled]()
		return rendered[#rendered]
	end

	describe("refresh_render items", function()
		it("renders hex deps only, skipping unknown requirements", function()
			local items = render_deps({
				{ kind = "hex", row = 1, col_start = 12, col_end = 18, name = "phoenix" },
				{ kind = "hex", status = "unknown", row = 2, name = "ecto" },
				{ kind = "path", row = 3, name = "local_dep" },
				{
					kind = "hex",
					status = "upgradable",
					row = 4,
					col_start = 10,
					col_end = 16,
					name = "jason",
					latest = "1.4.4",
				},
			})

			assert.are.equal(2, #items)
			assert.are.equal("phoenix", items[1].name)
			assert.are.equal("loading", items[1].status)
			assert.are.equal(12, items[1].col_start)
			assert.are.equal(18, items[1].col_end)
			assert.are.equal("jason", items[2].name)
			assert.are.equal("upgradable", items[2].status)
			assert.are.equal("1.4.4", items[2].latest)
		end)

		it("carries lock fields and flags a lock behind latest", function()
			local items = render_deps({
				{
					kind = "hex",
					name = "jason",
					requirement = "~> 1.0",
					status = "upgradable",
					latest = "1.4.5",
					locked = "1.2.0",
					lock_out_of_range = false,
					row = 3,
				},
			})
			assert.are.equal("1.2.0", items[1].locked)
			assert.are.equal("~> 1.0", items[1].requirement)
			assert.is_true(items[1].lock_behind)
			assert.is_falsy(items[1].lock_out_of_range)
		end)

		it("does not flag lock_behind while latest is unknown", function()
			local items = render_deps({
				{ kind = "hex", name = "x", status = "loading", locked = "1.1.0", row = 0 },
			})
			assert.are.equal("1.1.0", items[1].locked)
			assert.is_falsy(items[1].lock_behind)
		end)
	end)

	describe("apply_package_result", function()
		it("maps a 404 to invalid and other failures to error, clearing old data", function()
			local dep = { requirement = "~> 1.6", status = "loading", latest = "1.0.0" }
			core.apply_package_result(dep, { error = "package not found", not_found = true })
			assert.are.equal("invalid", dep.status)
			assert.is_nil(dep.latest)

			core.apply_package_result(dep, { error = "http 500" })
			assert.are.equal("error", dep.status)
		end)

		it("classifies stale results that still carry versions", function()
			local dep = { requirement = "~> 1.6" }
			core.apply_package_result(dep, { error = "http 503", versions = { "1.6.0", "1.7.14" } })
			assert.are.equal("upgradable", dep.status)
			assert.are.equal("1.7.14", dep.latest)
		end)

		it("classifies successful package results", function()
			local dep = { requirement = "~> 1.6" }
			core.apply_package_result(dep, { versions = { "1.6.0", "1.6.16", "1.7.14" } })
			assert.are.equal("upgradable", dep.status)
			assert.are.equal("1.7.14", dep.latest)
			assert.are.equal("~> 1.7", dep.suggested)
			assert.are.equal("~>", dep.op)
		end)
	end)

	describe("refresh_render coalescing", function()
		it("renders nothing inline and schedules a single tick for many calls", function()
			core.state[1] = { enabled = true, deps = {} }
			core.refresh_render(1)
			core.refresh_render(1)
			core.refresh_render(1)

			assert.are.equal(0, #rendered)
			assert.are.equal(1, #scheduled)

			scheduled[1]()
			assert.are.equal(1, #rendered)
		end)

		it("schedules a fresh render once the previous tick has flushed", function()
			core.state[1] = { enabled = true, deps = {} }
			core.refresh_render(1)
			scheduled[1]()
			core.refresh_render(1)

			assert.are.equal(2, #scheduled)
			scheduled[2]()
			assert.are.equal(2, #rendered)
		end)

		it("skips the render if the buffer was disabled before the tick ran", function()
			core.state[1] = { enabled = true, deps = {} }
			core.refresh_render(1)
			core.state[1].enabled = false

			scheduled[1]()
			assert.are.equal(0, #rendered)
		end)

		it("does nothing for an unknown or disabled buffer", function()
			core.refresh_render(99)
			core.state[2] = { enabled = false, deps = {} }
			core.refresh_render(2)

			assert.are.equal(0, #scheduled)
		end)
	end)
end)
