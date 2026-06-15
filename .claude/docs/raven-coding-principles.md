# Coding Principles

These language-neutral principles apply across templates. Language-specific rules may add stronger constraints.

## Clarity Over Cleverness

- Favor clear naming and explicit logic over clever shortcuts.
- Prefer readable control flow, early exits, and small helpers over deeply nested conditionals.
- Do not add abstraction unless it removes real complexity, matches local patterns, or creates a useful boundary for tests.
- Write code that can be understood locally without forcing readers to chase unnecessary indirection.

## Maintainability

- Keep functions, methods, and modules focused on one responsibility.
- Prefer composition and dependency injection over inheritance-heavy or globally coupled designs.
- Preserve existing architecture and local conventions unless the task explicitly calls for changing them.
- Use the type system to make invalid states harder to represent.
- Use comments for intent, constraints, tradeoffs, or surprising behavior. Avoid comments that restate the code.
- Use documentation comments for public APIs and reusable framework-like code.

## Dependencies

- Prefer standard library and platform-native capabilities before adding dependencies.
- Add dependencies only when they remove meaningful complexity, are maintained, and fit the project’s risk profile.
- Ask before adding dependencies when repository instructions require approval.

## Security And Privacy

- Do not hardcode secrets.
- Treat user-derived, linkable, or sensitive values as private by default.
- Validate external input where malformed values could cause crashes, invalid state, injection, or data corruption.
- Avoid logging sensitive values unless the repository explicitly allows it and the log level/privacy treatment is appropriate.

## Performance

- Keep hot paths simple and avoid unnecessary work.
- Defer expensive object creation when it is not needed on the common path.
- Use caching only when the invalidation and correctness story is clear.
- Prefer measuring or reproducing performance issues before broad optimization.

## User-Facing Quality

- Build accessible, localizable user-facing UI when the product supports it.
- Do not rely on color alone to communicate state.
- Use locale-aware formatting for dates, times, numbers, measurements, and lists.
- Avoid layout assumptions that break with longer localized strings or right-to-left languages.
