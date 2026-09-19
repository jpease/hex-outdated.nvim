#!/usr/bin/env python3
"""PreToolUse hook: deny edits to secret-like paths, and warn (without blocking) on high-churn ones.

Denial output is shaped differently for Claude (stderr + exit 2) vs Codex (a
``hookSpecificOutput`` JSON payload on stdout, exit 0) -- see `_deny` and
`_is_codex_hook` -- since the two hosts expect different denial protocols.
"""

from __future__ import annotations

import fnmatch
import importlib.util
import json
import os
import os.path
import re
import sys
from importlib.machinery import SourceFileLoader
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


def _adapter_directory_name() -> str:
    """``.claude``, ``.codex``, or ``.gemini``, from the path this hook was installed at.

    Read without resolving symlinks, like ``raven-session-checkpoint.py``: in
    the template the Codex and Gemini copies are links into ``.claude/hooks/``,
    and adapter identity follows the path the host invoked, not where the bytes
    live. Anything else answers ``.claude``, the host that supports the most.
    """
    try:
        name = Path(os.path.abspath(__file__)).parents[1].name
    except IndexError:
        return ".claude"
    return name if name in {".claude", ".codex", ".gemini"} else ".claude"


def _project_root() -> Path:
    """Two parents above ``<root>/.claude/hooks/`` (or ``.codex/hooks/``)."""
    return Path(__file__).resolve().parents[2]


def _raven_config_module():
    path = _project_root() / ".raven" / "git-hooks" / "lib" / "raven_config.py"
    spec = importlib.util.spec_from_file_location(
        "raven_config_for_edit_guard",
        path,
        loader=SourceFileLoader("raven_config_for_edit_guard", str(path)),
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load raven_config from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_QUOTED = re.compile(r'"((?:[^"\\]|\\.)*)"|\'([^\']*)\'')


def parse_protected_paths(text: str) -> tuple[list[str], str]:
    """``[edit_guard]`` from raw config text: (patterns, decision).

    ``protected_paths`` is a TOML array of strings; each is an ``fnmatch``
    glob against the edited path relative to the repository root, where ``*``
    crosses directory separators, so ``migrations/*`` covers the whole tree
    beneath it. ``protected_paths_decision`` is ``"ask"`` (default) or
    ``"warn"``. Issue #247: the Pause-And-Ask categories in ``AGENTS.md`` are
    prose, and this is the backstop for the ones a project can spell as paths.
    """
    try:
        raven_config = _raven_config_module()
    except (ImportError, OSError):
        return [], "ask"
    section = raven_config.parse_config_text(text).get("edit_guard", {})
    raw = section.get("protected_paths", "")
    patterns = [a or b for a, b in _QUOTED.findall(raw) if (a or b)]
    decision = section.get("protected_paths_decision", "").strip().strip("\"'").lower()
    return patterns, decision if decision in {"ask", "warn"} else "ask"


def read_protected_paths() -> tuple[list[str], str]:
    """``[edit_guard]`` from the install's ``.raven/config.toml``; empty when absent."""
    try:
        text = (_project_root() / ".raven" / "config.toml").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return [], "ask"
    return parse_protected_paths(text)


def relative_to_root(path: str, root: Path) -> str:
    """``path`` relative to ``root`` when it lies inside it; otherwise as given."""
    normalized = os.path.normpath(path.replace("\\", "/"))
    if not os.path.isabs(normalized):
        return normalized
    try:
        return os.path.relpath(normalized, str(root))
    except ValueError:
        return normalized


def matching_protected_pattern(relative: str, patterns: list[str]) -> str | None:
    """The first pattern ``relative`` matches, anchored at the root or any directory below it."""
    for pattern in patterns:
        if fnmatch.fnmatch(relative, pattern) or fnmatch.fnmatch(relative, f"*/{pattern}"):
            return pattern
    return None


def _context(message: str, payload: dict | None = None) -> None:
    """Add ``message`` to the agent's context without blocking, on any host."""
    if payload is not None and _is_gemini_hook(payload):
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
        return
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


def _ask(message: str) -> None:
    """Escalate the edit to the user. Claude Code only; Codex has no ``ask`` yet."""
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "ask",
                    "permissionDecisionReason": message,
                }
            }
        )
    )


# Hoisted to module level (rather than a local inside `main()`) so tests --
# and the native `permissions.deny` drift check in particular -- can read the
# real deny/warn tiers instead of restating them. Zero behavior change: same
# lists, same order, just reachable from outside `main()`.
BLOCKED = [
    r"\.pem$",
    r"\.key$",
    r"\.p12$",
    r"\.pfx$",
    r"\.crt$",
    r"\.cer$",
    # `.env` is the spelling projects use *least* for real values: the committed
    # template is `.env.example` and the secrets live in `.env.local`,
    # `.env.production`, `.env.development`. `.envrc` (direnv) is a shell script
    # that commonly exports them (issue #213).
    r"(^|/)\.env(\.[^/]*)?$",
    r"(^|/)\.envrc$",
    # Anchored to a path segment: a bare `secrets` substring also blocks
    # `docs/how-we-handle-secrets.md` and any `test_secrets_helper.py`.
    r"(^|/)secrets?(\.|/|$)",
    # Anchored to a path segment, same shape as `secrets` above: a bare
    # `credentials` substring also blocked `docs/credentials-design.md`,
    # `tests/test_credentials_helper.py`, and `src/credentialsProvider.ts`
    # (issue #197).
    r"(^|/)credentials?(\.|/|$)",
]
CAUTION = [
    r"/migrations/",
    r"/generated/",
    r"package-lock\.json$",
    r"Cargo\.lock$",
    r"pnpm-lock\.yaml$",
]


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
    """Read the hook payload from stdin and deny or warn based on the edited path."""
    payload = _load_payload()
    if payload is None:
        return 0

    path = _extract_path(payload)
    if not path:
        return 0

    # Collapse `..` traversal lexically (no filesystem access -- this must stay
    # fast and side-effect-free, unlike Path.resolve()) *after* the backslash
    # swap, so Windows-style input (`src\..\.env`) normalizes the same as
    # POSIX input. os.path.normpath never introduces a leading "./" for a
    # plain relative path on a POSIX host, so it does not break the `(^|/)`
    # anchors below (verified: normpath("docs/credentials-design.md") ==
    # "docs/credentials-design.md", normpath(".env") == ".env").
    normalized = os.path.normpath(path.replace("\\", "/"))

    if any(re.search(pattern, normalized, re.IGNORECASE) for pattern in BLOCKED):
        return _deny(f"Protected file path. Confirm intent before editing: {path}", payload)

    patterns, decision = read_protected_paths()
    if patterns:
        relative = relative_to_root(path, _project_root())
        pattern = matching_protected_pattern(relative, patterns)
        if pattern is not None:
            message = (
                f"{relative} matches `{pattern}` in .raven/config.toml [edit_guard] "
                "protected_paths. Pause and ask before editing it unless the user "
                "already approved this change."
            )
            if decision == "ask" and _adapter_directory_name() == ".claude":
                _ask(message)
            else:
                _context(message, payload)
            return 0

    if any(re.search(pattern, normalized, re.IGNORECASE) for pattern in CAUTION):
        _context(
            f"High-churn or generated/protected path. Edit only when required: {path}", payload
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
