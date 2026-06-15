---
name: raven-tool-bootstrap
description: Use when the Raven tool check reports missing tools, or when the user asks to check, install, remember, or stop reminding about recommended tools.
---

# Tool Bootstrap

Goal: respond to Raven tool availability checks without repeated tool discovery.

## Skip When

- No tool check was requested or reported.
- The task can proceed using installed baseline tools.

## Required Constraints

- Do not install tools silently.
- Do not suppress future reminders without explicit user approval.
- Treat `.mcp.json` tools as optional local capabilities until verified.
- If the SessionStart hook reports missing tools, ask whether the user wants installation, instructions, a later reminder, or no future reminders.

## Commands

After tools are installed or verified, update Raven's local tool-check cache so SessionStart does not repeat the same prompt:

```sh
python .claude/scripts/raven-tool-check.py --write
```

If the user chooses not to be reminded:

```sh
python .claude/scripts/raven-tool-check.py --no-reminder
```

Use `python3`, `py -3`, or the active virtual environment if `python` is not the correct launcher.

## Issue-Tracker CLI Tools

These are checked only when `[issue_tracker].platform` is set in `.raven/config.toml`:

| Platform | CLI | Install |
|---|---|---|
| `github` | `gh` | `brew install gh` / https://cli.github.com |
| `gitlab` | `glab` | `brew install glab` / https://gitlab.com/gitlab-org/cli |

If `platform = "github"` and `gh` is missing, or `platform = "gitlab"` and `glab` is missing, ask the user whether to install, get instructions, remind later, or stop reminding — same flow as other missing tools.

For GitHub sub-issues (used with `--parent` in `raven-session.py --init`), verify `gh` version is v2.49 or later:

```bash
gh --version
```

If older, note that `--parent` will fall back to task-list checkboxes in the parent issue body.
