#!/usr/bin/env bash
# PreToolUse guard for orchestrator ("coordinator") threads.
#
# Active only when the thread id ($PLAYBOOK_THREAD_ID, else $T3CODE_THREAD_ID) is
# listed in the coordinator registry
# (${PLAYBOOK_COORDINATOR_REGISTRY:-$HOME/.local/state/agent-playbook/coordinator-threads.json}).
# Unset variable, missing/unreadable/malformed registry or an unlisted thread
# exit 0 at once, so ordinary interactive sessions are never touched.
#
# The entry's lifecycle state is `state`, else "draining" when `draining` is
# true, else "active". Each state has its own rules:
#
# active: a registered coordinator may
#   - read: Read/Grep/Glob, MCP orchestration tools, ls cat head tail rg jq wc ...
#   - run read-only git (status log diff show rev-parse merge-base rev-list
#     ls-files ls-tree cat-file range-diff patch-id describe for-each-ref blame
#     shortlog show-ref ls-remote, `branch --list`, `worktree list`),
#   - run read-only gh (pr view/list/diff/checks/status, issue view/list/status,
#     run list/view, repo view), `gh issue create|comment` and GET-only `gh api`,
#   - run the publish broker (`publish-broker`, `publish-broker.sh`, also as
#     `sudo [-n] -u publisher <broker>`),
#   - run `playbook-registry.sh` renew, drain, status, show, review add|snapshot|
#     remove, worker add|remove, coordinator add, and coordinator remove of any
#     other entry that is not retired.
# draining: new dispatches (delegate_task, invoke_subagent, create_threads,
#   Agent/Task, run_scheduled_task_now, t3_queue) are denied. The handoff successor
#   may be launched only with the entry's "handoff_marker" in the call input, the
#   bound "candidate" may be messaged, a one-shot schedule may carry the marker,
#   publish-broker may only run `status`, and the registry accepts bind-candidate,
#   abort, status, show and review remove.
# candidate: dispatch-disabled. No Agent/Task, delegate, subagent, launch, send,
#   scheduled run, queue or publish-broker. The registry accepts takeover, status
#   and show only. Read tools and read-only shell remain.
# retired: inert. Only teardown and read tools (unwatch_pull_request,
#   delete_scheduled_task, pull_request_read, t3_thread_read, list_*, Read, Grep,
#   Glob) and shell lines that run `playbook-registry.sh show|status` pass.
#
# Everything else is denied: file edits, cargo/pnpm/npm builds, git push/commit/
# checkout/rebase/merge, gh pr merge, `gh pr checks --watch`, forge MCP tools
# that merge or write code (for example `*pull_request_merge`), removing its
# own registry entry, removing a retired entry, redirections to files, substitutions.
#
# Not a defense against a determined adversary; it stops a well-meaning
# orchestrator from drifting into hands-on work.

set -uo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=guard-lib.sh
. "$here/guard-lib.sh"

tid=$(thread_id)
[ -n "$tid" ] || exit 0
registry=${PLAYBOOK_COORDINATOR_REGISTRY:-$HOME/.local/state/agent-playbook/coordinator-threads.json}
entry=$(registry_entry "$registry" "$tid") || exit 0

HOOK_INPUT=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$HOOK_INPUT") || deny "coordinator-guard: unreadable hook input"
STATE=$(jq -r '.state // (if .draining == true then "draining" else "active" end)' <<<"$entry") \
  || deny "coordinator-guard: unreadable registry entry for $tid"
case $STATE in
  active | draining | candidate | retired) ;;
  *) deny "coordinator-guard: unknown lifecycle state '$STATE' for $tid; refusing every tool" ;;
esac
marker=$(jq -r '.handoff_marker // ""' <<<"$entry")
candidate=$(jq -r '.candidate // ""' <<<"$entry")

REASON=""

is_broker() {
  case ${1##*/} in
    publish-broker | publish-broker.sh) return 0 ;;
    *) return 1 ;;
  esac
}

