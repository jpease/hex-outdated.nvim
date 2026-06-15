---
name: raven-dependency-update
description: Use when reviewing or applying dependency changes, version bumps, lockfile updates, or supply-chain-sensitive package work.
---

# Dependency Update

Use this skill when a task changes package manifests, lockfiles, dependency versions, tool versions, vendored code, or supply-chain controls.

## Process

1. Identify every manifest, lockfile, tool config, and generated dependency artifact touched by the change.
2. Confirm whether the update is direct, transitive, security-driven, compatibility-driven, or tooling-only.
3. Prefer the repository's package-manager and task-runner commands over ad hoc edits.
4. Review release notes, migration notes, advisories, license changes, and major-version compatibility before applying non-trivial updates.
5. Keep lockfiles consistent with manifests. Do not hand-edit lockfiles unless the ecosystem explicitly expects it.
6. Run the narrowest dependency validation first, then the relevant test, lint, typecheck, build, or audit command.
7. Record residual risk, skipped checks, or required follow-up issues before handoff.

## Pause And Ask

Pause before adding a new dependency, changing license-sensitive packages, accepting vulnerable versions, replacing maintained libraries, vendoring code, or broadening install-time/network behavior.

## Review Checklist

- The dependency source and version are intentional.
- The lockfile delta matches the manifest change.
- Major-version or breaking changes are accounted for.
- Security advisories and license constraints were considered.
- Generated files are expected and reproducible.
- CI or local verification covers the affected runtime.

## Avoid

- Do not update unrelated dependencies to reduce diff noise.
- Do not weaken audit, integrity, or lockfile checks just to make an update pass.
- Do not copy package code into the repo without explicit approval and license review.
