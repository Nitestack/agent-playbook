#!/usr/bin/env bash
# PreToolUse guard for implementation workers.
#
# Active when $PLAYBOOK_WORKER_WORKTREE is set, or when the calling thread
# ($PLAYBOOK_THREAD_ID, else $T3CODE_THREAD_ID) is listed in the worker registry
# (${PLAYBOOK_WORKER_REGISTRY:-$HOME/.local/state/agent-playbook/worker-threads.json},
# entry {"worktree": ..., "branch": ...}). The environment wins over the entry.
# Otherwise exit 0 before reading stdin. The worktree is resolved with realpath;
# if it does not resolve to a directory every tool call is denied (fail closed).
#
# Relative paths count from the directory the tool runs in: the call's
# `workdir`/`cwd` (Codex) or the session `cwd` (Claude Code), else the worktree.
# A `cd` earlier on the same command line moves that directory.
#
# Writes must stay inside the worktree:
#   - Edit, Write, MultiEdit, NotebookEdit and apply_patch: every target path
#     must resolve (symlinks included) inside the worktree.
#   - Bash: `cd` must enter the worktree; file-writing commands (rm rmdir mv cp
#     mkdir touch ln chmod chown install tee truncate dd rsync unlink shred, and
#     sed -i) may only name paths inside it. `env`, `command`, `nice`, `nohup`
#     and `timeout` are looked through; `find` with -delete, -exec or -ok must
#     search inside the worktree, and its -exec command is checked the same way;
#     `sh -c`, `bash -c`, `eval` and writes through `xargs` are refused. A leading
#     $PLAYBOOK_WORKER_WORKTREE or ${PLAYBOOK_WORKER_WORKTREE} is expanded; any
#     other variable in a path is refused. Output redirections (other than
#     /dev/null) and substitutions are refused by the strict parser: write files
#     with the edit tools instead.
#   - git: mutating subcommands must name the worktree with `git -C <worktree>`,
#     and every -C directory must resolve inside it. Read-only git runs anywhere.
#   - git push: --all, --mirror and --tags are denied. A push must not reach a
#     protected branch ($PLAYBOOK_PROTECTED_BRANCHES, default "main master
#     develop"), whether named directly, in a refspec, inside --force-with-lease=,
#     through HEAD while the worktree is on one, or by a plain push from one; this
#     holds even for a bound worker. With $PLAYBOOK_WORKER_BRANCH set (or the
#     branch of its registry entry), a push must also name a remote and that branch
#     as its only destination (`push origin <branch>`, `HEAD:<branch>`, or `HEAD`
#     while on it).
#
# Reads are unrestricted. Interpreters (python, node, ...) are not inspected.
# Not a defense against a determined adversary; it stops a well-meaning worker
# from writing outside its worktree or pushing to a shared branch.

set -uo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=guard-lib.sh
. "$here/guard-lib.sh"

# The environment binds first; otherwise the worker registry entry of this thread.
# Both lookups happen before stdin is read, so an inactive guard never blocks.
WORKTREE=${PLAYBOOK_WORKER_WORKTREE:-}
ENTRY_BRANCH=""
if [ -z "$WORKTREE" ]; then
  tid=$(thread_id)
  [ -n "$tid" ] || exit 0
  wreg=${PLAYBOOK_WORKER_REGISTRY:-$HOME/.local/state/agent-playbook/worker-threads.json}
  entry=$(registry_entry "$wreg" "$tid") || exit 0
  WORKTREE=$(jq -r '.worktree // ""' <<<"$entry")
  ENTRY_BRANCH=$(jq -r '.branch // ""' <<<"$entry")
fi

WT=$(realpath -e -- "$WORKTREE" 2>/dev/null) || WT=""
HOOK_INPUT=$(cat)
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  deny "worker-guard: the worktree ($WORKTREE) does not resolve to a directory; refusing all tools"
fi
tool=$(jq -r '.tool_name // ""' <<<"$HOOK_INPUT") || deny "worker-guard: unreadable hook input"
BRANCH=${PLAYBOOK_WORKER_BRANCH:-$ENTRY_BRANCH}
read -ra PROTECTED <<<"${PLAYBOOK_PROTECTED_BRANCHES:-main master develop}"

# BASE: the directory relative paths count from.
BASE=$(tool_cwd)
[ -n "$BASE" ] || BASE=$WT
BASE=$(realpath -m -- "$BASE")

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

# resolve_word <word>: the canonical path a word names, from BASE; 1 if unverifiable.
resolve_word() {
  local p
  p=$(expand_wt "$1") || return 1
  [ -n "$p" ] || return 1
  case $p in '~'*) return 1 ;; esac
  canon_path "$p" "$BASE"
}

# inside_wt <word>: true when the path the word names resolves inside the worktree.
inside_wt() {
  local p
  p=$(resolve_word "$1") || return 1
  path_inside "$p" "$WT"
}

protected_branch() {
  local b
  for b in "${PROTECTED[@]}"; do
    [ "$1" = "$b" ] && return 0
  done
  return 1
}

