#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import sys


def _load_payload() -> dict | None:
    try:
        return json.load(sys.stdin)
    except Exception:
        return None


def _extract_command(payload: dict) -> str:
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    return tool_input.get("command") or payload.get("command") or ""


def _is_codex_hook(payload: dict) -> bool:
    # Both Claude Code and Codex include these fields; both use the structured JSON path.
    return "hook_event_name" in payload or "tool_name" in payload


def _deny(message: str, payload: dict) -> int:
    if _is_codex_hook(payload):
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": message,
                    }
                }
            )
        )
        return 0
    print(message, file=sys.stderr)
    return 2


def main() -> int:
    payload = _load_payload()
    if payload is None:
        return 0

    command = _extract_command(payload)
    if not command:
        return 0

    blocked_patterns = [
        # rm -rf / or rm -fr / (root only; /path/to/dir is intentionally allowed)
        r"rm\s+(-\w*rf\w*|-\w*fr\w*)\s+/(\s|[;|&]|$)",
        # rm -rf ~/ or rm -rf ~ (home directory)
        r"rm\s+(-\w*rf\w*|-\w*fr\w*)\s+~",
        r"sudo\s+rm\b",
        r"git\s+reset\s+--hard",
        r"git\s+clean\s+-fdx",
        r"\bdropdb\b",
        r"\bDROP\s+DATABASE\b",
        r"kubectl\s+delete\b",
        r"aws\b.*\bdelete\b",
    ]

    for pattern in blocked_patterns:
        if re.search(pattern, command, re.IGNORECASE):
            return _deny(
                f"Blocked potentially destructive command. Ask for explicit approval before running: {command}",
                payload,
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
