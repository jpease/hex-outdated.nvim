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
