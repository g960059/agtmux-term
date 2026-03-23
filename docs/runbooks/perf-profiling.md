# Performance Profiling

Use this runbook for local performance investigations such as Gate-L parity.

## Local Gate-L Prep

Build the embedded app binary first:

```bash
swift build -c debug --build-path .build-codex
export AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm"
```

Confirm the AX helper is trusted before running any input-driven bench:

```bash
scripts/perf/gate_l_ax_key_sender.sh --dry-run
```

## Recommended Instruments

- Time Profiler
- Points of Interest
- System Trace when scheduler behavior matters

## Useful Capture Windows

- 10s idle
- 10s active scroll
- repeated pane switches or navigation actions

## Gate-L Bench Scripts

- `scripts/perf/gate_l_idle_parity.sh`
- `scripts/perf/gate_l_scroll_bench.sh`
- `scripts/perf/gate_l_native_ghostty_scroll_bench.sh`
- `scripts/perf/gate_l_trackpad_history_scroll_bench.sh`
- `scripts/perf/gate_l_native_ghostty_trackpad_history_scroll_bench.sh`
- `scripts/perf/gate_l_trackpad_upscroll_step_bench.sh`
- `scripts/perf/gate_l_native_ghostty_trackpad_upscroll_step_bench.sh`
- `scripts/perf/gate_l_trackpad_upscroll_step_parity.sh`
- `scripts/perf/gate_l_trackpad_live_curses_history_step_parity.sh`
- `scripts/perf/gate_l_trackpad_live_pane_bench.sh`
- `scripts/perf/gate_l_frontmost_live_client_scroll_bench.sh`
- `scripts/perf/gate_l_frontmost_live_client_scroll_parity.sh`
- `scripts/perf/gate_l_terminal_host_live_client_scroll_bench.sh`
- `scripts/perf/gate_l_terminal_host_live_client_scroll_parity.sh`
- `scripts/perf/gate_l_terminal_host_loaded_viewport_bench.sh`
- `scripts/perf/gate_l_terminal_host_loaded_viewport_parity.sh`
- `scripts/perf/gate_l_keypress_bench.sh`
- `scripts/perf/gate_l_native_ghostty_keypress_bench.sh`
- `scripts/perf/gate_l_pane_switch_bench.sh`
- `scripts/perf/gate_l_native_ghostty_pane_switch_bench.sh`
- `scripts/perf/gate_l_ax_key_sender.sh --dry-run` to confirm AX trust before running input benches

## Bench Rules

- Run AX-driven benches serially. Do not run embedded and native captures in parallel.
- Do not touch the mouse or keyboard while a capture is running.
- For short-keypress and scroll probes, prefer the repo-local harnesses over ad hoc manual sampling so the tmux-visible markers stay comparable.
- Native Ghostty baselines should preferably run with no pre-existing Ghostty processes. Use `--allow-existing` only when you intentionally accept ambiguous pid attribution.
- The current scroll proof uses a `less -N` proxy observed through `tmux capture-pane`; do not treat it as a true image-diff measurement of terminal-local scrollback.
- `gate_l_trackpad_history_scroll_bench.sh` runs in full-app mode with a
  transcript-style `less -R -N` fixture and pixel-burst scroll input. Treat
  `tmux_visible_line_change_ms` as a legacy proxy only. Prefer
  `scroll_to_layer_present_ms` and `layer_present_gap_*` for the actual
  presentation path. `scroll_to_render_request_ms`, `scroll_to_first_draw_ms`,
  and `draw_gap_*` remain diagnostic for the `GHOSTTY_ACTION_RENDER` host path
  and may legitimately stay empty when the scroll path bypasses that callback.
  The default injector mode is now
  `AGTMUX_PERF_TRACKPAD_PHASE_MODE=trackpad-burst-momentum`, which keeps the
  same burst size but splits it into direct-touch and inertial momentum phases.
  Override it with `AGTMUX_PERF_TRACKPAD_PHASE_MODE=trackpad-burst` when you
  need the older direct-touch-only sender for A/B comparison.
- `gate_l_native_ghostty_trackpad_history_scroll_bench.sh` is the native
  companion for the same transcript fixture and pixel-burst input path. Use it
  when you need the exact same `tmux_visible_line_change_ms` proxy against
  `/Applications/Ghostty.app`, but do not confuse that proxy with the actual
  user-visible presentation seam.
- `gate_l_trackpad_upscroll_step_bench.sh` now samples the visible pane rows
  themselves, not just the wrapped logical line number. Use it when the user
  complaint is “rows jump in chunks” rather than “the first movement starts
  late.” The older logical-line-only interpretation was too sensitive to
  `less -N` wrapping and can overstate coarse steps.
- `gate_l_native_ghostty_trackpad_upscroll_step_bench.sh` is the native
  companion for the same up-scroll step-granularity path.
- `gate_l_trackpad_upscroll_step_parity.sh` is the new native-difference gate
  for upward trackpad smoothness. It runs embedded and native serially, then
  fails if embedded exceeds native by more than the configured deltas for
  `mean_lines_per_step.p50`, `step_rows.p95`, `max_step_rows`,
  `coarse_step_ratio_ge_2`, `coarse_step_ratio_ge_3`, and
  `first_changed_elapsed_ms`.
