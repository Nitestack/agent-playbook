#!/usr/bin/env bash
# Automated tests for the PreToolUse guards: coordinator, worker and reviewer.
#
# Every case runs a guard with a hook JSON on stdin inside `env -i`, so the
# caller's T3CODE_THREAD_ID or PLAYBOOK_* variables cannot leak in. Fixtures live in
# one mktemp directory that is removed on exit; git runs with no global or system
# config. Exit 0 when every case passes, 1 otherwise.
#
# Usage: bash hooks/tests/test-hooks.sh

set -uo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
hooks=$(cd "$here/.." && pwd)

for tool in jq realpath git mktemp; do
  command -v "$tool" >/dev/null || {
    echo "test-hooks: missing required tool: $tool" >&2
    exit 1
  }
done

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ── Fixtures ───────────────────────────────────────────────────────────
home=$tmp/home
out=$tmp/outside
mkdir -p "$home" "$out"
echo secret >"$out/secret.txt"

# Coordinator registry: one live, one draining with a handoff marker.
cat >"$tmp/coordinators.json" <<'JSON'
{
  "coord-1": { "draining": false },
  "coord-drain": { "draining": true, "handoff_marker": "HANDOFF-42" }
}
JSON

# Worker worktrees: a feature branch and a worktree on main.
wt=$tmp/wt
wt_main=$tmp/wt-main
mkdir -p "$wt/src" "$wt_main"
git -C "$wt" init -q -b feature/x
git -C "$wt_main" init -q -b main
ln -s "$out" "$wt/escape"

# Reviewer snapshot: .md files, a symlink that escapes, and three registry shapes.
snap=$tmp/snap
mkdir -p "$snap/sub"
echo '# a' >"$snap/a.md"
echo '# b' >"$snap/sub/b.md"
ln -s "$out" "$snap/leak"
cat >"$tmp/reviewers.json" <<JSON
{
  "rev-1": { "snapshot_root": "$snap" },
  "rev-nosnap": {},
  "rev-missing": { "snapshot_root": "$tmp/does-not-exist" }
}
JSON
cat >"$tmp/reviewers-array.json" <<JSON
[ { "thread_id": "rev-arr", "snapshot_root": "$snap" } ]
JSON

# ── Harness ────────────────────────────────────────────────────────────
pass=0
fail=0
RC=0
OUT=""
ERR=""

# run_guard <guard> <json> [VAR=value ...]: sets RC, OUT and ERR.
run_guard() {
  local guard=$1 json=$2
  shift 2
  RC=0
  OUT=$(env -i PATH="$PATH" HOME="$home" "$@" bash "$hooks/$guard" <<<"$json" 2>"$tmp/stderr") || RC=$?
  ERR=$(cat "$tmp/stderr")
}

# expect_allow <name> <guard> <json> [VAR=value ...]
expect_allow() {
  local name=$1 guard=$2 json=$3
  shift 3
  run_guard "$guard" "$json" "$@"
  if [ "$RC" -eq 0 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL (expected allow, exit $RC): $name -- $ERR"
  fi
}

# expect_deny <name> <guard> <json> [VAR=value ...]
expect_deny() {
  local name=$1 guard=$2 json=$3
  shift 3
  run_guard "$guard" "$json" "$@"
  if [ "$RC" -eq 2 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$OUT" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL (expected deny, exit $RC): $name -- stdout: $OUT stderr: $ERR"
  fi
}

bash_call() {
  jq -cn --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'
}

tool_call() {
  jq -cn --arg t "$1" --argjson i "$2" '{tool_name: $t, tool_input: $i}'
}

patch_call() {
  jq -cn --arg p "$1" '{tool_name: "apply_patch", tool_input: {input: $p}}'
}

# cwd_call <tool> <input-json> <cwd>: a tool call whose hook input names the session cwd.
cwd_call() {
  jq -cn --arg t "$1" --argjson i "$2" --arg d "$3" '{tool_name: $t, tool_input: $i, cwd: $d}'
}

# codex_call <cmd-json-array> <workdir>: a Codex exec_command call.
codex_call() {
  jq -cn --argjson c "$1" --arg d "$2" '{tool_name: "exec_command", tool_input: {cmd: $c, workdir: $d}}'
}

COORD=coordinator-guard.sh
WORKER=worker-guard.sh
REVIEWER=reviewer-guard.sh
COORD_ENV=(PLAYBOOK_COORDINATOR_REGISTRY="$tmp/coordinators.json" T3CODE_THREAD_ID=coord-1)
WORKER_ENV=(PLAYBOOK_WORKER_WORKTREE="$wt")
WORKER_MAIN_ENV=(PLAYBOOK_WORKER_WORKTREE="$wt_main")
REVIEW_ENV=(PLAYBOOK_REVIEW_REGISTRY="$tmp/reviewers.json" T3CODE_THREAD_ID=rev-1)

# ── Syntax ─────────────────────────────────────────────────────────────
for script in guard-lib.sh "$COORD" "$WORKER" "$REVIEWER" playbook-registry.sh tests/test-hooks.sh; do
  if bash -n "$hooks/$script" 2>"$tmp/syntax"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL syntax: $script -- $(cat "$tmp/syntax")"
  fi
done

# ── Coordinator ────────────────────────────────────────────────────────
# Passthrough: inactive for unlisted, unset and unregistered sessions.
expect_allow "coord: unlisted thread edits pass through" "$COORD" \
  "$(tool_call Edit '{"file_path":"/x"}')" PLAYBOOK_COORDINATOR_REGISTRY="$tmp/coordinators.json" T3CODE_THREAD_ID=someone-else
expect_allow "coord: unset thread id passes through" "$COORD" \
  "$(tool_call Edit '{"file_path":"/x"}')" PLAYBOOK_COORDINATOR_REGISTRY="$tmp/coordinators.json"
expect_allow "coord: missing registry passes through" "$COORD" \
  "$(tool_call Edit '{"file_path":"/x"}')" PLAYBOOK_COORDINATOR_REGISTRY="$tmp/absent.json" T3CODE_THREAD_ID=coord-1

# File edits are blocked for a registered coordinator.
for t in Edit Write MultiEdit NotebookEdit; do
  expect_deny "coord: $t is blocked" "$COORD" "$(tool_call "$t" '{"file_path":"/repo/a"}')" "${COORD_ENV[@]}"
done
expect_deny "coord: apply_patch is blocked" "$COORD" \
  "$(patch_call '*** Begin Patch
*** Update File: a.rs
*** End Patch')" "${COORD_ENV[@]}"
expect_allow "coord: Read is allowed" "$COORD" "$(tool_call Read '{"file_path":"/repo/a"}')" "${COORD_ENV[@]}"

# Read-only shell and gh are allowed.
for c in 'ls -la' 'git status --short' 'git log --oneline -n 3' 'git diff HEAD~1' 'git worktree list' \
  'git branch --list' 'rg TODO' 'gh pr view 12' 'gh pr list --state open' \
  'gh issue create --title t --body b' 'gh issue comment 3 --body x' 'gh api repos/o/r/pulls' \
  'gh api -X GET repos/o/r' 'echo "cargo test"' 'publish-broker status' \
  'sudo -n -u publisher publish-broker --dry-run' 'cd /tmp && ls'; do
  expect_allow "coord: read-only allowed: $c" "$COORD" "$(bash_call "$c")" "${COORD_ENV[@]}"
done

# Builds, writes, mutating git and gh, and non-GET gh api are denied.
for c in 'cargo test' 'pnpm install' 'npm run build' 'git commit -m x' 'git push origin x' \
  'git checkout -b foo' 'git reset --hard' 'git stash' 'gh pr merge 1' 'gh pr close 1' \
  'gh api -X POST repos/o/r/issues' 'gh api -XPATCH repos/o/r' 'gh api repos/o/r -f title=x' \
  'gh api repos/o/r -F x=1' 'gh api --input body.json repos/x' 'gh api --method DELETE repos/x' \
  'echo hi > out.txt' 'echo $(whoami)' 'FOO=1 ls' '/usr/bin/git status' 'sudo rm -rf /' \
  'git -c core.hooksPath=/x status' 'ls ; cargo build' 'cat x | sh'; do
  expect_deny "coord: denied: $c" "$COORD" "$(bash_call "$c")" "${COORD_ENV[@]}"
done

# Draining: new dispatches are frozen except the handoff successor.
drain_env=(PLAYBOOK_COORDINATOR_REGISTRY="$tmp/coordinators.json" T3CODE_THREAD_ID=coord-drain)
expect_deny "coord: draining blocks delegate_task" "$COORD" \
  "$(tool_call mcp__t3-code__delegate_task '{"prompt":"fix it"}')" "${drain_env[@]}"
expect_deny "coord: draining blocks Agent" "$COORD" "$(tool_call Agent '{"prompt":"x"}')" "${drain_env[@]}"
expect_deny "coord: draining blocks a launch without the marker" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_launch '{"prompt":"new work"}')" "${drain_env[@]}"
expect_allow "coord: draining allows the marked handoff launch" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_launch '{"prompt":"successor HANDOFF-42"}')" "${drain_env[@]}"
expect_allow "coord: draining still allows read-only Bash" "$COORD" "$(bash_call 'ls')" "${drain_env[@]}"
expect_allow "coord: live coordinator may dispatch" "$COORD" \
  "$(tool_call mcp__t3-code__delegate_task '{"prompt":"fix it"}')" "${COORD_ENV[@]}"

