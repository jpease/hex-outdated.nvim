#!/usr/bin/env python3
"""Raven session state manager for raven-project-lifecycle."""

from __future__ import annotations

import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import TypedDict


class Unit(TypedDict):
    """One tracked unit of work within a session: its name, completion, and linked issue."""

    name: str
    done: bool
    issue: str | None
    completed_at: str | None


class SessionData(TypedDict):
    """The full parsed contents of ``.raven/session.md``."""

    project_type: str
    started: str
    last_updated: str
    parent_issue: str | None
    units: list[Unit]
    context_lines: list[str]


RAVEN_DIR = Path(".raven")
SESSION_FILE = RAVEN_DIR / "session.md"
LOCK_FILE = RAVEN_DIR / "session.lock"
ARCHIVE_FILE = RAVEN_DIR / "session-archive.md"
CONFIG_FILE = RAVEN_DIR / "config.toml"
CONTEXT_SOFT_CAP = 50

# The trailing shapes _format_unit_entry appends to a unit's rendered line,
# and _parse_session strips back off on the next read. Named here so the
# input validators below can reject a stored name/issue that already looks
# like one of these shapes, instead of _parse_session misreading it later.
_TRAILING_CURRENT_SUFFIX = re.compile(r"\s*\(current\)\s*$")
_TRAILING_COMPLETED_SUFFIX = re.compile(r"\s*\(completed ([^)]+)\)\s*$")
# The exact shape the parser's issue-capture group requires: no whitespace
# or "→" (session.md's own field delimiter), ending in "#" plus digits.
_ISSUE_REF_SHAPE = r"[^\s→]*#\d+"


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _atomic_write(path: Path, content: str) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.rename(path)


def _parse_session(text: str) -> SessionData:
    """Parse session.md into a structured dict."""
    data: SessionData = {
        "project_type": "",
        "started": "",
        "last_updated": "",
        "parent_issue": None,
        "units": [],
        "context_lines": [],
    }
    lines = text.splitlines()
    in_units = False
    in_context = False

    for line in lines:
        if m := re.match(r"\*\*Project Type:\*\* (.+)", line):
            data["project_type"] = m.group(1).strip()
        elif m := re.match(r"\*\*Started:\*\* (.+)", line):
            data["started"] = m.group(1).strip()
        elif m := re.match(r"\*\*Last Updated:\*\* (.+)", line):
            data["last_updated"] = m.group(1).strip()
        elif m := re.match(r"\*\*Parent Issue:\*\* (.+)", line):
            data["parent_issue"] = m.group(1).strip()
        elif line.strip() == "## Units":
            in_units = True
            in_context = False
        elif line.strip() == "## Context":
            in_units = False
            in_context = True
        elif in_units and (m := re.match(r"- \[([ x])\] (.+)", line)):
            done = m.group(1) == "x"
            rest = m.group(2)
            issue = None
            completed_at = None
            # Strip the metadata that _render_session appends, from the end
            # inward, so unit names containing spaces and punctuation round-trip
            # instead of being truncated at the first whitespace.
            if cm := _TRAILING_COMPLETED_SUFFIX.search(rest):
                completed_at = cm.group(1)
                rest = rest[: cm.start()]
            else:
                rest = _TRAILING_CURRENT_SUFFIX.sub("", rest)
            if im := re.search(rf"\s*→ ({_ISSUE_REF_SHAPE})\s*$", rest):
                issue = im.group(1)
                rest = rest[: im.start()]
            name = rest
            data["units"].append(
                {
                    "name": name,
                    "done": done,
                    "issue": issue,
                    "completed_at": completed_at,
                }
            )
        elif in_context:
            data["context_lines"].append(line)

    return data


