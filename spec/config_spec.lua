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
