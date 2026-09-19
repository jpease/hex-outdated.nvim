#!/usr/bin/env python3
"""PreToolUse hook: deny destructive bash commands (rm -rf /, git reset --hard, dropdb, ...).

Every rule reasons about a tokenized command rather than its raw text: the
program is resolved past wrappers and environment assignments, options are
normalized so `-rf`, `-fr` and `--recursive --force` are one intent, payloads
handed to a nested interpreter are followed, and heredoc bodies that are data
rather than code are dropped.

Matching raw text instead is both noisier and leakier. It fires on any mention
-- a search pattern, a commit message, a line of documentation -- while missing
the ordinary spellings that put an option between a verb and its object, so
`kubectl -n default delete deployment` reads as harmless. Claude Code documents
the same fragility for its own Bash permission patterns.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys

# Tokens made up solely of these characters are top-level shell operators that
# separate one simple command from the next.
_OPERATOR_CHARS = frozenset(";|&()<>")

# Long options that map onto the short letters the destructive rules reason about.
# One shared map is enough: the program check gates which rule consumes the flags.
# `--force-with-lease` is deliberately absent: it is a *different* intent from
# `--force` (it refuses to overwrite work it has not seen), and it must not fold
# into the same `f` that denies a plain force-push -- see `_is_destructive_git`.
_LONG_OPTION_LETTERS = {
    "--recursive": "r",
    "--force": "f",
    "--delete": "d",
}

# Programs whose heredoc body is *executed* rather than consumed as data. A body
# fed to one of these is shell code and must still be scanned; a body fed to
# anything else (python3, jq, cat, a REST client) is stdin data that never runs
# as a command. Determining which decides whether `_strip_heredoc_bodies` may
# drop it, so an unrecognized program is treated as a shell -- err toward
# scanning.
_SHELL_PROGRAMS = frozenset({"sh", "bash", "dash", "ksh", "zsh", "csh", "tcsh", "fish"})

# Programs that retrieve a URL. What they emit is remote content, which
# `.claude/rules/raven-security.md` treats as untrusted; piping it into an
# interpreter is the step that turns that content into execution.
_FETCH_PROGRAMS = frozenset({"curl", "wget", "http", "https", "httpie", "aria2c"})

# Interpreters that execute *stdin* when handed no script operand, so
# `<fetcher> | <interpreter>` runs whatever the URL served. The shells are the
# common spelling; the rest are in scope because `curl ... | python3 -` has the
# identical consequence and costs one entry to cover.
_STDIN_INTERPRETERS = _SHELL_PROGRAMS | frozenset({"python", "python3", "node", "ruby", "perl"})

# `<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"`. The negative lookahead excludes
# `<<<`, which is a herestring: its operand is on the same line, with no body.
_HEREDOC_INTRODUCER = re.compile(
    r"<<(?!<)-?[ \t]*(?:'([^']*)'|\"([^\"]*)\"|([A-Za-z_][A-Za-z0-9_]*))"
)


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


def _extract_command(payload: dict) -> str:
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    return tool_input.get("command") or payload.get("command") or ""


def _is_gemini_hook(payload: dict) -> bool:
    if "GEMINI_PROJECT_DIR" in os.environ:
        return True
    event = payload.get("hook_event_name")
    if event in ("BeforeTool", "AfterTool"):
        return True
    tool = payload.get("tool_name")
    return tool in ("run_shell_command", "read_file", "write_file", "replace")


def _is_codex_hook(payload: dict) -> bool:
    # Both Claude Code and Codex include these fields; both use the structured JSON path.
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


def _deny_message(command: str) -> str:
    return (
        "Blocked potentially destructive command."
        f" Ask for explicit approval before running: {command}"
    )


def _command_segments(command: str) -> list[list[str]]:
    """Split a command into simple-command segments of tokens.

    Splits on top-level shell operators (``;`` ``|`` ``&`` ``(`` ``)`` ``<``
    ``>`` and newlines) while respecting quotes. On a lexer error such as
    unbalanced quotes, that line falls back to a whitespace split so the
    remaining checks still run (best effort -- err toward more checking).
    """
    segments: list[list[str]] = []
    for line in command.splitlines():
        try:
            lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
            lexer.whitespace_split = True
            tokens = list(lexer)
        except ValueError:
            segments.append(line.split())
            continue

        current: list[str] = []
        for token in tokens:
            if token and all(ch in _OPERATOR_CHARS for ch in token):
                segments.append(current)
                current = []
            else:
                current.append(token)
        segments.append(current)

    return [segment for segment in segments if segment]


def _line_program(line: str) -> str | None:
    """The program a single command line invokes, or None if it cannot be read."""
    for segment in _command_segments(line):
        parsed = _program_and_args(segment)
        if parsed is not None:
            return parsed[0].rsplit("/", 1)[-1].lower()
    return None


def _strip_heredoc_bodies(command: str) -> str:
    """Drop heredoc bodies that are data rather than code, keeping their introducer lines.

    A heredoc body is the stdin of the program on its introducer line. When that
    program is not a shell -- `python3 - <<'PY'`, `jq -f - <<EOF`, `gh pr create
    --body-file - <<EOF` -- the body never executes, so scanning it can only
    produce false positives. And they are not hypothetical: review prose, commit
    messages, SQL and documentation routinely *name* destructive commands, and
    the raw-text family matches text rather than intent. Blocking those trains
    people to route around the guard by writing the same content to a file and
    running that instead, which defeats it entirely while making the result less
    reviewable.

    A body fed to a shell (`bash <<EOF`) *is* code and is kept. So is a body
    whose introducer line this cannot parse, and any text after an unterminated
    delimiter -- both err toward scanning.

    The introducer line itself is always kept: it is a real command.
    """
    lines = command.splitlines()
    kept: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        kept.append(line)
        index += 1

        delimiters = [
            quoted_single or quoted_double or bare
            for quoted_single, quoted_double, bare in _HEREDOC_INTRODUCER.findall(line)
        ]
        if not delimiters:
            continue

        program = _line_program(line)
        drop_body = program is not None and program not in _SHELL_PROGRAMS

        for delimiter in delimiters:
            body: list[str] = []
            terminator: str | None = None
            while index < len(lines):
                body_line = lines[index]
                index += 1
                if body_line.strip() == delimiter:
                    terminator = body_line
                    break
                body.append(body_line)
            # An unterminated heredoc has no provable end, so its "body" may be
            # ordinary commands the author expected to run. Keep it and scan.
            if not drop_body or terminator is None:
                kept.extend(body)
            if terminator is not None:
                kept.append(terminator)
    return "\n".join(kept)


# A wrapper's own operand, such as the duration in `timeout 30 cmd`. Skipping
# only the wrapper name leaves that operand in the program position, so
# `timeout 30 kubectl delete pod` resolves to a program called "30" and every
# rule below misses it.
_WRAPPER_OPERAND = re.compile(r"\A\d+(\.\d+)?[smhd]?\Z")

# Programs that run their argument as the real command, so a rule written for
# the inner command should still see it. This mirrors the wrapper set Claude
# Code strips before matching its own Bash permission rules -- adopted rather
# than invented so the guard and the harness agree on what "the command" means.
# `command -v` is deliberately absent: it looks a command up instead of running
# it.
_TRANSPARENT_WRAPPERS = frozenset(
    {
        "sudo",
        "timeout",
        "time",
        "nice",
        "nohup",
        "stdbuf",
        "command",
        "builtin",
        "noglob",
    }
)


def _program_and_args(segment: list[str]) -> tuple[str, list[str]] | None:
    """Return (program, remaining tokens), skipping leading env-assignments and
    wrappers that run their argument as the real command, so the checks below
    reason about what actually executes.
    """
    index = 0
    while index < len(segment):
        token = segment[index]
        if token.rsplit("/", 1)[-1] in _TRANSPARENT_WRAPPERS:
            # `command -v foo` queries rather than runs; do not step over it.
            if token == "command" and segment[index + 1 : index + 2] == ["-v"]:
                break
            index += 1
            # Step over the wrapper's own options and duration operand so the
            # next token really is the command it runs.
            while index < len(segment) and segment[index].startswith("-"):
                index += 1
            if index < len(segment) and _WRAPPER_OPERAND.match(segment[index]):
                index += 1
            continue
        if re.match(r"[A-Za-z_][A-Za-z0-9_]*=", token):
            index += 1
            continue
        if token.rsplit("/", 1)[-1] == "rtk":
            # `rtk <cmd>` is a transparent proxy: AGENTS.md tells agents to route
            # noisy commands through it, and the hook that rewrites `git status`
            # into `rtk git status` does so silently, so this is a spelling the
            # guard produces for itself rather than one a user has to type. Only
            # `rtk proxy` was stepped over, which is the *rarest* form -- the
            # explicit escape hatch -- while every ordinary `rtk git clean -fdx`
            # resolved to a program called "rtk" and matched nothing.
            #
            # RTK's own meta commands (`rtk gain`, `rtk discover`) resolve to a
            # program named "gain" or "discover", which no rule matches, so they
            # need no special case.
            index += 1
            if segment[index : index + 1] == ["proxy"]:
                index += 1
            continue
        break
    if index >= len(segment):
        return None
    return segment[index], segment[index + 1 :]


#: Options whose value is a *separate* following token, keyed by program.
#:
#: Such a value is an ordinary token, so without skipping it the value lands in
#: the positionals and pushes the token that carries the meaning out of first
#: place: `git -c core.pager=cat clean -fdx` reads as subcommand
#: "core.pager=cat", and `ssh -p 2222 host "kubectl delete pod"` reads 2222 as
#: the destination and `host ...` as the remote command. Both then match
#: nothing. The valueless spellings (`git --no-pager clean -fdx`) were never
#: affected, which is what made the gap easy to miss.
#:
#: Only the separated spelling needs listing. `--git-dir=/x` and `-C/tmp` are
#: single tokens that never displace a positional.
_VALUE_TAKING_OPTIONS = {
    "git": frozenset(
        {"-c", "-C", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
    ),
    # ssh(1)'s value-taking options, in full. Both directions are unsafe: an
    # omission leaves a bypass, and a valueless option listed here swallows the
    # token after it, so the destination shifts and the remote command the
    # guard should scan disappears entirely. `-P` is the trap -- it took an
    # argument in neither current ssh(1) nor this list, though scp/sftp spell
    # their port option that way.
    "ssh": frozenset(
        {
            "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L",
            "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
        }
    ),
    # `xargs`' own options, so `_first_operand_index` can tell where its options
    # end and the command it runs begins. Only the spellings whose argument is
    # *required* belong here: GNU's optional-argument forms (`-e`, `-i`, `-l`,
    # and the `--eof` / `--replace` / `--max-lines` long spellings) take a value
    # only when it is attached, so listing them would swallow the command word
    # instead -- the same trap `ssh -P` was. `-J`, `-R` and `-S` are BSD's.
    "xargs": frozenset(
        {
            "-a", "-d", "-E", "-I", "-J", "-L", "-n", "-P", "-R", "-S", "-s",
            "--arg-file", "--delimiter", "--max-args", "--max-chars",
            "--max-procs", "--process-slot-var",
        }
    ),
}  # fmt: skip


def _value_options_for(program: str) -> frozenset:
    """Value-taking options for `program`, matching how the rules name it."""
    return _VALUE_TAKING_OPTIONS.get(program.rsplit("/", 1)[-1].lower(), frozenset())


def _normalize_options(
    args: list[str], value_options: frozenset = frozenset()
) -> tuple[set[str], list[str]]:
    """Split args into a set of short-option letters and positional arguments.

    Combined clusters (``-rf``), split short options (``-r`` ``-f``), and mapped
    long options (``--recursive`` -> ``r``) all reduce to the same letter set.
    Tokens after a ``--`` end-of-options marker are treated as positional only.
    A token in ``value_options`` consumes the one after it as its value, so the
    value is never mistaken for a positional -- see ``_VALUE_TAKING_OPTIONS``.
    """
    flags: set[str] = set()
    positionals: list[str] = []
    end_of_options = False
    skip_value = False
    for token in args:
        if skip_value:
            skip_value = False
            continue
        if end_of_options:
            positionals.append(token)
            continue
        if token == "--":
            end_of_options = True
            continue
        if token.startswith("--"):
            name = token.split("=", 1)[0]
            # An inline `--opt=value` carries its value already.
            skip_value = "=" not in token and name in value_options
            mapped = _LONG_OPTION_LETTERS.get(name)
            if mapped:
                flags.add(mapped)
            # Unknown long options carry no short letter; ignore them.
        elif token.startswith("-") and len(token) > 1:
            flags.update(token[1:])
            # Only the bare option takes a separate value; in a cluster
            # (`-rf`) or with the value attached (`-C/tmp`) it does not.
            skip_value = token in value_options
        else:
            positionals.append(token)
    return flags, positionals


def _first_operand_index(args: list[str], value_options: frozenset = frozenset()) -> int:
    """Index of the first non-option token, skipping any option's value operand.

    The complement of `_normalize_options`: that reports *what* the operands
    are, this reports *where* they start. A caller needs the second when the
    operands must keep their own flags, because rebuilding a command from
    `_normalize_options`' positionals discards them -- see the `xargs` branch of
    `_nested_payloads`.
    """
    index = 0
    skip_value = False
    while index < len(args):
        token = args[index]
        if skip_value:
            skip_value = False
        elif token == "--":
            return index + 1
        elif token.startswith("-") and len(token) > 1:
            # An inline `--opt=value` or `-I{}` carries its value already.
            skip_value = "=" not in token and token in value_options
        else:
            return index
        index += 1
    return index


# Programs that execute a payload argument as a fresh command. Without stepping
# into these, `bash -c "kubectl delete pod"` reads as a single `bash` call whose
# arguments happen to contain words, and the destructive command inside it is
# invisible to every rule below.
_NESTED_PAYLOAD_FLAG = {"bash": "-c", "sh": "-c", "zsh": "-c", "dash": "-c", "ksh": "-c"}

#: Database clients whose arguments can carry SQL. `DROP DATABASE` has no
#: program position of its own -- it is always an argument -- so it is scoped to
#: the clients that would run it rather than matched anywhere in the text.
_SQL_CLIENTS = frozenset({"psql", "mysql", "mariadb", "sqlite3"})

#: `<<<` feeds its operand to the program's stdin. When that program is a shell,
#: the operand is executed, so it is a nested payload like `-c` is -- unlike a
#: heredoc, which `_strip_heredoc_bodies` handles separately because its body
#: spans lines.
_HERESTRING = re.compile(r"<<<\s*(.+)$")

#: How deep to follow nested payloads. Two levels covers `ssh host "bash -c ..."`
#: without letting a crafted payload spin the guard.
_MAX_NESTING_DEPTH = 2


def _nested_payloads(program: str, args: list[str]) -> list[str]:
    """Command strings this invocation hands to another interpreter."""
    flag = _NESTED_PAYLOAD_FLAG.get(program)
    if flag is not None and flag in args:
        index = args.index(flag)
        return args[index + 1 : index + 2]
    if program == "ssh":
        # The first operand is the destination; everything after it is the remote
        # command, sliced verbatim so it keeps its own flags. Rebuilding from
        # `_normalize_options`' positionals instead worked only for the quoted
        # spelling, where the remote command is a single token that survives
        # intact; the equally legal bare spelling `ssh host rm -rf /` lost `-rf`
        # to the flag set and reduced to `/` (issue #215).
        #
        # Joined with plain spaces because that is what ssh(1) itself does: it
        # concatenates the remaining arguments and hands the result to the remote
        # *shell* as a string. So `ssh host sh -c 'rm -rf /'` really does run
        # `sh -c rm -rf /` remotely, and reproducing that faithfully means not
        # re-quoting. `xargs` below is the opposite case for the same reason.
        index = _first_operand_index(args, _value_options_for(program))
        return [" ".join(args[index + 1 :])] if index + 1 < len(args) else []
    if program == "xargs":
        # Followed whatever flags are present. Claude Code treats only a flagless
        # `xargs` as transparent, which is right for an *allow* rule -- granting
        # through a wrapper you have not fully parsed over-grants. A deny rule
        # wants the opposite: `xargs -I{} kubectl delete pod {}` still runs
        # `kubectl delete`, so not looking is the unsafe direction.
        #
        # Sliced out of the original tokens rather than rebuilt from the
        # positionals, because the command `xargs` runs is unquoted and
        # multi-token: its flags sit in `args` alongside `xargs`' own, so
        # `_normalize_options` strips them and `xargs rm -rf /` reduces to
        # `rm /` -- which no flag-keyed rule matches, and is not what was typed
        # either (issue #214). Only the rules keyed on a positional (`kubectl
        # delete pod`) survived that, which is why the gap stayed invisible.
        #
        # Re-quoted rather than space-joined, the opposite of `ssh` above and for
        # the same reason: `xargs` execs the argv it was given instead of
        # flattening it into a string, so a token that arrived quoted is still
        # one argument. Space-joining collapsed `["sh", "-c", "rm -rf /"]` into
        # `sh -c rm -rf /`, where `-c`'s operand reads as the bare word `rm` and
        # the payload disappears one level down (issue #215).
        index = _first_operand_index(args, _value_options_for(program))
        return [shlex.join(args[index:])] if index < len(args) else []
    return []


def _is_destructive_git(args: list[str], flags: set[str], positionals: list[str]) -> bool:
    """Whether a git invocation destroys uncommitted work, a ref, or published history.

    Matched on the subcommand *plus the flag that makes it destructive*, never
    the subcommand alone -- that is the whole precision budget here. `git
    checkout main`, `git restore --source=HEAD~1 file.ts`, `git stash`, `git
    branch -d merged` and `git push origin main` are ordinary work and stay
    allowed; only their forcing spellings are denied.

    `--force-with-lease` is deliberately left allowed. Refusing to overwrite
    work it has not seen is the entire point of that spelling, so denying it
    would push people toward plain `--force`, which is worse. It carries no
    short letter, so `_normalize_options` never folds it into `f`.

    `reflog expire` is here for the same reason the rest are: `reset --hard` and
    `branch -D` are survivable *because* the reflog exists, so destroying the
    reflog is what makes every other entry unrecoverable.
    """
    if not positionals:
        return False
    verb = positionals[0]
    operands = positionals[1:]
    force = "f" in flags
    if verb in {"checkout", "restore"}:
        # `-f` on either always means "discard whatever is in the worktree",
        # with or without a pathspec, so no operand is required. `--worktree` is
        # restore's own spelling for the same thing and carries no short letter.
        return force or "--worktree" in args
    if verb == "clean":
        return _is_destructive_git_clean(flags, positionals)
    if verb == "reset":
        return "--hard" in args
    if verb == "stash":
        return bool(operands) and operands[0] in {"clear", "drop"}
    if verb == "branch":
        return "D" in flags or ("d" in flags and force)
    if verb == "push":
        return force
    if verb == "filter-branch":
        # Unconditional: rewriting every commit is the only thing it does.
        return True
    if verb == "update-ref":
        return "d" in flags
    if verb == "reflog":
        return bool(operands) and operands[0] == "expire"
    return False


def _is_destructive_intent(
    program: str, args: list[str], segment: list[str], flags: set[str], positionals: list[str]
) -> bool:
    """Whether this invocation is one of the intents with no option-spelling bypass.

    Matched on the *program position* rather than anywhere in the command text.
    A regex over raw text is both noisier and leakier: it fires on any mention --
    a search pattern, a commit message, documentation -- while missing the
    ordinary spellings that put an option between the verb and its object, so
    `kubectl -n default delete deployment` slips straight through.
    """
    if program == "rm" and any(token == "sudo" for token in segment):
        return True
    if program == "git":
        return _is_destructive_git(args, flags, positionals)
    if program == "dropdb":
        return True
    if program == "kubectl" and "delete" in positionals:
        return True
    if program == "aws" and any(token.startswith("delete") for token in positionals):
        return True
    if program in _SQL_CLIENTS:
        return any("drop database" in token.lower() for token in args)
    return False


def _herestring_payloads(command: str) -> list[str]:
    """Operands of `<<<` on a line whose program is a shell, which executes them."""
    payloads: list[str] = []
    for line in command.splitlines():
        match = _HERESTRING.search(line)
        if match is None:
            continue
        program = _line_program(line)
        if program is None or program not in _SHELL_PROGRAMS:
            continue
        try:
            tokens = shlex.split(match.group(1))
        except ValueError:
            tokens = [match.group(1)]
        if tokens:
            payloads.append(tokens[0])
    return payloads


#: Which rule denied a command. A key rather than a bool because two of them
#: teach something the generic message cannot -- see `main`.
_DESTRUCTIVE = "destructive"
_RIPGREP_REPLACE = "ripgrep-replace"
_PIPE_TO_SHELL = "pipe-to-shell"


def _is_bare_interpreter(program: str, args: list[str]) -> bool:
    """Whether this invocation would execute *stdin* rather than a named script.

    `sh`, `bash -s`, `python3 -` read their program from stdin, so a fetch piped
    into one runs remote content. `sh ./install.sh`, `bash -c 'ls'` and `python3
    -m json.tool` all name what they run, and are ordinary.

    Tokens after `--` are arguments *for* the stdin script (`curl ... | sh -s --
    --yes`), so they are not a script operand and do not make it safe.
    """
    if program not in _STDIN_INTERPRETERS:
        return False
    for token in args:
        if token == "--":
            return True
        if not token.startswith("-"):
            return False
    return True


def _fetches_into_an_interpreter(segments: list[list[str]]) -> bool:
    """Whether one segment fetches a URL while another runs an interpreter on stdin.

    `_command_segments` drops the operator that joined two segments, so this
    cannot literally require a pipe; the bare-interpreter test does that work
    instead. It is also what keeps the two-step form allowed -- `curl -o x.sh
    URL; sh ./x.sh` names its script -- because fetching is not the problem and
    a shell with an operand is ordinary.

    This is a speed bump, not a boundary: fetching to a file and running it in
    two steps is still possible, and that is fine. The value is that the
    one-liner an agent just read in a README stops being frictionless.
    """
    fetches = False
    interprets = False
    for segment in segments:
        parsed = _program_and_args(segment)
        if parsed is None:
            continue
        program, args = parsed
        program = program.rsplit("/", 1)[-1].lower()
        if program in _FETCH_PROGRAMS:
            fetches = True
        if _is_bare_interpreter(program, args):
            interprets = True
    return fetches and interprets


#: A `$(...)` or backtick substitution. Its result is spliced into the command
#: line, so an interpreter handed one runs whatever it produced.
_COMMAND_SUBSTITUTION = re.compile(r"\$\(([^)]*)\)|`([^`]*)`")


def _substitution_fetches(payload: str) -> bool:
    """Whether a nested payload is a command substitution that fetches a URL.

    `sh -c "$(curl -fsSL https://example.com/i.sh)"` is the spelling most
    install docs publish, so it is the one an agent is most likely to copy. The
    substitution arrives as a single argument token, which is why the
    segment-relationship rule above cannot see it.
    """
    for dollar_form, backtick_form in _COMMAND_SUBSTITUTION.findall(payload):
        if _line_program(dollar_form or backtick_form) in _FETCH_PROGRAMS:
            return True
    return False


def _matched_rule(program: str, args: list[str], segment: list[str]) -> str | None:
    """Which deny rule this single command segment matches, or None.

    One dispatcher for every per-segment rule, so `_find_destructive_rule` can
    apply all of them at every nesting level. Keeping the option-normalized
    rules in a second, flat pass is exactly what let `sh -c 'rm -rf ~'` through
    while `sh -c 'dropdb prod'` was denied (issue #209): a new rule added to
    that pass would have inherited the same gap silently.
    """
    flags, positionals = _normalize_options(args, _value_options_for(program))
    if _is_destructive_intent(program, args, segment, flags, positionals):
        return _DESTRUCTIVE
    if _is_destructive_rm(program, flags, positionals):
        return _DESTRUCTIVE
    if _is_ripgrep_replace_cluster(program, args):
        return _RIPGREP_REPLACE
    return None


def _find_destructive_rule(command: str, depth: int = 0) -> str | None:
    """Scan a command, following payloads handed to a nested interpreter."""
    if depth > _MAX_NESTING_DEPTH:
        return None
    for payload in _herestring_payloads(command):
        rule = _find_destructive_rule(payload, depth + 1)
        if rule is not None:
            return rule
    segments = _command_segments(command)
    if _fetches_into_an_interpreter(segments):
        return _PIPE_TO_SHELL
    for segment in segments:
        parsed = _program_and_args(segment)
        if parsed is None:
            continue
        program, args = parsed
        program = program.rsplit("/", 1)[-1].lower()
        rule = _matched_rule(program, args, segment)
        if rule is not None:
            return rule
        for payload in _nested_payloads(program, args):
            if not payload:
                continue
            if program in _STDIN_INTERPRETERS and _substitution_fetches(payload):
                return _PIPE_TO_SHELL
            rule = _find_destructive_rule(payload, depth + 1)
            if rule is not None:
                return rule
    return None


# Targets that make a recursive force-delete catastrophic rather than routine.
# Exact matches; `_is_catastrophic_target` also handles the prefixed forms.
_CATASTROPHIC_TARGETS = frozenset({"/", "~", "/*", "~/*", "$HOME", "${HOME}", "$HOME/*"})


def _normalize_target(arg: str) -> str:
    """`arg` with redundant separators and `..` segments collapsed.

    `os.path.normpath` leaves exactly two leading slashes alone -- POSIX
    reserves `//` for the implementation -- so a path made only of separators is
    folded to "/" here instead.
    """
    normalized = os.path.normpath(arg)
    return "/" if set(normalized) == {"/"} else normalized


def _resolve_home() -> str | None:
    """The invoking user's home directory, normalized, or None if unusable.

    Resolved once per process: each hook invocation is a fresh interpreter, so
    there is nothing to invalidate, and a test can pin it through the
    environment.
    """
    home = os.path.expanduser("~")
    if not home or home == "~":
        return None
    normalized = _normalize_target(home)
    # A home of "/" -- a root shell with HOME=/ -- would make every absolute
    # path catastrophic and the guard useless. The root check covers that case
    # on its own.
    return None if normalized == "/" else normalized


_REAL_HOME = _resolve_home()


def _is_within(path: str, base: str) -> bool:
    """Whether `path` is `base` or sits under it, compared by whole segments.

    A raw `startswith` would read a sibling like `<home>XYZ` as living under
    `<home>`.
    """
    return path == base or path.startswith(base.rstrip("/") + "/")


def _is_catastrophic_target(arg: str) -> bool:
    """Whether an `rm` operand names the filesystem root or the user's home.

    Three spellings reach here, and the same deletion must be denied in all of
    them. Nothing expands an operand before this point -- shlex does not glob,
    and no shell runs -- so the literal `~`, `$HOME` and `${HOME}` forms are
    matched textually, and they must keep working when `$HOME` is unset or names
    someone other than the invoking user.

    The *expanded absolute* form arrives just as literally, and is the one a
    tool is most likely to produce, since anything that resolves a path before
    handing it over emits it. Matching it needs the real home, so that branch is
    separate: a tilde path and its expanded absolute twin name the same
    directory, and used to get opposite verdicts (issue #211).
    """
    if arg in _CATASTROPHIC_TARGETS:
        return True
    if arg.startswith(("~/", "$HOME/", "${HOME}/")):
        return True
    normalized = _normalize_target(arg)
    if normalized == "/":
        return True
    return _REAL_HOME is not None and _is_within(normalized, _REAL_HOME)


def _is_destructive_rm(program: str, flags: set[str], positionals: list[str]) -> bool:
    if program.lower() != "rm":
        return False
    recursive = "r" in flags or "R" in flags
    force = "f" in flags
    if not (recursive and force):
        return False
    return any(_is_catastrophic_target(arg) for arg in positionals)


def _is_destructive_git_clean(flags: set[str], positionals: list[str]) -> bool:
    """`git clean` deleting ignored and untracked files, in any flag spelling."""
    if not positionals or positionals[0] != "clean":
        return False
    return "f" in flags and "d" in flags and "x" in flags


def _is_ripgrep_replace_cluster(program: str, args: list[str]) -> bool:
    """True if an ``rg`` invocation bundles ``-r`` with another short flag.

    ripgrep's ``-r`` is ``--replace`` (takes an argument), not grep's
    ``--recursive`` -- ripgrep already searches recursively by default. A
    bundled cluster like ``-rn`` or an attached value like ``-rQQQ`` is
    indistinguishable from a typo'd ``--recursive``, so treat any short-option
    token longer than ``-r`` alone as suspect. A standalone ``-r`` token
    (``--replace`` with its value as a separate argument) is left alone.
    """
    if program.lower() != "rg":
        return False
    for token in args:
        if token == "--":
            break
        if token.startswith("--"):
            continue
        if token.startswith("-") and len(token) > 2 and "r" in token[1:]:
            return True
    return False


def _ripgrep_deny_message(command: str) -> str:
    return (
        "Blocked: '-r' in this rg command is ripgrep's --replace, not grep's --recursive."
        " ripgrep searches recursively by DEFAULT."
        "\n  rg -n PAT DIR        # line numbers, recursive by default"
        "\n  rg PAT DIR           # recursive by default"
        "\n  rg -r REPL PAT FILE  # only if you genuinely want --replace"
        f"\nCommand: {command}"
    )


def _pipe_to_shell_deny_message(command: str) -> str:
    return (
        "Blocked: this feeds fetched remote content straight into an interpreter."
        " Whatever that URL serves at this moment is what runs, unreviewed."
        "\n  curl -fsSL URL -o install.sh   # fetch it"
        "\n  less install.sh                # read what it actually does"
        "\n  sh ./install.sh                # then run it"
        f"\nCommand: {command}"
    )


def main() -> int:
    """Read the hook payload from stdin and deny the command if it matches a destructive pattern."""
    payload = _load_payload()
    if payload is None:
        return 0

    command = _extract_command(payload)
    if not command:
        return 0

    # Every rule reasons about the command with data-only heredoc bodies removed.
    # Deny messages still quote the original, so the user sees what they typed.
    scannable = _strip_heredoc_bodies(command)

    # One entry point, so every rule sees every nesting level. The only thing
    # left to decide here is which message the matched rule deserves.
    rule = _find_destructive_rule(scannable)
    if rule is None:
        return 0
    if rule == _RIPGREP_REPLACE:
        return _deny(_ripgrep_deny_message(command), payload)
    if rule == _PIPE_TO_SHELL:
        return _deny(_pipe_to_shell_deny_message(command), payload)
    return _deny(_deny_message(command), payload)


if __name__ == "__main__":
    raise SystemExit(main())
