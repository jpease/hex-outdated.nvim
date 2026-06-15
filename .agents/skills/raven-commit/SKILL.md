---
name: raven-commit
description: Use when writing git commit messages. Enforces Conventional Commits format.
allowed-tools: Bash(git *)
---

# Conventional Commits

## Commit format

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

## Types

| Type       | Use when                                 | SemVer impact |
| ---------- | ---------------------------------------- | ------------- |
| `feat`     | Adding a new feature                     | MINOR         |
| `fix`      | Patching a bug                           | PATCH         |
| `docs`     | Documentation only                       | none          |
| `style`    | Formatting, whitespace (no logic change) | none          |
| `refactor` | Neither a fix nor a feature              | none          |
| `perf`     | Performance improvement                  | none          |
| `test`     | Adding or fixing tests                   | none          |
| `build`    | Build system or dependency changes       | none          |
| `ci`       | CI configuration changes                 | none          |
| `chore`    | Misc tasks (e.g. release scripts)        | none          |
| `revert`   | Reverting a prior commit                 | none          |

## Breaking changes

Two ways to mark — use one or both:

1. Append `!` after the type/scope: `feat!:` or `feat(api)!:`
2. Add a footer: `BREAKING CHANGE: <description>`

Breaking changes trigger a MAJOR SemVer bump regardless of type.

## Rules

- **Description**: lowercase, imperative mood, no trailing period, immediately after `type: `
- **Body**: separated from description by one blank line; free-form; explain _what_ and _why_
- **Footers**: one blank line after body; format `Token: value` or `Token #value`; multi-word tokens use `-` (e.g. `Reviewed-by`); exception: `BREAKING CHANGE` (with space) is valid
- **`BREAKING CHANGE`** footer token must be uppercase
- **`BREAKING-CHANGE`** is synonymous with `BREAKING CHANGE` in footers
- Types and scopes are case-insensitive (except `BREAKING CHANGE`)
- **No AI attribution**: never add `Co-Authored-By`, `Generated-by`, or any footer or comment crediting an AI agent (Claude, Codex, Gemini, Copilot, etc.); commits represent the human author's work

## Examples

```
# Minimal
docs: fix typo in README

# With scope
feat(lang): add Polish language support

# Breaking change with !
feat(api)!: remove deprecated /v1/users endpoint

# Breaking change with footer
feat!: drop Node 6 support

BREAKING CHANGE: uses optional chaining, not available in Node 6.

# Bug fix with body and footers
fix: prevent request race condition

Introduce a request ID tied to the latest request.
Dismiss responses that don't match the latest ID.
Remove now-obsolete timeout workarounds.

Reviewed-by: Z
Refs: #123

# Revert
revert: let us never again speak of the noodle incident

Refs: 676104e, a215868
```

## Workflow guidance

- **One concern per commit.** If a change fits multiple types, split into multiple commits.
- **Wrong type before merge**: use `git rebase -i` to fix. After release, leave it — tools will simply ignore the non-conforming commit.

## SemVer mapping

```
fix            → PATCH
feat           → MINOR
BREAKING CHANGE → MAJOR  (overrides all other types)
```
