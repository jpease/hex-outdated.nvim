local health = require("hex-outdated.health")

describe("health._reachability_verdict", function()
	it("reports ok when the probe succeeds (curl exit 0)", function()
		local level, msg = health._reachability_verdict(0)
		assert.are.equal("ok", level)
		assert.is_truthy(msg:find("hex.pm", 1, true))
	end)

	it("warns with the curl exit code when the probe fails", function()
		local level, msg = health._reachability_verdict(7)
		assert.are.equal("warn", level)
		assert.is_truthy(msg:find("7", 1, true))
	end)
end)

describe("health._probe_command", function()
	local old_vim

	after_each(function()
		_G.vim = old_vim
	end)

	it("preserves fractional timeout seconds on non-Windows", function()
		old_vim = rawget(_G, "vim")
		_G.vim = { fn = {
			has = function()
				return 0
			end,
		} }
		assert.are.same(
			{ "curl", "-sS", "-o", "/dev/null", "--max-time", "1.999", "https://example.test" },
			health._probe_command("https://example.test", 1999)
		)
	end)

	it("falls back to five seconds for invalid timeout values on non-Windows", function()
		old_vim = rawget(_G, "vim")
		_G.vim = { fn = {
			has = function()
				return 0
			end,
		} }
		assert.are.same(
			{ "curl", "-sS", "-o", "/dev/null", "--max-time", "5", "https://example.test" },
			health._probe_command("https://example.test", 0)
		)
	end)

	it("uses NUL device on Windows", function()
		old_vim = rawget(_G, "vim")
		_G.vim = { fn = {
			has = function()
				return 1
			end,
		} }
		assert.are.same(
			{ "curl", "-sS", "-o", "NUL", "--max-time", "1.999", "https://example.test" },
			health._probe_command("https://example.test", 1999)
		)
	end)

	it("uses /dev/null device on non-Windows", function()
		old_vim = rawget(_G, "vim")
		_G.vim = { fn = {
			has = function()
				return 0
			end,
		} }
		assert.are.same(
			{ "curl", "-sS", "-o", "/dev/null", "--max-time", "1.999", "https://example.test" },
			health._probe_command("https://example.test", 1999)
		)
	end)
end)
