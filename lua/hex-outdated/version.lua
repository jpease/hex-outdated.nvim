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

return M