# ── Worker ─────────────────────────────────────────────────────────────
expect_allow "worker: unset worktree passes through" "$WORKER" \
  "$(tool_call Edit "{\"file_path\":\"$out/x\"}")"

# Edit tools: inside the worktree only, symlinks resolved.
expect_allow "worker: Edit inside worktree" "$WORKER" "$(tool_call Edit "{\"file_path\":\"$wt/src/a.rs\"}")" "${WORKER_ENV[@]}"
expect_allow "worker: Write with a relative path" "$WORKER" "$(tool_call Write '{"file_path":"src/b.rs"}')" "${WORKER_ENV[@]}"
expect_allow "worker: NotebookEdit inside worktree" "$WORKER" \
  "$(tool_call NotebookEdit "{\"notebook_path\":\"$wt/n.ipynb\"}")" "${WORKER_ENV[@]}"
expect_deny "worker: Edit outside worktree" "$WORKER" "$(tool_call Edit "{\"file_path\":\"$out/x\"}")" "${WORKER_ENV[@]}"
expect_deny "worker: Edit via dot-dot escape" "$WORKER" \
  "$(tool_call Edit "{\"file_path\":\"$wt/../outside/x\"}")" "${WORKER_ENV[@]}"
expect_deny "worker: Edit via symlink escape" "$WORKER" \
  "$(tool_call Write "{\"file_path\":\"$wt/escape/x\"}")" "${WORKER_ENV[@]}"
expect_deny "worker: MultiEdit outside worktree" "$WORKER" \
  "$(tool_call MultiEdit "{\"file_path\":\"/etc/hosts\"}")" "${WORKER_ENV[@]}"
expect_deny "worker: Edit without a path" "$WORKER" "$(tool_call Edit '{}')" "${WORKER_ENV[@]}"
expect_allow "worker: apply_patch inside worktree" "$WORKER" \
  "$(patch_call '*** Begin Patch
*** Update File: src/a.rs
*** End Patch')" "${WORKER_ENV[@]}"
expect_deny "worker: apply_patch adding outside file" "$WORKER" \
  "$(patch_call "*** Begin Patch
*** Add File: $out/x
*** End Patch")" "${WORKER_ENV[@]}"
expect_deny "worker: apply_patch with a move out" "$WORKER" \
  "$(patch_call '*** Begin Patch
*** Update File: src/a.rs
*** Move to: ../../x
*** End Patch')" "${WORKER_ENV[@]}"

# Reads and unrelated tools are not restricted.
expect_allow "worker: Read outside worktree" "$WORKER" "$(tool_call Read '{"file_path":"/etc/hostname"}')" "${WORKER_ENV[@]}"
expect_allow "worker: unrelated tool passes" "$WORKER" "$(tool_call WebFetch '{"url":"https://example.org"}')" "${WORKER_ENV[@]}"

# Git: mutations name the worktree; pushes never reach a protected branch.
expect_allow "worker: read-only git anywhere" "$WORKER" \
  "$(bash_call "git -C $out status")" "${WORKER_ENV[@]}"
expect_allow "worker: git status in worktree" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE status --short')" "${WORKER_ENV[@]}"
expect_allow "worker: git commit naming the worktree" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE commit -m x')" "${WORKER_ENV[@]}"
expect_allow "worker: braced variable names the worktree" "$WORKER" \
  "$(bash_call 'git -C ${PLAYBOOK_WORKER_WORKTREE}/src status')" "${WORKER_ENV[@]}"
expect_deny "worker: mutating git without -C" "$WORKER" "$(bash_call 'git commit -m x')" "${WORKER_ENV[@]}"
expect_deny "worker: mutating git on an outside directory" "$WORKER" \
  "$(bash_call "git -C $out commit -m x")" "${WORKER_ENV[@]}"
expect_deny "worker: second -C outside the worktree" "$WORKER" \
  "$(bash_call "git -C \$PLAYBOOK_WORKER_WORKTREE -C $out commit -m x")" "${WORKER_ENV[@]}"
expect_allow "worker: push of the feature branch" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE push origin feature/x')" "${WORKER_ENV[@]}"
expect_allow "worker: plain push from a feature branch" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE push')" "${WORKER_ENV[@]}"
for c in 'git -C $PLAYBOOK_WORKER_WORKTREE push origin main' \
  'git -C $PLAYBOOK_WORKER_WORKTREE push origin HEAD:main' \
  'git -C $PLAYBOOK_WORKER_WORKTREE push origin +refs/heads/develop' \
  'git -C $PLAYBOOK_WORKER_WORKTREE push origin origin/main' \
  'git -C $PLAYBOOK_WORKER_WORKTREE push --force-with-lease=main:abc origin feature/x' \
  'git -C $PLAYBOOK_WORKER_WORKTREE push --all origin' \
  'git -C $PLAYBOOK_WORKER_WORKTREE push --mirror origin'; do
  expect_deny "worker: push to protected branch: $c" "$WORKER" "$(bash_call "$c")" "${WORKER_ENV[@]}"
