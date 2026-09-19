#!/usr/bin/env sh
#
# Launch a Raven agent hook with whatever Python the machine has.
#
# `.claude/settings.json` used to invoke `python` directly. On a machine that
# ships only `python3` -- the default on macOS and most Linux distributions --
# that name resolves to nothing and every hook stops running. Because the
# hooks are deliberately fail-open, there is no signal when that happens: the
# edit guard, the bash guard, the roster and the formatter simply cease to
# exist, silently. The resolution order matches `.raven/git-hooks/`, so a
# checkout has one answer to "which Python runs Raven's tooling".
#
# Claude-only, by construction. `.codex/hooks.json` cannot use this shim: a
# Codex hook may run with a process cwd outside the project, so nothing
# repo-relative can be located until the JSON payload on stdin has been parsed
# (see CANONICAL_CODEX_LAUNCHER in tests/test_agent_hooks.py, and issues #115
# and #129). Claude Code exports $CLAUDE_PROJECT_DIR, which is what makes a
# fixed shim path resolvable here and not there.
#
# Usage: raven-run-hook.sh <script> [args...]
#   <script> is absolute, or relative to the project root.

set -u

if [ "$#" -lt 1 ]; then
    echo "raven-run-hook: usage: $0 <script> [args...]" >&2
    exit 0
fi

script="$1"
shift

# Anchor on this script's own install location rather than the working
# directory: a hook's cwd is not reliably the project.
case "$script" in
    /*) ;;
    *)
        hooks_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 0
        project_root=$(CDPATH='' cd -- "$hooks_dir/../.." && pwd) || exit 0
        script="$project_root/$script"
        ;;
esac

# Resolve a Python launcher, verifying it actually runs.
#
# Order matters on Windows: `python3` there is normally the WindowsApps App
# Execution Alias, which opens the Microsoft Store instead of running anything.
# `command -v python3` finds it, so a presence check alone selects a launcher
# that does nothing -- and because these hooks are fail-open, nothing reports
# it. `py -3` is the reliable launcher there, `python3` everywhere else, and
# `-c ""` confirms whichever we picked can execute at all.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*|Windows*) _candidates="py|python|python3" ;;
    *) _candidates="python3|python|py" ;;
esac

RAVEN_PY=""
_rest="$_candidates"
while [ -n "$_rest" ]; do
    _candidate=${_rest%%|*}
    [ "$_rest" = "$_candidate" ] && _rest="" || _rest=${_rest#*|}
    [ "$_candidate" = "py" ] && _candidate="py -3"
    # shellcheck disable=SC2086
    if command -v ${_candidate%% *} >/dev/null 2>&1 && $_candidate -c "" >/dev/null 2>&1; then
        RAVEN_PY="$_candidate"
        break
    fi
done

if [ -n "$RAVEN_PY" ]; then
    # shellcheck disable=SC2086
    exec $RAVEN_PY "$script" "$@"
fi

# Fail open, but say so. Exiting non-zero would block the tool call this hook
# was guarding, and a hook that cannot run must never be the reason work stops.
# The message is the only signal that a guard silently stopped existing.
echo "raven-run-hook: no working Python launcher (py, python3, python) found; skipped $script" >&2
exit 0
