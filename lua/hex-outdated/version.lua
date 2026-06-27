local M = {}

--- Parse a version string into { major, minor, patch, pre, precision, raw } or nil.
function M.parse(str)
	if type(str) ~= "string" then
		return nil
	end
	local s = str:match("^%s*(.-)%s*$")
	-- Split off build metadata (everything after the first "+"). It is ignored for
	-- comparison precedence, but Elixir still validates its syntax: dot-separated,
	-- non-empty identifiers of [A-Za-z0-9-] only. So "1.0.0+" (empty) and
	-- "1.0.0+bad_meta" (underscore) are rejected while "1.0.0+bad.meta" is accepted.
	local plus = s:find("+", 1, true)
	if plus then
		local build = s:sub(plus + 1)
		s = s:sub(1, plus - 1)
		for id in (build .. "."):gmatch("([^%.]*)%.") do
			if not id:match("^[%a%d%-]+$") then
				return nil
			end
		end
	end
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
		-- Reject leading zeros (Elixir/SemVer: "01" is not the same as "1")
		if #n > 1 and n:sub(1, 1) == "0" then
			return nil
		end
		parts[#parts + 1] = tonumber(n)
	end
	if #parts == 0 or #parts > 3 then
		return nil
	end
	-- Validate prerelease: dot-separated identifiers, each non-empty, only
	-- [A-Za-z0-9-], numeric identifiers must not have leading zeros.
	if pre then
		for id in (pre .. "."):gmatch("([^%.]*)%.") do
			if id == "" then
				return nil
			end
			if id:match("^%d+$") then
				if #id > 1 and id:sub(1, 1) == "0" then
					return nil
				end
			elseif not id:match("^[%a%d%-]+$") then
				return nil
			end
		end
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

-- Compare two pre-release strings per semver §11: split on ".", then compare
-- identifiers left to right. Numeric identifiers compare numerically and rank
-- below alphanumeric ones; alphanumeric identifiers compare lexically (ASCII).
-- When all shared identifiers are equal, the longer list wins (more fields =
-- higher precedence). This avoids the lexical trap where "rc.10" sorts before
-- "rc.2".
local function split_dots(s)
	local parts = {}
	for id in (s .. "."):gmatch("([^%.]*)%.") do
		parts[#parts + 1] = id
	end
	return parts
end

local function compare_prerelease(a, b)
	local ai, bi = split_dots(a), split_dots(b)
	for i = 1, math.max(#ai, #bi) do
		local x, y = ai[i], bi[i]
		if x == nil then
			return -1 -- a ran out of identifiers first: lower precedence
		elseif y == nil then
			return 1
		end
		local xn, yn = tonumber(x:match("^%d+$")), tonumber(y:match("^%d+$"))
		if xn and yn then
			if xn ~= yn then
				return xn < yn and -1 or 1
			end
		elseif xn then
			return -1 -- numeric identifiers rank below alphanumeric
		elseif yn then
			return 1
		elseif x ~= y then
			return x < y and -1 or 1
		end
	end
	return 0
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
	return compare_prerelease(a.pre, b.pre)
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
			-- ~> allows major.minor or major.minor.patch (precision >= 2); Elixir
			-- rejects `~> 1`. All other operators require a full major.minor.patch.
			if op == "~>" then
				if ver.precision < 2 then
					return nil
				end
			elseif ver.precision < 3 then
				return nil
			end
			return { op = op, version = ver, raw = str }
		end
	end
	-- Bare version string treated as ==; requires full precision.
	local ver = M.parse(s)
	if ver and ver.precision == 3 then
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
	-- Hex matches requirements with allow_pre: false. A prerelease candidate is
	-- therefore eligible only when the requirement operand is itself a prerelease.
	if v.pre and not req.version.pre then
		return false
	end
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
		local suffix = latest.pre and ("-" .. latest.pre) or ""
		if req.version.precision <= 2 then
			return string.format("~> %d.%d%s", latest.major, latest.minor, suffix)
		end
		return string.format("~> %d.%d.%d%s", latest.major, latest.minor, latest.patch, suffix)
	elseif req.op == "==" then
		return "== " .. M.tostring(latest)
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
	local pool = req.version.pre and parsed or ((#stables > 0) and stables or parsed)
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
		-- sat exists but sat != latest, and latest is not above req.version: the
		-- requirement excludes the latest (e.g. "< 2.0.0" when latest = 2.0.0).
		result.status = "upgradable"
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