def _format_unit_entry(unit: Unit, *, current: bool = False) -> str:
    """Render one unit as its ``- [ ] name → #issue`` session/archive line.

    Single source of truth for the unit line shared by ``_render_session`` (both
    the done and pending branches) and ``cmd_archive``. A done unit shows its
    completion timestamp; the in-progress unit is tagged ``(current)``.
    """
    mark = "x" if unit["done"] else " "
    entry = f"- [{mark}] {unit['name']}"
    if unit.get("issue"):
        entry += f" → {unit['issue']}"
    if unit["done"]:
        if unit.get("completed_at"):
            entry += f" (completed {unit['completed_at']})"
    elif current:
        entry += " (current)"
    return entry


def _render_session(data: SessionData) -> str:
    lines = ["# Raven Session", ""]
    lines.append(f"**Project Type:** {data['project_type']}  ")
    lines.append(f"**Started:** {data['started']}  ")
    lines.append(f"**Last Updated:** {data['last_updated']}  ")
    if data.get("parent_issue"):
        lines.append(f"**Parent Issue:** {data['parent_issue']}  ")
    lines.append("")
    lines.append("## Units")
    lines.append("")
    current_set = False
    for u in data["units"]:
        is_current = not u["done"] and not current_set
        lines.append(_format_unit_entry(u, current=is_current))
        if is_current:
            current_set = True
    lines.append("")
    lines.append("## Context")
    lines.extend(data["context_lines"] if data["context_lines"] else [""])
    return "\n".join(lines) + "\n"


def _validate_unit_name(name: str) -> str | None:
    r"""Check whether ``name`` is safe to store as a unit name in session.md.

    Returns an error message if unsafe, else ``None``. session.md is a plain
    text line format with no escaping: ``_format_unit_entry`` appends
    `` → {issue}``, then either `` (completed ...)`` or `` (current)``, to
    the end of a unit's rendered line, and ``_parse_session`` strips those
    same shapes back off the end on the next read. A name that itself
    contains a newline/carriage return/``→``, or already ends in one of
    those appended shapes, is indistinguishable from render output and would
    be silently truncated or split into extra lines on the next parse — so
    it is rejected here instead. Trailing whitespace is rejected too: the
    same stripping regexes' leading ``\s*`` greedily consumes a name's own
    trailing space along with the appended suffix's separator space whenever
    the unit becomes current, gets completed, or gets an issue linked, so
    a trailing space is silently lost on the next parse unless it is banned
    at the source.
    """
    if not name.strip():
        return "unit name must not be empty or whitespace-only"
    if name != name.strip():
        return "unit name must not have leading or trailing whitespace"
    if "\n" in name or "\r" in name:
        return "unit name must not contain a newline or carriage return"
    if "→" in name:
        return "unit name must not contain '→', which session.md uses as its own field delimiter"
    if _TRAILING_CURRENT_SUFFIX.search(name):
        return (
            "unit name must not end with '(current)': session.md's renderer appends"
            " that suffix to the in-progress unit, and could not tell it apart from"
            " the name itself on the next parse"
        )
    if _TRAILING_COMPLETED_SUFFIX.search(name):
        return (
            "unit name must not end with '(completed ...)': session.md's renderer"
            " appends that suffix to a finished unit, and could not tell it apart"
            " from the name itself on the next parse"
        )
    return None


def _validate_issue_ref(issue_ref: str) -> str | None:
    """Check whether ``issue_ref`` is safe to store verbatim in session.md.

    Returns an error message if unsafe, else ``None``. ``_format_unit_entry``
    splices ``issue_ref`` into a unit's rendered line with no escaping, so it
    must not be able to introduce new physical lines (a newline or carriage
    return would let it fabricate additional markdown that ``_parse_session``
    would read back as legitimate units), nor contain ``→`` or whitespace
    that would defeat the parser's issue-capture shape.
    """
    if "\n" in issue_ref or "\r" in issue_ref:
        return "issue reference must not contain a newline or carriage return"
    if "→" in issue_ref:
        return (
            "issue reference must not contain '→', which session.md uses as its own field delimiter"
        )
    if not re.fullmatch(_ISSUE_REF_SHAPE, issue_ref):
        return (
            "issue reference must match the shape '#123', 'group/project#123', or"
            " 'group/sub/project#7': no internal whitespace, and it must end in '#'"
            " followed by one or more digits"
        )
    return None


