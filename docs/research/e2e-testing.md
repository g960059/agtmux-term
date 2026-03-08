# E2E / Integration Testing Feasibility — agtmux-term

**Date**: 2026-03-03
**Status**: Research complete

---

## Executive Summary

| Test Type | Verdict | Effort |
|-----------|---------|--------|
| Unit tests (XCTest via SwiftPM) | **GO** | Low — add a `.testTarget` to Package.swift and extract pure logic into a library target |
| Integration tests (tmux subprocess) | **GO** | Medium — real tmux is available (`tmux 3.6a`), actors are isolatable with protocol injection |
| UI / E2E tests (XCUITest) | **NO-GO without tooling** / **PARTIAL with workaround** | High — requires Xcode project or a third-party accessibility harness |
| Crash investigation (placePane) | **Actionable** | Low to medium — root cause is identifiable without full E2E tests |

---

## 1. Unit Tests (XCTest via SwiftPM)

### Feasibility

**GO.** SwiftPM's `.testTarget` works for macOS apps. The only hard constraint is that test targets cannot directly import a `.executableTarget` — the source files that contain testable logic must live in a separate `.target` of type library (or module). Currently all code is in the single `AgtmuxTerm` executable target, so a small target split is required first.

`swift test` currently outputs:

```
error: no tests found; create a target in the 'Tests' directory
```

This confirms the build infrastructure works; only the target split and test code are missing.

### What is testable without the full app

The following types have zero AppKit/GhosttyKit dependencies and are pure Swift value/actor logic:

| Type | File | Testable surface |
|------|------|-----------------|
| `TmuxLayoutConverter` | TmuxLayoutConverter.swift | `convert(layoutString:windowPanes:source:)` — pure string-to-BSP |
| `LayoutNode` / `LeafPane` / `SplitContainer` | LayoutNode.swift | `splitLeaf`, `removingLeaf`, `replacing`, `validateUniqueIDs`, `leaves`, `leafIDs` |
| `AgtmuxPane` / `AgtmuxSnapshot` | DaemonModels.swift | JSON decoding, `primaryLabel`, `needsAttention`, `tagged(source:)` |
| `AppViewModel.panesBySession` grouping | AppViewModel.swift | Pure computed property; testable by constructing `AgtmuxPane` arrays |
| `TmuxControlMode.parseLine` | TmuxControlMode.swift | Private — requires making it `internal` or adding `@testable import` |
| `WorkspaceStore` BSP mutations | WorkspaceStore.swift | `placePane` (layout path only), `updateLeaf`, `mergeLayout` — needs MainActor test setup |

### Required Package.swift change

To enable `@testable import`, extract shared types into a library target:

```swift
// Package.swift (modified)
let package = Package(
    name: "AgtmuxTerm",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit/GhosttyKit.xcframework"
        ),
        // New: pure-logic library with no GhosttyKit dependency
        .target(
            name: "AgtmuxTermCore",
            path: "Sources/AgtmuxTermCore"
        ),
        // Existing executable keeps GhosttyKit
        .executableTarget(
            name: "AgtmuxTerm",
            dependencies: ["GhosttyKit", "AgtmuxTermCore"],
            path: "Sources/AgtmuxTerm",
            resources: [.process("Resources")],
            linkerSettings: [ /* existing linker flags */ ]
        ),
        .testTarget(
            name: "AgtmuxTermCoreTests",
            dependencies: ["AgtmuxTermCore"],
            path: "Tests/AgtmuxTermCoreTests"
        ),
    ]
)
```

Files to move to `AgtmuxTermCore` (no GhosttyKit or AppKit imports):
- `LayoutNode.swift`
- `TmuxLayoutConverter.swift`
- `DaemonModels.swift` (minus `AgtmuxDaemonClient` which uses Foundation/Network)

### Recommended test cases

**TmuxLayoutConverter**

