---
name: safe-cleanup
description: Inventory and remove stale worktrees, merged branches and build caches, sized and confirmed first, never touching unmerged, dirty or live work. Use when disk space is low, worktrees pile up, or PRs have merged and their branches need removing.
---

# Safe Cleanup Protocol

## Rules
1. **Confirm first for bulk or ambiguous cleanup.** Measure sizes (`du -sh`), sort largest first, show each item's merge status and last-modified time, and get confirmation before deleting anything.
2. **Delete only what is provably done.** A branch or worktree may go only when all three hold:
   - it is merged: `git merge-base --is-ancestor <sha> origin/<default>`,
   - its working tree is clean: `git -C <path> status --porcelain` prints nothing,
   - no live process runs inside it.
   Remove worktrees with `git worktree remove <path>`. Never add `--force`.
3. **Protect live state.** Never touch production data directories, uncommitted user files, or staged index entries that belong to unrelated work.
4. **No wildcards.** Never `rm -rf` a glob such as `/tmp/<prefix>*`, which could hit a concurrent run. Target exact paths you have verified.
5. **Report.** List what was removed, what was kept and why, and the space recovered.
