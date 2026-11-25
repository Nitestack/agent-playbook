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

COORD=coordinator-guard.sh
WORKER=worker-guard.sh
REVIEWER=reviewer-guard.sh
COORD_ENV=(PLAYBOOK_COORDINATOR_REGISTRY="$tmp/coordinators.json" T3CODE_THREAD_ID=coord-1)
WORKER_ENV=(PLAYBOOK_WORKER_WORKTREE="$wt")
WORKER_MAIN_ENV=(PLAYBOOK_WORKER_WORKTREE="$wt_main")
REVIEW_ENV=(PLAYBOOK_REVIEW_REGISTRY="$tmp/reviewers.json" T3CODE_THREAD_ID=rev-1)

# ── Syntax ─────────────────────────────────────────────────────────────
for script in guard-lib.sh "$COORD" "$WORKER" "$REVIEWER" tests/test-hooks.sh; do
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
expect_allow "reviewer: Read with a relative path" "$REVIEWER" \
  "$(tool_call Read '{"file_path":"sub/b.md"}')" "${REVIEW_ENV[@]}"
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
  "$(tool_call Read '{"file_path":"leak/secret.txt"}')" "${REVIEW_ENV[@]}"
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

# ── Summary ────────────────────────────────────────────────────────────
echo "test-hooks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
