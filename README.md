# agent-playbook

A portable kit for agent-driven development: workflow skills, repo bootstrap templates, `PreToolUse` guard hooks, and an architecture archive. It is plain files. Nix is optional.

## Overview page

A visual overview of the whole repository (structure, tiers, the shift workflow, every skill, guard hooks, setup, the R1 to R15 archive and how to adopt it) is in [`site/index.html`](site/index.html). Open it from a checkout, or serve the repository root and visit `/site/`: its links point to files one level up. It is one self-contained page: no fonts, scripts or images are loaded from elsewhere.

## What is inside

| Path | Contents |
|---|---|
| `skills/` | Ten workflow skills, each a single `SKILL.md`. `bootstrap-repo` also ships templates in `references/`. |
| `hooks/` | Bash guards for coordinator, worker and reviewer roles, a shared library, and `playbook-registry.sh`, which writes the guard registries. |
| `hooks/tests/test-hooks.sh` | The guard test suite. Run it with `bash hooks/tests/test-hooks.sh`. |
| `docs/universal-blueprint.md` | The living architecture: tiers, orchestration, guards, publishing. |
| `docs/archive/` | Frozen reference material: the full v15 spec, the decision log and the research evidence. Grep it; do not read it in full. |
| `site/` | The overview page. |

## Tiers

Adopt the tiers in order, and move up only when the trigger is real.

- **Tier 0 (solo or quick repo):** a short `AGENTS.md` with verifiable commands, a `CLAUDE.md` that points to it, and repo-scoped stack skills.
- **Tier 1 (active product repo):** Tier 0, plus a shift-based orchestrator, the role guards, `blind-review`, and `browser-verify` for UI repos.
- **Tier 2 (multi-host publishing):** Tier 1, plus brokered publishing where workers hold no push credentials, an owner gate for policy paths, and per-host admission control.

Details: [`docs/universal-blueprint.md`](docs/universal-blueprint.md).

## Requirements

The skills and templates are Markdown and need nothing. The guard hooks need **bash 4 or newer**, **jq**, **git** and **GNU coreutils** (`realpath -e` and `-m`). On macOS, install bash and coreutils first (for example `brew install bash coreutils jq`) and put the GNU tools first on `PATH`; with the BSD `realpath` the worker and reviewer guards deny every call.

## Install with Nix

Add the playbook as a non-flake input and pass it to your Home Manager configuration (for example with `extraSpecialArgs = { inherit agent-playbook; };`):

```nix
{
  inputs.agent-playbook = {
    url = "github:Nitestack/agent-playbook";
    flake = false;
  };
}
```

Then link every skill into the agent's skill directory from a Home Manager module:

```nix
{ lib, agent-playbook, ... }:
let
  skills = lib.filterAttrs (_: type: type == "directory") (builtins.readDir "${agent-playbook}/skills");
in
{
  home.file = lib.mapAttrs' (name: _:
    lib.nameValuePair ".claude/skills/${name}" { source = "${agent-playbook}/skills/${name}"; }
  ) skills;
}
```

Use `.codex/skills/` or `.agents/skills/` for other agents. CI keeps `skills/` Markdown-only, so linking whole skill directories deploys no scripts. Apply the same `.md`-only rule to third-party skill packs. In the hook configuration below, use `${agent-playbook}/hooks/<guard>.sh` as the command path.

**Local development loop.** Test a local checkout without pushing:

```bash
nix flake check --override-input agent-playbook git+file:///path/to/agent-playbook
```

## Install without Nix

Symlink the skills you want into your agent's skill directory. The loop creates the directory, replaces its own earlier links on a rerun, and skips anything else that already has the name:

```bash
dest=~/.claude/skills
mkdir -p "$dest"
for s in /path/to/agent-playbook/skills/*/; do
  name=$(basename "$s")
  if [ -e "$dest/$name" ] && [ ! -L "$dest/$name" ]; then
    echo "skip $name: $dest/$name exists and is not a link"
    continue
  fi
  ln -sfn "${s%/}" "$dest/$name"
done
```

