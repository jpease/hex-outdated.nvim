# hex-outdated.nvim

Live "are my Hex deps up to date?" feedback for Elixir `mix.exs`, in the spirit
of crates.nvim. As you edit `mix.exs`, each dependency's declared version
requirement is checked against hex.pm: inline virtual text shows the latest
version and status, and non-existent versions/packages surface as diagnostics.

```
defp deps do
  [
    {:jason, "~> 1.0"},        ↑ 1.4.5            (a newer version is available)
    {:phoenix, "~> 1.8"},      ✓ 1.8.8            (up to date)
    {:ecto, "== 3.0.0"},       ↓ 3.14.0           (pinned below latest)
    {:nope, "~> 9.9"},         ✗ no such version  (also a diagnostic)
  ]
end
```

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

## Usage

Open a `mix.exs` — status appears automatically and updates as you type.

`:HexOutdated {refresh|toggle|upgrade|versions|open}` (bare `:HexOutdated` = refresh)

| Subcommand | Action |
|---|---|
| `refresh`  | Re-fetch, bypassing the cache. |
| `toggle`   | Enable/disable the inline display for the current buffer. |
| `upgrade`  | Rewrite the requirement under the cursor to the latest published version. |
| `versions` | Floating window of published versions; `<CR>` inserts the selected one, `q`/`<Esc>` closes. |
| `open`     | Open the package's page on hex.pm in a browser. |

The same actions are exposed as functions so you can bind your own keys:

```lua
local hex = require("hex-outdated")
-- hex.refresh() / hex.toggle() / hex.upgrade() / hex.versions() / hex.open()
```

## Status meanings

| Status | Meaning |
|---|---|
| `up_to_date` | The requirement already allows the latest stable release. |
| `upgradable` | A newer minor/major exists than your requirement targets. |
| `outdated`   | An exact pin (`==`) that is below the latest release. |
| `invalid`    | No published version matches the requirement (also a diagnostic). |

Git/path deps and requirements the plugin can't analyze (combined `and`/`or`
clauses) are left unannotated.

## Configuration

`setup` merges your options over the defaults:

```lua
require("hex-outdated").setup({
  enabled = true,
  auto_update = true,        -- re-analyze on buffer changes
  debounce_ms = 500,
  api = { base_url = "https://hex.pm/api", timeout_ms = 5000 },
  cache = { ttl_seconds = 3600 },
  text = {                   -- %s is the latest version
    up_to_date = "✓ %s",
    upgradable = "↑ %s",
    outdated = "↓ %s",
    invalid = "✗ no such version",
    loading = "…",
    error = "fetch error",
  },
  highlight = {              -- highlight group per status
    up_to_date = "HexOutdatedUpToDate",
    upgradable = "HexOutdatedUpgradable",
    outdated = "HexOutdatedOutdated",
    invalid = "HexOutdatedInvalid",
    loading = "HexOutdatedLoading",
    error = "HexOutdatedError",
  },
  popup = { border = "rounded", max_height = 20 },
  -- opt-in buffer-local keymaps (unset by default):
  keymaps = {}, -- e.g. { upgrade = "<leader>cu", versions = "<leader>cv", open = "<leader>co" }
})
```

Highlight groups link to `Diagnostic*` by default and respect your colorscheme
if you define them first: `HexOutdatedUpToDate`, `HexOutdatedUpgradable`,
`HexOutdatedOutdated`, `HexOutdatedInvalid`, `HexOutdatedLoading`,
`HexOutdatedError`.

## How it works

`mix.exs` is parsed with Treesitter (Lua-pattern fallback) to find top-level
dependency tuples and their requirement strings. For each Hex dependency the
plugin asynchronously queries `https://hex.pm/api/packages/:name` (cached), then
compares your requirement against the published versions to classify it. Current
state is read from `mix.exs` itself — no `mix.lock` and no shelling out to `mix`.

## Development

```
just check   # stylua --check, luacheck, busted
just test    # busted
just format  # stylua
just lint    # luacheck
```

Pure logic (`version`, the fallback parser, `util`) is unit-tested with busted;
the Neovim-coupled modules are verified against a headless Neovim.
