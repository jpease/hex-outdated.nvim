# LSP MCP Defaults

Last verified: 2026-06-12

Use client-native LSP or language plugins first when the agent client provides a reliable one for the project language. When no client-native option is available, Raven's recommended general-purpose fallback is `mcp-language-server` from `isaacphi/mcp-language-server`.

`mcp-language-server` is a generic MCP adapter for stdio-based language servers. It exposes semantic tools such as definition, references, hover, diagnostics, and rename through MCP. It still requires the actual language server for the project language.

## Recommended Split

| Language | Preferred LSP command for generic MCP fallback |
|---|---|
| Python | `pyright-langserver --stdio` or the repo's configured `basedpyright-langserver --stdio` |
| TypeScript | `typescript-language-server --stdio` |
| Rust | `rust-analyzer` |
| Swift | `sourcekit-lsp` |
| Go | `gopls` |
| C/C++ | `clangd` with the repo's compile database settings |
| Lua | `lua-language-server` |
| Elixir | `expert` when available; ElixirLS remains a viable fallback if the repository already uses it |

## Install

Install the bridge and selected language server from their official documentation. Raven templates already include the matching `.mcp.json` command shape; the user only needs the bridge and language-server executable on PATH.

| Component | Official install documentation | Raven `.mcp.json` command |
|---|---|---|
| `mcp-language-server` | https://github.com/isaacphi/mcp-language-server | n/a |
| Python / Pyright | https://github.com/microsoft/pyright | `pyright-langserver --stdio` |
| TypeScript language server | https://github.com/typescript-language-server/typescript-language-server | `typescript-language-server --stdio` |
| Go / gopls | https://go.dev/gopls/ | `gopls` |
| Rust Analyzer | https://rust-analyzer.github.io/manual.html | `rust-analyzer` |
| SourceKit-LSP | https://github.com/swiftlang/sourcekit-lsp | `sourcekit-lsp` |
| Elixir Expert | https://expert-lsp.github.io/docs/installation | `expert` |
| Lua Language Server | https://github.com/LuaLS/lua-language-server | `lua-language-server` |

Treat Raven's template defaults as convenience defaults, not a replacement for upstream documentation.

## MCP Configuration Pattern

Language templates include a `.mcp.json` with a reasonable default for that language. The general shape is:

```json
{
  "mcpServers": {
    "lsp": {
      "command": "mcp-language-server",
      "args": ["--workspace", ".", "--lsp", "rust-analyzer"]
    }
  }
}
```

For language servers that require stdio flags, pass server arguments after `--`:

```json
{
  "mcpServers": {
    "lsp": {
      "command": "mcp-language-server",
      "args": ["--workspace", ".", "--lsp", "pyright-langserver", "--", "--stdio"]
    }
  }
}
```

## Use Policy

- Prefer LSP for known symbols: definitions, references, diagnostics, hover/type information, and rename-impact checks.
- Do not use LSP as a replacement for exact text search, semantic discovery, or architecture graph analysis.
- If the bridge or language server is not installed, fall back to `rg`, compiler diagnostics, and targeted file reads.
- Do not assume `.mcp.json` works unchanged on every machine; PATH and language-server installation still matter.
