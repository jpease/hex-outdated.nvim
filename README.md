# hex-outdated.nvim

[![CI](https://github.com/jpease/hex-outdated.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/jpease/hex-outdated.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)

Live "are my Hex deps up to date?" feedback for Elixir `mix.exs`, in the spirit
of crates.nvim. As you edit `mix.exs`, each dependency's declared version
requirement is checked against hex.pm: inline virtual text shows the latest
version and status, and non-existent versions/packages surface as diagnostics.

![hex-outdated.nvim showing inline version status in a mix.exs buffer](assets/demo.gif)

## Features

- Live inline virtual text as you edit `mix.exs` — no `:command` needed
- Status at a glance: up to date, upgradable, outdated pin, or non-existent
- Non-existent versions/packages also surface as real `vim.diagnostic` entries
- One-key actions: upgrade the requirement under the cursor, browse published
  versions, or open the package on hex.pm
- Treesitter parsing with a dependency-free Lua-pattern fallback
- Reads `mix.exs` directly — no `mix.lock` and no shelling out to `mix`
- Async, cached hex.pm requests; configurable text, highlights, and keymaps

## Requirements

- Neovim 0.10+
- `curl` on `PATH`
- (Recommended) the `elixir` Treesitter parser (`:TSInstall elixir`); a
  Lua-pattern fallback is used if it is missing.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "jpease/hex-outdated.nvim",
  ft = "elixir",
  opts = {},
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use({
  "jpease/hex-outdated.nvim",
  config = function()
    require("hex-outdated").setup({})
  end,
})
```

With [mini.deps](https://github.com/echasnovski/mini.deps):

```lua
MiniDeps.add({ source = "jpease/hex-outdated.nvim" })
require("hex-outdated").setup({})
```

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'jpease/hex-outdated.nvim'
" after plug#end():
lua require("hex-outdated").setup({})
```

As a native package (no plugin manager):

```sh
git clone https://github.com/jpease/hex-outdated.nvim \
  ~/.config/nvim/pack/plugins/start/hex-outdated.nvim
```

```lua
-- in your init.lua
require("hex-outdated").setup({})
```

Every manager other than lazy.nvim's `opts = {}` needs an explicit
`require("hex-outdated").setup({})` call — the plugin activates entirely through
`setup()`.

## Usage

Open a `mix.exs` — status appears automatically and updates as you type.

`:HexOutdated {refresh|toggle|upgrade|versions|open}` (bare `:HexOutdated` = refresh)

| Subcommand | Action |
|---|---|
| `refresh`  | Re-fetch, bypassing the cache. |
| `toggle`   | Enable/disable the inline display for the current buffer. |
| `upgrade`  | Rewrite the requirement under the cursor to the latest published version. |
| `versions` | Floating window of active published versions; `<CR>` inserts the selected one, `q`/`<Esc>` closes. |
| `open`     | Open the package's page on hex.pm in a browser. |
| `info`     | Floating detail view (requirement / locked / latest) for the dependency under the cursor. |
| `lock`     | Toggle the per-buffer lock lens — a `locked X · latest Y` line under each dependency. |

The same actions are exposed as functions so you can bind your own keys:

```lua
local hex = require("hex-outdated")
-- hex.refresh() / hex.toggle() / hex.upgrade() / hex.versions() / hex.open()
-- hex.info()    / hex.lock()
```

Selecting a release from `versions` preserves the current requirement
operator: comparison requirements stay comparisons, bare exact versions stay
bare, and `~>` keeps its existing precision (with full prerelease versions
preserved). Retired Hex releases are excluded from status calculations and the
popup.

## Status meanings

| Status | Meaning |
|---|---|
| `up_to_date` | The requirement already allows the latest stable release. |
| `upgradable` | A newer minor/major exists than your requirement targets. |
| `outdated`   | An exact pin (`==`) that is below the latest release. |
| `invalid`    | No published version matches the requirement (also a diagnostic). |

Git/path deps and requirements the plugin can't analyze (combined `and`/`or`
clauses) are left unannotated.

## Lock context (optional)

By default hex-outdated reads only `mix.exs`. When a `mix.lock` is present it can
also surface what's actually locked — kept secondary so the inline requirement
status stays primary:

- **Detail float** — `:HexOutdated info` (or press `K` on a dependency line)
  shows requirement / locked / latest for the dependency under the cursor.
- **Lens** — `:HexOutdated lock` toggles a `locked X · latest Y` line under each
  dependency (off by default).
- **Stale-lock diagnostic** — a warning when `mix.lock` holds a version that no
  longer satisfies your requirement (e.g. after you tighten it), prompting a
  `mix deps.get`.

All of this no-ops when there is no `mix.lock`. Disable it entirely with
`lock = { enabled = false }`. The `K` binding only acts on dependency lines and
otherwise falls through to LSP hover / `keywordprg`; set `popup.hover_key = false`
to leave `K` alone.

## Configuration

`setup` merges your options over the defaults:

```lua
require("hex-outdated").setup({
  enabled = true,
  auto_update = true,        -- re-analyze on buffer changes
  debounce_ms = 500,
  api = {
    base_url = "https://hex.pm/api",
    timeout_ms = 5000,          -- invalid/non-positive values use 5000
    max_concurrent = 8,        -- cap on simultaneous curl processes
  },
  cache = {
    ttl_seconds = 3600,
    error_ttl_seconds = 60,    -- how long a failed fetch is cached before retry
  },
  lock = {
    enabled = true,            -- read mix.lock when present
    lens = false,              -- show the locked-version lens by default
    stale_diagnostic = true,   -- warn when the lock no longer satisfies the requirement
  },
  text = {                   -- %s is the latest version
    up_to_date = "✓ %s",
    upgradable = "↑ %s",
    outdated = "↓ %s",
    invalid = "✗ no such version",
    loading = "…",
    error = "fetch error",
    lock_behind = "locked %s · latest %s", -- lens line when the lock is behind
    lock_current = "locked %s · up to date",
  },
  highlight = {              -- highlight group per status
    up_to_date = "HexOutdatedUpToDate",
    upgradable = "HexOutdatedUpgradable",
    outdated = "HexOutdatedOutdated",
    invalid = "HexOutdatedInvalid",
    loading = "HexOutdatedLoading",
    error = "HexOutdatedError",
    lock = "HexOutdatedLock",
    lock_behind = "HexOutdatedLockBehind",
  },
  popup = { border = "rounded", max_height = 20, hover_key = "K" }, -- hover_key=false disables auto-K
  -- opt-in buffer-local keymaps (unset by default):
  keymaps = {}, -- e.g. { upgrade = "<leader>cu", versions = "<leader>cv", info = "<leader>ci" }
})
```

Highlight groups link to `Diagnostic*` by default and respect your colorscheme
if you define them first: `HexOutdatedUpToDate`, `HexOutdatedUpgradable`,
`HexOutdatedOutdated`, `HexOutdatedInvalid`, `HexOutdatedLoading`,
`HexOutdatedError`, `HexOutdatedLock`, `HexOutdatedLockBehind`.

## How it works

`mix.exs` is parsed with Treesitter (Lua-pattern fallback) to find dependency
tuples inside the function referenced by the project's `deps:` setting
(`deps/0` by default). Hex package aliases such as
`{:local_app, "~> 2.0", hex: :actual_package}` are honored for API lookups while
the local application name remains associated with `mix.lock`. For each Hex
dependency the plugin asynchronously queries
`https://hex.pm/api/packages/:name` (cached), excludes retired releases, then
compares your requirement against the active published versions using Hex
prerelease semantics. The requirement status comes from `mix.exs` alone;
`mix.lock` is read locally only for the optional lock context above. There is no
shelling out to `mix`.

## Development

```
just check     # stylua --check, luacheck, busted, headless-nvim suite
just test      # busted (pure logic, no Neovim)
just test-nvim # headless-Neovim integration suite
just format    # stylua
just lint      # luacheck
```

Pure logic (`version`, the fallback parser, `util`, classification) is unit-tested
with busted under `spec/`. The Neovim-coupled modules — Treesitter parsing,
extmark/diagnostic rendering, the curl queue, and buffer actions — are exercised
against a real headless Neovim under `test/`, run with
`nvim --headless -u NONE -l test/run.lua` (no busted/luarocks needed). Both
suites run in CI.

CI runs the Lua checks on Ubuntu and macOS, and the dependency-free
headless-Neovim integration suite on Ubuntu, macOS, and Windows. The Elixir
Treesitter parser is installed best-effort on Linux; parser-independent and
platform-sensitive regressions run on every integration platform.

## License

[MIT](LICENSE) © Justin Pease
