---
name: raven-review-pr
description: Use when reviewing a diff, branch, or proposed patch for correctness and maintainability.
---

# Review PR

## Skip When

- The user did not ask for a review of a diff, branch, PR, or proposed patch.
- The task is to implement changes rather than assess existing changes.

## Required Constraints

- Findings must lead the response, ordered by severity.
- Each finding must include file/line evidence when available, severity, confidence, why it matters, and a suggested fix.
- Do not report style-only issues unless they violate documented conventions.
- Do not invent risk. If evidence is weak, state it as an open question instead of a finding.
- Do not over-compress semantic diffs when reviewing correctness.

## Process

1. Inspect changed files and diff summary.
2. Use full diff when necessary.
3. Use LSP diagnostics on changed files.
4. Use GitNexus for changed public APIs or shared modules.
5. Use tests and build output through RTK.
6. Report issues by severity: correctness, safety/security, maintainability, test coverage, and performance.

## Output

Use this shape:

- `Severity`: file:line, confidence, issue, impact, suggested fix.
- `Open questions`: only when needed.
- `Residual risk`: checks not run or areas not reviewed.
