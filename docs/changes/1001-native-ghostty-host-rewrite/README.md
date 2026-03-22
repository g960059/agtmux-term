# Change Pack

- **Issue:** `#1001` placeholder until a real GitHub issue exists
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** [ADR-0005-native-ghostty-host-rewrite.md](../../decisions/ADR-0005-native-ghostty-host-rewrite.md), [2026-03-18-scroll-smoothness-baseline.md](../../research/2026-03-18-scroll-smoothness-baseline.md), [2026-03-22-live-scroll-gates.md](../../research/2026-03-22-live-scroll-gates.md)

This pack tracks the structural rewrite that moves terminal hosting away from
the legacy embedded scroll-pump path and toward a Ghostty-owned host model in
the same repository.

Current state:

- the old scroll investigation pack is retired; its accepted findings now live
  in the research note and perf runbook
- completed packs for unsigned release fallback and sidebar daemon binding are
  retired from `docs/changes/`
- phase 1 now has an explicit `TerminalHostMode` boundary:
  - `legacy` routes through `GhosttyIslandRepresentable`
  - `next` routes through a separate next-host controller boundary
- phase 1 next-host ownership now keeps pane-keyed child controllers with a
  capped retention set, so same-tile pane switches can move toward controller
  swap instead of same-surface reattach
- the UITest tmux bridge and perf app launcher now surface
  `AGTMUX_TERMINAL_HOST_MODE`, so realistic live gates can target `legacy`
  and `next` explicitly instead of inferring host ownership from the app build
- phase 2 now has a deterministic loaded-TUI host-mode gate:
  - `gate_l_terminal_host_loaded_viewport_bench.sh` launches a fresh
    UITest-enabled app in `legacy` or `next` mode against an isolated tmux
    session that runs the repo-local `curses-history` viewer on a deterministic
    loaded fixture
  - `gate_l_terminal_host_loaded_viewport_parity.sh` compares `legacy` and
    `next` on first visible movement latency and step metrics before the
    rewrite is judged on the more variable live-pane path
  - the parity wrapper now accepts `--iterations` and aggregates medians across
    repeated `legacy`/`next` pairs because single-run `first_changed` is
    quantized by the `16ms` sampler
  - the gate is now valid on both sides; the first valid smoke run showed
    `next` trailing `legacy` by about `36.9ms`, while subsequent reruns passed
    with `next` leading by about `25-42ms`
  - with `--iterations 2`, the current aggregate smoke passed at about
    `+8.1ms` on median `first_changed_elapsed_ms`
  - with `--iterations 3`, `identifier + point` targeting passed at about
    `-14.0ms`, while `front-window + point` lost by about `+60.2ms`
  - the acceptance default therefore remains `focusMode=identifier` and
    `scrollMode=point`; `front-window` targeting stays diagnostic-only
  - phase 2 has now cleared repeatability enough to move back to the loaded
    live-pane gate
- the next-host bridge/runtime now resolves workbench tile IDs to the active
  pane leaf ID:
  - `TerminalHostActiveSurfaceRegistry` records the active pane-owned surface
    behind each workbench tile
  - `UITestTmuxBridge` viewport/focus snapshots now use that mapping so `next`
    host parity benches can target the active pane correctly
  - `GhosttyIslandViewController.hostContainerDidAttachVisibleView()` retries
    pending attach once the next-host container has actually made the child
    visible
- the perf harness now disables inherited shell xtrace when sourcing
  `gate_l_common.sh`, because machine-readable JSON payloads such as
  `active-target.json` were occasionally polluted by stray `output=''` prefixes
- the realistic live client-scroll gate now has a host-mode wrapper:
  - `gate_l_terminal_host_live_client_scroll_bench.sh` launches a fresh app in
    either `legacy` or `next` mode and measures the live pane path
  - `gate_l_terminal_host_live_client_scroll_parity.sh` compares those two
    modes on the same live pane before the rewrite is judged against native
  - the wrapper now resolves the pane target dynamically inside the tmux
    session, so a stale `%pane` can fall back to title/command/active-pane
    matching instead of failing outright
  - it now talks to the default local tmux server with `env -u TMUX -u
    TMUX_PANE tmux`, both in the shell wrapper and in the client-scroll
    sampler, so the gate no longer depends on the invoking shell's stale tmux
    environment
  - it no longer depends on tmux client `scroll_position` / `list-clients` /
    `display-message` during the measured run, because the user's default live
    tmux server can block those commands
  - the measured run now uses the bridge viewport sampler as ground truth and
    sends the wheel burst directly with `gate_l_ax_key_sender.sh`
  - the bridge now also has a local `paneID` inventory fallback before
    session-only open, because the daemon/live side can lose `session_name`
    while still keeping a usable local pane inventory entry
- fresh live-client investigation has now isolated a stricter boundary:
  - the fresh host-mode wrapper now completes on both `legacy` and `next`
    using viewport-only truth
  - both modes currently render a fresh local session viewport that still shows
    only the new-login shell and records `changed_sample_count = 0`
  - with `AGTMUX_SCROLL_TELEMETRY=1`, that same wheel burst still increments
    `scrollInputCount`, `scrollPresentationDrawCount`, and `layerPresentCount`
    while the terminal viewport text stays unchanged
  - vendor `Surface.scrollCallback` explains why: on a normal-screen pane with
    `uses_alternate_scroll == false` and no mouse-reporting mode, wheel input
    takes the local `scrollViewport` path rather than tmux copy-mode or
    alternate-scroll writes
  - therefore the current phase-2 blocker is not "live wrapper hangs" but
    "fresh app mounting does not reproduce the already-loaded live history path
    that the user is scrolling in the existing app"
  - bridge `open_terminal_for_pane` now waits for terminal view registration
    before returning, because otherwise fresh live gates can fail with
    `No terminal view registered for tileID ...` before the tile is actually
    mounted
  - the next structural step is now in place: terminal host mode can be
    overridden at runtime for UITest/bench flows instead of being fixed only
    at app launch, which is the foundation for measuring `legacy` and `next`
    against the same already-loaded app state
  - as a result, the fresh host-mode live-client wrapper is diagnostic only and
    cannot be the final rewrite acceptance gate for the user's loaded-pane
    history complaint
- the obsolete replay/frontmost-AX scroll gates are retired in favor of:
  - the deterministic loaded-TUI host-mode gate for phase-2 `legacy` vs `next`
    acceptance
  - the live-captured `curses-history` proxy
  - the frontmost live client-scroll parity gate