done
expect_allow "worker: HEAD names the feature branch of this worktree" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE push origin HEAD')" "${WORKER_ENV[@]}"
expect_deny "worker: plain push while the worktree is on main" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE push')" "${WORKER_MAIN_ENV[@]}"
expect_deny "worker: push from main with a named remote only" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE push origin')" "${WORKER_MAIN_ENV[@]}"
expect_deny "worker: HEAD while the worktree is on main" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE push origin HEAD')" "${WORKER_MAIN_ENV[@]}"

# Shell writes: only inside the worktree.
for c in 'rm -rf target' 'rm -rf $PLAYBOOK_WORKER_WORKTREE/target' 'touch $PLAYBOOK_WORKER_WORKTREE/new' \
  'tee -a log.txt' 'sed -i s/a/b/ src/main.rs' 'sed s/a/b/ '"$out"'/x' 'cargo test 2>&1 | tail -5' \
  'echo hi > /dev/null' 'echo "rm -rf /etc"' 'cd src' 'cd $PLAYBOOK_WORKER_WORKTREE && cargo test' \
  'FOO=1 cargo build'; do
  expect_allow "worker: allowed: $c" "$WORKER" "$(bash_call "$c")" "${WORKER_ENV[@]}"
done
for c in "rm -rf $out/secret.txt" 'rm -rf /etc/passwd' 'rm -rf ../x' 'rm -rf $HOME/x' \
  "mkdir -p $out/new" "cp src/a $out/b" "sed -i s/a/b/ $out/x" "sed -ni s/a/b/ $out/x" 'echo hi > notes.txt' \
  'echo $(whoami)' "cd $out && ls" 'cd' 'cat <<EOF' 'mv a ~/x' 'ln -s /etc/passwd link'; do
  expect_deny "worker: denied: $c" "$WORKER" "$(bash_call "$c")" "${WORKER_ENV[@]}"
done

# ── Reviewer ───────────────────────────────────────────────────────────
expect_allow "reviewer: unlisted thread passes through" "$REVIEWER" \
  "$(bash_call 'rm -rf /')" PLAYBOOK_REVIEW_REGISTRY="$tmp/reviewers.json" T3CODE_THREAD_ID=someone-else
expect_allow "reviewer: unset thread id passes through" "$REVIEWER" \
  "$(bash_call 'rm -rf /')" PLAYBOOK_REVIEW_REGISTRY="$tmp/reviewers.json"
expect_allow "reviewer: missing registry passes through" "$REVIEWER" \
  "$(bash_call 'rm -rf /')" PLAYBOOK_REVIEW_REGISTRY="$tmp/absent.json" T3CODE_THREAD_ID=rev-1

expect_allow "reviewer: Read of a snapshot file" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$snap/a.md\"}")" "${REVIEW_ENV[@]}"
expect_allow "reviewer: relative Read from a cwd inside the snapshot" "$REVIEWER" \
  "$(cwd_call Read '{"file_path":"sub/b.md"}' "$snap")" "${REVIEW_ENV[@]}"
expect_allow "reviewer: Grep inside snapshot" "$REVIEWER" \
  "$(tool_call Grep "{\"pattern\":\"x\",\"path\":\"$snap\"}")" "${REVIEW_ENV[@]}"
expect_allow "reviewer: Glob inside snapshot" "$REVIEWER" \
  "$(tool_call Glob "{\"pattern\":\"**/*.md\",\"path\":\"$snap\"}")" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Read outside snapshot" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$out/secret.txt\"}")" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Read with dot-dot" "$REVIEWER" \
  "$(tool_call Read '{"file_path":"../outside/secret.txt"}')" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Read with dot-dot after the root" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$snap/../outside/secret.txt\"}")" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Read through an escaping symlink" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$snap/leak/secret.txt\"}")" "${REVIEW_ENV[@]}"
expect_deny "reviewer: relative path through an escaping symlink" "$REVIEWER" \
  "$(cwd_call Read '{"file_path":"leak/secret.txt"}' "$snap")" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Read of the symlink itself" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$snap/leak\"}")" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Read without a path" "$REVIEWER" "$(tool_call Read '{}')" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Grep without a path" "$REVIEWER" \
  "$(tool_call Grep '{"pattern":"x"}')" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Grep outside snapshot" "$REVIEWER" \
  "$(tool_call Grep "{\"pattern\":\"x\",\"path\":\"$out\"}")" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Glob with an absolute pattern" "$REVIEWER" \
  "$(tool_call Glob "{\"pattern\":\"/etc/*\",\"path\":\"$snap\"}")" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Glob with dot-dot in the pattern" "$REVIEWER" \
  "$(tool_call Glob "{\"pattern\":\"../*\",\"path\":\"$snap\"}")" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Glob without a path" "$REVIEWER" \
  "$(tool_call Glob '{"pattern":"*.md"}')" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Glob outside snapshot" "$REVIEWER" \
  "$(tool_call Glob "{\"pattern\":\"*\",\"path\":\"$out\"}")" "${REVIEW_ENV[@]}"
for t in Bash Edit Write MultiEdit NotebookEdit WebFetch WebSearch Agent mcp__t3-code__t3_thread_read; do
  expect_deny "reviewer: $t is denied" "$REVIEWER" "$(tool_call "$t" '{"command":"ls","file_path":"'"$snap"'/a.md"}')" "${REVIEW_ENV[@]}"
done
expect_deny "reviewer: apply_patch is denied" "$REVIEWER" \
  "$(patch_call '*** Begin Patch
*** End Patch')" "${REVIEW_ENV[@]}"

# Registry shapes and broken entries.
expect_allow "reviewer: array-shaped registry is read" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$snap/a.md\"}")" PLAYBOOK_REVIEW_REGISTRY="$tmp/reviewers-array.json" T3CODE_THREAD_ID=rev-arr
expect_deny "reviewer: array-shaped registry still denies Bash" "$REVIEWER" \
  "$(bash_call 'ls')" PLAYBOOK_REVIEW_REGISTRY="$tmp/reviewers-array.json" T3CODE_THREAD_ID=rev-arr
expect_deny "reviewer: entry without snapshot_root refuses every tool" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$snap/a.md\"}")" PLAYBOOK_REVIEW_REGISTRY="$tmp/reviewers.json" T3CODE_THREAD_ID=rev-nosnap
expect_deny "reviewer: snapshot_root that does not exist refuses every tool" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$snap/a.md\"}")" PLAYBOOK_REVIEW_REGISTRY="$tmp/reviewers.json" T3CODE_THREAD_ID=rev-missing

# ── Council fixes ──────────────────────────────────────────────────────
# Thread identity: PLAYBOOK_THREAD_ID activates the guards outside T3 Code.
expect_deny "coord: PLAYBOOK_THREAD_ID activates the guard" "$COORD" \
  "$(tool_call Edit '{"file_path":"/x"}')" PLAYBOOK_COORDINATOR_REGISTRY="$tmp/coordinators.json" PLAYBOOK_THREAD_ID=coord-1
