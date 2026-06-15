# Lua Rules

## Applicability

Use these rules for Lua modules and applications, Neovim configuration and plugins,
LÖVE (love2d) games, OpenResty/nginx scripting, Redis scripts, and Lua embedded in
a host application.

Project-specific `AGENTS.md`, nested `AGENTS.md`, local docs, and existing
task-runner commands override this file when they are more specific.

Use `.claude/docs/raven-lua-quality.md` for detailed Lua quality guidance when the
task touches error design, version compatibility, module architecture, metatables,
performance, security, or dependency policy.

## Setup And Commands

- Prefer the repository's task runner, such as `just`, `make`, or project scripts,
  before inventing raw commands.
- Discover available commands before guessing when the repo documents them.
- Use the narrowest relevant command first, then broaden after it passes.
- Common fallback commands are:
  - `stylua .` and `stylua --check .`
  - `luacheck .`
  - `busted`
- Use `luarocks` for dependency and build tasks when the project uses it.
- Do not assume every project uses `busted`, `luacheck`, or `stylua`. Use them when
  configured or clearly appropriate. `selene` is a common single-binary alternative
  to `luacheck`.

## Pause And Ask

In addition to the guardrails in AGENTS.md, ask before changing:

- Lua version targets or compatibility (PUC-Lua 5.1/5.2/5.3/5.4 vs LuaJIT differ on
  `goto`, integer division `//`, bitwise operators, and `__index`/`__gc` semantics).
- The C API, LuaJIT FFI, embedded host contracts, or generated bindings.
- Host-application integration points (Neovim runtime, LÖVE callbacks, OpenResty
  phases) where behavior depends on the host rather than the Lua file alone.

## Lua Safety

- Declare `local` by default. Do not create accidental globals; a stray global is a
  common source of cross-module bugs and leaks.
- Never call `load`, `loadstring`, `dofile`, or `loadfile` on untrusted input.
- Avoid string-built shell commands with `os.execute` and `io.popen`; prefer
  structured APIs and validate any interpolated values.
- Prefer explicit returns and table-based modules over hidden global state.
- Treat `nil` deliberately: distinguish "absent" from "false", and check return
  values from functions that signal failure with `nil, err`.

## Error Handling

- Use `pcall`/`xpcall` to contain recoverable failures at boundaries; let truly
  unexpected conditions surface.
- Follow the `nil, err` convention for recoverable errors callers should inspect;
  reserve `error()` for programmer errors and invariant violations.
- When re-raising, preserve context (include the original message); do not swallow
  errors silently.

For full error-design guidance, see `.claude/docs/raven-lua-quality.md`.

## Architecture

- Modules should return a table and avoid mutating globals on require.
- Keep pure logic separate from I/O, host APIs, time, and randomness.
- Preserve existing module boundaries unless the task is explicitly architectural.
- Use metatables intentionally; do not add metatable magic where a plain table or
  function is clearer.

For full architecture and metatable guidance, see
`.claude/docs/raven-lua-quality.md`.

## Testing

- Inspect nearby tests and fixtures before adding new patterns.
- Prefer `busted` specs for behavior; keep pure helpers unit-tested.
- Add regression tests for bug fixes when the failure can be reproduced
  deterministically.
- Do not delete or weaken tests to make a change pass unless explicitly requested.

## Dependencies

- Prefer the standard library and existing dependencies before adding new rocks.
- Check license compatibility and maintenance status for new `luarocks` packages.
- Be explicit about the Lua version a dependency supports.

For full dependency and license hygiene, see `.claude/docs/raven-lua-quality.md`.

## Quality Gates

- Run the repository's documented final quality gate before handoff when code
  changed; `just check` runs `stylua --check`, `luacheck`, and `busted` when present.
- If no final gate exists, use the narrowest relevant checks first, then broaden to
  formatting, lint, and tests.
- Fix formatting and lint failures in touched code.
- Do not add broad inline ignores to silence the linter. Prefer fixing the code or
  the narrowest justified `.luacheckrc`/inline ignore with a reason.
