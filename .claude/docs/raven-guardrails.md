# Guardrails

Guardrails are checks and procedures that make agent work more reliable. Prefer deterministic guardrails over instruction-only guardrails when the behavior can be checked mechanically.

## Guardrail Levels

| Level | Examples | Use when |
|---|---|---|
| Deterministic | tests, linters, type checks, hooks, scripts, dry-run tools | A machine can verify the condition. |
| Procedural | skills with required discovery, edit, and verification steps | The agent must follow a repeatable workflow. |
| Instructional | `AGENTS.md`, scoped rules, review guidance | The behavior is contextual and cannot be fully automated. |
| Manual | user approval, code review, explicit override paths | Judgment or risk acceptance is required. |

## Current Deterministic Guardrails

- `scripts/raven.py` previews template application, classifies identical files, protects changed files, and only overwrites explicitly requested paths.
- `.claude/scripts/raven-tool-check.py` checks recommended local tools. Agent workflows may record tool availability or reminder preferences outside the repository.
- `.claude/hooks/raven-pre-bash-guard.py` blocks clearly destructive shell commands.
- `.claude/hooks/raven-pre-edit-guard.py` blocks edits to protected secret-like files and warns on high-churn paths.
- `.claude/hooks/raven-post-bash-summarize.py` nudges noisy commands toward RTK when exact raw output is not required.
- `.claude/hooks/raven-post-edit-format.py` runs cheap formatters when available.

## Required Verification Pattern

For implementation work:

1. Discover the smallest sufficient context.
2. Verify candidate context with deterministic tools before editing.
3. Make the smallest coherent change.
4. Run the narrowest relevant verification.
5. Broaden verification only after narrow checks pass.
6. Report what was verified and what remains unverified.

## Override Rules

- Destructive commands require explicit user approval.
- Template overwrites require explicit path arguments to `scripts/raven.py`.
- Missing-tool reminder suppression requires explicit user approval and must be recorded through `.claude/scripts/raven-tool-check.py --no-reminder`.
- Optional tools must not become hard requirements unless the repository documents them as required.

## Maintenance

- Add deterministic checks when a repeated agent failure can be detected mechanically.
- Add or update skills when the failure is procedural.
- Keep root instructions short; move detailed guardrail explanations into this file or a skill.