expect_deny "reviewer: PLAYBOOK_THREAD_ID activates the guard" "$REVIEWER" \
  "$(bash_call 'ls')" PLAYBOOK_REVIEW_REGISTRY="$tmp/reviewers.json" PLAYBOOK_THREAD_ID=rev-1
expect_allow "coord: PLAYBOOK_THREAD_ID wins over T3CODE_THREAD_ID" "$COORD" \
  "$(tool_call Edit '{"file_path":"/x"}')" PLAYBOOK_COORDINATOR_REGISTRY="$tmp/coordinators.json" \
  PLAYBOOK_THREAD_ID=someone-else T3CODE_THREAD_ID=coord-1

# Coordinator: forge merges, wait loops and program-running git options.
for t in mcp__t3-code__pull_request_merge mcp__github__merge_pull_request mcp__github__push_files \
  mcp__github__create_or_update_file mcp__github__update_pull_request_branch; do
  expect_deny "coord: forge tool $t is denied" "$COORD" "$(tool_call "$t" '{"number":1}')" "${COORD_ENV[@]}"
done
expect_allow "coord: forge read tools pass" "$COORD" \
  "$(tool_call mcp__t3-code__pull_request_read '{"number":1}')" "${COORD_ENV[@]}"
for c in 'gh pr checks 12 --watch' 'git ls-remote --upload-pack=touch origin' 'git ls-remote --exec=x origin' \
  'git diff --ext-diff'; do
  expect_deny "coord: denied: $c" "$COORD" "$(bash_call "$c")" "${COORD_ENV[@]}"
done
for c in 'gh pr checks 12' 'git branch --merged main' 'git branch --contains abc123' 'git branch -r --no-merged origin/main' \
  'git branch --points-at HEAD'; do
  expect_allow "coord: allowed: $c" "$COORD" "$(bash_call "$c")" "${COORD_ENV[@]}"
done
expect_deny "coord: git branch creating a branch" "$COORD" "$(bash_call 'git branch newbranch')" "${COORD_ENV[@]}"

# Coordinator: playbook-registry, and the drain flow end to end.
reg=$tmp/drain-registry.json
reviews_reg=$tmp/drain-reviews.json
regenv=(PLAYBOOK_COORDINATOR_REGISTRY="$reg" PLAYBOOK_REVIEW_REGISTRY="$reviews_reg")
check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>"$tmp/check-err"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $name -- $(cat "$tmp/check-err")"
  fi
}
registry() {
  env -i PATH="$PATH" HOME="$home" "${regenv[@]}" "$@"
}
check "registry: operator registers a coordinator" registry bash "$hooks/playbook-registry.sh" coordinator add shift-1
for c in 'playbook-registry.sh drain HANDOFF-7' "$hooks/playbook-registry.sh review add rev-9 $snap" \
  'playbook-registry.sh review remove rev-9' 'playbook-registry.sh coordinator add shift-2' \
  'playbook-registry.sh coordinator remove shift-0' 'playbook-registry.sh show coordinator'; do
  expect_allow "coord: registry command allowed: $c" "$COORD" "$(bash_call "$c")" "${regenv[@]}" T3CODE_THREAD_ID=shift-1
done
for c in 'playbook-registry.sh coordinator remove shift-1' 'playbook-registry.sh wipe' \
  "$hooks/playbook-registry.sh coordinator remove shift-1"; do
  expect_deny "coord: registry command denied: $c" "$COORD" "$(bash_call "$c")" "${regenv[@]}" T3CODE_THREAD_ID=shift-1
done
expect_allow "drain: a live coordinator may dispatch" "$COORD" \
  "$(tool_call mcp__t3-code__delegate_task '{"prompt":"x"}')" "${regenv[@]}" T3CODE_THREAD_ID=shift-1
check "drain: the coordinator drains itself" registry T3CODE_THREAD_ID=shift-1 bash "$hooks/playbook-registry.sh" drain HANDOFF-7
check "drain: the registry records the marker" jq -e '.["shift-1"] | .draining == true and .handoff_marker == "HANDOFF-7"' "$reg"
expect_deny "drain: a dispatch is now frozen" "$COORD" \
  "$(tool_call mcp__t3-code__delegate_task '{"prompt":"x"}')" "${regenv[@]}" T3CODE_THREAD_ID=shift-1
expect_deny "drain: a launch without the marker is frozen" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_launch '{"prompt":"new work"}')" "${regenv[@]}" T3CODE_THREAD_ID=shift-1
expect_allow "drain: the successor launch with the marker passes" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_launch '{"prompt":"take over, HANDOFF-7"}')" "${regenv[@]}" T3CODE_THREAD_ID=shift-1
check "drain: the successor registers itself" registry bash "$hooks/playbook-registry.sh" coordinator add shift-2
check "drain: the successor removes its predecessor" registry bash "$hooks/playbook-registry.sh" coordinator remove shift-1
check "drain: only the successor is left" jq -e 'keys == ["shift-2"]' "$reg"
if registry bash "$hooks/playbook-registry.sh" drain X >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL: registry: drain without a thread id must fail"
else
  pass=$((pass + 1))
fi
check "registry: a review entry stores the resolved snapshot" registry bash "$hooks/playbook-registry.sh" review add rev-9 "$snap"
check "registry: review entry content" jq -e --arg s "$snap" '.["rev-9"].snapshot_root == $s' "$reviews_reg"
expect_deny "registry: the registered reviewer is confined" "$REVIEWER" "$(bash_call 'ls')" "${regenv[@]}" T3CODE_THREAD_ID=rev-9

# Worker: the working directory of the call decides relative paths.
expect_deny "worker: Codex workdir outside the worktree" "$WORKER" \
  "$(codex_call '["bash","-lc","rm -rf x"]' "$out")" "${WORKER_ENV[@]}"
expect_allow "worker: Codex workdir inside the worktree" "$WORKER" \
  "$(codex_call '["bash","-lc","rm -rf target"]' "$wt")" "${WORKER_ENV[@]}"
expect_allow "worker: Codex array command without a shell" "$WORKER" \
  "$(codex_call '["rm","-rf","target"]' "$wt")" "${WORKER_ENV[@]}"
expect_deny "worker: Claude session cwd outside the worktree" "$WORKER" \
  "$(jq -cn --arg d "$out" '{tool_name: "Bash", tool_input: {command: "touch x"}, cwd: $d}')" "${WORKER_ENV[@]}"
expect_deny "worker: relative Write from a cwd outside the worktree" "$WORKER" \
  "$(cwd_call Write '{"file_path":"x"}' "$out")" "${WORKER_ENV[@]}"
expect_allow "worker: cd inside the worktree moves the base" "$WORKER" \
  "$(bash_call 'cd src && touch a.rs')" "${WORKER_ENV[@]}"

# Worker: sed scripts are not paths; only in-place targets are checked.
for c in "sed -i '/^#/d' src/main.rs" "sed --silent '/foo/p' $out/x" "sed -n '/foo/p' $out/x" \
  "sed -e 's/a/b/' -i src/main.rs" "sed -i.bak s/a/b/ src/main.rs" "sed -E -i 's/a+/b/' src/a.rs"; do
  expect_allow "worker: sed allowed: $c" "$WORKER" "$(bash_call "$c")" "${WORKER_ENV[@]}"
