# Test Rules

Core test discipline (narrowest-first, failing-output-first, RTK for noise) is in `AGENTS.md`. This file adds Claude-scoped specifics:

- Add tests near existing coverage and follow local naming and fixture patterns.
- Avoid brittle sleeps, timing assumptions, and oversized snapshots unless the codebase already relies on them.
