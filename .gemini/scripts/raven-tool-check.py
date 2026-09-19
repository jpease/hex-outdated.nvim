#!/usr/bin/env python3
"""Probe recommended Raven tooling and report/cache what's installed, configured, or missing.

Every check tolerates absence and timeout as normal outcomes rather than errors --
this runs unattended from a SessionStart hook as well as interactively, so a slow
or missing tool must degrade to a reported status, never a crash.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import platform
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from functools import cache, lru_cache
from importlib.machinery import SourceFileLoader
from pathlib import Path

MEMORY_PATH = Path(os.environ.get("RAVEN_TOOL_MEMORY", Path.home() / ".raven" / "tool-memory.json"))
_DO_NOT_REMIND_KEY = "doNotRemind"
_GENERIC_INSTALL_HINT = "follow this tool's current install docs for your OS"

TOOLS = [
    {
        "id": "rg",
        "name": "ripgrep",
        "commands": [["rg", "--version"]],
        "purpose": "exact strings, symbols, errors, and exhaustive confirmation",
        "install": "official install docs: https://github.com/BurntSushi/ripgrep#installation",
    },
    {
        "id": "just",
        "name": "just",
        "commands": [["just", "--version"]],
        "purpose": (
            "consistent task runner for test, lint, format, typecheck, and hook installation"
        ),
        "install": "official install docs: https://just.systems/man/en/",
    },
    {
        "id": "fd",
        "name": "fd",
        "commands": [["fd", "--version"]],
        "purpose": "fast file discovery by name, extension, type, or pattern",
        "install": "official install docs: https://github.com/sharkdp/fd#installation",
    },
    {
        "id": "gitnexus",
        "name": "GitNexus",
        "commands": [["gitnexus", "--version"]],
        "purpose": "architecture, dependency, call-path, and blast-radius reasoning",
        "install": {
            "darwin": "official install docs: https://github.com/abhigyanpatwari/GitNexus",
            "linux": "official install docs: https://github.com/abhigyanpatwari/GitNexus",
            "windows": (
                "official install docs: https://github.com/abhigyanpatwari/GitNexus; "
                "validate native Windows vs WSL for this repo"
            ),
        },
    },
    {
        "id": "mcp-language-server",
        "name": "mcp-language-server",
        "commands": [["mcp-language-server", "--help"]],
        "purpose": (
            "LSP-over-MCP bridge for definitions, references, hover/type info, diagnostics, "
            "and rename safety; required by Codex for every language, and by Claude Code only "
            "where no official LSP plugin covers the language"
        ),
        "install": {
            "darwin": (
                "official install docs: https://github.com/isaacphi/mcp-language-server; "
                "see .claude/docs/raven-lsp-mcp.md for template language-server docs"
            ),
            "linux": (
                "official install docs: https://github.com/isaacphi/mcp-language-server; "
                "see .claude/docs/raven-lsp-mcp.md for template language-server docs"
            ),
            "windows": (
                "official install docs: https://github.com/isaacphi/mcp-language-server; "
                "validate PATH/toolchain behavior for this repo"
            ),
        },
    },
    {
        "id": "ast-grep",
        "name": "ast-grep",
        # Probe only `ast-grep`, never the `sg` alias: on some Linux systems
        # /usr/bin/sg is the unrelated setgroups utility, which would yield a
        # false positive (or an interactive hang). Raven always invokes ast-grep
        # by its full name anyway.
        "commands": [["ast-grep", "--version"]],
        "purpose": "syntax-aware search and mechanical rewrites",
        "install": "official install docs: https://ast-grep.github.io/guide/quick-start.html",
    },
    {
        "id": "semgrep",
        "name": "Semgrep",
        "commands": [["semgrep", "--version"]],
        "purpose": "security, policy, and multi-language static-analysis rules",
        "install": {
            "darwin": "official install docs: https://semgrep.dev/docs/getting-started/cli",
            "linux": "official install docs: https://semgrep.dev/docs/getting-started/cli",
            "windows": (
                "official install docs: https://semgrep.dev/docs/getting-started/cli; "
                "validate native Windows behavior for the team's workflows"
            ),
        },
    },
    {
        "id": "gitleaks",
        "name": "Gitleaks",
        "commands": [["gitleaks", "version"], ["gitleaks", "--version"]],
        "purpose": "deterministic secret scanning for staged changes and full git history",
        "install": {
            "darwin": "official install docs: https://github.com/gitleaks/gitleaks",
            "linux": "official install docs: https://github.com/gitleaks/gitleaks",
            "windows": (
                "official install docs: https://github.com/gitleaks/gitleaks; "
                "validate native Windows vs WSL hook behavior for this repo"
            ),
        },
        "optionalWhen": (
            "secret scanning is provided by another approved project or platform control"
        ),
    },
    {
        "id": "osv-scanner",
        "name": "OSV-Scanner",
        "commands": [["osv-scanner", "--version"]],
        "purpose": "reporting known advisories in dependency lockfiles via `just audit`",
        "install": {
            "darwin": "official install docs: https://google.github.io/osv-scanner/installation/",
            "linux": "official install docs: https://google.github.io/osv-scanner/installation/",
            "windows": (
                "official install docs: https://google.github.io/osv-scanner/installation/; "
                "Scoop, WinGet, and a signed release binary are all documented"
            ),
        },
        # Unlike every other gate tool, nothing breaks without this one: `audit`
        # is deliberately not part of `check` (its findings vary with time, not
        # with the working tree), so a repo whose advisories arrive by another
        # route is fully covered without it.
        "optionalWhen": (
            "dependency advisories are reported by another approved control"
            " (e.g. Dependabot, Renovate, or a platform scanner)"
        ),
    },
    {
        "id": "vale",
        "name": "Vale",
        "commands": [["vale", "--version"]],
        "purpose": "word-level prose checks for the raven-write-prose and raven-review-prose skills",
        "install": {
            "darwin": "brew install vale",
            "linux": "official install docs: https://vale.sh/docs/install",
            "windows": "winget install errata-ai.Vale, or see https://vale.sh/docs/install",
        },
        # The prose skills degrade to a printed notice without it, and
        # self-check skips its prose gate rather than failing. The structural
        # half of those skills is a reading pass no linter performs, so a repo
        # without Vale still gets most of the value.
        "optionalWhen": ("prose is reviewed by hand, or the repo does not keep prose under review"),
    },
    {
        "id": "jq",
        "name": "jq",
        "commands": [["jq", "--version"]],
        "purpose": "reading and transforming structured JSON without brittle text parsing",
        "install": "official install docs: https://jqlang.org/download/",
        "optionalWhen": (
            "the task does not involve JSON transformation"
            " or another structured parser is available"
        ),
    },
    {
        "id": "yq",
        "name": "yq",
        "commands": [["yq", "--version"]],
        "purpose": "reading and transforming structured YAML without brittle text parsing",
        "install": "official install docs: https://github.com/mikefarah/yq/#install",
        "optionalWhen": (
            "the task does not involve YAML transformation"
            " or another structured parser is available"
        ),
    },
    {
        "id": "rtk",
        "name": "RTK",
        "commands": [["rtk", "--version"]],
        "purpose": "compressing noisy command output before it enters model context",
        "install": {
            "darwin": "official install docs: https://github.com/rtk-ai/rtk/blob/master/INSTALL.md",
            "linux": "official install docs: https://github.com/rtk-ai/rtk/blob/master/INSTALL.md",
            "windows": (
                "official install docs: https://github.com/rtk-ai/rtk/blob/master/INSTALL.md; "
                "WSL may be simpler for POSIX-heavy repos"
            ),
        },
    },
]


REQUIRED_TOOL_IDS: frozenset[str] = frozenset(tool["id"] for tool in TOOLS)
COMMAND_TIMEOUT_SECONDS = 3
CLAUDE_MCP_TIMEOUT_SECONDS = 3
RUN_COMMAND_PROBES = os.environ.get("RAVEN_TOOL_CHECK_EXECUTE") == "1"
RUN_CLAUDE_MCP_CLI = os.environ.get("RAVEN_TOOL_CHECK_CLAUDE_CLI") == "1"
_ADAPTER_DIRECTORY_NAMES = frozenset({".claude", ".codex", ".gemini"})
# Shown in command examples when this script is not running from an installed
# `<root>/<adapter>/scripts/` layout and no adapter can be inferred.
_DEFAULT_ADAPTER_DIRECTORY_NAME = ".claude"
_PROBER_FILENAME = "raven-tool-check.py"


def result_status(result: dict) -> str:
    """Map a check result's (available, source) pair to its tri-state label.

    Single source of truth for the "available / timed_out / missing" decision so
    the report properties, the streamed output, and the cached records can never
    disagree about what a given result means.
    """
    if result["available"]:
        return "available"
    if result.get("source") == "timed-out":
        return "timed_out"
    return "missing"


class ToolCheckReport:
    """Check results for one run, split into present/timed-out/missing on demand."""

    def __init__(
        self, memory_path: Path, current_os: str, do_not_remind: bool, results: list[dict]
    ) -> None:
        """Store the raw check results and run context this report summarizes."""
        self.memory_path = memory_path
        self.current_os = current_os
        self.do_not_remind = do_not_remind
        self.results = results

    @property
    def present(self) -> list[dict]:
        """Results for tools found available."""
        return [result for result in self.results if result_status(result) == "available"]

    @property
    def timed_out(self) -> list[dict]:
        """Results for tools whose check timed out (status unconfirmed, not "missing")."""
        return [result for result in self.results if result_status(result) == "timed_out"]

    @property
    def missing(self) -> list[dict]:
        """Results for tools confirmed not available."""
        return [result for result in self.results if result_status(result) == "missing"]


def os_key() -> str:
    """Normalize the running platform to one of "darwin"/"windows"/"linux"."""
    name = platform.system().lower()
    if name == "darwin":
        return "darwin"
    if name == "windows":
        return "windows"
    return "linux"


def _default_memory() -> dict:
    return {"version": 1, "tools": {}, "preferences": {}}


def _normalize_memory(raw: object) -> dict:
    """Coerce decoded memory into the documented shape.

    Tolerates structurally invalid local memory by falling back to clean defaults
    for the bad part: a non-object root yields a fresh versioned object, and
    non-object ``tools``/``preferences`` are reset to empty objects. This keeps a
    corrupted cache from crashing callers (notably the SessionStart hook) that
    assume ``setdefault``/``update`` on those containers.
    """
    if not isinstance(raw, dict):
        return _default_memory()
    memory = dict(raw)
    if not isinstance(memory.get("tools"), dict):
        memory["tools"] = {}
    if not isinstance(memory.get("preferences"), dict):
        memory["preferences"] = {}
    return memory


def load_memory() -> dict:
    """Load tool-check memory from disk, falling back to fresh defaults if absent or corrupt."""
    if not MEMORY_PATH.exists():
        return _default_memory()
    try:
        raw = json.loads(MEMORY_PATH.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return _default_memory()
    return _normalize_memory(raw)


def save_memory(memory: dict) -> None:
    """Write tool-check memory to disk as sorted, indented JSON."""
    MEMORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    MEMORY_PATH.write_text(json.dumps(memory, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def command_status(command: list[str]) -> str:
    """Probe one command: "available", "timed_out", or "missing"; never raises."""
    executable = shutil.which(command[0])
    if not executable:
        return "missing"
    if not RUN_COMMAND_PROBES:
        return "available"
    try:
        result = subprocess.run(
            [executable, *command[1:]],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return "timed_out"
    except OSError:
        return "missing"
    return "available" if result.returncode == 0 else "missing"


def command_works(command: list[str]) -> bool:
    """Whether a command probe reported "available"."""
    return command_status(command) == "available"


def _top_level_mcp_server_names(value: object) -> set[str]:
    """MCP server names from a flat top-level ``mcpServers`` dict.

    Non-recursive on purpose (#194): this is the only shape ``.mcp.json`` and
    ``~/.claude/settings.json`` ever use, and it is also how ``~/.claude.json``
    names servers available to every project. It must not walk into nested
    values -- ``~/.claude.json`` nests other, unrelated data (including every
    other project's own ``mcpServers``) under other keys, and reporting those
    as configured for this repo is exactly the over-reporting bug this
    function replaces (a prior version recursed into every nested dict/list
    looking for an ``mcpServers`` key anywhere).

    Tolerant of any unrecognized shape: a non-dict ``value``, a non-dict
    ``mcpServers``, or a non-string name all yield no names rather than
    raising or guessing, per the project's fail-toward-under-reporting rule --
    over-reporting an MCP server as configured is the harmful direction.
    """
    if not isinstance(value, dict):
        return set()
    servers = value.get("mcpServers")
    if not isinstance(servers, dict):
        return set()
    return {name for name in servers if isinstance(name, str)}


def _canonical_path(path: Path) -> Path:
    """Canonicalize a path for identity comparison.

    Resolves symlinks and normalizes separators/``.``/``..`` components so a
    symlinked repo root or a trailing separator compares equal to its
    canonical form. Used only to compare a ``~/.claude.json`` ``projects`` key
    against a repo root -- an independent concern from
    ``_adapter_directory_from_install_layout``'s deliberate *non*-resolution
    of this script's own install path (see its docstring), which must keep
    answering in terms of the path this script was invoked through, not where
    its bytes physically live.
    """
    try:
        return path.resolve()
    except OSError:
        return Path(os.path.normpath(str(path)))


def _claude_json_project_mcp_server_names(value: object, root: Path) -> set[str]:
    """MCP server names from ``projects.<this-repo-root>.mcpServers`` only.

    ``~/.claude.json`` nests MCP config per project under absolute-path keys;
    every other project's entry must be ignored, or a server configured only
    for another repo on the machine gets reported as configured for this one
    (#194). Keys are compared canonicalized (symlink-resolved, normalized) so
    a symlinked repo root or a trailing path separator on either side still
    matches. Tolerant of any unrecognized shape -- a non-dict ``value``, a
    non-dict ``projects``, a non-dict project entry -- which all yield no
    names rather than raising.
    """
    if not isinstance(value, dict):
        return set()
    projects = value.get("projects")
    if not isinstance(projects, dict):
        return set()
    canonical_root = _canonical_path(root)
    names: set[str] = set()
    for key, entry in projects.items():
        if not isinstance(key, str):
            continue
        try:
            candidate = _canonical_path(Path(key))
        except (OSError, ValueError):
            continue
        if candidate == canonical_root:
            names.update(_top_level_mcp_server_names(entry))
    return names


def _adapter_directory_from_install_layout() -> Path | None:
    """The ``.claude``/``.codex`` directory this script was installed under.

    Raven installs the prober at ``<root>/.claude/scripts/`` or
    ``<root>/.codex/scripts/``, so the adapter directory is the second parent
    and the project root is its parent. Returns ``None`` when the script runs
    from a location that does not match that layout.

    Single source of truth for every adapter-specific answer -- the project
    root and the directory name shown in command examples -- because one file
    now serves both adapters: in the template, ``.codex/scripts/`` entries are
    symlinks to the ``.claude/scripts/`` copies.

    That sharing is why the path is made absolute *without* resolving symlinks.
    Adapter identity is a property of the path the script was invoked through,
    not of where its bytes physically live, so following the link would make
    the Codex copy answer ``.claude``. Installed destinations hold real files,
    where the two spellings agree; and because both template trees sit at the
    same depth under ``common/``, the derived project root is identical either
    way.
    """
    try:
        script = Path(os.path.abspath(__file__))
    except (NameError, OSError):
        return None
    parents = script.parents
    if len(parents) >= 3 and parents[1].name in _ADAPTER_DIRECTORY_NAMES:
        return parents[1]
    return None


def _root_from_install_layout() -> Path | None:
    """Project root implied by this script's own install path.

    Returns ``None`` when the script runs from a location that does not match
    the install layout, so the caller can fall back to the process cwd.
    """
    adapter = _adapter_directory_from_install_layout()
    return adapter.parent if adapter is not None else None


def adapter_directory_name() -> str:
    """Adapter directory to name in user-facing command examples.

    Falls back to ``.claude`` when the install layout gives no answer: no
    adapter can be inferred at that point, and the Claude tree is both the
    canonical copy and the more common install, so it is the least-wrong
    suggestion for a command the reader is meant to paste.
    """
    adapter = _adapter_directory_from_install_layout()
    return adapter.name if adapter is not None else _DEFAULT_ADAPTER_DIRECTORY_NAME


def _prober_path() -> str:
    """Repo-relative path to this script, as a command example should spell it."""
    return f"{adapter_directory_name()}/scripts/{_PROBER_FILENAME}"


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


@lru_cache(maxsize=1)
def project_root() -> Path:
    """Project root used for project-scoped MCP configuration lookups.

    A hook's process working directory is not reliably the project. Codex
    Desktop can invoke a hook from outside the worktree, and its launcher runs
    this script through ``runpy`` without changing directory, so ``Path.cwd()``
    is the wrong anchor. Prefer the script's own install location, which is
    inside the project by construction.
    """
    return _root_from_install_layout() or _root_from_cwd() or Path(".")


def _claude_mcp_config_paths(root: Path | None = None) -> list[Path]:
    home = Path.home()
    paths = [
        (root if root is not None else project_root()) / ".mcp.json",
        home / ".claude.json",
        home / ".claude" / "settings.json",
    ]
    return list(dict.fromkeys(paths))


def _codex_mcp_config_paths(root: Path | None = None) -> list[Path]:
    home = Path.home()
    paths = [
        (root if root is not None else project_root()) / ".codex" / "config.toml",
        home / ".codex" / "config.toml",
    ]
    return list(dict.fromkeys(paths))


def _gemini_mcp_config_paths(root: Path | None = None) -> list[Path]:
    home = Path.home()
    paths = [
        (root if root is not None else project_root()) / ".gemini" / "settings.json",
        home / ".gemini" / "settings.json",
    ]
    return list(dict.fromkeys(paths))


def _raven_config_module():
    """Import ``.raven/git-hooks/lib/raven_config.py`` for the shared config parser.

    Resolved via ``_root_from_install_layout()`` -- this script's own
    install-derived root -- not the ``root`` argument the MCP-name lookups
    below take: those name the repo whose ``.codex/config.toml`` is actually
    being read, which a test fixture may point at an isolated directory.
    Also deliberately not the full ``project_root()``: ``_root_from_cwd()``
    (one of ``project_root()``'s own fallback branches) calls this function
    to reach ``resolve_repo_root``, so routing this lookup through
    ``project_root()`` would recurse into ``_root_from_cwd()`` a second time
    before the first call ever returns. Falls back to ``Path(".")`` --
    matching ``project_root()``'s own ultimate fallback -- when the install
    layout can't be inferred either, since at that point there is no
    reliable answer left to try.
    This always resolves to the sibling ``raven_config.py`` shipped next to
    this script's own installed copy, in the same "hooks" component. Same
    ``spec_from_file_location`` + ``SourceFileLoader`` mechanism
    ``load_prober`` in ``raven-capability-roster.py`` uses to reach this
    script as a sibling module.
    """
    root = _root_from_install_layout() or Path(".")
    path = root / ".raven" / "git-hooks" / "lib" / "raven_config.py"
    spec = importlib.util.spec_from_file_location(
        "raven_config_for_tool_check",
        path,
        loader=SourceFileLoader("raven_config_for_tool_check", str(path)),
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load raven_config from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _codex_mcp_server_names_from_toml(text: str) -> set[str]:
    """Server names declared as ``[mcp_servers.<name>]`` table headers.

    Routes through the shared parser's ``parse_config_text``, whose returned
    section names already are exactly the set of declared table headers --
    nested per-tool headers like ``mcp_servers.<name>.tools.<tool>`` are
    filtered out the same way as before (a remaining "." after the prefix),
    and a quoted header name is unquoted the same way as before too. This
    file is Codex's own, not Raven's -- it can contain constructs (arrays,
    nested tables) beyond this parser's subset, which is exactly why the
    shared parser only ever looks at declared section names here rather than
    trying to interpret every line.
    """
    raven_config = _raven_config_module()
    sections = raven_config.parse_config_text(text)
    names: set[str] = set()
    for section in sections:
        if not section.startswith("mcp_servers."):
            continue
        server = section[len("mcp_servers.") :].strip()
        if not server or "." in server:
            continue
        names.add(server.strip('"'))
    return names


@cache
def _claude_mcp_server_names_from_config(root: Path | None = None) -> frozenset[str]:
    """MCP server names configured for this repo, from Claude's config files.

    Each file contributes its flat top-level ``mcpServers`` (the only shape
    ``.mcp.json`` and ``~/.claude/settings.json`` use), plus -- when present --
    ``projects.<this-repo-root>.mcpServers`` from ``~/.claude.json``, which is
    the only file of the three that nests configuration per project. Checking
    for a ``projects`` key rather than special-casing a specific path lets one
    code path serve all three files: the other two simply never have that key,
    so the check is a no-op for them.
    """
    resolved_root = root if root is not None else project_root()
    names: set[str] = set()
    for path in _claude_mcp_config_paths(root):
        if not path.is_file():
            continue
        try:
            parsed = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            continue
        names.update(_top_level_mcp_server_names(parsed))
        names.update(_claude_json_project_mcp_server_names(parsed, resolved_root))
    return frozenset(names)


@cache
def _codex_mcp_server_names_from_config(root: Path | None = None) -> frozenset[str]:
    names: set[str] = set()
    for path in _codex_mcp_config_paths(root):
        if not path.is_file():
            continue
        try:
            names.update(_codex_mcp_server_names_from_toml(path.read_text(encoding="utf-8")))
        except (OSError, UnicodeDecodeError):
            continue
    return frozenset(names)


@cache
def _gemini_mcp_server_names_from_config(root: Path | None = None) -> frozenset[str]:
    names: set[str] = set()
    for path in _gemini_mcp_config_paths(root):
        if not path.is_file():
            continue
        try:
            parsed = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            continue
        names.update(_top_level_mcp_server_names(parsed))
    return frozenset(names)


def gemini_mcp_server_configured(server_name: str, root: Path | None = None) -> bool:
    """Whether a Gemini MCP server is configured, per its ``settings.json``."""
    return server_name in _gemini_mcp_server_names_from_config(root)


@lru_cache(maxsize=1)
def _claude_mcp_server_names_from_cli() -> tuple[frozenset[str], bool]:
    """Best-effort supplement: MCP servers ``claude mcp list`` reports.

    Decision record (#194): kept, not dropped, but strictly additive. Every
    caller (``claude_mcp_server_status``, ``_claude_mcp_server_names``) only
    unions this result on top of the config-file names -- a parsing miss here
    (the human-readable output format drifts, the CLI times out, ``claude``
    is missing) can never downgrade a server the config files already proved
    configured, only fail to add one the config files didn't mention. It is
    also opt-in: disabled unless ``RAVEN_TOOL_CHECK_CLAUDE_CLI=1`` is set, so
    a repo relying purely on config files never pays for its brittleness.
    ``_configured_mcp_server_names`` parses that output with prefix
    heuristics that are inherently version-sensitive; that fragility is
    accepted here specifically because it can only ever add a name, never
    remove one that the config files already established.
    """
    if not RUN_CLAUDE_MCP_CLI or not shutil.which("claude"):
        return frozenset(), False
    try:
        result = subprocess.run(
            ["claude", "mcp", "list"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            timeout=CLAUDE_MCP_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return frozenset(), True
    except OSError:
        return frozenset(), False
    return frozenset(_configured_mcp_server_names(result.stdout)), False


@cache
def _claude_mcp_server_names(root: Path | None = None) -> frozenset[str]:
    cli_names, _timed_out = _claude_mcp_server_names_from_cli()
    return _claude_mcp_server_names_from_config(root) | cli_names


def claude_mcp_server_status(server_name: str, root: Path | None = None) -> str:
    """Whether a Claude MCP server is "configured", "not_configured", or "timed_out" (CLI probe)."""
    if server_name in _claude_mcp_server_names_from_config(root):
        return "configured"
    cli_names, timed_out = _claude_mcp_server_names_from_cli()
    if server_name in cli_names:
        return "configured"
    if timed_out:
        return "timed_out"
    return "not_configured"


def claude_mcp_server_configured(server_name: str, root: Path | None = None) -> bool:
    """Whether a Claude MCP server is configured (config file or `claude mcp list`)."""
    return claude_mcp_server_status(server_name, root) == "configured"


def codex_mcp_server_configured(server_name: str, root: Path | None = None) -> bool:
    """Whether a Codex MCP server is configured, per its ``config.toml``."""
    return server_name in _codex_mcp_server_names_from_config(root)


def _configured_mcp_server_names(output: str) -> set[str]:
    names: set[str] = set()
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("[", "└", "Suggestion:")):
            continue
        if ":" not in line:
            continue
        name = line.split(":", 1)[0].strip()
        if name and " " not in name:
            names.add(name)
    return names


def check_tool_with_source(tool: dict, root: Path | None = None) -> tuple[bool, str | None]:
    """Check a tool via its CLI commands, then MCP config, returning (available, how it was found).

    Checked in that order because a CLI hit is the cheapest and most direct
    evidence; MCP config is consulted only when no command succeeds. A timeout
    anywhere in the chain is remembered but does not short-circuit the
    remaining checks, so a slow CLI probe doesn't hide a working MCP config.

    No entry in ``TOOLS`` sets ``claudeMcpServer`` or ``codexMcpServer`` today:
    every tool Raven recommends needs its CLI on PATH even when it is also run
    as an MCP server. The branches stay because the next MCP-only tool needs
    them and they cost nothing when the keys are absent.
    """
    timed_out = False
    for command in tool["commands"]:
        status = command_status(command)
        if status == "available":
            return True, "cli"
        if status == "timed_out":
            timed_out = True
    mcp_server = tool.get("claudeMcpServer")
    if isinstance(mcp_server, str):
        mcp_status = claude_mcp_server_status(mcp_server, root)
        if mcp_status == "configured":
            return True, "claude-mcp-config"
        if mcp_status == "timed_out":
            timed_out = True
    codex_mcp_server = tool.get("codexMcpServer")
    if isinstance(codex_mcp_server, str) and codex_mcp_server_configured(codex_mcp_server, root):
        return True, "codex-mcp-config"
    gemini_mcp_server = tool.get("geminiMcpServer")
    if isinstance(gemini_mcp_server, str) and gemini_mcp_server_configured(gemini_mcp_server, root):
        return True, "gemini-mcp-config"
    if timed_out:
        return False, "timed-out"
    return False, None


def _memory_has_complete_records(memory: dict, current_os: str) -> bool:
    remembered = memory.get("tools", {})
    return all(
        isinstance(remembered.get(tid), dict) and remembered[tid].get("os") == current_os
        for tid in REQUIRED_TOOL_IDS
    )


def _resolve_install(install: object, current_os: str) -> str:
    """Resolve a tool's install guidance for ``current_os``.

    ``install`` is a single string when guidance is the same on every OS, or an
    ``{os: text}`` dict when one OS (typically Windows) needs a caveat. Anything
    else falls back to a generic hint.
    """
    if isinstance(install, str):
        return install
    if isinstance(install, dict):
        return install.get(current_os, _GENERIC_INSTALL_HINT)
    return _GENERIC_INSTALL_HINT


def _tool_result(tool: dict, current_os: str, root: Path | None = None) -> dict:
    available, source = check_tool_with_source(tool, root)
    return {
        "id": tool["id"],
        "name": tool["name"],
        "available": available,
        "source": source,
        "purpose": tool["purpose"],
        "install": _resolve_install(tool["install"], current_os),
        "optionalWhen": tool.get("optionalWhen"),
    }


def _print_streamed_result(result: dict) -> None:
    status = result_status(result)
    if status == "available":
        source = f" via {result['source']}" if result.get("source") else ""
        print(f"[ok] {result['name']}: installed or configured{source}", flush=True)
    elif status == "timed_out":
        print(f"[timed out] {result['name']}: check timed out", flush=True)
    else:
        print(f"[missing] {result['name']}: not installed or configured", flush=True)


def check_all_tools(
    current_os: str, *, stream: bool = False, root: Path | None = None
) -> list[dict]:
    """Check every tool in `TOOLS` concurrently, returning results in `TOOLS` order.

    ``stream=True`` prints each result as it completes (for interactive human
    use) but still returns them re-sorted to `TOOLS` order, since completion
    order is nondeterministic and callers rely on a stable result order.
    """
    if not stream:
        with ThreadPoolExecutor() as pool:
            return list(pool.map(lambda tool: _tool_result(tool, current_os, root), TOOLS))

    order = {tool["id"]: index for index, tool in enumerate(TOOLS)}
    results: list[dict] = []
    with ThreadPoolExecutor() as pool:
        futures = {pool.submit(_tool_result, tool, current_os, root): tool for tool in TOOLS}
        for future in as_completed(futures):
            result = future.result()
            _print_streamed_result(result)
            results.append(result)
    return sorted(results, key=lambda result: order[result["id"]])


def _build_tool_records(results: list[dict], checked_at: str, current_os: str) -> dict[str, dict]:
    return {
        result["id"]: {
            "name": result["name"],
            "available": result["available"],
            "purpose": result["purpose"],
            "source": result.get("source"),
            "status": result_status(result),
            "checkedAt": checked_at,
            "os": current_os,
        }
        for result in results
    }


def remember_results(memory: dict, results: list[dict], checked_at: str, current_os: str) -> None:
    """Merge fresh check results into ``memory["tools"]`` in place, keyed by tool id."""
    memory["tools"].update(_build_tool_records(results, checked_at, current_os))


def print_session_start_prompt(missing: list[dict], memory_path: Path) -> None:
    """Print the SessionStart-hook prompt asking the agent how to handle missing tools."""
    print("Recommended RAVEN tools are not installed, configured, or verified for this OS.")
    print(f"Local tool memory: {memory_path}")
    print()
    print("Recommended tools not installed, configured, or verified:")
    for result in missing:
        print(f"- {result['name']}: {result['purpose']}")
        print(f"  Install guidance: {result['install']}")
        if result.get("optionalWhen"):
            print(f"  Note: {result['optionalWhen']}")
    print()
    print(
        "Ask the user whether they want to install the missing tools,"
        " receive install instructions, be reminded later, or stop being reminded."
    )
    prober = _prober_path()
    print(
        f"If tools are installed, run `python {prober} --write` afterward to update local memory."
    )
    print(f"If the user chooses not to be reminded, run `python {prober} --no-reminder`.")


def build_tool_check_report(memory: dict, current_os: str, *, stream: bool) -> ToolCheckReport:
    """Run every tool check and assemble the report, carrying forward the no-reminder preference."""
    results = check_all_tools(current_os, stream=stream)
    return ToolCheckReport(
        memory_path=MEMORY_PATH,
        current_os=current_os,
        do_not_remind=bool(memory["preferences"].get(_DO_NOT_REMIND_KEY)),
        results=results,
    )


def print_json_report(report: ToolCheckReport) -> None:
    """Print the report as JSON, for the SessionStart hook and other machine callers."""
    print(
        json.dumps(
            {
                "memoryPath": str(report.memory_path),
                "os": report.current_os,
                _DO_NOT_REMIND_KEY: report.do_not_remind,
                "results": report.results,
            },
            indent=2,
        )
    )


def print_human_report(report: ToolCheckReport) -> None:
    """Print the report as readable text, grouped into timed-out/present/missing sections."""
    print(f"Tool memory: {report.memory_path}")
    print(f"OS: {report.current_os}")
    print()

    if report.timed_out:
        print("Recommended tools whose checks timed out:")
        for result in report.timed_out:
            print(
                f"- {result['name']}: check timed out; installation/configuration was not confirmed"
            )
            print(f"  Install guidance, if needed: {result['install']}")
            if result.get("optionalWhen"):
                print(f"  Note: {result['optionalWhen']}")
        print()

    if not report.missing:
        if report.timed_out:
            print("No recommended tools were confirmed missing, but at least one check timed out.")
        else:
            print("All recommended tools appear to be installed or configured.")
        return

    if report.do_not_remind:
        print("Some recommended tools are missing, but local memory says not to remind again.")
        return

    print("Recommended tools not installed or configured:")
    for result in report.missing:
        print(f"- {result['name']}: {result['purpose']}")
        print(f"  Install guidance: {result['install']}")
        if result.get("optionalWhen"):
            print(f"  Note: {result['optionalWhen']}")

    print()
    print(
        "Ask the user whether to install missing tools, provide install instructions, "
        "remind later, or stop reminding."
    )


def main() -> int:
    """CLI entry point: parse args, run checks, print a report, and apply --write/--no-reminder."""
    parser = argparse.ArgumentParser(
        description=(
            "Check recommended RAVEN tooling and optionally update RAVEN's local tool-check cache."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Default human use:
  python {_prober_path()}

Agent/cache use:
  python {_prober_path()} --write
  python {_prober_path()} --session-start
  python {_prober_path()} --no-reminder

Cache location:
  ~/.raven/tool-memory.json, or RAVEN_TOOL_MEMORY if set.
""",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help=(
            "agent workflow: cache current availability results in ~/.raven/tool-memory.json "
            "after tools are installed or verified"
        ),
    )
    parser.add_argument(
        "--no-reminder",
        action="store_true",
        help="record preference to stop reminding about missing tools",
    )
    parser.add_argument(
        "--clear-no-reminder", action="store_true", help="clear missing-tool reminder suppression"
    )
    parser.add_argument(
        "--session-start",
        action="store_true",
        help=(
            "deprecated: superseded by raven-capability-roster.py; retained so "
            "repos whose hook wiring was customized or not upgraded keep working"
        ),
    )
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    args = parser.parse_args()

    current_os = os_key()
    checked_at = datetime.now(timezone.utc).isoformat()
    memory = load_memory()
    memory.setdefault("tools", {})
    memory.setdefault("preferences", {})
    memory["version"] = 1
    memory["preferences"]["os"] = current_os
    memory["preferences"]["updatedAt"] = checked_at

    if args.no_reminder:
        memory["preferences"][_DO_NOT_REMIND_KEY] = True
        save_memory(memory)
        print(
            f"Recorded preference in {MEMORY_PATH}: do not remind about missing recommended tools."
        )
        return 0

    if args.clear_no_reminder:
        memory["preferences"].pop(_DO_NOT_REMIND_KEY, None)
        save_memory(memory)
        print(f"Cleared missing-tool reminder suppression in {MEMORY_PATH}.")
        return 0

    if args.session_start:
        if memory["preferences"].get(_DO_NOT_REMIND_KEY):
            return 0
        if _memory_has_complete_records(memory, current_os):
            return 0

        results = check_all_tools(current_os)
        remember_results(memory, results, checked_at, current_os)
        save_memory(memory)

        missing = [result for result in results if not result["available"]]
        if missing:
            print_session_start_prompt(missing, MEMORY_PATH)
        return 0

    if not args.json:
        print("Checking recommended RAVEN tools...", flush=True)
    report = build_tool_check_report(memory, current_os, stream=not args.json)
    if not args.json:
        print()

    if args.write:
        remember_results(memory, report.results, checked_at, current_os)
        save_memory(memory)

    if args.json:
        print_json_report(report)
        return 0

    print_human_report(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
