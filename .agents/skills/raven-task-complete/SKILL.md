---
name: raven-task-complete
description: Use before declaring a unit of work done to verify correctness, diff scope, and cleanliness.
---

# Task Complete

Lightweight verification ritual before declaring a unit of work finished. Closes the gap between "I think I'm done" and "I verified I'm done."

## Skip When

- The change is docs-only, config-only, or a one-line edit with no behavior change.
- The user explicitly says to skip verification and ship.

## Required Constraints

- Do not declare a task done without running at least the narrowest relevant verification.
- State what was verified and what was not — never silently skip a step.
- If a verification step fails, address it before proceeding.

## Process

1. **Run the narrowest test** covering the changed behavior — the single test file, test case, or command most directly relevant. If no test exists and one should, note the gap explicitly.
2. **Check diff scope** — run `git diff` and confirm only intended files changed. Flag unintended files, config drift, or stray hunks.
3. **Remove debug scaffolding** — scan touched files for temporary additions left during the session: `print`, `console.log`, `dbg!`, `IO.inspect`, `fmt.Println`, temporary `TODO` comments, commented-out blocks.
4. **Run lint and type-check** on touched files using the project's configured tools. If no tool is configured, note it and skip.
5. **State the verification summary** before handing off.

## Integration with raven-project-lifecycle

When using `raven-project-lifecycle`, run this skill immediately before calling `python .claude/scripts/raven-session.py --complete <unit>`. The checkpoint hook enforces completion criteria; this skill ensures you meet them before invoking it.

## Output

On success:
> Verified: [test command and result], [lint/type-check result]. Diff scoped to [N files]. No debug scaffolding found.

When gaps exist:
> Gap: [what was not verified and why]. Residual risk: [what remains unchecked].
