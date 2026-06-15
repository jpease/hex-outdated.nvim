-- Luacheck configuration for Neovim plugin development.
-- See https://luacheck.readthedocs.io for all options.
std = "lua54"
max_line_length = 100
unused_args = false
globals = { "vim" }
-- Skip the locally installed luarocks tree (vendored deps installed in CI).
exclude_files = { ".luarocks" }
