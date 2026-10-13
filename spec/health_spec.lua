local config = require("hex-outdated.config")
local fake_vim = require("spec.helpers.fake_vim")
local health = require("hex-outdated.health")

describe("health.check", function()
	local restore_vim
	local reports
	local probe
	local windows
	local curl_exit

	local function report(level)
		return function(msg)
			reports[#reports + 1] = { level = level, msg = msg }
		end
	end

	local function find(pattern)
		for _, r in ipairs(reports) do
			if r.msg:find(pattern, 1, true) then
				return r
			end
		end
	end

	before_each(function()
		reports = {}
		probe = nil
		windows = false
		curl_exit = 0
		restore_vim = select(
			2,
			fake_vim.install({
				fn = {
					has = function(feature)
						if feature == "win32" then
							return windows and 1 or 0
						end
						return 1
					end,
					executable = function()
						return 1
					end,
				},
				version = function()
					return "0.11.0"
				end,
				system = function(cmd)
					probe = cmd
					return {
						wait = function()
							return { code = curl_exit }
						end,
					}
				end,
				health = {
					start = function() end,
					ok = report("ok"),
					warn = report("warn"),
					error = report("error"),
				},
				treesitter = {
					language = {
						add = function()
							return true
						end,
					},
				},
			})
		)
	end)

	after_each(function()
		config.setup({})
		restore_vim()
	end)

	it("probes the configured API with the configured timeout", function()
		config.setup({ api = { base_url = "https://mirror.test/api", timeout_ms = 1999 } })
		health.check()
		assert.are.same(
			{ "curl", "-sS", "-o", "/dev/null", "--max-time", "1.999", "https://mirror.test/api" },
			probe
		)
	end)

	it("discards the probe body to NUL on Windows", function()
		windows = true
		health.check()
		assert.are.equal("NUL", probe[4])
	end)

	it("reports the configured host as reachable when curl succeeds", function()
		config.setup({ api = { base_url = "https://mirror.test/api" } })
		health.check()
		assert.are.equal("ok", find("mirror.test").level)
		assert.is_nil(find("hex.pm"))
	end)

	it("warns with the curl exit code when the probe fails", function()
		curl_exit = 7
		health.check()
		local r = find("hex.pm")
		assert.are.equal("warn", r.level)
		assert.is_truthy(r.msg:find("7", 1, true))
	end)
end)
