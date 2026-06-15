---
name: raven-safe-refactor
description: Use for renames, shared abstraction changes, API changes, moved code, or broad mechanical edits.
---

# Safe Refactor

## Skip When

- The edit is isolated, internal, and does not rename, move, or change a contract.
- The task is a behavior change rather than a structure-preserving refactor.

## Required Constraints

- Do not combine refactor and behavior change unless asked.
- Capture reference or dependency evidence before editing public or shared symbols.
- Use syntax-aware tools for broad mechanical changes when available.
- Verify textual leftovers with `rg` after renames, moves, or API changes.
- Stop and ask or delegate when ownership, references, or blast radius remain unclear after targeted retrieval.
- Do not reformat unrelated files.
- Run targeted tests or explain why no targeted verification exists.

## Process

1. Identify public surface area.
2. Use LSP references before editing. If similar implementations may exist elsewhere, use Semble `find_related` on the symbol or pattern to find them too.
3. Use GitNexus for dependency and blast-radius analysis.
4. Use ast-grep or Semgrep for mechanical syntax-aware rewrites.
5. Use `rg` to verify no textual leftovers.
6. Run targeted tests.
7. Summarize contract changes.

## When To Stop

Stop before editing when LSP, GitNexus, text search, or syntax-aware search cannot establish the references, ownership, or blast radius of the refactor. Summarize the missing evidence and delegate per AGENTS.md Delegation guidance, or pause and ask the user if the safe change depends on intent or compatibility decisions.