done
for c in "sed -i '/^#/d' $out/x" "sed -e 's/a/b/' -i $out/x" "sed --in-place s/a/b/ $out/x" "sed -Ei s/a/b/ $out/x"; do
  expect_deny "worker: sed denied: $c" "$WORKER" "$(bash_call "$c")" "${WORKER_ENV[@]}"
done

# Worker: wrappers, find and nested shells.
for c in "env rm -rf $out/x" "env FOO=1 rm $out/x" "command rm $out/x" "timeout 5 rm $out/x" "nice -n 5 rm $out/x" \
  "find $out -delete" "find $out -name x -exec rm {} ;" "find . -exec cp {} $out ;" "bash -c 'rm -rf $out'" \
  "sh -c true" "eval rm x" "xargs rm" "nohup mv a $out/b"; do
  expect_deny "worker: denied: $c" "$WORKER" "$(bash_call "$c")" "${WORKER_ENV[@]}"
done
for c in 'env FOO=1 cargo test' 'timeout 600 cargo test' 'find . -name "*.rs"' 'find src -name x -delete' \
  'find . -exec rm {} +' "find $out -name x" 'bash scripts/check.sh' 'xargs grep foo'; do
  expect_allow "worker: allowed: $c" "$WORKER" "$(bash_call "$c")" "${WORKER_ENV[@]}"
done

# Worker: push bound to its branch, configurable protected branches.
bound=(PLAYBOOK_WORKER_WORKTREE="$wt" PLAYBOOK_WORKER_BRANCH=feature/x)
for c in 'push origin feature/x' 'push origin HEAD:feature/x' 'push origin HEAD' \
  'push --force-with-lease=feature/x:abc origin feature/x'; do
  expect_allow "worker (bound): allowed: git $c" "$WORKER" "$(bash_call "git -C \$PLAYBOOK_WORKER_WORKTREE $c")" "${bound[@]}"
done
for c in 'push' 'push origin' 'push origin feat:trunk' 'push origin feature/x:v2/core' 'push origin feature/y' \
  'push origin feature/x other' 'push --force-with-lease=trunk:abc origin feature/x' 'push --tags origin'; do
  expect_deny "worker (bound): denied: git $c" "$WORKER" "$(bash_call "git -C \$PLAYBOOK_WORKER_WORKTREE $c")" "${bound[@]}"
done
expect_deny "worker: custom protected branch" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE push origin feat:trunk')" "${WORKER_ENV[@]}" PLAYBOOK_PROTECTED_BRANCHES="main trunk"
expect_allow "worker: feature push with custom protected branches" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE push origin feature/x')" "${WORKER_ENV[@]}" PLAYBOOK_PROTECTED_BRANCHES="main trunk"

# Reviewer: relative paths are bound to the tool cwd.
expect_deny "reviewer: relative Read without a cwd" "$REVIEWER" \
  "$(tool_call Read '{"file_path":"sub/b.md"}')" "${REVIEW_ENV[@]}"
expect_deny "reviewer: relative Grep from a cwd outside the snapshot" "$REVIEWER" \
  "$(cwd_call Grep '{"pattern":"x","path":"src"}' "$out")" "${REVIEW_ENV[@]}"
expect_deny "reviewer: Codex shell is denied" "$REVIEWER" \
  "$(codex_call '["bash","-lc","cat a.md"]' "$snap")" "${REVIEW_ENV[@]}"

# Review snapshots: exact, export attributes ignored, patch beside the tree, torn down.
src=$tmp/src
mkdir -p "$src"
git -C "$src" init -q -b main
git -C "$src" config user.name fixture
git -C "$src" config user.email fixture@example.invalid
git -C "$src" config commit.gpgsign false
git -C "$src" config core.hooksPath ''
echo one >"$src/a.txt"
git -C "$src" add -A
git -C "$src" commit -qm base
snap_base=$(git -C "$src" rev-parse HEAD)
printf 'hidden.txt export-ignore\n' >"$src/.gitattributes"
echo hidden >"$src/hidden.txt"
echo tracked >"$src/REVIEW.patch"
echo two >"$src/a.txt"
git -C "$src" add -A
git -C "$src" commit -qm head
snap_head=$(git -C "$src" rev-parse HEAD)
root=$(registry bash "$hooks/playbook-registry.sh" review snapshot rev-snap "$src" "$snap_base" "$snap_head" 2>"$tmp/check-err") || root=""
check "snapshot: built and registered" test -n "$root"
check "snapshot: export-ignore files are present" test -f "$root/tree/hidden.txt"
check "snapshot: a tracked REVIEW.patch keeps its content" grep -qx tracked "$root/tree/REVIEW.patch"
check "snapshot: the diff sits beside the tree" grep -q '^+two' "$root/REVIEW.patch"
check "snapshot: no .git inside" test ! -e "$root/tree/.git"
check "snapshot: read-only" test ! -w "$root/tree/a.txt"
check "snapshot: registry points at it" jq -e --arg r "$root" '.["rev-snap"].snapshot_root == $r' "$reviews_reg"
expect_allow "snapshot: the reviewer reads the tree" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$root/tree/a.txt\"}")" "${regenv[@]}" T3CODE_THREAD_ID=rev-snap
expect_allow "coord: may build a snapshot" "$COORD" \
  "$(bash_call "playbook-registry.sh review snapshot rev-x $src $snap_base $snap_head")" "${regenv[@]}" T3CODE_THREAD_ID=shift-2
if registry bash "$hooks/playbook-registry.sh" review snapshot rev-bad "$src" HEAD "$snap_head" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL: snapshot: a mutable ref must be refused"
else
  pass=$((pass + 1))
fi
check "snapshot: remove unregisters" registry bash "$hooks/playbook-registry.sh" review remove rev-snap
check "snapshot: remove deletes the snapshot" test ! -e "$root"
check "snapshot: the entry is gone" jq -e 'has("rev-snap") | not' "$reviews_reg"

# ── Coordinator lifecycle: renew, status, drain, candidate, takeover, abort ──
# as_thread <registry> <thread-id> <registry args...>: run the registry as a thread.
as_thread() {
  local reg=$1 thread=$2
  shift 2
  env -i PATH="$PATH" HOME="$home" PLAYBOOK_COORDINATOR_REGISTRY="$reg" \
    PLAYBOOK_REVIEW_REGISTRY="$reviews_reg" T3CODE_THREAD_ID="$thread" \
    bash "$hooks/playbook-registry.sh" "$@"
}

# refuses <name> <command...>: the command must fail.
refuses() {
  local name=$1
  shift
  if "$@" >/dev/null 2>"$tmp/refuse-err"; then
    fail=$((fail + 1))
    echo "FAIL: $name -- the command succeeded"
  else
    pass=$((pass + 1))
  fi
}

# open_stdin_guard <guard> [VAR=value ...]: run a guard whose stdin pipe never closes.
# RC 0 means it returned without reading stdin; 124 means timeout killed it.
open_stdin_guard() {
  local guard=$1 hold fifo=$tmp/stdin-$1.fifo rc=0
  shift
  rm -f -- "$fifo"
  mkfifo "$fifo"
  (exec sleep 30 >"$fifo") &
  hold=$!
  env -i PATH="$PATH" HOME="$home" "$@" timeout 2 bash "$hooks/$guard" <"$fifo" >/dev/null 2>&1 || rc=$?
  kill "$hold" 2>/dev/null
  wait "$hold" 2>/dev/null
  RC=$rc
}

