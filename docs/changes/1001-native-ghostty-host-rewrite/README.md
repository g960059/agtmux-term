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
- the next-host bridge/runtime now treats leaf ownership more strictly:
  - `UITestTmuxBridge` no longer resolves `next` host terminal view lookups by
    falling back to the tile UUID before an active leaf is published
  - `waitForTerminalViewRegistration`, viewport dumps, and focus-state lookups
    now wait for a true `TerminalHostActiveSurfaceRegistry` leaf on `next`
    instead of accidentally accepting a stale legacy tile-level view
  - `activeTerminalTargetSnapshot` can still fall back to the focused rendered
    tile during bootstrap, but the returned `terminalHostMode` now comes from
    the rendered surface context rather than the runtime override alone
- `GhosttyTerminalSurfaceRegistry` now treats a host-mode remount on the same
  tile as a new rendered generation:
  - same-command `legacy -> next` or `next -> legacy` remounts no longer
    preserve `generation` or `clientTTY`
  - this removes one stale-state seam during loaded-tile host-mode switches
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
  - destructive bootstrap against the default local tmux server is now
    explicitly forbidden:
    - `gate_l_launch_app` refuses to run a UITest bootstrap scenario on the
      default local server unless an explicit override is set
    - `gate_l_launch_app_without_bootstrap` now forces `bridge_config_mode=
      defaults` whenever it targets the default local server, so live wrapper
      runs use a normal persisted app launch instead of an env-driven UITest
      app that could mutate the user's server
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
  - during live-wrapper hardening, tmux client targeting turned out to be
    stricter than the old code assumed:
    - `switch-client -c <renderedClientTTY> -t %pane` is invalid on tmux and
      fails with `can't find client`
    - the bridge now resolves `client_name` from `list-clients` before issuing
      `switch-client`
    - this removes one false blocker from the fresh wrapper, but it is still
      not acceptance-ready because `open_terminal_for_pane` on fresh app
      mounts can stall before the already-loaded live pane path is reached
  - as a result, the fresh host-mode live-client wrapper is diagnostic only and
    cannot be the final rewrite acceptance gate for the user's loaded-pane
    history complaint
- the obsolete replay/frontmost-AX scroll gates are retired in favor of:
  - the deterministic loaded-TUI host-mode gate for phase-2 `legacy` vs `next`
    acceptance
  - the live-captured `curses-history` proxy
  - the frontmost live client-scroll parity gate
- phase 3 has now started on the rewrite branch:
  - `GhosttyTerminalSurfaceContext` carries `terminalHostMode` all the way into
    `GhosttyTerminalView`
  - `next` host disables the legacy host scroll-presentation pump and relies on
    Ghostty-owned cadence for normal-screen wheel input
  - `next` host now also keeps recent precise normal-screen render callbacks on
    the renderer-owned refresh path instead of feeding them back into the
    legacy direct-draw scheduler
  - the same renderer-owned callback fast path now also covers recent precise
    alternate-scroll bursts on `next`, so the deterministic loaded-TUI gate no
    longer special-cases them back onto the legacy direct-draw scheduler
  - the deterministic loaded-TUI parity gate currently passes with this phase-3
    wiring; a fresh `--iterations 2` run recorded median
    `first_changed_elapsed_delta_ms = -18.8639`, with zero
    `islandRetryCountDelta` and zero `islandApplyCommandCountDelta`
  - after broadening the render-callback fast path and hardening bridge command
    delivery, a fresh `--iterations 3` deterministic parity run still passed
    with median `first_changed_elapsed_delta_ms = +0.0699`,
    `scrollFirstInputElapsedDeltaMs = +5.2475`, and
    `scrollToLayerPresentP50DeltaMs = -5.8036`
  - the same hardening removed a real live-wrapper blocker:
    `refreshInventory` bridge commands are now emitted as JSON booleans via
    atomic command-file swaps, so the bridge no longer spins on
    `invalid-request-payload` during rewrite diagnostics
  - runtime host-mode selection now also honors the app default
    `TerminalHostMode`, so an installed rewrite-branch build can be switched to
    `next` without launch-time env injection
  - persisted/sanitized active pane refs with blank `windowID/paneID` no longer
    count as a real visible-pane identity in `next`
  - startup mounts therefore stay on the tile-fallback controller until live
    pane observation resolves an actual pane target, instead of creating a
    pane-keyed child from an invalid blank identity
  - persisted local terminal tiles in `next` no longer stay blank until the
    first inventory sync completes:
    - while the tile is still in `bootstrapping`, `next` now allows an
      optimistic local attach when the persisted attach plan already resolves
    - a fresh rewrite build now shows the persisted startup tile's rendered
      target and viewport text at `T0`, before `activePaneSelection` becomes
      queryable through the bridge
- the rewrite branch now keeps the existing UI safety net green while `next`
  host work continues:
  - the full `AgtmuxTermUITests` suite currently passes on this branch at
    `36 tests, 7 skipped, 0 failures`
  - the suite is pinned to `AGTMUX_TERMINAL_HOST_MODE=legacy` so rewrite
    experiments do not inherit a developer-local runtime override and create
    unrelated failures
  - `WorkbenchFocusedNavigationActor` polling now tolerates store-driven
    desired/observed pane updates during a live reverse-sync run instead of
    self-canceling when the snapshot no longer exactly matches the original
    pane refs
  - durable conclusion: rewrite validation should use the dedicated host-mode
    parity gates, while the app-wide UI suite stays on the proven legacy path
    until the loaded live-pane gate is acceptance-ready
