-- curl queue / dedup / negative-cache / stale-while-error logic against real
-- vim.schedule and vim.json. `vim.system` is stubbed so no network is touched;
-- everything else (scheduling, cache aging) runs for real.
local hex_api = require("hex-outdated.hex_api")

-- Replace vim.system with a fake whose responses are scripted per package name.
-- Returns a handle exposing the spawn count and a way to restore the real one.
local function with_fake_curl(responder)
	local real = vim.system
	local spawns = {}
	vim.system = function(cmd, _opts, on_exit)
		-- cmd is the curl argv; the URL is the last element: .../packages/<name>
		local url = cmd[#cmd]
		local name = url:match("/packages/([%w_]+)$")
		spawns[#spawns + 1] = name
		-- Deliver asynchronously, like the real vim.system, via the event loop.
		vim.schedule(function()
			on_exit(responder(name))
		end)
		return { wait = function() end }
	end
	return {
		spawns = spawns,
		restore = function()
			vim.system = real
		end,
	}
end

local function ok_body(versions, latest)
	local releases = {}
	for _, v in ipairs(versions) do
		releases[#releases + 1] = { version = v }
	end
	local json = vim.json.encode({ releases = releases, latest_stable_version = latest })
	return { code = 0, stdout = json .. "\n200" }
end

-- Drain scheduled callbacks until `done` is true (or a short timeout elapses).
local function flush(done)
	vim.wait(500, done, 5)
end

describe("hex_api.get_package", function()
	it("dedupes concurrent requests for the same package into one spawn", function()
		hex_api.clear_cache()
		local fake = with_fake_curl(function(_)
			return ok_body({ "1.0.0", "1.4.5" }, "1.4.5")
		end)
		local hits = 0
		local opts = {
			base_url = "https://hex.pm/api",
			ttl_seconds = 3600,
			max_concurrent = 8,
			force = true,
		}
		hex_api.get_package("jason", opts, function()
			hits = hits + 1
		end)
		hex_api.get_package("jason", opts, function()
			hits = hits + 1
		end)
		flush(function()
			return hits == 2
		end)
		fake.restore()
		eq(2, hits, "both callbacks fired")
		eq(1, #fake.spawns, "only one curl spawned")
	end)

	it("caps concurrent spawns and drains the queue", function()
		hex_api.clear_cache()
		local fake = with_fake_curl(function(name)
			return ok_body({ "1.0.0" }, "1.0.0")
		end)
		local done = 0
		local opts = {
			base_url = "https://hex.pm/api",
			ttl_seconds = 3600,
			max_concurrent = 1,
			force = true,
		}
		for _, name in ipairs({ "a", "b", "c" }) do
			hex_api.get_package(name, opts, function()
				done = done + 1
			end)
		end
		flush(function()
			return done == 3
		end)
		fake.restore()
		eq(3, done, "all three resolved")
		eq(3, #fake.spawns, "each distinct package spawned once")
	end)

	it("serves stale versions through a transient error", function()
		hex_api.clear_cache()
		-- Prime the cache with a good response.
		local good = with_fake_curl(function(_)
			return ok_body({ "1.0.0", "2.0.0" }, "2.0.0")
		end)
		local primed
		hex_api.get_package("ecto", { ttl_seconds = 3600, force = true }, function(res)
			primed = res
		end)
		flush(function()
			return primed ~= nil
		end)
		good.restore()
		eq({ "1.0.0", "2.0.0" }, primed.versions)

		-- Now a connection failure (curl exit 7) must keep the cached versions.
		local bad = with_fake_curl(function(_)
			return { code = 7, stdout = "" }
		end)
		local errored
		hex_api.get_package(
			"ecto",
			{ ttl_seconds = 0, error_ttl_seconds = 60, force = true },
			function(res)
				errored = res
			end
		)
		flush(function()
			return errored ~= nil
		end)
		bad.restore()
		truthy(errored.error, "error is reported")
		truthy(errored.stale, "marked stale")
		eq({ "1.0.0", "2.0.0" }, errored.versions, "stale versions retained")
	end)

	it("caches a failure for error_ttl before retrying", function()
		hex_api.clear_cache()
		local fake = with_fake_curl(function(_)
			return { code = 7, stdout = "" }
		end)
		local opts = { ttl_seconds = 3600, error_ttl_seconds = 60 }
		local first
		hex_api.get_package("missing", opts, function(res)
			first = res
		end)
		flush(function()
			return first ~= nil
		end)
		-- A second (non-forced) call within error_ttl is served from cache, no spawn.
		local second
		hex_api.get_package("missing", opts, function(res)
			second = res
		end)
		flush(function()
			return second ~= nil
		end)
		fake.restore()
		eq(1, #fake.spawns, "negative cache prevented a second spawn")
	end)
end)
