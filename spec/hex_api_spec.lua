local hex_api = require("hex-outdated.hex_api")

describe("hex_api pure helpers", function()
	describe("_curl_command", function()
		it("builds the curl command from opts", function()
			assert.are.same(
				{
					"curl",
					"-sSL",
					"--max-time",
					"5",
					"-w",
					"\n%{http_code}",
					"https://example.test/api/packages/jason",
				},
				hex_api._curl_command("jason", {
					base_url = "https://example.test/api",
					timeout_ms = 5200,
				})
			)
		end)
	end)

	describe("_parse_package_response", function()
		local function now()
			return 123
		end

		it("normalizes successful package JSON", function()
			local result = hex_api._parse_package_response({
				code = 0,
				stdout = '{"ok":true}\n200',
			}, function(body)
				assert.are.equal('{"ok":true}', body)
				return {
					latest_stable_version = "1.7.14",
					latest_version = "1.8.0-rc.0",
					releases = {
						{ version = "1.7.14" },
						{ other = "ignored" },
						{ version = "1.6.16" },
					},
				}
			end, now)

			assert.are.same({
				versions = { "1.7.14", "1.6.16" },
				latest = "1.7.14",
				time = 123,
			}, result)
		end)

		it("falls back to latest_version when no stable version is present", function()
			local result = hex_api._parse_package_response({
				code = 0,
				stdout = "{}\n200",
			}, function()
				return { latest_version = "1.8.0-rc.0" }
			end, now)

			assert.are.same({
				versions = {},
				latest = "1.8.0-rc.0",
				time = 123,
			}, result)
		end)

		it("normalizes request and HTTP failures", function()
			assert.are.same(
				{ error = "request failed" },
				hex_api._parse_package_response({ code = 7 }, function() end, now)
			)
			assert.are.same(
				{ error = "malformed response (no http_code trailer)" },
				hex_api._parse_package_response({ code = 0, stdout = "{}" }, function() end, now)
			)
			assert.are.same(
				{ error = "package not found", not_found = true },
				hex_api._parse_package_response(
					{ code = 0, stdout = "{}\n404" },
					function() end,
					now
				)
			)
			assert.are.same(
				{ error = "http 503" },
				hex_api._parse_package_response(
					{ code = 0, stdout = "{}\n503" },
					function() end,
					now
				)
			)
		end)

		it("rejects invalid decoded JSON", function()
			assert.are.same(
				{ error = "invalid response" },
				hex_api._parse_package_response({ code = 0, stdout = "nope\n200" }, function()
					error("bad json")
				end, now)
			)
			assert.are.same(
				{ error = "invalid response" },
				hex_api._parse_package_response({ code = 0, stdout = "[]\n200" }, function()
					return "not a table"
				end, now)
			)
		end)
	end)
end)
