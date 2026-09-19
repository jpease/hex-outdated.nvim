#!/usr/bin/env python3
"""PreToolUse hook: once per session, say when the first test run covers the whole suite.

``AGENTS.md`` asks for the narrowest relevant test first, then the full gate
once it passes. That line is prose, and the eval's ``narrowest-test-first``
scenario is the only thing that checks whether an agent followed it. This is
the mechanical half: on the session's first test command, if it names no
file, test, or filter, one advisory sentence is added to the agent's context.
Nothing is denied -- running the whole suite first is sometimes the right
call -- and nothing is said again for the rest of the session, because a
whole-suite run *after* a narrow one is exactly the broadening step the
guidance asks for.

Shared byte-for-byte between the Claude and Codex adapters: both deliver
``hookSpecificOutput.additionalContext`` from a PreToolUse command hook, and
both put ``session_id`` in the payload, which is what makes "first in this
session" answerable. The stamp lives under the temp directory, never in the
repository. No ``session_id`` means no stamp and therefore no nudge, rather
than a nudge on every test command.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys
import tempfile
from pathlib import Path


def _is_gemini_hook(payload: dict) -> bool:
    if "GEMINI_PROJECT_DIR" in os.environ:
        return True
    event = payload.get("hook_event_name")
    if event in ("BeforeTool", "AfterTool"):
        return True
    tool = payload.get("tool_name")
    return tool in ("run_shell_command", "read_file", "write_file", "replace")


STAMP_PREFIX = "raven-test-scope-"

# Tokens that wrap a runner without changing what it runs.
_WRAPPERS = frozenset({"rtk", "uv", "run", "poetry", "pipenv", "bundle", "exec", "npx", "bunx"})
_INTERPRETERS = frozenset(
    {
        "python",
        "python3",
        "python3.9",
        "python3.10",
        "python3.11",
        "python3.12",
        "python3.13",
        "python3.14",
        "py",
    }
)

# (runner tokens) -> whole-suite when nothing narrowing follows them.
_RUNNERS: tuple[tuple[str, ...], ...] = (
    ("pytest",),
    ("just", "test"),
    ("just", "check"),
    ("cargo", "test"),
    ("cargo", "nextest", "run"),
    ("go", "test"),
    ("npm", "test"),
    ("npm", "run", "test"),
    ("pnpm", "test"),
    ("pnpm", "run", "test"),
    ("yarn", "test"),
    ("swift", "test"),
    ("mix", "test"),
    ("rspec",),
    ("busted",),
    ("vitest",),
    ("jest",),
)

# Flags that select a subset. Anything positional that is not a whole-tree
# spelling also counts as narrowing.
_NARROWING_FLAGS = frozenset(
    {"-k", "-m", "-run", "--run", "--filter", "-p", "--package", "--test", "--only", "-t"}
)
_WHOLE_TREE = frozenset({".", "./...", "..."})


def _load_payload() -> dict | None:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return None
    return payload if isinstance(payload, dict) else None


def _first_simple_command(command: str) -> list[str]:
    """Tokens of the first simple command, past env assignments and wrappers."""
    head = re.split(r"\s*(?:&&|\|\||;|\|)\s*", command.strip(), maxsplit=1)[0]
    try:
        tokens = shlex.split(head)
    except ValueError:
        tokens = head.split()
    while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
        tokens.pop(0)
    while tokens and tokens[0] in _WRAPPERS:
        tokens.pop(0)
        # `uv run --group dev pytest`: drop the wrapper's own options.
        while tokens and tokens[0].startswith("-"):
            flag = tokens.pop(0)
            if flag in {"--group", "--with", "--python", "-p"} and tokens:
                tokens.pop(0)
    if len(tokens) >= 2 and tokens[0] in _INTERPRETERS and tokens[1] == "-m":
        tokens = tokens[2:]
    return tokens


def classify(command: str) -> str | None:
    """``"whole"``, ``"narrow"``, or None when this is not a test command."""
    tokens = _first_simple_command(command)
    for runner in _RUNNERS:
        if tuple(tokens[: len(runner)]) == runner:
            rest = tokens[len(runner) :]
            break
    else:
        return None
    if any(
        flag in _NARROWING_FLAGS or flag.startswith(("-k=", "--filter=", "-run=")) for flag in rest
    ):
        return "narrow"
    positional = [token for token in rest if not token.startswith("-") and token != "--"]
    if any(token not in _WHOLE_TREE for token in positional):
        return "narrow"
    return "whole"


def _stamp_path(session_id: str) -> Path:
    safe = "".join(ch for ch in session_id if ch.isalnum() or ch in "-_")[:64]
    return Path(tempfile.gettempdir()) / f"{STAMP_PREFIX}{safe}"


def main() -> int:
    """Read the PreToolUse payload; nudge once if the session's first test run is whole-suite."""
    payload = _load_payload()
    if payload is None:
        return 0
    tool_input = payload.get("tool_input") or {}
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    session_id = payload.get("session_id")
    if not isinstance(command, str) or not isinstance(session_id, str) or not session_id:
        return 0

    verdict = classify(command)
    if verdict is None:
        return 0
    stamp = _stamp_path(session_id)
    if stamp.exists():
        return 0
    try:
        stamp.write_text(verdict, encoding="utf-8")
    except OSError:
        return 0
    if verdict != "whole":
        return 0

    message = (
        "This is the session's first test run and it covers the whole "
        "suite. Raven asks for the narrowest relevant test first, then "
        "the full gate once it passes. Continue if the whole suite is "
        "what this step needs."
    )
    if _is_gemini_hook(payload):
        print(
            json.dumps(
                {
                    "systemMessage": message,
                    "hookSpecificOutput": {
                        "hookEventName": "BeforeTool",
                        "additionalContext": message,
                    },
                }
            )
        )
    else:
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "additionalContext": message,
                    }
                }
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
