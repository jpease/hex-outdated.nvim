---
name: raven-dotfiles
description: Use when editing home-directory configuration (dotfiles) — shell rc files, editor/WM/app config under ~/.config or $HOME — especially when files may be symlinked, generated, or managed by a tool like chezmoi, stow, yadm, bare-git, or Nix home-manager.
---

# Editing Dotfiles Safely

Follow this workflow whenever you edit home-directory configuration. The hazard is
that the live file is frequently not the source of truth, there is no test/build
gate, and bad configs often fail only at next login or reload.

## Workflow

1. **Locate the source of truth.** Before editing, determine whether the live file
   is real or a symlink/generated artifact of a managed source.
   - `ls -l <file>` to detect symlinks; follow the link.
   - Check for a managed source tree: a `dotfiles/` repo, a chezmoi source dir, a
     bare git work-tree, or a Nix/home-manager generation (read-only store path).
   - The tool ecosystem grows; treat the examples as a starting point and
     investigate. If you cannot determine the source, STOP and ask.

2. **Capture a revert path.** Before any risky edit, ensure you can undo:
   `git stash` / `git diff` in a tracked tree, the manager's diff or dry-run, or a
   plain copy of the file. Prefer dry-run/diff over in-place edits on managed trees.

3. **Edit the source, not the artifact.** Make the change in the source-of-truth
   file located in step 1.

4. **Validate syntax.** Run the validator for the format. Skip validators that are
   not installed; never claim a check you did not run.

   | Format | Check |
   |---|---|
   | bash/sh | `shellcheck <file>` |
   | zsh | `zsh -n <file>` (shellcheck zsh support is partial) |
   | fish | `fish -n <file>` (a.k.a. `--no-execute`) |
   | PowerShell | `Invoke-ScriptAnalyzer <file>` for lint; `pwsh` parse for syntax |
   | toml | `taplo lint <file>` |
   | yaml | `yq . <file>` (or yamllint) |
   | json | `jq . <file>` |
   | ssh config | `ssh -G -F <file> <host>` |
   | git config | `git config --list --file <file>` |

5. **State the apply step — never auto-apply.** Tell the user exactly how the change
   takes effect (source the file, reload the daemon, run the manager's apply) and
   warn if it can only fail at next login/restart.

6. **Secrets-scan before any commit.** Dotfiles are secret-dense. Run gitleaks (if
   available) or scan for tokens/keys before committing. Never commit secrets
   inline.