# Renew, status, the drain escalation and abort on one coordinator.
ren=$tmp/renew.json
cat >"$ren" <<'JSON'
{
  "L-1": { "state": "active", "draining": false, "generation": 3,
           "started_at": "2020-01-01T00:00:00Z", "cancel_count": 2, "slice": "wave-9" }
}
JSON
as_thread "$ren" L-1 status >"$tmp/status-1"
check "status: prints the state" grep -qx 'state: active' "$tmp/status-1"
check "status: prints the cancel count" grep -qx 'cancel_count: 2' "$tmp/status-1"
check "status: prints the age" grep -q '^age_seconds: [0-9]' "$tmp/status-1"
check "status: an old shift is due for rotation" grep -qx 'ROTATE_DUE: age>=6h' "$tmp/status-1"
refuses "status: an unregistered thread is refused" as_thread "$ren" nobody status
as_thread "$ren" L-1 renew >"$tmp/packet" 2>&1
check "renew: prints a recovery packet for the thread" grep -qE 'thread: +L-1' "$tmp/packet"
check "renew: the recovery packet is at most 10 lines" test "$(wc -l <"$tmp/packet")" -le 10
check "renew: bumps the generation" jq -e '.["L-1"].generation == 4' "$ren"
check "renew: resets started_at" jq -e '.["L-1"].started_at != "2020-01-01T00:00:00Z"' "$ren"
check "renew: keeps cancel_count and slice" jq -e '.["L-1"].cancel_count == 2 and .["L-1"].slice == "wave-9"' "$ren"
check "renew: keeps the coordinator active" jq -e '.["L-1"].state == "active" and .["L-1"].draining == false' "$ren"
as_thread "$ren" L-1 status >"$tmp/status-2"
check "status: a fresh shift is not due for rotation" grep -qx 'ROTATE_DUE: no' "$tmp/status-2"
as_thread "$ren" L-1 drain M-ESC --cancelled >"$tmp/drain-esc" 2>&1
check "drain: prints the drain deadline" grep -q '^drain_deadline: ' "$tmp/drain-esc"
check "drain: escalates an owner whose shifts keep getting cancelled" grep -q '^ESCALATE_OWNER' "$tmp/drain-esc"
check "drain: counts the cancellation" jq -e '.["L-1"].cancel_count == 3' "$ren"
check "drain: records the marker and the draining state" jq -e '.["L-1"].handoff_marker == "M-ESC" and .["L-1"].state == "draining"' "$ren"
refuses "renew: refused while draining" as_thread "$ren" L-1 renew
as_thread "$ren" L-1 abort M-ESC >/dev/null 2>&1
check "abort: the escalated owner resumes as active" jq -e '.["L-1"].state == "active" and (.["L-1"] | has("handoff_marker") | not)' "$ren"
check "lock: no lock directory is left behind" test ! -e "$ren.lock"

# Full flow: drain -> bind-candidate -> candidate -> takeover -> retired.
flow=$tmp/flow.json
flow_p=(PLAYBOOK_COORDINATOR_REGISTRY="$flow" T3CODE_THREAD_ID=P)
flow_c=(PLAYBOOK_COORDINATOR_REGISTRY="$flow" T3CODE_THREAD_ID=C)
check "flow: the operator registers the predecessor P" as_thread "$flow" operator coordinator add P wave-f
check "flow: P drains under marker M-FLOW" as_thread "$flow" P drain M-FLOW
expect_deny "flow: draining P cannot message an unbound candidate" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_send '{"threadId":"C","prompt":"go"}')" "${flow_p[@]}"
expect_deny "flow: draining P cannot run a recurring schedule" "$COORD" \
  "$(tool_call mcp__t3-code__schedule_task '{"schedule":{"type":"cron","expr":"0 * * * *"},"prompt":"M-FLOW"}')" "${flow_p[@]}"
expect_deny "flow: draining P cannot run a one-shot schedule without the marker" "$COORD" \
  "$(tool_call mcp__t3-code__schedule_task '{"schedule":{"type":"once","at":"2030-01-01T00:00:00Z"},"prompt":"check"}')" "${flow_p[@]}"
expect_allow "flow: draining P may schedule a one-shot that carries the marker" "$COORD" \
  "$(tool_call mcp__t3-code__schedule_task '{"schedule":{"type":"once","at":"2030-01-01T00:00:00Z"},"prompt":"resume M-FLOW"}')" "${flow_p[@]}"
expect_deny "flow: draining P cannot run a scheduled task now" "$COORD" \
  "$(tool_call mcp__t3-code__run_scheduled_task_now '{"id":"t1"}')" "${flow_p[@]}"
expect_deny "flow: draining P cannot queue work" "$COORD" \
  "$(tool_call mcp__t3-code__t3_queue '{"prompt":"x"}')" "${flow_p[@]}"
expect_deny "flow: draining P cannot publish" "$COORD" \
  "$(bash_call 'publish-broker publish --branch feature/x')" "${flow_p[@]}"
expect_allow "flow: draining P may check broker status" "$COORD" \
  "$(bash_call 'publish-broker status')" "${flow_p[@]}"
expect_deny "flow: draining P cannot renew" "$COORD" "$(bash_call 'playbook-registry.sh renew')" "${flow_p[@]}"
expect_allow "flow: draining P may read its status" "$COORD" \
  "$(bash_call 'playbook-registry.sh status')" "${flow_p[@]}"
check "flow: P binds C as its candidate" as_thread "$flow" P bind-candidate C
expect_allow "flow: draining P may message the bound candidate" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_send '{"threadId":"C","prompt":"take over M-FLOW"}')" "${flow_p[@]}"
expect_deny "flow: draining P still cannot message anyone else" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_send '{"threadId":"X","prompt":"hi"}')" "${flow_p[@]}"
expect_deny "flow: candidate C cannot dispatch delegate_task" "$COORD" \
  "$(tool_call mcp__t3-code__delegate_task '{"prompt":"x"}')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot spawn an Agent" "$COORD" "$(tool_call Agent '{"prompt":"x"}')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot launch threads" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_launch '{"prompt":"HANDOFF"}')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot send messages" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_send '{"threadId":"P","prompt":"x"}')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot run a scheduled task now" "$COORD" \
  "$(tool_call mcp__t3-code__run_scheduled_task_now '{"id":"t1"}')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot queue work" "$COORD" "$(tool_call mcp__t3-code__t3_queue '{}')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot publish" "$COORD" "$(bash_call 'publish-broker publish x')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot drain" "$COORD" "$(bash_call 'playbook-registry.sh drain M-X')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot bind a candidate" "$COORD" \
  "$(bash_call 'playbook-registry.sh bind-candidate Z')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot abort" "$COORD" "$(bash_call 'playbook-registry.sh abort M-FLOW')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot renew" "$COORD" "$(bash_call 'playbook-registry.sh renew')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot add coordinators" "$COORD" \
  "$(bash_call 'playbook-registry.sh coordinator add Z')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot write review entries" "$COORD" \
  "$(bash_call 'playbook-registry.sh review add r /tmp')" "${flow_c[@]}"
