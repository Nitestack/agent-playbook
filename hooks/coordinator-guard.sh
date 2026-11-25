#!/usr/bin/env bash
# PreToolUse guard for orchestrator ("coordinator") threads.
#
# Active only when $T3CODE_THREAD_ID is listed in the coordinator registry
# (${PLAYBOOK_COORDINATOR_REGISTRY:-$HOME/.local/state/agent-playbook/coordinator-threads.json}).
# Unset variable, missing/unreadable/malformed registry or an unlisted thread
# exit 0 at once, so ordinary interactive sessions are never touched.
#
# A registered coordinator may
#   - read: Read/Grep/Glob, MCP orchestration tools, ls cat head tail rg jq wc ...
#   - run read-only git (status log diff show rev-parse merge-base rev-list
#     ls-files ls-tree cat-file range-diff patch-id describe for-each-ref blame
#     shortlog show-ref ls-remote, `branch --list`, `worktree list`),
#   - run read-only gh (pr view/list/diff/checks/status, issue view/list/status,
#     run list/view, repo view), `gh issue create|comment` and GET-only `gh api`,
#   - run the publish broker (`publish-broker`, `publish-broker.sh`, also as
#     `sudo [-n] -u publisher <broker>`).
# Everything else is denied: file edits, cargo/pnpm/npm builds, git push/commit/
# checkout/rebase/merge, gh pr merge, redirections to files, substitutions.
#
# While the entry has "draining": true, new dispatches (delegate_task,
# invoke_subagent, create_threads, Agent/Task, t3_thread_launch) are denied.
# The one exception is t3_thread_launch of the handoff successor, recognised by
# the entry's "handoff_marker" string appearing verbatim in the call input.
#
# Not a defence against a determined adversary; it stops a well-meaning
# orchestrator from drifting into hands-on work.

set -uo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=guard-lib.sh
. "$here/guard-lib.sh"

tid=${T3CODE_THREAD_ID:-}
[ -n "$tid" ] || exit 0
registry=${PLAYBOOK_COORDINATOR_REGISTRY:-$HOME/.local/state/agent-playbook/coordinator-threads.json}
entry=$(registry_entry "$registry" "$tid") || exit 0

HOOK_INPUT=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$HOOK_INPUT") || deny "coordinator-guard: unreadable hook input"
draining=$(jq -r '.draining == true' <<<"$entry")

REASON=""

is_broker() {
  case ${1##*/} in
    publish-broker | publish-broker.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# gh_allowed: W is a gh command. Sets REASON and returns 1 when it is not allowed.
gh_allowed() {
  local i=1 n=${#W[@]} w group="" verb="" method=""
  while ((i < n)); do
    w=${W[i]}
    case $w in
      -R | --repo)
        i=$((i + 2))
        continue
        ;;
      --repo=* | -R?*)
        i=$((i + 1))
        continue
        ;;
      -*)
        if [ -z "$group" ]; then
          REASON="gh option $w before the command cannot be analysed"
          return 1
        fi
        ;;
      *)
        if [ -z "$group" ]; then
          group=$w
        elif [ -z "$verb" ]; then
          verb=$w
        fi
        ;;
    esac
    i=$((i + 1))
  done
  case "$group $verb" in
    "pr view" | "pr list" | "pr diff" | "pr checks" | "pr status" | \
      "issue view" | "issue list" | "issue status" | "issue create" | "issue comment" | \
      "run list" | "run view" | "repo view")
      return 0
      ;;
  esac
  if [ "$group" = api ]; then
    i=1
    while ((i < n)); do
      w=${W[i]}
      case $w in
        -X | --method)
          method=${W[i + 1]:-}
          i=$((i + 1))
          ;;
        -X?* | --method=*)
          method=${w#-X}
          method=${method#--method=}
          ;;
        -f | -F | --field | --raw-field | --input | -f?* | -F?* | --field=* | --raw-field=* | --input=*)
          REASON="gh api with a request body (-f/-F/--field/--raw-field/--input) is a write"
          return 1
          ;;
      esac
      i=$((i + 1))
    done
    if [ -n "$method" ] && [ "${method^^}" != GET ]; then
      REASON="gh api -X ${method} is a write; only GET is allowed"
      return 1
    fi
    return 0
  fi
  REASON="gh ${group:-?} ${verb} is not on the coordinator allowlist"
  return 1
}

# segment_allowed: W is one simple command. Sets REASON and returns 1 when denied.
segment_allowed() {
  local cmd=${W[0]} a i
  if [[ $cmd =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    REASON="variable assignment prefixes are not allowed"
    return 1
  fi
  if [[ $cmd == */* ]]; then
    is_broker "$cmd" && return 0
    REASON="commands must be invoked by name, not by path ($cmd)"
    return 1
  fi
  case $cmd in
    publish-broker | publish-broker.sh) return 0 ;;
    ls | cat | head | tail | wc | jq | pwd | cd | echo | basename | dirname | realpath | stat | true)
      return 0
      ;;
    rg)
      for a in "${W[@]:1}"; do
        case $a in
          --pre | --pre=* | --pre-glob* | --hostname-bin*)
            REASON="rg --pre runs external programs"
            return 1
            ;;
        esac
      done
      return 0
      ;;
    git)
      git_parse
      if [ -n "$GIT_BAD" ]; then
        REASON=$GIT_BAD
        return 1
      fi
      if git_is_readonly; then return 0; fi
      REASON="git ${GIT_SUB:-?} can change the repository; coordinators only run read-only git"
      return 1
      ;;
    gh) gh_allowed ;;
    sudo)
      i=1
      if [ "${W[i]:-}" = -n ]; then i=2; fi
      if [ "${W[i]:-}" = -u ] && [ "${W[i + 1]:-}" = publisher ] && is_broker "${W[i + 2]:-}"; then
        return 0
      fi
      REASON="sudo is only allowed as: sudo [-n] -u publisher <publish-broker>"
      return 1
      ;;
    *)
      REASON="$cmd is not on the coordinator allowlist (no builds, tests or repo writes; delegate them)"
      return 1
      ;;
  esac
}

case $tool in
  Edit | Write | NotebookEdit | MultiEdit | apply_patch)
    deny "coordinator-guard: $tool is blocked for coordinators; delegate file changes to a worker."
    ;;
  Agent | Task | *delegate_task | *invoke_subagent | *create_threads | *t3_thread_launch)
    [ "$draining" = true ] || exit 0
    marker=$(jq -r '.handoff_marker // ""' <<<"$entry")
    if [[ $tool == *t3_thread_launch && -n $marker ]] \
      && jq -e --arg m "$marker" '.tool_input | tostring | contains($m)' <<<"$HOOK_INPUT" >/dev/null 2>&1; then
      exit 0
    fi
    deny "coordinator-guard: this shift is draining; $tool is frozen. Only the successor launch carrying the handoff_marker is allowed."
    ;;
  Bash | shell | local_shell | exec_command | unified_exec)
    PARSE_MODE=strict
    command=$(tool_command)
    if ! parse_command "$command"; then
      deny "coordinator-guard: cannot verify the command ($PARSE_ERR). Coordinators run only simple read-only git/gh/inspection commands."
    fi
    for element in "${CMDS[@]}"; do
      split_cmd "$element"
      if ! segment_allowed; then
        deny "coordinator-guard: ${W[*]:0:4}: $REASON"
      fi
    done
    exit 0
    ;;
  *) exit 0 ;;
esac
