import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore
import GhosttyKit

final class GhosttySurfaceTelemetryBridgeTests: XCTestCase {
    @MainActor
    func testRecordIfTelemetryActionUpdatesRegisteredSurfaceClientTTY() throws {
        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9912)
        let context = GhosttyTerminalSurfaceContext(
            viewportID: UUID(),
            surfaceID: UUID(),
            surfaceKey: "wb:main",
            sessionRef: SessionRef(target: .local, sessionName: "main")
        )
        registry.register(
            surfaceHandle: surfaceHandle,
            context: context,
            attachCommand: "tmux attach-session -t main"
        )

        let consumed = try withCustomOSCAction(osc: GhosttySurfaceTelemetryBridge.command, payload: "/dev/ttys008") { action in
            try GhosttySurfaceTelemetryBridge.recordIfTelemetryAction(
                target: makeSurfaceTarget(surfaceHandle),
                action: action,
                registry: registry
            )
        }

        XCTAssertTrue(consumed)
        XCTAssertEqual(registry.renderedState(forSurfaceHandle: surfaceHandle)?.clientTTY, "/dev/ttys008")
        XCTAssertEqual(registry.renderedState(forSurfaceHandle: surfaceHandle)?.generation, 1)
    }

    @MainActor
    func testRecordIfTelemetryActionIgnoresNonTelemetryOSC() throws {
        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9913)
        let context = GhosttyTerminalSurfaceContext(
            viewportID: UUID(),
            surfaceID: UUID(),
            surfaceKey: "wb:main",
            sessionRef: SessionRef(target: .local, sessionName: "main")
        )
        registry.register(
            surfaceHandle: surfaceHandle,
            context: context,
            attachCommand: "tmux attach-session -t main"
        )

        let consumed = try withCustomOSCAction(osc: 7000, payload: "/dev/ttys008") { action in
            try GhosttySurfaceTelemetryBridge.recordIfTelemetryAction(
                target: makeSurfaceTarget(surfaceHandle),
                action: action,
                registry: registry
            )
        }

        XCTAssertFalse(consumed)
        XCTAssertNil(registry.renderedState(forSurfaceHandle: surfaceHandle)?.clientTTY)
    }

    @MainActor
    func testRecordIfTelemetryActionRejectsEmptyTTY() throws {
        let registry = GhosttyTerminalSurfaceRegistry()

        XCTAssertThrowsError(
            try withCustomOSCAction(osc: GhosttySurfaceTelemetryBridge.command, payload: "") { action in
                try GhosttySurfaceTelemetryBridge.recordIfTelemetryAction(
                    target: makeAppTarget(),
                    action: action,
                    registry: registry
                )
            }
        ) { error in
            XCTAssertEqual(error as? GhosttySurfaceTelemetryBridgeError, .emptyClientTTY)
        }
    }

    @MainActor
    func testResolvedTerminalViewFallsBackToRegistrySurfaceIDWhenSurfaceHandleMappingDrifts() {
        let callbackHandle = GhosttySurfaceHandle(rawValue: 0x9914)
        let poolHandle = GhosttySurfaceHandle(rawValue: 0x9915)
        let surfaceID = UUID()
        let view = GhosttyTerminalView()
        let context = GhosttyTerminalSurfaceContext(
            viewportID: UUID(),
            surfaceID: surfaceID,
            surfaceKey: "main-terminal:local:alpha",
            sessionRef: SessionRef(target: .local, sessionName: "alpha")
        )

        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        defer {
            GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
            SurfacePool.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        }

        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: callbackHandle,
            context: context,
            attachCommand: "tmux attach-session -t alpha"
        )
        SurfacePool.shared.register(
            view: view,
            leafID: surfaceID,
            tmuxPaneID: "%1",
            surfaceHandle: poolHandle
        )

        XCTAssertTrue(
            GhosttyApp.resolvedTerminalViewForTesting(surfaceHandle: callbackHandle) === view
        )
    }

    @MainActor
    func testResolvedTerminalViewPrefersActiveSurfaceOverInactiveHandleMapping() {
        let callbackHandle = GhosttySurfaceHandle(rawValue: 0x9916)
        let activePoolHandle = GhosttySurfaceHandle(rawValue: 0x9917)
        let activeSurfaceID = UUID()
        let inactiveSurfaceID = UUID()
        let activeView = GhosttyTerminalView()
        let inactiveView = GhosttyTerminalView()
        let context = GhosttyTerminalSurfaceContext(
            viewportID: UUID(),
            surfaceID: activeSurfaceID,
            surfaceKey: "main-terminal:local:beta",
            sessionRef: SessionRef(target: .local, sessionName: "beta")
        )

        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        defer {
            GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
            SurfacePool.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        }

        SurfacePool.shared.register(
            view: activeView,
            leafID: activeSurfaceID,
            tmuxPaneID: "%2",
            surfaceHandle: activePoolHandle
        )
        SurfacePool.shared.register(
            view: inactiveView,
            leafID: inactiveSurfaceID,
            tmuxPaneID: "%3",
            surfaceHandle: callbackHandle
        )
        SurfacePool.shared.background(leafID: inactiveSurfaceID)
        TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(
            activeSurfaceID,
            forSurfaceID: activeSurfaceID
        )
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: callbackHandle,
            context: context,
            attachCommand: "tmux attach-session -t beta"
        )

        XCTAssertTrue(
            GhosttyApp.resolvedTerminalViewForTesting(surfaceHandle: callbackHandle) === activeView
        )
    }

    private func withCustomOSCAction<T>(
        osc: UInt16,
        payload: String,
        body: (ghostty_action_s) throws -> T
    ) throws -> T {
        let payloadBytes = Array(payload.utf8)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, payloadBytes.count))
        if payloadBytes.isEmpty {
            buffer.initialize(to: 0)
        } else {
            buffer.initialize(from: payloadBytes, count: payloadBytes.count)
        }
        defer {
            buffer.deinitialize(count: max(1, payloadBytes.count))
            buffer.deallocate()
        }

        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_CUSTOM_OSC,
            action: ghostty_action_u(
                custom_osc: ghostty_action_custom_osc_s(
                    osc: osc,
                    payload: buffer,
                    len: UInt(payloadBytes.count)
                )
            )
        )
        return try body(action)
    }

    private func makeSurfaceTarget(_ surfaceHandle: GhosttySurfaceHandle) -> ghostty_target_s {
        ghostty_target_s(
            tag: GHOSTTY_TARGET_SURFACE,
            target: ghostty_target_u(
                surface: UnsafeMutableRawPointer(bitPattern: surfaceHandle.rawValue)!
            )
        )
    }

    private func makeAppTarget() -> ghostty_target_s {
        ghostty_target_s(
            tag: GHOSTTY_TARGET_APP,
            target: ghostty_target_u(surface: nil)
        )
    }
}
