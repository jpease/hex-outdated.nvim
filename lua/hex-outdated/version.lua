local M = {}

--- Parse a version string into { major, minor, patch, pre, precision, raw } or nil.
function M.parse(str)
	if type(str) ~= "string" then
		return nil
	end
	local s = str:match("^%s*(.-)%s*$")
	s = s:gsub("%+.*$", "") -- strip build metadata
	local pre
	local main, prerelease = s:match("^([%d%.]+)%-(.+)$")
	if main then
		s = main
		pre = prerelease
	end
	-- Must be digit-led, digits/dots only, with no empty dot groups ("1..") or
	-- trailing dot ("1.2."). Lua patterns can't quantify groups, so check explicitly.
	if not s:match("^%d[%d%.]*$") or s:find("%.%.") or s:sub(-1) == "." then
		return nil
	end
	local parts = {}
	for n in s:gmatch("(%d+)") do
		parts[#parts + 1] = tonumber(n)
	end
	if #parts == 0 then
		return nil
	end
	return {
		major = parts[1] or 0,
		minor = parts[2] or 0,
		patch = parts[3] or 0,
		pre = pre,
		precision = #parts,
		raw = str,
	}
end

--- Compare two parsed versions: -1, 0, or 1.
function M.compare(a, b)
	for _, k in ipairs({ "major", "minor", "patch" }) do
		if a[k] ~= b[k] then
			return a[k] < b[k] and -1 or 1
		end
	end
	if a.pre == b.pre then
		return 0
	end
	if a.pre == nil then
		return 1 -- release > pre-release
	end
	if b.pre == nil then
		return -1
	end
	if a.pre < b.pre then
		return -1
	elseif a.pre > b.pre then
		return 1
	end
	return 0
end

function M.is_stable(v)
	return v.pre == nil
end

function M.tostring(v)
	local s = string.format("%d.%d.%d", v.major, v.minor, v.patch)
	if v.pre then
		s = s .. "-" .. v.pre
	end
	return s
end

local OPS = { "~>", ">=", "<=", "==", "!=", ">", "<" }

--- Parse a single-clause Elixir requirement into { op, version, raw } or nil.
--- Combined clauses (" and "/" or ") are unsupported in v1 and return nil.
function M.parse_requirement(str)
	if type(str) ~= "string" then
		return nil
	end
	local s = str:match("^%s*(.-)%s*$")
	if s:find(" and ") or s:find(" or ") then
		return nil
	end
	for _, op in ipairs(OPS) do
		if s:sub(1, #op) == op then
			local ver = M.parse(s:sub(#op + 1))
			if not ver then
				return nil
			end
			return { op = op, version = ver, raw = str }
		end
	end
	local ver = M.parse(s)
	if ver then
		return { op = "==", version = ver, raw = str }
	end
	return nil
end

-- Upper bound (exclusive) for a ~> requirement.
local function tilde_upper(v)
	if v.precision <= 2 then
		return { major = v.major + 1, minor = 0, patch = 0 }
	end
	return { major = v.major, minor = v.minor + 1, patch = 0 }
end

--- Does parsed version `v` satisfy parsed requirement `req`?
function M.satisfies(req, v)
	local c = M.compare(v, req.version)
	local op = req.op
	if op == "==" then
		return c == 0
	elseif op == "!=" then
		return c ~= 0
	elseif op == ">=" then
		return c >= 0
	elseif op == "<=" then
		return c <= 0
	elseif op == ">" then
		return c > 0
	elseif op == "<" then
		return c < 0
	elseif op == "~>" then
		if c < 0 then
			return false
		end
		return M.compare(v, tilde_upper(req.version)) < 0
	end
	return false
end

--- Suggest a replacement requirement string bumping to `latest`, or nil.
function M.suggested_requirement(req, latest)
	if req.op == "~>" then
		if req.version.precision <= 2 then
			return string.format("~> %d.%d", latest.major, latest.minor)
		end
		return string.format("~> %d.%d.%d", latest.major, latest.minor, latest.patch)
	elseif req.op == "==" then
		return string.format("== %d.%d.%d", latest.major, latest.minor, latest.patch)
	end
	return nil
end

-- True if `latest`, truncated to the requirement's precision, equals the requirement version.
local function truncated_equal(latest, reqver)
	if reqver.precision >= 1 and latest.major ~= reqver.major then
		return false
	end
	if reqver.precision >= 2 and latest.minor ~= reqver.minor then
		return false
	end
	if reqver.precision >= 3 and latest.patch ~= reqver.patch then
		return false
	end
	return true
end

-- Memoized classification results, keyed first by the `published` table identity
-- (weak, so an entry is collected once its version list is no longer referenced)
-- then by requirement string. Hot paths re-classify the same cached version list
-- on every edit; without this each call re-parses every published version string.
local classify_memo = setmetatable({}, { __mode = "k" })

local function compute_classify(req_str, published)
	local req = M.parse_requirement(req_str)
	if not req then
		return { status = "unknown" }
	end
	local parsed, stables = {}, {}
	for _, vs in ipairs(published or {}) do
		local v = M.parse(vs)
		if v then
			parsed[#parsed + 1] = v
			if M.is_stable(v) then
				stables[#stables + 1] = v
			end
		end
	end
	local pool = (#stables > 0) and stables or parsed
	if #pool == 0 then
		return { status = "invalid", op = req.op }
	end
	local latest = pool[1]
	for _, v in ipairs(pool) do
		if M.compare(v, latest) > 0 then
			latest = v
		end
	end
	local sat
	for _, v in ipairs(pool) do
		if M.satisfies(req, v) and (not sat or M.compare(v, sat) > 0) then
			sat = v
		end
	end
	local result = { latest = M.tostring(latest), op = req.op }
	if not sat then
		result.status = "invalid"
		return result
	end
	local up_to_date
	if req.op == "~>" then
		up_to_date = truncated_equal(latest, req.version)
	elseif req.op == "==" then
		up_to_date = M.compare(req.version, latest) == 0
	else
		up_to_date = M.compare(sat, latest) == 0
	end
	if up_to_date then
		result.status = "up_to_date"
	elseif M.compare(latest, req.version) > 0 then
		result.status = (req.op == "==") and "outdated" or "upgradable"
		result.suggested = M.suggested_requirement(req, latest)
	else
		result.status = "up_to_date"
	end
	return result
end

--- Classify a requirement string against a list of published version strings.
--- Returns { status, latest?, suggested?, op? } where status is one of
--- "up_to_date" | "upgradable" | "outdated" | "invalid" | "unknown".
--- Results are memoized per (published list identity, requirement); callers must
--- treat the returned table as read-only and not mutate it.
function M.classify(req_str, published)
	if type(req_str) ~= "string" then
		return compute_classify(req_str, published or {})
	end
	published = published or {}
	local by_req = classify_memo[published]
	if by_req == nil then
		by_req = {}
		classify_memo[published] = by_req
	end
	local cached = by_req[req_str]
	if cached ~= nil then
		return cached
	end
	local result = compute_classify(req_str, published)
	by_req[req_str] = result
	return result
end

return M
