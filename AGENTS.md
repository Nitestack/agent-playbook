# AGENTS.md

This repo is a portable kit consumed by other repos. Keep it small, plain and public-ready.

## Commands (run before every commit)

- Hook tests: `bash hooks/tests/test-hooks.sh`. It must end with `0 failed`.
- Skill lint: run the `Skill lint` step of `.github/workflows/ci.yml` locally, with the same bash. It checks that `skills/` holds only Markdown, that each `SKILL.md` has a frontmatter `name:` equal to its directory and a `description:`, and that names are unique.
- Workflow lint: `actionlint .github/workflows/ci.yml` when `actionlint` is available. Do not skip it silently.

## Public-ready privacy rule

- Never commit private host names, local home-directory paths, private device or ruleset identifiers, or internals of private repositories.
- Use placeholders instead: `<owner>/<repo>`, `<coordinator-host>`, `<worker-host>`, `<operator>`, `<path/to/agent-playbook>`.
- Do not paste output from private systems into docs or tests. Write a sanitized version.
- The maintainer keeps the list of private identifiers outside this repo and runs their own scan before a release. Do not write that list here.

## AX rule

- `docs/archive/` is frozen reference-only — grep specific sections, never read it in full.

## Skill rules

- `skills/` holds only `SKILL.md` and `references/**/*.md`. No scripts, shims, hooks or binaries.
- The frontmatter `name:` equals the directory name, and names are unique across the set.
- Keep each `SKILL.md` lean. Move long templates to `references/` and say when to read them.
- Write skills in tool-neutral English. Name a capability, not one provider's product, unless the skill is provider-specific.
- The single template location is `skills/bootstrap-repo/references/`. Do not add a second template directory.

## Hook rules

- Every guard exits `0` before it reads input when it is not active for the session.
- Every new rule gets a case in `hooks/tests/test-hooks.sh`. Never delete, skip or weaken a case.
- Guards need only `bash`, `jq` and coreutils. Do not add a dependency for a guard.

## Commits

- Conventional Commits, signed. Never use `--no-verify` or `--no-gpg-sign`.
