---
name: session-miner
description: Mine agent session transcripts, CI failures and review rounds for recurring friction, cluster the root causes and turn each into a mechanical fix. Use after a milestone or a multi-ticket run, or when the same failure keeps coming back.
---

# Session Miner Protocol

Turn evidence from a run into fixes that stop the failure from recurring. Work from logs and counts, never from anecdote.

## Workflow
1. **Collect evidence.** Read recent session transcripts, failed CI runs, review rounds, and host telemetry (memory events, OOM kills, retry loops). Note the count of each symptom.
2. **Cluster by mechanism.** Group symptoms by root cause: missing test isolation, stale environment, slow repeated shell startup, a missing lint or structural rule, an ambiguous contract, a permission prompt that blocks flow.
3. **Prefer mechanical fixes to prose.** In order of preference:
   1. a CI gate, a structural lint, a test fixture that isolates state, or a host guardrail (a hook, a cgroup limit, a timeout);
   2. a minimal rule in `AGENTS.md` or the review rules. Delete the obsolete prose it replaces.
4. **Verify each fix** against the incident that motivated it. A fix that cannot be shown to stop the failure is not done.
5. **Report** as a table: `Observed incident -> Root cause -> Mechanical fix -> Verification`. Leave out vanity metrics and speculative abstractions.
