---
name: raven-write-tests
description: Use when adding, fixing, or reviewing tests.
---

# Write Tests

## Skip When

- The task does not add or change behavior and no test gap is being addressed — run existing tests as an oracle instead.
- The user explicitly asks not to touch tests.

## Required Constraints

- Inspect nearby tests before adding a new pattern.
- Keep tests behavior-focused: tests should protect observable contracts so refactors can change internals without needless rewrites.
- Test names should describe the scenario and expected outcome, not the implementation.
- Tests should fail when observable behavior breaks; do not couple them to safe-refactor internals.
- Mock only true external boundaries: time, randomness, network, filesystem, process state, expensive services, unavailable platform APIs, or hard-to-trigger failure modes. Do not use mocks that merely restate implementation.
- Separate behavior changes from refactors: existing tests must be green before starting a refactor; add or update tests for behavior changes before changing the implementation.
- Run only the new or changed tests first.
- Broaden test scope only after narrow tests pass.
- Do not delete, weaken, or over-mock tests just to make a change pass.

## When Existing Tests Fail

Classify the failure before acting:

- **Regression** — the change broke real behavior; fix the code.
- **Stale assertion** — the test was tied to a contract that was intentionally changed; update the test.
- **Test bug** — the test was wrong before the change; fix the test and document why.
- **Environment issue** — flaky, timing-dependent, or platform-specific; fix or isolate the condition.
- **Pre-existing failure** — was already failing before the change; note it separately, do not fix as part of this change.

## Process

1. Use `rg` for similar test names and fixtures.
2. Use Semble if the relevant behavior is conceptually described but not obvious.
3. Add focused coverage for the behavior or regression.
4. Use RTK for noisy test output when exact raw output is not required.

## Avoid

- Do not chase line coverage; prefer meaningful scenarios, edge cases, regressions, and integration boundaries.
- Do not snapshot large irrelevant output.
- Do not add brittle timing or sleep-based tests unless unavoidable.
