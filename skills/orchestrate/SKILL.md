---
name: orchestrate
description: Run or take over an orchestrator shift for one milestone slice that splits work, dispatches workers and reviewers, and merges, without hands-on coding. Use when starting an orchestrator thread, taking over from a rotated shift, or when a shift hits a rotation trigger.
---

# Orchestrator Shift Protocol

An orchestrator is a **dispatcher, not a mechanic**. It owns scheduling, triage, review triggers and publish triggers for **one milestone slice**. It never owns a project forever, and it never turns into a forever-thread that accumulates context until it drifts.

## 0. Shift Model
- **1 orchestrator thread = 1 shift = 1 milestone slice.** Never one thread per ticket, never one thread for the whole project.
- A shift **rotates** when any trigger fires:
  - `compactions >= 2`, or
  - `dispatches_in_shift >= 40`, or
  - `shift_age >= 6h`, or
  - the milestone slice is complete.
- Rotation is proactive. Do not wait for the thread to break.

## 1. Recovery-First Startup (Mandatory)
Rebuild ground truth from external authorities, never from memory:
1. Read the repo's `AGENTS.md`, its orchestration handbook if it has one (for example `docs/orchestration.md`), and any state directory the project names (for example `~/.local/state/<project>-orch/`).
2. Inspect open issues and open PRs with the forge CLI (`gh issue list`, `gh pr list`).
3. Inspect live child threads and linked hosts. Reconcile stale leases and unfinished publish records before dispatching anything.

## 2. Role Boundary
- **Never** edit feature code or tests, debug failing tests over SSH, resolve conflicts by hand, or run build and test gates in the orchestrator's own turn.
- **Never** block waiting for CI or a merge queue (no wait loops, no long foreground scripts). Stop the turn and let the wakeup do it.
- Any PR that needs code fixes, a rebase, migration renumbering or a gate rerun goes to a worker with `rebase-and-fix` on the ticket's existing host.

## 3. Parallelism Without Pre-Serialization
- Fill every free worker slot immediately with ready, unblocked tickets, in dependency order. Respect the host caps the project declares; if none are declared, use the caps in section 7.
- Overlapping files are **not** a reason to serialize. Isolated worktrees plus non-blocking `NEEDS_REBASE` routing (see `rebase-and-fix`) absorb them.
- Block dispatch only on a real functional dependency, or when two tickets rewrite the same dedicated module.
- Keep a ticket's implementation and fix rounds on the same host and worktree.

## 4. Event-Driven Wakeup Loop
On every wakeup run this pass once, then end the turn:
1. **Verify completions.** Read the terminal state of finished children. Never claim "done" or "green" without exact PR, branch and SHA evidence.
2. **Advance PRs.**
   - Green and complete: dispatch a fresh, read-only `blind-review` on the exact `(pr, base_oid, head_oid)`.
   - `REQUEST_CHANGES` or `NEEDS_REBASE`: dispatch `rebase-and-fix` on the ticket's host. `NEEDS_REBASE` never blocks the rest of the queue.
   - Approved, with required CI green on the exact head: hand off to `publish-pr` (fire and forget).
3. **Refill slots.** Count running implementers per host and dispatch the next ready ticket with `ticket-implement`.
4. **Hygiene.** Settle finished child threads; run `safe-cleanup` only for PRs confirmed merged.
5. **Stop the turn.** Children and async publish jobs run on their own.

## 5. Rotation: Drain, Cancel, Hand Off
1. **Freeze.** Set `draining = true` in the shift's state. No new dispatches, except the successor launch described below.
2. **Drain for at most 15 minutes.** Let active children finish. Then cancel what is left: `task_cancel` for delegates, `t3_thread_interrupt(stop: true)` for top-level threads. Bump the shift generation `G -> G+1`.
3. **Anti-livelock.** Count cancellations in `rotation_cancel_count`. If it reaches `>= 2`, stop rotating and escalate to the owner with the list of live children. Do not cancel a third time.
4. **Launch the successor** with `shift_generation = N+1` and a `handoff_marker` string in its prompt. The marker is what lets the one launch through while draining.
5. **Two-phase acknowledgement.** The old shift stays alive until the successor confirms:
   - Phase 1: the successor reads the state (open issues, open PRs, child threads) and records `handoff_received`.
   - Phase 2: the successor attaches PR watches, reads each watched PR, schedules a **20-minute heartbeat**, and sets `handoff_acked = true`.
   Only then does the predecessor stop. If `handoff_acked` never arrives, the predecessor keeps the shift and escalates.

## 6. Universal Rules
- No project paths are hard-coded here. Read the project's own handbook and state location in section 1.
- Keep state in durable places (issues, PRs, the project's state directory), never only in thread memory.
- When a shift ends, report a short delta: done, running, blocked, open.

## 7. Default Host Caps (when the project declares none)
- Strong worker host: 3 to 4 concurrent implementers.
- Secondary worker host: 2 to 3.
- Coordinator host: 0 heavy builds; orchestration and reviews only.
- Admission: pause new implementers when disk is below 20 GB free or memory pressure is high; resume once it recovers.
