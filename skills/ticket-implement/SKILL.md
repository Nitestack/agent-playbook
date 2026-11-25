---
name: ticket-implement
description: Implement one GitHub issue end to end in an isolated worktree with red-green TDD, foreground gate runs, signed linear commits and an exact-SHA PR. Use when the task is a single issue number to implement, from pre-flight to pull request.
---

# Ticket Implementation Protocol

Use this for one atomic issue (`#N`), from pre-flight to a PR that is ready for review.

## 1. Pre-Flight and Contract Check
1. Read `AGENTS.md`, plus any nested `AGENTS.md` for the stacks you touch, and the full issue `#N`: Goal, ACs, Non-Goals, Reuse, Protected Paths, Decisions.
2. Work on a clean branch from the latest `origin/<default>`. Confirm with `git merge-base --is-ancestor origin/<default> HEAD`. Never work on the default branch.
3. Check whether any AC already holds on the base. If so, make no synthetic diff. Pin it with a test, or cite the existing test and its output on the head SHA.
4. If an ambiguity affects scope, the data model, dependencies, credentials or a non-goal, stop and report `BLOCKED: <question and proposal>`. Small, reversible choices go under PR Assumptions.

## 2. Red-Green TDD and Isolation
1. Implement every AC completely, and nothing beyond the Non-Goals. Reuse named helpers and standard libraries.
2. For each behavioral AC, write or find a test that **fails without the change** (red), then make the smallest clean change that passes it (green).
3. Never delete, skip, mark ignored or weaken an existing test.
4. Keep tests and manual runs in throwaway temp directories and databases, with isolated git config. Never touch user data directories or global config.

## 3. Foreground Verification
1. Run the repository's full gate (format, lint, test, and the frontend checks if they apply) in the foreground until it exits 0.
2. If you changed UI, layout or client-side flow, run `browser-verify` against the exact candidate build.
3. Confirm every commit builds and passes on its own: linear history, no merge or fixup commits.

## 4. Commit, Push and Exact-SHA PR Handoff
1. Make a few clean, **signed** Conventional Commits. Never use `--no-verify` or `--no-gpg-sign`. If you rebase onto `origin/<default>`, rerun the gate after the final rebase.
2. Push the feature branch and open or update the PR against `<default>` with:
   - `Closes #N`
   - the exact `base_oid` and `head_oid` (40-character SHAs)
   - evidence per AC: test names and observed behavior
   - each new dependency with a one-sentence justification, and the Assumptions and Unverified lists.
3. Report only facts verified on the exact pushed head. No self-assessment prose.
