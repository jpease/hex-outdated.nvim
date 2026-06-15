-- Luacheck configuration for Neovim plugin development.
-- See https://luacheck.readthedocs.io for all options.
std = "lua54"
max_line_length = 100
unused_args = false
globals = { "vim" }
-- Skip the locally installed luarocks tree (vendored deps installed in CI).
exclude_files = { ".luarocks" }

-- The headless test runner (test/run.lua) installs these as globals; specs read them.
local harness = { "describe", "it", "skip", "eq", "is_true", "is_nil", "truthy", "contains" }
files["test/run.lua"] = { globals = harness }
files["test/*_spec.lua"] = { read_globals = harness }
