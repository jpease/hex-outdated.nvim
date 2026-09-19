#!/usr/bin/env python3
"""PreToolUse hook: validate raven-session.py --complete before allowing."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

# This file is shared byte-for-byte between the Claude and Codex adapters (the
# `.codex/hooks/raven-session-checkpoint.py` copy is a template-internal symlink
# to this one, issue #195). It used to be two near-identical real files that
# each hardcoded their own adapter's scripts directory in the subprocess.run
# call below; that let the Claude copy gain a bugfix (the isinstance guard in
# _load_payload) without the Codex copy ever being touched. Computing the
# adapter directory from this script's own install path -- the same pattern
# `raven-tool-check.py` already uses for the identical problem -- makes that
# drift structurally impossible instead of relying on a reviewer to catch it.
_ADAPTER_DIRECTORY_NAMES = frozenset({".claude", ".codex", ".gemini"})
_DEFAULT_ADAPTER_DIRECTORY_NAME = ".claude"


def _adapter_directory_from_install_layout() -> Path | None:
    """The ``.claude``/``.codex`` directory this script was installed under.

    Raven installs this hook at ``<root>/.claude/hooks/`` or
    ``<root>/.codex/hooks/``, so the adapter directory is the second parent and
    the project root is its parent. Returns ``None`` when the script runs from
    a location that does not match that layout.

    The path is made absolute *without* resolving symlinks. Adapter identity is
    a property of the path this script was invoked through, not of where its
    bytes physically live -- in the template, ``.codex/hooks/`` entries are
    symlinks into the ``.claude/hooks/`` copies. Following the link before
    inspecting `parents` would make the Codex copy answer ``.claude`` too.
    Installed destinations hold real files, where the two spellings agree.
    """
    try:
        script = Path(os.path.abspath(__file__))
    except (NameError, OSError):
        return None
    parents = script.parents
    if len(parents) >= 3 and parents[1].name in _ADAPTER_DIRECTORY_NAMES:
        return parents[1]
    return None


def adapter_directory_name() -> str:
    """Adapter directory this hook's own ``raven-session.py`` sibling lives under.

    Falls back to ``.claude`` when the install layout gives no answer: no
    adapter can be inferred at that point, and the Claude tree is both the
    canonical copy and the more common install, so it is the least-wrong guess
    for a path this function's only caller is about to invoke.
    """
    adapter = _adapter_directory_from_install_layout()
    return adapter.name if adapter is not None else _DEFAULT_ADAPTER_DIRECTORY_NAME


def _root_from_install_layout() -> Path | None:
    """Project root implied by this script's own install path.

    One line on top of ``_adapter_directory_from_install_layout()``: the
    project root is that adapter directory's parent. Returns ``None`` when
    the script runs from a location that does not match the install layout,
    so the caller can fall back to the process cwd.
    """
    adapter = _adapter_directory_from_install_layout()
    return adapter.parent if adapter is not None else None


def _root_from_cwd() -> Path | None:
    """Nearest enclosing project directory at or above the process cwd.

    Delegates the walk to the shared ``.raven/git-hooks/lib/raven_config.py``
    module's ``resolve_repo_root`` (issue #202) rather than duplicating it.
    """
    try:
        cwd = Path.cwd().resolve()
    except OSError:
        return None
    try:
        return _raven_config_module().resolve_repo_root(cwd)
    except (ImportError, OSError):
        # Bootstrap edge case: this branch only runs once
        # _root_from_install_layout() has already failed to find where this
        # checkout lives, and _raven_config_module() (see its own docstring)
        # needs exactly that answer to locate its sibling raven_config.py.
        # When it still can't be found from here, fall back to the walk
        # inline -- project_root() must never raise, and there is no way to
        # ask the shared module where it is without already knowing where
        # this script is. This is the one duplicate this refactor cannot
        # fully remove.
        for candidate in (cwd, *cwd.parents):
            if (candidate / ".git").exists() or (candidate / ".raven").is_dir():
                return candidate
        return cwd


def project_root() -> Path:
    """Project root every repo-relative lookup in this hook is anchored to.

    A hook's process working directory is not reliably the project: Codex
    Desktop can invoke a hook with a cwd outside the worktree, and its
    launcher (``CANONICAL_CODEX_LAUNCHER`` in tests/test_agent_hooks.py) runs
    this script through ``runpy`` without ever calling ``os.chdir()``, so
    ``Path.cwd()`` is the wrong anchor for ``.raven/session.md``,
    ``.raven/config.toml``, or the validator script path. Prefer this
    script's own install location, which is inside the project by
    construction, and fall back to walking up from cwd only when that
    layout can't be inferred (e.g. a test loading this module from a
    non-standard location). Same shape as ``raven-tool-check.py``'s
    ``project_root()``, minus the ``@lru_cache``: that script memoizes
    because it is called from many places in one long-lived process; this
    hook computes it once per fresh, single-shot invocation, so caching
    would save nothing.
    """
    return _root_from_install_layout() or _root_from_cwd() or Path(".")


def _raven_config_module():
    """Import ``.raven/git-hooks/lib/raven_config.py`` for its quote-aware
    comment stripping and boolean parsing.

    Resolved via ``_root_from_install_layout()`` -- this script's own
    install-derived root -- not the ``root`` argument ``_enforcement_enabled``
    receives: those are different concerns. ``root`` there says which repo's
    ``.raven/config.toml`` to read (tests point it at an isolated fixture).
    Also deliberately not the full ``project_root()``: ``_root_from_cwd()``
    (one of ``project_root()``'s own fallback branches) calls this function
    to reach ``resolve_repo_root``, so routing this lookup through
    ``project_root()`` would recurse into ``_root_from_cwd()`` a second time
    before the first call ever returns. Falls back to ``Path(".")`` --
    matching ``project_root()``'s own ultimate fallback -- when the install
    layout can't be inferred either, since at that point there is no
    reliable answer left to try.
    This always resolves to the sibling ``raven_config.py`` shipped next to
    this hook's own installed copy, in the same "hooks" component. Same
    ``spec_from_file_location`` + ``SourceFileLoader`` mechanism
    ``load_prober`` in ``raven-capability-roster.py`` uses for the same kind
    of sibling-script import.
    """
    root = _root_from_install_layout() or Path(".")
    path = root / ".raven" / "git-hooks" / "lib" / "raven_config.py"
    spec = importlib.util.spec_from_file_location(
        "raven_config_for_checkpoint",
        path,
        loader=SourceFileLoader("raven_config_for_checkpoint", str(path)),
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load raven_config from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _load_payload() -> dict | None:  # type: ignore[type-arg] -- host JSON, shape varies
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return None
    # Valid JSON of the wrong shape (a list, a bare string, a number) is still
    # unusable: returning it would break the `dict` contract below and raise on
    # `.get`. That is the one parseable input that would traceback instead of
    # failing open, on every tool call.
    return payload if isinstance(payload, dict) else None


def _extract_command(payload: dict) -> str:  # type: ignore[type-arg] -- host JSON, shape varies
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    return tool_input.get("command") or payload.get("command") or ""


def _is_gemini_hook(payload: dict) -> bool:  # type: ignore[type-arg] -- host JSON, shape varies
    if "GEMINI_PROJECT_DIR" in os.environ:
        return True
    event = payload.get("hook_event_name")
    if event in ("BeforeTool", "AfterTool"):
        return True
    tool = payload.get("tool_name")
    return tool in ("run_shell_command", "read_file", "write_file", "replace")


def _is_codex_hook(payload: dict) -> bool:  # type: ignore[type-arg] -- host JSON, shape varies
    return "hook_event_name" in payload or "tool_name" in payload


def _deny(message: str, payload: dict) -> int:  # type: ignore[type-arg] -- host JSON, shape varies
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


def _enforcement_enabled(root: Path) -> bool:
    """Whether the [lifecycle].checkpoint_enforcement assignment is active.

    Reads only the active boolean assignment of ``checkpoint_enforcement`` inside
    the ``[lifecycle]`` section. Comments, similarly named keys, and the key in
    other sections are ignored, so a commented or unrelated ``false`` never
    silently disables enforcement.

    Fail-safe: a missing config, an unreadable file, or a non-boolean value keeps
    enforcement enabled (returns True) and emits a diagnostic to stderr.

    ``root`` is the resolved project root (``project_root()``), not the raw
    process cwd -- see that function's docstring for why.
    """
    config = root / ".raven" / "config.toml"
    if not config.exists():
        return True
    try:
        text = config.read_text(encoding="utf-8")
    except OSError as exc:
        print(
            f"raven-session-checkpoint: cannot read {config} ({exc}); keeping enforcement enabled",
            file=sys.stderr,
        )
        return True
    # Comment stripping and boolean coercion delegate to the shared
    # .raven/git-hooks/lib/raven_config.py module (quote-aware, unlike the old
    # `raw.split("#", 1)[0]` here); the section-aware walk and per-key
    # precedence stay exactly as before.
    raven_config = _raven_config_module()
    section: str | None = None
    for raw in text.splitlines():
        line = raven_config.strip_comment(raw)
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if section != "lifecycle" or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if key != "checkpoint_enforcement":
            continue
        parsed = raven_config.parse_bool(value)
        if parsed is not None:
            return parsed
        print(
            "raven-session-checkpoint: [lifecycle].checkpoint_enforcement must be true or false, "
            f"got {value!r}; keeping enforcement enabled",
            file=sys.stderr,
        )
        return True
    return True


def _strip_heredoc_bodies(text: str) -> str:
    """Remove heredoc bodies from text before tokenization.

    Tracks heredoc delimiters (dash variant, quoted or bare) and removes every
    line between the opener and its matching terminator, including the terminator.
    Known limitation: does not handle bash 4's tilde-indented variant. This is a
    strict improvement over zero heredoc awareness.
    """
    lines = text.split("\n")
    result = []
    i = 0
    while i < len(lines):
        line = lines[i]
        # Check for heredoc openers: <<EOF, <<'EOF', <<"EOF", <<-EOF, etc.
        heredoc_match = re.search(r"<<-?(['\"]?)(\w+)\1(?:\s|$)", line)
        if heredoc_match:
            # Found a heredoc opener; extract the delimiter
            delimiter = heredoc_match.group(2)
            # Add the line up to and including the heredoc opener
            result.append(line[: heredoc_match.start()] + "<<" + delimiter)
            i += 1
            # Skip all lines until we find the terminator
            while i < len(lines):
                if lines[i].strip() == delimiter:
                    # Found the terminator; skip it and continue
                    i += 1
                    break
                i += 1
        else:
            result.append(line)
            i += 1
    return "\n".join(result)


_ENV_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def _completion_unit(command: str) -> str | None:
    """Return the unit argument only for a genuine ``raven-session.py --complete``.

    A completion command must actually invoke the session CLI in command position:
    the token in command position (after stripping env-var assignments and
    interpreter prefixes) must have basename ``raven-session.py``, and a
    ``--complete`` flag must follow in the same statement. Any other command —
    including one that merely mentions those tokens in prose, heredocs, or
    non-command positions — yields ``None`` so unrelated shell commands are
    allowed through untouched.

    Algorithm:
    1. Strip heredoc bodies before tokenization (shlex has no heredoc awareness).
    2. Normalize newlines to statement separators.
    3. Tokenize with shlex.shlex(punctuation_chars=True, posix=True, whitespace_split=True)
       to isolate statement operators (;, |, &) as individual tokens.
    4. Split the token stream into statements on those operators.
    5. Per statement, skip leading NAME=value assignments and optional interpreter
       prefixes (python/python3), then check that the next token's basename is
       the session script filename and the statement contains --complete.

    Falls back to regexes only when the command is not validly quoted (ValueError),
    so a malformed command still defers to the CLI's own validation.
    """
    # Strip heredoc bodies first
    text = _strip_heredoc_bodies(command)

    # Normalize newlines to a statement separator (semicolon)
    # so multi-line commands are treated as separate statements.
    text = text.replace("\n", ";")

    try:
        # Tokenize with punctuation_chars so statement operators are isolated.
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        # Malformed quote: fall back to the regex-based fallback path.
        if not re.search(r"(?:^|[\s/])raven-session\.py(?:\s|$)", command):
            return None
        m = re.search(r"--complete\s+(\S+)", command)
        return m.group(1) if m else None

    # Split tokens into statements on shell operators.
    statement_operators = {";", "|", "&", "&&", "||"}
    statements = []
    current_statement = []
    for token in tokens:
        if token in statement_operators:
            if current_statement:
                statements.append(current_statement)
                current_statement = []
        else:
            current_statement.append(token)
    if current_statement:
        statements.append(current_statement)

    # Check each statement for a valid raven-session.py invocation.
    for stmt in statements:
        if not stmt:
            continue

        # Skip leading NAME=value assignments.
        idx = 0
        while idx < len(stmt) and _ENV_ASSIGNMENT_RE.match(stmt[idx]):
            idx += 1

        # Skip optional interpreter prefix (python or python3).
        if idx < len(stmt) and stmt[idx] in ("python", "python3"):
            idx += 1

        # The next token must be the session script (or a path to it).
        if idx >= len(stmt) or Path(stmt[idx]).name != "raven-session.py":
            continue

        # This statement invokes raven-session.py; now check for --complete.
        for i in range(idx + 1, len(stmt)):
            if stmt[i] == "--complete":
                return stmt[i + 1] if i + 1 < len(stmt) else None

    return None


def main() -> int:
    """Read the hook payload from stdin and deny a ``--complete`` bash call raven-session.py would reject."""
    payload = _load_payload()
    if payload is None:
        return 0

    command = _extract_command(payload)
    unit = _completion_unit(command)
    if not unit:
        return 0

    root = project_root()

    if not _enforcement_enabled(root):
        return 0

    if not (root / ".raven" / "session.md").exists():
        return _deny("No active session. Run raven-session.py --init first.", payload)

    script_path = root / adapter_directory_name() / "scripts" / "raven-session.py"
    if not script_path.is_file():
        print(
            f"raven-session-checkpoint: cannot find {script_path}; "
            "skipping checkpoint validation (failing open)",
            file=sys.stderr,
        )
        return 0

    result = subprocess.run(
        [
            # sys.executable here is not a bare interpreter guess: when this
            # hook runs via raven-run-hook.sh (Claude side), that shim already
            # probed for a working `python3`/`python`, verified it actually
            # executes `-c ""` (dodging the Windows WindowsApps alias trap),
            # and re-exec'd this hook script under it. So sys.executable, at
            # this point, IS that already-resolved, already-verified
            # interpreter -- reusing it to invoke the validator is correct,
            # not a shortcut.
            sys.executable,
            str(script_path),
            "--validate",
            unit,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        msg = result.stderr.strip() or result.stdout.strip() or f"Cannot complete unit '{unit}'"
        return _deny(msg, payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