- `gate_l_trackpad_live_curses_history_step_parity.sh` is the current
  alternate-screen proxy for tmux-attached live history:
  - it captures the real pane history with `--no-join-wrapped`
  - replays it through the repo-local reactive `curses-history` fixture
  - it uses the same native-difference parity gate, but defaults the tail long
    enough (`AGTMUX_PERF_UPSTEP_SAMPLE_TAIL_MS=1200`) to observe the first
    changed step
- treat the `curses-history` wrapper as a proxy, not the final acceptance gate
  for loaded live normal-screen scrollback
- prefer the live-captured `curses-history` wrapper over the older
  `scrollback` replay path when the user complaint is “the first visible up
  step arrives too late”:
  - the plain replay path writes history into a sleeping shell
  - tmux-attached wheel-up becomes alternate-scroll cursor keys
  - the sleeping shell just echoes `^[[A`, so that path is structurally invalid
    as a realistic gate
- `gate_l_frontmost_live_client_scroll_bench.sh` is the current realistic gate
  for the actual displayed live pane path:
  - it targets the current frontmost app window only
  - it measures the frontmost tmux client's `scroll_position` directly instead
    of depending on AX text sampling alone
  - it is only valid when tmux `mouse` is `on`
  - the bench JSON now reports `tmux_mouse_mode`, `valid`, and
    `invalid_reason`; treat `tmux_mouse_off` as setup failure, not as parity
  - use it when agtmux-term and native Ghostty are already open on the panes
    you want to compare
- `gate_l_frontmost_live_client_scroll_parity.sh` runs that same live-client
  bench twice, once for agtmux-term and once for native Ghostty, and compares
  `first_changed_elapsed_ms`, scroll delta, and coarse-step counts.
  - it refuses to run unless tmux `mouse` is `on`
- `gate_l_terminal_host_live_client_scroll_bench.sh` launches a fresh
  UITest-enabled agtmux-term app on the default local tmux server, opens the
  target live pane, and then runs the same frontmost live client-scroll bench
  for a specific `AGTMUX_TERMINAL_HOST_MODE`.
- for the current rewrite/live-host path, prefer a matching app bundle over a
  stale installed app:
  ```bash
  xcodebuild build -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath build-live-direct-debug CODE_SIGN_IDENTITY='-' \
    CODE_SIGNING_REQUIRED=NO
  export GATE_L_APP_BIN="$PWD/build-live-direct-debug/Build/Products/Debug/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm"
  ```
- the currently reliable same-bundle live host-mode path is:
  ```bash
  AGTMUX_PERF_LIVE_ATTACH_RUNNING_APP=0 \
  AGTMUX_PERF_LIVE_USE_INTERNAL_SCROLL_MEASUREMENT=1 \
  AGTMUX_PERF_LIVE_USE_ACTIVE_TARGET=1 \
  AGTMUX_PERF_LIVE_SESSION_NAME='gate-normal-scroll' \
  AGTMUX_PERF_LIVE_PANE_ID='%2' \
  scripts/perf/gate_l_terminal_host_live_client_scroll_bench.sh --host-mode next --timeout 25
  ```
- if you need the host-mode comparison on that same pane, run:
  ```bash
  AGTMUX_PERF_LIVE_ATTACH_RUNNING_APP=0 \
  AGTMUX_PERF_LIVE_USE_INTERNAL_SCROLL_MEASUREMENT=1 \
  AGTMUX_PERF_LIVE_USE_ACTIVE_TARGET=1 \
  AGTMUX_PERF_LIVE_SESSION_NAME='gate-normal-scroll' \
  AGTMUX_PERF_LIVE_PANE_ID='%2' \
  scripts/perf/gate_l_terminal_host_live_client_scroll_parity.sh \
    --session-name 'gate-normal-scroll' --pane-id '%2' --timeout 25
  ```
- do not bootstrap tmux scenarios on the default local server:
  - `gate_l_launch_app` now refuses that path unless you explicitly set
    `AGTMUX_PERF_ALLOW_DEFAULT_LOCAL_TMUX_SCENARIO=1`
  - for live default-server work, prefer the bundle/defaults path used by
    `gate_l_launch_app_without_bootstrap`
- that wrapper now primes the fresh client with a client-targeted `PageUp`
  before the measured wheel burst and emits `clientCommandProbe` in the JSON.
  If `clientCommandProbe.moved == true` while `changed_sample_count == 0`,
  the fresh client is scrollable but wheel-up still is not producing tmux
  client scroll on that path.
- the same wrapper now also emits `baselineViewport`, `finalViewport`, and
  `postScrollTelemetry`.
  - if `scrollInputCount > 0` but both `changed_sample_count == 0` and the
    viewport snapshots are unchanged, the wheel burst reached the terminal
    presentation path without changing visible state
- `gate_l_terminal_host_live_client_scroll_parity.sh` is the phase-1/phase-2
  rewrite gate for `legacy` vs `next` host mode on the same live pane. Use it
  before native parity when the question is “does the rewrite path regress the
  real live-pane scroll path?”
