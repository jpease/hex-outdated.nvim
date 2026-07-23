# Run the pure busted suite (no Neovim required)
test:
    busted

# Run the headless-Neovim integration suite
test-nvim:
    nvim --headless -u NONE -l test/run.lua

# Run lint checks
lint:
    luacheck .

# Format the codebase in place
format:
    stylua .

# Check formatting without modifying files
fmt-check:
    stylua --check .

# Fast static checks for the pre-commit hook (no tests)
check-fast: fmt-check lint

# Run the standard local verification set (also runs in the pre-push hook).
# A successful run credits the pre-push stamp too, so a manual `just check`
# right before pushing skips a redundant rerun in the hook.
check: check-fast test test-nvim
    [ -f .raven/git-hooks/lib/with-verified-cache.sh ] && sh .raven/git-hooks/lib/with-verified-cache.sh check true || true

# List open issues with hierarchy and priority
list-open:
    ./scripts/list_open_issues.py

# Install pre-commit (fast checks) and pre-push (full check) git hooks
install-hooks:
    #!/usr/bin/env sh
    # Resolve Git's effective hooks dir (honors core.hooksPath and linked
    # worktrees) so hooks land where Git will run them, not a hard-coded
    # .git/hooks that a custom hooksPath would ignore.
    hooks_dir=$(git rev-parse --git-path hooks) || exit 1
    install_hook() {
        name="$1"
        cmd="$2"
        path="$hooks_dir/$name"
        if [ -f "$path" ]; then
            echo "A $name hook already exists at $path."
            echo "To use RAVEN's gate, add this line to it:"
            printf "  %s\n" "$cmd"
        else
            mkdir -p "$hooks_dir"
            printf '#!/bin/sh\n%s\n' "$cmd" > "$path"
            chmod +x "$path"
            echo "Installed $path to run '$cmd'."
        fi
    }
    install_hook pre-commit "just check-fast"
    install_hook pre-push "just check"
