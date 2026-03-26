import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore
import GhosttyKit

final class GhosttyCLIOSCBridgeTests: XCTestCase {
    func testDecodeActionParsesBindClientPayload() throws {
        let payload = """
        {"version":1,"action":"bind_client","client_tty":"/dev/ttys008"}
        """

        XCTAssertEqual(
            try GhosttyCLIOSCBridge.decodeAction(from: Data(payload.utf8)),
            .bindClientTTY("/dev/ttys008")
        )
    }

    func testDecodeActionRejectsEmptyBindClientTTY() {
        let payload = """
        {"version":1,"action":"bind_client","client_tty":""}
        """

        XCTAssertThrowsError(
            try GhosttyCLIOSCBridge.decodeAction(from: Data(payload.utf8))
        ) { error in
            XCTAssertEqual(error as? GhosttyCLIOSCBridgeError, .emptyClientTTY)
        }
    }

    @MainActor
    func testDispatchIfBridgeActionRegistersClientTTYOnRenderedSurface() throws {
        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9911)
        let context = GhosttyTerminalSurfaceContext(
            viewportID: UUID(),
            surfaceID: UUID(),
            surfaceKey: "main:session",
            sessionRef: SessionRef(target: .local, sessionName: "main")
        )
        registry.register(
            surfaceHandle: surfaceHandle,
            context: context,
            attachCommand: "tmux attach-session -t main"
        )

        let result = try withCustomOSCAction(
            osc: GhosttyCLIOSCBridge.command,
            payload: #"{"version":1,"action":"bind_client","client_tty":"/dev/ttys011"}"#
        ) { action in
            try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                target: makeSurfaceTarget(surfaceHandle),
                action: action,
                registry: registry
            )
        }

        XCTAssertEqual(result, .boundClientTTY("/dev/ttys011"))
        XCTAssertEqual(
            registry.renderedState(forSurfaceHandle: surfaceHandle)?.clientTTY,
            "/dev/ttys011"
        )
    }

    @MainActor
    func testDispatchIfBridgeActionRejectsUnsupportedTarget() throws {
        let registry = GhosttyTerminalSurfaceRegistry()

        XCTAssertThrowsError(
            try withCustomOSCAction(
                osc: GhosttyCLIOSCBridge.command,
                payload: #"{"version":1,"action":"bind_client","client_tty":"/dev/ttys012"}"#
            ) { action in
                try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                    target: makeAppTarget(),
                    action: action,
                    registry: registry
                )
            }
        ) { error in
            XCTAssertEqual(
                error as? GhosttyCLIOSCBridgeError,
                .surfaceResolution(.unsupportedTarget)
            )
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
