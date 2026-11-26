---
name: publish-pr
description: Publish one approved, green PR to the protected default branch by an exact-SHA compare-and-swap fast-forward, never rewriting reviewed commits, then confirm MERGED and clean up. Use when a PR is approved and green and needs to land, or when a publish stops because the default branch moved (the PR then goes to rebase-and-fix).
---

# Exact-SHA PR Publish Protocol

Publish a reviewed PR without changing a single reviewed commit SHA. The publish is a fast-forward compare-and-swap on the exact inputs, nothing else.

## 1. Exact Inputs Only
Require all of these as full 40-character lowercase OIDs and names:
- `pr`, `expected_base_oid`, `expected_head_oid`
- `host`, `branch`, `worktree_path`

Never accept a mutable ref (`HEAD`, a bare branch name) as a publish input.

## 2. Use the Project Publisher
Only the publisher runs this skill and pushes. At Tier 2 that is the one publisher identity; workers hand it their branch and SHAs and never push themselves.

At Tier 1, landing defaults to **operator-owned**: the operator lands the PR, or a dedicated publish run does. Use a dedicated exact-FF publisher only once it is configured **and** writes a durable intent record. A guarded worker never pushes: the worker guard refuses pushes to protected branches.

If the project provides an audited publish script or broker, call it with the validated tuple and read its exit code and log. Never bypass it. Never use the forge's "Rebase and merge" button, because it creates new, unreviewed commit SHAs.

## 3. Pre-Push Invariants (Fail Closed)
Stop at the first failed check:
1. **Reconcile first.** Resolve any unfinished publish record for this PR with the rules in section 7 before starting a new one.
2. **Writer freeze.** No implementer or fixer may be writing to the PR branch.
3. **Shape.** The PR is `OPEN`, targets the default branch, has `headRefOid == expected_head_oid`, has `expected_base_oid` as an ancestor of `expected_head_oid`, and has no merge commits.
4. **Base moved?** If the live default branch has moved past `expected_base_oid`, **do not rebase here**. Release the publish lock and route the PR as `NEEDS_REBASE` (section 5).
5. **Signatures.** Every commit in `expected_base_oid..expected_head_oid` passes `git verify-commit`.
6. **Gate provenance.** Run `git diff --no-renames --name-only -z <base> <head>`. If any CI, gate, policy, lint, ignore, lockfile or toolchain file changed, require the project's gate-owner approval on the exact `expected_head_oid`.
7. **Independent review.** Approval evidence exists for the exact `(pr, expected_base_oid, expected_head_oid)`, in one of these forms:
   - a current `APPROVE` for that tuple, or
   - a `DELTA_RE_REVIEW` approval from a fresh reviewer that names the exact new tuple, or
   - for a `MECHANICAL_CARRY_FORWARD`, a carry-forward record (`rebase-and-fix` section 4).

   Re-verify a carry-forward yourself with the same FULL-first predicate as `rebase-and-fix` section 4, in order:
   - no `FULL_HEAD_RE_REVIEW` trigger applies: the rebase was clean, and no gate-defining path changed (CI, build, lint, ignore, lockfile, toolchain, agent-instruction, policy or migration paths);
   - the base delta `B` is disjoint from the PR's paths `P` (`B ∩ P = ∅`) and lies strictly within the project's declared docs-only paths; with none declared, carry-forward is not available;
   - the old tuple has an `APPROVE`, and the ordered per-commit `git patch-id --verbatim` values of the old and new series are equal.

   If any check fails, the PR needs a full review. Reviews and records for other tuples do not count.
8. **Authoritative CI.** The required checks are `success` on the exact `expected_head_oid`.

## 4. Equivalence After a Rebase
When a PR was rebased and you must confirm its content did not change, compare patch IDs in verbatim mode, one commit at a time, in series order:
```bash
git -C "<repo>" show <old-commit> | git patch-id --verbatim
git -C "<repo>" show <new-commit> | git patch-id --verbatim
```
Use `--verbatim`, not `--stable`. `--stable` treats whitespace-only differences as equal, which hides real changes. A mismatch means the content changed and the PR needs a full re-review.

## 5. Non-Blocking NEEDS_REBASE Routing
`NEEDS_REBASE` is a routing outcome, not a failure of the queue:
1. Release this PR's publish lock and record `NEEDS_REBASE` with the old and current base OIDs.
2. Dispatch `rebase-and-fix` for the PR on its host, and classify the result with its three-outcome classifier.
3. Keep publishing the other approved PRs. One blocked PR never stalls the queue.

## 6. CAS Push, Confirmation and Hygiene
1. Record `INTENT` in the publish record, then push fast-forward only with a lease on the expected base:
   `git push --force-with-lease=refs/heads/<default>:<expected_base_oid> origin <head>:<default>`.
2. Confirm on the forge and in git. The PR must be `MERGED` at exact `expected_head_oid`, and `git merge-base --is-ancestor <head_oid> origin/<default>` must succeed. Re-poll up to three times, three seconds apart, for forge lag. Never mark the publish done from a local ref alone.
3. Close the publish record with `PUBLISHED`, delete the merged branch, remove the clean merged worktree (`safe-cleanup`), and confirm the linked issues closed.

## 7. Reconciling an Unfinished Publish Record
A record stays open if it has an `INTENT` but no close. Reconcile it before any new publish of the same PR:
1. **Exact merge confirmed** (the PR is `MERGED` at `expected_head_oid`, and `<head_oid>` is an ancestor of `origin/<default>`): close the record `PUBLISHED`, then finish the hygiene in section 6.3.
2. **Base and head unchanged, no effect on the forge** (the default branch is still at `expected_base_oid`, the PR is still at `expected_head_oid`, and it is not merged): nothing landed. Recheck every invariant in section 3, then retry under a fresh intent record.
3. **Base moved, or the PR conflicts with it:** do not push. Route the PR as `NEEDS_REBASE` (section 5).
4. **Anything else, or contradictory evidence:** stop and escalate to the owner. Never retry blind.