- phase 3 startup/render ownership is now less lossy on real local tiles:
  - the app always instantiates `UITestTmuxBridge`, and `startIfNeeded()` now
    decides whether bundle/defaults launches should activate the command loop
  - this makes same-app rewrite diagnostics possible on a normal app bundle
    launch instead of only env-driven UITest startup
  - `next` host no longer tears down the bootstrap fallback controller when
    the first real `visiblePaneIdentity` arrives for a persisted local tile
  - instead it promotes the existing fallback controller/surface to the real
    pane key, removing one blank handoff during bootstrap on loaded local
    workbenches
- live rewrite diagnostics now have stronger same-app plumbing:
  - `UITestTmuxBridge` can synthesize an internal trackpad burst directly
    against a registered `GhosttyTerminalView` and sample viewport text in the
    same command, so fresh/live diagnosis no longer depends on external AX
    sender trust
  - that internal path proved the durable negative result more cleanly:
    fresh-mounted normal-screen panes can still record `changed_sample_count =
    0` even when scroll delivery is fully in-process
  - the real blocker therefore remains "fresh mount does not reproduce the
    already-loaded live history path", not external AX hit-testing
  - the bridge activation monitor now reconciles command-loop paths while the
    bridge stays enabled, so same-running app diagnostics can rotate
    `UITestTmuxCommandPath` / `UITestTmuxCommandResultPath` after launch
  - a focused regression now covers that rebind behavior, and a rebuilt
    installed app responds on both the first and second temp command paths in
  - the bridge command loop now consumes the command file after decoding a
    request, which stops expensive internal scroll measurements from being
    re-executed with the same request ID during command-loop polling
  - `gate_l_step_metrics.py` now treats movement below a stable header and
    line-number-only upward motion as real viewport change instead of a false
    zero-step result
  - `gate_l_terminal_host_live_client_scroll_bench.sh` now gives measured
    bridge-internal bursts the same timeout budget as prime bursts, so the
    same matching debug bundle can complete the full `next` live wrapper path
  - a fresh matching-debug-bundle run now exits `0` on the `next` host-mode
    live wrapper with visible movement recorded:
    - temp dir:
      `/var/folders/pm/qr6qn8mn1n5cwkgk82yn3cnh0000gn/T//agtmux-gate-l-live-client-next-6636d5f0.MAlrzy`
    - stage log reached `viewport-primed`, `initial-baseline-viewport`,
      `initial-bench-done`, `initial-viewport-samples-done`, and
      `initial-post-scroll-telemetry`
    - the measured summary recorded non-zero `changed_sample_count` instead of
      the earlier false-zero blocker
  - the same matching debug bundle now also completes the `legacy` live
    wrapper and a full `legacy` vs `next` live parity comparison:
    - `legacy` temp dir:
      `/var/folders/pm/qr6qn8mn1n5cwkgk82yn3cnh0000gn/T//agtmux-gate-l-live-client-legacy-d0fc7551.nBM6qf`
    - parity payload:
      `/tmp/gate-l-live-parity.XXXXXX.json`
    - the parity result is currently `passed: true` and `valid: true`, with
      `sameResolvedPane: true`, `legacyWheelMoved: true`, and
      `nextWheelMoved: true`
    - the current payload records `legacy.changed_sample_count = 16`,
      `next.changed_sample_count = 17`, and
      `comparison.first_changed_elapsed_delta_ms = -357.9162`
    a same-running attach check
  - same-running app tmux passthrough now returns real stdout on installed
    rewrite builds:
    - `TmuxCommandRunner` local subprocesses now normalize their launch
      environment via `ManagedDaemonLaunchEnvironment`
    - the runner also stopped draining stdout/stderr through unsynchronized
      mutable `Data` captured by background queues; it now waits for process
      exit and reads both pipes on one thread
  - before this fix, the running app could answer bridge commands with
      `ok=true` and `stdout=""` for `display-message`, `list-sessions`, and
      `list-clients`, which left same-app live gates unable to resolve the
      real rendered client on the default local tmux server
    - after the fix, same-running bridge commands return the default tmux
      socket, session inventory, and client list, including the loaded
      `gate-normal-scroll` client on `/dev/ttys026`
    - this moved the blocker forward: the live gate now samples the actual
      current pane text, but bridge-internal wheel bursts on that already-
      loaded pane still record zero viewport change, and same-app runtime
      host-mode switching remains flaky
- the same-running bridge-internal live wrapper is now less coupled to
  rendered-target metadata:
  - when `AGTMUX_PERF_LIVE_USE_INTERNAL_SCROLL_MEASUREMENT=1`, the live bench
    no longer blocks on `__agtmux_dump_rendered_terminal_target__` before it
    can focus the host and measure a burst
  - the perf common bridge helper now normalizes the last JSON payload line
    when wrapper noise appears ahead of the real bridge response, so repeated
    same-app measurement rounds keep producing machine-readable JSON
  - a fresh same-running `next` run now reaches the real priming failure
    boundary instead of hanging in rendered-target resolution:
    `changed_sample_count = 0` across all prime rounds while the viewport text
    stays unchanged
