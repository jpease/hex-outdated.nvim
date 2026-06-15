---
name: raven-security-review
description: Use before shipping changes that touch auth, file I/O, shell commands, network calls, database queries, config parsing, secrets, or other security-sensitive boundaries.
---

# Security Review

Systematic security review for in-scope changes. Prefer deterministic findings first, then use judgment for risks scanners cannot prove.

Reference `.claude/rules/raven-security.md` for baseline security rules and `.claude/docs/raven-semgrep.md` for Semgrep CE setup.

## Skip When

- The change is docs-only.
- The change is test-only and does not add new fixtures, helpers, or test-only services that touch security-sensitive boundaries.
- The change is a one-line config or metadata edit with no parsing, permissions, network, filesystem, command, secret, or dependency behavior.
- A broader security review was already completed for the same unchanged diff and its verification is still current.

## Trigger Heuristics

Use this skill when a change touches:

- authentication, authorization, sessions, permissions, roles, tenants, or ownership checks
- input parsing, validation, deserialization, templating, or config loading
- filesystem reads, writes, deletes, archive extraction, path joins, uploads, downloads, or temp files
- shell commands, subprocesses, dynamic evaluation, plugins, hooks, or generated code
- database queries, migrations, search filters, object lookups, or multi-tenant data access
- network calls, webhooks, redirects, CORS, CSP, request signing, or external integrations
- secrets, credentials, tokens, keys, environment variables, logging, telemetry, or error reporting
- dependency additions, version changes, vendored code, or security-tool configuration

## Required Constraints

- Run a Semgrep CE scan before the manual checklist when Semgrep is available.
- Use `mcp__semgrep__semgrep_scan` with `--config auto` by default. Use `p/owasp-top-ten`, `p/security-audit`, or `semgrep_scan_with_custom_rule` only when the change calls for a narrower or project-specific scan.
- Do not treat a clean scan as proof of security; it is evidence for mechanical patterns only.
- Review scanner findings manually before reporting them. Separate confirmed findings from false positives and open questions.
- Keep the checklist language-neutral. Put language-specific remediation details in the relevant language quality docs or local project conventions.
- If Semgrep is unavailable, state that gap and continue with the manual checklist rather than skipping the review.

## Process

1. Identify changed files and the security-sensitive boundaries they touch.
2. Run Semgrep CE on the changed files first, using `--config auto` unless a narrower CE ruleset is more appropriate.
3. Triage Semgrep results: confirmed issue, false positive, or needs human judgment.
4. Manually review untrusted input paths: validation, normalization, encoding, and trust-boundary crossing.
5. Manually review auth/authz: identity source, permission checks, tenant or ownership isolation, and bypass paths.
6. Manually review file, shell, database, network, and parser operations for injection, traversal, confused-deputy behavior, unsafe defaults, and destructive side effects.
7. Manually review secrets and error disclosure: hardcoded values, logs, telemetry, stack traces, user-facing messages, and storage.
8. Manually review business logic: abuse cases, replay or duplicate delivery, rate limits, state transitions, and privilege changes that scanners cannot infer.
9. Verify relevant tests or checks. Add regression coverage when the issue is concrete and reproducible.

## Output

Lead with confirmed findings by severity. Use this shape:

- `Severity`: file:line when available, confidence, issue, impact, suggested fix.
- `Semgrep`: command or tool used, result summary, and any findings triaged as false positives or open questions.
- `Manual checklist`: boundaries reviewed and notable residual risks.
- `Verification`: tests, scans, or checks run; state anything not run.

If no issues are found, say that clearly and still report Semgrep coverage, manual areas reviewed, and residual risk.
