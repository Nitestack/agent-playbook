# Orchestration

<!-- Bootstrap note: Tier 1 sections apply to any repo with parallel agents.
     Tier 2 sections apply only to a multi-host repo that publishes. Delete what does not apply. -->

## Tier 1: roles and capacity

| Role | Does | Does not |
|---|---|---|
| Orchestrator | Splits work, dispatches, triages, triggers review and publish | Edit code, run build gates, resolve conflicts by hand |
| Implementer | Implements one issue in its own worktree, opens a PR | Push to the default branch, merge |
| Reviewer | Reviews one exact `(PR, base, head)` tuple from a read-only snapshot | Write anything |
| Fixer | Applies review findings and rebases a PR on its ticket's host | Start new tickets |

- **Caps:** `<host>`: `<n>` concurrent implementers. Coordinator host: no heavy builds.
- **Hotspot files** (module roots, manifests, lockfiles, registration files) are expected conflict points. They never block dispatch.
- **Rotation:** one orchestrator per shift. Rotate on `compactions >= 2`, `dispatches >= 40`, `age >= 6h`, or milestone completion.
- **Wakeup:** on each wakeup, verify completions by exact SHA, advance PRs, refill free slots, and stop. Never wait in a loop.
- **State and registry:** coordinator registry `<registry path>`, written only by `playbook-registry.sh`. Project state directory `<state path>`. A coordinator does not write the state directory directly.
- **Wakeup and heartbeat owner:** `<orchestrator role>` schedules a thread-bound 20-minute heartbeat while open PRs or active children exist, and checks `playbook-registry.sh status` for `ROTATE_DUE`.
- **Tier 1 landing and cleanup owner:** `operator` by default. Name a dedicated publisher only once it is configured with a durable intent record: `<publisher or none>`. Cleanup (`safe-cleanup`) runs on that owner, never on a guarded coordinator.
- **Docs-only paths:** `<none declared>` by default. With none declared, automatic carry-forward is disabled and every base delta gets a delta or full re-review. List the globs to enable it: `<docs/** ...>`.
- **Gate-defining paths:** `<CI, build, lint, ignore, lockfile, toolchain, agent-instruction, policy and migration paths>`.

## Tier 2: publishing across hosts

- Workers hold no push credentials. Only the publisher pushes, under one lock.
- Policy paths (CI, build, lint, ignore, lockfile, toolchain, agent instructions) need the owner's signed approval on the exact head.
- Admission: pause new heavy jobs above `<memory %>` memory use, pressure `some avg10 > <n>`, or below `<gb>` GB free disk. Resume below the lower thresholds.
