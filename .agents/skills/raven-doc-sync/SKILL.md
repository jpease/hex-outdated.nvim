---
name: raven-doc-sync
description: Use after implementing a feature or behavior change, before declaring done, to keep AGENTS.md, README, CHANGELOG, and related docs synchronized.
---

# Doc Sync

Use this skill after a feature, behavior change, template change, workflow change, or user-visible tooling change lands.

## Process

1. Identify the changed behavior and its audience: users, maintainers, agents, or template consumers.
2. Check project-owned documentation that describes that behavior, such as `README.md`, `AGENTS.md`, `CHANGELOG.md`, docs pages, examples, and template-specific guidance.
3. Update only documentation that is stale or missing because of the change.
4. Keep generated or managed files aligned through the repository's documented generation path instead of editing generated output directly.
5. Verify links, commands, filenames, and examples against the implementation.
6. If documentation work is durable but out of scope, create or update a follow-up issue instead of silently leaving it in chat.

## Checklist

- Installation, upgrade, or setup instructions still match the behavior.
- Command examples and file paths still work.
- Agent guidance and skills mention new workflow expectations.
- Changelog or release notes are updated when the project expects them.
- Managed-template output is regenerated when template sources changed.

## Avoid

- Do not rewrite unrelated docs for style.
- Do not document behavior that was not implemented.
- Do not update generated files by hand when the repo provides a generator.
