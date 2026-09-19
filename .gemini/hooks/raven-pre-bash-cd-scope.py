#!/usr/bin/env python3
"""PreToolUse hook: once per session, name the absolute-path rewrite for a leading ``cd``.

``cd <dir> && <cmd>`` makes a command's meaning depend on state that is not in
the command. In an agent harness the working directory is reset between tool
calls, so the ``cd`` buys nothing that a path argument would not, and every
later reader of the transcript has to reconstruct where the command ran. The
same shape also defeats static analysis of what a command will read: Claude
Code 2.1.259 escalates it with "would search a directory that cannot be
determined here". That escalation is the symptom that prompted this hook, but
it is not the reason for it -- the determinism argument holds whatever upstream
does with its permission analysis, and this hook should outlive the 2.1.259
behavior either way (jpease/raven#260).

Deliberately narrow. It fires only when the command after the ``cd`` is
read-only *and* already takes a path operand, so a mechanical rewrite always
exists: ``git`` (``git -C <dir> ...``) and the search/read tools in
``_PATH_TAKING``. ``just``, package managers, build tools, and anything that
resolves config from the working directory are left alone, because for those
the ``cd`` is correct. A matcher broad enough to catch every case would fire on
legitimate work and be tuned out within a day, which turns a control back into
a prompt -- the failure this exists to fix.

Advisory, not a denial, and once per session -- the same two choices
``raven-pre-bash-test-scope.py`` makes, for the same reason: the rewrite is
usually right, not always, and a nudge repeated on every call is noise. Whether
once is enough is an open question the ``absolute-path-search`` eval scenario
is there to answer; escalating to a denial is a decision for that measurement,
not for this docstring.

Shared byte-for-byte between the Claude and Codex adapters: both deliver
``hookSpecificOutput.additionalContext`` from a PreToolUse command hook, and
both put ``session_id`` in the payload. The stamp lives under the temp
directory, never in the repository. No ``session_id`` means no stamp and
therefore no nudge, rather than a nudge on every command.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys
import tempfile
from pathlib import Path

STAMP_PREFIX = "raven-cd-scope-"

# Read-only and already path-taking: for each of these, `cd d && tool ... x` has
# an exact equivalent in `tool ... d/x`. Writers (`sed -i`, `tee`) and anything
# that resolves config from the working directory are deliberately absent.
_PATH_TAKING = frozenset(
    {
        "rg",
        "grep",
        "egrep",
        "fgrep",
        "fd",
        "find",
        "cat",
        "head",
        "tail",
        "wc",
        "ls",
        "stat",
        "file",
    }
)

# Tokens that wrap a command without changing what it runs.
_WRAPPERS = frozenset({"rtk", "command", "env"})


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


def _split_after_cd(command: str) -> tuple[str, str] | None:
    """``(directory, remainder)`` when the command opens with ``cd <dir>`` then ``&&``/``;``.

    ``||`` is not a separator here: ``cd d || exit 1`` is error handling, and
    the command that would run is the fallback, not something the ``cd``
    scopes.
    """
    match = re.match(r"\s*cd\s+([^\s;&|]+|\"[^\"]*\"|'[^']*')\s*(?:&&|;)\s*(.+)", command, re.S)
    if match is None:
        return None
    directory = match.group(1).strip("\"'")
    remainder = match.group(2).strip()
    return (directory, remainder) if directory and remainder else None


def _first_tokens(segment: str) -> list[str]:
    """Tokens of the first simple command in ``segment``, past wrappers."""
    head = re.split(r"\s*(?:&&|\|\||;|\|)\s*", segment.strip(), maxsplit=1)[0]
    try:
        tokens = shlex.split(head)
    except ValueError:
        tokens = head.split()
    while tokens and tokens[0] in _WRAPPERS:
        tokens.pop(0)
    return tokens


def classify(command: str) -> tuple[str, str] | None:
    """``(directory, rewrite-hint)`` when a leading ``cd`` has a mechanical rewrite."""
    split = _split_after_cd(command)
    if split is None:
        return None
    directory, remainder = split
    tokens = _first_tokens(remainder)
    if not tokens:
        return None
    # Re-quote: the directory was unquoted out of the source command, and a path
    # holding a space would otherwise be emitted as a rewrite that does not run.
    quoted = shlex.quote(directory)
    if tokens[0] == "git":
        return directory, f"git -C {quoted} {' '.join(tokens[1:])}".rstrip()
    if tokens[0] in _PATH_TAKING:
        return directory, f"pass {quoted} (or a path under it) to {tokens[0]} as an argument"
    return None


def _stamp_path(session_id: str) -> Path:
    safe = "".join(ch for ch in session_id if ch.isalnum() or ch in "-_")[:64]
    return Path(tempfile.gettempdir()) / f"{STAMP_PREFIX}{safe}"


def main() -> int:
    """Read the PreToolUse payload; nudge once per session on a rewritable leading ``cd``."""
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
        stamp.write_text("nudged", encoding="utf-8")
    except OSError:
        return 0

    _, rewrite = verdict
    message = (
        "This command opens with `cd`, so what it reads depends on state "
        "that is not in the command, and the harness resets the working "
        "directory between calls anyway. An equivalent absolute-path form "
        f"exists: {rewrite}. Prefer that spelling for the rest of this "
        "session. Continue if the `cd` is load-bearing here."
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
