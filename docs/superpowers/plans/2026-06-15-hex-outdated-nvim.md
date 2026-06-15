# hex-outdated.nvim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Neovim plugin that shows, live as you edit `mix.exs`, whether each declared Hex dependency is up to date — via inline virtual text and diagnostics — with upgrade/versions/open/refresh/toggle actions.

**Architecture:** Single-purpose Lua modules under `lua/hex-outdated/`. The correctness-critical logic (`version.lua`, the Lua-pattern parser, `util.lua`) is pure and unit-tested with `busted`. Host-coupled modules (`parser` Treesitter path, `hex_api`, `render`, `actions`, `core`, `init`) wrap Neovim APIs and are verified manually for v1. Data flows: autocmd → `parser` extracts deps → `core` fetches from hex.pm async (cached) → `version` classifies → `render` draws virtual text + diagnostics.

**Tech Stack:** Lua, Neovim 0.10+ (`vim.system`, `vim.ui.open`, `vim.diagnostic`, extmarks, Treesitter), `curl`, hex.pm API, `busted`/`luacheck`/`stylua` via `just`.

**Reference spec:** `docs/superpowers/specs/2026-06-15-hex-outdated-nvim-design.md`

---

## File Structure

| File | Responsibility | Tested by |
|---|---|---|
| `.luacheckrc` | Switch to Neovim Lua config | — |
| `.busted` | busted lpath so `require("hex-outdated.*")` resolves | — |
| `lua/hex-outdated/util.lua` | Pure `deep_merge` | busted |
| `lua/hex-outdated/config.lua` | Defaults + `setup` merge | busted |
| `lua/hex-outdated/version.lua` | Pure SemVer + Elixir requirement parsing, comparison, classification | busted |
| `lua/hex-outdated/parser.lua` | Extract deps: Treesitter path + pure Lua-pattern fallback | busted (fallback), manual (TS) |
| `lua/hex-outdated/hex_api.lua` | Async hex.pm fetch + TTL cache | manual |
| `lua/hex-outdated/render.lua` | Virtual text + diagnostics, highlight groups | manual |
| `lua/hex-outdated/actions.lua` | upgrade / versions popup / open | manual |
| `lua/hex-outdated/core.lua` | Orchestrator + per-buffer state | manual |
| `lua/hex-outdated/init.lua` | `setup`, `:HexOutdated`, autocmds, public API | manual |
| `spec/*_spec.lua` | busted unit tests | — |
| `README.md` | Usage/install docs | — |

**Canonical `dep` shape** (produced by `parser`, consumed everywhere): all positions 0-indexed.
```lua
{
  name = "phoenix",        -- package name, no leading colon
  requirement = "~> 1.6",  -- version requirement string, or nil for scm deps
  kind = "hex",            -- "hex" | "scm"
  row = 2,                 -- 0-indexed buffer row of the requirement
  col_start = 15,          -- 0-indexed byte col of first char inside the quotes
  col_end = 21,            -- 0-indexed byte col just past last char inside the quotes
  -- filled in by core after classification:
  status = "upgradable",   -- "loading"|"up_to_date"|"upgradable"|"outdated"|"invalid"|"error"
  latest = "1.7.14",
  suggested = "~> 1.7",    -- replacement requirement string, or nil
  op = "~>",               -- operator from the requirement, for the versions popup
}
```

---

## Task 1: Project scaffolding (luacheck, busted, util, config)

**Files:**
- Modify: `.luacheckrc`
- Create: `.busted`
- Create: `lua/hex-outdated/util.lua`
- Create: `lua/hex-outdated/config.lua`
- Test: `spec/util_spec.lua`, `spec/config_spec.lua`

- [ ] **Step 1: Switch `.luacheckrc` to Neovim**

Replace the entire file with:
```lua
-- Luacheck configuration for Neovim plugin development.
-- See https://luacheck.readthedocs.io for all options.
std = "lua54"
max_line_length = 100
unused_args = false
globals = { "vim" }
```

- [ ] **Step 2: Create `.busted` so tests can require the modules**

Create `.busted`:
```lua
return {
  default = {
    lpath = "./lua/?.lua;./lua/?/init.lua",
    pattern = "_spec",
  },
}
```

- [ ] **Step 3: Write the failing test for `util.deep_merge`**

Create `spec/util_spec.lua`:
```lua
local util = require("hex-outdated.util")

describe("util.deep_merge", function()
  it("returns a deep clone when override is empty", function()
    local base = { a = 1, nested = { b = 2 } }
    local out = util.deep_merge(base, {})
    assert.are.same({ a = 1, nested = { b = 2 } }, out)
    out.nested.b = 99
    assert.are.equal(2, base.nested.b) -- original not mutated
  end)

  it("recursively merges nested tables", function()
    local base = { api = { url = "x", timeout = 1 }, on = true }
    local out = util.deep_merge(base, { api = { timeout = 5 }, on = false })
    assert.are.same({ api = { url = "x", timeout = 5 }, on = false }, out)
  end)

  it("override scalar replaces table and vice versa", function()
    local out = util.deep_merge({ a = { x = 1 } }, { a = 7 })
    assert.are.equal(7, out.a)
  end)
end)
```

- [ ] **Step 4: Run it and confirm failure**

Run: `busted spec/util_spec.lua`
Expected: FAIL — module `hex-outdated.util` not found.