```swift
import XCTest
@testable import AgtmuxTermCore

final class TmuxLayoutConverterTests: XCTestCase {

    // Helpers
    private func pane(_ num: Int, session: String = "s") -> AgtmuxPane {
        AgtmuxPane(source: "local",
                   paneId: "%\(num)",
                   sessionName: session,
                   windowId: "@1")
    }

    // Single-pane layout: "c1e7a,220x50,0,0,1"
    func testSingleLeaf() throws {
        let layout = "c1e7a,220x50,0,0,1"
        let result = TmuxLayoutConverter.convert(
            layoutString: layout,
            windowPanes: [pane(1)],
            source: "local"
        )
        XCTAssertNotNil(result)
        guard case .leaf(let leaf) = result else {
            return XCTFail("Expected leaf, got \(String(describing: result))")
        }
        XCTAssertEqual(leaf.tmuxPaneID, "%1")
        XCTAssertEqual(leaf.source, "local")
    }

    // Horizontal split: "{left,right}"
    func testHorizontalSplit() throws {
        // 220 total, left=110, right=109
        let layout = "c1e7a,220x50,0,0{110x50,0,0,1,109x50,111,0,2}"
        let panes = [pane(1), pane(2)]
        let result = TmuxLayoutConverter.convert(
            layoutString: layout,
            windowPanes: panes,
            source: "local"
        )
        XCTAssertNotNil(result)
        guard case .split(let container) = result else {
            return XCTFail("Expected split")
        }
        XCTAssertEqual(container.axis, .horizontal)
        // ratio ≈ 110/220 = 0.5
        XCTAssertEqual(container.ratio, 0.5, accuracy: 0.01)
        guard case .leaf(let left) = container.first else { return XCTFail("Expected leaf") }
        XCTAssertEqual(left.tmuxPaneID, "%1")
        guard case .leaf(let right) = container.second else { return XCTFail("Expected leaf") }
        XCTAssertEqual(right.tmuxPaneID, "%2")
    }

    // Vertical split: "[top,bottom]"
    func testVerticalSplit() throws {
        let layout = "abcde,220x50,0,0[220x25,0,0,1,220x24,0,26,2]"
        let result = TmuxLayoutConverter.convert(
            layoutString: layout,
            windowPanes: [pane(1), pane(2)],
            source: "local"
        )
        guard case .split(let c) = result else { return XCTFail("Expected split") }
        XCTAssertEqual(c.axis, .vertical)
    }

    // Three-pane layout folds right: {A, B, C} -> split(A, split(B, C))
    func testThreePaneRightFold() throws {
        let layout = "abcde,300x50,0,0{100x50,0,0,1,100x50,101,0,2,99x50,202,0,3}"
        let result = TmuxLayoutConverter.convert(
            layoutString: layout,
            windowPanes: [pane(1), pane(2), pane(3)],
            source: "local"
        )
        guard case .split(let outer) = result else { return XCTFail("Expected outer split") }
        guard case .leaf = outer.first else { return XCTFail("Expected leaf first") }
        guard case .split = outer.second else { return XCTFail("Expected inner split second") }
    }

    // Missing pane returns nil
    func testMissingPaneReturnsNil() {
        let layout = "c1e7a,220x50,0,0,99"  // pane %99 not in windowPanes
        let result = TmuxLayoutConverter.convert(
            layoutString: layout,
            windowPanes: [],
            source: "local"
        )
        XCTAssertNil(result)
    }

    // Malformed layout returns nil
    func testMalformedLayoutReturnsNil() {
        XCTAssertNil(TmuxLayoutConverter.convert(
            layoutString: "notvalid",
            windowPanes: [],
            source: "local"
        ))
    }

    // Ratio clamping: ratio is never outside 0.1...0.9
    func testRatioIsClamped() throws {
        // Extreme ratio: left pane = 1 char of 220 total
        let layout = "abcde,220x50,0,0{1x50,0,0,1,218x50,2,0,2}"
        let result = TmuxLayoutConverter.convert(
            layoutString: layout,
            windowPanes: [pane(1), pane(2)],
            source: "local"
        )
        guard case .split(let c) = result else { return XCTFail("Expected split") }
        XCTAssertGreaterThanOrEqual(c.ratio, 0.1)
        XCTAssertLessThanOrEqual(c.ratio, 0.9)
    }
}
```

**LayoutNode BSP operations**