is_registry_tool() {
  case ${1##*/} in
    playbook-registry | playbook-registry.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# entry_state <entry-json>: the lifecycle state of a registry entry.
entry_state() {
  jq -r '.state // (if .draining == true then "draining" else "active" end)' <<<"$1"
}

# registry_allowed: W is a playbook-registry command. What it may do depends on
# STATE. Nothing a coordinator can do may remove its own entry (that would lift
# its guard) or a retired entry (the operator's call). Sets REASON on refusal.
registry_allowed() {
  local cmd=${W[1]:-} arg=${W[2]:-} other other_entry
  case $STATE:$cmd:$arg in
    active:renew:* | active:drain:* | active:status:* | active:show:*) return 0 ;;
    active:review:add | active:review:snapshot | active:review:remove) return 0 ;;
    active:worker:add | active:worker:remove | active:coordinator:add) return 0 ;;
    active:coordinator:remove)
      other=${W[3]:-}
      if [ -z "$other" ]; then
        REASON="coordinator remove needs a thread id"
        return 1
      fi
      if [ "$other" = "$tid" ]; then
        REASON="a coordinator must not remove its own registry entry"
        return 1
      fi
      if other_entry=$(registry_entry "$registry" "$other") && [ "$(entry_state "$other_entry")" = retired ]; then
        REASON="$other is retired; a coordinator must not remove a retired entry"
        return 1
      fi
      return 0
      ;;
    draining:drain:* | draining:bind-candidate:* | draining:abort:* | draining:status:* | draining:show:* | draining:review:remove)
      return 0
      ;;
    candidate:takeover:* | candidate:status:* | candidate:show:*) return 0 ;;
    retired:status:* | retired:show:*) return 0 ;;
  esac
  REASON="playbook-registry ${cmd:-?} ${arg} is not allowed while this coordinator is $STATE"
  return 1
}

# broker_allowed <args after the broker name>: active coordinators run the broker;
# a draining one may only check its status; a candidate or retired one not at all.
broker_allowed() {
  local a
  case $STATE in
    active) return 0 ;;
    draining)
      if [ "${1:-}" = status ]; then
        for a in "${@:2}"; do
          case $a in
            -*) ;;
            *)
              REASON="a draining coordinator may only run publish-broker status"
              return 1
              ;;
          esac
        done
        return 0
      fi
      REASON="a draining coordinator may only run publish-broker status"
      return 1
      ;;
    *)
      REASON="publish-broker is closed while this coordinator is $STATE"
      return 1
      ;;
  esac
}

# retired_segment_allowed: a retired coordinator's shell may only inspect the registry.
retired_segment_allowed() {
  local cmd=${W[0]##*/}
  if { [ "$cmd" = playbook-registry ] || [ "$cmd" = playbook-registry.sh ]; } \
    && { [ "${W[1]:-}" = show ] || [ "${W[1]:-}" = status ]; }; then
    return 0
  fi
  REASON="a retired coordinator may only run playbook-registry show or status"
  return 1
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
          REASON="gh option $w before the command cannot be analyzed"
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
  if [ "$group $verb" = "pr checks" ]; then
    for w in "${W[@]}"; do
      case $w in
        --watch | --watch=*)
          REASON="gh pr checks --watch is a wait loop; end the turn and check again on the next wakeup"
          return 1
          ;;
      esac
    done
  fi
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
    if is_broker "$cmd"; then
      broker_allowed "${W[@]:1}"
      return
    fi
    if is_registry_tool "$cmd"; then
      registry_allowed
      return
    fi
    REASON="commands must be invoked by name, not by path ($cmd)"
    return 1
  fi
  case $cmd in
    publish-broker | publish-broker.sh) broker_allowed "${W[@]:1}" ;;
    playbook-registry | playbook-registry.sh) registry_allowed ;;
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
        broker_allowed "${W[@]:i+3}"
        return
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

