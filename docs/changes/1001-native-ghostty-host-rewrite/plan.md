# Plan

1. Retire stale change packs and invalid scroll gates, and keep only the
   current durable findings plus realistic live-pane perf tooling.
2. Phase 1: introduce an explicit terminal host-mode boundary so the legacy
   host and next host can coexist in the same app.
3. Phase 1: create the next-host surface ownership layer with persistent pane
   surfaces and a dedicated AppKit controller boundary.
4. Phase 2: prove the next-host boundary on the deterministic loaded-TUI gate,
   then stabilize repeatable `legacy` vs `next` parity there before widening
   the acceptance surface.
5. Phase 3: route next-host history scroll through Ghostty-owned cadence and
   delete host scroll-pump behavior from that path on the loaded live-pane
   acceptance gate.
6. Phase 4: compare next host against native Ghostty on live-pane gates and
   cut over only after it wins on the relevant path.
