local hex_api = require("hex-outdated.hex_api")

describe("hex_api pure helpers", function()
	describe("_curl_command", function()
		it("builds the curl command from opts", function()
			assert.are.same(
				{
					"curl",
					"-sSL",
					"--max-time",
					"5.2",
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
				retirements = {},
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
				retirements = {},
				time = 123,
			}, result)
		end)

		it("excludes retired releases and chooses the latest active release", function()
			local result = hex_api._parse_package_response({
				code = 0,
				stdout = "{}\n200",
			}, function()
				return {
					latest_stable_version = "2.0.0",
					latest_version = "2.0.0",
					releases = {
						{ version = "2.0.0" },
						{ version = "1.9.0" },
						{ version = "1.8.0" },
					},
					retirements = {
						["2.0.0"] = { reason = "invalid" },
					},
				}
			end, now)

			assert.are.same({ "1.9.0", "1.8.0" }, result.versions)
			assert.are.equal("1.9.0", result.latest)
			assert.are.same({ reason = "invalid" }, result.retirements["2.0.0"])
			assert.is_nil(result.all_retired)
		end)

		it("returns no active versions when every release is retired", function()
			local result = hex_api._parse_package_response({
				code = 0,
				stdout = "{}\n200",
			}, function()
				return {
					latest_stable_version = "1.0.0",
					releases = {
						{ version = "1.0.0" },
					},
					retirements = {
						["1.0.0"] = { reason = "invalid" },
					},
				}
			end, now)

			assert.are.same({}, result.versions)
			assert.is_nil(result.latest)
			assert.is_true(result.all_retired)
		end)

		it("describes curl exit codes so failures are actionable", function()
			local function err_for(code)
				return hex_api._parse_package_response({ code = code }, function() end, now).error
			end
			assert.are.equal("could not resolve hex.pm", err_for(6))
			assert.are.equal("could not connect to hex.pm", err_for(7))
			assert.are.equal("request timed out", err_for(28))
			assert.are.equal("request failed (curl 35)", err_for(35))
		end)

		it("normalizes request and HTTP failures", function()
			assert.are.same(
				{ error = "could not connect to hex.pm" },
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

		it("rejects a non-table releases field", function()
			assert.are.same(
				{ error = "invalid response" },
				hex_api._parse_package_response({ code = 0, stdout = "{}\n200" }, function()
					return { releases = "not a table" }
				end, now)
			)
		end)

		it("rejects a releases table containing non-table entries (issue #46 repro)", function()
			-- Confirm the malformed body actually raises pre-fix, not just returns a
			-- wrong value: `rel.version` indexes a number when `rel` is `1`.
			assert.has_error(function()
				local ok, data = pcall(function()
					return { releases = { 1 } }
				end)
				assert.is_true(ok)
				for _, rel in ipairs(data.releases) do
					local _ = rel.version -- luacheck: ignore
				end
			end)

			assert.are.same(
				{ error = "invalid response" },
				hex_api._parse_package_response({ code = 0, stdout = "{}\n200" }, function()
					return { releases = { 1 } }
				end, now)
			)
		end)

		it("rejects a release entry whose version field is the wrong type", function()
			assert.are.same(
				{ error = "invalid response" },
				hex_api._parse_package_response({ code = 0, stdout = "{}\n200" }, function()
					return { releases = { { version = 42 } } }
				end, now)
			)
		end)

		it("still accepts a table release entry lacking a version key (no regression)", function()
			-- Same body shape as "normalizes successful package JSON" above: the
			-- `{ other = "ignored" }` entry has no `version` key at all and must
			-- keep being silently skipped rather than treated as an error.
			local result = hex_api._parse_package_response({
				code = 0,
				stdout = '{"ok":true}\n200',
			}, function()
				return {
					latest_stable_version = "1.7.14",
					releases = {
						{ version = "1.7.14" },
						{ other = "ignored" },
					},
				}
			end, now)

			assert.are.same({ "1.7.14" }, result.versions)
			assert.are.equal("1.7.14", result.latest)
			assert.is_nil(result.error)
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

	it("makes separate requests for the same package on different endpoints", function()
		local results = {}
		api.get_package(
			"demo",
			{ base_url = "https://one.test/api", ttl_seconds = 3600 },
			function(r)
				results[#results + 1] = r
			end
		)
		complete_last()

		api.get_package(
			"demo",
			{ base_url = "https://two.test/api", ttl_seconds = 3600 },
			function(r)
				results[#results + 1] = r
			end
		)
		complete_last()

		assert.are.equal(2, system_calls)
		assert.are.equal(2, #results)
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

	it("does not reuse stale versions for a definitive 404 (issue #48)", function()
		api.get_package("jason", { ttl_seconds = 3600 }, function() end)
		complete_last() -- success: caches versions { "1.4.4" }

		local res
		api.get_package("jason", { ttl_seconds = 3600, force = true }, function(r)
			res = r
		end)
		exits[#exits]({ code = 0, stdout = "{}\n404" }) -- refetch: package removed

		assert.is_truthy(res.error)
		assert.is_true(res.not_found)
		assert.is_nil(res.stale)
		assert.is_nil(res.versions)
		assert.is_nil(res.latest)
	end)
end)

describe("api.get_package concurrency cap", function()
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
					return { releases = {} }
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

	it("queues fetches beyond the cap and drains them on completion", function()
		api.get_package("a", { max_concurrent = 1 }, function() end)
		api.get_package("b", { max_concurrent = 1 }, function() end)

		assert.are.equal(1, system_calls) -- "b" is queued behind "a"

		exits[#exits]({ code = 0, stdout = "body\n200" }) -- "a" finishes

		assert.are.equal(2, system_calls) -- the queue drains and "b" starts
	end)

	it("drains the queue after a malformed response ahead of it completes (#46)", function()
		-- Unlike the other tests in this block, this one needs the stubbed
		-- decode to actually reflect the malformed body it's fed, rather than
		-- always returning `{ releases = {} }`.
		_G.vim.json.decode = function(body)
			if body:match("releases") then
				return { releases = { 1 } }
			end
			return { releases = {} }
		end

		local result_a
		local result_b
		api.get_package("a", { max_concurrent = 1 }, function(r)
			result_a = r
		end)
		api.get_package("b", { max_concurrent = 1 }, function(r)
			result_b = r
		end)

		assert.are.equal(1, system_calls) -- "b" is queued behind "a"

		-- "a"'s response decodes fine at the top level but has a malformed
		-- nested releases entry (a number instead of a release table). Pre-fix,
		-- this raises inside the vim.system completion callback, `deliver()`
		-- never runs, and "b" stalls in the queue forever.
		exits[#exits]({ code = 0, stdout = '{"releases":[1]}\n200' })

		assert.are.equal(2, system_calls) -- the queue still drains and "b" starts
		assert.is_truthy(result_a) -- "a"'s own callback still received a result
		assert.is_truthy(result_a.error) -- ...specifically an error, not a raised exception

		exits[#exits]({ code = 0, stdout = "body\n200" }) -- "b" finishes
		assert.is_truthy(result_b)
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

-- get_package's own clamp is a silent defensive fallback (issue #35): the
-- user-visible warning for invalid config now lives in config.setup(), which
-- runs once per setup() call rather than once per dependency per refresh.
describe("api.get_package max_concurrent clamping", function()
	local old_vim
	local api
	local system_calls
	local exits
	local warnings

	before_each(function()
		old_vim = rawget(_G, "vim")
		system_calls = 0
		exits = {}
		warnings = {}
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
					return { releases = { { version = "1.0.0" } }, latest_stable_version = "1.0.0" }
				end,
			},
			notify = function(msg, _level)
				warnings[#warnings + 1] = msg
			end,
			log = { levels = { WARN = 2 } },
		}
		package.loaded["hex-outdated.hex_api"] = nil
		api = require("hex-outdated.hex_api")
	end)

	after_each(function()
		package.loaded["hex-outdated.hex_api"] = nil
		_G.vim = old_vim
	end)

	local function complete_last()
		exits[#exits]({ code = 0, stdout = "body\n200" })
	end

	it("clamps zero to 1 without warning", function()
		local done = false
		api.get_package("a", { max_concurrent = 0 }, function()
			done = true
		end)
		complete_last()

		assert.is_true(done)
		assert.are.equal(1, system_calls)
		assert.are.equal(0, #warnings)
	end)

	it("clamps a negative value to 1 without warning", function()
		local done = false
		api.get_package("a", { max_concurrent = -5 }, function()
			done = true
		end)
		complete_last()

		assert.is_true(done)
		assert.are.equal(0, #warnings)
	end)

	it("floors a fractional value greater than 1 without warning", function()
		api.get_package("a", { max_concurrent = 1.9 }, function() end)
		api.get_package("b", { max_concurrent = 1.9 }, function() end)

		assert.are.equal(1, system_calls) -- floored to 1; "b" queued
		assert.are.equal(0, #warnings)
		complete_last()
		assert.are.equal(2, system_calls)
	end)

	it("clamps a non-number to 1 without warning", function()
		local done = false
		api.get_package("a", { max_concurrent = "2" }, function()
			done = true
		end)
		complete_last()

		assert.is_true(done)
		assert.are.equal(0, #warnings)
	end)

	it("clamps repeatedly across many calls without ever warning (issue #35)", function()
		-- Simulates config.api_opts() fanning an invalid value out to every
		-- dependency on a refresh; the pre-fix code warned once per call here.
		for i = 1, 30 do
			api.get_package("dep" .. i, { max_concurrent = 0 }, function() end)
		end

		assert.are.equal(0, #warnings)
	end)

	it("accepts a valid positive integer without warning", function()
		api.get_package("a", { max_concurrent = 2 }, function() end)
		api.get_package("b", { max_concurrent = 2 }, function() end)

		assert.are.equal(2, system_calls) -- both slots available; no queuing
		assert.are.equal(0, #warnings)
	end)

	it("clamps NaN to 1 without warning (issue #70)", function()
		local done = false
		api.get_package("a", { max_concurrent = 0 / 0 }, function()
			done = true
		end)
		complete_last()

		assert.is_true(done)
		assert.are.equal(1, system_calls)
		assert.are.equal(0, #warnings)
	end)

	it("clamps positive infinity to 1, enforcing the concurrency cap (issue #70)", function()
		-- A single call can't detect this: 0 < math.huge is true either way, so it
		-- spawns regardless of whether the clamp ran. The real defect is that an
		-- unclamped math.huge is stored as the module's max_concurrent, silently
		-- disabling the cap for every call after this one — so assert the cap
		-- itself by queuing a second request behind the first.
		api.get_package("a", { max_concurrent = math.huge }, function() end)
		api.get_package("b", { max_concurrent = math.huge }, function() end)

		assert.are.equal(1, system_calls) -- capped at 1: "b" queued behind "a"
		assert.are.equal(0, #warnings)

		complete_last()
		assert.are.equal(2, system_calls) -- the queue drains once "a" finishes
	end)

	it("clamps negative infinity to 1 without warning (issue #70)", function()
		local done = false
		api.get_package("a", { max_concurrent = -math.huge }, function()
			done = true
		end)
		complete_last()

		assert.is_true(done)
		assert.are.equal(1, system_calls)
		assert.are.equal(0, #warnings)
	end)

	it("does not leave requests queued forever when max_concurrent is NaN (issue #70)", function()
		api.get_package("a", { max_concurrent = 0 / 0 }, function() end)
		api.get_package("b", { max_concurrent = 0 / 0 }, function() end)

		assert.are.equal(1, system_calls) -- "b" queued behind "a", not stalled

		complete_last()

		assert.are.equal(2, system_calls) -- the queue drains once "a" finishes
	end)
end)

-- get_package's own clamp is a silent defensive fallback (issue #49), mirroring
-- the max_concurrent precedent above: config.setup already warns once for an
-- invalid cache.ttl_seconds/error_ttl_seconds, so get_package must not also warn
-- and, more importantly, must not let a bad value reach `fresh`'s `age < ttl`
-- numeric comparison and raise.
describe("api.get_package TTL clamping (issue #49)", function()
	local old_vim
	local api
	local system_calls
	local exits
	local warnings

	before_each(function()
		old_vim = rawget(_G, "vim")
		system_calls = 0
		exits = {}
		warnings = {}
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
					return { releases = { { version = "1.0.0" } }, latest_stable_version = "1.0.0" }
				end,
			},
			notify = function(msg, _level)
				warnings[#warnings + 1] = msg
			end,
			log = { levels = { WARN = 2 } },
		}
		package.loaded["hex-outdated.hex_api"] = nil
		api = require("hex-outdated.hex_api")
	end)

	after_each(function()
		package.loaded["hex-outdated.hex_api"] = nil
		_G.vim = old_vim
	end)

	local function complete_last()
		exits[#exits]({ code = 0, stdout = "body\n200" })
	end

	it("does not crash for a non-number ttl_seconds and still delivers a result", function()
		local result
		api.get_package("a", { ttl_seconds = "3600" }, function(r)
			result = r
		end)
		complete_last()

		assert.is_truthy(result)
		assert.are.same({ "1.0.0" }, result.versions)
	end)

	it("reads second cached lookup without raising for invalid ttl_seconds (#49 repro)", function()
		-- First call spawns and completes, populating the cache.
		local first
		api.get_package("jason", { ttl_seconds = "3600" }, function(r)
			first = r
		end)
		complete_last()
		assert.is_truthy(first)

		-- Second call must read from the now-populated cache. Pre-fix, `fresh`
		-- compared `age < ttl` with ttl == "3600" (a string), raising
		-- "attempt to compare number with string".
		local second
		assert.has_no.errors(function()
			api.get_package("jason", { ttl_seconds = "3600" }, function(r)
				second = r
			end)
		end)

		assert.are.equal(1, system_calls) -- served from cache, not re-spawned
		assert.is_truthy(second)
		assert.are.same({ "1.0.0" }, second.versions)
	end)

	it("does not crash a cached-failure lookup when error_ttl_seconds is invalid", function()
		_G.vim.json.decode = function()
			return {}
		end

		api.get_package("jason", { error_ttl_seconds = -1 }, function() end)
		exits[#exits]({ code = 0, stdout = "{}\n503" }) -- completes with an error result

		-- A negative error_ttl_seconds is clamped to the default (0), so the
		-- cached failure is never "fresh" and a second lookup re-spawns rather
		-- than serving from cache; the key assertion is that `fresh`'s numeric
		-- comparison doesn't raise when handed the invalid value.
		local second
		assert.has_no.errors(function()
			api.get_package("jason", { error_ttl_seconds = -1 }, function(r)
				second = r
			end)
		end)
		exits[#exits]({ code = 0, stdout = "{}\n503" })

		assert.is_truthy(second)
		assert.is_truthy(second.error)
	end)

	it("does not emit a warning from get_package itself for an invalid TTL", function()
		api.get_package("a", { ttl_seconds = "3600", error_ttl_seconds = 0 / 0 }, function() end)
		complete_last()

		assert.are.equal(0, #warnings)
	end)
end)

-- Resetting the scheduler while curl processes from before the reset are still
-- running (issue #74). Pre-fix, `clear_cache()` wiped `pending` and zeroed
-- `in_flight` unconditionally, so a completion from before the reset found no
-- callback list (`ipairs(nil)` raised), drove the active count to -1, and wrote
-- its result into the freshly cleared cache.
describe("api.get_package reset while requests are active (issue #74)", function()
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
					return { releases = { { version = "1.0.0" } }, latest_stable_version = "1.0.0" }
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

	it("does not raise when a request completes after clear_cache", function()
		api.get_package("a", { ttl_seconds = 3600 }, function() end)
		api.clear_cache()

		assert.has_no.errors(function()
			exits[1]({ code = 0, stdout = "body\n200" })
		end)
	end)

	it("keeps the concurrency cap intact after a late completion", function()
		api.get_package("a", { max_concurrent = 1 }, function() end)
		api.clear_cache()
		-- Pre-fix this decrements the reset counter to -1 (and then raises).
		pcall(exits[1], { code = 0, stdout = "body\n200" })
		assert.are.equal(1, system_calls)

		api.get_package("b", { max_concurrent = 1 }, function() end)
		api.get_package("c", { max_concurrent = 1 }, function() end)

		-- "c" queues behind "b" only if the active count is 1, not 0 or -1.
		assert.are.equal(2, system_calls)
	end)

	it("does not repopulate the cleared cache from a late completion", function()
		api.get_package("a", { ttl_seconds = 3600 }, function() end)
		api.clear_cache()
		pcall(exits[1], { code = 0, stdout = "body\n200" })

		api.get_package("a", { ttl_seconds = 3600 }, function() end)

		assert.are.equal(2, system_calls) -- the cache really was cleared
	end)

	it("still answers the waiters a retired request was spawned for", function()
		local result
		api.get_package("a", { ttl_seconds = 3600 }, function(r)
			result = r
		end)
		api.clear_cache()
		exits[1]({ code = 0, stdout = "body\n200" })

		assert.is_truthy(result)
		assert.are.same({ "1.0.0" }, result.versions)
	end)

	it("discards queued work on reset without stalling later requests", function()
		api.get_package("a", { max_concurrent = 1 }, function() end)
		api.get_package("b", { max_concurrent = 1 }, function() end)
		assert.are.equal(1, system_calls) -- "b" is queued behind "a"

		api.clear_cache()

		api.get_package("c", { max_concurrent = 1 }, function() end)
		assert.are.equal(2, system_calls) -- the reset freed the slot, so "c" runs now

		pcall(exits[1], { code = 0, stdout = "body\n200" }) -- "a" completes late
		assert.are.equal(2, system_calls) -- the discarded "b" is not resurrected
	end)
end)

-- The scheduler's effect boundaries -- process spawn, event-loop scheduling,
-- clock, JSON decode -- are injectable (issue #74), so these tests run with no
-- `vim` global at all rather than monkeypatching one wholesale.
describe("api scheduler boundaries (issue #74)", function()
	local old_vim
	local api
	local spawns
	local fail_for
	local decoder
	local clock_time

	before_each(function()
		old_vim = rawget(_G, "vim")
		_G.vim = nil
		package.loaded["hex-outdated.hex_api"] = nil
		api = require("hex-outdated.hex_api")

		spawns = {}
		fail_for = {}
		clock_time = 1000
		decoder = function()
			return { releases = { { version = "1.0.0" } }, latest_stable_version = "1.0.0" }
		end
		api._set_boundaries({
			system = function(cmd, _opts, on_exit)
				local name = cmd[#cmd]:match("/packages/(.+)$")
				spawns[#spawns + 1] = { name = name, on_exit = on_exit }
				if fail_for[name] then
					error("ENOENT: curl not found")
				end
				return {}
			end,
			schedule = function(fn)
				fn()
			end,
			now = function()
				return clock_time
			end,
			decode_json = function(body)
				return decoder(body)
			end,
		})
	end)

	after_each(function()
		api._set_boundaries(nil)
		package.loaded["hex-outdated.hex_api"] = nil
		_G.vim = old_vim
	end)

	it("fetches through the injected boundaries with no vim global", function()
		local result
		api.get_package("a", { ttl_seconds = 3600 }, function(r)
			result = r
		end)
		assert.is_nil(rawget(_G, "vim"))

		spawns[1].on_exit({ code = 0, stdout = "body\n200" })

		assert.are.same({ "1.0.0" }, result.versions)
		assert.are.equal(1000, result.time) -- the injected clock, not os.time
	end)

	it("ignores a malformed late completion after a reset", function()
		decoder = function()
			return { releases = { 1 } } -- raises inside the response parser
		end
		api.get_package("a", { max_concurrent = 1 }, function() end)
		api.clear_cache()

		assert.has_no.errors(function()
			spawns[1].on_exit({ code = 0, stdout = '{"releases":[1]}\n200' })
		end)

		api.get_package("b", { max_concurrent = 1 }, function() end)
		api.get_package("c", { max_concurrent = 1 }, function() end)
		assert.are.equal(2, #spawns) -- "c" queued behind "b": the count never went negative
	end)

	it("keeps draining the queue when a queued spawn fails", function()
		fail_for = { b = true }
		local results = {}
		for _, name in ipairs({ "a", "b", "c" }) do
			api.get_package(name, { max_concurrent = 1 }, function(r)
				results[name] = r
			end)
		end
		assert.are.equal(1, #spawns) -- "b" and "c" wait behind "a"

		spawns[1].on_exit({ code = 0, stdout = "body\n200" })

		assert.are.equal(3, #spawns) -- "b" attempted (and failed), then "c" started
		assert.are.equal("b", spawns[2].name)
		assert.are.equal("c", spawns[3].name)
		assert.is_truthy(results.a)
		assert.is_truthy(results.b.error) -- the spawn failure was delivered, not raised
		assert.is_nil(results.c)

		spawns[3].on_exit({ code = 0, stdout = "body\n200" })
		assert.is_truthy(results.c)

		-- Every slot the three requests took has been released again.
		api.get_package("d", { max_concurrent = 1 }, function() end)
		assert.are.equal(4, #spawns)
	end)

	it("ignores a duplicate completion for the same request", function()
		api.get_package("a", { max_concurrent = 1 }, function() end)
		local on_exit = spawns[1].on_exit
		on_exit({ code = 0, stdout = "body\n200" })
		on_exit({ code = 0, stdout = "body\n200" }) -- a double-fired completion

		api.get_package("b", { max_concurrent = 1 }, function() end)
		api.get_package("c", { max_concurrent = 1 }, function() end)

		assert.are.equal(2, #spawns) -- no phantom free slot: "c" is queued behind "b"
	end)

	it("drains queued work when the concurrency limit is raised", function()
		api.get_package("a", { max_concurrent = 1 }, function() end)
		api.get_package("b", { max_concurrent = 1 }, function() end)
		assert.are.equal(1, #spawns) -- "b" is queued behind "a"

		api.get_package("c", { max_concurrent = 3 }, function() end)

		assert.are.equal(3, #spawns)
		assert.are.equal("b", spawns[2].name) -- the queue drains first, in FIFO order
		assert.are.equal("c", spawns[3].name)
	end)
end)
