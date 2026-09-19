#!/usr/bin/env python3

"""Raven skeleton-first read gate (rung 2).

A Claude Code ``PreToolUse`` hook for ``Read``. When enabled in
``.raven/config.toml``, it denies *unbounded* reads of large supported-language
files and points the agent at the ``raven-skeleton`` helper so it fetches a
symbol map and reads only the ranges it needs.

Opt-in and default off: absent or unset config means the gate never fires.
Self-contained: standard library only.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

DEFAULT_THRESHOLD = 500

# Extensions the raven-skeleton ast-grep backend can produce a skeleton for.
# Keep in sync with the languages raven-skeleton.py supports via ast-grep --
# its NODE_KINDS table plus STRUCTURAL_RULES (Elixir is handled by a structural
# rule). Gating an extension the helper cannot skeletonize would point the agent
# at a helper that returns nothing.
SUPPORTED_EXTENSIONS = {
    ".py",
    ".ts",
    ".tsx",
    ".js",
    ".jsx",
    ".go",
    ".rs",
    ".swift",
    ".lua",
    ".ex",
    ".exs",
}


def _raven_config_module():
    """Import ``.raven/git-hooks/lib/raven_config.py`` for its quote-aware
    comment stripping and boolean parsing.

    Resolved relative to this script's own installed location -- two levels
    up from ``.claude/hooks/`` is the project root, and ``raven_config.py``
    ships alongside this hook in the same "hooks" component -- not the
    process cwd, so this keeps working regardless of where the hook is
    invoked from. Same ``spec_from_file_location`` + ``SourceFileLoader``
    mechanism ``load_prober`` in ``raven-capability-roster.py`` already uses
    to reach a sibling script.
    """
    path = Path(__file__).resolve().parents[2] / ".raven" / "git-hooks" / "lib" / "raven_config.py"
    spec = importlib.util.spec_from_file_location(
        "raven_config_for_skeleton_guard",
        path,
        loader=SourceFileLoader("raven_config_for_skeleton_guard", str(path)),
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load raven_config from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def parse_gate_config(text: str) -> tuple[bool, int]:
    """Parse the opt-in gate config from the ``[skeleton]`` table of raw
    ``.raven/config.toml`` text.

    Returns ``(enabled, threshold)``. Default off with the default threshold.
    Only assignments inside the ``[skeleton]`` table are honored; keys in other
    tables (including the implicit root table), comments, and similarly named
    keys have no effect. A section-aware line scan keeps the walk order and
    per-key precedence exactly as before; only the per-line comment stripping
    and boolean coercion are delegated to the shared
    ``.raven/git-hooks/lib/raven_config.py`` module, which strips a ``#``
    comment correctly even inside a quoted value (the old
    ``line.split("#", 1)[0]`` here did not). Malformed values fall back to the
    documented safe defaults without raising: a non-boolean ``read_gate``
    keeps the prior value and a non-integer threshold keeps the prior
    threshold.
    """
    raven_config = _raven_config_module()
    enabled = False
    threshold = DEFAULT_THRESHOLD
    section: str | None = None
    for raw in text.splitlines():
        line = raven_config.strip_comment(raw)
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if section != "skeleton" or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if key == "read_gate":
            parsed = raven_config.parse_bool(value)
            if parsed is not None:
                enabled = parsed
        elif key == "read_gate_threshold_lines" and value.isdigit():
            threshold = int(value)
    return (enabled, threshold)


def is_unbounded_read(tool_input: dict) -> bool:
    """A read with neither offset/limit (Claude) nor start_line/end_line (Gemini) pulls the whole file."""
    has_bounds = (
        bool(tool_input.get("offset"))
        or bool(tool_input.get("limit"))
        or bool(tool_input.get("start_line"))
        or bool(tool_input.get("end_line"))
    )
    return not has_bounds


#: Backends `raven-skeleton.py` can build a symbol map with. The gate denies a
#: read only when one of these resolves: without a backend the helper it points
#: at returns "No skeleton available", so the denial would send the reader to a
#: dead end instead of a cheaper path.
SKELETON_BACKENDS = ("ast-grep", "rg")


def skeleton_backend_available() -> bool:
    """Whether any backend the skeleton helper uses resolves on this machine."""
    return any(shutil.which(binary) for binary in SKELETON_BACKENDS)


def should_gate(
    tool_input: dict,
    line_count: int,
    *,
    enabled: bool,
    threshold: int,
    supported: bool,
    backend_available: bool = True,
) -> bool:
    """Deny only when the gate is on, the file is a supported language, the read
    is unbounded, the file is at least ``threshold`` lines, and the skeleton
    helper can actually produce a map. Everything else passes through.
    """
    if not enabled:
        return False
    if not supported or not backend_available:
        return False
    if not is_unbounded_read(tool_input):
        return False
    return line_count >= threshold


def is_supported(path: str) -> bool:
    """Whether ``path``'s extension is one `raven-skeleton` can produce a real skeleton for."""
    _, ext = os.path.splitext(path)
    return ext.lower() in SUPPORTED_EXTENSIONS


def _line_count(path: str) -> int:
    with open(path, "rb") as handle:
        return sum(1 for _ in handle)


def _gate_config() -> tuple[bool, int]:
    """Read and parse the gate config, failing safe (gate off) on any read error.

    Previously this had no ``try``/``except`` around ``read_text()`` at all: a
    present-but-unreadable config (e.g. bad permissions) propagated an
    uncaught ``OSError`` out of the hook. That was never an intentional
    failure semantic -- every other read failure in this hook fails safe --
    so it is fixed here rather than preserved, matching the missing-file case
    just above it.
    """
    config = Path(".raven/config.toml")
    if not config.exists():
        return (False, DEFAULT_THRESHOLD)
    try:
        text = config.read_text(encoding="utf-8")
    except OSError:
        return (False, DEFAULT_THRESHOLD)
    return parse_gate_config(text)


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


def _is_gemini_hook(payload: dict) -> bool:
    if "GEMINI_PROJECT_DIR" in os.environ:
        return True
    event = payload.get("hook_event_name")
    if event in ("BeforeTool", "AfterTool"):
        return True
    tool = payload.get("tool_name")
    return tool in ("run_shell_command", "read_file", "write_file", "replace")


def _is_codex_hook(payload: dict) -> bool:
    return "hook_event_name" in payload or "tool_name" in payload


def _deny(message: str, payload: dict) -> int:
    if _is_gemini_hook(payload):
        print(json.dumps({"decision": "deny", "reason": message}))
        return 0
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
    """Read the hook payload from stdin and deny an unbounded large-file read, if the gate applies."""
    payload = _load_payload()
    if payload is None:
        return 0
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return 0

    enabled, threshold = _gate_config()
    if not enabled:
        return 0

    path = tool_input.get("file_path") or tool_input.get("path") or ""
    if not path or not is_supported(path) or not is_unbounded_read(tool_input):
        return 0
    if not os.path.isfile(path):
        return 0

    if not should_gate(
        tool_input,
        _line_count(path),
        enabled=enabled,
        threshold=threshold,
        supported=True,
        backend_available=skeleton_backend_available(),
    ):
        return 0

    return _deny(
        f"Skeleton-first read gate: {path} is large. Get a symbol map first with the "
        "raven-skeleton helper (.claude/scripts/raven-skeleton.py <file>), then Read only "
        "the ranges you need, or pass offset/limit for a bounded read. See the "
        "raven-skeleton skill.",
        payload,
    )


if __name__ == "__main__":
    raise SystemExit(main())
