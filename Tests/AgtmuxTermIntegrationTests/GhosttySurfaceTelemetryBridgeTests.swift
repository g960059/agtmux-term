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
            workbenchID: UUID(),
            tileID: UUID(),
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
            workbenchID: UUID(),
            tileID: UUID(),
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