# bash_gate: every simple command of a shell line must pass for the current STATE.
bash_gate() {
  local command element
  command=$(tool_command)
  if ! parse_command "$command"; then
    deny "coordinator-guard: cannot verify the command ($PARSE_ERR). Coordinators run only simple read-only git/gh/inspection commands."
  fi
  for element in "${CMDS[@]}"; do
    split_cmd "$element"
    REASON=""
    if [ "$STATE" = retired ]; then
      retired_segment_allowed || deny "coordinator-guard: ${W[*]:0:4}: $REASON"
    elif ! segment_allowed; then
      deny "coordinator-guard: ${W[*]:0:4}: $REASON"
    fi
  done
  exit 0
}

# retired_gate: an inert coordinator keeps only teardown, reads and registry inspection.
retired_gate() {
  case $tool in
    *unwatch_pull_request | *delete_scheduled_task | *pull_request_read | *t3_thread_read | \
      *list_scheduled_tasks | *list_thread_pull_requests | Read | Grep | Glob)
      exit 0
      ;;
    Bash | shell | local_shell | exec_command | unified_exec) bash_gate ;;
    *)
      deny "coordinator-guard: this coordinator is retired; $tool is refused. Only teardown and read tools remain."
      ;;
  esac
}

# candidate_gate: dispatch is disabled until the candidate takes over.
candidate_gate() {
  case $tool in
    Agent | Task | *delegate_task | *invoke_subagent | *create_threads | *t3_thread_launch | \
      *t3_thread_send* | *run_scheduled_task_now | *t3_queue)
      deny "coordinator-guard: this candidate is dispatch-disabled until takeover; $tool is refused."
      ;;
    Bash | shell | local_shell | exec_command | unified_exec) bash_gate ;;
    *) exit 0 ;;
  esac
}

# draining_gate: the shift is frozen except the handoff path: the marked successor
# launch, the marked one-shot schedule, messages to the bound candidate, and status.
draining_gate() {
  case $tool in
    Agent | Task | *delegate_task | *invoke_subagent | *create_threads | *run_scheduled_task_now | *t3_queue)
      deny "coordinator-guard: this shift is draining; $tool is frozen."
      ;;
    *t3_thread_launch)
      if [ -n "$marker" ] && jq -e --arg m "$marker" '.tool_input | tostring | contains($m)' \
        <<<"$HOOK_INPUT" >/dev/null 2>&1; then
        exit 0
      fi
      deny "coordinator-guard: this shift is draining; only the successor launch carrying the handoff_marker is allowed."
      ;;
    *t3_thread_send*)
      if [ -n "$candidate" ] && jq -e --arg c "$candidate" '.tool_input.threadId == $c' \
        <<<"$HOOK_INPUT" >/dev/null 2>&1; then
        exit 0
      fi
      deny "coordinator-guard: this shift is draining; messages go only to the bound candidate."
      ;;
    *schedule_task)
      if [ -n "$marker" ] && jq -e --arg m "$marker" \
        '.tool_input.schedule.type == "once" and ((.tool_input.prompt // "") | tostring | contains($m))' \
        <<<"$HOOK_INPUT" >/dev/null 2>&1; then
        exit 0
      fi
      deny "coordinator-guard: this shift is draining; only a one-shot schedule carrying the handoff_marker is allowed."
      ;;
    Bash | shell | local_shell | exec_command | unified_exec) bash_gate ;;
    *) exit 0 ;;
  esac
}

# active_gate: the shell rules and the registry rules; dispatch is open.
active_gate() {
  case $tool in
    Bash | shell | local_shell | exec_command | unified_exec) bash_gate ;;
    *) exit 0 ;;
  esac
}

case $tool in
  Edit | Write | NotebookEdit | MultiEdit | apply_patch)
    deny "coordinator-guard: $tool is blocked for coordinators; delegate file changes to a worker."
    ;;
  # Forge tools that land, rewrite or write code. Merges go through publish-pr.
  *pull_request_merge | *merge_pull_request | *update_pull_request_branch | \
    *push_files | *create_or_update_file | *delete_file | *create_branch)
    deny "coordinator-guard: $tool can merge or write to the forge; coordinators hand approved PRs to publish-pr."
    ;;
esac

case $STATE in
  retired) retired_gate ;;
  candidate) candidate_gate ;;
  draining) draining_gate ;;
  *) active_gate ;;
esac
exit 0