- [ ] **Step 5: Implement `util.lua`**

Create `lua/hex-outdated/util.lua`:
```lua
local M = {}

--- Recursively merge `override` onto a deep copy of `base`. Pure; mutates nothing.
function M.deep_merge(base, override)
  local out = {}
  for k, v in pairs(base or {}) do
    if type(v) == "table" then
      out[k] = M.deep_merge(v, {})
    else
      out[k] = v
    end
  end
  for k, v in pairs(override or {}) do
    if type(v) == "table" and type(out[k]) == "table" then
      out[k] = M.deep_merge(out[k], v)
    else
      out[k] = v
    end
  end
  return out
end

return M
```

- [ ] **Step 6: Run and confirm pass**

Run: `busted spec/util_spec.lua`
Expected: PASS (3 successes).

- [ ] **Step 7: Write the failing test for `config.setup`**

Create `spec/config_spec.lua`:
```lua
local config = require("hex-outdated.config")

describe("config", function()
  before_each(function()
    config.setup({}) -- reset to defaults
  end)

  it("exposes sensible defaults", function()
    assert.are.equal("https://hex.pm/api", config.options.api.base_url)
    assert.is_true(config.options.enabled)
    assert.are.equal(3600, config.options.cache.ttl_seconds)
  end)

  it("deep-merges user options over defaults", function()
    config.setup({ api = { timeout_ms = 1234 }, enabled = false })
    assert.are.equal(1234, config.options.api.timeout_ms)
    assert.are.equal("https://hex.pm/api", config.options.api.base_url) -- preserved
    assert.is_false(config.options.enabled)
  end)
end)
```

- [ ] **Step 8: Run and confirm failure**

Run: `busted spec/config_spec.lua`
Expected: FAIL — module `hex-outdated.config` not found.

- [ ] **Step 9: Implement `config.lua`** (uses pure `util.deep_merge`, so it is busted-testable without a `vim` global)

Create `lua/hex-outdated/config.lua`:
```lua
local util = require("hex-outdated.util")

local M = {}

M.defaults = {
  enabled = true,
  auto_update = true,
  debounce_ms = 500,
  api = {
    base_url = "https://hex.pm/api",
    timeout_ms = 5000,
  },
  cache = { ttl_seconds = 3600 },
  text = {
    up_to_date = "✓ %s",
    upgradable = "↑ %s",
    outdated = "↓ %s",
    invalid = "✗ no such version",
    loading = "…",
    error = "fetch error",
  },
  highlight = {
    up_to_date = "HexOutdatedUpToDate",
    upgradable = "HexOutdatedUpgradable",
    outdated = "HexOutdatedOutdated",
    invalid = "HexOutdatedInvalid",
    loading = "HexOutdatedLoading",
    error = "HexOutdatedError",
  },
  popup = { border = "rounded", max_height = 20 },
  -- opt-in buffer-local keymaps, e.g. { upgrade = "<leader>cu", versions = "<leader>cv", open = "<leader>co" }
  keymaps = {},
}

M.options = util.deep_merge(M.defaults, {})

function M.setup(opts)
  M.options = util.deep_merge(M.defaults, opts or {})
  return M.options
end

return M
```

- [ ] **Step 10: Run and confirm pass**

Run: `busted spec/config_spec.lua`
Expected: PASS (2 successes).

- [ ] **Step 11: Lint, format, commit**

```bash
stylua lua spec && luacheck lua spec
git add .luacheckrc .busted lua/hex-outdated/util.lua lua/hex-outdated/config.lua spec/util_spec.lua spec/config_spec.lua
git commit -m "feat: scaffold hex-outdated config and util with tests"
```

---

## Task 2: version.lua — parsing, comparison, satisfaction

**Files:**
- Create: `lua/hex-outdated/version.lua`
- Test: `spec/version_spec.lua`

- [ ] **Step 1: Write the failing tests for parse/compare/satisfies**

Create `spec/version_spec.lua`:
```lua
local version = require("hex-outdated.version")

describe("version.parse", function()
  it("parses a full semver", function()
    local v = version.parse("1.7.14")
    assert.are.equal(1, v.major)
    assert.are.equal(7, v.minor)
    assert.are.equal(14, v.patch)
    assert.are.equal(3, v.precision)
    assert.is_nil(v.pre)
  end)

  it("records lower precision and defaults missing parts to 0", function()
    local v = version.parse("1.6")
    assert.are.equal(6, v.minor)
    assert.are.equal(0, v.patch)
    assert.are.equal(2, v.precision)
  end)

  it("captures pre-release and strips build metadata", function()
    local v = version.parse("2.0.0-rc.1+build5")
    assert.are.equal("rc.1", v.pre)
    assert.are.equal(2, v.major)
  end)

  it("returns nil for garbage", function()
    assert.is_nil(version.parse("not-a-version"))
  end)
end)

describe("version.compare", function()
  local p = version.parse
  it("orders by major/minor/patch", function()
    assert.are.equal(-1, version.compare(p("1.2.3"), p("1.3.0")))
    assert.are.equal(1, version.compare(p("2.0.0"), p("1.9.9")))
    assert.are.equal(0, version.compare(p("1.0.0"), p("1.0.0")))
  end)
  it("treats a pre-release as lower than its release", function()
    assert.are.equal(-1, version.compare(p("1.0.0-rc.1"), p("1.0.0")))
  end)
end)

describe("version.satisfies", function()
  local p = version.parse
  local req = version.parse_requirement
  it("handles ~> two-component upper bound", function()
    assert.is_true(version.satisfies(req("~> 1.6"), p("1.7.14")))  -- < 2.0.0
    assert.is_false(version.satisfies(req("~> 1.6"), p("2.0.0")))
    assert.is_false(version.satisfies(req("~> 1.6"), p("1.5.0")))
  end)
  it("handles ~> three-component upper bound", function()
    assert.is_true(version.satisfies(req("~> 1.6.2"), p("1.6.9")))  -- < 1.7.0
    assert.is_false(version.satisfies(req("~> 1.6.2"), p("1.7.0")))
  end)
  it("handles comparison operators and bare exact", function()
    assert.is_true(version.satisfies(req(">= 1.0.0"), p("2.5.0")))
    assert.is_true(version.satisfies(req("== 1.2.3"), p("1.2.3")))
    assert.is_false(version.satisfies(req("1.2.3"), p("1.2.4")))
  end)
end)
```

