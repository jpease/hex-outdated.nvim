# Machine-local recipes (not committed); `import?` skips it when absent.
import? 'private.just'

# Run the busted suite (no Neovim required)
test:
    busted

# Run the headless-Neovim integration suite
test-nvim:
    nvim --headless -u NONE -i NONE -l test/run.lua

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

# Full local verification (also run by the pre-push hook)
check: check-fast test test-nvim

# Install pre-commit (fast checks) and pre-push (full check) git hooks
install-hooks:
    #!/usr/bin/env sh
    # Honors core.hooksPath and linked worktrees.
    hooks_dir=$(git rev-parse --git-path hooks) || exit 1
    install_hook() {
        name="$1"
        cmd="$2"
        path="$hooks_dir/$name"
        if [ -f "$path" ]; then
            echo "A $name hook already exists at $path."
            echo "Add this line to it to run the project checks:"
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
