# hex-outdated.nvim — Design

Date: 2026-06-15
Status: Approved (pending spec review)

## Summary

`hex-outdated.nvim` is a Neovim plugin that inspects an Elixir project's
`mix.exs` and shows, live as you edit, whether each declared Hex dependency is
up to date. It follows the crates.nvim / cargo.nvim interaction model: inline
virtual text annotates each dependency line with the latest published version
and a status, and invalid or non-existent versions surface as diagnostics.

The reference point for "current version" is what is **declared in `mix.exs`**
(the version requirement string). hex.pm tells us which versions actually exist
and which is latest; the plugin compares the two and reports status as you type.

## Goals

- Live, in-buffer feedback while editing `mix.exs`.
- For each Hex dependency: show the latest published version and a status of
  up-to-date / upgradable / outdated / invalid.
- Validate that an entered version requirement actually resolves to a published
  release; flag non-existent versions and unknown packages as diagnostics.
- Provide interactive actions: upgrade-in-place, a versions popup, open
  hex.pm/hexdocs, and refresh/toggle commands.

## Non-Goals (v1)

- Resolving the full dependency graph or transitive deps (we read top-level
  declarations only).
- Reading `mix.lock` (current state is taken from `mix.exs`, matching the
  cargo.nvim model the user asked for).
- Shelling out to `mix` (no requirement on a compiled project or installed
  Elixir toolchain).
- An nvim-headless test harness for host-coupled modules (tracked as follow-up).

## Target

Neovim 0.10+ — relies on `vim.system`, `vim.ui.open`, `vim.diagnostic`, and
extmark virtual text.

## Architecture

Single-purpose Lua modules under `lua/hex-outdated/`, each returning a table.
Pure logic is deliberately separated from the Neovim host so the
correctness-critical parts are unit-testable with `busted`.

| Module | Responsibility | Host-coupled |
|---|---|---|
| `init.lua` | Public API: `setup()`, `:HexOutdated` command, autocmds, exposed action functions. | yes |
| `config.lua` | Default config, user merge, highlight-group registration. | minimal |
| `version.lua` | **Pure.** Parse SemVer and Elixir version requirements (`~>`, `>=`, `<=`, `>`, `<`, `==`, `!=`); classify a requirement against published versions. | no — unit tested |
| `parser.lua` | Extract deps from a buffer via Treesitter (Elixir AST query); Lua-pattern fallback. Returns per-dep `{name, requirement, range, kind}`. | yes (Treesitter); fallback is pure |
| `hex_api.lua` | Async fetch package releases from hex.pm via `curl` + `vim.system`, decode with `vim.json.decode`, in-memory TTL cache. | yes |
| `render.lua` | Place virtual text (extmarks) and `vim.diagnostic` entries from computed statuses; manage namespaces. | yes |
| `actions.lua` | Upgrade-in-place, versions popup, open hex.pm/hexdocs. | yes |
| `core.lua` | Orchestrator: debounced parse → fetch → compare → render per buffer; owns buffer state. | yes |

## Data Flow

1. An autocmd attaches to any `mix.exs` buffer (FileType `elixir` + filename
   match `mix.exs`).
2. On attach and on debounced `TextChanged` / `InsertLeave`, `parser` extracts
   the dependency list with precise buffer ranges for each requirement string.
3. For each **Hex** dependency, `core` consults the cache. On a miss or a stale
   entry it fires an async `hex_api` fetch. Fetches for distinct packages run
   concurrently. Git/path deps are skipped (rendered neutral or not at all).
4. On response, `version` classifies the declared requirement against the
   published versions; `render` draws color-coded virtual text and emits
   diagnostics for invalid/non-existent versions or unknown packages.
5. Interactive actions read the dependency under the cursor from the parsed
   buffer state.

## Status Classification (version.lua)

Given a declared requirement and the set of published versions:

- **up_to_date** — the requirement's resolved/allowed version is the latest
  stable release.
