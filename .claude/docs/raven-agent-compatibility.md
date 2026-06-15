# Raven Agent Compatibility

Raven keeps one source of truth and adds thin compatibility layers for individual agent clients.

## Canonical Files

These files are agent-neutral and should remain the source of truth:

- `AGENTS.md`: root instructions loaded by compatible agents.
- `.agents/skills/raven-*/`: reusable skills loaded on demand.
- `.claude/docs/raven-*.md`: shared Raven reference documents. The path is Claude-shaped today, but the content is intended to be reusable across agents.

Do not duplicate canonical guidance into agent-specific files unless the target client requires a different schema.

## Claude Code Adapter

Claude-specific files:

- `CLAUDE.md`: compatibility symlink or pointer to `AGENTS.md`.
- `.claude/skills`: compatibility symlink to `.agents/skills`.
- `.claude/agents/raven-*.md`: Claude Code subagents.
- `.claude/hooks/raven-*.py`: Claude Code hook scripts.
- `.claude/rules/raven-*.md`: Claude Code scoped rules.
- `.claude/settings.json`: Claude Code hook wiring.

## Codex Adapter

Codex-specific files:

- `.codex/config.toml`: Codex project config, including subagent concurrency defaults and MCP servers.
- `.codex/agents/raven-*.toml`: Codex custom agents.
- `.codex/hooks.json`: Codex hook wiring.
- `.codex/hooks/raven-*.py`: Codex hook scripts.
- `.codex/rules/raven.rules`: Codex command approval rules.
- `.codex/scripts/raven-*.py`: Codex helper scripts.

Codex reads `.agents/skills` directly, so Raven does not install a `.codex/skills` copy.

## Maintenance Rules

- Keep `AGENTS.md` and `.agents/skills` canonical.
- Keep adapter files as schema translations, not independent policy documents.
- When a Claude and Codex adapter describe the same role, update both in the same Raven change.
- Prefer project config switches over deleting Raven files by hand.
- If a destination project has stronger local guidance, preserve it and merge Raven guidance into the managed block or local agent adapter as appropriate.
