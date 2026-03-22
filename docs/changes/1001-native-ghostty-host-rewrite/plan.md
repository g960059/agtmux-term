# Plan

1. Retire stale change packs and invalid scroll gates, and keep only the
   current durable findings plus realistic live-pane perf tooling.
2. Phase 1: introduce an explicit terminal host-mode boundary so the legacy
   host and next host can coexist in the same app.
3. Phase 1: create the next-host surface ownership layer with persistent pane
   surfaces and a dedicated AppKit controller boundary.
4. Phase 2: route next-host history scroll through Ghostty-owned cadence and
   delete host scroll-pump behavior from that path.
5. Phase 3: compare next host against native Ghostty on live-pane gates and
   cut over only after it wins on the relevant path.