- [ ] **Step 2: Run and confirm failure**

Run: `busted spec/version_spec.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement parse/compare/is_stable/parse_requirement/satisfies/tostring**

Create `lua/hex-outdated/version.lua`:
```lua
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
  if not s:match("^%d+[%d%.]*$") then
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
```

- [ ] **Step 4: Run and confirm pass**

Run: `busted spec/version_spec.lua`
Expected: PASS.

- [ ] **Step 5: Lint, format, commit**

```bash
stylua lua spec && luacheck lua spec
git add lua/hex-outdated/version.lua spec/version_spec.lua
git commit -m "feat: version parsing, comparison, and requirement satisfaction"
```

---

## Task 3: version.lua — classification & suggested requirement

**Files:**
- Modify: `lua/hex-outdated/version.lua`
- Test: `spec/version_classify_spec.lua`

- [ ] **Step 1: Write the failing classification tests**

Create `spec/version_classify_spec.lua`:
```lua
local version = require("hex-outdated.version")

local published = { "1.4.0", "1.4.4", "1.6.0", "1.6.16", "1.7.0", "1.7.14", "1.8.0-rc.0" }

describe("version.classify", function()
  it("flags a ~> requirement behind the latest minor as upgradable", function()
    local r = version.classify("~> 1.6", published)
    assert.are.equal("upgradable", r.status)
    assert.are.equal("1.7.14", r.latest)
    assert.are.equal("~> 1.7", r.suggested)
  end)

  it("treats a ~> requirement matching the latest minor as up to date", function()
    local r = version.classify("~> 1.7", published)
    assert.are.equal("up_to_date", r.status)
  end)

  it("ignores pre-releases when choosing the latest stable", function()
    -- 1.8.0-rc.0 must NOT become the latest
    local r = version.classify("~> 1.7", published)
    assert.are.equal("1.7.14", r.latest)
  end)

  it("flags an exact pin below latest as outdated", function()
    local r = version.classify("== 1.6.0", published)
    assert.are.equal("outdated", r.status)
    assert.are.equal("== 1.7.14", r.suggested)
  end)

  it("flags a requirement that matches no published version as invalid", function()
    local r = version.classify("~> 9.9", published)
    assert.are.equal("invalid", r.status)
  end)

  it("returns unknown for unparseable/combined requirements", function()
    local r = version.classify(">= 1.0.0 and < 2.0.0", published)
    assert.are.equal("unknown", r.status)
  end)
end)
```

- [ ] **Step 2: Run and confirm failure**

Run: `busted spec/version_classify_spec.lua`
Expected: FAIL — `classify` is nil.

- [ ] **Step 3: Add `classify` and `suggested_requirement` to `version.lua`**

Insert before the final `return M` in `lua/hex-outdated/version.lua`:
```lua
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

--- Classify a requirement string against a list of published version strings.
--- Returns { status, latest?, suggested?, op? } where status is one of
--- "up_to_date" | "upgradable" | "outdated" | "invalid" | "unknown".
function M.classify(req_str, published)
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
```

- [ ] **Step 4: Run and confirm pass**

Run: `busted spec/version_classify_spec.lua`
Expected: PASS (6 successes).

- [ ] **Step 5: Lint, format, commit**

```bash
stylua lua spec && luacheck lua spec
git add lua/hex-outdated/version.lua spec/version_classify_spec.lua
git commit -m "feat: classify hex requirements and suggest upgrades"
```

---

## Task 4: parser.lua — pure Lua-pattern fallback

**Files:**
- Create: `lua/hex-outdated/parser.lua`
- Test: `spec/parser_spec.lua`

- [ ] **Step 1: Write the failing test for `parse_lines`**

Create `spec/parser_spec.lua`:
```lua
local parser = require("hex-outdated.parser")

