# agent-playbook: Blueprint

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
- **In-place renewal (default):** when a rotation trigger fires, the coordinator runs `playbook-registry.sh renew` and continues in a fresh context: `t3_thread_send` with `freshContext: true` in T3 Code, or `/clear` on the plain CLI. The thread keeps its id, so its guard, watches, heartbeat and live child callbacks carry over unchanged. Renew in place whenever the host can.
- **New-thread rotation (fallback):** use it only when the thread cannot be renewed in place. The fenced flow is:
  1. **Drain.** The predecessor runs `playbook-registry.sh drain <handoff-marker>` (add `--cancelled` if it will cancel children). Its entry becomes `draining`, which freezes new dispatches.
  2. **Drain or cancel.** Wait up to 15 minutes for active children, then cancel what is left with the host's cancel capability: `task_cancel` for delegated tasks, `t3_thread_interrupt` with `stop: true` for top-level threads. Bump the shift generation.
  3. **Launch idle and bind.** Launch the successor idle, with the marker in its prompt, and run `playbook-registry.sh bind-candidate <candidate-thread-id>`. The candidate's entry is in state `candidate`, and it cannot dispatch until takeover.
  4. **Recover and attach.** The candidate records receipt, recovers its state, attaches its watches, schedules the 20-minute heartbeat and acknowledges.
  5. **Take over atomically.** `playbook-registry.sh takeover <predecessor-thread-id> <handoff-marker>` makes the candidate the coordinator and sets the predecessor to `state: "retired"`. The predecessor's entry is never removed, so its guard keeps running. Only after takeover does the predecessor stop.
  6. **Abort on failure.** If anything fails before takeover, run `playbook-registry.sh abort <handoff-marker>`. The predecessor keeps the shift.
- A rotation that had to cancel children counts once, however many it cancelled. After the second such rotation, stop and escalate to the owner. Never start a third.

### Pre-tool guards

The guards are `PreToolUse` hooks for Claude Code and Codex. Each one does nothing until it is activated for a thread, so they are safe to register globally. The coordinator and reviewer guards are active when the thread id (`PLAYBOOK_THREAD_ID`, else T3 Code's `T3CODE_THREAD_ID`) is listed in their registry; `playbook-registry.sh` writes those registries. The worker guard is active when `PLAYBOOK_WORKER_WORKTREE` is set or, as a fallback, when the thread id is listed in the worker registry (`PLAYBOOK_WORKER_REGISTRY`, written with `playbook-registry.sh worker add`). A bare delegated launch with neither the variable nor a pre-registered entry is unguarded. The README shows the setup.

| Role | Allows | Denies |
|---|---|---|
| **Coordinator** | Read tools, read-only git and `gh`, `gh issue` create and comment, GET-only `gh api`, the publish broker, `playbook-registry.sh` (except removing itself), orchestration tools | Repo writes, builds, tests, mutating git, merges (CLI and forge tools), wait loops, new dispatches while draining or while its entry is a `candidate`. A `retired` entry keeps its guard, so the predecessor stays under these rules after takeover |
| **Worker** | Writes only inside its own worktree (`git -C "$WT"`); pushes only to `PLAYBOOK_WORKER_BRANCH` when set | Writes outside the worktree, pushes to protected branches (`PLAYBOOK_PROTECTED_BRANCHES`, default `main master develop`) |
| **Reviewer** | Claude Code's Read, Grep and Glob inside the review snapshot | Bash, every write tool, MCP tools, web access, sub-agents, paths that escape the snapshot |

A Codex reviewer reads through its shell, which the reviewer guard denies; run it in Codex's read-only sandbox with the snapshot as its working directory instead of registering it.

Guards need bash 4 or newer, `jq`, `git` and GNU coreutils. They stop a well-meaning agent from drifting. They are not defenses against a determined adversary; the hard boundaries are the credential and publishing boundaries in Tier 2.

## 3. Independent review

- **Context, not vendor:** an independent reviewer starts with a fresh context, has read-only tools, and reads only an exact snapshot. The same provider as the author is enough.
- **Snapshot:** export every tracked file of the exact head with no `.git` directory and no export attributes applied, put the diff against the base next to that tree (never inside it), and make the snapshot read-only. See `skills/blind-review`.
- **Packages:** `playbook-registry.sh review snapshot` builds the snapshot. With `--with-base` it writes a single-root package that also carries the base, so the reviewer opens one root. With `--fetch <remote> <ref>` it fetches the ref before exporting. `--fetch` is opt-in; without it the snapshot uses only the objects already present.
- **Exact tuple:** a verdict counts only for the `(PR, base, head)` it names. A new head needs new approval evidence: a new review, or, after a rebase, the evidence its classification defines (section 4).
- **Defects only:** the reviewer reports numbered defects with severity, file, impact and minimal fix. It skips style.

## 4. Publishing (Tier 2)

- **No push credentials on workers.** Workers commit locally and read from the remote. They hand the publisher the branch, the new head and the expected old remote head; a single publisher identity, serialized by one lock, performs every push, feature branches included.
- **Exact-SHA compare-and-swap:** publish only with a lease on the expected base. Never rebase during publish. If the base moved, route the PR to `rebase-and-fix`.
- **Rebase classifier:** after a rebase, classify the change as `FULL_HEAD_RE_REVIEW` (conflict, content change, base touches the PR, or a policy path), `MECHANICAL_CARRY_FORWARD` (clean, and the base delta touches only documentation), or `DELTA_RE_REVIEW` (anything else). Green CI on the new head is required in all three. Each outcome has its approval evidence for the new tuple: a full `APPROVE` (`FULL_HEAD_RE_REVIEW`), an `APPROVE` of the base delta that names the new tuple (`DELTA_RE_REVIEW`), or a carry-forward record that the publisher re-verifies itself (`MECHANICAL_CARRY_FORWARD`; see `skills/rebase-and-fix`). When the publisher cannot verify a carry-forward, it requires a full review.
- **Owner gate:** changes to CI, build, lint, ignore, lockfile, toolchain or agent-instruction files need the owner's signed approval on the exact head.
- **Verified patch equivalence:** compare patches with `git patch-id --verbatim`, never `--stable`.

## 5. Host admission and containment

- **Caps:** derive per-host concurrent job caps from core count and memory. The coordinator host runs no heavy builds.
- **Hysteresis:** pause new heavy jobs when memory use or pressure stall information (where available) rises above the high threshold, or free disk falls below its floor; resume once they are back past the low threshold.
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
