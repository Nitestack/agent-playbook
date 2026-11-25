# Universal Agentic Setup: Blueprint

This is the living architecture document for the agent playbook. It is portable: it names no hosts, accounts or private repositories. The rationale and the round-by-round history live in the [archive](archive/README.md), which is frozen and never loaded at runtime.

## Tiers

Adopt the tiers in order. Move to the next tier only when its trigger is real.

| Tier | Applies to | What you turn on |
|---|---|---|
| **Tier 0** (solo or quick repo) | Scripts, experiments, configuration repos | A lean global skill baseline, a short `AGENTS.md` with verifiable commands, and repo-scoped stack skills |
| **Tier 1** (active product repo) | Any repo with pull requests and parallel agents | Tier 0, plus a shift-based orchestrator, `PreToolUse` guards for coordinator, worker and reviewer roles, `blind-review`, and `browser-verify` for UI repos |
| **Tier 2** (multi-host publishing) | Several hosts writing code that lands on a protected branch | Tier 1, plus brokered publishing (workers hold no push credentials), an owner gate for policy paths, and per-host admission control |

Bootstrap a repo with the `bootstrap-repo` skill. It reads only the templates for the tier it is applying.

## 1. Global skill baseline

Deploy skills as files, not as code:

- **Filter:** deploy only `SKILL.md` and `references/**/*.md`. Scripts, shims and embedded hooks from external packs are never materialized.
- **Assertions:** fail the build on duplicate directory names, duplicate frontmatter `name:` values, or references to files that were stripped.
- **Collisions:** check the global catalog against each repo's stack skills before a name is chosen. A repo skill named like a global one is silently shadowed.
- **Size:** keep the global set small. The consensus baseline is **28** skills: the ten workflow skills in this repository plus about eighteen vetted, domain-agnostic skills for debugging, planning, testing, git hygiene, security review and verification.

Stack-specific skills (a framework, a language's build tool, a deploy stack) live in the repo, under `.claude/skills/` and `.agents/skills/`. See `skills/bootstrap-repo/references/stack-packs.md`.

## 2. Shift-based orchestration

- **Unit:** one orchestrator thread equals one shift, which covers one milestone slice. Never run a forever-thread, and never one thread per ticket.
- **Parallelism by default:** fill every free worker slot with ready work. Overlapping files are absorbed by isolated worktrees and by non-blocking `NEEDS_REBASE` routing (see `skills/rebase-and-fix`). Do not serialize dispatch in advance.
- **Rotation triggers:** `compactions >= 2`, or `dispatches_in_shift >= 40`, or `shift_age >= 6h`, or milestone completion.
- **Drain-or-cancel handoff:**
  1. Freeze new dispatches (`draining = true`).
  2. Wait up to 15 minutes for active children. Cancel what is left: `task_cancel` for delegated tasks, `t3_thread_interrupt(stop: true)` for top-level threads. Bump the shift generation.
  3. If cancellations reach two, stop and escalate to the owner. Never cancel a third time.
  4. Launch the successor. The old shift stays alive until the successor records receipt, attaches its watches, schedules a heartbeat and acknowledges.

### Pre-tool guards

The guards are `PreToolUse` hooks. Each one is inert unless its thread is registered, so they are safe to register globally.

| Role | Allows | Denies |
|---|---|---|
| **Coordinator** | Read tools, read-only git and `gh`, `gh issue` create and comment, GET-only `gh api`, the publish broker, orchestration tools | Repo writes, builds, tests, mutating git, merges, new dispatches while draining |
| **Worker** | Writes only inside its own worktree (`git -C "$WT"`), pushes only to its feature branch | Writes outside the worktree, pushes to protected branches |
| **Reviewer** | Read, Grep and Glob inside the review snapshot | Bash, every write tool, MCP tools, web access, sub-agents, paths that escape the snapshot |

Guards need only `bash`, `jq` and coreutils. They stop a well-meaning agent from drifting. They are not defenses against a determined adversary; the hard boundaries are the credential and publishing boundaries in Tier 2.

## 3. Independent review

- **Context, not vendor:** an independent reviewer starts with a fresh context, has read-only tools, and reads only an exact snapshot. The same provider as the author is enough.
- **Snapshot:** export the exact head tree with no `.git` directory, write the diff against the base into the snapshot, and make the snapshot read-only.
- **Exact tuple:** a verdict counts only for the `(PR, base, head)` it names. A new head needs a new review.
- **Defects only:** the reviewer reports numbered defects with severity, file, impact and minimal fix. It skips style.

## 4. Publishing (Tier 2)

- **No push credentials on workers.** Workers commit locally and read from the remote. A single publisher identity, serialized by one lock, performs every push.
- **Exact-SHA compare-and-swap:** publish only with a lease on the expected base. Never rebase during publish. If the base moved, route the PR to `rebase-and-fix`.
- **Rebase classifier:** after a rebase, classify the change as `FULL_HEAD_RE_REVIEW` (conflict, content change, base touches the PR, or a policy path), `MECHANICAL_CARRY_FORWARD` (clean, and the base delta touches only documentation), or `DELTA_RE_REVIEW` (anything else). Green CI on the new head is required in all three.
- **Owner gate:** changes to CI, build, lint, ignore, lockfile, toolchain or agent-instruction files need the owner's signed approval on the exact head.
- **Verified patch equivalence:** compare patches with `git patch-id --verbatim`, never `--stable`.

## 5. Host admission and containment

- **Caps:** derive per-host concurrent job caps from core count and memory. The coordinator host runs no heavy builds.
- **Hysteresis:** pause new heavy jobs above the high threshold and resume below the low threshold. Use at least memory use, pressure stall information where available, and free disk.
- **Out-of-memory:** run a user-slice out-of-memory daemon with the pressure-kill policy on worker hosts.
- **Credential separation:** no owner token in any agent shell. No agent has general passwordless `sudo`.

## 6. Lean host configuration switch

Deploy a host configuration only from an exact, verified revision. This is a sketch; the lean form is the default.

1. Take an exclusive lock.
2. As the unprivileged operator, check that the tree is clean and create a single-ref bundle in a private directory.
3. As root, fetch the bundle into a fresh, root-owned bare repository with system and global git config disabled and a pinned signing program. Verify the owner's signature on the revision and refuse a rollback below the last deployed revision.
4. Export the verified revision to a fresh directory. Show a diff of the sensitive paths (policy, allowed signers, hooks). Require a human confirmation.
5. Switch. On success, record the revision. On failure, stop and leave the decision to the operator at the console.

## Reading guide

- Start a new repo: `skills/bootstrap-repo/SKILL.md`, then the tier's templates.
- Run a milestone: `skills/orchestrate/SKILL.md`.
- Implement one issue: `skills/ticket-implement/SKILL.md`.
- Review a head: `skills/blind-review/SKILL.md`.
- Land a reviewed PR: `skills/publish-pr/SKILL.md`.
- Fix or rebase a PR: `skills/rebase-and-fix/SKILL.md`.
- Verify UI changes: `skills/browser-verify/SKILL.md`.
- Recover disk space: `skills/safe-cleanup/SKILL.md`.
- Learn from a run: `skills/session-miner/SKILL.md`.
- Decide a high-impact design question: `skills/council-review/SKILL.md`.
