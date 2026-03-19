# Plan

1. Add host-side direct dirty-draw scheduling for render callbacks and tighten
   dirty-surface consumption.
2. Extend the AX helper and perf harness for trackpad-style pixel bursts and
   transcript-history fixtures.
3. Add integration coverage for direct-draw coalescing, background deferral,
   and scroll telemetry bookkeeping.
4. Extend the same host-side pacing approach to same-window pane retargets
   without recreating the surface, and trim sidebar selection churn that lands
   on the same frame.
5. Re-run targeted tests and perf benches, then document the measured results
   and the assumptions that broke.
