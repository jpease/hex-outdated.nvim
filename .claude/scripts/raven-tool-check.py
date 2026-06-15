#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

MEMORY_PATH = Path(os.environ.get("RAVEN_TOOL_MEMORY", Path.home() / ".raven" / "tool-memory.json"))
_DO_NOT_REMIND_KEY = "doNotRemind"

TOOLS = [
    {
        "id": "rg",
        "name": "ripgrep",
        "commands": [["rg", "--version"]],
        "purpose": "exact strings, symbols, errors, and exhaustive confirmation",
        "install": {
            "darwin": "official install docs: https://github.com/BurntSushi/ripgrep#installation",
            "linux": "official install docs: https://github.com/BurntSushi/ripgrep#installation",
            "windows": "official install docs: https://github.com/BurntSushi/ripgrep#installation",
        },
    },
    {
        "id": "just",
        "name": "just",
        "commands": [["just", "--version"]],
        "purpose": "consistent task runner for test, lint, format, typecheck, and hook installation",
        "install": {
            "darwin": "official install docs: https://just.systems/man/en/",
            "linux": "official install docs: https://just.systems/man/en/",
            "windows": "official install docs: https://just.systems/man/en/",
        },
    },
    {
        "id": "fd",
        "name": "fd",
        "commands": [["fd", "--version"]],
        "purpose": "fast file discovery by name, extension, type, or pattern",
        "install": {
            "darwin": "official install docs: https://github.com/sharkdp/fd#installation",
            "linux": "official install docs: https://github.com/sharkdp/fd#installation",
            "windows": "official install docs: https://github.com/sharkdp/fd#installation",
        },
    },
    {
        "id": "uvx",
        "name": "uvx",
        "commands": [["uvx", "--version"]],
        "purpose": "running Python-packaged tools such as Semble MCP without a permanent project dependency",
        "install": {
            "darwin": "official install docs: https://docs.astral.sh/uv/getting-started/installation/",
            "linux": "official install docs: https://docs.astral.sh/uv/getting-started/installation/",
            "windows": "official install docs: https://docs.astral.sh/uv/getting-started/installation/",
        },
    },
    {
        "id": "semble",
        "name": "Semble",
        "commands": [["semble", "--version"]],
        "purpose": "intent-based code search when the owning file or symbol is unknown",
        "install": {
            "darwin": "official install docs: https://minish.ai/packages/semble/installation/",
            "linux": "official install docs: https://minish.ai/packages/semble/installation/",
            "windows": "official install docs: https://minish.ai/packages/semble/installation/",
        },
        "optionalWhen": "uvx is available and Semble is configured only as an MCP server",
        "claudeMcpServer": "semble",
        "codexMcpServer": "semble",
    },
    {
        "id": "gitnexus",
        "name": "GitNexus",
        "commands": [["gitnexus", "--version"]],
        "purpose": "architecture, dependency, call-path, and blast-radius reasoning",
        "install": {
            "darwin": "official install docs: https://gitnexus.vercel.app/",
            "linux": "official install docs: https://gitnexus.vercel.app/",
            "windows": (
                "official install docs: https://gitnexus.vercel.app/; "
                "validate native Windows vs WSL for this repo"
            ),
        },
    },
    {
        "id": "mcp-language-server",
        "name": "mcp-language-server",
        "commands": [["mcp-language-server", "--help"]],
        "purpose": (
            "general-purpose LSP-over-MCP bridge for definitions, references, hover/type info, "
            "diagnostics, and rename safety"
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
        "commands": [["ast-grep", "--version"], ["sg", "--version"]],
        "purpose": "syntax-aware search and mechanical rewrites",
        "install": {
            "darwin": "official install docs: https://ast-grep.github.io/guide/quick-start.html",
            "linux": "official install docs: https://ast-grep.github.io/guide/quick-start.html",
            "windows": "official install docs: https://ast-grep.github.io/guide/quick-start.html",
        },
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
        "optionalWhen": "secret scanning is provided by another approved project or platform control",
    },
    {
        "id": "jq",
        "name": "jq",
        "commands": [["jq", "--version"]],
        "purpose": "reading and transforming structured JSON without brittle text parsing",
        "install": {
            "darwin": "official install docs: https://jqlang.org/download/",
            "linux": "official install docs: https://jqlang.org/download/",
            "windows": "official install docs: https://jqlang.org/download/",
        },
        "optionalWhen": "the task does not involve JSON transformation or another structured parser is available",
    },
    {
        "id": "yq",
        "name": "yq",
        "commands": [["yq", "--version"]],
        "purpose": "reading and transforming structured YAML without brittle text parsing",
        "install": {
            "darwin": "official install docs: https://github.com/mikefarah/yq/#install",
            "linux": "official install docs: https://github.com/mikefarah/yq/#install",
            "windows": "official install docs: https://github.com/mikefarah/yq/#install",
        },
        "optionalWhen": "the task does not involve YAML transformation or another structured parser is available",
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


class ToolCheckReport:
    def __init__(
        self, memory_path: Path, current_os: str, do_not_remind: bool, results: list[dict]
    ) -> None:
        self.memory_path = memory_path
        self.current_os = current_os
        self.do_not_remind = do_not_remind
        self.results = results

    @property
    def present(self) -> list[dict]:
        return [result for result in self.results if result["available"]]

    @property
    def timed_out(self) -> list[dict]:
        return [result for result in self.results if result.get("source") == "timed-out"]

    @property
    def missing(self) -> list[dict]:
        return [
            result
            for result in self.results
            if not result["available"] and result.get("source") != "timed-out"
        ]


def os_key() -> str:
    name = platform.system().lower()
    if name == "darwin":
        return "darwin"
    if name == "windows":
        return "windows"
    return "linux"


def load_memory() -> dict:
    if not MEMORY_PATH.exists():
        return {"version": 1, "tools": {}, "preferences": {}}
    try:
        return json.loads(MEMORY_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {"version": 1, "tools": {}, "preferences": {}}


def save_memory(memory: dict) -> None:
    MEMORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    MEMORY_PATH.write_text(json.dumps(memory, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def command_status(command: list[str]) -> str:
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
    return command_status(command) == "available"


def _mcp_server_names_from_value(value: object) -> set[str]:
    names: set[str] = set()
    if isinstance(value, dict):
        servers = value.get("mcpServers")
        if isinstance(servers, dict):
            names.update(str(name) for name in servers if isinstance(name, str))
        for nested in value.values():
            names.update(_mcp_server_names_from_value(nested))
    elif isinstance(value, list):
        for nested in value:
            names.update(_mcp_server_names_from_value(nested))
    return names


def _claude_mcp_config_paths() -> list[Path]:
    home = Path.home()
    paths = [
        Path.cwd() / ".mcp.json",
        home / ".claude.json",
        home / ".claude" / "settings.json",
    ]
    return list(dict.fromkeys(paths))


def _codex_mcp_config_paths() -> list[Path]:
    home = Path.home()
    paths = [
        Path.cwd() / ".codex" / "config.toml",
        home / ".codex" / "config.toml",
    ]
    return list(dict.fromkeys(paths))


def _codex_mcp_server_names_from_toml(text: str) -> set[str]:
    names: set[str] = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("[mcp_servers.") or not stripped.endswith("]"):
            continue
        server = stripped.removeprefix("[mcp_servers.").removesuffix("]").strip()
        if not server or "." in server:
            continue
        names.add(server.strip('"'))
    return names


@lru_cache(maxsize=1)
def _claude_mcp_server_names_from_config() -> frozenset[str]:
    names: set[str] = set()
    for path in _claude_mcp_config_paths():
        if not path.is_file():
            continue
        try:
            names.update(_mcp_server_names_from_value(json.loads(path.read_text(encoding="utf-8"))))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            continue
    return frozenset(names)


@lru_cache(maxsize=1)
def _codex_mcp_server_names_from_config() -> frozenset[str]:
    names: set[str] = set()
    for path in _codex_mcp_config_paths():
        if not path.is_file():
            continue
        try:
            names.update(_codex_mcp_server_names_from_toml(path.read_text(encoding="utf-8")))
        except (OSError, UnicodeDecodeError):
            continue
    return frozenset(names)


@lru_cache(maxsize=1)
def _claude_mcp_server_names_from_cli() -> tuple[frozenset[str], bool]:
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


@lru_cache(maxsize=1)
def _claude_mcp_server_names() -> frozenset[str]:
    cli_names, _timed_out = _claude_mcp_server_names_from_cli()
    return _claude_mcp_server_names_from_config() | cli_names


def claude_mcp_server_status(server_name: str) -> str:
    if server_name in _claude_mcp_server_names_from_config():
        return "configured"
    cli_names, timed_out = _claude_mcp_server_names_from_cli()
    if server_name in cli_names:
        return "configured"
    if timed_out:
        return "timed_out"
    return "not_configured"


def claude_mcp_server_configured(server_name: str) -> bool:
    return claude_mcp_server_status(server_name) == "configured"


def codex_mcp_server_configured(server_name: str) -> bool:
    return server_name in _codex_mcp_server_names_from_config()


def _configured_mcp_server_names(output: str) -> set[str]:
    names: set[str] = set()
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if (
            not line
            or line.startswith("[")
            or line.startswith("└")
            or line.startswith("Suggestion:")
        ):
            continue
        if ":" not in line:
            continue
        name = line.split(":", 1)[0].strip()
        if name and " " not in name:
            names.add(name)
    return names


def check_tool_with_source(tool: dict) -> tuple[bool, str | None]:
    timed_out = False
    for command in tool["commands"]:
        status = command_status(command)
        if status == "available":
            return True, "cli"
        if status == "timed_out":
            timed_out = True
    mcp_server = tool.get("claudeMcpServer")
    if isinstance(mcp_server, str):
        mcp_status = claude_mcp_server_status(mcp_server)
        if mcp_status == "configured":
            return True, "claude-mcp-config"
        if mcp_status == "timed_out":
            timed_out = True
    codex_mcp_server = tool.get("codexMcpServer")
    if isinstance(codex_mcp_server, str) and codex_mcp_server_configured(codex_mcp_server):
        return True, "codex-mcp-config"
    if timed_out:
        return False, "timed-out"
    return False, None


def check_tool(tool: dict) -> bool:
    available, _source = check_tool_with_source(tool)
    return available


def _memory_has_complete_records(memory: dict, current_os: str) -> bool:
    remembered = memory.get("tools", {})
    return all(
        isinstance(remembered.get(tid), dict) and remembered[tid].get("os") == current_os
        for tid in REQUIRED_TOOL_IDS
    )


def _tool_result(tool: dict, current_os: str) -> dict:
    available, source = check_tool_with_source(tool)
    return {
        "id": tool["id"],
        "name": tool["name"],
        "available": available,
        "source": source,
        "purpose": tool["purpose"],
        "install": tool["install"].get(
            current_os, "follow this tool's current install docs for your OS"
        ),
        "optionalWhen": tool.get("optionalWhen"),
    }


def _print_streamed_result(result: dict) -> None:
    if result["available"]:
        source = f" via {result['source']}" if result.get("source") else ""
        print(f"[ok] {result['name']}: installed or configured{source}", flush=True)
    elif result.get("source") == "timed-out":
        print(f"[timed out] {result['name']}: check timed out", flush=True)
    else:
        print(f"[missing] {result['name']}: not installed or configured", flush=True)


def check_all_tools(current_os: str, *, stream: bool = False) -> list[dict]:
    if not stream:
        with ThreadPoolExecutor() as pool:
            return list(pool.map(lambda tool: _tool_result(tool, current_os), TOOLS))

    order = {tool["id"]: index for index, tool in enumerate(TOOLS)}
    results: list[dict] = []
    with ThreadPoolExecutor() as pool:
        futures = {pool.submit(_tool_result, tool, current_os): tool for tool in TOOLS}
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
            "status": (
                "available"
                if result["available"]
                else ("timed_out" if result.get("source") == "timed-out" else "missing")
            ),
            "checkedAt": checked_at,
            "os": current_os,
        }
        for result in results
    }


def remember_results(memory: dict, results: list[dict], checked_at: str, current_os: str) -> None:
    memory["tools"].update(_build_tool_records(results, checked_at, current_os))


def print_session_start_prompt(missing: list[dict], memory_path: Path) -> None:
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
        "Ask the user whether they want to install the missing tools, receive install instructions, "
        "be reminded later, or stop being reminded."
    )
    print(
        "If tools are installed, run `python .claude/scripts/raven-tool-check.py --write` "
        "afterward to update local memory."
    )
    print(
        "If the user chooses not to be reminded, run `python .claude/scripts/raven-tool-check.py --no-reminder`."
    )


def build_tool_check_report(memory: dict, current_os: str, *, stream: bool) -> ToolCheckReport:
    results = check_all_tools(current_os, stream=stream)
    return ToolCheckReport(
        memory_path=MEMORY_PATH,
        current_os=current_os,
        do_not_remind=bool(memory["preferences"].get(_DO_NOT_REMIND_KEY)),
        results=results,
    )


def print_json_report(report: ToolCheckReport) -> None:
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
    parser = argparse.ArgumentParser(
        description="Check recommended RAVEN tooling and optionally update RAVEN's local tool-check cache.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Default human use:
  python .claude/scripts/raven-tool-check.py

Agent/cache use:
  python .claude/scripts/raven-tool-check.py --write
  python .claude/scripts/raven-tool-check.py --session-start
  python .claude/scripts/raven-tool-check.py --no-reminder

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
        help="Claude Code SessionStart hook mode; uses the local cache to avoid repeated prompts",
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
