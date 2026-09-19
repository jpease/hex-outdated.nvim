#!/usr/bin/env python3
"""PreToolUse hook: deny a ``Read`` of a secret-bearing path.

This replaces the 21 ``Read(...)`` entries that used to sit in
``permissions.deny`` (#260). Those rules used gitignore semantics, where a bare
filename matches at any depth -- ``Read(*.pem)`` covered every ``.pem``
anywhere, which is what made them worth having. Claude Code 2.1.259 began
evaluating a Bash command's implied read scope against the same rules at
*directory* granularity, so a recursive read of the repository root escalated
because some ``.pem`` *could* exist inside it. No file had to be present. Every
``rg`` and ``grep`` at the root prompted, which put the prompt on routine
discovery and trained approval reflex -- the opposite of what a secrets guard
is for.

A settings-only fix does not exist. Rules evaluate deny -> ask -> allow
(``raven-guardrails.md``), so no ``permissions.allow`` entry can carry an
exception to a deny, and anchoring the globs so they stop matching at depth
would trade the prompt for a real hole (``packages/api/.env`` would stop being
covered). A hook is the one place that sees the *concrete path* a read is
about, so it can refuse ``.env`` while saying nothing about a directory scan
that might contain one.

Coverage is unchanged in both directions. It was always Claude-only
(``.claude/settings.json``), and it never stopped ``cat .env`` through Bash --
a documented ceiling of every ``Read(...)`` entry, recorded beside the original
rules. Bash remains ``raven-pre-bash-guard.py``'s territory.

``[hooks] block_secret_reads = false`` in ``.raven/config.toml`` turns this off,
the same shape ``block_gate_relaxation`` uses: a repository-level decision made
in the open and reviewable as a config change.
"""

from __future__ import annotations

import fnmatch
import json
import sys
from pathlib import Path

# Ported one-for-one from the `Read()` deny entries this replaces. Matched
# against the path's basename, and separately against each directory segment
# for the container names, which is what `secret/**` expressed before.
_SECRET_FILE_GLOBS = (
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.crt",
    "*.cer",
    ".env",
    ".env.*",
    ".envrc",
    "secret",
    "secrets",
    "secret.*",
    "secrets.*",
    "credential",
    "credentials",
    "credential.*",
    "credentials.*",
)

#: Directory names whose contents were covered by `secret/**`-style rules.
_SECRET_DIRS = frozenset({"secret", "secrets", "credential", "credentials"})


def _load_payload() -> dict | None:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return None
    return payload if isinstance(payload, dict) else None


def matches(file_path: str) -> str | None:
    """The rule a path trips, or None. Directory segments count, as `secret/**` did."""
    path = Path(file_path)
    name = path.name
    for glob in _SECRET_FILE_GLOBS:
        if fnmatch.fnmatch(name, glob):
            return glob
    for segment in path.parts[:-1]:
        if segment in _SECRET_DIRS:
            return f"{segment}/**"
    return None


def _enabled(start: Path) -> bool:
    """Whether `[hooks] block_secret_reads` is on; anything short of an explicit false."""
    for candidate in (start, *start.parents):
        config = candidate / ".raven" / "config.toml"
        if not config.is_file():
            continue
        try:
            text = config.read_text(encoding="utf-8")
        except OSError:
            return True
        for line in text.splitlines():
            stripped = line.split("#", 1)[0].strip()
            if stripped.replace(" ", "").lower() == "block_secret_reads=false":
                return False
        return True
    return True


def main() -> int:
    """Deny a Read whose target matches one of the ported secret rules."""
    payload = _load_payload()
    if payload is None:
        return 0
    tool_input = payload.get("tool_input") or {}
    file_path = tool_input.get("file_path") if isinstance(tool_input, dict) else None
    if not isinstance(file_path, str) or not file_path:
        return 0

    rule = matches(file_path)
    if rule is None:
        return 0

    cwd = payload.get("cwd")
    start = Path(cwd) if isinstance(cwd, str) and cwd else Path.cwd()
    if not _enabled(start):
        return 0

    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        f"{file_path} matches the secret-file rule `{rule}`. Raven denies "
                        "reading credential material into the transcript. If this file is "
                        "an example or fixture, rename it or read the specific line range "
                        "you need through a command that does not tool-Read the file."
                    ),
                }
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
