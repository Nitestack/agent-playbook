# Historical Reference: Research Evidence

> **Historical Reference, frozen.** Consolidated, generic empirical findings from the 2026-11-25 council audits. Each claim says how it was verified. Read only the section you need (`grep -n "^## " <file>`); do not read the file in full. Pair this file with the index in [`README.md`](README.md).

## 1. T3 Code hooks and `T3CODE_THREAD_ID`

- **Finding:** Both the Claude and the Codex adapters pass `T3CODE_THREAD_ID` into the hook environment of every thread they run. A `PreToolUse` guard can therefore identify the thread it is judging. Source locations at audit time: `ClaudeAdapterV2.ts:1733` and `CodexAdapterV2.ts:1744`.
- **Consequence for the guards:** a guard is active only when the thread ID is listed in its registry. An unlisted or unset thread passes through untouched, so ordinary interactive sessions are not affected.
- **Dispatch primitives:** top-level threads are launched with `t3_thread_launch` and stopped with `t3_thread_interrupt(stop: true)`. Delegated child tasks use `delegate_task` and `task_cancel`. Mixing the two families gives the wrong cancellation behavior.
- **Idempotent launch:** `t3_thread_launch` and `t3_thread_send` accept a `clientRequestId`. Replaying the same ID after a lost response yields the same run, which is what makes crash recovery safe.
- **Limit:** the guards are accident and drift barriers. Processes that run as the same user share the same environment, so they are not cryptographic authentication.
- **Verified tool version:** T3 Code. No version was recorded at audit time; the source references above are the evidence.

## 2. Skill catalog

- **Finding:** the global catalog held 87 skills, with duplicates (three debugging skills, two TDD skills, two review skills) and unused platform-specific packs. It was pruned to **28** (−68%). This is the figure used in every council artifact.
- **Precedence:** Claude Code gives a personal skill precedence over a project skill with the same name. A repo skill named like a global skill is silently shadowed, so the check must run before a name is chosen.
- **Supply chain:** three external packs shipped code that a skill loader should never run by default: a shim that wrapped a CLI tool, bundled hooks that started a local HTTP server, and a pre-approved write permission. Policy: deploy only `SKILL.md` and `references/**/*.md`, and read every file of a third-party pack before installing it.
- **Note on the count:** an early draft of the structure proposal named the archive for "87→26". No recorded catalog supports 26. The consensus figure is 28.
- **Verified tool version:** Claude Code. No version was recorded at audit time.

## 3. Git `patch-id`: `--stable` versus `--verbatim`

- **Finding:** `git patch-id --stable` ignores whitespace, so two patches that differ only in whitespace get the same ID. `--verbatim` keeps whitespace significant. A rebase that changes whitespace is a real content change and must not pass as "equivalent".
- **Re-run on this machine:** two patches that add `foo bar` and `foo  bar` produced the same `--stable` ID (`a0b2d117…`) and different `--verbatim` IDs (`4ead0de4…` and `fe757c2f…`).
- **Verified tool version:** Git 2.56.0 (re-run).

## 4. OpenSSH owner signatures: `verify-required`

- **Finding:** in `OpenSSH 10.6p1`, the `allowed_signers` file does not accept the `verify-required` option. Requiring user verification must therefore come from the key itself: generate a FIDO2 key with `ssh-keygen -t ed25519-sk -O verify-required`, then check the signature blob for both the user-presence flag (`0x01`) and the user-verification flag (`0x04`). A passphrase-protected software key is not an acceptable owner key.
- **Verified tool version:** OpenSSH 10.6p1 (`ssh -V` confirmed on this machine). The `allowed_signers` behavior comes from the source audit and was not re-run here.

## 5. `ast-grep` 0.51.2 flags and the suppression check

- **Finding:** `ast-grep scan --no-ignore=all` is rejected by version 0.51.2. The equivalent is six explicit flags: `--no-ignore hidden`, `--no-ignore dot`, `--no-ignore exclude`, `--no-ignore global`, `--no-ignore parent` and `--no-ignore vcs`.
- **Suppression check:** an inline ignore comment must be banned with `rg`. Ripgrep exits `0` on a match, `1` on no match and `2` on an error. Pass the check **only** on exit `1`. A plain `! rg ...` passes on error (exit `2`), which hides a broken search.
- **Verified tool version:** ast-grep 0.51.2. Carried from the source audit; ast-grep was not installed on this machine, so it was not re-run.

## 6. Host admission and memory pressure

- **Principles, not numbers:** per-host job caps follow from core count and memory. Use hysteresis: pause new heavy jobs above the high threshold and resume only below the low threshold. Measure at least memory use, pressure stall information where the kernel exposes it, and free disk.
- **Thresholds used in the audit:** pause at memory above 85%, pressure `some avg10` above 20, or free disk below 20 GB; resume at memory below 75%, pressure below 10, or free disk at least 25 GB.
- **Out-of-memory handling:** a user-slice out-of-memory daemon with the pressure-kill policy keeps one runaway build from taking the whole session down. WSL2 may not expose pressure stall information, so document the fallback.
- **Verified tool version:** Linux systemd-oomd. Version not recorded at audit time.

## 7. Orchestrator session failure mode

- **Finding:** a live session of about 55 MB showed 13 context compactions, 161 shell calls against 17 delegated tasks, and serialization the orchestrator had imposed on itself. Context grew until the orchestrator drifted.
- **Fix:** rotate by shift on measurable triggers (compactions, dispatch count, age, milestone completion), and drain or cancel children before handoff.
- **Verified tool version:** T3 Code and Claude Code. Versions not recorded at audit time.

## 8. Publish-script bugs

- **Finding:** an audit of a publish script found twelve concrete bugs (P1–P12). The recurring classes were: a `--dry-run` that still wrote; a missing lease, so a stale base could land; a rebase path that was skipped silently; an unisolated test job that ran candidate code; and key material left world-readable.
- **Fix:** the broker is the only writer. Dry-run is read-only, and each class has a regression test.
- **Verified tool version:** Git 2.56.0 for the lease and push semantics. The script itself is not reproduced here.

## 9. Reviewer independence

- **Finding:** what makes a reviewer independent is its context, not its vendor. A fresh context, with no author transcript and no write tools, that reads only an exact snapshot, is independent. A second provider is an opt-in; a single-subscription project must still get full review.
- **Verified tool version:** none specific; this is a design finding from the council rounds.
