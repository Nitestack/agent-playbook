---
name: council-review
description: Run a structured council of independent reviewers on a major architecture, security boundary, policy or proposal change, then converge on a consensus with evidence. Use for high-impact design decisions only, not for routine PR review (that is blind-review).
---

# Council Review Protocol

Use this for high-impact proposals, architecture shifts, security boundaries and policy changes. Never use it for small edits, typos or mechanical refactors. Routine PR review is `blind-review`.

## 1. Independent Panel
1. Act as the critical judge. Never a passive secretary.
2. Spawn reviewers with fresh, read-only context. **Single-provider default:** every reviewer can come from the one provider the project already uses. Cross-family reviewers are opt-in: use them only when the project has configured a second provider. A project with one subscription must still get a full council.
3. Give each reviewer only:
   - the goal, the hard constraints and the non-goals,
   - the exact diff or draft document, and the repository context it needs,
   - a rubric: `CRITICAL` / `HIGH` / `MEDIUM` findings, each with a concrete failure scenario, a missing proof or a contradiction, plus an explicit `CONSENSUS` or `REVISE` verdict.
4. In round 1 keep reviewers blind to each other's output, to avoid groupthink.

## 2. Evidence-Based Triage (Anti-Sycophancy)
- Never adopt a finding just because a reviewer raised it.
- Check every factual claim against the live code, docs, APIs or host state before editing.
- Reject speculative or out-of-scope suggestions with a short factual reason.

## 3. Bounded Convergence
1. Apply all validated fixes in one revised artifact. Record what changed and what was rejected, with reasons.
2. Run the next round on the **delta plus the updated artifact**, not from scratch. Stop when every panel member returns `CONSENSUS`, which usually takes two or three rounds.
3. If a real trade-off remains (scope, UX, credentials, cost or policy), stop debating. Escalate a numbered decision list to the owner, with a `(Recommended)` default for each item.

## 4. Deliverable
A short council summary: each reviewer's final verdict, the key defects found and resolved, the rejected findings with reasons, and the open owner decisions.
