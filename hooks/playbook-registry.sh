#!/usr/bin/env bash
# Writes the guard registries, so nobody has to edit their JSON by hand.
#
# Usage:
#   playbook-registry.sh coordinator add <thread-id> [slice]
#   playbook-registry.sh coordinator remove <thread-id>
#   playbook-registry.sh status [thread-id]
#   playbook-registry.sh renew
#   playbook-registry.sh drain <handoff-marker> [--cancelled]
#   playbook-registry.sh bind-candidate <candidate-thread-id>
#   playbook-registry.sh takeover <predecessor-thread-id> <handoff-marker>
#   playbook-registry.sh abort <handoff-marker>
#   playbook-registry.sh worker add <thread-id> <worktree> [branch]
#   playbook-registry.sh worker remove <thread-id>
#   playbook-registry.sh review snapshot [--with-base] [--fetch <remote> <ref>] <thread-id> <repo> <base-oid> <head-oid>
#   playbook-registry.sh review add <thread-id> <snapshot-root>
#   playbook-registry.sh review remove <thread-id>
#   playbook-registry.sh show coordinator|review|worker
#
# The calling thread is $PLAYBOOK_THREAD_ID, else $T3CODE_THREAD_ID.
#
# Coordinator lifecycle (entries of coordinator-threads.json):
#   active     --renew--> active (new generation, started_at reset, cancel_count kept)
#   active     --drain <marker>--> draining (15 minute drain deadline)
#   draining   --bind-candidate <tid>--> the successor tid is a candidate
#   candidate  --takeover <pred> <marker>--> candidate becomes active, pred retired (one step)
#   draining   --abort <marker>--> active again, the bound candidate is retired
# A retired entry is never deleted by these commands; the guards keep it inert.
#
# Registry files, read by the guards (each is a {"<thread-id>": {...}} map):
#   coordinator: ${PLAYBOOK_COORDINATOR_REGISTRY:-$HOME/.local/state/agent-playbook/coordinator-threads.json}
#   review:      ${PLAYBOOK_REVIEW_REGISTRY:-$HOME/.local/state/agent-playbook/review-threads.json}
#   worker:      ${PLAYBOOK_WORKER_REGISTRY:-$HOME/.local/state/agent-playbook/worker-threads.json}
# Every change takes a lock and replaces the file atomically.
#
# `review snapshot` exports the head commit into a fresh directory, tree/, blob
# for blob: no checkout, no smudge, EOL or export-ignore attributes, no .git.
# With --with-base the base commit goes to base/ in the same directory. Gitlinks
# (submodules) and unknown modes are refused. REVIEW.patch (base..head) sits
# beside them, everything is made read-only, and the thread is registered with
# the snapshot. `review remove` unregisters the thread and deletes the snapshot
# only when it is the one `review snapshot` made.

set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=guard-lib.sh
. "$here/guard-lib.sh"

statedir=$HOME/.local/state/agent-playbook
coordinators=${PLAYBOOK_COORDINATOR_REGISTRY:-$statedir/coordinator-threads.json}
reviews=${PLAYBOOK_REVIEW_REGISTRY:-$statedir/review-threads.json}
workers=${PLAYBOOK_WORKER_REGISTRY:-$statedir/worker-threads.json}

# Effective lifecycle state of an entry: the `state` field, else from `draining`.
# Prepended to every filter that needs it.
JQ_STATE='def st: .state // (if .draining == true then "draining" else "active" end);'

LOCK=""
LOCK_TRAP=""

die() {
  printf 'playbook-registry: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '4,18s/^# //p' "${BASH_SOURCE[0]}" >&2
  exit 1
}