```swift
import XCTest
@testable import AgtmuxTermCore

final class LayoutNodeTests: XCTestCase {

    private func makeLeaf(paneID: String = "%1") -> LeafPane {
        LeafPane(tmuxPaneID: paneID, sessionName: "s", source: "local", linkedSession: .creating)
    }

    func testLeavesOnSingleLeaf() {
        let leaf = makeLeaf()
        let node = LayoutNode.leaf(leaf)
        XCTAssertEqual(node.leaves.map(\.tmuxPaneID), ["%1"])
    }

    func testSplitLeaf() {
        let original = makeLeaf(paneID: "%1")
        let node = LayoutNode.leaf(original)
        let newLeaf = makeLeaf(paneID: "%2")
        let result = node.splitLeaf(id: original.id, axis: .horizontal, newLeaf: newLeaf)
        XCTAssertNotNil(result)
        guard case .split(let c) = result else { return XCTFail("Expected split") }
        XCTAssertEqual(c.axis, .horizontal)
        XCTAssertEqual(c.first.leaves.map(\.tmuxPaneID), ["%1"])
        XCTAssertEqual(c.second.leaves.map(\.tmuxPaneID), ["%2"])
    }

    func testRemovingLeafFromSplit() {
        let a = makeLeaf(paneID: "%1")
        let b = makeLeaf(paneID: "%2")
        let container = SplitContainer(axis: .horizontal, ratio: 0.5,
                                       first: .leaf(a), second: .leaf(b))
        let node = LayoutNode.split(container)
        let result = node.removingLeaf(id: a.id)
        XCTAssertNotNil(result)
        guard case .leaf(let remaining) = result else { return XCTFail("Expected leaf") }
        XCTAssertEqual(remaining.tmuxPaneID, "%2")
    }

    func testRemovingOnlyLeafReturnsNil() {
        let leaf = makeLeaf()
        let node = LayoutNode.leaf(leaf)
        XCTAssertNil(node.removingLeaf(id: leaf.id))
    }

    func testValidateUniqueIDsPassesOnCleanTree() throws {
        let a = makeLeaf(paneID: "%1")
        let b = makeLeaf(paneID: "%2")
        let container = SplitContainer(axis: .horizontal, ratio: 0.5,
                                       first: .leaf(a), second: .leaf(b))
        let node = LayoutNode.split(container)
        XCTAssertNoThrow(try node.validateUniqueIDs())
    }

    func testLeafIDsOrder() {
        let a = makeLeaf(paneID: "%1")
        let b = makeLeaf(paneID: "%2")
        let c = makeLeaf(paneID: "%3")
        // Build: split(a, split(b, c))
        let inner = SplitContainer(axis: .horizontal, ratio: 0.5,
                                   first: .leaf(b), second: .leaf(c))
        let outer = SplitContainer(axis: .horizontal, ratio: 0.5,
                                   first: .leaf(a), second: .split(inner))
        let node = LayoutNode.split(outer)
        XCTAssertEqual(node.leaves.map(\.tmuxPaneID), ["%1", "%2", "%3"])
    }
}
```

**AgtmuxPane JSON decoding**

```swift
import XCTest
@testable import AgtmuxTermCore

final class AgtmuxSnapshotTests: XCTestCase {

    func testDecodeMinimalSnapshot() throws {
        let json = """
        {
          "version": 1,
          "panes": [
            {
              "pane_id": "%42",
              "session_name": "main",
              "window_id": "@1",
              "presence": "managed",
              "provider": "claude",
              "activity_state": "running",
              "evidence_mode": "deterministic"
            }
          ]
        }
        """.data(using: .utf8)!

        let snapshot = try AgtmuxSnapshot.decode(from: json, source: "local")
        XCTAssertEqual(snapshot.panes.count, 1)
        let p = snapshot.panes[0]
        XCTAssertEqual(p.paneId, "%42")
        XCTAssertEqual(p.source, "local")
        XCTAssertEqual(p.provider, .claude)
        XCTAssertEqual(p.activityState, .running)
        XCTAssertTrue(p.isManaged)
        XCTAssertFalse(p.needsAttention)
    }

    func testNeedsAttentionForWaitingApproval() throws {
        let pane = AgtmuxPane(source: "local", paneId: "%1", sessionName: "s",
                              windowId: "@1", activityState: .waitingApproval)
        XCTAssertTrue(pane.needsAttention)
    }

    func testPrimaryLabelManagedPane() {
        let pane = AgtmuxPane(source: "local", paneId: "%1", sessionName: "s",
                              windowId: "@1", presence: .managed,
                              provider: .claude,
                              conversationTitle: "Fix the bug")
        XCTAssertEqual(pane.primaryLabel, "Fix the bug")
    }

    func testPrimaryLabelFallsBackToProvider() {
        let pane = AgtmuxPane(source: "local", paneId: "%1", sessionName: "s",
                              windowId: "@1", presence: .managed,
                              provider: .codex)
        XCTAssertEqual(pane.primaryLabel, "codex")
    }
}
```

