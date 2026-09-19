#!/usr/bin/env python3
"""PostToolUse hook: nudge toward RTK when a just-run bash command looks like a noisy test/build/CLI."""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
from functools import lru_cache

# Commands noisy enough to be worth compressing. Every entry is matched as a
# whole word (see _NOISY_COMMAND): plain substring matching flagged any command
# merely containing an entry's letters, so `aws` fired on
# `git commit -m "fix draws bug"`. The hint is advisory, which is exactly why a
# false positive is corrosive -- it teaches people to ignore hook output.
_NOISY_COMMANDS = (
    r"cargo\s+test",
    r"pytest",
    r"npm\s+test",
    r"pnpm\s+test",
    r"go\s+test",
    r"swift\s+test",
    r"xcodebuild",
    r"docker",
    r"kubectl",
    r"aws",
)

_NOISY_COMMAND = re.compile(r"\b(?:" + "|".join(_NOISY_COMMANDS) + r")\b")


@lru_cache(maxsize=1)
def _rtk_installed() -> bool:
    """True when `rtk` is on PATH.

    RTK is optional, and a hint pointing at a tool the reader cannot run is
    pure context cost on every noisy command -- in a hook whose whole purpose
    is spending less of it. Advisory output that cannot be acted on is the
    fastest way to teach people to ignore hook output, so a project without
    RTK gets silence instead. `brew install rtk` (or https://www.rtk-ai.app/)
    turns the hint back on with no Raven change.
    """
    return shutil.which("rtk") is not None


def _load_payload() -> dict | None:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return None
    # Valid JSON of the wrong shape (a list, a bare string, a number) is still
    # unusable: returning it would break the `dict` contract below and raise on
    # `.get`. That is the one parseable input that would traceback instead of
    # failing open, on every tool call.
    return payload if isinstance(payload, dict) else None


def _extract_command(payload: dict) -> str:
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    return tool_input.get("command") or payload.get("command") or ""


def _is_gemini_hook(payload: dict) -> bool:
    if "GEMINI_PROJECT_DIR" in os.environ:
        return True
    event = payload.get("hook_event_name")
    if event in ("BeforeTool", "AfterTool"):
        return True
    tool = payload.get("tool_name")
    return tool in ("run_shell_command", "read_file", "write_file", "replace")


def main() -> int:
    """Read the hook payload from stdin and print an RTK hint if the command matches a noisy tool."""
    payload = _load_payload()
    if payload is None:
        return 0

    command = _extract_command(payload)
    if not command:
        return 0

    if (
        _rtk_installed()
        and not command.lstrip().startswith("rtk ")
        and _NOISY_COMMAND.search(command)
    ):
        hint = (
            f"Consider running noisy commands through RTK when exact raw output"
            f" is not required: {command}"
        )
        if _is_gemini_hook(payload):
            print(
                json.dumps(
                    {
                        "systemMessage": hint,
                        "hookSpecificOutput": {
                            "hookEventName": "AfterTool",
                            "additionalContext": hint,
                        },
                    }
                )
            )
        elif "hook_event_name" in payload or "tool_name" in payload:
            print(
                json.dumps(
                    {
                        "hookSpecificOutput": {
                            "hookEventName": "PostToolUse",
                            "additionalContext": hint,
                        }
                    }
                )
            )
        else:
            print(hint)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
