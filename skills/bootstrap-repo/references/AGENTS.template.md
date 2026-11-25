# AGENTS.md

<!-- Bootstrap note: replace every <placeholder>, then delete the sections that do not apply.
     Keep only rules the code cannot show. Do not restate what the README says. -->

## Commands

- Format: `<format command>`
- Lint: `<lint command>`
- Test: `<test command>`
- Full gate (run before every push, must exit 0): `<gate command>`

## Safety and architecture boundaries

- <for example: never write to the user data directory; never edit generated files>
- <for example: the core module performs no I/O; the adapter layer owns it>

## Traps the code does not reveal

- <a non-obvious trap, with the reason it exists>

## Definition of done

- Every acceptance criterion in the issue is met, with a test that fails without the change.
- The full gate exits 0 on the exact head commit.
- No test was deleted, skipped or weakened.
- New dependencies are justified in one sentence in the PR.
