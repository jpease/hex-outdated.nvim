# Raven Namespace

Raven-owned files use the `raven-*` namespace wherever the host tool allows it. This leaves destination repositories free to use ordinary names for project-specific guidance without causing update conflicts.

## Raven-Owned Paths

These paths are owned by the Raven template:

- `.agents/skills/raven-*/`
- `.claude/rules/raven-*.md`
- `.claude/docs/raven-*.md`
- `.claude/agents/raven-*.md`
- `.claude/hooks/raven-*.py`
- `.claude/scripts/raven-*.py`
- `.codex/agents/raven-*.toml`
- `.codex/hooks/raven-*.py`
- `.codex/rules/raven.rules`
- `.codex/scripts/raven-*.py`
- `.raven/config.toml` (feature flags and platform config; tracked in git)
- `.raven/session.md` (gitignored; per-project lifecycle state)
- `.raven/session.lock` (transient; never committed)
- `.raven/session-archive.md` (gitignored; completed unit history)

These integration files are also template-managed, but they cannot be fully namespaced because agents and tools expect these names:

- `AGENTS.md`
- `CLAUDE.md`
- `.mcp.json`
- `.claude/settings.json`
- `.codex/config.toml`
- `.codex/hooks.json`

## Rules

- Do not put project-specific guidance in `raven-*` files.
- Project repositories may use ordinary names for their own skills, rules, docs, agents, hooks, and scripts.
- Use nested `AGENTS.md` when the guidance applies only to a directory.
- If project guidance conflicts with template guidance, prefer the more specific project guidance for its scope.
- When reapplying the template, manually merge only files that the apply script reports as changed existing files.
- Use `.claude/docs/raven-agent-compatibility.md` to distinguish canonical Raven content from Claude and Codex adapter files.

## AGENTS.md Authoring Rules

Use these rules when writing project-specific agent instructions:

- Write operational instructions for agents, not broad human-facing documentation.
- Place guidance at the most specific directory that fully owns it; move it upward only when genuinely shared.
- Keep instructions concise. Every always-loaded line must earn its place.
- Use descriptive, search-friendly prose and stable names instead of brittle path-heavy references.
- Keep content text-only and easy to search. Avoid diagrams, binary content, and formatting that interferes with parsing.
- Prefer default-no: if most tasks in the scope do not need the information, move it to a skill, scoped rule, or reference document.
