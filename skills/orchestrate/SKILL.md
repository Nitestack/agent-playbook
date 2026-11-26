---
name: orchestrate
description: Run or take over an orchestrator shift for one milestone slice that splits work, dispatches workers and reviewers, and merges, without hands-on coding. Use when starting an orchestrator thread, taking over from a rotated shift, or when a shift hits a rotation trigger.
---

# Orchestrator Shift Protocol

An orchestrator is a **dispatcher, not a mechanic**. It owns scheduling, triage, review triggers and publish triggers for **one milestone slice**. It never owns a project forever, and it never turns into a forever-thread that accumulates context until it drifts.

## 0. Shift Model
- **1 orchestrator thread = 1 shift = 1 milestone slice.** Never one thread per ticket, never one thread for the whole project.
- A shift **renews or rotates** when any trigger fires:
  - `compactions >= 2`, or
  - `dispatches_in_shift >= 40`, or
  - `shift_age >= 6h`, or
  - the milestone slice is complete.
- Renewal is proactive. Do not wait for the thread to break. Section 5 says how.

## 1. Unified Startup (Mandatory)
Run this startup in **every** context: Generation 1, each in-place renewal, and each rotated successor. Rebuild ground truth from external authorities, never from memory:
1. Read the repo's `AGENTS.md`, its orchestration handbook if it has one (for example `docs/orchestration.md`), and any state location the project names. A coordinator cannot write the project state directory directly. Its durable shift metadata lives in the coordinator registry (`playbook-registry.sh`), plus issues and PRs.
2. Inspect open issues and open PRs with the forge CLI (`gh issue list`, `gh pr list`).
3. Inspect live child threads and linked hosts. Reconcile stale leases and unfinished publish records before dispatching anything.
4. Attach a PR watch to each open PR, then read each watched PR immediately. A callback that arrived before the watch existed must not be lost.
5. Ensure a **thread-bound 20-minute heartbeat** is scheduled while any open PR or active child exists.

## 2. Role Boundary
- **Never** edit feature code or tests, debug failing tests over SSH, resolve conflicts by hand, or run build and test gates in the orchestrator's own turn.
- **Never** block waiting for CI or a merge queue (no wait loops, no long foreground scripts). Stop the turn and let the wakeup do it.
- Any PR that needs code fixes, a rebase, migration renumbering or a gate rerun goes to a worker with `rebase-and-fix` on the ticket's existing host.
- **Guards.** The operator enrolls the first shift before it starts (`playbook-registry.sh coordinator add <thread-id>`). A worker is guarded only if it is enrolled **before its first turn**, either by starting it with `PLAYBOOK_WORKER_WORKTREE` (and `PLAYBOOK_WORKER_BRANCH`) set to its worktree and branch, or by pre-binding it in the host-local worker registry (`playbook-registry.sh worker add`). A bare delegated launch with neither is **unguarded**: do not rely on guard protection for it, and keep its write work to the ticket it was given.

## 3. Parallelism Without Pre-Serialization
- Fill every free worker slot immediately with ready, unblocked tickets, in dependency order. Respect the host caps the project declares; if none are declared, use the caps in section 7.
- Overlapping files are **not** a reason to serialize. Isolated worktrees plus non-blocking `NEEDS_REBASE` routing (see `rebase-and-fix`) absorb them.
- Block dispatch only on a real functional dependency, or when two tickets rewrite the same dedicated module.
- Keep a ticket's implementation and fix rounds on the same host and worktree.

## 4. Event-Driven Wakeup Loop
On every wakeup run this pass once, then end the turn:
1. **Verify completions.** Read the terminal state of finished children. Never claim "done" or "green" without exact PR, branch and SHA evidence.
2. **Advance PRs.**
   - Green and complete: build and register the review snapshot (`playbook-registry.sh review snapshot`, see `blind-review`), then dispatch a fresh, read-only `blind-review` on the exact `(pr, base_oid, head_oid)`. After the verdict, `playbook-registry.sh review remove` tears the snapshot down.
   - Rebased by `rebase-and-fix`: route by its classification. `FULL_HEAD_RE_REVIEW` gets a new full review; `DELTA_RE_REVIEW` gets a review of the base delta on the new tuple; `MECHANICAL_CARRY_FORWARD` goes to `publish-pr` with the carry-forward record, which the publisher re-verifies.
   - `REQUEST_CHANGES` or `NEEDS_REBASE`: dispatch `rebase-and-fix` on the ticket's host. `NEEDS_REBASE` never blocks the rest of the queue.
   - Approval evidence for the exact tuple, with required CI green on the exact head: **Tier 1 landing defaults to the operator.** Report the PR as ready to land. Hand off to `publish-pr` only when a dedicated exact-head publisher is configured (fire and forget).
