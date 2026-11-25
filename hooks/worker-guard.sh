#!/usr/bin/env bash
# PreToolUse guard for implementation workers.
#
# Active only when $PLAYBOOK_WORKER_WORKTREE is set. Unset means exit 0 at once.
# The worktree is resolved with realpath; if it does not resolve to a directory
# every tool call is denied (fail closed).
#
# Writes must stay inside the worktree:
#   - Edit, Write, MultiEdit, NotebookEdit and apply_patch: every target path
#     must resolve (symlinks included) inside the worktree. Relative paths count
#     from the worktree.
#   - Bash: `cd` must enter the worktree; file-writing commands (rm rmdir mv cp
#     mkdir touch ln chmod chown install tee truncate dd rsync unlink shred, and
#     sed -i) may only name paths inside it. A leading $PLAYBOOK_WORKER_WORKTREE or
#     ${PLAYBOOK_WORKER_WORKTREE} is expanded; any other variable in a path is refused.
#     Output redirections (other than /dev/null) and substitutions are refused by
#     the strict parser: write files with the edit tools instead.
#   - git: mutating subcommands must name the worktree with `git -C <worktree>`,
#     and every -C directory must resolve inside it. Read-only git runs anywhere.
#   - git push: never to main, master or develop, whether named directly, in a
#     refspec (HEAD:main, +refs/heads/main), inside --force-with-lease=, or by a
#     plain push while the worktree is on one of them. --all and --mirror are denied.
#
# Reads are unrestricted. Not a defence against a determined adversary; it stops
# a well-meaning worker from writing outside its worktree or pushing to a shared
# branch.

set -uo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=guard-lib.sh
. "$here/guard-lib.sh"

[ -n "${PLAYBOOK_WORKER_WORKTREE:-}" ] || exit 0

WT=$(realpath -e -- "$PLAYBOOK_WORKER_WORKTREE" 2>/dev/null) || WT=""
HOOK_INPUT=$(cat)
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  deny "worker-guard: PLAYBOOK_WORKER_WORKTREE ($PLAYBOOK_WORKER_WORKTREE) does not resolve to a directory; refusing all tools"
fi
tool=$(jq -r '.tool_name // ""' <<<"$HOOK_INPUT") || deny "worker-guard: unreadable hook input"

REASON=""

# expand_wt <word>: print the word with a leading $PLAYBOOK_WORKER_WORKTREE (or
# ${PLAYBOOK_WORKER_WORKTREE}) replaced by the worktree. Return 1 for any other
# variable or substitution, because such a path cannot be verified.
expand_wt() {
  # The quoted `$PLAYBOOK_WORKER_WORKTREE` patterns below are literal text to match.
  # shellcheck disable=SC2016
  local w=$1
  case $w in
    '$PLAYBOOK_WORKER_WORKTREE' | '${PLAYBOOK_WORKER_WORKTREE}') printf '%s' "$WT" ;;
    '$PLAYBOOK_WORKER_WORKTREE/'*) printf '%s' "$WT${w#'$PLAYBOOK_WORKER_WORKTREE'}" ;;
    '${PLAYBOOK_WORKER_WORKTREE}/'*) printf '%s' "$WT${w#'${PLAYBOOK_WORKER_WORKTREE}'}" ;;
    *'$'* | *'`'*) return 1 ;;
    *) printf '%s' "$w" ;;
  esac
}

# inside_wt <word>: true when the path the word names resolves inside the worktree.
# Relative paths count from the worktree; `~` is never inside.
inside_wt() {
  local p
  p=$(expand_wt "$1") || return 1
  [ -n "$p" ] || return 1
  case $p in '~'*) return 1 ;; esac
  path_inside "$(canon_path "$p" "$WT")" "$WT"
}

protected_branch() {
  case $1 in
    main | master | develop) return 0 ;;
    *) return 1 ;;
  esac
}