describe("parser.parse_lines (fallback)", function()
  local lines = {
    "defp deps do",
    "  [",
    '    {:phoenix, "~> 1.6"},',
    '    {:jason, "~> 1.4", only: :test},',
    '    {:my_dep, github: "owner/repo"},',
    "  ]",
    "end",
  }

  it("extracts hex deps with name, requirement, and 0-indexed ranges", function()
    local deps = parser.parse_lines(lines)
    assert.are.equal(2, #deps)

    assert.are.equal("phoenix", deps[1].name)
    assert.are.equal("~> 1.6", deps[1].requirement)
    assert.are.equal("hex", deps[1].kind)
    assert.are.equal(2, deps[1].row) -- 0-indexed line 3
    -- the requirement content is between the quotes
    local line = lines[deps[1].row + 1]
    assert.are.equal('~> 1.6', line:sub(deps[1].col_start + 1, deps[1].col_end))
  end)

  it("keeps deps that have version + options", function()
    local deps = parser.parse_lines(lines)
    assert.are.equal("jason", deps[2].name)
    assert.are.equal("~> 1.4", deps[2].requirement)
  end)

  it("skips scm deps with no positional version string", function()
    local deps = parser.parse_lines(lines)
    for _, d in ipairs(deps) do
      assert.are_not.equal("my_dep", d.name)
    end
  end)
end)
```

- [ ] **Step 2: Run and confirm failure**

Run: `busted spec/parser_spec.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the fallback parser**

Create `lua/hex-outdated/parser.lua`:
```lua
local M = {}

-- A dep tuple where the element right after the name atom is a string literal,
-- e.g. {:phoenix, "~> 1.6"} or {:jason, "~> 1.4", only: :test}.
-- Deps whose second element is a keyword (github:/path:/git:) have no quote
-- immediately after the comma and are intentionally skipped here.
local DEP_PATTERN = '{%s*:([%w_]+)%s*,%s*"'

--- Parse dependency tuples out of a list of lines (pure; no Neovim APIs).
--- Returns a list of dep tables with 0-indexed `row`, `col_start`, `col_end`.
function M.parse_lines(lines)
  local deps = {}
  for i, line in ipairs(lines) do
    local name = line:match(DEP_PATTERN)
    if name then
      -- The first double-quote on the line opens the requirement string.
      local quote_pos = line:find('"', 1, true)
      local content = line:match('"([^"]*)"')
      if quote_pos and content then
        deps[#deps + 1] = {
          name = name,
          requirement = content,
          kind = "hex",
          row = i - 1,
          col_start = quote_pos, -- 0-indexed position just inside the opening quote
          col_end = quote_pos + #content, -- 0-indexed, exclusive end (the closing quote)
        }
      end
    end
  end
  return deps
end

return M
```

- [ ] **Step 4: Run and confirm pass**

Run: `busted spec/parser_spec.lua`
Expected: PASS (3 successes).

- [ ] **Step 5: Lint, format, commit**

```bash
stylua lua spec && luacheck lua spec
git add lua/hex-outdated/parser.lua spec/parser_spec.lua
git commit -m "feat: pure Lua-pattern fallback dependency parser"
```

---

## Task 5: parser.lua — Treesitter path + buffer dispatcher

**Files:**
- Modify: `lua/hex-outdated/parser.lua`

- [ ] **Step 1: Add the Treesitter extraction and `parse_buffer` dispatcher**

Insert before the final `return M` in `lua/hex-outdated/parser.lua`:
```lua
-- Direct-child (atom) then (string) inside a tuple. Because the string must be a
-- *direct* child of the tuple, keyword values like github: "owner/repo" (nested in
-- a keywords node) are not matched.
local TS_QUERY = "(tuple (atom) @name (string) @req)"

local warned = false
local function warn_once(msg)
  if not warned then
    warned = true
    vim.schedule(function()
      vim.notify("hex-outdated: " .. msg, vim.log.levels.WARN)
    end)
  end
end

local function parse_treesitter(bufnr)
  local ok, lang_tree = pcall(vim.treesitter.get_parser, bufnr, "elixir")
  if not ok or not lang_tree then
    return nil
  end
  local tree = lang_tree:parse()[1]
  if not tree then
    return nil
  end
  local query_ok, query = pcall(vim.treesitter.query.parse, "elixir", TS_QUERY)
  if not query_ok then
    return nil
  end
  local deps = {}
  local current
  -- iter_captures(node, source, start_row, end_row): yields capture id + node in
  -- document order, so each @name precedes its sibling @req within a tuple.
  for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
    local capture = query.captures[id]
    local text = vim.treesitter.get_node_text(node, bufnr)
    if capture == "name" then
      current = { name = (text:gsub("^:", "")), kind = "hex" }
    elseif capture == "req" and current then
      local srow, scol, _, ecol = node:range()
      current.requirement = text:gsub('^"', ""):gsub('"$', "")
      current.row = srow
      current.col_start = scol + 1 -- inside opening quote
      current.col_end = ecol - 1 -- before closing quote
      deps[#deps + 1] = current
      current = nil
    end
  end
  return deps
end

--- Parse deps from a buffer. Uses Treesitter when the elixir parser is available,
--- otherwise falls back to the pure line parser.
function M.parse_buffer(bufnr)
  local deps = parse_treesitter(bufnr)
  if deps == nil then
    warn_once("Treesitter elixir parser unavailable; using pattern fallback")
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return M.parse_lines(lines)
  end
  return deps
end
```

- [ ] **Step 2: Manually verify Treesitter parsing in Neovim**

Run (requires the elixir Treesitter parser installed):
```bash
nvim --headless -c "set rtp+=." -c "edit /tmp/mix.exs" <<'EOF'
EOF
```
Then with a real `mix.exs` open, evaluate:
```vim
:lua print(vim.inspect(require("hex-outdated.parser").parse_buffer(0)))
```
Expected: a list of `{ name, requirement, kind = "hex", row, col_start, col_end }` for each `{:name, "req"}` dep, with `row` matching the dep's 0-indexed line and `requirement` containing the version string (no quotes). `github:`/`path:` deps are absent.

- [ ] **Step 3: Lint, format, commit**

```bash
stylua lua && luacheck lua
git add lua/hex-outdated/parser.lua
git commit -m "feat: Treesitter dependency extraction with pattern fallback"
```

---

## Task 6: hex_api.lua — async fetch + TTL cache

**Files:**
- Create: `lua/hex-outdated/hex_api.lua`

- [ ] **Step 1: Implement the async hex.pm client**

Create `lua/hex-outdated/hex_api.lua`:
```lua
local M = {}

-- name -> { versions = {...}, latest = "x.y.z", time = epoch } | { error = msg, not_found = bool }
local cache = {}

function M.clear_cache()
  cache = {}
end

local function fresh(entry, ttl)
  return entry and not entry.error and (os.time() - (entry.time or 0)) < ttl
end

--- Fetch package release info from hex.pm.
--- opts: { base_url, timeout_ms, ttl_seconds, force }
--- callback receives { versions = {strings}, latest = string } or { error = msg, not_found? }.
function M.get_package(name, opts, callback)
  opts = opts or {}
  local ttl = opts.ttl_seconds or 3600
  if not opts.force and fresh(cache[name], ttl) then
    callback(cache[name])
    return
  end
  local base = opts.base_url or "https://hex.pm/api"
  local timeout_s = math.max(1, math.floor((opts.timeout_ms or 5000) / 1000))
  local url = string.format("%s/packages/%s", base, name)
  local cmd = {
    "curl", "-sSL", "--max-time", tostring(timeout_s), "-w", "\n%{http_code}", url,
  }

  vim.system(cmd, { text = true }, function(obj)
    local result
    if obj.code ~= 0 then
      result = { error = "request failed" }
    else
      local body, status = (obj.stdout or ""):match("^(.*)\n(%d+)%s*$")
      status = tonumber(status)
      if status == 404 then
        result = { error = "package not found", not_found = true }
      elseif status ~= 200 then
        result = { error = "http " .. tostring(status) }
      else
        local ok, data = pcall(vim.json.decode, body)
        if not ok or type(data) ~= "table" then
          result = { error = "invalid response" }
        else
          local versions = {}
          for _, rel in ipairs(data.releases or {}) do
            if rel.version then
              versions[#versions + 1] = rel.version
            end
          end
          result = {
            versions = versions,
            latest = data.latest_stable_version or data.latest_version,
            time = os.time(),
          }
        end
      end
    end
    cache[name] = result
    vim.schedule(function()
      callback(result)
    end)
  end)
end

return M
```

- [ ] **Step 2: Manually verify against the live API**

```vim
:lua require("hex-outdated.hex_api").get_package("jason", {}, function(r) print(vim.inspect(r)) end)
```
Expected: prints `{ versions = { ... many ... }, latest = "1.4.x", time = ... }`. Then verify 404 handling:
```vim
:lua require("hex-outdated.hex_api").get_package("this_pkg_does_not_exist_xyz", {}, function(r) print(vim.inspect(r)) end)
```
Expected: `{ error = "package not found", not_found = true }`. Confirm the `releases[].version` and `latest_stable_version` field names match the live payload; adjust if hex.pm differs.

- [ ] **Step 3: Lint, format, commit**

```bash
stylua lua && luacheck lua
git add lua/hex-outdated/hex_api.lua
git commit -m "feat: async hex.pm client with TTL cache"
```

---

## Task 7: render.lua — virtual text + diagnostics

**Files:**
- Create: `lua/hex-outdated/render.lua`

- [ ] **Step 1: Implement rendering and highlight setup**

Create `lua/hex-outdated/render.lua`:
```lua
local config = require("hex-outdated.config")

local M = {}

local ns = vim.api.nvim_create_namespace("hex_outdated_virt")
local diag_ns = vim.api.nvim_create_namespace("hex_outdated_diag")

function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.diagnostic.reset(diag_ns, bufnr)
end

local function label_for(item, opts)
  if item.status == "invalid" then
    return opts.text.invalid
  elseif item.status == "loading" then
    return opts.text.loading
  elseif item.status == "error" then
    return opts.text.error
  end
  local tpl = opts.text[item.status] or "%s"
  return string.format(tpl, item.latest or "")
end

--- Draw virtual text + diagnostics for a buffer.
--- items: list of { row, col_start, col_end, name, status, latest, suggested }
function M.render(bufnr, items)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  M.clear(bufnr)
  local opts = config.options
  local diagnostics = {}
  for _, item in ipairs(items) do
    local hl = opts.highlight[item.status] or "Comment"
    vim.api.nvim_buf_set_extmark(bufnr, ns, item.row, 0, {
      virt_text = { { "  " .. label_for(item, opts), hl } },
      virt_text_pos = "eol",
    })
    if item.status == "invalid" then
      diagnostics[#diagnostics + 1] = {
        lnum = item.row,
        col = item.col_start or 0,
        end_col = item.col_end or (item.col_start or 0),
        severity = vim.diagnostic.severity.ERROR,
        message = string.format(
          "No published version of '%s' matches this requirement (latest: %s)",
          item.name or "?",
          item.latest or "unknown"
        ),
        source = "hex-outdated",
      }
    end
  end
  vim.diagnostic.set(diag_ns, bufnr, diagnostics, {})
end

--- Register default highlight links (only if not already defined by the user/theme).
function M.setup_highlights()
  local links = {
    HexOutdatedUpToDate = "DiagnosticOk",
    HexOutdatedUpgradable = "DiagnosticWarn",
    HexOutdatedOutdated = "DiagnosticWarn",
    HexOutdatedInvalid = "DiagnosticError",
    HexOutdatedLoading = "Comment",
    HexOutdatedError = "Comment",
  }
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

return M
```

- [ ] **Step 2: Manually verify rendering**

```vim
:lua require("hex-outdated.render").setup_highlights()
:lua require("hex-outdated.render").render(0, { { row = 2, col_start = 15, col_end = 21, name = "phoenix", status = "upgradable", latest = "1.7.14" }, { row = 3, col_start = 14, col_end = 20, name = "ecto", status = "invalid", latest = "3.11.0" } })
```
Expected: line 3 shows `↑ 1.7.14` at end of line; line 4 shows `✗ no such version` and an error diagnostic (`:lua print(vim.inspect(vim.diagnostic.get(0)))` lists one entry).

- [ ] **Step 3: Lint, format, commit**

```bash
stylua lua && luacheck lua
git add lua/hex-outdated/render.lua
git commit -m "feat: virtual text and diagnostics rendering"
```

---

## Task 8: actions.lua — upgrade, versions popup, open

**Files:**
- Create: `lua/hex-outdated/actions.lua`

- [ ] **Step 1: Implement actions**

Create `lua/hex-outdated/actions.lua`:
```lua
local config = require("hex-outdated.config")

local M = {}

--- Return the dep whose row matches the cursor, or nil.
function M.dep_at_cursor(deps)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, dep in ipairs(deps or {}) do
    if dep.row == row then
      return dep
    end
  end
  return nil
end

--- Replace the requirement under the cursor with its suggested upgrade.
function M.upgrade(bufnr, dep)
  if not dep or not dep.suggested then
    vim.notify("hex-outdated: nothing to upgrade on this line", vim.log.levels.INFO)
    return
  end
  vim.api.nvim_buf_set_text(bufnr, dep.row, dep.col_start, dep.row, dep.col_end, { dep.suggested })
end

--- Open the package's hex.pm page in a browser.
function M.open(dep)
  if not dep then
    vim.notify("hex-outdated: no dependency on this line", vim.log.levels.INFO)
    return
  end
  vim.ui.open("https://hex.pm/packages/" .. dep.name)
end

-- Build a requirement string for an inserted version, preserving the operator style.
local function requirement_for(op, version_str)
  if op == "~>" then
    local major, minor = version_str:match("^(%d+)%.(%d+)")
    if major and minor then
      return string.format("~> %s.%s", major, minor)
    end
  end
  return string.format("== %s", version_str)
end

--- Open a floating window listing published versions for the dep; selecting one
--- (Enter) inserts it into the requirement; `q` closes.
--- `fetch(name, cb)` is injected by the caller (wraps hex_api.get_package).
function M.versions(bufnr, dep, fetch)
  if not dep then
    vim.notify("hex-outdated: no dependency on this line", vim.log.levels.INFO)
    return
  end
  fetch(dep.name, function(res)
    if res.error or not res.versions or #res.versions == 0 then
      vim.notify("hex-outdated: " .. (res.error or "no versions found"), vim.log.levels.WARN)
      return
    end
    vim.schedule(function()
      local lines = res.versions -- newest-first per hex.pm ordering
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      local width = 20
      for _, l in ipairs(lines) do
        width = math.max(width, #l + 2)
      end
      local height = math.min(#lines, config.options.popup.max_height)
      local win = vim.api.nvim_open_win(buf, true, {
        relative = "cursor",
        row = 1,
        col = 0,
        width = width,
        height = height,
        border = config.options.popup.border,
        style = "minimal",
      })
      local function close()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end
      vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
      vim.keymap.set("n", "<esc>", close, { buffer = buf, nowait = true })
      vim.keymap.set("n", "<cr>", function()
        local selected = vim.api.nvim_get_current_line()
        close()
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_set_text(
            bufnr,
            dep.row,
            dep.col_start,
            dep.row,
            dep.col_end,
            { requirement_for(dep.op, selected) }
          )
        end
      end, { buffer = buf, nowait = true })
    end)
  end)
end

return M
```

- [ ] **Step 2: Manually verify** (after Task 10 wiring, re-check). For now, lint and confirm it loads:

```vim
:lua require("hex-outdated.actions")
```
Expected: no error.

- [ ] **Step 3: Lint, format, commit**

```bash
stylua lua && luacheck lua
git add lua/hex-outdated/actions.lua
git commit -m "feat: upgrade, versions popup, and open actions"
```

---

## Task 9: core.lua — orchestrator + per-buffer state

**Files:**
- Create: `lua/hex-outdated/core.lua`

- [ ] **Step 1: Implement the orchestrator**

Create `lua/hex-outdated/core.lua`:
```lua
local parser = require("hex-outdated.parser")
local hex_api = require("hex-outdated.hex_api")
local version = require("hex-outdated.version")
local render = require("hex-outdated.render")
local config = require("hex-outdated.config")

local M = {}

-- bufnr -> { deps = {...}, enabled = bool }
M.state = {}

function M.api_opts(extra)
  local o = config.options
  local opts = {
    base_url = o.api.base_url,
    timeout_ms = o.api.timeout_ms,
    ttl_seconds = o.cache.ttl_seconds,
  }
  for k, v in pairs(extra or {}) do
    opts[k] = v
  end
  return opts
end

-- Rebuild render items from current dep state (hex deps only).
function M.refresh_render(bufnr)
  local st = M.state[bufnr]
  if not st or not st.enabled then
    return
  end
  local items = {}
  for _, dep in ipairs(st.deps or {}) do
    if dep.kind == "hex" then
      items[#items + 1] = {
        row = dep.row,
        col_start = dep.col_start,
        col_end = dep.col_end,
        name = dep.name,
        status = dep.status or "loading",
        latest = dep.latest,
        suggested = dep.suggested,
      }
    end
  end
  render.render(bufnr, items)
end

--- Parse the buffer, render loading state, then fetch + classify each hex dep.
function M.analyze(bufnr, opts)
  opts = opts or {}
  local st = M.state[bufnr] or { enabled = config.options.enabled }
  M.state[bufnr] = st
  st.deps = parser.parse_buffer(bufnr)
  if not st.enabled then
    return
  end
  for _, dep in ipairs(st.deps) do
    dep.status = (dep.kind == "hex" and dep.requirement) and "loading" or nil
  end
  M.refresh_render(bufnr)

  for _, dep in ipairs(st.deps) do
    if dep.kind == "hex" and dep.requirement then
      hex_api.get_package(dep.name, M.api_opts({ force = opts.force }), function(res)
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        local cur = M.state[bufnr]
        if not cur or not cur.enabled then
          return
        end
        if res.error then
          dep.status = res.not_found and "invalid" or "error"
          dep.latest = res.latest
        else
          local c = version.classify(dep.requirement, res.versions or {})
          dep.status = c.status == "unknown" and "loading" or c.status
          dep.latest = c.latest
          dep.suggested = c.suggested
          dep.op = c.op
        end
        M.refresh_render(bufnr)
      end)
    end
  end
end

return M
```

- [ ] **Step 2: Manually verify after Task 10 (full pipeline). For now confirm it loads:**

```vim
:lua require("hex-outdated.core")
```
Expected: no error.

- [ ] **Step 3: Lint, format, commit**

```bash
stylua lua && luacheck lua
git add lua/hex-outdated/core.lua
git commit -m "feat: orchestrate parse, fetch, classify, and render"
```

---

## Task 10: init.lua — setup, command, autocmds, public API

**Files:**
- Create: `lua/hex-outdated/init.lua`

- [ ] **Step 1: Implement the public entry point**

Create `lua/hex-outdated/init.lua`:
```lua
local config = require("hex-outdated.config")
local core = require("hex-outdated.core")
local actions = require("hex-outdated.actions")
local render = require("hex-outdated.render")
local hex_api = require("hex-outdated.hex_api")

local M = {}

local SUBCOMMANDS = { "refresh", "toggle", "upgrade", "versions", "open" }

local function is_mixexs(bufnr)
  return vim.api.nvim_buf_get_name(bufnr):match("mix%.exs$") ~= nil
end

local function current_deps()
  local bufnr = vim.api.nvim_get_current_buf()
  local st = core.state[bufnr]
  return bufnr, st and st.deps or {}
end

function M.refresh()
  core.analyze(vim.api.nvim_get_current_buf(), { force = true })
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  local st = core.state[bufnr] or { enabled = config.options.enabled }
  st.enabled = not st.enabled
  core.state[bufnr] = st
  if st.enabled then
    core.analyze(bufnr)
  else
    render.clear(bufnr)
  end
end

function M.upgrade()
  local bufnr, deps = current_deps()
  actions.upgrade(bufnr, actions.dep_at_cursor(deps))
end

function M.open()
  local _, deps = current_deps()
  actions.open(actions.dep_at_cursor(deps))
end

function M.versions()
  local bufnr, deps = current_deps()
  actions.versions(bufnr, actions.dep_at_cursor(deps), function(name, cb)
    hex_api.get_package(name, core.api_opts(), cb)
  end)
end

local function attach(bufnr)
  if not is_mixexs(bufnr) then
    return
  end
  core.state[bufnr] = core.state[bufnr] or { enabled = config.options.enabled }
  for action, lhs in pairs(config.options.keymaps or {}) do
    if lhs and type(M[action]) == "function" then
      vim.keymap.set("n", lhs, M[action], { buffer = bufnr, desc = "hex-outdated: " .. action })
    end
  end
  if config.options.enabled then
    core.analyze(bufnr)
  end
  if config.options.auto_update then
    local timer
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
      buffer = bufnr,
      callback = function()
        if timer then
          timer:stop()
        end
        timer = vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(bufnr) then
            core.analyze(bufnr)
          end
        end, config.options.debounce_ms)
      end,
    })
  end
end

function M.setup(opts)
  config.setup(opts)
  render.setup_highlights()
  local group = vim.api.nvim_create_augroup("HexOutdated", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    pattern = "mix.exs",
    callback = function(args)
      attach(args.buf)
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and is_mixexs(b) then
      attach(b)
    end
  end
  vim.api.nvim_create_user_command("HexOutdated", function(a)
    local sub = (a.args ~= "" and a.args) or "refresh"
    if type(M[sub]) == "function" then
      M[sub]()
    else
      vim.notify("hex-outdated: unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
    end
  end, {
    nargs = "?",
    complete = function(arglead)
      return vim.tbl_filter(function(c)
        return c:find(arglead, 1, true) == 1
      end, SUBCOMMANDS)
    end,
  })
end

return M
```

- [ ] **Step 2: Manually verify the full pipeline end-to-end**

Create `/tmp/proj/mix.exs`:
```elixir
defmodule Demo.MixProject do
  use Mix.Project
  def project, do: [app: :demo, version: "0.1.0", deps: deps()]
  defp deps do
    [
      {:phoenix, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:ecto, "~> 99.9"},
      {:my_dep, github: "owner/repo"}
    ]
  end
end
```
Run:
```bash
nvim -u NORC --cmd "set rtp+=$PWD" /tmp/proj/mix.exs \
  -c "lua require('hex-outdated').setup({})"
```
Expected (after the debounce/fetch): `phoenix` and `jason` show a status + latest version inline; `ecto` (`~> 99.9`) shows `✗ no such version` with an error diagnostic; `my_dep` shows nothing. Test commands: `:HexOutdated refresh`, cursor on the phoenix line then `:HexOutdated upgrade` (rewrites `~> 1.6` → `~> 1.7`-style), `:HexOutdated versions` (popup), `:HexOutdated open` (browser), `:HexOutdated toggle` (clears/redraws).

- [ ] **Step 3: Lint, format, commit**

```bash
stylua lua && luacheck lua
git add lua/hex-outdated/init.lua
git commit -m "feat: setup, :HexOutdated command, autocmds, and public API"
```

---

## Task 11: README + final verification

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

Create `README.md`:
```markdown
# hex-outdated.nvim

Live "are my Hex deps up to date?" feedback for Elixir `mix.exs`, in the spirit
of crates.nvim. As you edit `mix.exs`, each dependency's declared version
requirement is checked against hex.pm: inline virtual text shows the latest
version and status, and non-existent versions/packages surface as diagnostics.

## Requirements

- Neovim 0.10+
- `curl` on `PATH`
- (Recommended) the `elixir` Treesitter parser (`:TSInstall elixir`); a
  Lua-pattern fallback is used if it is missing.

## Install (lazy.nvim)

```lua
{
  "jpease/hex-outdated.nvim",
  ft = "elixir",
  opts = {},
}
```

## Usage

Open a `mix.exs`. Status appears automatically. Command:

`:HexOutdated {refresh|toggle|upgrade|versions|open}` (bare = refresh).

- `upgrade` — rewrite the requirement under the cursor to the latest version.
- `versions` — popup of published versions; `<CR>` inserts the selected one.
- `open` — open the package on hex.pm.
- `toggle` — enable/disable inline display for the buffer.
- `refresh` — re-fetch, bypassing the cache.

## Configuration

Defaults (pass overrides to `setup`/`opts`):

```lua
require("hex-outdated").setup({
  enabled = true,
  auto_update = true,
  debounce_ms = 500,
  api = { base_url = "https://hex.pm/api", timeout_ms = 5000 },
  cache = { ttl_seconds = 3600 },
  popup = { border = "rounded", max_height = 20 },
  -- opt-in buffer-local keymaps:
  keymaps = {}, -- e.g. { upgrade = "<leader>cu", versions = "<leader>cv", open = "<leader>co" }
})
```

Highlight groups (linked to `Diagnostic*` by default): `HexOutdatedUpToDate`,
`HexOutdatedUpgradable`, `HexOutdatedOutdated`, `HexOutdatedInvalid`,
`HexOutdatedLoading`, `HexOutdatedError`.

## Development

`just check` runs `stylua --check`, `luacheck`, and `busted`.
```

- [ ] **Step 2: Run the full verification suite**

Run: `just check`
Expected: stylua clean, luacheck clean, all busted specs pass.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add README"
```

---

## Self-Review Notes

- **Spec coverage:** data source (hex.pm, Task 6) ✓; live virtual text + diagnostics (Tasks 7, 9, 10) ✓; status classification incl. invalid/non-existent (Task 3) ✓; Treesitter + fallback parsing (Tasks 4–5) ✓; upgrade/versions/open/refresh/toggle (Tasks 8, 10) ✓; config surface (Task 1) ✓; `.luacheckrc` switch (Task 1) ✓; busted tests for pure modules (Tasks 1–4) ✓; Neovim 0.10+ APIs (`vim.system`, `vim.ui.open`, `vim.diagnostic`) ✓.
- **Type consistency:** the canonical `dep` shape (`row`/`col_start`/`col_end`/`name`/`requirement`/`kind`/`status`/`latest`/`suggested`/`op`) is produced by `parser`, enriched by `core`, and consumed by `render`/`actions` consistently. `classify` returns `{status, latest, suggested, op}`; `core` maps `status == "unknown"` to a neutral `loading` render.
- **Known v1 limitations (per spec):** combined requirements (`and`/`or`) render neutrally; over-matching of non-dep `{:atom, "string"}` tuples by the Treesitter query is possible but rare in `mix.exs`; hex.pm field names confirmed during Task 6.
```