def cmd_init(args: list[str]) -> int:
    """``--init``: create ``.raven/session.md`` for a new multi-unit session; refuses if one exists."""
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("project_type")
    p.add_argument("units", nargs="+")
    p.add_argument("--parent", default=None)
    ns = p.parse_args(args)

    for unit_name in ns.units:
        error = _validate_unit_name(unit_name)
        if error:
            print(f"error: invalid unit name {unit_name!r}: {error}", file=sys.stderr)
            return 1

    if SESSION_FILE.exists():
        print(
            f"error: session already exists at {SESSION_FILE}. Use --status to resume.",
            file=sys.stderr,
        )
        return 1

    RAVEN_DIR.mkdir(exist_ok=True)
    units: list[Unit] = [
        {"name": u, "done": False, "issue": None, "completed_at": None} for u in ns.units
    ]
    data: SessionData = {
        "project_type": ns.project_type,
        "started": _now(),
        "last_updated": _now(),
        "parent_issue": ns.parent,
        "units": units,
        "context_lines": [""],
    }
    _atomic_write(SESSION_FILE, _render_session(data))
    print(f"Session initialized: {len(ns.units)} unit(s), project type '{ns.project_type}'.")
    if ns.parent:
        print(
            f"Parent issue: {ns.parent}."
            " Create child issues manually with gh/glab, then record each with"
            " --link <unit> <issue>."
        )
    _update_gitignore()
    return 0


def _existing_ignore_patterns(text: str) -> set[str]:
    """Effective ignore patterns from .gitignore text.

    Compares by exact pattern, not substring, so a comment or a longer path that
    merely contains an entry does not count as the entry. Per gitignore syntax a
    line is a comment only when it starts with ``#``; surrounding whitespace is
    not significant for these simple path patterns, so it is stripped.
    """
    patterns = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        patterns.add(line)
    return patterns


def _update_gitignore() -> None:
    """Append session file entries to .gitignore if not already present."""
    gitignore = Path(".gitignore")
    entries = [".raven/session.md", ".raven/session.lock", ".raven/session-archive.md"]
    existing = gitignore.read_text(encoding="utf-8") if gitignore.exists() else ""
    present = _existing_ignore_patterns(existing)
    missing = [e for e in entries if e not in present]
    if missing:
        block = "\n# Raven session state\n" + "\n".join(missing) + "\n"
        with gitignore.open("a", encoding="utf-8") as f:
            f.write(block)


def cmd_status(args: list[str]) -> int:
    """``--status``: print completed/pending unit counts and the current unit."""
    if not SESSION_FILE.exists():
        print("No active session. Run --init to start one.", file=sys.stderr)
        return 1
    data = _parse_session(SESSION_FILE.read_text(encoding="utf-8"))
    completed = [u for u in data["units"] if u["done"]]
    pending = [u for u in data["units"] if not u["done"]]
    current = pending[0]["name"] if pending else None
    print(f"Project type : {data['project_type']}")
    if data.get("parent_issue"):
        print(f"Parent issue : {data['parent_issue']}")
    print(f"Completed    : {len(completed)}/{len(data['units'])} unit(s)")
    if current:
        print(f"Current unit : {current}")
    else:
        print("All units complete.")
    if len(pending) > 1:
        print(f"Remaining    : {', '.join(u['name'] for u in pending[1:])}")
    if len(data["context_lines"]) > CONTEXT_SOFT_CAP:
        print(
            f"warning: context block is {len(data['context_lines'])} lines"
            f" (>{CONTEXT_SOFT_CAP}). Consider running --archive."
        )
    return 0


