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

describe("api.get_package in-flight coalescing", function()
	local old_vim
	local api
	local system_calls
	local exits

	before_each(function()
		old_vim = rawget(_G, "vim")
		system_calls = 0
		exits = {}
		_G.vim = {
			system = function(_, _, on_exit)
				system_calls = system_calls + 1
				exits[#exits + 1] = on_exit
				return {}
			end,
			schedule = function(fn)
				fn() -- run synchronously so tests can assert without a real loop
			end,
			json = {
				decode = function()
					return { releases = { { version = "1.4.4" } }, latest_stable_version = "1.4.4" }
				end,
			},
		}
		package.loaded["hex-outdated.hex_api"] = nil
		api = require("hex-outdated.hex_api")
	end)

	after_each(function()
		package.loaded["hex-outdated.hex_api"] = nil
		_G.vim = old_vim
	end)

	-- Drive the most-recently-spawned curl to completion with a 200 response.
	local function complete_last()
		exits[#exits]({ code = 0, stdout = "body\n200" })
	end

	it("spawns one process for concurrent fetches of the same package", function()
		local results = {}
		local function collect(r)
			results[#results + 1] = r
		end
		api.get_package("jason", { ttl_seconds = 3600 }, collect)
		api.get_package("jason", { ttl_seconds = 3600 }, collect)

		assert.are.equal(1, system_calls)
		assert.are.equal(0, #results) -- neither resolves until curl returns

		complete_last()

		assert.are.equal(2, #results)
		assert.are.equal(results[1], results[2]) -- both get the same result table
		assert.are.same({ "1.4.4" }, results[1].versions)
	end)

	it("serves a later fetch from cache without spawning again", function()
		api.get_package("jason", { ttl_seconds = 3600 }, function() end)
		complete_last()

		local cached
		api.get_package("jason", { ttl_seconds = 3600 }, function(r)
			cached = r
		end)

		assert.are.equal(1, system_calls)
		assert.are.same({ "1.4.4" }, cached.versions)
	end)

	it("spawns again once the previous request has finished", function()
		api.get_package("jason", { ttl_seconds = 3600 }, function() end)
		complete_last()

		-- force bypasses the fresh cache and, with no in-flight request, re-spawns
		api.get_package("jason", { ttl_seconds = 3600, force = true }, function() end)
		assert.are.equal(2, system_calls)
	end)

	it("serves last-known-good versions when a refetch fails", function()
		api.get_package("jason", { ttl_seconds = 3600 }, function() end)
		complete_last() -- success: caches versions { "1.4.4" }

		local res
		api.get_package("jason", { ttl_seconds = 3600, force = true }, function(r)
			res = r
		end)
		exits[#exits]({ code = 0, stdout = "{}\n503" }) -- refetch fails

		assert.is_truthy(res.error) -- the failure is still recorded
		assert.is_true(res.stale)
		assert.are.same({ "1.4.4" }, res.versions) -- but the good data survives
	end)
end)

describe("api.get_package negative caching", function()
	local old_vim
	local api
	local system_calls
	local exits

	before_each(function()
		old_vim = rawget(_G, "vim")
		system_calls = 0
		exits = {}
		_G.vim = {
			system = function(_, _, on_exit)
				system_calls = system_calls + 1
				exits[#exits + 1] = on_exit
				return {}
			end,
			schedule = function(fn)
				fn()
			end,
			json = {
				decode = function()
					return {}
				end,
			},
		}
		package.loaded["hex-outdated.hex_api"] = nil
		api = require("hex-outdated.hex_api")
	end)

	after_each(function()
		package.loaded["hex-outdated.hex_api"] = nil
		_G.vim = old_vim
	end)

	local function complete_error()
		exits[#exits]({ code = 0, stdout = "{}\n503" })
	end

	it("serves a recent failure from cache instead of re-spawning", function()
		api.get_package("jason", { error_ttl_seconds = 60 }, function() end)
		complete_error()

		local res
		api.get_package("jason", { error_ttl_seconds = 60 }, function(r)
			res = r
		end)

		assert.are.equal(1, system_calls) -- the cached failure is still fresh
		assert.is_truthy(res.error)
	end)

	it("re-spawns when negative caching is disabled (error_ttl_seconds = 0)", function()
		api.get_package("jason", { error_ttl_seconds = 0 }, function() end)
		complete_error()
		api.get_package("jason", { error_ttl_seconds = 0 }, function() end)

		assert.are.equal(2, system_calls)
	end)
end)

describe("api.get_package spawn failure", function()
	local old_vim
	local api
	local system_calls

	before_each(function()
		old_vim = rawget(_G, "vim")
		system_calls = 0
		_G.vim = {
			system = function()
				system_calls = system_calls + 1
				error("ENOENT: curl not found") -- libuv raises when the process can't spawn
			end,
			schedule = function(fn)
				fn()
			end,
			json = {
				decode = function()
					return {}
				end,
			},
		}
		package.loaded["hex-outdated.hex_api"] = nil
		api = require("hex-outdated.hex_api")
	end)

	after_each(function()
		package.loaded["hex-outdated.hex_api"] = nil
		_G.vim = old_vim
	end)

	it("delivers an error to the callback instead of raising", function()
		local result
		api.get_package("jason", {}, function(r)
			result = r
		end)

		assert.is_truthy(result)
		assert.is_truthy(result.error)
	end)

	it("clears the in-flight entry so a forced retry can re-spawn", function()
		api.get_package("jason", {}, function() end)
		local retried
		api.get_package("jason", { force = true }, function(r)
			retried = r
		end)

		assert.are.equal(2, system_calls) -- not poisoned: the second call attempts again
		assert.is_truthy(retried.error)
	end)
end)