- the current durable requirement for this wrapper is a matching bundle plus
  bridge-internal measurement:
  - on 2026-03-23 the matching-debug-bundle path completed on both `legacy`
    and `next`
  - the same run also produced a valid parity payload with
    `sameResolvedPane: true`, `legacyWheelMoved: true`, and
    `nextWheelMoved: true`
  - one recorded payload reported:
    - `legacy.changed_sample_count = 16`
    - `next.changed_sample_count = 17`
    - `first_changed_elapsed_delta_ms = -357.9162`
- the host-mode parity wrapper is still only meaningful when both sides record
  at least one wheel-driven scroll change. If either side has
  `changed_sample_count == 0`, it reports `valid: false` instead of a false
  pass.
- `gate_l_terminal_host_loaded_viewport_bench.sh` is the current phase-2
  acceptance surface for `legacy` vs `next`:
  - it launches a fresh UITest-enabled app in the selected host mode
  - it runs the repo-local `curses-history` viewer on a deterministic loaded
    fixture inside an isolated tmux session
  - it waits for the loaded marker to enter the viewport, then measures first
    visible movement latency and step metrics via the bridge viewport sampler
- `gate_l_terminal_host_loaded_viewport_parity.sh` compares those two host
  modes and currently fails if `next` exceeds `legacy` by more than:
  - `25ms` on `first_changed_elapsed_ms`
  - `0` on `max_step_rows`
  - `2` fewer changed samples
  - `2` fewer total upward rows
- pass `--iterations N` or `AGTMUX_PERF_HOST_MODE_PARITY_ITERATIONS=N` when you
  want the parity wrapper to aggregate medians across repeated `legacy`/`next`
  pairs
- the first few valid smokes on this gate have mixed latency deltas, so treat a
  single pass as a sanity check and prefer median aggregate runs before
  concluding that `next` is stably at parity
- keep the deterministic gate on the default sender path unless you are
  explicitly diagnosing targeting:
  - `AGTMUX_PERF_LOADED_FOCUS_MODE=identifier`
  - `AGTMUX_PERF_LOADED_SCROLL_MODE=point`
  - a `3`-iteration aggregate on 2026-03-22 passed at about `-14.0ms` with
    that path, while `front-window + point` lost by about `+60.2ms`
- the earlier plain loaded-transcript variant is diagnostic-only:
  - on that path `baselineViewport.usesAlternateScroll` can still be true
  - wheel-up then becomes alternate-scroll cursor keys instead of a useful
    deterministic acceptance surface
- `gate_l_trackpad_live_pane_bench.sh` is the direct diagnostic seam for an
  actual local pane, for example a live Claude/Codex history pane. It launches
  a UITest-enabled app without a bootstrap tmux socket, opens the real pane on
  the default local tmux server, then samples the terminal viewport while a
  single injected trackpad burst runs.
- Use the direct live-pane bench to answer “does a fresh client even expose
  older rows for this pane?” not “is this the final native parity gate?” On
  2026-03-21 the real Claude pane `%662` recorded non-zero `scrollInputCount`,
  `scrollPresentationDrawCount`, and `layerPresentCount`, but
  `changed_transition_count` stayed `0`, which showed that a fresh direct
  attach still does not represent the existing app's loaded scrollback history.
- For the host-mode live wrapper, prefer session-aware pane selection over a
  hard-coded `%pane` whenever the user's workflow is churning panes:
  - `AGTMUX_PERF_LIVE_PANE_TITLE_CONTAINS='Claude Code'`
  - `AGTMUX_PERF_LIVE_PANE_COMMAND=node`
  - if the requested pane disappears, the wrapper now falls back to
    title/command/active-pane resolution inside the target session
- The fresh/live host-mode scripts now force `env -u TMUX -u TMUX_PANE tmux`
  for all default-local tmux sampling so they do not inherit a stale caller
  socket.
- The step-granularity gate uses the same momentum-aware injector as the
  history bench (`AGTMUX_PERF_UPSTEP_PHASE_MODE=trackpad-burst-momentum` by
  default) and samples every `16ms`.
  - the base upscroll-step benches default to a `180ms` tail
  - the live-captured `curses-history` wrapper raises that default to `1200ms`
    because the first changed sample can arrive well after the last injected
    scroll event
- A true screen/image-diff native parity bench requires Screen Recording
  capability for the current terminal environment. If `/usr/sbin/screencapture`
  fails with `could not create image from display`, treat visual parity work as
  blocked until that permission path is fixed.
- Set `AGTMUX_PERF_KEEP_TMP=1` if you need the bench temp directory for failed
  captures or ad hoc inspection.

## Signpost Categories

- `GhosttyTick`
- `SurfaceDraw`
- `FetchAll`
- `LocalInventory`
- `RemoteInventory`
- `MetadataSync`
- `NavigationSync`
- `TmuxRunner`
- `Publish`
- `PublishAssemble`
- `GhosttyBridge`

## Storage Rule

Store binary traces outside `docs/` and link them from the relevant Issue or PR.
Keep this runbook procedural; keep dated conclusions in `docs/research/`.
