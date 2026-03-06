Place a signed `agtmux` executable here to bundle it with the app.

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
