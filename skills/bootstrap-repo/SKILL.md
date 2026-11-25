---
name: bootstrap-repo
description: Set up agent rails in a new or existing repository in tiers (Tier 0 day-zero baseline, Tier 1 multi-agent rails, Tier 2 multi-host publishing) and add repo-scoped stack skills in .claude/skills/ and .agents/skills/. Use when equipping a repo for agents, adding AGENTS.md or CLAUDE.md, or adding project-specific skills.
---

# Repo Bootstrap for Agent-Driven Work

Equip a repository with lean, provider-neutral agent rails. Start at **Tier 0** and add a tier only when its trigger is real. Never add infrastructure for a problem the repo does not have.

Templates live in `references/` next to this file. **Read only the files for the tier you are applying.** Do not load the rest.

## Tier 0: day-zero baseline (always)

Read `references/AGENTS.template.md`, `references/CLAUDE.template.md`, `references/ISSUE_TEMPLATE.md` and `references/PULL_REQUEST_TEMPLATE.md`.

1. **Issue as contract:** copy `ISSUE_TEMPLATE.md` to `.github/ISSUE_TEMPLATE/` as a Markdown issue template.
2. **PR template:** copy `PULL_REQUEST_TEMPLATE.md` to `.github/pull_request_template.md`.
3. **`AGENTS.md`:** from `AGENTS.template.md`. Replace every placeholder with the repo's real build, lint and test commands. Keep only rules the code cannot show.
4. **`CLAUDE.md`:** from `CLAUDE.template.md`, a single line: `@AGENTS.md`.
5. **Fail-closed CI:** write `.github/workflows/ci.yml` with format, lint and test. Use locked dependencies (`--locked`, `--frozen-lockfile`), `permissions: { contents: read }`, and actions pinned to full commit SHAs. No template is provided: write it to the repo's own toolchain.
6. **Isolated tests:** tests never read or write user data directories, the user's git config or live databases. Put temp-dir and git-environment isolation in one shared test helper.

## Tier 1: multi-agent and verified quality (when triggered)

Trigger: two or more agents work in parallel, UI changes need browser checks, or a defect escaped review.

Read `references/REVIEW.template.md`, `references/orchestration.template.md` and `references/stack-packs.md`.

1. **`REVIEW.md`:** from `REVIEW.template.md`. Reviewers are fresh and read-only. A second provider is optional.
2. **`docs/orchestration.md`:** from `orchestration.template.md`, Tier 1 sections only. Keep it short.
3. **Structural lints:** add an AST or compiler rule only for a failure that has actually recurred.
4. **UI smoke gate (UI repos only):** one production-build browser check. UI changes are verified in a real browser, not only by tests.

## Tier 2: multi-host publishing (only when several hosts publish)

Trigger: several hosts write code that lands on a protected branch.

Read the Tier 2 sections of `references/orchestration.template.md` only.

1. **Brokered publishing:** workers hold no push credentials. One publisher identity, serialized by one lock, performs every push.
2. **Owner gate for policy paths:** changes to CI, build, lint, ignore, lockfile, toolchain or agent-instruction files need the owner's signed approval on the exact head.
3. **Host admission:** per-host caps on concurrent heavy jobs, with pause and resume thresholds on memory, pressure and free disk.

## Repo-scoped stack skills

Read `references/stack-packs.md` before adding any stack skill. The rules: check for name collisions with the global catalog first, keep each skill to what an agent cannot infer from the code, and mirror the same content into `.claude/skills/` and `.agents/skills/`.

## Constraints

- Respect the repo's existing conventions and package managers.
- Never invent ticket-tracking tables, fake abstractions or premature infrastructure.
- Verify every file you add against the repo's own CI before reporting the bootstrap done.
