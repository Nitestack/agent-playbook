# Archive Index

> **Frozen reference-only.** Nothing in this directory is loaded by a skill, a hook or a template. Grep the section you need; never read a file in full.

The archive keeps the evidence behind the blueprint. Each row gives the claim, the file and section that holds it, and the tool version it was checked against. A row marked "not re-run" was carried from the source audit and was not re-checked when this repository was created.

| Claim or topic | File and section | Verified tool version |
|---|---|---|
| Hooks run per thread and see `T3CODE_THREAD_ID` (Claude and Codex adapters) | [`2026-11-25-research-evidence.md` §1](2026-11-25-research-evidence.md#1-t3-code-hooks-and-t3code_thread_id) | T3 Code (version not recorded at audit time) |
| Guards are inert unless the thread is registered | research-evidence §1 | T3 Code (version not recorded) |
| Dispatch and cancel primitives: `t3_thread_launch` / `t3_thread_interrupt` versus `delegate_task` / `task_cancel` | research-evidence §1 | T3 Code (version not recorded) |
| Idempotent launch and send via `clientRequestId` | research-evidence §1 | T3 Code (version not recorded) |
| Skill catalog pruned from 87 to 28 (−68%) | research-evidence §2 | Claude Code (version not recorded) |
| Personal skills take precedence over project skills with the same name | research-evidence §2 | Claude Code (version not recorded) |
| Supply-chain findings in external skill packs; `.md`-only policy | research-evidence §2 | Not applicable (audit of third-party packs) |
| `git patch-id --verbatim` keeps whitespace significant; `--stable` does not | research-evidence §3 | Git 2.56.0 (**re-run**) |
| `OpenSSH` rejects the `verify-required` option in `allowed_signers`; use FIDO2 flags | research-evidence §4 | OpenSSH 10.6p1 (`ssh -V` checked; `allowed_signers` behavior not re-run) |
| `ast-grep` needs six explicit `--no-ignore` flags; suppression check passes only on `rg` exit 1 | research-evidence §5 | ast-grep 0.51.2 (not re-run) |
| Host admission thresholds with hysteresis; out-of-memory daemon | research-evidence §6 | Linux systemd-oomd (version not recorded) |
| Orchestrator session failure mode (compactions, dispatch ratio) | research-evidence §7 | T3 Code and Claude Code (versions not recorded) |
| Publish-script bug classes and their fixes | research-evidence §8 | Git 2.56.0 (lease and push semantics) |
| Reviewer independence is about context, not vendor | research-evidence §9 | Not applicable (design finding) |
| Round-by-round scores and what each round changed | [`2026-11-25-council-decisions-r1-r15.md`](2026-11-25-council-decisions-r1-r15.md) | Not applicable |
| Why the R10–R15 over-engineering was trimmed | council-decisions, "Trimmed" | Not applicable |
| Complete hardened design, including the optional local-CI fallback | [`2026-11-25-full-specification-v15.md`](2026-11-25-full-specification-v15.md) | Not applicable (historical snapshot) |

## Files

- [`2026-11-25-full-specification-v15.md`](2026-11-25-full-specification-v15.md): sanitized frozen snapshot of the v15 council dossier.
- [`2026-11-25-council-decisions-r1-r15.md`](2026-11-25-council-decisions-r1-r15.md): decision log, R1 to R15.
- [`2026-11-25-research-evidence.md`](2026-11-25-research-evidence.md): consolidated, generic empirical findings.

## Sanitization

The archive is public-ready. Host names, local paths, the operator's account name, private identifiers and private repository internals were replaced with placeholders (`<coordinator-host>`, `<worker-host-a>`, `<worker-host-b>`, `<operator>`, `<owner>/<repo>`, `<ruleset-id>`, `<project>`, `<trunk>`, `<crate-path>`, `<web-path>`, `<local-path>`). Issue numbers appear as `#<n>`. Each file states what it changed in its header.