Other agents read their own skill directories; for example, `~/.codex/skills/` or `~/.agents/skills/`.

## Guard hooks

The three guards are `PreToolUse` hooks. Each one does nothing until it is activated for a thread, so you can register all three globally.

**Register them.** In Claude Code, add them to `~/.claude/settings.json`:

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

In Codex, register the same three commands in `~/.codex/hooks.json`. Codex passes shell calls as `exec_command` with a `cmd` and a `workdir`; the guards read both.

```json
{
  "hooks": {
    "PreToolUse": [
      {
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

**Activate them.** A guard acts only when its condition holds:

| Guard | Active when | Configuration |
|---|---|---|
| `coordinator-guard.sh` | the thread id is listed in the coordinator registry | registry path: `PLAYBOOK_COORDINATOR_REGISTRY`, default `~/.local/state/agent-playbook/coordinator-threads.json` |
| `worker-guard.sh` | `PLAYBOOK_WORKER_WORKTREE` is set in the worker's environment | `PLAYBOOK_WORKER_BRANCH` (the one branch it may push), `PLAYBOOK_PROTECTED_BRANCHES` (default `main master develop`) |
| `reviewer-guard.sh` | the thread id is listed in the review registry with a `snapshot_root` | registry path: `PLAYBOOK_REVIEW_REGISTRY`, default `~/.local/state/agent-playbook/review-threads.json` |

The thread id is `PLAYBOOK_THREAD_ID`, or `T3CODE_THREAD_ID`, which T3 Code sets for every thread it runs. Outside T3 Code, start each guarded agent with its own `PLAYBOOK_THREAD_ID`. Without a thread id, the coordinator and reviewer guards stay inactive.

**Write the registries with `playbook-registry.sh`**, never by hand:

```bash
hooks/playbook-registry.sh coordinator add <thread-id>             # operator, before the shift starts
hooks/playbook-registry.sh drain <handoff-marker>                  # the coordinator, when it rotates
hooks/playbook-registry.sh coordinator add <successor-thread-id>   # the successor, first thing
hooks/playbook-registry.sh coordinator remove <old-thread-id>      # the successor, after the handoff
hooks/playbook-registry.sh review add <thread-id> <snapshot-root>  # the coordinator, before a review
hooks/playbook-registry.sh review remove <thread-id>               # the coordinator, after the verdict
hooks/playbook-registry.sh show coordinator|review
```

A guarded coordinator may run exactly these commands, except removing its own entry. The registries are JSON objects keyed by thread id: `{"<thread-id>": {"draining": false}}` for coordinators, `{"<thread-id>": {"snapshot_root": "/abs/path"}}` for reviewers.

**Workers** get their environment from whoever starts them: `PLAYBOOK_WORKER_WORKTREE=<worktree>` and, recommended, `PLAYBOOK_WORKER_BRANCH=<feature-branch>`.

**Codex reviewers.** The reviewer guard allows only Claude Code's `Read`, `Grep` and `Glob`, and Codex reads files through its shell. Do not register a Codex reviewer in the review registry; run it in Codex's read-only sandbox with the snapshot as its working directory. That setup is not covered by the test suite.

The guards stop a well-meaning agent from drifting. They are not a defense against a determined adversary; interpreters such as `python -c` are not inspected.

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

CI runs the same suite and `shellcheck` on the hooks, then checks that `skills/` holds only regular Markdown files, that each `SKILL.md` has closed frontmatter with a `name:` equal to its directory and a unique name, and that every `references/` file a skill names exists. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## License

Licensed under the [Apache License 2.0](LICENSE). This covers everything in the repo: skills, templates, hooks, docs and the overview page.

You may use, copy and adapt these files in private and commercial projects, including copying a template into your own repo's `AGENTS.md`. Keep the license notice when you redistribute the files themselves.
