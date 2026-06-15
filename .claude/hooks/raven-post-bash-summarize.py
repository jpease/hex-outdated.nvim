#!/usr/bin/env python3

from __future__ import annotations

import json
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


def main() -> int:
    payload = _load_payload()
    if payload is None:
        return 0

    command = _extract_command(payload)
    if not command:
        return 0

    noisy_commands = [
        "cargo test",
        "pytest",
        "npm test",
        "pnpm test",
        "go test",
        "swift test",
        "xcodebuild",
        "docker",
        "kubectl",
        "aws",
    ]

    if not command.lstrip().startswith("rtk ") and any(
        candidate in command for candidate in noisy_commands
    ):
        hint = (
            f"Consider running noisy commands through RTK when exact raw output"
            f" is not required: {command}"
        )
        # Both Claude Code and Codex include hook_event_name/tool_name in payloads.
        if "hook_event_name" in payload or "tool_name" in payload:
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
