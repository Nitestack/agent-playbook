---
name: rebase-and-fix
description: Apply review fixes, resolve conflicts, renumber migrations and rebase a PR onto a moved default branch, then classify the change as FULL_HEAD_RE_REVIEW, MECHANICAL_CARRY_FORWARD or DELTA_RE_REVIEW. Use when a PR is REQUEST_CHANGES, reports NEEDS_REBASE, or conflicts with a moved base.
---

# Rebase and Fix Worker Protocol

Use this when an existing PR needs review fixes, conflict resolution, migration renumbering or a rebase onto a moved base. It keeps all hands-on work out of the orchestrator.

## 1. Safe Pre-Check (Ticket-Host Affinity)
1. Run on the **same host and worktree** as the original ticket whenever it exists.
2. Read `git status` and `git log --oneline -n 10` first. Never run a blind `git reset --hard` that could discard unpushed work.
3. Record `old_base_oid` and `old_head_oid` before changing anything. The classifier needs them.

## 2. Apply Review Findings
For each numbered finding, either:
- fix the root cause with a regression test that fails before the fix, or
- record a concrete technical objection if the finding is factually wrong.

Keep the scope to the ticket's ACs and the findings. No unrelated refactoring.

## 3. Rebase and Resolve
1. `git fetch origin`, then rebase onto `origin/<default>`.
2. Resolve conflicts cleanly. Hotspot files (module roots, manifests, lockfiles, shared registration files) are expected conflict points. Do not treat them as blockers.
3. Renumber new migrations to the next free number after the final rebase, and update the version assertions that depend on them.
4. Every commit in the rebased series must be **signed** and **green on its own**. Squash broken intermediate commits. No merge or fixup commits.
5. Run the repository's full gate in the foreground on the final head, and per commit if commits were reordered or edited.

## 4. Classify the Change (Three Outcomes)
Compare the old and new series with patch IDs in verbatim mode, and classify:

1. **`FULL_HEAD_RE_REVIEW`**: any of these
   - a conflict was resolved by hand,
   - `git patch-id --verbatim` differs for any commit pair (`git patch-id --verbatim` treats whitespace as significant, so this catches real content changes),
   - the base delta `B` touches a file the PR touches (`B ∩ P ≠ ∅`),
   - the change touches a **gate-defining path**: CI, build, lint, ignore, lockfile, toolchain, agent-instruction or policy files, or the migration directory.
2. **`MECHANICAL_CARRY_FORWARD`**: the rebase was clean **and** the base delta touches only documentation paths the project declares as docs-only.
3. **`DELTA_RE_REVIEW`**: anything else. A fresh read-only reviewer checks the base delta `B` against the PR's interfaces.

Green CI on the new head is required in **all three** outcomes.

## 5. Push and Hand Off
1. Push with a lease on the old head, never a plain force: `git push --force-with-lease="refs/heads/<branch>:<old_head_oid>" origin <branch>`.
2. Return a compact handoff:
   - **Tuple transition:** `old (base, head) -> new (base, head)`
   - **Classification:** `FULL_HEAD_RE_REVIEW` | `MECHANICAL_CARRY_FORWARD` | `DELTA_RE_REVIEW`, with the reason
   - **Findings disposition:** `FIXED (<sha>)` or `NO-FIX (<reason>)` for each finding
   - **Gate result:** exit status on the exact new head.

Routing is non-blocking. The orchestrator keeps other PRs moving while this one waits for its re-review.
