# Lua Quality Reference

Detailed guidance for Lua work. The always-loaded rules live in
`.claude/rules/raven-lua.md`; this document is the deeper reference.

## Version Compatibility

Lua dialects are not fully compatible. Confirm the target before using
version-specific features.

| Feature | 5.1 / LuaJIT | 5.2 | 5.3 | 5.4 |
|---|---|---|---|---|
| `goto`/labels | LuaJIT only | yes | yes | yes |
| Integer subtype + `//` | no | no | yes | yes |
| Bitwise operators (`&` `\|` `~`) | no (use `bit` in LuaJIT) | no | yes | yes |
| `<close>` / to-be-closed vars | no | no | no | yes |
| `__gc` on tables | no | yes | yes | yes |

- LuaJIT tracks 5.1 semantics with extensions (FFI, `bit`). Do not assume 5.3+
  integer or bitwise behavior on LuaJIT.
- When writing libraries meant to be portable, prefer the common subset and document
  the supported versions.

## Error Design

- Two idioms coexist: returning `nil, err` for expected failures, and `error()` for
  programmer errors. Pick one per function and be consistent with the surrounding
  code.
- `error({code = ..., msg = ...})` raises a table error object that `pcall` returns
  intact — use it when callers must branch on error kind.
- Use `xpcall` with a handler (e.g. `debug.traceback`) where a stack trace aids
  diagnosis.
- Do not discard the second return value of functions that signal failure with
  `nil, err`.

## Globals And Modules

- Every identifier should be `local` unless a global is genuinely required. Consider
  `luacheck` to catch accidental globals.
- A module returns a table; requiring it must not mutate global state.
- Avoid monkey-patching standard library tables in library code; it leaks across the
  whole VM.

## Metatables And OOP

- Use metatables deliberately: `__index` for prototype lookup, `__eq`/`__lt` for
  value semantics, `__call` for callable tables.
- Keep OOP simple. A closure-based object or a single metatable per "class" is
  usually clearer than deep inheritance chains.
- Document any non-obvious metamethod behavior; hidden `__index` functions surprise
  readers.

## Performance

- Cache globals and table lookups in `local`s inside hot loops (`local insert =
  table.insert`).
- Reuse tables instead of reallocating in tight loops; avoid creating garbage per
  iteration.
- Preallocate or reuse buffers; use `table.concat` instead of repeated string
  concatenation in loops.
- On LuaJIT, prefer FFI and avoid patterns that abort trace compilation; measure
  with the project's profiler before claiming a win.

## Security

- Never `load`/`loadstring`/`dofile`/`loadfile` untrusted input. If dynamic code is
  unavoidable, sandbox the environment and restrict available globals.
- Validate values interpolated into `os.execute`/`io.popen`; prefer argument arrays
  or escaping helpers where the host provides them.
- In OpenResty/Redis contexts, treat request and key data as untrusted and follow
  the host's escaping/quoting rules.

## Testing

- `busted` is the common test runner: group with `describe`, assert with `assert.*`,
  isolate with `before_each`/`after_each`.
- Test pure logic directly; for host-coupled code (Neovim, LÖVE), isolate the pure
  parts so they are testable without the host.
- Some Neovim plugins use `plenary.nvim`'s harness instead of busted; follow the
  repo's existing choice.

## Linting And Formatting

- `luacheck` is the default linter (config `.luacheckrc`). `selene` is a fast,
  single-binary alternative that needs no Lua/luarocks toolchain — reasonable when a
  project prefers a standalone tool.
- `stylua` is the formatter (config `stylua.toml`). Keep formatting automated rather
  than hand-tuned.

## Dependencies

- `luarocks` is the standard package manager; a `rockspec` documents dependencies.
- Prefer the standard library and existing rocks before adding new ones.
- Check license and maintenance status, and confirm the rock supports the project's
  Lua version.
