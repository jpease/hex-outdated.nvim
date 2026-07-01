local config = require("hex-outdated.config")

describe("config", function()
	before_each(function()
		config.setup({}) -- reset to defaults
	end)

	it("exposes sensible defaults", function()
		assert.are.equal("https://hex.pm/api", config.options.api.base_url)
		assert.is_true(config.options.enabled)
		assert.are.equal(3600, config.options.cache.ttl_seconds)
	end)

	it("deep-merges user options over defaults", function()
		config.setup({ api = { timeout_ms = 1234 }, enabled = false })
		assert.are.equal(1234, config.options.api.timeout_ms)
		assert.are.equal("https://hex.pm/api", config.options.api.base_url) -- preserved
		assert.is_false(config.options.enabled)
	end)
end)

describe("config api.max_concurrent validation (issue #35)", function()
	local old_vim
	local warnings

	before_each(function()
		old_vim = rawget(_G, "vim")
		warnings = {}
		_G.vim = {
			notify = function(msg, _level)
				warnings[#warnings + 1] = msg
			end,
			log = { levels = { WARN = 2 } },
		}
	end)

	after_each(function()
		_G.vim = old_vim
		config.setup({}) -- reset to defaults for subsequent describe blocks
	end)

	it("warns exactly once and clamps to 1 for an invalid value", function()
		config.setup({ api = { max_concurrent = 0 } })

		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("max_concurrent"))
		assert.are.equal(1, config.options.api.max_concurrent)
	end)

	it("does not re-warn on a later valid setup call", function()
		config.setup({ api = { max_concurrent = 0 } })
		config.setup({ api = { max_concurrent = 4 } })

		assert.are.equal(1, #warnings)
		assert.are.equal(4, config.options.api.max_concurrent)
	end)

	it("does not warn for a valid positive integer", function()
		config.setup({ api = { max_concurrent = 4 } })

		assert.are.equal(0, #warnings)
		assert.are.equal(4, config.options.api.max_concurrent)
	end)

	it("floors a fractional value greater than 1 without warning", function()
		config.setup({ api = { max_concurrent = 2.9 } })

		assert.are.equal(0, #warnings)
		assert.are.equal(2, config.options.api.max_concurrent)
	end)
end)

describe("config lock defaults", function()
	it("exposes lock, hover_key, and lens text/highlight defaults", function()
		config.setup({})
		local o = config.options
		assert.is_true(o.lock.enabled)
		assert.is_false(o.lock.lens)
		assert.is_true(o.lock.stale_diagnostic)
		assert.are.equal("K", o.popup.hover_key)
		assert.are.equal("locked %s · latest %s", o.text.lock_behind)
		assert.are.equal("locked %s · up to date", o.text.lock_current)
		assert.are.equal("HexOutdatedLock", o.highlight.lock)
		assert.are.equal("HexOutdatedLockBehind", o.highlight.lock_behind)
	end)
end)