# short_ref <ref>: a branch name without refs/heads/ or a remote prefix.
short_ref() {
  local r=${1#+}
  r=${r#refs/heads/}
  r=${r#refs/remotes/origin/}
  r=${r#origin/}
  printf '%s' "$r"
}

# push_allowed: W[0..] is `git ... push`; GIT_ARGS holds the words after `push`.
push_allowed() {
  local a part dir current="" sub dst parts=() pos=() lease=()
  dir=$(expand_wt "${GIT_DIRS[0]:-$WT}") || dir=$WT
  for a in "${GIT_ARGS[@]}"; do
    case $a in
      --all | --mirror | --tags)
        REASON="git push $a is not allowed for workers"
        return 1
        ;;
      --force-with-lease=*) lease+=("${a#--force-with-lease=}") ;;
      -*) ;;
      *) pos+=("$a") ;;
    esac
  done
  current=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null) || current=""

  # Protected branches are refused first, bound or not, so a worker bound to
  # main cannot push main. HEAD counts as the branch the worktree is on.
  for a in "${lease[@]}" "${pos[@]:1}"; do
    sub=${a#+}
    read -ra parts <<<"${sub//:/ }"
    for part in "${parts[@]}"; do
      if [ "$part" = HEAD ]; then part=$current; fi
      if protected_branch "$(short_ref "$part")"; then
        REASON="git push must not target $(short_ref "$part"); workers push only their own branch"
        return 1
      fi
    done
  done

  if [ -n "$BRANCH" ]; then
    # Bound worker: an explicit remote and exactly its own branch as destination.
    if [ "${#pos[@]}" -lt 2 ]; then
      REASON="name the remote and the branch: git -C \"\$PLAYBOOK_WORKER_WORKTREE\" push origin $BRANCH"
      return 1
    fi
    for a in "${pos[@]:1}"; do
      dst=${a##*:}
      if [ "$dst" = HEAD ]; then dst=$current; fi
      if [ "$(short_ref "$dst")" != "$BRANCH" ]; then
        REASON="workers push only their own branch $BRANCH; refused destination: $a"
        return 1
      fi
    done
    for a in "${lease[@]}"; do
      if [ "$(short_ref "${a%%:*}")" != "$BRANCH" ]; then
        REASON="--force-with-lease must name $BRANCH; refused: $a"
        return 1
      fi
    done
    return 0
  fi

  # Unbound worker: a plain push, or one naming HEAD, pushes the worktree's own branch.
  local push_current=0
  if [ "${#pos[@]}" -le 1 ]; then push_current=1; fi
  for a in "${pos[@]:1}"; do
    [ "$a" = HEAD ] && push_current=1
  done
  if [ "$push_current" = 1 ] && [ -n "$current" ] && protected_branch "$current"; then
    REASON="this worktree is on $current; workers must not push it"
    return 1
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

# check_targets <cmd> <word>...: every non-option word must be inside the worktree.
check_targets() {
  local cmd=$1 a
  shift
  for a in "$@"; do
    case $a in
      -*) continue ;;
      of=*) a=${a#of=} ;;
    esac
    if ! inside_wt "$a"; then
      REASON="$cmd may only write inside the worktree; cannot verify or outside: $a"
      return 1
    fi
  done
}

# sed_allowed: W is a sed command. Only in-place edits write; their file
# operands (not the script) must be inside the worktree.
sed_allowed() {
  local i=1 n=${#W[@]} a inplace=0 script_given=0 files=()
  while ((i < n)); do
    a=${W[i]}
    case $a in
      --in-place | --in-place=*) inplace=1 ;;
      -e | --expression | -f | --file | -l | --line-length)
        [[ $a == -e || $a == --expression || $a == -f || $a == --file ]] && script_given=1
        i=$((i + 1))
        ;;
      --expression=* | --file=*) script_given=1 ;;
      --*) ;;
      -?*)
        # A short option cluster such as -i, -ni, -Ei or -i.bak. Letters after
        # `e`, `f` or `l` are that option's value; `i` takes the rest as a suffix.
        local k ch
        for ((k = 1; k < ${#a}; k++)); do
          ch=${a:k:1}
          case $ch in
            i)
              inplace=1
              break
              ;;
            e | f)
              script_given=1
              [ $((k + 1)) -lt ${#a} ] || i=$((i + 1))
              break
              ;;
            l)
              [ $((k + 1)) -lt ${#a} ] || i=$((i + 1))
              break
              ;;
          esac
        done
        ;;
      *)
        if ((script_given)); then files+=("$a"); else script_given=1; fi
        ;;
    esac
    i=$((i + 1))
  done
  ((inplace)) || return 0
  check_targets sed "${files[@]}"
}

# find_allowed: W is a find command. Actions that write must search inside the worktree.
find_allowed() {
  local i=1 n=${#W[@]} a writes=0 starts=() sub=() saved=()
  while ((i < n)) && [[ ${W[i]} != -* && ${W[i]} != '(' && ${W[i]} != '!' ]]; do
    starts+=("${W[i]}")
    i=$((i + 1))
  done
  [ "${#starts[@]}" -gt 0 ] || starts=(.)
  while ((i < n)); do
    a=${W[i]}
    case $a in
      -delete | -fprint | -fprint0 | -fprintf | -fls) writes=1 ;;
      -exec | -execdir | -ok | -okdir)
        writes=1
        sub=()
        i=$((i + 1))
        while ((i < n)) && [ "${W[i]}" != ';' ] && [ "${W[i]}" != '+' ]; do
          if [ "${W[i]}" = '{}' ]; then sub+=("$WT"); else sub+=("${W[i]}"); fi
          i=$((i + 1))
        done
        if [ "${#sub[@]}" -gt 0 ]; then
          saved=("${W[@]}")
          W=("${sub[@]}")
          segment_allowed || return 1
          W=("${saved[@]}")
        fi
        ;;
    esac
    i=$((i + 1))
  done
  ((writes)) || return 0
  for a in "${starts[@]}"; do
    if ! inside_wt "$a"; then
      REASON="find with -delete, -exec or -ok must search inside the worktree; refused: $a"
      return 1
    fi
  done
}

# unwrap: drop wrappers that run the next command (env, command, nice, nohup,
# timeout) from the front of W.
unwrap() {
  local cmd
  while ((${#W[@]} > 0)); do
    cmd=${W[0]##*/}
    case $cmd in
      env)
        W=("${W[@]:1}")
        while ((${#W[@]} > 0)) && [[ ${W[0]} == -* || ${W[0]} == *=* ]]; do
          case ${W[0]} in
            -u | --unset | -C | --chdir | -S | --split-string)
              REASON="env ${W[0]} cannot be analyzed"
              return 1
              ;;
          esac
          W=("${W[@]:1}")
        done
        ;;
      command | nohup)
        W=("${W[@]:1}")
        while ((${#W[@]} > 0)) && [[ ${W[0]} == -* ]]; do W=("${W[@]:1}"); done
        ;;
      nice)
        W=("${W[@]:1}")
        while ((${#W[@]} > 0)) && [[ ${W[0]} == -* ]]; do
          [ "${W[0]}" = -n ] && W=("${W[@]:1}")
          W=("${W[@]:1}")
        done
        ;;
      timeout)
        W=("${W[@]:1}")
        while ((${#W[@]} > 0)) && [[ ${W[0]} == -* ]]; do
          case ${W[0]} in -s | --signal | -k | --kill-after) W=("${W[@]:1}") ;; esac
          W=("${W[@]:1}")
        done
        W=("${W[@]:1}") # the duration
        ;;
      *) return 0 ;;
    esac
  done
}

# segment_allowed: W is one simple command. Sets REASON and returns 1 when denied.
segment_allowed() {
  local cmd a dir
  unwrap || return 1
  ((${#W[@]} > 0)) || return 0
  while [[ ${W[0]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    W=("${W[@]:1}")
    ((${#W[@]} > 0)) || return 0
    unwrap || return 1
  done
  cmd=${W[0]##*/}
  case $cmd in
    git) git_allowed ;;
    cd)
      if [ "${#W[@]}" -ne 2 ] || ! inside_wt "${W[1]}"; then
        REASON="cd must enter a directory inside the worktree"
        return 1
      fi
      dir=$(resolve_word "${W[1]}") && BASE=$dir
      ;;
    sh | bash | zsh | dash | ksh | eval)
      for a in "${W[@]:1}"; do
        if [[ $cmd == eval || $a == -*c* ]]; then
          REASON="$cmd runs a command line the guard cannot check; run the command directly"
          return 1
        fi
      done
      ;;
    xargs)
      for a in "${W[@]:1}"; do
        case ${a##*/} in
          rm | rmdir | mv | cp | mkdir | touch | ln | chmod | chown | install | tee | truncate | dd | \
            rsync | unlink | shred | sed | sh | bash | git)
            REASON="xargs $a takes its paths from input the guard cannot check"
            return 1
            ;;
        esac
      done
      ;;
    find) find_allowed ;;
    sed) sed_allowed ;;
    rm | rmdir | mv | cp | mkdir | touch | ln | chmod | chown | install | tee | truncate | dd | rsync | unlink | shred)
      check_targets "$cmd" "${W[@]:1}"
      ;;
  esac
}

# check_bash: validate every simple command of a shell line.
check_bash() {
  local cmdline element
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
    patch_files=$(sed -n -e 's/^\*\*\* \(Add\|Update\|Delete\) File: //p' -e 's/^\*\*\* Move to: //p' <<<"$patch")
    if [ -z "$patch_files" ]; then
      deny "worker-guard: apply_patch names no file; cannot verify it stays inside the worktree"
    fi
    while IFS= read -r p; do check_path "$p"; done <<<"$patch_files"
    exit 0
    ;;
  Bash | shell | local_shell | exec_command | unified_exec)
    check_bash
    exit 0
    ;;
  *) exit 0 ;;
esac
