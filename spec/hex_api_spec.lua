local config = require("hex-outdated.config")
local fake_vim = require("spec.helpers.fake_vim")
local api = require("hex-outdated.hex_api")

local OK_DATA = { releases = { { version = "1.0.0" } }, latest_stable_version = "1.0.0" }

-- `vim.system` records every spawn; `fail_for[name]` makes that spawn raise.
-- `decode` is what `vim.json.decode` does with a 200 body.
local fake, restore_vim
local spawns
local fail_for
local decode

before_each(function()
	spawns = {}
	fail_for = {}
	decode = function()
		return OK_DATA
	end
	fake, restore_vim = fake_vim.install({
		system = function(cmd, _, on_exit)
			local name = cmd[#cmd]:match("/packages/(.+)$")
			spawns[#spawns + 1] = { cmd = cmd, name = name, on_exit = on_exit }
			if fail_for[name] then
				error("ENOENT: curl not found")
			end
			return {}
		end,
		json = {
			decode = function(body)
				return decode(body)
			end,
		},
	})
	api.clear_cache()
end)

after_each(function()
	restore_vim()
end)

local function opts(extra)
	local d = config.defaults
	local o = {
		base_url = d.api.base_url,
		timeout_ms = d.api.timeout_ms,
		max_concurrent = d.api.max_concurrent,
		ttl_seconds = d.cache.ttl_seconds,
		error_ttl_seconds = d.cache.error_ttl_seconds,
	}
	for k, v in pairs(extra or {}) do
		o[k] = v
	end
	return o
end

local function complete(i, obj)
	spawns[i].on_exit(obj or { code = 0, stdout = "body\n200" })
end

local function complete_last(obj)
	complete(#spawns, obj)
end

-- Fetch one package and complete its request with `obj`; returns the result.
local function fetch(obj, extra)
	local result
	api.get_package("pkg", opts(extra), function(r)
		result = r
	end)
	complete_last(obj)
	return result
end

describe("hex_api request", function()
	it("runs curl against the configured endpoint and timeout", function()
		fetch(nil, { base_url = "https://example.test/api", timeout_ms = 5200 })
		assert.are.same({
			"curl",
			"-sSL",
			"--max-time",
			"5.2",
			"-w",
			"\n%{http_code}",
			"https://example.test/api/packages/pkg",
		}, spawns[1].cmd)
	end)

	it("delivers callbacks through vim.schedule, not inside the process callback", function()
		local scheduled = {}
		fake.schedule = function(fn)
			scheduled[#scheduled + 1] = fn
		end
		local result
		api.get_package("pkg", opts(), function(r)
			result = r
		end)
		complete_last()
		assert.is_nil(result)
		scheduled[1]()
		assert.are.same({ "1.0.0" }, result.versions)
	end)
end)

describe("hex_api response handling", function()
	it("returns release versions and the latest stable version", function()
		decode = function(body)
			assert.are.equal('{"ok":true}', body)
			return {
				latest_stable_version = "1.7.14",
				latest_version = "1.8.0-rc.0",
				releases = { { version = "1.7.14" }, { other = "ignored" }, { version = "1.6.16" } },
			}
		end
		local result = fetch({ code = 0, stdout = '{"ok":true}\n200' })
		assert.are.same({ "1.7.14", "1.6.16" }, result.versions)
		assert.are.equal("1.7.14", result.latest)
		assert.is_nil(result.error)
		assert.is_nil(result.all_retired)
	end)

	it("falls back to latest_version when no stable version is present", function()
		decode = function()
			return { latest_version = "1.8.0-rc.0" }
		end
		local result = fetch()
		assert.are.same({}, result.versions)
		assert.are.equal("1.8.0-rc.0", result.latest)
	end)

	it("excludes retired releases and picks the latest active one", function()
		decode = function()
			return {
				latest_stable_version = "2.0.0",
				releases = { { version = "2.0.0" }, { version = "1.9.0" }, { version = "1.8.0" } },
				retirements = { ["2.0.0"] = { reason = "invalid" } },
			}
		end
		local result = fetch()
		assert.are.same({ "1.9.0", "1.8.0" }, result.versions)
		assert.are.equal("1.9.0", result.latest)
		assert.is_nil(result.all_retired)
	end)

	it("flags a package whose every release is retired", function()
		decode = function()
			return {
				latest_stable_version = "1.0.0",
				releases = { { version = "1.0.0" } },
				retirements = { ["1.0.0"] = { reason = "invalid" } },
			}
		end
		local result = fetch()
		assert.are.same({}, result.versions)
		assert.is_nil(result.latest)
		assert.is_true(result.all_retired)
	end)

	it("names the configured host when it cannot be resolved or reached", function()
		for _, code in ipairs({ 6, 7 }) do
			api.clear_cache()
			local result = fetch(
				{ code = code },
				{ base_url = "https://mirror.test/api", force = true }
			)
			assert.is_truthy(result.error:find("mirror.test", 1, true))
			assert.is_nil(result.error:find("hex.pm", 1, true))
		end
	end)

	it("keeps an unmapped curl exit code in the error", function()
		assert.is_truthy(fetch({ code = 35 }).error:find("35", 1, true))
	end)

	it("marks a 404 as not found and other failures as plain errors", function()
		local missing = fetch({ code = 0, stdout = "{}\n404" })
		assert.is_truthy(missing.error)
		assert.is_true(missing.not_found)

		for _, stdout in ipairs({ "{}\n503", "{}" }) do
			api.clear_cache()
			local failed = fetch({ code = 0, stdout = stdout })
			assert.is_truthy(failed.error)
			assert.is_nil(failed.not_found)
			assert.is_nil(failed.versions)
		end
	end)

	local malformed = {
		["undecodable JSON"] = function()
			error("bad json")
		end,
		["a non-table body"] = function()
			return "not a table"
		end,
		["a non-table releases field"] = function()
			return { releases = "not a table" }
		end,
		["a non-table release entry"] = function()
			return { releases = { 1 } }
		end,
		["a non-string release version"] = function()
			return { releases = { { version = 42 } } }
		end,
	}
	for label, decoder in pairs(malformed) do
		it("reports an error for " .. label, function()
			decode = decoder
			local result = fetch()
			assert.is_truthy(result.error)
			assert.is_nil(result.versions)
		end)
	end
end)

describe("hex_api in-flight coalescing", function()
	it("spawns one process for concurrent fetches of the same package", function()
		local results = {}
		local function collect(r)
			results[#results + 1] = r
		end
		api.get_package("jason", opts(), collect)
		api.get_package("jason", opts(), collect)

		assert.are.equal(1, #spawns)
		assert.are.equal(0, #results)

		complete_last()

		assert.are.equal(2, #results)
		assert.are.equal(results[1], results[2])
		assert.are.same({ "1.0.0" }, results[1].versions)
	end)

	it("serves a later fetch from cache without spawning again", function()
		api.get_package("jason", opts(), function() end)
		complete_last()

		local cached
		api.get_package("jason", opts(), function(r)
			cached = r
		end)

		assert.are.equal(1, #spawns)
		assert.are.same({ "1.0.0" }, cached.versions)
	end)

	it("spawns again for a forced fetch once the previous request finished", function()
		api.get_package("jason", opts(), function() end)
		complete_last()
		api.get_package("jason", opts({ force = true }), function() end)
		assert.are.equal(2, #spawns)
	end)

	it("makes separate requests for the same package on different endpoints", function()
		local results = {}
		for _, base_url in ipairs({ "https://one.test/api", "https://two.test/api" }) do
			api.get_package("demo", opts({ base_url = base_url }), function(r)
				results[#results + 1] = r
			end)
			complete_last()
		end

		assert.are.equal(2, #spawns)
		assert.are.equal(2, #results)
	end)

	it("keeps last-known-good versions when a refetch fails transiently", function()
		api.get_package("jason", opts(), function() end)
		complete_last()

		local res
		api.get_package("jason", opts({ force = true }), function(r)
			res = r
		end)
		complete_last({ code = 0, stdout = "{}\n503" })

		assert.is_truthy(res.error)
		assert.are.same({ "1.0.0" }, res.versions)
		assert.are.equal("1.0.0", res.latest)
	end)

	it("does not keep old versions for a definitive 404", function()
		api.get_package("jason", opts(), function() end)
		complete_last()

		local res
		api.get_package("jason", opts({ force = true }), function(r)
			res = r
		end)
		complete_last({ code = 0, stdout = "{}\n404" })

		assert.is_true(res.not_found)
		assert.is_nil(res.versions)
		assert.is_nil(res.latest)
	end)
end)

describe("hex_api concurrency cap", function()
	local capped = { max_concurrent = 1 }

	it("queues fetches beyond the cap and drains them on completion", function()
		api.get_package("a", opts(capped), function() end)
		api.get_package("b", opts(capped), function() end)
		assert.are.equal(1, #spawns)

		complete(1)
		assert.are.equal(2, #spawns)
	end)

	it("drains the queue after a malformed response ahead of it", function()
		decode = function()
			return { releases = { 1 } }
		end
		local result_a
		api.get_package("a", opts(capped), function(r)
			result_a = r
		end)
		api.get_package("b", opts(capped), function() end)

		complete(1)

		assert.are.equal(2, #spawns)
		assert.is_truthy(result_a.error)
	end)

	it("keeps draining when a queued spawn fails", function()
		fail_for = { b = true }
		local results = {}
		for _, name in ipairs({ "a", "b", "c" }) do
			api.get_package(name, opts(capped), function(r)
				results[name] = r
			end)
		end
		assert.are.equal(1, #spawns)

		complete(1)

		assert.are.equal(3, #spawns)
		assert.are.equal("b", spawns[2].name)
		assert.are.equal("c", spawns[3].name)
		assert.is_truthy(results.b.error)
		assert.is_nil(results.c)

		complete(3)
		assert.is_truthy(results.c)

		api.get_package("d", opts(capped), function() end)
		assert.are.equal(4, #spawns)
	end)

	it("releases one slot for a duplicate completion", function()
		api.get_package("a", opts(capped), function() end)
		complete(1)
		complete(1)

		api.get_package("b", opts(capped), function() end)
		api.get_package("c", opts(capped), function() end)

		assert.are.equal(2, #spawns)
	end)

	it("drains queued work when the limit is raised", function()
		api.get_package("a", opts(capped), function() end)
		api.get_package("b", opts(capped), function() end)
		assert.are.equal(1, #spawns)

		api.get_package("c", opts({ max_concurrent = 3 }), function() end)

		assert.are.equal(3, #spawns)
		assert.are.equal("b", spawns[2].name)
		assert.are.equal("c", spawns[3].name)
	end)
end)

describe("hex_api negative caching", function()
	local function fail(extra)
		api.get_package("jason", opts(extra), function() end)
		complete_last({ code = 0, stdout = "{}\n503" })
	end

	it("serves a recent failure from cache instead of re-spawning", function()
		fail({ error_ttl_seconds = 60 })
		local res
		api.get_package("jason", opts({ error_ttl_seconds = 60 }), function(r)
			res = r
		end)

		assert.are.equal(1, #spawns)
		assert.is_truthy(res.error)
	end)

	it("re-spawns when negative caching is disabled", function()
		fail({ error_ttl_seconds = 0 })
		fail({ error_ttl_seconds = 0 })

		assert.are.equal(2, #spawns)
	end)
end)

describe("hex_api spawn failure", function()
	before_each(function()
		fail_for = { jason = true }
	end)

	it("delivers an error to the callback instead of raising", function()
		local result
		api.get_package("jason", opts(), function(r)
			result = r
		end)
		assert.is_truthy(result.error)
	end)

	it("clears the in-flight entry so a forced retry spawns again", function()
		api.get_package("jason", opts(), function() end)
		local retried
		api.get_package("jason", opts({ force = true }), function(r)
			retried = r
		end)

		assert.are.equal(2, #spawns)
		assert.is_truthy(retried.error)
	end)
end)

describe("hex_api clear_cache while requests are running", function()
	it("does not raise when a request completes after the reset", function()
		api.get_package("a", opts(), function() end)
		api.clear_cache()
		assert.has_no.errors(function()
			complete(1)
		end)
	end)

	it("ignores a malformed late completion", function()
		decode = function()
			return { releases = { 1 } }
		end
		api.get_package("a", opts({ max_concurrent = 1 }), function() end)
		api.clear_cache()
		assert.has_no.errors(function()
			complete(1)
		end)
	end)

	it("keeps the concurrency cap intact after a late completion", function()
		api.get_package("a", opts({ max_concurrent = 1 }), function() end)
		api.clear_cache()
		complete(1)

		api.get_package("b", opts({ max_concurrent = 1 }), function() end)
		api.get_package("c", opts({ max_concurrent = 1 }), function() end)

		assert.are.equal(2, #spawns)
	end)

	it("does not repopulate the cleared cache from a late completion", function()
		api.get_package("a", opts(), function() end)
		api.clear_cache()
		complete(1)

		api.get_package("a", opts(), function() end)

		assert.are.equal(2, #spawns)
	end)

	it("still answers the waiters a retired request was spawned for", function()
		local result
		api.get_package("a", opts(), function(r)
			result = r
		end)
		api.clear_cache()
		complete(1)

		assert.are.same({ "1.0.0" }, result.versions)
	end)

	it("discards queued work without stalling later requests", function()
		api.get_package("a", opts({ max_concurrent = 1 }), function() end)
		api.get_package("b", opts({ max_concurrent = 1 }), function() end)
		assert.are.equal(1, #spawns)

		api.clear_cache()

		api.get_package("c", opts({ max_concurrent = 1 }), function() end)
		assert.are.equal(2, #spawns)

		complete(1)
		assert.are.equal(2, #spawns)
	end)
end)
