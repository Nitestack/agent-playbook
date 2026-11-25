#!/usr/bin/env bash
# PreToolUse guard for independent reviewer threads (fresh, read-only context).
#
# Active only when the thread id ($PLAYBOOK_THREAD_ID, else $T3CODE_THREAD_ID) is
# listed in the review registry
# (${PLAYBOOK_REVIEW_REGISTRY:-$HOME/.local/state/agent-playbook/review-threads.json}).
# Unset variable, missing/unreadable/malformed registry or an unlisted thread
# exit 0 at once.
#
# The registry entry of a reviewer must carry "snapshot_root": the .git-free,
# read-only directory the review is confined to. Only these tools are allowed:
#   - Read: file_path inside the snapshot,
#   - Grep: path inside the snapshot,
#   - Glob: path inside the snapshot and a pattern that is neither absolute nor
#     contains `..`.
# A path is inside when it has no `..` component and, after symlinks are resolved
# (realpath), it is the snapshot root or lies below it. A relative path counts
# from the directory the tool runs in (the hook input `cwd`); without one it is
# refused. Everything else is denied: Bash, edits and writes, MCP tools, web
# access, sub-agents.
#
# The allowlist names Claude Code tools. Codex reads files through its shell
# tool, which this guard denies, so do not register a Codex reviewer here:
# run it in its read-only sandbox with the snapshot as its working directory.
#
# This guard reads no transcripts. Containment comes from the snapshot itself
# (no .git, chmod -R a-w) and from the broker's post-run checks.

set -uo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=guard-lib.sh
. "$here/guard-lib.sh"

tid=$(thread_id)
[ -n "$tid" ] || exit 0
registry=${PLAYBOOK_REVIEW_REGISTRY:-$HOME/.local/state/agent-playbook/review-threads.json}
entry=$(registry_entry "$registry" "$tid") || exit 0

HOOK_INPUT=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$HOOK_INPUT") || deny "reviewer-guard: unreadable hook input"

snapshot_raw=$(jq -r '.snapshot_root // ""' <<<"$entry")
[ -n "$snapshot_raw" ] || deny "reviewer-guard: review registry entry has no snapshot_root; refusing every tool"
ROOT=$(realpath -e -- "$snapshot_raw" 2>/dev/null) || ROOT=""
[ -n "$ROOT" ] && [ -d "$ROOT" ] || deny "reviewer-guard: snapshot_root does not resolve to a directory; refusing every tool"
CWD=$(tool_cwd)

# check_path <path>: deny unless the path names something inside the snapshot.
check_path() {
  local p=$1 abs
  [ -n "$p" ] || deny "reviewer-guard: $tool names no path; pass a path inside the snapshot"
  if has_dotdot "$p"; then
    deny "reviewer-guard: '..' is not allowed in review paths: $p"
  fi
  case $p in
    /*) ;;
    *)
      [ -n "$CWD" ] || deny "reviewer-guard: relative path $p with no known working directory; use an absolute path inside the snapshot"
      ;;
  esac
  abs=$(canon_path "$p" "$CWD")
  if ! path_inside "$abs" "$ROOT"; then
    deny "reviewer-guard: $tool may only read inside the review snapshot ($ROOT); refused: $p"
  fi
}

case $tool in
  Read)
    check_path "$(jq -r '.tool_input.file_path // ""' <<<"$HOOK_INPUT")"
    ;;
  Grep)
    check_path "$(jq -r '.tool_input.path // ""' <<<"$HOOK_INPUT")"
    ;;
  Glob)
    pattern=$(jq -r '.tool_input.pattern // ""' <<<"$HOOK_INPUT")
    case $pattern in
      /* | *..*) deny "reviewer-guard: Glob pattern must be relative and must not contain '..': $pattern" ;;
    esac
    check_path "$(jq -r '.tool_input.path // ""' <<<"$HOOK_INPUT")"
    ;;
  *)
    deny "reviewer-guard: $tool is not allowed for independent reviewers; only Read, Grep and Glob inside the snapshot"
    ;;
esac
exit 0