def _acquire_lock() -> None:
    """Create lockfile with PID. Retry 3x on live PID; remove stale."""
    import time

    for attempt in range(4):
        if not LOCK_FILE.exists():
            LOCK_FILE.write_text(f"{os.getpid()}\n{_now()}", encoding="utf-8")
            return
        text = LOCK_FILE.read_text(encoding="utf-8").strip()
        pid_str = text.splitlines()[0] if text else ""
        try:
            pid = int(pid_str)
        except ValueError:
            LOCK_FILE.unlink(missing_ok=True)
            continue
        try:
            os.kill(pid, 0)
        except (ProcessLookupError, PermissionError):
            LOCK_FILE.unlink(missing_ok=True)
            continue
        if attempt < 3:
            time.sleep(0.2)
        else:
            print(
                f"error: session locked by PID {pid}. Another agent may be running. "
                "If not, delete .raven/session.lock manually.",
                file=sys.stderr,
            )
            sys.exit(1)


def _release_lock() -> None:
    LOCK_FILE.unlink(missing_ok=True)


def _current_unit(data: SessionData) -> Unit | None:
    for u in data["units"]:
        if not u["done"]:
            return u
    return None


def _validate_session(data: SessionData) -> int:
    """Session-wide checks over already-parsed state.

    Currently the only rule: no issue reference may be assigned to more than
    one unit. The field is an opaque string, so "same reference" means exact,
    case-sensitive string equality — no tracker-specific normalization.
    """
    by_issue: dict[str, list[str]] = {}
    for u in data["units"]:
        issue = u.get("issue")
        if issue:
            by_issue.setdefault(issue, []).append(u["name"])
    duplicates = {issue: names for issue, names in by_issue.items() if len(names) > 1}
    if duplicates:
        for issue, names in duplicates.items():
            print(
                f"error: issue '{issue}' is assigned to multiple units: {', '.join(names)}",
                file=sys.stderr,
            )
        return 1
    print("Session valid: no duplicate issue references.")
    return 0


def cmd_validate(args: list[str]) -> int:
    """``--validate [unit]``: per-unit precondition check, or session-wide checks.

    With a unit name, checks that ``<unit>`` is the current, not-yet-done unit.
    Read-only precondition check `cmd_complete` also runs internally before
    mutating state, so a caller can validate up front without the side effect
    of completing the unit.

    With no argument, runs session-wide checks instead — currently, duplicate
    issue-reference detection. `cmd_complete` always calls this with a unit
    name, so it is unaffected by the session-wide checks.
    """
    if not SESSION_FILE.exists():
        print("error: no active session", file=sys.stderr)
        return 1
    data = _parse_session(SESSION_FILE.read_text(encoding="utf-8"))
    if not args:
        return _validate_session(data)
    unit_name = args[0]
    current = _current_unit(data)
    if current is None:
        print("error: all units already complete", file=sys.stderr)
        return 1
    if current["name"] != unit_name:
        print(
            f"error: '{unit_name}' is not the current unit (current: '{current['name']}')",
            file=sys.stderr,
        )
        return 1
    if current["done"]:
        print(f"error: unit '{unit_name}' is already marked complete", file=sys.stderr)
        return 1
    return 0


def cmd_complete(args: list[str]) -> int:
    """``--complete <unit>``: mark the current unit done and print the next one, under the session lock."""
    if not args:
        print("error: --complete requires a unit name", file=sys.stderr)
        return 1
    unit_name = args[0]
    if not SESSION_FILE.exists():
        print("error: no active session", file=sys.stderr)
        return 1
    rc = cmd_validate([unit_name])
    if rc != 0:
        return rc
    _acquire_lock()
    try:
        data = _parse_session(SESSION_FILE.read_text(encoding="utf-8"))
        for u in data["units"]:
            if u["name"] == unit_name:
                u["done"] = True
                u["completed_at"] = _now()
                break
        data["last_updated"] = _now()
        _atomic_write(SESSION_FILE, _render_session(data))
    finally:
        _release_lock()
    print(f"Unit '{unit_name}' marked complete.")
    remaining = [u for u in data["units"] if not u["done"]]
    if remaining:
        print(f"Next unit: {remaining[0]['name']}")
    else:
        print("All units complete. Run --status for a summary.")
    return 0


