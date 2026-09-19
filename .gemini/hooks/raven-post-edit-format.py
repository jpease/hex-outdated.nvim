#!/usr/bin/env python3
"""PostToolUse hook: best-effort auto-format a just-edited file with its language's formatter.

Silent and always exits 0 -- a missing formatter, an unsupported extension, or a
malformed hook payload all mean "nothing to do", never a hook failure that would
block the edit or spam the transcript.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path


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


def _extract_path(payload: dict) -> str:
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    return tool_input.get("file_path") or tool_input.get("path") or payload.get("file_path") or ""


def run(command: list[str]) -> None:
    """Run a formatter command, discarding its output; failure is not reported (best-effort)."""
    subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def _swift_format_cmd() -> list[str] | None:
    """Resolve Apple's swift-format: prefer a PATH binary, else the Xcode toolchain via xcrun."""
    if shutil.which("swift-format"):
        return ["swift-format"]
    if shutil.which("xcrun"):
        return ["xcrun", "swift-format"]
    return None


def main() -> int:
    """Read the hook payload from stdin and format the edited file, if its type is supported."""
    payload = _load_payload()
    if payload is None:
        return 0

    raw_path = _extract_path(payload)
    if not raw_path:
        return 0

    path = Path(raw_path)
    if not path.is_file():
        return 0

    suffix = path.suffix.lower()
    if suffix == ".py" and shutil.which("ruff"):
        run(["ruff", "format", str(path)])
    elif suffix in {".js", ".jsx", ".ts", ".tsx", ".json", ".md"} and shutil.which("prettier"):
        run(["prettier", "--write", str(path)])
    elif suffix == ".swift":
        swift_format = _swift_format_cmd()
        if swift_format:
            run([*swift_format, "format", "--in-place", str(path)])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