- **upgradable** — the requirement is satisfiable, but a newer stable release
  exists than what the requirement currently allows (e.g. `~> 1.6` when `1.7.x`
  is out).
- **outdated** — the requirement pins to a version that is no longer current and
  is below the latest (a more emphatic upgradable; surfaced distinctly so users
  can spot hard-pinned laggards).
- **invalid** — the requirement matches no published version, or the package is
  unknown on hex.pm.

Pre-releases are not treated as the "latest" unless the declared requirement
itself targets a pre-release. Latest = latest **stable** version by default.

## hex.pm API

- Endpoint: `GET https://hex.pm/api/packages/:name` (base URL configurable).
- Response provides the release list and the latest stable version; the plugin
  reads published version strings and the latest-stable marker.
- Transport: `curl` invoked via `vim.system` (async), JSON decoded with
  `vim.json.decode`.
- Cache: in-memory, keyed by package name, with a configurable TTL
  (default 1 hour). `:HexOutdated refresh` bypasses the cache.

## Error Handling

- `curl` / network failure → unobtrusive "fetch error" virtual text; no
  diagnostic spam; retried on the next refresh.
- 404 package → `invalid` (unknown package) diagnostic on the dependency name.
- Requirement matches no published version → `invalid` diagnostic on the
  version string.
- Treesitter Elixir parser absent → fall back to the Lua-pattern parser and
  notify once.
- No `deps` block or unparseable buffer → no-op.

## Commands & Public API

Single user command with subcommand completion:

```
:HexOutdated {refresh|toggle|upgrade|versions|open}
```

- bare `:HexOutdated` → refresh the current buffer.
- `refresh` → re-fetch, bypassing cache.
- `toggle` → enable/disable the inline display for the buffer.
- `upgrade` → rewrite the requirement under the cursor to the latest published
  version (e.g. `~> 1.6` → `~> 1.7`), via `nvim_buf_set_text` using the stored
  range.
- `versions` → floating window listing published versions (newest first) for the
  dep under the cursor; selecting one inserts it.
- `open` → open the package's hex.pm page / hexdocs in a browser (`vim.ui.open`).

Public functions (`require("hex-outdated").upgrade()`, `.versions()`, `.open()`,
`.refresh()`, `.toggle()`) let users bind their own keys. **No default keymaps**
are set unless the user opts in via `config.keymaps`.

## Configuration

`setup(opts)` deep-merges over defaults. Covered options:

- `enabled`, `auto_update` (live update on buffer changes).
- `api.base_url`, `api.timeout_ms`.
- `cache.ttl_seconds`.
- `text` — format strings / symbols for each status and for loading/error.
- `highlight` — highlight group names per status (color is not the only signal;
  symbols carry status too, per accessibility guidance).
- `popup` — border and sizing for the versions window.
- `keymaps` — opt-in buffer-local mappings for the actions.

## Testing

- `busted` unit tests for `version.lua`: requirement parsing, version
  comparison, and status classification — the correctness-critical core.
- `busted` unit tests for the **Lua-pattern fallback parser** (pure, needs no
  nvim runtime), so `just test` stays green without a headless harness.
- Treesitter and other host-coupled modules are verified manually for v1; an
  nvim-headless harness (e.g. mini.test or plenary) is a tracked follow-up.

## Project Conventions

- `.luacheckrc` switched to `std = "lua54"` with `globals = { "vim" }` for
  Neovim plugin development.
- Format with `stylua`, lint with `luacheck`, test with `busted`, all via the
  existing `justfile` (`just check`).
- Locals over globals; each module returns a table and does not mutate global
  state (per raven-lua-quality).

## Risks & Open Questions

- `mix.exs` is executable Elixir, so even Treesitter extraction can miss deps
  built dynamically (e.g. deps assembled in a helper function). v1 handles the
  conventional `defp deps do [ ... ] end` list-literal shape; unusual shapes
  degrade gracefully to "not analyzed".
- hex.pm API shape/field names should be confirmed against the live API during
  implementation.
