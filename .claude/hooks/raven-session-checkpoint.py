#!/usr/bin/env python3
"""PreToolUse hook: validate raven-session.py --complete before allowing."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


def _load_payload() -> dict | None:  # type: ignore[type-arg]
    try:
        return json.load(sys.stdin)
    except Exception:
        return None


def _extract_command(payload: dict) -> str:  # type: ignore[type-arg]
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    return tool_input.get("command") or payload.get("command") or ""


def _is_codex_hook(payload: dict) -> bool:  # type: ignore[type-arg]
    return "hook_event_name" in payload or "tool_name" in payload


def _deny(message: str, payload: dict) -> int:  # type: ignore[type-arg]
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


def _enforcement_enabled() -> bool:
    config = Path(".raven/config.toml")
    if not config.exists():
        return True
    for line in config.read_text(encoding="utf-8").splitlines():
        if "checkpoint_enforcement" in line and "false" in line:
            return False
    return True


def _extract_unit(command: str) -> str | None:
    m = re.search(r"--complete\s+(\S+)", command)
    return m.group(1) if m else None


def main() -> int:
    payload = _load_payload()
    if payload is None:
        return 0

    if not _enforcement_enabled():
        return 0

    if not Path(".raven/session.md").exists():
        return _deny("No active session. Run raven-session.py --init first.", payload)

    command = _extract_command(payload)
    unit = _extract_unit(command)
    if not unit:
        return 0

    result = subprocess.run(
        [sys.executable, ".claude/scripts/raven-session.py", "--validate", unit],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        msg = result.stderr.strip() or result.stdout.strip() or f"Cannot complete unit '{unit}'"
        return _deny(msg, payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
