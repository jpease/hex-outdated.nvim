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
