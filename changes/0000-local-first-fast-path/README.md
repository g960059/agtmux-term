# Local-First Fast Path

- **Issue:** not yet created; `0000-` is a migration placeholder for in-progress work
- **Status:** Ready for Merge
- **Related PRs:** add active PR links here
- **Related ADRs / research:** `docs/decisions/ADR-0003-tmux-first-cockpit.md`, `docs/research/2026-03-14-local-parity-baseline.md`, `docs/research/2026-03-17-gate-l-closeout.md`

This change pack carries the active local-first closeout and Gate-L parity work
after the default-branch task/progress/review ledgers were retired.

Gate-L is now green on the current host after the latest local hot-path
reductions landed on head. Broad SwiftPM verification is green when the
unrelated live managed-agent harness suite is excluded, and focused local
steady state no longer shows `FetchAll` / `TmuxRunner` dominance in a 10s
local-only signpost window.

AX-targeted terminal focus is now wired for the embedded Ghostty host. The perf
harness aligns attach-session with the UITest tmux config path, captures true
key-mode pane switching again, and now includes same-host keypress benches for
both embedded `agtmux-term` and native Ghostty. The root cause for pane-switch
key-mode was the embedded Ghostty bridge replaying `keyDown`-accumulated text
through `ghostty_surface_text`, which libghostty treats like paste instead of
key input; replay now goes back through `ghostty_surface_key(..., text: ...)`.
On the current host, the 10-iteration same-host key pane-switch sample is
green: embedded p95 `324.578ms` versus native Ghostty p95 `608.910ms`.

Same-host keypress proof is now green after moving the bench to a point-based
focus fast path and fixing the raw-tty driver to emit `\r\n` so marker matching
does not break on wrapped captures. On the current host, the 10-iteration
sample lands at embedded p95 `415.557ms` versus native Ghostty p95 `422.673ms`
(`0.983x`).

Same-host scroll proof is now green via a wheel-driven `less -N` proxy that is
observable through `tmux capture-pane`. On the current host, the 10-iteration
sample lands at embedded p95 `485.808ms` versus native Ghostty p95 `482.161ms`
(`1.008x`). The proxy is used because this environment cannot provide
display/window image capture for true terminal-local scrollback observation.

Durable runbook and research notes have now been updated. The remaining work
for this pack is to merge the local-first closeout and retire
`changes/0000-local-first-fast-path/` in that final merge.