expect_deny "flow: candidate C cannot write worker entries" "$COORD" \
  "$(bash_call 'playbook-registry.sh worker add w /tmp')" "${flow_c[@]}"
expect_allow "flow: candidate C may take over" "$COORD" \
  "$(bash_call 'playbook-registry.sh takeover P M-FLOW')" "${flow_c[@]}"
expect_allow "flow: candidate C may read the registry" "$COORD" \
  "$(bash_call 'playbook-registry.sh show coordinator')" "${flow_c[@]}"
expect_allow "flow: candidate C may read files" "$COORD" "$(tool_call Read '{"file_path":"/repo/a"}')" "${flow_c[@]}"
expect_allow "flow: candidate C may watch a PR" "$COORD" \
  "$(tool_call mcp__t3-code__watch_pull_request '{"number":1}')" "${flow_c[@]}"
expect_allow "flow: candidate C may read a thread" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_read '{"threadId":"P"}')" "${flow_c[@]}"
check "flow: C takes over from P atomically" as_thread "$flow" C takeover P M-FLOW
check "flow: C is active at generation 2 with P as predecessor" \
  jq -e '.C.state == "active" and .C.generation == 2 and .C.predecessor == "P"' "$flow"
check "flow: P is retired and names C as successor" \
  jq -e '.P.state == "retired" and .P.draining == true and .P.successor == "C"' "$flow"
check "flow: replaying the takeover succeeds" as_thread "$flow" C takeover P M-FLOW
check "flow: the replay keeps the generation" jq -e '.C.generation == 2' "$flow"
refuses "flow: the retired P cannot abort after takeover" as_thread "$flow" P abort M-FLOW
expect_deny "flow: retired P cannot dispatch" "$COORD" \
  "$(tool_call mcp__t3-code__delegate_task '{"prompt":"x"}')" "${flow_p[@]}"
expect_deny "flow: retired P cannot send messages" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_send '{"threadId":"C","prompt":"x"}')" "${flow_p[@]}"
expect_deny "flow: retired P cannot organize threads" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_organize '{"threadId":"C"}')" "${flow_p[@]}"
expect_deny "flow: retired P cannot launch threads" "$COORD" \
  "$(tool_call mcp__t3-code__t3_thread_launch '{"prompt":"M-FLOW"}')" "${flow_p[@]}"
expect_deny "flow: retired P cannot schedule" "$COORD" \
  "$(tool_call mcp__t3-code__schedule_task '{"schedule":{"type":"once"},"prompt":"M-FLOW"}')" "${flow_p[@]}"
expect_deny "flow: retired P cannot publish" "$COORD" "$(bash_call 'publish-broker publish x')" "${flow_p[@]}"
expect_deny "flow: retired P cannot run ordinary shell" "$COORD" "$(bash_call 'ls')" "${flow_p[@]}"
expect_deny "flow: retired P cannot drain again" "$COORD" \
  "$(bash_call 'playbook-registry.sh drain M-X')" "${flow_p[@]}"
expect_deny "flow: retired P cannot take over again" "$COORD" \
  "$(bash_call 'playbook-registry.sh takeover C M-FLOW')" "${flow_p[@]}"
expect_allow "flow: retired P may unwatch a PR" "$COORD" \
  "$(tool_call mcp__t3-code__unwatch_pull_request '{"number":1}')" "${flow_p[@]}"
expect_allow "flow: retired P may delete a scheduled task" "$COORD" \
  "$(tool_call mcp__t3-code__delete_scheduled_task '{"id":"t1"}')" "${flow_p[@]}"
expect_allow "flow: retired P may read its status" "$COORD" \
  "$(bash_call 'playbook-registry.sh status P')" "${flow_p[@]}"
expect_allow "flow: retired P may show the registry" "$COORD" \
  "$(bash_call 'playbook-registry.sh show coordinator')" "${flow_p[@]}"
expect_allow "flow: the new active C may dispatch" "$COORD" \
  "$(tool_call mcp__t3-code__delegate_task '{"prompt":"x"}')" "${flow_c[@]}"
expect_deny "flow: active C cannot remove the retired P" "$COORD" \
  "$(bash_call 'playbook-registry.sh coordinator remove P')" "${flow_c[@]}"
expect_allow "flow: active C may remove an entry that is not retired" "$COORD" \
  "$(bash_call 'playbook-registry.sh coordinator remove Z')" "${flow_c[@]}"
check "lock: no lock directory is left after the flow" test ! -e "$flow.lock"

# Abort: the draining coordinator resumes, the candidate is retired and kept.
ab=$tmp/abort.json
check "abort: the operator registers Q" as_thread "$ab" operator coordinator add Q wave-q
check "abort: Q drains under M-AB" as_thread "$ab" Q drain M-AB
expect_allow "draining: coordinator may record --cancelled while draining" "$COORD" \
  "$(bash_call 'playbook-registry.sh drain M-AB --cancelled')" PLAYBOOK_COORDINATOR_REGISTRY="$ab" T3CODE_THREAD_ID=Q
check "abort: Q binds R as candidate" as_thread "$ab" Q bind-candidate R
refuses "abort: a wrong marker is refused" as_thread "$ab" Q abort M-WRONG
check "abort: the right marker restores Q" as_thread "$ab" Q abort M-AB
check "abort: Q is active with no marker or candidate left" \
  jq -e '.Q.state == "active" and .Q.draining == false and (.Q | has("handoff_marker") | not) and (.Q | has("candidate") | not)' "$ab"
check "abort: the bound candidate is retired, not deleted" jq -e '.R.state == "retired" and .R.draining == true' "$ab"
refuses "abort: the retired candidate cannot take over" as_thread "$ab" R takeover Q M-AB
expect_allow "abort: Q dispatches again" "$COORD" "$(tool_call mcp__t3-code__delegate_task '{"prompt":"x"}')" \
  PLAYBOOK_COORDINATOR_REGISTRY="$ab" T3CODE_THREAD_ID=Q
expect_deny "abort: the retired candidate R is inert" "$COORD" \
  "$(tool_call mcp__t3-code__delegate_task '{"prompt":"x"}')" PLAYBOOK_COORDINATOR_REGISTRY="$ab" T3CODE_THREAD_ID=R

# One owner per slice: a takeover is refused while another coordinator owns the slice.
sl=$tmp/slice.json
as_thread "$sl" operator coordinator add S-live wave-s
as_thread "$sl" operator coordinator add S-old wave-s
as_thread "$sl" S-old drain M-SL
as_thread "$sl" S-old bind-candidate S-new
refuses "takeover: refused while another coordinator owns the slice" as_thread "$sl" S-new takeover S-old M-SL
check "takeover: the refused candidate stays a candidate" jq -e '.["S-new"].state == "candidate"' "$sl"

# ── Worker registry, bound pushes and the inactive guards ─────────────
wreg=$tmp/workers.json
check "worker: add records the realpath and branch" \
  env -i PATH="$PATH" HOME="$home" PLAYBOOK_WORKER_REGISTRY="$wreg" \
  bash "$hooks/playbook-registry.sh" worker add w-1 "$wt" feature/x
