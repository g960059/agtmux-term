Place a signed `agtmux` executable here to bundle it with the app.

Expected bundled path at runtime:
- `AgtmuxTerm.app/Contents/Resources/Tools/agtmux`
- (SwiftPM resource flattening fallback) `AgtmuxTerm.app/Contents/Resources/agtmux`

XPC mode note:
- In default XPC mode, `AgtmuxDaemonService.xpc` resolves this binary via the host app bundle path above.

Resolution order used by the app:
1. `AGTMUX_BIN` (explicit override)
2. Bundled `Resources/Tools/agtmux`
3. PATH/common install locations
