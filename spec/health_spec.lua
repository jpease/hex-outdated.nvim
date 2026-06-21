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
	it("preserves fractional timeout seconds", function()
		assert.are.same(
			{ "curl", "-sS", "-o", "/dev/null", "--max-time", "1.999", "https://example.test" },
			health._probe_command("https://example.test", 1999)
		)
	end)

	it("falls back to five seconds for invalid timeout values", function()
		assert.are.same(
			{ "curl", "-sS", "-o", "/dev/null", "--max-time", "5", "https://example.test" },
			health._probe_command("https://example.test", 0)
		)
	end)
end)
