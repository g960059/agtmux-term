# Review Pack

## Objective
- Task: T-102
- User story: GhosttyKit custom OSC host action exposure for the `agt open` bridge
- Acceptance criteria touched: vendored Ghostty parses the chosen custom OSC bridge command and preserves its raw payload, `ghostty_action_s` exposes a typed custom-OSC payload at the C boundary, rebuilt `GhosttyKit.xcframework` delivers that typed action through the existing `action_cb`

## Summary (3-7 lines)
- Added `OSC 9911` as the agtmux bridge carrier in vendored Ghostty.
- The parser now preserves raw payload bytes for that OSC and carries them as a typed `custom_osc` action through the existing embedded runtime `action_cb`.
- `ghostty_action_s` and the public `ghostty.h` header now expose the custom OSC payload at the C boundary, including the OSC numeric code and raw payload pointer/length.
- Embedded runtime coverage now proves a real `custom_osc` action reaches `action_cb` with the exact `osc` and payload bytes.
- Shared-source GTK runtime parity is now explicit: the GTK action switch handles `.custom_osc` via `Action.customOSC(...)` instead of leaving the new action path undefined outside the embedded runtime.
- Rebuilt `GhosttyKit.xcframework` from source and verified the generated headers stay in sync with `vendor/ghostty/include/ghostty.h`.

## Change scope (max 10 files)
- `vendor/ghostty/src/terminal/osc.zig`
- `vendor/ghostty/src/terminal/stream.zig`
- `vendor/ghostty/src/termio/stream_handler.zig`
- `vendor/ghostty/src/apprt/surface.zig`
- `vendor/ghostty/src/Surface.zig`
- `vendor/ghostty/src/apprt/action.zig`
- `vendor/ghostty/src/apprt/embedded.zig`
- `vendor/ghostty/src/apprt/gtk/class/application.zig`
- `vendor/ghostty/include/ghostty.h`
- `GhosttyKit/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h`
- `GhosttyKit/GhosttyKit.xcframework/ios-arm64/Headers/ghostty.h`
- `GhosttyKit/GhosttyKit.xcframework/ios-arm64-simulator/Headers/ghostty.h`

## Verification evidence (Tester output)
- Commands run:
  - `cd vendor/ghostty && zig build test -Dtest-filter='custom osc'` => PASS
  - `./scripts/build-ghosttykit.sh` => PASS
  - `cmp -s vendor/ghostty/include/ghostty.h GhosttyKit/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h` => PASS
  - `cmp -s vendor/ghostty/include/ghostty.h GhosttyKit/GhosttyKit.xcframework/ios-arm64/Headers/ghostty.h` => PASS
  - `cmp -s vendor/ghostty/include/ghostty.h GhosttyKit/GhosttyKit.xcframework/ios-arm64-simulator/Headers/ghostty.h` => PASS
  - `swift build` => PASS
- Notes:
  - the carrier is surfaced through the existing `action_cb`; no second top-level callback was added
  - `vendor/ghostty/src/apprt/embedded.zig` now contains an executed proof that `App.performAction(..., .custom_osc, ...)` reaches the runtime `action` callback with exact `osc` and payload bytes
  - `vendor/ghostty/src/terminal/stream.zig` now contains an ST-terminated stream proof alongside the BEL parser coverage in `vendor/ghostty/src/terminal/osc.zig`
  - `vendor/ghostty/src/apprt/gtk/class/application.zig` now handles `.custom_osc` explicitly for shared-source parity

## Risk declaration
- Breaking change: low but real; vendored Ghostty ABI/C header surface changed by one new action tag and payload
- Fallbacks: none; unknown OSCs remain invalid, only `OSC 9911` is surfaced for this path
- Known gaps / follow-ups:
  - `T-103` still needs to decode the `custom_osc` payload in Swift and dispatch it into `WorkbenchStoreV2`
  - GTK parity is verified by source inspection on this macOS pass; no GTK-targeted runtime test was executed here

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Status
- Previous reviewer verdicts:
  - Codex review #1: `GO_WITH_CONDITIONS`
  - Codex review #2: `NO_GO`
- Previous blocking findings:
  - automated proof did not yet show exact `osc` plus payload bytes reaching the host `action_cb`, including an ST-terminated path
  - GTK runtime parity for `.custom_osc` was not explicit in the shared-source application switch
- Remediation status:
  both blocking findings are fixed on the current worktree and reflected in the refreshed verification evidence above
- Claude CLI status:
  per current repo policy, Claude review was not required for this closeout path; Codex review coverage was increased instead
- Final reviewer verdicts:
  - independent Codex review #1: `GO`
  - independent Codex review #2: `GO`
