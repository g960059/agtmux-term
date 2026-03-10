The packaged app/XPC path expects a bundled `agtmux` executable here.

In local Debug builds, the `AgtmuxTerm` target now stages the daemon directly
into the built app bundle at build time:

- source priority at build time:
  1. `AGTMUX_BIN`
  2. sibling workspace binary `../agtmux/target/debug/agtmux`
- bundled runtime path:
  - `AgtmuxTerm.app/Contents/Resources/Tools/agtmux`

Expected bundled path at runtime:
- `AgtmuxTerm.app/Contents/Resources/Tools/agtmux`
- (SwiftPM resource flattening fallback) `AgtmuxTerm.app/Contents/Resources/agtmux`

XPC mode note:
- In default XPC mode, `AgtmuxDaemonService.xpc` resolves this binary via the host app bundle path above.

Resolution order used by the app:
1. `AGTMUX_BIN` (explicit override)
2. Bundled `Resources/Tools/agtmux`

Notes:
- If `AGTMUX_BIN` is set, runtime resolution does not guess or fall back to other locations.
- PATH lookup and common install locations are not part of the runtime resolution order.