3. **Refill slots.** Count running implementers per host and dispatch the next ready ticket with `ticket-implement`.
4. **Hygiene.** Settle finished child threads. Run `safe-cleanup` only for PRs confirmed merged, and route it to a named executor or the operator with host access. A guarded coordinator does not run cleanup.
5. **Check rotation.** Run `playbook-registry.sh status` and renew or rotate when it reports `ROTATE_DUE`.
6. **Stop the turn.** Children and async publish jobs run on their own.

## 5. Renew This Shift

### Default: In-Place Renewal
Use this when the host can refresh context in the same thread (a fresh-context send or a context clear).
1. Run `playbook-registry.sh renew`. It bumps the generation `G -> G+1`, resets `started_at`, preserves `cancel_count`, and prints a compact recovery packet.
2. Trigger fresh context on the same thread.
3. Run the section 1 startup.

The thread ID, guard registration, PR watches, heartbeat and live child callbacks all carry over. Healthy workers are not drained.

### Fallback: Fenced New-Thread Rotation
Use this only when the thread identity must change: the host lacks fresh context, the thread is wedged, or the model must switch.

1. **Drain.** If there are zero active children and zero pending publishes, skip the wait. Otherwise schedule a deadline wake if one is needed, then run `playbook-registry.sh drain <handoff-marker>`. This freezes dispatches, sends, schedules and broker enqueues.
2. **Wait, then cancel.** Let children finish for at most 15 minutes. Cancel what is still running with the host's cancel capability (see the host mapping in `README.md`). Record the forced cancellation once per attempt with `--cancelled`. At `cancel_count >= 2`, stop rotating and escalate to the owner with the live child list. Never start a third such rotation.
3. **Create the successor.** Create the successor idle, using an idempotent request ID derived from the handoff marker. Bind it with `playbook-registry.sh bind-candidate <successor-tid>`, which records it in a dispatch-disabled `candidate` state. Then send the Handoff Packet below to `<successor-tid>`.
4. **Successor takes over.** The successor runs the section 1 startup, including PR watches, reads, heartbeat, and reconciling the predecessor's child task IDs. It then runs `playbook-registry.sh takeover <predecessor-tid> <handoff-marker>`. This single atomic step promotes the successor to `active` and marks the predecessor `retired`. Never use `coordinator remove` for this.
5. **Retire.** The retired predecessor unsubscribes its PR watches, deletes its heartbeat, and stops. If anything fails before takeover, the predecessor runs `playbook-registry.sh abort <handoff-marker>`, which retires any bound candidate and resumes the shift.

**Handoff Packet** (12 lines at most):
```
Handoff <handoff-marker> | predecessor <thread-id> | slice <milestone>
Generation G -> G+1 | cancel_count <n>
Open PRs: #<n> base <oid> head <oid> state <state> next <action>
Active children: <task-id> <ticket> <host>, or none
Cancelled children: <task-id> <ticket>, or none
Pending publishes: <PR, tuple, record state>, or none
Blockers: <owner decision needed>, or none
Successor to reconcile: child task IDs, PR watches, heartbeat
```

## 6. Universal Rules
- No project paths are hard-coded here. Read the project's own handbook and state location in section 1.
- Keep state in durable places (issues, PRs, the coordinator registry, and the project's state directory), never only in thread memory.
- When a shift ends, report a short delta: done, running, blocked, open.

## 7. Default Host Caps (when the project declares none)
- Strong worker host: 3 to 4 concurrent implementers.
- Secondary worker host: 2 to 3.
- Coordinator host: 0 heavy builds; orchestration and reviews only.
- Admission: pause new implementers when disk is below 20 GB free or memory pressure is high; resume once it recovers.