# push_allowed: W[0..] is `git ... push`; GIT_ARGS holds the words after `push`.
push_allowed() {
  local a part dir current sub parts=() pos=()
  dir=$(expand_wt "${GIT_DIRS[0]:-$WT}") || dir=$WT
  for a in "${GIT_ARGS[@]}"; do
    case $a in
      --all | --mirror)
        REASON="git push $a is not allowed for workers"
        return 1
        ;;
    esac
    # Check every ref-like part: refspec sides, --force-with-lease=<ref>:<sha>.
    sub=${a#--force-with-lease=}
    sub=${sub#+}
    read -ra parts <<<"${sub//:/ }"
    for part in "${parts[@]}"; do
      part=${part#refs/heads/}
      part=${part#refs/remotes/origin/}
      part=${part#origin/}
      if protected_branch "$part"; then
        REASON="git push must not target $part; workers push only their feature branch"
        return 1
      fi
    done
    case $a in
      -*) ;;
      *) pos+=("$a") ;;
    esac
  done
  # A plain push, or one naming HEAD, pushes the worktree's own branch.
  local push_current=0
  if [ "${#pos[@]}" -le 1 ]; then push_current=1; fi
  for a in "${pos[@]:1}"; do
    [ "$a" = HEAD ] && push_current=1
  done
  if [ "$push_current" = 1 ]; then
    current=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null) || current=""
    if [ -n "$current" ] && protected_branch "$current"; then
      REASON="this worktree is on $current; workers must not push it"
      return 1
    fi
  fi
  return 0
}

# git_allowed: W is a git command. Sets REASON and returns 1 when it is denied.
git_allowed() {
  local d
  git_parse
  if [ -n "$GIT_BAD" ]; then
    REASON=$GIT_BAD
    return 1
  fi
  if git_is_readonly; then return 0; fi
  if [ "${#GIT_DIRS[@]}" -eq 0 ]; then
    REASON="mutating git must name the worktree: git -C \"\$PLAYBOOK_WORKER_WORKTREE\" $GIT_SUB ..."
    return 1
  fi
  for d in "${GIT_DIRS[@]}"; do
    if ! inside_wt "$d"; then
      REASON="git $GIT_SUB targets a directory outside the worktree: $d"
      return 1
    fi
  done
  if [ "$GIT_SUB" = push ]; then push_allowed || return 1; fi
  return 0
}

# segment_allowed: W is one simple command. Sets REASON and returns 1 when denied.
segment_allowed() {
  local cmd=${W[0]} a
  cmd=${cmd##*/}
  case $cmd in
    git) git_allowed ;;
    cd)
      if [ "${#W[@]}" -ne 2 ] || ! inside_wt "${W[1]}"; then
        REASON="cd must enter a directory inside the worktree"
        return 1
      fi
      ;;
    rm | rmdir | mv | cp | mkdir | touch | ln | chmod | chown | install | tee | truncate | dd | rsync | unlink | shred | sed)
      if [ "$cmd" = sed ]; then
        local inplace=0
        for a in "${W[@]:1}"; do
          # Any option cluster with an `i` (-i, -ni, -Ei, -i.bak, --in-place) counts as in-place.
          # Over-matching only adds a path check, which is the safe direction.
          case $a in -*i* | --in-place*) inplace=1 ;; esac
        done
        [ "$inplace" = 1 ] || return 0
      fi
      for a in "${W[@]:1}"; do
        case $a in
          -*) continue ;;
          of=*) a=${a#of=} ;;
        esac
        if ! inside_wt "$a"; then
          REASON="$cmd may only write inside the worktree; cannot verify or outside: $a"
          return 1
        fi
      done
      ;;
  esac
}

# check_bash: validate every simple command of a shell line.
check_bash() {
  local cmdline element
  PARSE_MODE=strict
  cmdline=$(tool_command)
  if ! parse_command "$cmdline"; then
    deny "worker-guard: cannot verify the command ($PARSE_ERR). Workers write with the edit tools; keep Bash to simple commands inside the worktree."
  fi
  for element in "${CMDS[@]}"; do
    split_cmd "$element"
    REASON=""
    if ! segment_allowed; then
      deny "worker-guard: ${W[*]:0:4}: $REASON"
    fi
  done
}

# check_path <path>: deny unless the path is inside the worktree.
check_path() {
  if [ -z "$1" ]; then
    deny "worker-guard: $tool call names no path; cannot verify it stays inside the worktree"
  fi
  if ! inside_wt "$1"; then
    deny "worker-guard: $tool may only write inside the worktree ($WT); refused: $1"
  fi
}

case $tool in
  Edit | Write | MultiEdit | NotebookEdit)
    p=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // ""' <<<"$HOOK_INPUT")
    check_path "$p"
    exit 0
    ;;
  apply_patch)
    patch=$(jq -r '(.tool_input.input // .tool_input.command // .tool_input.patch // "") | if type == "array" then join("\n") else . end' <<<"$HOOK_INPUT")
    files=$(sed -n -e 's/^\*\*\* \(Add\|Update\|Delete\) File: //p' -e 's/^\*\*\* Move to: //p' <<<"$patch")
    if [ -z "$files" ]; then
      deny "worker-guard: apply_patch names no file; cannot verify it stays inside the worktree"
    fi
    while IFS= read -r p; do check_path "$p"; done <<<"$files"
    exit 0
    ;;
  Bash | shell | local_shell | exec_command | unified_exec)
    check_bash
    exit 0
    ;;
  *) exit 0 ;;
esac