### Running the tests

```bash
# After the Package.swift target split and file moves:
swift test --filter AgtmuxTermCoreTests
# Expected: all pass, no GhosttyKit linkage needed
```

---

## 2. Integration Tests (tmux subprocess)

Note: the linked-session examples below are historical analysis of the older workspace path, not current product direction. The active product path is `WorkbenchStoreV2` direct attach to exact sessions, so new integration/E2E work should prefer V2 direct-attach proofs and should not add fresh `LinkedSessionManager` coverage.

### Approach

`TmuxCommandRunner` and `LinkedSessionManager` both spawn real `tmux` subprocesses via `Process`. These are testable with a real local tmux session (tmux 3.6a is installed at `/opt/homebrew/bin/tmux`).

The actors are currently concrete singletons. The recommended approach is:

1. **Protocol-abstract the runner** — introduce a `TmuxRunner` protocol and inject it into `LinkedSessionManager`. In tests, inject a `MockTmuxRunner` that returns canned responses or delegates to a real isolated test session.
2. **Real-tmux integration tests** — create a throw-away tmux session in `setUp()` and kill it in `tearDown()`. These tests run in the test process; no app launch needed.

### Concrete integration test pattern

```swift
import XCTest

// Protocol that TmuxCommandRunner conforms to (add to production code)
protocol TmuxRunning: Actor {
    func run(_ args: [String], source: String) async throws -> String
}

// Fake implementation for unit tests
actor MockTmuxRunner: TmuxRunning {
    var responses: [String: String] = [:]
    var callLog: [[String]] = []

    func run(_ args: [String], source: String) async throws -> String {
        callLog.append(args)
        let key = args.joined(separator: " ")
        guard let response = responses[key] else {
            throw TmuxCommandError.failed(args: args, code: 1, stderr: "no mock")
        }
        return response
    }
}

// Real-tmux integration test (requires tmux in PATH)
final class LinkedSessionIntegrationTests: XCTestCase {
    private var testSessionName: String!

    override func setUp() async throws {
        testSessionName = "agtmux-test-\(Int.random(in: 100000...999999))"
        // Create a real isolated parent session for the test
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "new-session", "-d", "-s", testSessionName]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("tmux not available or session creation failed")
        }
    }

    override func tearDown() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "kill-session", "-t", testSessionName]
        try? process.run()
        process.waitUntilExit()
    }

    func testCreateLinkedSessionAndNavigate() async throws {
        // This exercises the exact sequence from LinkedSessionManager.createSession()
        // without the Ghostty dependency.
        let runner = TmuxCommandRunner.shared
        let linkedName = "agtmux-\(UUID().uuidString)"

        // Step 1: create linked session
        try await runner.run(
            ["new-session", "-d", "-s", linkedName, "-t", testSessionName],
            source: "local"
        )

        // Verify it exists
        let listOutput = try await runner.run(
            ["list-sessions", "-F", "#{session_name}"],
            source: "local"
        )
        XCTAssertTrue(listOutput.contains(linkedName), "Linked session should exist")

        // Step 2: kill it
        try await runner.run(["kill-session", "-t", linkedName], source: "local")

        let listAfter = try await runner.run(
            ["list-sessions", "-F", "#{session_name}"],
            source: "local"
        )
        XCTAssertFalse(listAfter.contains(linkedName), "Linked session should be gone")
    }
}
```

### TmuxControlMode line parser tests (with protocol extraction)

`TmuxControlMode.parseLine` is currently `private`. Making it `internal` (or using `@testable import`) allows testing the parser in isolation:

```swift
final class TmuxControlModeParserTests: XCTestCase {

    // These test the line-parsing logic independent of the subprocess.

    func testLayoutChangeLine() async throws {
        let mode = TmuxControlMode(sessionName: "test", source: "local")
        var received: ControlModeEvent?

        // Observe events by subscribing before parsing
        // (In practice, expose an internal helper or make parseLine internal)

        // Expected: .layoutChange(windowId: "@1", layout: "abc,100x50,0,0,1", isCurrent: true)
        // Test by calling internal method or via subprocess stub
    }
}
```

