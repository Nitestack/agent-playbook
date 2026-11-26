# agent-playbook

A portable kit for agent-driven development: workflow skills, repo bootstrap templates, `PreToolUse` guard hooks, and an architecture archive. It is plain files. Nix is optional.

## Overview page

A visual overview of the whole repository (structure, tiers, the shift workflow, every skill, guard hooks with an interactive simulator, setup, the R1 to R15 archive and how to adopt it) is published at <https://nitestack.github.io/agent-playbook/>; the source is [`site/index.html`](site/index.html), which also opens straight from a checkout. It uses Google Fonts (Fraunces, Plus Jakarta Sans, JetBrains Mono, with system fallbacks) and zero external scripts or tracking, and its file links point to this repository on GitHub.

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

Symlink the skills you want into your agent's skill directory. The loop creates the directory and replaces only the links that point into this checkout, so a rerun refreshes its own links. It skips and reports everything else: a real file or directory with the name, and a link (dangling or not) that points anywhere outside this checkout.

```bash
src_root=$(readlink -f /path/to/agent-playbook)
dest=~/.claude/skills
mkdir -p "$dest"
for s in "$src_root"/skills/*/; do
  s=${s%/}
  name=$(basename "$s")
  link=$dest/$name
  if [ -L "$link" ]; then
    owner=$(readlink -f "$link")
    case $owner in
      "$src_root"/*) ln -sfn "$s" "$link" ;;
      *) echo "skip $name: $link is a link to $owner, not to this checkout" ;;
    esac
  elif [ -e "$link" ]; then
    echo "skip $name: $link exists and is not a link"
  else
    ln -s "$s" "$link"
  fi
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
| `worker-guard.sh` | `PLAYBOOK_WORKER_WORKTREE` is set in the worker's environment, or, as a fallback, the thread id is listed in the worker registry | `PLAYBOOK_WORKER_BRANCH` (the one branch it may push), `PLAYBOOK_PROTECTED_BRANCHES` (default `main master develop`); worker registry path: `PLAYBOOK_WORKER_REGISTRY`, default `~/.local/state/agent-playbook/worker-threads.json`, written with `playbook-registry.sh worker add` |
| `reviewer-guard.sh` | the thread id is listed in the review registry with a `snapshot_root` | registry path: `PLAYBOOK_REVIEW_REGISTRY`, default `~/.local/state/agent-playbook/review-threads.json` |

The thread id is `PLAYBOOK_THREAD_ID`, or `T3CODE_THREAD_ID`, which T3 Code sets for every thread it runs. Outside T3 Code, start each guarded agent with its own `PLAYBOOK_THREAD_ID`. Without a thread id, the coordinator and reviewer guards stay inactive.

**Write the registries with `playbook-registry.sh`**, never by hand. Writes take the registry lock and replace the file atomically. A guarded coordinator may run these commands, except removing its own entry.

| Command | What it does |
|---|---|
| `coordinator add <thread-id> [slice]` | Registers a coordinator for one shift. `slice` is an optional label for the milestone slice. |
| `coordinator remove <thread-id>` | Removes a coordinator entry. |
| `status [thread-id]` | Prints the coordinator state, age, cancel count and `ROTATE_DUE` of one thread (defaults to the calling thread). |
| `renew` | In-place renewal. The calling coordinator keeps its thread id, guard, watches and heartbeat and continues in a fresh context. |
| `drain <handoff-marker> [--cancelled]` | Marks the caller as draining, which freezes new dispatches, and stores the marker that lets its successor through. `--cancelled` records that the rotation had to cancel children; such a rotation counts toward the limit of two forced rotations. |
| `bind-candidate <candidate-thread-id>` | Binds an idle successor as a `candidate` with dispatch disabled, so it can recover and attach its watches before it takes over. |
| `takeover <predecessor-thread-id> <handoff-marker>` | Atomically makes the candidate the coordinator and sets the predecessor to `state: "retired"`. The predecessor's entry stays in place, so its guard keeps running. |
| `abort <handoff-marker>` | Ends a handoff that failed before `takeover`. The predecessor keeps the shift. |
| `review snapshot [--with-base] [--fetch <remote> <ref>] <thread-id> <repo> <base-oid> <head-oid>` | Exports the exact head to a read-only snapshot root, prints its path and registers it for the reviewer. `--with-base` builds the package as a single root that also includes the base. `--fetch` fetches the ref from the remote before exporting; it is opt-in. |
| `review add <thread-id> <snapshot-root>` | Registers a reviewer thread for a snapshot root you prepared yourself. |
| `review remove <thread-id>` | Unregisters a reviewer and deletes the snapshot if `review snapshot` created it. |
| `worker add <thread-id> <worktree> [branch]` | Registers a worker for the worker guard's registry fallback. |
| `worker remove <thread-id>` | Unregisters a worker. |
| `show coordinator\|review\|worker` | Prints one registry as JSON. |

The registries are JSON objects keyed by thread id: `{"<thread-id>": {"draining": false}}` for coordinators, `{"<thread-id>": {"snapshot_root": "/abs/path"}}` for reviewers. A coordinator entry also carries a `state`: `candidate` while a successor waits for takeover, and `retired` for a predecessor after takeover. A retired entry is kept on purpose, so its guard still applies.

**Registries are host- and account-local.** Each machine and OS account keeps its own files under `~/.local/state/agent-playbook/`, or at the paths the `PLAYBOOK_*_REGISTRY` variables name. In v1, shift rotation stays on one coordinator host, which is the authority for the shift. Do not share a registry between hosts or accounts.

**Workers** get their environment from whoever starts them: `PLAYBOOK_WORKER_WORKTREE=<worktree>` and, recommended, `PLAYBOOK_WORKER_BRANCH=<feature-branch>`. When the variable is missing, the worker guard falls back to the worker registry, which `worker add` writes. A bare delegated launch that has neither the variable nor a registry entry made before it starts is unguarded, because the guard cannot know which worktree is its own. Register the worker before it starts, or launch it with the variable.

**Codex reviewers.** The reviewer guard allows only Claude Code's `Read`, `Grep` and `Glob`, and Codex reads files through its shell. Do not register a Codex reviewer in the review registry; run it in Codex's read-only sandbox with the snapshot as its working directory. That setup is not covered by the test suite.

The guards stop a well-meaning agent from drifting. They are not a defense against a determined adversary; interpreters such as `python -c` are not inspected.

## Host mapping

The skills describe capabilities, not products. This table maps each capability to the tool a host provides. T3 Code tools come first, then the plain CLI.

| Capability | T3 Code | Plain CLI |
|---|---|---|
| Idle thread launch: start a fresh agent on a ready worktree | `t3_thread_launch` without `message` (creates an idle thread so you can bind it before sending the brief) | Start a new agent session in the worktree |
| Fresh-context renewal: same thread, empty context | `t3_thread_send` with `freshContext: true` | `/clear` |
| Cancel a running child | `task_cancel` for a delegated task; `t3_thread_interrupt` with `stop: true` for a top-level thread | Stop the process, or interrupt it with Ctrl+C |
| PR watch: wake on checks and reviews of an exact head | `watch_pull_request` | Poll `gh pr view` by head SHA; do not run a wait loop inside an agent |
| Heartbeat schedule: wake the coordinator on a fixed interval | `schedule_task` | A cron entry or systemd timer that resumes the session |
| Browser verification: drive the built UI and check it | `preview_open`, `preview_navigate`, `preview_snapshot` and the other `preview_*` tools | A headless browser run by your test tooling |

The skills name the capability. Use this table to find the tool on the host you run on.

## Bootstrap a repo

One line copies the Tier 0 agent file into a new repo:

```bash
cp /path/to/agent-playbook/skills/bootstrap-repo/references/AGENTS.template.md AGENTS.md
```

Or ask an agent to run the `bootstrap-repo` skill, which reads only the templates for the tier it is applying.

## Test and check

```bash
bash hooks/tests/test-hooks.sh
bash hooks/tests/lint-skills.sh
```

CI runs the same suite and `shellcheck` on the hooks. It runs `hooks/tests/lint-skills.sh` for the skills, so local and CI checks use one script. That script checks that `skills/` holds only regular Markdown files, that each `SKILL.md` has closed frontmatter with exactly one `name:` equal to its directory and a non-empty `description:`, that names are unique, and that every `references/` file a skill names stays inside its skill and exists. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## License

Licensed under the [Apache License 2.0](LICENSE). This covers everything in the repo: skills, templates, hooks, docs and the overview page.

You may use, copy and adapt these files in private and commercial projects, including copying a template into your own repo's `AGENTS.md`. Keep the license notice when you redistribute the files themselves.
