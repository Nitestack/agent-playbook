---
name: browser-verify
description: Verify a UI change in a real browser against the exact candidate build before claiming it done, checking routes, console errors, network failures, focus and empty states. Use when a task changes web UI, layout, routing or client-side API behavior.
---

# Browser Verification Protocol

Use this whenever a task changes web UI, layout, routing or client-side API behavior. Unit tests and `curl` do not prove that a page works.

## Checklist
1. **Serve the exact candidate build.** Use a freshly built bundle or the live dev server of the current worktree. Never a stale build or a cached artifact.
2. **Drive a real browser.** Use the browser tooling the session provides (T3 Code's `preview_*` tools let the user watch the run). Do not rely on `curl` or unit tests alone.
3. **Check every changed route and interaction:**
   - Snapshot or screenshot the page, and inspect layout, contrast, overflow and responsive behavior.
   - Check keyboard focus and every interactive control: buttons, forms, dialogs and links.
   - Expect zero `console.error` entries, zero uncaught page errors, and zero unexpected HTTP 4xx or 5xx responses on happy paths.
   - Exercise at least one error or empty state where the change makes one reachable.
4. **Clean up.** Stop any temporary server and close any preview tab you opened.
5. **Report.** List the exact URLs and routes checked, what was observed, and any failures with their output.
