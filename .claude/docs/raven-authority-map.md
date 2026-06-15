# Authority Map

This repository separates canonical context from non-canonical context so agents know what to trust.

## Canonical Context

Canonical context describes the current system and current operating rules. Agents may rely on it as source-of-truth guidance.

| Artifact | Authority | Purpose |
|---|---|---|
| `AGENTS.md` | Canonical | Root operating instructions loaded by interoperable coding agents. |
| Nested `AGENTS.md` files | Canonical | Directory-scoped operating instructions. Use only when the directory owns the guidance. |
| `PROJECT_AGENTS.md` | Canonical project extension | Root-level project-specific instructions read after template-provided `AGENTS.md` when present. |
| `.agents/skills/raven-*/` | Canonical Raven procedures | Reusable Raven procedures loaded on demand. |
| Other `.agents/skills/` entries | Canonical project procedures | Project-specific reusable procedures owned by the destination repository. |
| `.claude/skills` | Compatibility | Claude Code compatibility symlink to `.agents/skills`. Do not treat it as a separate source. |
| `.claude/rules/raven-*.md` | Canonical Raven rules for Claude Code | Path or topic scoped Raven rules. Keep these operational and concise. |
| Other `.claude/rules/` entries | Canonical project rules for Claude Code | Project-specific rules owned by the destination repository. |
| `.claude/agents/raven-*.md` | Canonical Raven subagents for Claude Code | Specialized Raven subagent role definitions. |
| Other `.claude/agents/` entries | Canonical project subagents for Claude Code | Project-specific subagents owned by the destination repository. |
| `.claude/hooks/raven-*.py` and `.claude/scripts/raven-*.py` | Canonical Raven tooling | Deterministic local enforcement, setup, and bootstrap behavior. |
| Other `.claude/hooks/` and `.claude/scripts/` entries | Canonical project tooling | Project-specific tooling owned by the destination repository. |
| `.claude/docs/raven-*.md` | Canonical Raven reference | Raven reference material that is too detailed for always-loaded instructions. |
| Other `.claude/docs/` entries | Canonical project reference | Project-specific reference material owned by the destination repository. |
| Source code, tests, and inline comments | Canonical | Current implementation behavior and executable verification. |

## Non-Canonical Context

Non-canonical context can be useful, but it is not proof of current behavior.

| Artifact | Authority | Purpose |
|---|---|---|
| Plans, specs, and task notes | Non-canonical | Intent, proposed behavior, and historical reasoning. Verify against code and canonical instructions. |
| Issue tracker discussions | Non-canonical unless explicitly referenced by current instructions | Useful for intent and history, not current truth. |
| Chat transcripts and ad hoc notes | Non-canonical | Helpful background only. |

## Rules

- Do not duplicate canonical guidance in multiple places. Prefer symlinks or references.
- If two canonical sources conflict, prefer the more local source when it fully owns the scope; otherwise ask for clarification.
- If canonical and non-canonical context conflict, trust canonical context and verify against code/tests.
- Move guidance closer to where it applies. Move it up only when it is genuinely shared.
- Keep always-loaded canonical context short. Put detailed procedures in skills and detailed reference in `.claude/docs/`.
