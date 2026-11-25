# agent-playbook

A portable kit for agent-driven development: workflow skills, repo bootstrap templates, `PreToolUse` guard hooks, and an architecture archive. It is plain files. Nix is optional.

## Overview page

A visual overview of the whole repository (structure, tiers, the shift workflow, every skill, guard hooks, setup, the R1 to R15 archive and how to adopt it) is in [`site/index.html`](site/index.html). Open it in a browser. It is one self-contained page: no fonts, scripts or images are loaded from elsewhere.

## What is inside

| Path | Contents |
|---|---|
| `skills/` | Ten workflow skills, each a single `SKILL.md`. `bootstrap-repo` also ships templates in `references/`. |
| `hooks/` | Bash guards for coordinator, worker and reviewer roles, with a shared library. Needs only `bash`, `jq` and coreutils. |
| `hooks/tests/test-hooks.sh` | The guard test suite. Run it with `bash hooks/tests/test-hooks.sh`. |
| `docs/universal-blueprint.md` | The living architecture: tiers, orchestration, guards, publishing. |
| `docs/archive/` | Frozen reference material: the full v15 spec, the decision log and the research evidence. Grep it; do not read it in full. |

## Tiers

Adopt the tiers in order, and move up only when the trigger is real.

- **Tier 0 (solo or quick repo):** a short `AGENTS.md` with verifiable commands, a `CLAUDE.md` that points to it, and repo-scoped stack skills.
- **Tier 1 (active product repo):** Tier 0, plus a shift-based orchestrator, the role guards, `blind-review`, and `browser-verify` for UI repos.
- **Tier 2 (multi-host publishing):** Tier 1, plus brokered publishing where workers hold no push credentials, and an owner gate for policy paths.

Details: [`docs/universal-blueprint.md`](docs/universal-blueprint.md).

## Install with Nix

Add the playbook as a non-flake input. It is a plain source tree.

```nix
{
  inputs.agent-playbook = {
    url = "github:Nitestack/agent-playbook";
    flake = false;
  };

  outputs = { self, nixpkgs, agent-playbook, ... }: {
    # Reference the files as paths, for example:
    #   "${agent-playbook}/skills/orchestrate"
    #   "${agent-playbook}/hooks/coordinator-guard.sh"
  };
}
```

Deploy only the `SKILL.md` files and the `references/**/*.md` files. Do not deploy the scripts from third-party packs.

**Local development loop.** Test a local checkout without pushing:

```bash
nix flake check --override-input agent-playbook git+file:///path/to/agent-playbook
```

## Install without Nix

Symlink the skills you want into your agent's skill directory:

```bash
for s in /path/to/agent-playbook/skills/*/; do
  ln -s "${s%/}" ~/.claude/skills/
done
```

Other agents read their own skill directories; for example, `~/.codex/skills/` or `~/.agents/skills/`.

**Opt-in hooks.** The guards are inert unless a thread is registered, so they are safe to register globally. In Claude Code, add them to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/path/to/agent-playbook/hooks/coordinator-guard.sh" },
          { "type": "command", "command": "/path/to/agent-playbook/hooks/worker-guard.sh" },
          { "type": "command", "command": "/path/to/agent-playbook/hooks/reviewer-guard.sh" }
        ]
      }
    ]
  }
}
```

Each guard is configured by an environment variable. Set it only in the process that should be guarded:

| Variable | Activates | Default registry |
|---|---|---|
| `PLAYBOOK_COORDINATOR_REGISTRY` | `coordinator-guard.sh` | `~/.local/state/agent-playbook/coordinator-threads.json` |
| `PLAYBOOK_WORKER_WORKTREE` | `worker-guard.sh`, set to the worker's worktree | none |
| `PLAYBOOK_REVIEW_REGISTRY` | `reviewer-guard.sh` | `~/.local/state/agent-playbook/review-threads.json` |

The guards stop a well-meaning agent from drifting. They are not a defense against a determined adversary.

## Bootstrap a repo

One line copies the Tier 0 agent file into a new repo:

```bash
cp /path/to/agent-playbook/skills/bootstrap-repo/references/AGENTS.template.md AGENTS.md
```

Or ask an agent to run the `bootstrap-repo` skill, which reads only the templates for the tier it is applying.

## Test and check

```bash
bash hooks/tests/test-hooks.sh
```

CI runs the same suite, then checks that `skills/` holds only Markdown files and that each `SKILL.md` has a frontmatter `name:` equal to its directory and a unique name. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## License

Licensed under the [Apache License 2.0](LICENSE). This covers everything in the repo: skills, templates, hooks, docs and the overview page.

You may use, copy and adapt these files in private and commercial projects, including copying a template into your own repo's `AGENTS.md`. Keep the license notice when you redistribute the files themselves.
