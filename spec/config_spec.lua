local config = require("hex-outdated.config")
local fake_vim = require("spec.helpers.fake_vim")

local fake, restore_vim

before_each(function()
	fake, restore_vim = fake_vim.install()
end)

after_each(function()
	config.setup({})
	restore_vim()
end)

local function warnings()
	return fake.notified
end

describe("config", function()
	it("deep-merges user options over defaults", function()
		config.setup({ api = { timeout_ms = 1234 }, enabled = false })
		assert.are.equal(1234, config.options.api.timeout_ms)
		assert.are.equal(config.defaults.api.base_url, config.options.api.base_url)
		assert.is_false(config.options.enabled)
	end)

	it("does not re-warn on a later valid setup call", function()
		config.setup({ api = { max_concurrent = 0 } })
		config.setup({ api = { max_concurrent = 4 } })
		assert.are.equal(1, #warnings())
		assert.are.equal(4, config.options.api.max_concurrent)
	end)
end)

describe("config.normalize", function()
	it("does not touch vim", function()
		local previous = rawget(_G, "vim")
		_G.vim = nil
		local ok, normalized, warns = pcall(config.normalize, config.defaults, {
			api = false,
			cache = { ttl_seconds = 0 / 0 },
			text = { up_to_date = 42 },
		})
		_G.vim = previous
		assert.is_true(ok)
		assert.are.equal("table", type(normalized))
		assert.are.equal(3, #warns)
	end)

	it("returns a copy of the defaults and no warnings for empty input", function()
		local normalized, warns = config.normalize(config.defaults, {})
		assert.are.same(config.defaults, normalized)
		assert.are_not.equal(config.defaults.api, normalized.api)
		assert.are.same({}, warns)
	end)
end)

describe("config numeric validation", function()
	-- { section, field, input, accepted value }; no accepted value means the
	-- input is invalid and falls back to the default with one warning.
	local cases = {
		{ "api", "max_concurrent", 4, 4 },
		{ "api", "max_concurrent", 2.9, 2 },
		{ "api", "max_concurrent", 0 },
		{ "api", "max_concurrent", 0 / 0 },
		{ "api", "max_concurrent", math.huge },
		{ "api", "max_concurrent", -math.huge },
		{ "api", "timeout_ms", 1234.5, 1234.5 },
		{ "api", "timeout_ms", 0 },
		{ "api", "timeout_ms", -100 },
		{ "api", "timeout_ms", 0 / 0 },
		{ "api", "timeout_ms", math.huge },
		{ nil, "debounce_ms", 0, 0 },
		{ nil, "debounce_ms", 250.9, 250 },
		{ nil, "debounce_ms", -1 },
		{ nil, "debounce_ms", math.huge },
		{ "cache", "ttl_seconds", 0, 0 },
		{ "cache", "ttl_seconds", 1.5, 1.5 },
		{ "cache", "ttl_seconds", "3600" },
		{ "cache", "error_ttl_seconds", -1 },
		{ "cache", "error_ttl_seconds", 0 / 0 },
		{ "popup", "max_height", 15.9, 15 },
		{ "popup", "max_height", 0 },
		{ "popup", "max_height", math.huge },
	}

	for _, case in ipairs(cases) do
		local section, field, input, accepted = case[1], case[2], case[3], case[4]
		local label = (section and (section .. ".") or "") .. field
		it(string.format("%s = %s", label, tostring(input)), function()
			config.setup(section and { [section] = { [field] = input } } or { [field] = input })
			local get = function(t)
				return (section and t[section] or t)[field]
			end
			if accepted ~= nil then
				assert.are.equal(accepted, get(config.options))
				assert.are.equal(0, #warnings())
			else
				assert.are.equal(get(config.defaults), get(config.options))
				assert.are.equal(1, #warnings())
			end
		end)
	end
end)

describe("config malformed shapes", function()
	it("keeps defaults and warns once when opts itself is not a table", function()
		for _, opts in ipairs({ false, "nope" }) do
			fake.notified = {}
			config.setup(opts)
			assert.are.equal(1, #warnings())
			assert.are.same(config.defaults, config.options)
		end
	end)

	it("does not warn when opts is nil", function()
		config.setup(nil)
		assert.are.equal(0, #warnings())
		assert.are.same(config.defaults, config.options)
	end)

	for _, section in ipairs({ "api", "lock", "cache", "text", "highlight", "popup", "keymaps" }) do
		it("falls back to the defaults when " .. section .. " is not a table", function()
			config.setup({ [section] = false, enabled = false })
			assert.are.equal(1, #warnings())
			assert.are.same(config.defaults[section], config.options[section])
			assert.is_false(config.options.enabled)
		end)
	end
end)

describe("config string validation", function()
	-- { section, field, invalid value }
	local cases = {
		{ "text", "up_to_date", 42 },
		{ "highlight", "outdated", false },
		{ "popup", "border", 7 },
		{ "popup", "hover_key", {} },
		{ "popup", "hover_key", true },
		{ "api", "base_url", 1 },
	}
	for _, case in ipairs(cases) do
		local section, field, value = case[1], case[2], case[3]
		it(
			string.format("%s.%s = %s falls back to the default", section, field, tostring(value)),
			function()
				config.setup({ [section] = { [field] = value } })
				assert.are.equal(1, #warnings())
				assert.are.equal(config.defaults[section][field], config.options[section][field])
			end
		)
	end

	it("accepts popup.hover_key = false to disable the hover mapping", function()
		config.setup({ popup = { hover_key = false } })
		assert.are.equal(0, #warnings())
		assert.is_false(config.options.popup.hover_key)
	end)

	it("drops a non-string keymap and keeps the valid ones", function()
		config.setup({ keymaps = { upgrade = "<leader>u", versions = true } })
		assert.are.equal(1, #warnings())
		assert.are.same({ upgrade = "<leader>u" }, config.options.keymaps)
	end)
end)

describe("config warnings", function()
	it("emits exactly one warning per invalid field", function()
		config.setup({
			api = { max_concurrent = 0, timeout_ms = 0 / 0 },
			cache = { ttl_seconds = "bad" },
			debounce_ms = -1,
			popup = { max_height = 0 },
			text = { up_to_date = 1 },
		})
		assert.are.equal(6, #warnings())
	end)

	it("emits none for a fully valid, fully specified setup call", function()
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
		assert.are.equal(0, #warnings())
	end)
end)
