#!/usr/bin/env python3

"""Emit a capability roster into session context at session start.

Ships beside raven-tool-check.py in the adapter's scripts/ directory, and
loads it as a sibling module rather than duplicating its probe primitives.
Named adapter-neutrally on purpose: one file serves both the Claude and Codex
adapters, so naming either one here would be wrong in the other.

Probes inline rather than caching. Probing all recommended tools costs about
3 ms because the prober short-circuits to ``shutil.which`` unless
``RAVEN_TOOL_CHECK_EXECUTE=1``; a cache plus a background refresh would have
cost a second ~140 ms interpreter start to defer that. See
docs/superpowers/specs/2026-08-11-session-capability-roster-design.md.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any

PROBER_FILENAME = "raven-tool-check.py"
SESSION_FILENAME = "raven-session.py"
INDENT = "  "
LABEL_WIDTH = 9

SAFE_IDENTIFIER = re.compile(r"\A[A-Za-z0-9._-]{1,64}\Z")
# Control characters, including the ESC that starts an ANSI escape sequence.
_CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f-\x9f]")
MAX_FREE_TEXT = 60
SAFE_SHA = re.compile(r"\A[0-9a-f]{7,40}\Z")
MAX_ROSTER_BYTES = 4096

TRACKER_CLIS = {"github": "gh", "gitlab": "glab"}

GIT_TIMEOUT_SECONDS = 5


def _load_sibling(module_name: str, path: Path) -> Any:
    """Import a Raven script from an explicit path under a private module name.

    The loader is passed explicitly so an extensionless or hyphenated script
    loads too, which ``spec_from_file_location`` alone will not do.
    """
    spec = importlib.util.spec_from_file_location(
        module_name, path, loader=SourceFileLoader(module_name, str(path))
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_prober(scripts_dir: Path) -> Any:
    """Import the sibling tool-check script for its probe primitives.

    Uses ``__file__``-relative resolution, never ``sys.argv[0]``: the Codex
    launcher invokes hooks through ``runpy.run_path`` with a relative path.
    """
    return _load_sibling("raven_tool_check_for_roster", scripts_dir / PROBER_FILENAME)


def load_raven_config(scripts_dir: Path) -> Any:
    """Import ``.raven/git-hooks/lib/raven_config.py`` for the shared config parser.

    Same shape as ``load_prober`` above, and resolved the same way:
    ``scripts_dir`` is this script's own directory, whichever adapter it was
    installed under, two levels below the project root, and
    ``raven_config.py`` ships two levels up from there in the same "hooks"
    component -- independent of the ``root`` argument ``read_config_keys``
    takes, which names the repo whose ``.raven/config.toml`` is actually
    being read (a test fixture can point that at an isolated directory
    without needing a full install alongside it).
    """
    path = scripts_dir.parent.parent / ".raven" / "git-hooks" / "lib" / "raven_config.py"
    return _load_sibling("raven_config_for_roster", path)


def resolve_repo_root_for_payload(payload: dict | None, start: Path) -> Path | None:
    """Find the repository root without trusting the process cwd.

    Codex Desktop can invoke a hook with a cwd outside the project, so the
    hook payload's ``cwd`` takes precedence when present.

    Named distinctly from -- and delegates its walk to -- the shared
    ``raven_config.resolve_repo_root(start) -> Path`` (issue #202): that
    function never returns ``None`` (it falls back to ``start`` itself), but
    ``build_roster`` uses ``None`` here to mean "no repo found at all," which
    skips every repo-specific roster section (template, gates, MCP servers,
    tracker, index). Keeping this a separate name avoids two functions
    called ``resolve_repo_root`` with different signatures and different
    ``None`` semantics silently shadowing one another in the same file.
    ``None`` is re-derived after the shared walk by checking whether its
    answer actually carries a ``.git``/``.raven`` marker, rather than just
    equaling the un-resolved ``start`` it fell back to -- also widening this
    caller from ``.git``-only to the same ``.git``-or-``.raven`` semantics
    every other rewired call site now shares.
    """
    candidate = start
    if isinstance(payload, dict):
        raw = payload.get("cwd")
        if isinstance(raw, str) and raw:
            candidate = Path(raw)
    try:
        candidate = candidate.resolve()
    except OSError:
        return None
    raven_config = load_raven_config(Path(__file__).resolve().parent)
    found = raven_config.resolve_repo_root(candidate)
    if (found / ".git").exists() or (found / ".raven").is_dir():
        return found
    return None


def read_payload() -> dict | None:
    """Read the hook's stdin payload, tolerating absence or malformed JSON."""
    if sys.stdin is None or sys.stdin.isatty():
        return None
    try:
        raw = sys.stdin.read()
    except (OSError, ValueError):
        return None
    if not raw.strip():
        return None
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return decoded if isinstance(decoded, dict) else None


def _line(label: str, value: str) -> str:
    return f"{INDENT}{label.ljust(LABEL_WIDTH)}  {value}"


def sanitize_identifier(value: object) -> str | None:
    """Return the value if it is a safe bare identifier, else None.

    Dropped rather than escaped: an escaped hostile string still occupies
    context and still reads as content. The caller renders a dropped count.
    """
    if not isinstance(value, str):
        return None
    return value if SAFE_IDENTIFIER.match(value) else None


def sanitize_sha(value: object) -> str | None:
    """A value if it looks like a git sha, else None -- dropped, not escaped, if unsafe."""
    if not isinstance(value, str):
        return None
    return value if SAFE_SHA.match(value) else None


def sanitize_free_text(value: object) -> str | None:
    """Clean a free-text field for the roster, or None when nothing survives.

    Unlike `sanitize_identifier`, which drops anything unexpected, this keeps
    the value: a unit name legitimately holds spaces and punctuation, and
    dropping it would hide the state the line exists to report. Control
    characters go (an ANSI sequence would paint the roster), runs of
    whitespace collapse to one space, and the result is capped so a long name
    cannot crowd out the rest of the roster.
    """
    if not isinstance(value, str):
        return None
    cleaned = " ".join(_CONTROL_CHARS.sub("", value).split())
    if not cleaned:
        return None
    if len(cleaned) > MAX_FREE_TEXT:
        cleaned = cleaned[:MAX_FREE_TEXT].rstrip() + "…"
    return cleaned


def read_session_units(root: Path, scripts_dir: Path) -> list | None:
    """Parse `.raven/session.md` into unit dicts, or None when there is nothing to report.

    Reuses `raven-session.py`'s own parser as a sibling module rather than
    re-deriving session.md's line shapes here -- the same reason this script
    loads the prober instead of copying its probes. Any failure (no session,
    unreadable file, a `raven-session.py` that will not import) yields None:
    a SessionStart hook that cannot read optional state must stay quiet.
    """
    try:
        text = (root / ".raven" / "session.md").read_text(encoding="utf-8")
        manager = _load_sibling("raven_session_for_roster", scripts_dir / SESSION_FILENAME)
        units = manager._parse_session(text)["units"]
    except Exception:  # noqa: BLE001 -- optional state; see main()'s boundary
        return None
    return units or None


def render_session_line(root: Path, scripts_dir: Path | None = None) -> str | None:
    """Render the in-progress unit of work, or None when no session is tracked.

    Compaction keeps the narrative of a session and drops its bookkeeping, yet
    `AGENTS.md` asks the agent to restate the current goal after compaction.
    `SessionStart` re-fires with source `compact`, so this line is where that
    fact comes back -- and it costs nothing in a repo that tracks no session.
    """
    units = read_session_units(root, scripts_dir or Path(__file__).resolve().parent)
    if units is None:
        return None
    done = sum(1 for unit in units if unit.get("done"))
    value = f"{done}/{len(units)} complete"
    pending = [unit for unit in units if not unit.get("done")]
    if pending:
        name = sanitize_free_text(pending[0].get("name"))
        issue = sanitize_identifier(str(pending[0].get("issue") or "").lstrip("#"))
        if name:
            value += f" · current: {name}"
            if issue:
                value += f" → #{issue}"
    return _line("Session", value)


def cap_roster(text: str) -> str:
    """Bound total roster size so no input can produce an unbounded block."""
    encoded = text.encode("utf-8")
    if len(encoded) <= MAX_ROSTER_BYTES:
        return text
    clipped = encoded[:MAX_ROSTER_BYTES].decode("utf-8", errors="ignore")
    return clipped + "\n  … roster truncated\n"


def render_mcp_line(names: list) -> str:
    """Render the MCP line from repo-controlled server names."""
    safe = [name for name in (sanitize_identifier(n) for n in names) if name]
    dropped = len(names) - len(safe)
    value = " ".join(sorted(safe)) if safe else "—"
    if dropped:
        value += f"  ({dropped} dropped)"
    return _line("MCP (cfg)", value)


def read_config_keys(root: Path) -> dict:
    """Read `template` and `[issue_tracker].platform` from .raven/config.toml.

    A deliberately minimal two-key reader built on the shared
    ``.raven/git-hooks/lib/raven_config.py`` parser: the real parser in
    scripts/raven_lib/config.py does not ship to a destination repository.
    Missing file, missing section, missing key, and an unreadable file (the
    shared module's ``RavenConfigError``) all fall back to the same
    ``{"template": None, "platform": None}`` this always returned.
    """
    keys: dict = {"template": None, "platform": None}
    raven_config = load_raven_config(Path(__file__).resolve().parent)
    path = root / ".raven" / "config.toml"
    try:
        parsed = raven_config.read_config(path)
    except raven_config.RavenConfigError:
        return keys
    if parsed is None:
        return keys
    raw_template = parsed.get("", {}).get("template")
    if raw_template is not None:
        keys["template"] = raw_template.strip('"') or None
    raw_platform = parsed.get("issue_tracker", {}).get("platform")
    if raw_platform is not None:
        keys["platform"] = raw_platform.strip('"') or None
    return keys


def render_tracker_line(platform: object, present) -> str | None:
    """Render the tracker CLI line, or None when not applicable."""
    safe = sanitize_identifier(platform)
    cli = TRACKER_CLIS.get(safe or "")
    if cli is None:
        return None
    return _line("Tracker", f"{cli} {'✓' if present(cli) else '✗'}")


def read_gate_tools(root: Path) -> list:
    """Read the installer-resolved gate tools from .raven/manifest.json."""
    try:
        raw = json.loads((root / ".raven" / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return []
    tools = raw.get("gateTools") if isinstance(raw, dict) else None
    return tools if isinstance(tools, list) else []


def render_gates_line(tools: list, present) -> str | None:
    """Render gate tools with availability marks, or None when empty."""
    safe = [name for name in (sanitize_identifier(t) for t in tools) if name]
    if not safe:
        return None
    marks = "  ".join(f"{name} {'✓' if present(name) else '✗'}" for name in safe)
    return _line("Gates", marks)


def run_git(root: Path, args: list) -> str | None:
    """Run a git command in `root`, returning stdout or None on any failure."""
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=str(root),
            capture_output=True,
            text=True,
            check=False,
            timeout=GIT_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def read_index_meta(root: Path) -> dict | None:
    """Read .gitnexus/meta.json, or None if absent or shaped unexpectedly.

    schemaVersion is an unversioned external contract, so a meta file
    without the fields we render yields None rather than placeholders.
    """
    try:
        raw = json.loads((root / ".gitnexus" / "meta.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(raw, dict):
        return None
    stats = raw.get("stats")
    if not isinstance(stats, dict) or "nodes" not in stats or "files" not in stats:
        return None
    return raw


#: Returned when git could not answer, so "checked and current" and "could not
#: check" do not render identically. Reporting an unanswered check as `current`
#: asserts freshness nothing verified, which matters because the managed
#: guidance requires impact analysis against this index before a symbol edit.
STALENESS_UNKNOWN = "unknown"


def index_staleness(root: Path, meta: dict, run_git) -> str | None:
    """Return a staleness reason, ``STALENESS_UNKNOWN``, or None when current.

    Checks committed and uncommitted drift. A commit-only check reports a
    dirty tree as current -- the common case and the one that matters.
    """
    head = run_git(["rev-parse", "HEAD"])
    if head is None:
        return STALENESS_UNKNOWN
    indexed = sanitize_sha(meta.get("lastCommit"))
    head_sha = sanitize_sha(head)
    if indexed and head_sha and indexed != head_sha:
        return f"indexed {indexed[:7]}, HEAD {head_sha[:7]}"
    status = run_git(["status", "--porcelain"])
    if status is None:
        return STALENESS_UNKNOWN
    return "working tree modified" if status.strip() else None


def render_index_line(meta: dict | None, verdict: str | None) -> str | None:
    """Render the "Index" roster line from GitNexus metadata, or None if absent/malformed."""
    if meta is None:
        return None
    stats = meta["stats"]
    nodes, files = stats.get("nodes"), stats.get("files")
    if not isinstance(nodes, int) or not isinstance(files, int):
        return None
    if verdict is None:
        state = "current"
    elif verdict == STALENESS_UNKNOWN:
        state = "freshness UNKNOWN (git did not answer)"
    else:
        state = f"STALE ({verdict})"
    return _line("Index", f"gitnexus · {nodes} nodes / {files} files · {state}")


def render_roster(
    *,
    probed_on: str,
    template: str | None,
    tool_results: list[dict],
    do_not_remind: bool,
    mcp_servers: list | None = None,
    tracker_line: str | None = None,
    gates_line: str | None = None,
    index_line: str | None = None,
    session_line: str | None = None,
) -> str:
    """Format the roster. Pure: no I/O, no probing."""
    available = [r for r in tool_results if r.get("available")]
    required_absent, optional_absent, unverified = _gap_lines(tool_results)

    header = f"=== RAVEN CAPABILITIES ===  probed {probed_on}"
    safe_template = sanitize_identifier(template)
    if safe_template:
        header += f" · template: {safe_template}"
    lines = [header]

    if available:
        lines.append(_line("CLI", " ".join(str(r["name"]) for r in available)))
    if gates_line:
        lines.append(gates_line)
    if mcp_servers:
        lines.append(render_mcp_line(mcp_servers))
    if tracker_line:
        lines.append(tracker_line)
    if index_line:
        lines.append(index_line)
    if session_line:
        lines.append(session_line)

    if not do_not_remind:
        if required_absent:
            lines.extend(_entry_lines("Absent", required_absent))
        else:
            lines.append(_line("Absent", "—"))
        if optional_absent:
            names = " ".join(sorted(str(r["name"]) for r in optional_absent))
            lines.append(_line("Optional", names))
        if unverified:
            lines.extend(_entry_lines("Unverified", unverified))

    return cap_roster("\n".join(lines) + "\n")


def _gap_lines(tool_results: list[dict]) -> tuple[list[dict], list[dict], list[dict]]:
    """Split not-available results into required-absent, optional-absent, and unverified.

    A timed-out result is unverified regardless of optionalWhen -- its
    availability is unknown, not confirmed missing, so it never joins the
    optional-absent collapse.
    """
    required_absent, optional_absent, unverified = [], [], []
    for result in tool_results:
        if result.get("available"):
            continue
        if result.get("source") == "timed-out":
            unverified.append(result)
        elif result.get("optionalWhen"):
            optional_absent.append(result)
        else:
            required_absent.append(result)
    return required_absent, optional_absent, unverified


def _entry_lines(label: str, results: list[dict]) -> list[str]:
    """Render one `name — purpose` entry per line, hanging-indented under the label.

    Used for required-absent and unverified tools, where the reader has no
    fallback and needs the full purpose string to judge the gap. Optional-absent
    tools skip this in favor of a single name-only Optional line -- something
    else already covers the work, so the reasoning lives only in TOOLS.
    """
    lines = []
    pad = INDENT + " " * (LABEL_WIDTH + 2)
    for index, result in enumerate(results):
        text = f"{result['name']} — {result.get('purpose', '')}".rstrip(" —")
        lines.append(_line(label, text) if index == 0 else f"{pad}{text}")
    return lines


def build_roster(root: Path | None, prober: Any) -> str:
    """Probe and render. Separated from main() so tests can force a failure."""
    results = prober.check_all_tools(prober.os_key(), root=root)
    memory = prober.load_memory()
    do_not_remind = bool(memory.get("preferences", {}).get("doNotRemind"))
    probed_on = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    template = None
    mcp_servers: list = []
    tracker_line = None
    gates_line = None
    index_line = None
    session_line = None
    if root is not None:
        keys = read_config_keys(root)
        template = keys["template"]
        claude_mcp = getattr(prober, "_claude_mcp_server_names_from_config", lambda r: set())(root)
        codex_mcp = getattr(prober, "_codex_mcp_server_names_from_config", lambda r: set())(root)
        gemini_mcp = getattr(prober, "_gemini_mcp_server_names_from_config", lambda r: set())(root)
        mcp_servers = sorted(claude_mcp | codex_mcp | gemini_mcp)
        tracker_line = render_tracker_line(
            keys["platform"], present=lambda cli: prober.command_works([cli, "--version"])
        )
        gates_line = render_gates_line(
            read_gate_tools(root), present=lambda tool: prober.command_works([tool, "--version"])
        )
        meta = read_index_meta(root)
        if meta is not None:
            verdict = index_staleness(root, meta, run_git=lambda args: run_git(root, args))
            index_line = render_index_line(meta, verdict)
        session_line = render_session_line(root)

    return render_roster(
        probed_on=probed_on,
        template=template,
        tool_results=results,
        do_not_remind=do_not_remind,
        mcp_servers=mcp_servers,
        tracker_line=tracker_line,
        gates_line=gates_line,
        index_line=index_line,
        session_line=session_line,
    )


def main() -> int:
    """CLI/hook entry point: build and print the roster, always exiting 0.

    Any exception during roster assembly is swallowed rather than reported --
    see the ``except`` block below for why a crashing SessionStart hook is
    worse than a silently missing roster.
    """
    parser = argparse.ArgumentParser(
        description="Emit a Raven capability roster for the current session."
    )
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    args = parser.parse_args()

    try:
        payload = read_payload()
        root = resolve_repo_root_for_payload(payload, Path.cwd())
        prober = load_prober(Path(__file__).resolve().parent)
        text = build_roster(root, prober)
        if args.json:
            print(json.dumps({"roster": text}, indent=2))
        elif payload is not None and (
            "GEMINI_PROJECT_DIR" in os.environ
            or (
                payload.get("hook_event_name") in ("BeforeTool", "AfterTool", "SessionStart")
                and ("transcript_path" in payload or "session_id" in payload)
            )
        ):
            print(json.dumps({"systemMessage": text}))
        else:
            sys.stdout.write(text)
    except Exception:  # noqa: BLE001 -- deliberate last-resort boundary, see spec's Error Handling
        # A hook that crashes noisily costs context every session and trains
        # the user to ignore hook output. Silence is the correct failure.
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
