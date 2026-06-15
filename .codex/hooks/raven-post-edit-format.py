#!/usr/bin/env python3

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path


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


def run(command: list[str]) -> None:
    subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def main() -> int:
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

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