Because `parseLine` is private and the actor is not injectable, the near-term approach is:
- Make `parseLine` `internal` (not public, just accessible to `@testable import`)
- Use `MainActor.run {}` in test for actor-isolated setup

### Feasibility assessment

Real-tmux integration tests: **GO** with moderate effort. The critical path is:
1. Add `TmuxRunner` protocol (one-hour refactor)
2. Add `Tests/` directory and `testTarget` to Package.swift
3. Write `setUp/tearDown` session lifecycle helpers

These tests will run reliably in CI as long as tmux is installed (it is on the developer machine; add to CI environment setup).

---

## 3. UI / E2E Tests

### Feasibility

**NO-GO for XCUITest** without generating an Xcode project. XCUITest requires:
- An `.xcodeproj` or `.xcworkspace`
- An `.xctestplan`
- The test bundle to be signed with the same team as the app

SwiftPM has no built-in support for XCUITest targets. `swift package generate-xcodeproj` was deprecated in Xcode 14 and removed in Xcode 15+.

### Option A: Generate Xcode project with Tuist or XcodeGen

[Tuist](https://tuist.io) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) can generate a `.xcodeproj` from a manifest that references existing SwiftPM dependencies, including a `binaryTarget`. This enables XCUITest.

Effort: Medium. Must maintain the Tuist/XcodeGen manifest alongside `Package.swift`. The GhosttyKit XCFramework binary target is fully supported by both tools.

Once an Xcode project is generated:

```swift
// UI test target (requires Xcode project)
import XCTest

final class SidebarPaneTapTests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testTapPaneRowOpensTerminalTile() throws {
        // Prerequisite: at least one tmux session running locally
        let sidebarList = app.scrollViews.firstMatch
        let firstPaneRow = sidebarList.staticTexts.element(boundBy: 0)
        XCTAssertTrue(firstPaneRow.waitForExistence(timeout: 3))
        firstPaneRow.tap()

        // After tap, a GhosttyPaneTile should appear in the workspace area
        // (identified by accessibility label set on the tile)
        let tile = app.otherElements["GhosttyPaneTile"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5),
                      "Terminal tile should appear after pane tap")
    }
}
```

This test directly reproduces the crash scenario (sidebar pane tap -> placePane).

### Option B: Accessibility API from a separate process

macOS Accessibility API (`AXUIElement`) can drive the app from an external test runner without Xcode:

```swift
import ApplicationServices

// External test harness (plain Swift executable or XCTest in a separate SwiftPM target)
let appRef = AXUIElementCreateApplication(pid)
// Traverse element tree and simulate tap on a pane row
// AXPress on the element triggers the same code path as a real click
```

Limitation: this requires the app to have the `NSAppleScriptEnabled` entitlement or for the test process to have accessibility permissions granted. It works but is fragile compared to XCUITest.

### Option C: Testable app mode with launch argument

Add a `--uitest` launch argument that makes `main.swift` skip `ghostty_init()` and `GhosttyApp.shared`, inject a stub layout, and start a headless NSApplication loop. This allows SwiftPM test targets to exercise WorkspaceStore / SidebarView logic in-process without Metal/Ghostty:

```swift
// main.swift (modified)
if CommandLine.arguments.contains("--uitest-headless") {
    // Skip Ghostty init, run minimal loop for automated testing
    // WorkspaceStore and AppViewModel are still exercised
    HeadlessTestRunner.run()
} else {
    // Normal launch path
    let ghosttyInitResult = ghostty_init(...)
    ...
    app.run()
}
```

This is the lowest-effort path to exercising `placePane` without Metal.

### Recommendation

For the crash investigation specifically, Option C (headless launch argument) is the highest-value, lowest-cost approach. XCUITest via Tuist/XcodeGen is the correct long-term investment.

---

## 4. Crash Investigation — placePane crash

### Observed symptom

"pane item を選択すると、main panel にロードされずに、crash します"

Pane tap in SidebarView → `workspaceStore.placePane(pane)` → async task → `LinkedSessionManager.createSession()` → leaf transitions to `.ready(linkedName)` → `_GhosttyNSView.updateNSView` is called → `GhosttyApp.shared.newSurface(for:command:)` → `ghostty_surface_new()` → crash.

### Crash site analysis

Looking at `_GhosttyNSView.updateNSView` (WorkspaceArea.swift:373–397):

```swift
func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
    let cmd = attachCommand       // non-nil only when leaf.linkedSession == .ready
    if context.coordinator.currentCommand != cmd {
        context.coordinator.currentCommand = cmd
        if let cmd,
           let surface = GhosttyApp.shared.newSurface(for: nsView, command: cmd) {
            nsView.attachSurface(surface)
            SurfacePool.shared.register(view: nsView, ...)
        }
    }
    ...
}
```

`attachCommand` in `GhosttyPaneTile` is:

```swift
private var attachCommand: String? {
    guard case .ready(let sessionTarget) = leaf.linkedSession else { return nil }
    let base = "tmux attach-session -t \(sessionTarget)"
    ...
}
```

### Root cause hypotheses

**Hypothesis 1 (most likely): ghostty_surface_new called before the NSView has a window (no Metal layer context)**

`GhosttyTerminalView` is an `NSViewRepresentable`. `updateNSView` can be called by SwiftUI before the view is inserted into the window hierarchy (i.e., before `viewWillAppear` / `addedToWindow`). At that point `view.window` is nil and `NSScreen.main` may return nil. `ghostty_surface_new` passes `nsview` as a raw `UnsafeRawPointer` to libghostty which accesses the CAMetalLayer immediately. If the view is not yet in a window, the Metal layer may have no drawable, causing a null dereference inside libghostty.

Evidence: `ghostty_surface_config_s.scale_factor` is set as `NSScreen.main?.backingScaleFactor ?? 1.0` — if `NSScreen.main` is nil, this is 1.0 (safe), but the `nsview` pointer itself being unhoped is the real risk.

**Hypothesis 2: tmux linked session name refers to a non-existent session**

If `LinkedSessionManager.createSession()` completes and returns a name but the tmux session was immediately killed (e.g., by a race with `tearDown` or by the parent session exiting), the `tmux attach-session -t <linkedName>` command embedded in `attachCommand` will fail. Ghostty's `ghostty_surface_new` creates a PTY and runs the command — if tmux exits immediately with an error, libghostty may crash trying to read from a closed PTY.

**Hypothesis 3: Double-surface creation on rapid tap**

If the user taps the same pane row twice quickly, `placePane` is called twice. The first call creates a `LeafPane` and starts an async task. The second call replaces the root (because `splitLeaf` fails and falls back to `tabs[idx].root = .leaf(newLeaf)`). When the first async task completes, it calls `updateLeaf(id: leafID1, ...)`. But `leafID1` is no longer in the tree, so `updateLeaf` silently does nothing — however, the `_GhosttyNSView` for the second leaf may be in a partially initialized state.

### Recommended debugging approach

**Step 1: Add symbolic breakpoints in Xcode or lldb**

```
# Attach lldb to the running process
xcrun lldb -n AgtmuxTerm
(lldb) breakpoint set --name ghostty_surface_new
(lldb) continue
# Trigger the crash via pane tap
# Inspect: po nsView, po nsView.window
```

If `nsView.window` is nil at the breakpoint, Hypothesis 1 is confirmed.

**Step 2: Add a guard in updateNSView (short-term mitigation)**

```swift
func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
    let cmd = attachCommand
    if context.coordinator.currentCommand != cmd {
        context.coordinator.currentCommand = cmd
        // Guard: do not create surface until the view is in a window
        guard nsView.window != nil else { return }
        if let cmd,
           let surface = GhosttyApp.shared.newSurface(for: nsView, command: cmd) {
            nsView.attachSurface(surface)
            SurfacePool.shared.register(view: nsView, leafID: leafID, tmuxPaneID: tmuxPaneID)
        }
    }
}
```

This makes the behavior deterministic: surface creation is deferred until the view's window is available.

**Step 3: Verify tmux session exists before transitioning to .ready**

In `LinkedSessionManager.createSession()`, add a verification step after `select-window`:

```swift
// After select-window, confirm the session is listed
let verify = try await TmuxCommandRunner.shared.run(
    ["list-sessions", "-F", "#{session_name}", "-f",
     "#{==:#{session_name},\(name)}"],
    source: source
)
guard verify.contains(name) else {
    throw TmuxCommandError.failed(args: ["verify"], code: 1,
                                  stderr: "Session \(name) not found after creation")
}
```

**Step 4: Unit test the guard (verifiable without app launch)**

```swift
func testUpdateNSViewDoesNotCreateSurfaceWithoutWindow() {
    // Create a GhosttyTerminalView not added to any window
    let view = GhosttyTerminalView()
    XCTAssertNil(view.window, "View should have no window")
    // After the guard is added: surface should remain nil
    XCTAssertNil(view.surface, "Surface should not be created without a window")
}
```

### Crash flow summary

```
SidebarView.onTapGesture
  └─ Task { await workspaceStore.placePane(pane) }
       └─ LeafPane(linkedSession: .creating) inserted into BSP tree
       └─ Task { LinkedSessionManager.createSession() }
            └─ tmux new-session + select-window
            └─ updateLeaf(id:, linkedSession: .ready("agtmux-uuid"))
                 └─ SwiftUI rerender: GhosttyPaneTile.body
                      └─ attachCommand becomes non-nil
                      └─ _GhosttyNSView.updateNSView
                           └─ GhosttyApp.shared.newSurface(for: view, command: cmd)
                                └─ ghostty_surface_new(app, &cfg)
                                     └─ CRASH (likely: view.window == nil or PTY issue)
```

---

## 5. Recommended Next Steps

In priority order:

### P0 — Crash fix (this week)

1. **Add `guard nsView.window != nil else { return }` in `_GhosttyNSView.updateNSView`** before calling `GhosttyApp.shared.newSurface`. This is a 3-line change. After the guard, SwiftUI will call `updateNSView` again once the view is in the window hierarchy (because the coordinator's `currentCommand` was not set), at which point the surface creation will proceed safely.

2. **Confirm with lldb** that `nsView.window` is indeed nil at the crash site before shipping the fix.

### P1 — Unit test infrastructure (this sprint)

3. **Split Package.swift** into `AgtmuxTermCore` (library, no GhosttyKit) and `AgtmuxTerm` (executable). Move `LayoutNode.swift`, `TmuxLayoutConverter.swift`, and `DaemonModels.swift` to `Sources/AgtmuxTermCore/`. Add `testTarget`.

4. **Write and run the unit tests** from Section 1. Estimated: 2–3 hours including Package.swift changes. These will catch regressions in the BSP tree logic and the layout string parser, which are the most complex pure-logic components.

5. **Make `TmuxControlMode.parseLine` internal** so it can be tested via `@testable import` without subprocess involvement.

### P2 — Integration tests (next sprint)

6. **Add `TmuxRunner` protocol** and inject it into `LinkedSessionManager`. Write integration tests that create a real tmux session in `setUp` and verify the full `createSession` → verify → `destroySession` lifecycle.

7. **Add CI guard**: `swift test` in the CI pipeline (GitHub Actions / local). Tests that touch real tmux should be tagged `Integration` and skipped in environments without tmux.

### P3 — UI testing (backlog)

8. **Evaluate Tuist** for generating an Xcode project from the existing SwiftPM manifest. The GhosttyKit XCFramework is fully Tuist-compatible. This unblocks XCUITest and would allow the sidebar-tap crash to be covered by an automated regression test.

9. **Alternatively: headless launch mode** (`--uitest-headless` argument in `main.swift`). Lower effort than Tuist, but tests less of the real stack.

---

## Appendix: Test infrastructure file layout

```
Tests/
  AgtmuxTermCoreTests/
    TmuxLayoutConverterTests.swift
    LayoutNodeTests.swift
    AgtmuxSnapshotTests.swift
    WorkspaceStoreTests.swift      # @MainActor, BSP mutations only
  AgtmuxTermIntegrationTests/      # requires tmux in PATH
    LinkedSessionIntegrationTests.swift
    TmuxCommandRunnerTests.swift
Sources/
  AgtmuxTermCore/                  # NEW: no AppKit, no GhosttyKit
    LayoutNode.swift
    TmuxLayoutConverter.swift
    DaemonModels.swift
  AgtmuxTerm/                      # existing executable
    main.swift
    GhosttyApp.swift
    GhosttyTerminalView.swift
    ... (all files with AppKit/GhosttyKit imports)
```

This layout keeps `swift test` fast (Core tests have no framework deps) while allowing integration tests to be run selectively.
