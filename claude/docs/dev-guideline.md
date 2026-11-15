# Development Guideline

Read by implementation skills and by the steps of a workflow that change code, and given to code reviewers. It applies to any language or framework.

The project's instructions (the root `AGENTS.md`, and the root `CLAUDE.md` if it has instructions of its own) take precedence over this document. Where they say nothing, follow this document.

## Hard rules

Work that breaks any of these is not done, whatever the tests say. A code review reports any break as a P0 or P1 finding.

1. No secrets in code, configuration, tests, or logs. Read them from the environment or the project's secret store
2. Never disable, skip, or delete tests, and never weaken assertions, to make a check pass
3. Never suppress or swallow an error to make it go away. Fix the cause, or record it where the next person will see it
4. No debugging leftovers: temporary files, debug output, commented-out code, or stray notes added for the work
5. No change outside what the task needs. Record other problems you notice instead of fixing them on the side
6. New behaviour comes with tests that check the behaviour, including its error cases
7. Follow the conventions of the surrounding code: naming, structure, error handling, and the style tools the project uses
8. Add a dependency only when it is needed. Check its license and maintenance status first

## Guidelines

Use judgment. A reviewer may point these out, but they do not on their own make work not done.

### Design
- Keep the code small and the change easy to review. Split large changes into steps
- Keep user interface code separate from logic
- One source of truth for each piece of knowledge; avoid duplication
- Names should state intent

### Errors and reliability
- Detect errors early, and make messages say what failed and what to do about it
- Set timeouts on calls to other systems. Retry only operations that are safe to repeat, with backoff
- Log enough to diagnose a failure, never secrets or personal data

### Tests
- Test behaviour, not implementation details
- Tests are independent of each other and of the order they run in
- Keep tests fast. Coverage is an indicator, not a goal

### Performance
- Optimize based on measurement, not guesses
- Avoid repeated queries in loops and fetching more than needed
- When caching, decide how entries expire and are invalidated

### Security
- Grant the least privilege that works
- Treat input from outside the program as untrusted: validate it, and keep it out of queries and commands except through safe interfaces

### Documentation
- Update documentation in the same change as the code it describes
- When an interface the project documents changes (an API, a CLI, a configuration format), update that documentation in the format the project already uses
- Record significant design decisions where the project keeps them. Record known technical debt explicitly

### Version control
- Follow the project's branching and commit-message policy
- Keep each commit to one logical change