# need <count> <min> <max>: the argument count must be in range, else usage.
need() {
  [ "$1" -ge "$2" ] && [ "$1" -le "$3" ] || usage
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# lock_take <file>: take <file>.lock (mkdir is atomic), waiting about 10 seconds.
# The EXIT trap releases it if the process dies first; lock_release restores the
# trap the caller had.
lock_take() {
  local file=$1 tries=0
  (umask 077 && mkdir -p -- "$(dirname -- "$file")")
  LOCK=$file.lock
  until mkdir -- "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    ((tries < 100)) || die "cannot take the lock $LOCK; remove it if no other writer runs"
    sleep 0.1
  done
  LOCK_TRAP=$(trap -p EXIT)
  trap '[ -z "${LOCK:-}" ] || rm -rf -- "$LOCK"' EXIT
}

# lock_release: drop the lock now and put back the caller's EXIT trap.
lock_release() {
  if [ -n "$LOCK" ]; then
    rm -rf -- "$LOCK"
  fi
  LOCK=""
  trap - EXIT
  if [ -n "$LOCK_TRAP" ]; then
    eval "$LOCK_TRAP"
  fi
  LOCK_TRAP=""
}

# write_registry <file> <jq filter> [jq args...]: replace the registry with the
# filter's result. The caller holds the lock. Returns 1 when jq refuses.
write_registry() {
  local file=$1 filter=$2 tmp
  shift 2
  if [ ! -e "$file" ]; then
    (umask 077 && printf '{}\n' >"$file")
  fi
  jq -e 'type == "object" and (has("threads") | not)' "$file" >/dev/null 2>&1 \
    || die "$file is not a {\"<thread-id>\": {...}} object; fix or remove it"
  tmp=$(mktemp -- "$file.XXXXXX")
  if ! jq "$@" "$filter" "$file" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$file"
}

# update <file> <jq filter> [jq args...]: apply the filter to the registry under the lock.
update() {
  local file=$1
  lock_take "$file"
  if ! write_registry "$@"; then
    lock_release
    die "could not update $file"
  fi
  lock_release
}

# field <thread-id> <jq expression>: one value of a coordinator entry (caller holds the lock).
field() {
  jq -r --arg t "$1" ".[\$t] | $2" "$coordinators"
}

require_caller() {
  local tid
  tid=$(thread_id)
  [ -n "$tid" ] || die "this needs PLAYBOOK_THREAD_ID or T3CODE_THREAD_ID"
  printf '%s' "$tid"
}

# ── Coordinators ───────────────────────────────────────────────────────

coordinator_add() {
  local tid=$1 slice=${2:-}
  [ -n "$tid" ] || die "the thread id must not be empty"
  update "$coordinators" \
    'if has($t) then . else .[$t] = ({state: "active", draining: false, generation: 1, started_at: $now, cancel_count: 0} + (if $s == "" then {} else {slice: $s} end)) end' \
    --arg t "$tid" --arg now "$(now_iso)" --arg s "$slice"
}

coordinator_remove() {
  [ -n "$1" ] || die "the thread id must not be empty"
  update "$coordinators" 'del(.[$t])' --arg t "$1"
}

# status [thread-id]: the lifecycle state of a coordinator, read only.
status() {
  local tid=${1:-}
  [ -n "$tid" ] || tid=$(require_caller)
  [ -r "$coordinators" ] || die "no coordinator registry at $coordinators"
  jq -e --arg t "$tid" 'has($t)' "$coordinators" >/dev/null 2>&1 \
    || die "thread $tid is not registered"
  jq -r --arg t "$tid" --arg now "$(now_iso)" "$JQ_STATE"'
    .[$t] as $e
    | ($e.started_at) as $s
    | (if $s then (($now | fromdateiso8601) - ($s | fromdateiso8601)) else null end) as $age
    | ([
        "thread: \($t)",
        "state: \($e | st)",
        "slice: \($e.slice // "")",
        "generation: \($e.generation // 1)",
        "started_at: \($s // "unknown")",
        "age_seconds: \($age // "unknown")",
        "cancel_count: \($e.cancel_count // 0)"
      ]
      + (if $e.drain_deadline then ["drain_deadline: \($e.drain_deadline)"] else [] end)
      + [(if ($age // -1) >= 21600 then "ROTATE_DUE: age>=6h" else "ROTATE_DUE: no" end)])
    | .[]
  ' "$coordinators"
}

# renew: a registered active coordinator starts a new generation of its shift.
renew() {
  local tid slice gen cc
  tid=$(require_caller)
  lock_take "$coordinators"
  if ! write_registry "$coordinators" "$JQ_STATE"'
    if has($t) and ((.[$t] | st) == "active") then
      .[$t] |= (.generation = ((.generation // 1) + 1) | .started_at = $now | .state = "active" | .draining = false)
    else error("renew: \($t) is not a registered active coordinator") end
  ' --arg t "$tid" --arg now "$(now_iso)"; then
    lock_release
    die "could not renew $tid"
  fi
  slice=$(field "$tid" '.slice // "(none)"')
  gen=$(field "$tid" '.generation // 1')
  cc=$(field "$tid" '.cancel_count // 0')
  lock_release
  cat <<EOF
recovery packet
  thread:       $tid
  slice:        $slice
  generation:   $gen
  cancel_count: $cc
  recovery:
    1. Read the slice brief, then the PRs, workers and scheduled tasks you own.
    2. Run: playbook-registry.sh status   (before any dispatch)
    3. Continue the slice; drain with a fresh handoff marker when a successor is needed.
EOF
}

# drain <marker> [--cancelled]: the calling coordinator starts its handoff.
drain() {
  local tid marker=$1 cancelled=0 deadline cc gen
  tid=$(require_caller)
  [ -n "$marker" ] && [[ $marker != --* ]] || die "the handoff marker must not be empty or an option"
  case ${2:-} in
    '') ;;
    --cancelled) cancelled=1 ;;
    *) usage ;;
  esac
  deadline=$(date -u -d '+15 minutes' +%Y-%m-%dT%H:%M:%SZ)
  lock_take "$coordinators"
  if ! write_registry "$coordinators" "$JQ_STATE"'
    if has($t) and ((.[$t] | st) != "retired" and (.[$t] | st) != "candidate") then
      .[$t] |= (. + {state: "draining", draining: true, handoff_marker: $m, drain_deadline: $deadline}
                | .cancel_count = ((.cancel_count // 0) + $c))
    else error("drain: \($t) is not a registered coordinator that can drain") end
  ' --arg t "$tid" --arg m "$marker" --arg deadline "$deadline" --argjson c "$cancelled"; then
    lock_release
    die "could not drain $tid"
  fi
  cc=$(field "$tid" '.cancel_count // 0')
  gen=$(field "$tid" '.generation // 1')
  lock_release
  printf 'drain_deadline: %s\ncancel_count: %s\n' "$deadline" "$cc"
  if [ "$cc" -ge 2 ]; then
    printf 'ESCALATE_OWNER: cancel_count is %s; the owner must decide before another drain\n' "$cc"
  fi
  cat <<EOF
handoff packet
  predecessor: $tid (generation $gen, cancel_count $cc)
  handoff_marker: $marker
  successor: launch it idle (carrying the marker in title or clientRequestId), then
    playbook-registry.sh bind-candidate <successor-thread-id>
  send the successor this packet; it runs: playbook-registry.sh takeover $tid $marker
EOF
}

# bind-candidate <candidate-thread-id>: a draining coordinator names its successor.
bind_candidate() {
  local tid cand=$1
  tid=$(require_caller)
  [ -n "$cand" ] || die "the candidate thread id must not be empty"
  [ "$cand" != "$tid" ] || die "a coordinator cannot be its own candidate"
  lock_take "$coordinators"
  if ! write_registry "$coordinators" "$JQ_STATE"'
    if has($t) | not then error("bind-candidate: \($t) is not registered")
    elif (.[$t] | st) != "draining" then error("bind-candidate: \($t) is not draining")
    elif ((.[$t].candidate // "") != "" and .[$t].candidate != $c) then
      error("bind-candidate: \($t) is already bound to \(.[$t].candidate)")
    elif has($c) and ((.[$c] | st) != "candidate" or .[$c].predecessor != $t) then
      error("bind-candidate: \($c) is already registered (\(.[$c] | st))")
    else
      .[$t].candidate = $c
      | .[$c] = {state: "candidate", draining: false, predecessor: $t,
                 handoff_marker: (.[$t].handoff_marker // ""), slice: (.[$t].slice // ""),
                 generation: (.[$t].generation // 1), started_at: $now}
    end
  ' --arg t "$tid" --arg c "$cand" --arg now "$(now_iso)"; then
    lock_release
    die "could not bind $cand"
  fi
  lock_release
  printf 'candidate bound: %s (predecessor %s)\n' "$cand" "$tid"
  printf 'the candidate must now run: playbook-registry.sh takeover %s <handoff-marker>\n' "$tid"
}

# takeover <predecessor-thread-id> <handoff-marker>: the candidate becomes the
# active coordinator and the predecessor is retired, in one locked write.
takeover() {
  local tid pred=$1 marker=$2 gen
  tid=$(require_caller)
  [ -n "$pred" ] && [ -n "$marker" ] || die "takeover needs <predecessor-thread-id> <handoff-marker>"
  [ "$pred" != "$tid" ] || die "a coordinator cannot take over from itself"
  lock_take "$coordinators"
  if ! write_registry "$coordinators" "$JQ_STATE"'
    (.[$p].slice // "") as $s
    | if has($t) and (.[$t] | st) == "active" and (.[$t].predecessor // "") == $p
         and has($p) and (.[$p] | st) == "retired" and (.[$p].successor // "") == $t then
        .
      elif has($p) | not then error("takeover: predecessor \($p) is not registered")
      elif (.[$p] | st) != "draining" then error("takeover: predecessor \($p) is not draining")
      elif (.[$p].handoff_marker // "") != $m then error("takeover: the handoff marker does not match")
      elif ((.[$p].candidate // "") != "" and .[$p].candidate != $t) then
        error("takeover: \($p) is bound to candidate \(.[$p].candidate), not \($t)")
      elif has($t) and (.[$t] | st) != "candidate" then error("takeover: \($t) is \(.[$t] | st), not a candidate")
      elif $s != "" and any(to_entries[];
              .key != $p and .key != $t and ((.value | st) == "active" or (.value | st) == "draining")
              and ((.value.slice // "") == $s)) then
        error("takeover: slice \($s) already has an active or draining owner")
      else
        .[$t] = {state: "active", draining: false, generation: ((.[$p].generation // 1) + 1),
                 started_at: $now, cancel_count: (.[$p].cancel_count // 0), predecessor: $p, slice: $s}
        | .[$p] += {state: "retired", draining: true, retired_at: $now, successor: $t}
      end
  ' --arg t "$tid" --arg p "$pred" --arg m "$marker" --arg now "$(now_iso)"; then
    lock_release
    die "could not take over from $pred"
  fi
  gen=$(field "$tid" '.generation // 1')
  lock_release
  printf 'took over from %s: %s is active at generation %s\n' "$pred" "$tid" "$gen"
}

# abort <handoff-marker>: the draining coordinator resumes; its candidate is retired.
abort() {
  local tid marker=$1
  tid=$(require_caller)
  [ -n "$marker" ] || die "the handoff marker must not be empty"
  lock_take "$coordinators"
  if ! write_registry "$coordinators" "$JQ_STATE"'
    if has($t) | not then error("abort: \($t) is not registered")
    elif (.[$t] | st) != "draining" or (.[$t].handoff_marker // "") != $m then
      error("abort: \($t) is not draining under this handoff marker")
    else
      (.[$t].candidate // "") as $c
      | (if $c != "" and has($c) and (.[$c] | st) == "candidate"
           then .[$c] += {state: "retired", draining: true, retired_at: $now}
           else . end)
      | .[$t] |= (del(.handoff_marker, .drain_deadline, .candidate) | .state = "active" | .draining = false)
    end
  ' --arg t "$tid" --arg m "$marker" --arg now "$(now_iso)"; then
    lock_release
    die "could not abort the handoff of $tid"
  fi
  lock_release
  printf 'handoff aborted: %s is active again\n' "$tid"
}

# ── Workers ────────────────────────────────────────────────────────────

worker_add() {
  local tid=$1 wt branch=${3:-}
  [ -n "$tid" ] || die "the thread id must not be empty"
  wt=$(realpath -e -- "$2" 2>/dev/null) || wt=""
  [ -n "$wt" ] && [ -d "$wt" ] || die "worktree $2 is not a directory"
  update "$workers" '.[$t] = {worktree: $wt} + (if $b == "" then {} else {branch: $b} end)' \
    --arg t "$tid" --arg wt "$wt" --arg b "$branch"
}

worker_remove() {
  [ -n "$1" ] || die "the thread id must not be empty"
  update "$workers" 'del(.[$t])' --arg t "$1"
}

# ── Review snapshots ───────────────────────────────────────────────────

# snapshot_package <root>: the package_id recorded in a snapshot's marker file.
snapshot_package() {
  sed -n 's/^package_id=//p' -- "$1/.playbook-snapshot"
}

# discard <root>: remove a snapshot directory, which may be read-only.
discard() {
  chmod -R u+w -- "$1" 2>/dev/null || true
  rm -rf -- "$1"
}

# export_tree <repo> <commit> <dest>: write every file of the commit to dest exactly
# as stored: blob bytes, no checkout filters, no export-ignore, no .git. Returns 1
# on a gitlink, an unsafe path, an unknown mode or an incomplete export.
export_tree() {
  local repo=$1 commit=$2 dest=$3 rec meta path mode blob target expected seen=0
  mkdir -p -- "$dest" || return 1
  expected=$(git -C "$repo" ls-tree -rz "$commit" | tr -cd '\0' | wc -c) || return 1
  while IFS= read -r -d '' rec; do
    meta=${rec%%$'\t'*}
    path=${rec#*$'\t'}
    read -r mode _ blob <<<"$meta"
    case $path in
      '' | /* | ../* | */../* | */.. | ..)
        echo "playbook-registry: unsafe path in the tree: $path" >&2
        return 1
        ;;
    esac
    case $mode in
      160000)
        echo "playbook-registry: $path is a submodule; review it another way" >&2
        return 1
        ;;
      120000 | 100644 | 100755) ;;
      *)
        echo "playbook-registry: $path has an unsupported mode $mode" >&2
        return 1
        ;;
    esac
    case $path in */*) mkdir -p -- "$dest/${path%/*}" || return 1 ;; esac
    if [ "$mode" = 120000 ]; then
      target=$(git -C "$repo" cat-file blob "$blob" && printf x) || return 1
      target=${target%x}
      ln -s -- "$target" "$dest/$path" || return 1
    else
      git -C "$repo" cat-file blob "$blob" >"$dest/$path" || return 1
      if [ "$mode" = 100755 ]; then
        chmod +x -- "$dest/$path" || return 1
      fi
    fi
    seen=$((seen + 1))
  done < <(git -C "$repo" ls-tree -rz "$commit")
  if ((seen != expected)); then
    echo "playbook-registry: the export of $commit is incomplete" >&2
    return 1
  fi
}

# build_snapshot <repo> <base> <head> <root> <with-base>: fill a snapshot directory.
# Every step is checked explicitly: callers run this inside `if !`, where set -e is off.
build_snapshot() {
  local repo=$1 base=$2 head=$3 root=$4 with_base=$5
  git -C "$repo" diff --no-color --no-ext-diff --no-textconv "$base" "$head" >"$root/REVIEW.patch" || return 1
  export_tree "$repo" "$head" "$root/tree" || return 1
  if [ "$with_base" = 1 ]; then
    export_tree "$repo" "$base" "$root/base" || return 1
  fi
  printf 'package_id=%s\nbase=%s\nhead=%s\n' "$(basename -- "$root")" "$base" "$head" >"$root/.playbook-snapshot" || return 1
  chmod -R a-w -- "$root" || return 1
}

# register_review <thread-id> <root> <package-id>: point the reviewer at its snapshot.
register_review() {
  local status=0
  lock_take "$reviews"
  write_registry "$reviews" '.[$t] = {snapshot_root: $r, package_id: $p}' \
    --arg t "$1" --arg r "$2" --arg p "$3" || status=1
  lock_release
  return "$status"
}

# review_snapshot [--with-base] [--fetch <remote> <ref>] <thread-id> <repo> <base-oid> <head-oid>
review_snapshot() {
  local with_base=0 fetch=0 fetch_remote="" fetch_ref="" tid repo base head root pid oid
  while [ $# -gt 0 ]; do
    case $1 in
      --with-base)
        with_base=1
        shift
        ;;
      --fetch)
        [ $# -ge 3 ] || usage
        fetch=1
        fetch_remote=$2
        fetch_ref=$3
        shift 3
        ;;
      *) break ;;
    esac
  done
  [ $# -eq 4 ] || usage
  tid=$1 repo=$2 base=$3 head=$4
  [ -n "$tid" ] || die "the thread id must not be empty"
  if [ "$fetch" = 1 ]; then
    [ -n "$fetch_remote" ] && [ -n "$fetch_ref" ] || die "--fetch needs a remote and a ref"
    git -C "$repo" fetch --no-tags -- "$fetch_remote" "$fetch_ref" >&2 \
      || die "could not fetch $fetch_ref from $fetch_remote"
  fi
  for oid in "$base" "$head"; do
    [[ $oid =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || die "$oid is not a full commit id"
    git -C "$repo" cat-file -e "$oid^{commit}" 2>/dev/null || die "$oid is not a commit in $repo"
  done
  root=$(mktemp -d -t playbook-review.XXXXXX) || die "cannot create a snapshot directory"
  if ! build_snapshot "$repo" "$base" "$head" "$root" "$with_base"; then
    discard "$root"
    die "could not build the snapshot of $head (see above)"
  fi
  pid=$(basename -- "$root")
  if ! register_review "$tid" "$root" "$pid"; then
    discard "$root"
    die "could not register the snapshot for $tid"
  fi
  printf '%s\n' "$root"
}

# review_remove <thread-id>: read and drop the entry under the lock, so a concurrent
# rebind is not clobbered; then delete the snapshot only if this entry made it.
review_remove() {
  local tid=$1 root="" pid=""
  [ -n "$tid" ] || die "the thread id must not be empty"
  lock_take "$reviews"
  if [ -r "$reviews" ]; then
    root=$(jq -r --arg t "$tid" '.[$t].snapshot_root // ""' "$reviews" 2>/dev/null) || root=""
    pid=$(jq -r --arg t "$tid" '.[$t].package_id // ""' "$reviews" 2>/dev/null) || pid=""
  fi
  if ! write_registry "$reviews" 'del(.[$t])' --arg t "$tid"; then
    lock_release
    die "could not update $reviews"
  fi
  lock_release
  if [ -n "$root" ] && [ -n "$pid" ] && [ -f "$root/.playbook-snapshot" ] \
    && [ "$(snapshot_package "$root")" = "$pid" ]; then
    discard "$root"
  fi
}

review_add() {
  local tid=$1 root
  [ -n "$tid" ] || die "the thread id must not be empty"
  root=$(realpath -e -- "$2" 2>/dev/null) || root=""
  [ -n "$root" ] && [ -d "$root" ] || die "snapshot root $2 is not a directory"
  update "$reviews" '.[$t] = {snapshot_root: $r}' --arg t "$tid" --arg r "$root"
}

# show <coordinator|review|worker>
show() {
  local file
  case $1 in
    coordinator) file=$coordinators ;;
    review) file=$reviews ;;
    worker) file=$workers ;;
    *) usage ;;
  esac
  if [ -e "$file" ]; then jq . "$file"; else echo '{}'; fi
}

# ── Dispatch ───────────────────────────────────────────────────────────

[ $# -ge 1 ] || usage
case $1 in
  coordinator)
    need $# 2 4
    case $2 in
      add)
        need $# 3 4
        coordinator_add "$3" "${4:-}"
        ;;
      remove)
        need $# 3 3
        coordinator_remove "$3"
        ;;
      *) usage ;;
    esac
    ;;
  status)
    need $# 1 2
    status "${2:-}"
    ;;
  renew)
    need $# 1 1
    renew
    ;;
  drain)
    need $# 2 3
    drain "$2" "${3:-}"
    ;;
  bind-candidate)
    need $# 2 2
    bind_candidate "$2"
    ;;
  takeover)
    need $# 3 3
    takeover "$2" "$3"
    ;;
  abort)
    need $# 2 2
    abort "$2"
    ;;
  worker)
    need $# 2 5
    case $2 in
      add)
        need $# 4 5
        worker_add "$3" "$4" "${5:-}"
        ;;
      remove)
        need $# 3 3
        worker_remove "$3"
        ;;
      *) usage ;;
    esac
    ;;
  review)
    need $# 2 999
    case $2 in
      add)
        need $# 4 4
        review_add "$3" "$4"
        ;;
      snapshot)
        shift 2
        review_snapshot "$@"
        ;;
      remove)
        need $# 3 3
        review_remove "$3"
        ;;
      *) usage ;;
    esac
    ;;
  show)
    need $# 2 2
    show "$2"
    ;;
  *) usage ;;
esac
