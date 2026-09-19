#!/usr/bin/env python3
"""PostToolUse hook: replace an oversized Bash result with its head, its tail, and a path to the whole.

Every line of a tool result is paid for on every later turn of the session,
so a 2,000-line test log costs its full price dozens of times over. This hook
keeps the first ``HEAD_LINES`` lines (where a traceback starts) and the last
lines up to the configured limit (where a summary lands), writes the complete
output to a file, and names that file in the replacement so nothing is lost:
the agent can search it with ``rg`` or read a range with ``sed -n`` instead
of carrying all of it in context.

Claude Code only, by construction. Claude's PostToolUse hook can replace a
result through ``hookSpecificOutput.updatedToolOutput``; Codex's PostToolUse
can block or add feedback but has no field that swaps the result, so this
file has no ``.codex/hooks/`` counterpart (recorded in
``.claude/docs/raven-agent-compatibility.md``). A command already routed
through RTK is left alone -- it is compressed once, on purpose.

Configured by ``[bash_output] max_lines`` in ``.raven/config.toml``; ``0``
turns it off. Fail-open: anything this cannot parse leaves the result as it
was.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import tempfile
from importlib.machinery import SourceFileLoader
from pathlib import Path

DEFAULT_MAX_LINES = 150
HEAD_LINES = 40
SPILL_DIRECTORY_NAME = "raven-bash-output"


def _load_payload() -> dict | None:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return None
    return payload if isinstance(payload, dict) else None


def _is_gemini_hook(payload: dict) -> bool:
    if "GEMINI_PROJECT_DIR" in os.environ:
        return True
    event = payload.get("hook_event_name")
    if event in ("BeforeTool", "AfterTool"):
        return True
    tool = payload.get("tool_name")
    return tool in ("run_shell_command", "read_file", "write_file", "replace")


def _raven_config_module():
    """Import ``.raven/git-hooks/lib/raven_config.py`` from the install layout.

    Installed at ``<root>/.claude/hooks/``, so two parents up is the project
    root. Same pattern as ``raven-skeleton-read-guard.py``.
    """
    path = Path(__file__).resolve().parents[2] / ".raven" / "git-hooks" / "lib" / "raven_config.py"
    spec = importlib.util.spec_from_file_location(
        "raven_config_for_bash_truncate",
        path,
        loader=SourceFileLoader("raven_config_for_bash_truncate", str(path)),
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load raven_config from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_max_lines(text: str) -> int:
    """``[bash_output] max_lines`` from raw config text; the default when absent.

    A non-integer or negative value keeps the default rather than turning the
    hook off: a typo should not silently remove a guardrail.
    """
    try:
        raven_config = _raven_config_module()
    except (ImportError, OSError):
        return DEFAULT_MAX_LINES
    section = raven_config.parse_config_text(text).get("bash_output", {})
    value = section.get("max_lines", "").strip()
    if value.isdigit():
        return int(value)
    return DEFAULT_MAX_LINES


def read_max_lines() -> int:
    """The configured limit from the install's ``.raven/config.toml``, or the default."""
    config = Path(__file__).resolve().parents[2] / ".raven" / "config.toml"
    try:
        text = config.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return DEFAULT_MAX_LINES
    return parse_max_lines(text)


def truncate(
    stdout: str, max_lines: int, spill_path: str, head_lines: int = HEAD_LINES
) -> str | None:
    """The replacement text, or None when ``stdout`` is within ``max_lines``.

    Head and tail are split so the tail gets whatever the limit leaves after
    the head: a test runner prints its verdict last, and that is the part a
    reader must not lose.
    """
    if max_lines <= 0:
        return None
    lines = stdout.splitlines()
    total = len(lines)
    if total <= max_lines:
        return None
    head = min(head_lines, max_lines // 2)
    tail = max_lines - head
    omitted = total - head - tail
    marker = (
        f"[raven: {omitted} of {total} lines omitted from the middle. Full output: "
        f"{spill_path} -- search it with rg, or read a range with sed -n, rather "
        f"than the whole file.]"
    )
    kept = [*lines[:head], marker, *lines[total - tail :]]
    return "\n".join(kept) + ("\n" if stdout.endswith("\n") else "")


def _spill(stdout: str, session_id: str) -> str | None:
    """Write the complete output under the temp directory; the path, or None."""
    directory = Path(tempfile.gettempdir()) / SPILL_DIRECTORY_NAME
    digest = hashlib.sha1(stdout.encode("utf-8", "replace")).hexdigest()[:12]
    safe_session = "".join(ch for ch in session_id if ch.isalnum() or ch in "-_")[:32] or "session"
    path = directory / f"{safe_session}-{digest}.log"
    try:
        directory.mkdir(parents=True, exist_ok=True)
        path.write_text(stdout, encoding="utf-8", errors="replace")
    except OSError:
        return None
    return str(path)


def main() -> int:
    """Read the PostToolUse payload and replace an oversized Bash result."""
    payload = _load_payload()
    if payload is None:
        return 0
    response = payload.get("tool_response")
    stdout = None
    if isinstance(response, str):
        stdout = response
    elif isinstance(response, dict):
        stdout = response.get("stdout") or response.get("output")
    if not isinstance(stdout, str):
        return 0
    tool_input = payload.get("tool_input") or {}
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if isinstance(command, str) and command.lstrip().startswith("rtk "):
        return 0

    max_lines = read_max_lines()
    if max_lines <= 0 or len(stdout.splitlines()) <= max_lines:
        return 0

    session_id = payload.get("session_id")
    spill_path = _spill(stdout, session_id if isinstance(session_id, str) else "")
    if spill_path is None:
        # Nowhere to keep the whole output means nothing may be dropped.
        return 0
    replacement = truncate(stdout, max_lines, spill_path)
    if replacement is None:
        return 0

    if _is_gemini_hook(payload):
        print(json.dumps({"decision": "deny", "reason": replacement}))
        return 0

    if isinstance(response, dict):
        updated = dict(response)
        updated["stdout"] = replacement
    else:
        updated = replacement
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "updatedToolOutput": updated,
                }
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
