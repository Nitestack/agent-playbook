# Historical Reference: Council Decisions R1 to R15

> **Historical Reference, frozen.** Decision log of the fifteen-round council that produced the v15 dossier (2026-11-25). Read the section you need; do not read the file in full. The living guidance is [`../universal-blueprint.md`](../universal-blueprint.md). The full design is [`2026-11-25-full-specification-v15.md`](2026-11-25-full-specification-v15.md).

## Scores by round

Two reviewer panels scored each round on Developer Experience (DX) and Agent Experience (AX), out of 10.

| Round | Panel A: DX / AX | Panel B: DX / AX | What changed |
|---|---|---|---|
| R1–R2 | 5.0/4.5 → 7.5/7.0 | 4.5/4.0 → 7.0/6.5 | Live audits: the skill catalog, Git 2.56 `patch-id`, and a publish-script bug audit (P1–P12) |
| R3–R6 | 8.0/7.5 → 8.5/8.5 | 8.0/7.5 → 8.5/7.0 | Brokered publishing with no worker push tokens, the policy-path owner gate, and a bundle-based host switch |
| R7–R9 | 8.8/8.6 → 8.9/8.6 | 8.5/7.5 → 8.5/7.8 | Static CI unit, Check Runs provenance, `OpenSSH 10.6p1` and `ast-grep 0.51.2` live verification, isolated fences job |
| R10–R14 | 9.3/9.2 → 9.6/9.6 | 8.9/8.4 → 9.3/8.9 | Diminishing returns: registration race conditions and multi-pointer crash states |
| R15 | 9.6 / 9.6 | 9.5 / 9.1 | The judge trimmed R10–R15 over-engineering; the lean plan scored 9.4 DX / 9.3 AX |

## Kept: the high-return findings (R1–R9)

1. **Orchestrator failure mode and the shift model.** A live audit of a long orchestrator session found 13 context compactions, 161 shell calls against 17 delegated tasks, and self-inflicted serialization. The fix is one orchestrator per milestone shift, rotated proactively, with a drain-or-cancel handoff and mechanical pre-tool guards.
2. **Skill pruning and supply-chain hygiene.** The global catalog went from 87 to 28 skills (−68%). The audit found trigger collisions, personal-over-project precedence, and unsafe bundled scripts and hooks in external packs. The fix is a `.md`-only filter, duplicate and broken-reference assertions, and repo-scoped stack packs.
3. **Credential and host boundaries.** No owner token in agent shells, no push credentials on worker hosts, and one serialized publish broker.
4. **Verified tooling bugs.** `patch-id --verbatim` instead of `--stable`; explicit `ast-grep` flags instead of `--no-ignore=all`; FIDO2 `verify-required` with an explicit flag check, since the installed `OpenSSH` does not accept the `allowed_signers` option.
5. **A bundle-based, root-isolated host switch.** Never run `root` `git` inside the user's working checkout; fetch from an unprivileged bundle into a fresh root-owned bare repository with a pinned signing program and an anti-rollback check.
6. **Single-provider default.** An independent reviewer means a fresh, read-only context, not a second vendor. Cross-provider review is an opt-in.

## Trimmed: the over-engineering (R10–R15)

1. **Stdin injection into read-only reviewers, and transcript parsing on every read.** A reviewer already runs in a read-only, no-network sandbox over a `.git`-free snapshot. Its verdict is checked after the run (single turn, brief hash, canonical run ID). A race that sends input to a read-only shell cannot change a byte, and parsing internal transcripts on every read is brittle. *Replacement:* snapshot containment plus post-run verification.
2. **A distributed crash write-ahead log for the host switch.** The switch is run interactively by the owner. A three-pointer crash log with failure-injection tests is excessive for an interactive wrapper. *Replacement:* a lock, a verified bundle, a diff of sensitive paths, a human confirmation, and a live-identity check after the switch.
3. **A local attested CI subsystem.** Building a signed local-CI service with its own app identity and policy units, just to work around paused hosted CI minutes, is premature infrastructure. *Replacement:* hosted CI when it is available. The local-CI design stays in the full specification as an opt-in fallback only.

## What the trim left open

- The local-CI fallback and the crash-durable switch remain specified in the full specification. Neither is part of the portable kit.
- The owner-proof and anti-phishing design applies to any project that publishes through a broker. Small projects can skip it.
