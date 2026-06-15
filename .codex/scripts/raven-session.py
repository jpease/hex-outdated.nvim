#!/usr/bin/env python3
"""Raven session state manager for raven-project-lifecycle."""

from __future__ import annotations

import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

RAVEN_DIR = Path(".raven")
SESSION_FILE = RAVEN_DIR / "session.md"
LOCK_FILE = RAVEN_DIR / "session.lock"
ARCHIVE_FILE = RAVEN_DIR / "session-archive.md"
CONFIG_FILE = RAVEN_DIR / "config.toml"
CONTEXT_SOFT_CAP = 50


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _atomic_write(path: Path, content: str) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.rename(path)


def _parse_session(text: str) -> dict:  # type: ignore[type-arg]
    """Parse session.md into a structured dict."""
    data: dict = {  # type: ignore[type-arg]
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
        elif in_units and (m := re.match(r"- \[([ x])\] (\S+)(.*)", line)):
            done = m.group(1) == "x"
            name = m.group(2)
            rest = m.group(3)
            issue = None
            completed_at = None
            if im := re.search(r"→ (#\d+)", rest):
                issue = im.group(1)
            if cm := re.search(r"\(completed ([^)]+)\)", rest):
                completed_at = cm.group(1)
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


def _render_session(data: dict) -> str:  # type: ignore[type-arg]
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
        if u["done"]:
            entry = f"- [x] {u['name']}"
            if u.get("issue"):
                entry += f" → {u['issue']}"
            if u.get("completed_at"):
                entry += f" (completed {u['completed_at']})"
        else:
            if not current_set:
                entry = f"- [ ] {u['name']}"
                if u.get("issue"):
                    entry += f" → {u['issue']}"
                entry += " (current)"
                current_set = True
            else:
                entry = f"- [ ] {u['name']}"
                if u.get("issue"):
                    entry += f" → {u['issue']}"
        lines.append(entry)
    lines.append("")
    lines.append("## Context")
    lines.extend(data["context_lines"] if data["context_lines"] else [""])
    return "\n".join(lines) + "\n"


def cmd_init(args: list[str]) -> int:
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("project_type")
    p.add_argument("units", nargs="+")
    p.add_argument("--parent", default=None)
    ns = p.parse_args(args)

    if SESSION_FILE.exists():
        print(
            f"error: session already exists at {SESSION_FILE}. Use --status to resume.",
            file=sys.stderr,
        )
        return 1

    RAVEN_DIR.mkdir(exist_ok=True)
    data = {
        "project_type": ns.project_type,
        "started": _now(),
        "last_updated": _now(),
        "parent_issue": ns.parent,
        "units": [
            {"name": u, "done": False, "issue": None, "completed_at": None} for u in ns.units
        ],
        "context_lines": [""],
    }
    _atomic_write(SESSION_FILE, _render_session(data))
    print(f"Session initialized: {len(ns.units)} unit(s), project type '{ns.project_type}'.")
    if ns.parent:
        print(
            f"Parent issue: {ns.parent}. Create child issues manually with gh/glab and record them in session.md."
        )
    _update_gitignore()
    return 0


def _update_gitignore() -> None:
    """Append session file entries to .gitignore if not already present."""
    gitignore = Path(".gitignore")
    entries = [".raven/session.md", ".raven/session.lock", ".raven/session-archive.md"]
    existing = gitignore.read_text(encoding="utf-8") if gitignore.exists() else ""
    missing = [e for e in entries if e not in existing]
    if missing:
        block = "\n# Raven session state\n" + "\n".join(missing) + "\n"
        with gitignore.open("a", encoding="utf-8") as f:
            f.write(block)


def cmd_status(args: list[str]) -> int:
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
            f"warning: context block is {len(data['context_lines'])} lines (>{CONTEXT_SOFT_CAP}). Consider running --archive."
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


def _current_unit(data: dict) -> dict | None:  # type: ignore[type-arg]
    for u in data["units"]:
        if not u["done"]:
            return u
    return None


def cmd_validate(args: list[str]) -> int:
    if not args:
        print("error: --validate requires a unit name", file=sys.stderr)
        return 1
    unit_name = args[0]
    if not SESSION_FILE.exists():
        print("error: no active session", file=sys.stderr)
        return 1
    data = _parse_session(SESSION_FILE.read_text(encoding="utf-8"))
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


def cmd_archive(args: list[str]) -> int:
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
        for u in completed:
            entry = f"- [x] {u['name']}"
            if u.get("issue"):
                entry += f" → {u['issue']}"
            if u.get("completed_at"):
                entry += f" (completed {u['completed_at']})"
            archive_lines.append(entry)
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
    args = argv if argv is not None else sys.argv[1:]
    if not args:
        print(
            "usage: raven-session.py --init|--status|--validate|--complete|--archive [args]",
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
    if cmd == "--complete":
        return cmd_complete(rest)
    if cmd == "--archive":
        return cmd_archive(rest)
    print(f"error: unknown command {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
