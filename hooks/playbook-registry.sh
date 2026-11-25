#!/usr/bin/env bash
# Writes the guard registries, so nobody has to edit their JSON by hand.
#
# Usage:
#   playbook-registry.sh coordinator add <thread-id>
#   playbook-registry.sh coordinator remove <thread-id>
#   playbook-registry.sh drain <handoff-marker>
#   playbook-registry.sh review snapshot <thread-id> <repo> <base-oid> <head-oid>
#   playbook-registry.sh review add <thread-id> <snapshot-root>
#   playbook-registry.sh review remove <thread-id>
#   playbook-registry.sh show coordinator|review
#
# `review snapshot` exports every tracked file of <head-oid> into a fresh
# directory (tree/, no .git, no export attributes applied), refuses an
# incomplete export, writes REVIEW.patch (base..head) next to tree/, makes it
# read-only, registers it for the reviewer thread and prints its path.
# `review remove` unregisters the thread and deletes a snapshot made that way.
#
# `drain` marks the calling thread ($PLAYBOOK_THREAD_ID, else $T3CODE_THREAD_ID)
# as draining and stores the handoff marker that lets its successor launch
# through. The registry files are the ones the guards read:
#   coordinator: ${PLAYBOOK_COORDINATOR_REGISTRY:-$HOME/.local/state/agent-playbook/coordinator-threads.json}
#   review:      ${PLAYBOOK_REVIEW_REGISTRY:-$HOME/.local/state/agent-playbook/review-threads.json}
# Both use the layout {"<thread-id>": {...}}. Every change takes a lock and
# replaces the file atomically.

set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=guard-lib.sh
. "$here/guard-lib.sh"

state=$HOME/.local/state/agent-playbook
coordinators=${PLAYBOOK_COORDINATOR_REGISTRY:-$state/coordinator-threads.json}
reviews=${PLAYBOOK_REVIEW_REGISTRY:-$state/review-threads.json}

die() {
  printf 'playbook-registry: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '4,11s/^#   //p' "${BASH_SOURCE[0]}" >&2
  exit 1
}

# update <file> <jq filter> [jq args...]: apply the filter to the registry under a lock.
update() {
  local file=$1 filter=$2 tmp tries=0
  shift 2
  (umask 077 && mkdir -p -- "$(dirname -- "$file")")
  LOCK=$file.lock
  until mkdir -- "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    ((tries < 100)) || die "cannot take the lock $LOCK; remove it if no other writer runs"
    sleep 0.1
  done
  trap 'rm -rf -- "$LOCK"' EXIT
  [ -e "$file" ] || printf '{}\n' >"$file"
  jq -e 'type == "object" and (has("threads") | not)' "$file" >/dev/null 2>&1 \
    || die "$file is not a {\"<thread-id>\": {...}} object; fix or remove it"
  tmp=$(mktemp -- "$file.XXXXXX")
  if ! jq "$@" "$filter" "$file" >"$tmp"; then
    rm -f -- "$tmp"
    die "could not update $file"
  fi
  mv -f -- "$tmp" "$file"
}

# snapshot <thread-id> <repo> <base-oid> <head-oid>: build, check and register a review snapshot.
snapshot() {
  local tid=$1 repo=$2 base=$3 head=$4 root oid
  for oid in "$base" "$head"; do
    [[ $oid =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || die "$oid is not a full commit id"
    git -C "$repo" cat-file -e "$oid^{commit}" 2>/dev/null || die "$oid is not a commit in $repo"
  done
  root=$(mktemp -d -t playbook-review.XXXXXX)
  GIT_INDEX_FILE=$root/.index git -C "$repo" read-tree "$head"
  GIT_INDEX_FILE=$root/.index git -C "$repo" checkout-index --all --prefix="$root/tree/"
  rm -f -- "$root/.index"
  mkdir -p -- "$root/tree"
  if ! diff -q <(git -C "$repo" -c core.quotePath=false ls-tree -r --name-only "$head") \
    <(cd "$root/tree" && find . ! -type d | sed 's|^\./||' | LC_ALL=C sort) >/dev/null; then
    rm -rf -- "$root"
    die "the export of $head is incomplete (submodules or unsupported entries); review it another way"
  fi
  git -C "$repo" diff "$base" "$head" >"$root/REVIEW.patch"
  printf '%s %s\n' "$base" "$head" >"$root/.playbook-snapshot"
  chmod -R a-w -- "$root"
  update "$reviews" '.[$t] = {snapshot_root: $r}' --arg t "$tid" --arg r "$root"
  printf '%s\n' "$root"
}

# unregister_review <thread-id>: drop the entry; delete the snapshot if `snapshot` made it.
unregister_review() {
  local tid=$1 root=""
  if [ -r "$reviews" ]; then
    root=$(jq -r --arg t "$tid" '.[$t].snapshot_root // ""' "$reviews" 2>/dev/null) || root=""
  fi
  update "$reviews" 'del(.[$t])' --arg t "$tid"
  if [ -n "$root" ] && [ -f "$root/.playbook-snapshot" ]; then
    chmod -R u+w -- "$root"
    rm -rf -- "$root"
  fi
}

need() {
  [ "$1" -ge "$2" ] || usage
}

[ $# -ge 1 ] || usage
case $1 in
  coordinator)
    need $# 3
    case $2 in
      add) update "$coordinators" '.[$t] = (.[$t] // {draining: false})' --arg t "$3" ;;
      remove) update "$coordinators" 'del(.[$t])' --arg t "$3" ;;
      *) usage ;;
    esac
    ;;
  drain)
    need $# 2
    tid=$(thread_id)
    [ -n "$tid" ] || die "drain needs PLAYBOOK_THREAD_ID or T3CODE_THREAD_ID"
    [ -n "$2" ] || die "the handoff marker must not be empty"
    update "$coordinators" 'if has($t) then .[$t] += {draining: true, handoff_marker: $m} else error("thread \($t) is not registered") end' \
      --arg t "$tid" --arg m "$2"
    ;;
  review)
    need $# 3
    case $2 in
      add)
        need $# 4
        root=$(realpath -e -- "$4" 2>/dev/null) && [ -d "$root" ] || die "snapshot root $4 is not a directory"
        update "$reviews" '.[$t] = {snapshot_root: $r}' --arg t "$3" --arg r "$root"
        ;;
      snapshot)
        need $# 6
        snapshot "$3" "$4" "$5" "$6"
        ;;
      remove) unregister_review "$3" ;;
      *) usage ;;
    esac
    ;;
  show)
    need $# 2
    case $2 in
      coordinator) file=$coordinators ;;
      review) file=$reviews ;;
      *) usage ;;
    esac
    if [ -e "$file" ]; then jq . "$file"; else echo '{}'; fi
    ;;
  *) usage ;;
esac
