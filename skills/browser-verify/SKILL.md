---
name: browser-verify
description: Verify a UI change in a real browser against the exact candidate build before claiming it done, checking routes, console errors, network failures, focus and empty states. Use when a task changes web UI, layout, routing or client-side API behavior.
---

# Browser Verification Protocol

Use this whenever a task changes web UI, layout, routing or client-side API behavior. Unit tests and `curl` do not prove that a page works.

## Checklist
1. **Serve the exact candidate build.** Use a freshly built bundle or the live dev server of the current worktree. Never a stale build or a cached artifact.
2. **Drive a real browser.** Use the browser tooling the session provides, ideally in a way the user can watch; see `README.md` for host mappings. Do not rely on `curl` or unit tests alone.
3. **Check every changed route and interaction:**
   - Snapshot or screenshot the page, and inspect layout, contrast, overflow and responsive behavior.
   - Check keyboard focus and every interactive control: buttons, forms, dialogs and links.
   - Expect zero `console.error` entries, zero uncaught page errors, and zero unexpected HTTP 4xx or 5xx responses on happy paths.
   - Exercise at least one error or empty state where the change makes one reachable.
4. **Clean up.** Stop any temporary server and close any preview tab you opened.
5. **Report.** List the exact URLs and routes checked, what was observed, and any failures with their output. Record the **verified candidate SHA or build identity**. For uncommitted work, record the pre-commit worktree state instead: the base SHA plus a hash of the diff. Bind the record to the final candidate; any later change needs a new run.
