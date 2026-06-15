---
name: raven-project-lifecycle
description: Use for multi-session or multi-unit tasks where you need brownfield detection, work scoping, and session state. Skip for single-unit tasks, one-off fixes, or doc-only changes.
---

# Project Lifecycle

Lightweight session orchestration for tasks that span multiple units or sessions. Scopes work, tracks progress, and delegates execution to appropriate Raven skills. Does not replace AI-DLC or full lifecycle frameworks — use those when you need phased requirements, NFR design, or structured approval workflows.

For projects with an external issue tracker, check `[issue_tracker].platform` in `.raven/config.toml`:
- `platform = "github"`: use `raven-github-issues` for issue-driven execution alongside this skill
- `platform = "gitlab"`: use `raven-gitlab-issues` alongside this skill
- `platform = "none"`: this skill is the sole task tracker

## Skip When

- The task is a single unit completable in one session with no context-loss risk
- The user has already scoped and decomposed the work explicitly
- The task is a one-off fix, doc change, or isolated refactor

## Required Constraints

- Never implement code directly; always delegate to the appropriate Raven execution skill
- Always call `python .claude/scripts/raven-session.py --status` before beginning Phase 3 to confirm the current unit
- Always call `python .claude/scripts/raven-session.py --complete <unit>` at the end of each unit — the checkpoint hook will validate before allowing it
- Never skip the checkpoint call to move faster

## Phase 1 — Workspace Detection

1. Check for existing `.raven/session.md`:
   - If found: run `python .claude/scripts/raven-session.py --status` and jump to Phase 3
2. Scan for brownfield signals: source files, dependency manifests, git history, existing configs
3. Classify: **greenfield** (no existing code) or **brownfield** (existing codebase)
4. If brownfield: invoke `raven-codebase-discovery` to build architecture context before scoping

## Phase 2 — Scoping

1. Decompose the work into ordered, named units — each completable in a single session
2. Name units with kebab-case (e.g., `add-auth-middleware`, `write-auth-tests`)
3. Run: `python .claude/scripts/raven-session.py --init <greenfield|brownfield> <unit-1> <unit-2> ...`
   - If the parent task is a tracked issue and `[issue_tracker].platform` is set, add `--parent <issue-number>`
   - After `--init`, create child issues manually using `gh issue create` or `glab issue create` and record their numbers in `session.md`
4. Present the unit plan to the user and wait for confirmation before proceeding

## Phase 3 — Execution Loop *(repeats per unit)*

1. Run `python .claude/scripts/raven-session.py --status` — confirm the current unit
2. Select the appropriate Raven execution skill:
   - New feature or behavior → `raven-implement-feature`
   - Rename, move, or API change → `raven-safe-refactor`
   - Test coverage gap → `raven-write-tests`
   - Failing behavior → `raven-debug-failure`
3. Execute that skill for the current unit
4. Run `python .claude/scripts/raven-session.py --complete <unit-name>`
   - The checkpoint hook validates this before allowing it to succeed
5. Invoke `raven-context-hygiene`.
6. If the context block in `session.md` grows large, the script will warn — run `--archive` after user confirmation
7. Advance to the next unit

## Phase 4 — Wrap-up

1. Run `python .claude/scripts/raven-session.py --status` to confirm all units complete
2. Summarize changes across all units and files touched
3. Suggest next steps: PR, review, deploy
