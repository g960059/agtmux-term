# Instruments Template

## Recommended Instruments

Use this stack for `T-LF-00` and later Gate-L slices:

- Time Profiler
- Points of Interest
- System Trace when scroll/input latency needs scheduler detail

## Signpost Categories To Enable

- `GhosttyTick`
- `SurfaceDraw`
- `FetchAll`
- `MetadataSync`
- `NavigationSync`
- `RemoteSSH`
- `TmuxRunner`
- `Publish`

## Session Setup

1. Build the app with `swift build`.
2. Start the benchmark session with `scripts/perf/local_scroll_bench.sh`.
3. Launch `agtmux-term`.
4. Focus the benchmark session tile.
5. Start capture.

## Capture Windows

Collect three windows when possible:

- 10s idle
- 10s active scroll
- 10 pane switches or navigation events

## What To Compare

- main-thread total during active scroll
- frequency and total time of `FetchAll`
- frequency and total time of `TmuxRunner`
- `NavigationSync` activity during pane switch
- `SurfaceDraw` volume during idle vs active scroll

## Storage Convention

Keep exported traces or summaries outside `docs/` and reference them from the
task, review pack, or progress ledger. The design docs should record procedure,
not binary artifacts.