check "worker: the entry holds the worktree and branch" \
  jq -e --arg wt "$(realpath "$wt")" '.["w-1"].worktree == $wt and .["w-1"].branch == "feature/x"' "$wreg"
wreg_env=(PLAYBOOK_WORKER_REGISTRY="$wreg" T3CODE_THREAD_ID=w-1)
expect_allow "worker (registry): edit inside the registered worktree" "$WORKER" \
  "$(tool_call Edit "{\"file_path\":\"$wt/src/a.rs\"}")" "${wreg_env[@]}"
expect_deny "worker (registry): edit outside the registered worktree" "$WORKER" \
  "$(tool_call Edit "{\"file_path\":\"$out/x\"}")" "${wreg_env[@]}"
expect_deny "worker (registry): the entry branch cannot push main" "$WORKER" \
  "$(bash_call "git -C $wt push origin main")" "${wreg_env[@]}"
expect_allow "worker (registry): the entry branch can be pushed" "$WORKER" \
  "$(bash_call "git -C $wt push origin feature/x")" "${wreg_env[@]}"
expect_deny "worker: the environment worktree wins over the registry entry" "$WORKER" \
  "$(tool_call Edit "{\"file_path\":\"$wt/src/a.rs\"}")" "${wreg_env[@]}" PLAYBOOK_WORKER_WORKTREE="$wt_main"
expect_deny "worker (bound main): pushing main is refused" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE push origin main')" \
  PLAYBOOK_WORKER_WORKTREE="$wt_main" PLAYBOOK_WORKER_BRANCH=main
expect_deny "worker (bound main): HEAD on main is refused" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE push origin HEAD')" \
  PLAYBOOK_WORKER_WORKTREE="$wt_main" PLAYBOOK_WORKER_BRANCH=main
expect_deny "worker (bound feature): a protected branch is refused even when it is the bound one" "$WORKER" \
  "$(bash_call 'git -C $PLAYBOOK_WORKER_WORKTREE push origin feature/x')" \
  PLAYBOOK_WORKER_WORKTREE="$wt" PLAYBOOK_WORKER_BRANCH=feature/x PLAYBOOK_PROTECTED_BRANCHES="feature/x main"
open_stdin_guard "$WORKER" PLAYBOOK_WORKER_REGISTRY="$wreg" T3CODE_THREAD_ID=unlisted
if [ "$RC" -eq 0 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: worker: an inactive guard must exit before reading stdin (rc $RC)"
fi
open_stdin_guard "$COORD" PLAYBOOK_COORDINATOR_REGISTRY="$tmp/coordinators.json" T3CODE_THREAD_ID=someone-else
if [ "$RC" -eq 0 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: coord: an unlisted thread must exit before reading stdin (rc $RC)"
fi

# ── Review snapshots: base/, removal and cleanup ───────────────────────
root_b=$(registry bash "$hooks/playbook-registry.sh" review snapshot --with-base rev-base "$src" "$snap_base" "$snap_head" 2>"$tmp/check-err") || root_b=""
check "snapshot --with-base: built and registered" test -n "$root_b"
check "snapshot --with-base: tree/ holds the head commit" grep -qx two "$root_b/tree/a.txt"
check "snapshot --with-base: base/ holds the base commit" grep -qx one "$root_b/base/a.txt"
check "snapshot --with-base: the registry names the one root" \
  jq -e --arg r "$root_b" '.["rev-base"].snapshot_root == $r and (.["rev-base"].package_id | length > 0)' "$reviews_reg"
expect_allow "reviewer: reads tree/ under the same root" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$root_b/tree/a.txt\"}")" "${regenv[@]}" T3CODE_THREAD_ID=rev-base
expect_allow "reviewer: reads base/ under the same root" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$root_b/base/a.txt\"}")" "${regenv[@]}" T3CODE_THREAD_ID=rev-base
expect_deny "reviewer: base/ does not widen the root" "$REVIEWER" \
  "$(tool_call Read "{\"file_path\":\"$root_b/../outside/x\"}")" "${regenv[@]}" T3CODE_THREAD_ID=rev-base

git clone -q --bare "$src" "$tmp/remote.git"
root_f=$(registry bash "$hooks/playbook-registry.sh" review snapshot --fetch "$tmp/remote.git" main rev-fetch "$src" "$snap_base" "$snap_head" 2>"$tmp/check-err") || root_f=""
check "snapshot --fetch: fetches the ref, then builds the snapshot" test -f "$root_f/tree/a.txt"
check "review remove: unregisters the --fetch snapshot" registry bash "$hooks/playbook-registry.sh" review remove rev-fetch
check "review remove: deletes the --fetch snapshot files" test ! -e "$root_f"

mkdir -p "$tmp/keep"
check "review add: a plain directory is registered" registry bash "$hooks/playbook-registry.sh" review add rev-keep "$tmp/keep"
check "review remove: a plain directory is left alone" registry bash "$hooks/playbook-registry.sh" review remove rev-keep
check "review remove: the plain directory still exists" test -d "$tmp/keep"

mkdir -p "$tmp/mismatch"
echo 'package_id=someone-else' >"$tmp/mismatch/.playbook-snapshot"
jq --arg r "$tmp/mismatch" '. + {"rev-mm": {snapshot_root: $r, package_id: "expected"}}' "$reviews_reg" >"$tmp/rv.json" \
  && mv -f -- "$tmp/rv.json" "$reviews_reg"
check "review remove: a snapshot with another package id is left alone" \
  registry bash "$hooks/playbook-registry.sh" review remove rev-mm
check "review remove: the mismatched snapshot still exists" test -f "$tmp/mismatch/.playbook-snapshot"

check "review remove: unregisters the --with-base snapshot" registry bash "$hooks/playbook-registry.sh" review remove rev-base
check "review remove: deletes the --with-base snapshot" test ! -e "$root_b"

gl=$tmp/gitlink-src
mkdir -p "$gl"
git -C "$gl" init -q -b main
git -C "$gl" config user.name fixture
git -C "$gl" config user.email fixture@example.invalid
git -C "$gl" config commit.gpgsign false
echo one >"$gl/a.txt"
git -C "$gl" add -A
git -C "$gl" commit -qm base
gl_base=$(git -C "$gl" rev-parse HEAD)
git -C "$gl" update-index --add --cacheinfo "160000,$(printf 'a%.0s' {1..40}),vendor"
git -C "$gl" commit -qm 'add submodule'
gl_head=$(git -C "$gl" rev-parse HEAD)
mkdir -p "$tmp/snaptmp"
refuses "snapshot: a submodule is refused" registry TMPDIR="$tmp/snaptmp" bash "$hooks/playbook-registry.sh" \
  review snapshot rev-gl "$gl" "$gl_base" "$gl_head"
check "snapshot: the refusal names the submodule" grep -q submodule "$tmp/refuse-err"
check "snapshot: a refused snapshot leaves nothing behind" test -z "$(ls -A "$tmp/snaptmp")"
check "snapshot: a refused snapshot is not registered" jq -e 'has("rev-gl") | not' "$reviews_reg"

# ── Summary ────────────────────────────────────────────────────────────
echo "test-hooks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
