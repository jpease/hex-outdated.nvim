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

	it("warns exactly once and clamps to 1 for a NaN value (issue #70)", function()
		config.setup({ api = { max_concurrent = 0 / 0 } })

		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("max_concurrent"))
		assert.are.equal(1, config.options.api.max_concurrent)
	end)

	it("warns exactly once and clamps to 1 for positive infinity (issue #70)", function()
		config.setup({ api = { max_concurrent = math.huge } })

		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("max_concurrent"))
		assert.are.equal(1, config.options.api.max_concurrent)
	end)

	it("warns exactly once and clamps to 1 for negative infinity (issue #70)", function()
		config.setup({ api = { max_concurrent = -math.huge } })

		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("max_concurrent"))
		assert.are.equal(1, config.options.api.max_concurrent)
	end)
end)

describe("config cache TTL validation (issue #49)", function()
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

	it("warns exactly once and falls back to 3600 for an invalid ttl_seconds", function()
		config.setup({ cache = { ttl_seconds = "3600" } })

		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("ttl_seconds"))
		assert.are.equal(3600, config.options.cache.ttl_seconds)
	end)

	it("warns once and falls back to 60 for a negative error_ttl_seconds", function()
		config.setup({ cache = { error_ttl_seconds = -1 } })

		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("error_ttl_seconds"))
		assert.are.equal(60, config.options.cache.error_ttl_seconds)
	end)

	it("warns and falls back to 60 for a NaN error_ttl_seconds", function()
		config.setup({ cache = { error_ttl_seconds = 0 / 0 } })

		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("error_ttl_seconds"))
		assert.are.equal(60, config.options.cache.error_ttl_seconds)
	end)

	it("does not warn for a valid ttl_seconds of 0", function()
		config.setup({ cache = { ttl_seconds = 0 } })

		assert.are.equal(0, #warnings)
		assert.are.equal(0, config.options.cache.ttl_seconds)
	end)

	it("does not warn for a valid fractional ttl_seconds", function()
		config.setup({ cache = { ttl_seconds = 1.5 } })

		assert.are.equal(0, #warnings)
		assert.are.equal(1.5, config.options.cache.ttl_seconds)
	end)

	it("does not re-warn on a later valid setup call", function()
		config.setup({ cache = { ttl_seconds = "3600" } })
		config.setup({ cache = { ttl_seconds = 120 } })

		assert.are.equal(1, #warnings)
		assert.are.equal(120, config.options.cache.ttl_seconds)
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

describe("config.normalize (issue #72)", function()
	local config_module = require("hex-outdated.config")

	it("is a pure function: it does not read or write vim state", function()
		-- No _G.vim at all during this call. If normalize touches vim.* the
		-- require or the call itself raises "attempt to index a nil value".
		local old_vim = rawget(_G, "vim")
		_G.vim = nil
		local ok, normalized, warnings = pcall(config_module.normalize, config_module.defaults, {
			api = false,
			cache = { ttl_seconds = 0 / 0 },
			text = { up_to_date = 42 },
		})
		_G.vim = old_vim
		assert.is_true(ok)
		assert.are.equal("table", type(normalized))
		assert.are.equal("table", type(warnings))
	end)

	it("returns normalized options plus a warnings array without mutating defaults", function()
		local normalized, warnings = config_module.normalize(config_module.defaults, {})
		assert.are.same(config_module.defaults, normalized)
		assert.are.same({}, warnings)
	end)
end)

describe("config setup: malformed top-level input does not crash (issue #72)", function()
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

	it("does not crash and keeps defaults when opts itself is not a table", function()
		assert.has_no.errors(function()
			config.setup(false)
		end)
		assert.are.equal(1, #warnings)
		assert.are.same(config.defaults, config.options)
	end)

	it("does not crash for a string opts value", function()
		assert.has_no.errors(function()
			config.setup("nope")
		end)
		assert.are.equal(1, #warnings)
	end)

	it("does not warn when opts is nil (the normal reset-to-defaults call)", function()
		assert.has_no.errors(function()
			config.setup(nil)
		end)
		assert.are.equal(0, #warnings)
		assert.are.same(config.defaults, config.options)
	end)
end)

describe("config setup: malformed nested section shapes do not crash (issue #72)", function()
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

	local sections = { "api", "lock", "cache", "text", "highlight", "popup", "keymaps" }

	for _, section in ipairs(sections) do
		it("falls back to defaults and warns once when " .. section .. " is not a table", function()
			assert.has_no.errors(function()
				config.setup({ [section] = false })
			end)
			assert.are.equal(1, #warnings)
			assert.is_truthy(warnings[1]:find(section, 1, true))
			assert.are.same(config.defaults[section], config.options[section])
		end)
	end

	it("the reproduction from the issue no longer crashes: setup({ api = false })", function()
		assert.has_no.errors(function()
			config.setup({ api = false })
		end)
		assert.are.same(config.defaults.api, config.options.api)
	end)

	it("preserves unrelated sibling sections when one section is malformed", function()
		config.setup({ api = false, enabled = false })
		assert.are.same(config.defaults.api, config.options.api)
		assert.is_false(config.options.enabled)
	end)
end)

describe("config setup: api.timeout_ms validation (issue #72)", function()
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
		config.setup({})
	end)

	it("warns once and falls back to 5000 for a NaN timeout_ms", function()
		config.setup({ api = { timeout_ms = 0 / 0 } })
		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("timeout_ms"))
		assert.are.equal(5000, config.options.api.timeout_ms)
	end)

	it("warns once and falls back to 5000 for positive infinity", function()
		config.setup({ api = { timeout_ms = math.huge } })
		assert.are.equal(1, #warnings)
		assert.are.equal(5000, config.options.api.timeout_ms)
	end)

	it("warns once and falls back to 5000 for negative infinity", function()
		config.setup({ api = { timeout_ms = -math.huge } })
		assert.are.equal(1, #warnings)
		assert.are.equal(5000, config.options.api.timeout_ms)
	end)

	it("warns and falls back to 5000 for zero (must be strictly positive)", function()
		config.setup({ api = { timeout_ms = 0 } })
		assert.are.equal(1, #warnings)
		assert.are.equal(5000, config.options.api.timeout_ms)
	end)

	it("warns and falls back to 5000 for a negative value", function()
		config.setup({ api = { timeout_ms = -100 } })
		assert.are.equal(1, #warnings)
		assert.are.equal(5000, config.options.api.timeout_ms)
	end)

	it("does not warn for a valid positive value and keeps it unfloored", function()
		config.setup({ api = { timeout_ms = 1234.5 } })
		assert.are.equal(0, #warnings)
		assert.are.equal(1234.5, config.options.api.timeout_ms)
	end)
end)

describe("config setup: debounce_ms validation (issue #72)", function()
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
		config.setup({})
	end)

	it("warns once and falls back to 500 for a NaN debounce_ms", function()
		config.setup({ debounce_ms = 0 / 0 })
		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("debounce_ms"))
		assert.are.equal(500, config.options.debounce_ms)
	end)

	it("warns once and falls back to 500 for infinity", function()
		config.setup({ debounce_ms = math.huge })
		assert.are.equal(1, #warnings)
		assert.are.equal(500, config.options.debounce_ms)
	end)

	it("warns and falls back to 500 for a negative value", function()
		config.setup({ debounce_ms = -1 })
		assert.are.equal(1, #warnings)
		assert.are.equal(500, config.options.debounce_ms)
	end)

	it("does not warn for a valid zero (no debounce is a legitimate setting)", function()
		config.setup({ debounce_ms = 0 })
		assert.are.equal(0, #warnings)
		assert.are.equal(0, config.options.debounce_ms)
	end)

	it("floors a fractional value without warning", function()
		config.setup({ debounce_ms = 250.9 })
		assert.are.equal(0, #warnings)
		assert.are.equal(250, config.options.debounce_ms)
	end)
end)

describe("config setup: popup.max_height validation (issue #72)", function()
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
		config.setup({})
	end)

	it("warns once and falls back to 20 for a NaN max_height", function()
		config.setup({ popup = { max_height = 0 / 0 } })
		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("max_height"))
		assert.are.equal(20, config.options.popup.max_height)
	end)

	it("warns and falls back to 20 for zero", function()
		config.setup({ popup = { max_height = 0 } })
		assert.are.equal(1, #warnings)
		assert.are.equal(20, config.options.popup.max_height)
	end)

	it("warns and falls back to 20 for infinity", function()
		config.setup({ popup = { max_height = math.huge } })
		assert.are.equal(1, #warnings)
		assert.are.equal(20, config.options.popup.max_height)
	end)

	it("floors a valid fractional value without warning", function()
		config.setup({ popup = { max_height = 15.9 } })
		assert.are.equal(0, #warnings)
		assert.are.equal(15, config.options.popup.max_height)
	end)
end)

describe("config setup: text/highlight/popup string-leaf validation (issue #72)", function()
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
		config.setup({})
	end)

	it("falls back to the default template and warns once for a non-string text leaf", function()
		config.setup({ text = { up_to_date = 42 } })
		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("up_to_date", 1, true))
		assert.are.equal(config.defaults.text.up_to_date, config.options.text.up_to_date)
	end)

	it(
		"falls back to the default group name and warns once for a non-string highlight leaf",
		function()
			config.setup({ highlight = { outdated = false } })
			assert.are.equal(1, #warnings)
			assert.are.equal(config.defaults.highlight.outdated, config.options.highlight.outdated)
		end
	)

	it("falls back to the default border and warns once for a non-string popup.border", function()
		config.setup({ popup = { border = 7 } })
		assert.are.equal(1, #warnings)
		assert.is_truthy(warnings[1]:find("border", 1, true))
		assert.are.equal(config.defaults.popup.border, config.options.popup.border)
	end)

	it(
		"falls back to the default hover_key and warns once for a non-string popup.hover_key",
		function()
			config.setup({ popup = { hover_key = {} } })
			assert.are.equal(1, #warnings)
			assert.are.equal(config.defaults.popup.hover_key, config.options.popup.hover_key)
		end
	)

	it("does not warn when every text/highlight/popup leaf is valid", function()
		config.setup({ text = { up_to_date = "ok %s" }, popup = { border = "single" } })
		assert.are.equal(0, #warnings)
		assert.are.equal("ok %s", config.options.text.up_to_date)
		assert.are.equal("single", config.options.popup.border)
	end)
end)

describe("config setup: only one warning per invalid field, not per section (issue #72)", function()
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
		config.setup({})
	end)

	it("emits exactly one warning per distinct invalid field across a mixed setup call", function()
		config.setup({
			api = { max_concurrent = 0, timeout_ms = 0 / 0 },
			cache = { ttl_seconds = "bad" },
			debounce_ms = -1,
			popup = { max_height = 0 },
			text = { up_to_date = 1 },
		})
		-- 6 invalid fields: max_concurrent, timeout_ms, ttl_seconds, debounce_ms,
		-- max_height, up_to_date — exactly one warning each, none duplicated.
		assert.are.equal(6, #warnings)
	end)

	it("emits no warnings at all for a fully valid, fully-specified setup call", function()
		config.setup({
			enabled = false,
			auto_update = false,
			debounce_ms = 200,
			api = { base_url = "https://x", timeout_ms = 2000, max_concurrent = 3 },
			lock = { enabled = false, lens = true, stale_diagnostic = false },
			cache = { ttl_seconds = 10, error_ttl_seconds = 5 },
			text = { up_to_date = "yes %s" },
			highlight = { outdated = "MyHl" },
			popup = { border = "single", max_height = 10, hover_key = "H" },
			keymaps = { upgrade = "<leader>u" },
		})
		assert.are.equal(0, #warnings)
	end)
end)
