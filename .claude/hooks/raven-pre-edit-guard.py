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


def _extract_path(payload: dict) -> str:
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    return tool_input.get("file_path") or tool_input.get("path") or payload.get("file_path") or ""


def _is_codex_hook(payload: dict) -> bool:
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

    path = _extract_path(payload)
    if not path:
        return 0

    normalized = path.replace("\\", "/")

    blocked = [
        r"\.pem$",
        r"\.key$",
        r"\.p12$",
        r"\.pfx$",
        r"\.crt$",
        r"\.cer$",
        r"(^|/)\.env$",
        r"secrets",
        r"credentials",
    ]
    caution = [
        r"/migrations/",
        r"/generated/",
        r"package-lock\.json$",
        r"Cargo\.lock$",
        r"pnpm-lock\.yaml$",
    ]

    if any(re.search(pattern, normalized, re.IGNORECASE) for pattern in blocked):
        return _deny(f"Protected file path. Confirm intent before editing: {path}", payload)

    if any(re.search(pattern, normalized, re.IGNORECASE) for pattern in caution):
        print(
            f"High-churn or generated/protected path. Edit only when required: {path}",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
