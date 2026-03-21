# Plan

1. Freeze the current host-scheduler baseline and treat it as the fallback path,
   not the target architecture for history scroll parity.
2. Keep the accepted vendor-side renderer optimization and normalize its
   provenance around pinned upstream Ghostty `v1.2.3` plus a checked-in
   aggregate patch that can rebuild `GhosttyKit` from a fresh clone.
3. Design and keep measuring history-scroll branches where direct-touch
   trackpad input is cadence-led by libghostty/native rendering semantics
   instead of by a host-side draw pump, but only keep them if they beat the
   vendor-optimized hybrid baseline.
4. Keep host-owned immediate draws only for explicit host seams:
   render-callback direct draws, pane-retarget refresh, attach/activate
   transitions, and delayed recovery when presentation truly stalls.
5. Add validation that compares the native-cadence branch against both:
   the current embedded baseline and native Ghostty on the same transcript-style
   burst path.
6. After the stricter renderer-owned branches are measured, only keep them if
   they beat the hybrid baseline on both short and long bursts. If they do not,
   keep targeting reusable viewport-shift and `up`-scrollback rebuild cost
   inside embedded Ghostty rather than returning to host cadence policy tweaks.
   The current accepted state now includes a `Contents.shiftRows(...)`
   `abs_shift == 1` fast path plus background/foreground sparse upload reuse on
   compatible viewport shifts, so the next renderer pass should focus on the
   fixed per-frame work and fallback cases that still remain after row shifting
   and GPU reuse itself.
7. With both background and foreground viewport-shift uploads reduced, treat
   later-`up` wake/presentation variance and the conservative fallback cases
   (cursor overlays, row-count-changing rebuilt rows) as the next primary
   seams. Only after those seams are understood, revisit secondary contributors
   such as runtime-store churn or pane/sidebar work that still overlaps the
   main thread during long bursts.
