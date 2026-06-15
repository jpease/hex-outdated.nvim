# Semgrep Setup

Last verified: 2026-06-12

Raven defaults to the **community (free) edition** of Semgrep. No account or login is required.

## Community Edition (Default)

### Install

Use Semgrep's official CLI installation documentation: https://semgrep.dev/docs/getting-started/cli

### MCP Server

Raven's `.mcp.json` includes `semgrep mcp` as an MCP server. This enables the
`mcp__plugin_semgrep_semgrep__*` tools for on-demand scanning during a session —
no authentication needed.

### Pre-commit Hook (Recommended)

Add a `.pre-commit-config.yaml` to your project to scan commits automatically:

```yaml
repos:
  - repo: https://github.com/semgrep/pre-commit
    rev: 'v1.163.0'
    hooks:
      - id: semgrep
        entry: semgrep
        args: ['--config', 'auto', '--error', '--skip-unknown-extensions']
```

`--config auto` selects community rules appropriate for the project type without an account.
Replace `auto` with a specific ruleset URL from https://semgrep.dev/explore for a pinned rule set.

### Do Not Install the Claude Code Semgrep Plugin

The `semgrep@claude-plugins-official` plugin requires a Semgrep AppSec Platform account
(`SEMGREP_APP_TOKEN`). Its session hooks (`post-tool-cli-scan`, `inject-secure-defaults`)
fail with an authentication error when no token is present. The MCP server entry in
`.mcp.json` provides equivalent on-demand scanning capability without authentication.

## Pro Edition (AppSec Platform)

If your team has a Semgrep AppSec Platform subscription:

1. **Log in**: `semgrep login` (opens a browser window to authenticate)
2. **Enable the plugin**: set `"semgrep@claude-plugins-official": true` in `~/.claude/settings.json`
3. **Remove the `semgrep` entry from `.mcp.json`**: the plugin manages the MCP server itself;
   keeping both causes a duplicate server conflict

The plugin provides live session hooks — scanning after each file write and injecting
security guidance at session start — using your organization's configured rule policies.