def cmd_link(args: list[str]) -> int:
    """``--link <unit> <issue>``: record an opaque issue reference on ``<unit>``, under the session lock.

    ``<issue>`` must match ``_ISSUE_REF_SHAPE``: no newline, carriage return,
    or ``→`` (session.md's own field delimiter), no internal whitespace, and
    it must end in ``#`` followed by one or more digits. ``#123``,
    ``group/project#123``, and ``group/sub/project#7`` all satisfy that shape
    and round-trip unchanged; anything else is rejected with an error rather
    than being stored and silently mangled on the next parse. No
    tracker-specific parsing or issue creation happens here; creation stays
    manual. Allowed on a completed unit as well as the current one: linking
    is bookkeeping, not a state-machine transition, so it does not carry
    `cmd_complete`'s current-unit precondition.
    """
    if len(args) < 2:
        print("error: --link requires a unit name and an issue reference", file=sys.stderr)
        return 1
    unit_name, issue_ref = args[0], args[1]
    error = _validate_issue_ref(issue_ref)
    if error:
        print(f"error: invalid issue reference {issue_ref!r}: {error}", file=sys.stderr)
        return 1
    if not SESSION_FILE.exists():
        print("error: no active session", file=sys.stderr)
        return 1
    data = _parse_session(SESSION_FILE.read_text(encoding="utf-8"))
    if not any(u["name"] == unit_name for u in data["units"]):
        print(f"error: unknown unit '{unit_name}'", file=sys.stderr)
        return 1
    _acquire_lock()
    try:
        data = _parse_session(SESSION_FILE.read_text(encoding="utf-8"))
        for u in data["units"]:
            if u["name"] == unit_name:
                u["issue"] = issue_ref
                break
        data["last_updated"] = _now()
        _atomic_write(SESSION_FILE, _render_session(data))
    finally:
        _release_lock()
    print(f"Unit '{unit_name}' linked to issue {issue_ref}.")
    return 0


def cmd_archive(args: list[str]) -> int:
    """``--archive``: move completed units out of ``session.md`` into ``session-archive.md``."""
    if not SESSION_FILE.exists():
        print("error: no active session", file=sys.stderr)
        return 1
    _acquire_lock()
    try:
        data = _parse_session(SESSION_FILE.read_text(encoding="utf-8"))
        completed = [u for u in data["units"] if u["done"]]
        if not completed:
            print("No completed units to archive.")
            return 0
        archive_lines = [f"\n## Archived {_now()}\n"]
        archive_lines.extend(_format_unit_entry(u) for u in completed)
        with ARCHIVE_FILE.open("a", encoding="utf-8") as f:
            f.write("\n".join(archive_lines) + "\n")
        data["units"] = [u for u in data["units"] if not u["done"]]
        data["last_updated"] = _now()
        _atomic_write(SESSION_FILE, _render_session(data))
    finally:
        _release_lock()
    print(f"Archived {len(completed)} unit(s) to {ARCHIVE_FILE}.")
    return 0


def main(argv: list[str] | None = None) -> int:
    """CLI entry point: dispatch ``--init``/``--status``/``--validate``/``--link``/``--complete``/``--archive``."""
    args = argv if argv is not None else sys.argv[1:]
    if not args:
        print(
            "usage: raven-session.py --init|--status|--validate|--link|--complete|--archive [args]",
            file=sys.stderr,
        )
        return 1
    cmd = args[0]
    rest = args[1:]
    if cmd == "--init":
        return cmd_init(rest)
    if cmd == "--status":
        return cmd_status(rest)
    if cmd == "--validate":
        return cmd_validate(rest)
    if cmd == "--link":
        return cmd_link(rest)
    if cmd == "--complete":
        return cmd_complete(rest)
    if cmd == "--archive":
        return cmd_archive(rest)
    print(f"error: unknown command {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
