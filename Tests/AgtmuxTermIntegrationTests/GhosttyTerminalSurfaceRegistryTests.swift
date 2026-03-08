import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore
import GhosttyKit

final class GhosttyTerminalSurfaceRegistryTests: XCTestCase {
    @MainActor
    func testRegisterResolveAndUnregisterContextBySurfaceHandle() {
        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x101)
        let context = makeContext(
            tileID: UUID(),
            target: .remote(hostKey: "edge"),
            sessionName: "backend",
            repoRoot: "/srv/backend"
        )

        registry.register(surfaceHandle: surfaceHandle, context: context, attachCommand: "tmux attach-session -t backend")

        XCTAssertEqual(registry.context(forSurfaceHandle: surfaceHandle), context)
        XCTAssertEqual(registry.context(forSurfaceHandle: surfaceHandle)?.sourceTarget, .remote(hostKey: "edge"))
        XCTAssertEqual(registry.context(forSurfaceHandle: surfaceHandle)?.lastSeenRepoRoot, "/srv/backend")
        XCTAssertEqual(registry.context(forTarget: makeSurfaceTarget(surfaceHandle)), context)
        XCTAssertEqual(
            registry.renderedState(forSurfaceHandle: surfaceHandle)?.attachCommand,
            "tmux attach-session -t backend"
        )
        XCTAssertEqual(registry.renderedState(forSurfaceHandle: surfaceHandle)?.generation, 1)
        XCTAssertNil(registry.renderedState(forSurfaceHandle: surfaceHandle)?.clientTTY)

        registry.unregister(surfaceHandle: surfaceHandle)

        XCTAssertNil(registry.context(forSurfaceHandle: surfaceHandle))
        XCTAssertNil(registry.context(forTarget: makeSurfaceTarget(surfaceHandle)))
    }

    @MainActor
    func testRegisterOverwritesExistingSurfaceMappingWhenTileReattaches() {
        let registry = GhosttyTerminalSurfaceRegistry()
        let tileID = UUID()
        let firstHandle = GhosttySurfaceHandle(rawValue: 0x201)
        let secondHandle = GhosttySurfaceHandle(rawValue: 0x202)
        let first = makeContext(
            tileID: tileID,
            target: .local,
            sessionName: "main",
            repoRoot: "/tmp/old"
        )
        let second = makeContext(
            tileID: tileID,
            target: .local,
            sessionName: "main",
            repoRoot: "/tmp/new"
        )

        registry.register(surfaceHandle: firstHandle, context: first, attachCommand: "tmux attach-session -t main")
        registry.register(surfaceHandle: secondHandle, context: second, attachCommand: "tmux select-pane -t %4 \\; attach-session -t main")

        XCTAssertNil(registry.context(forSurfaceHandle: firstHandle))
        XCTAssertEqual(registry.context(forSurfaceHandle: secondHandle), second)
        XCTAssertEqual(registry.context(forSurfaceHandle: secondHandle)?.lastSeenRepoRoot, "/tmp/new")
        XCTAssertEqual(registry.surfaceHandle(forTileID: tileID), secondHandle)
        XCTAssertEqual(
            registry.renderedState(forTileID: tileID)?.attachCommand,
            "tmux select-pane -t %4 \\; attach-session -t main"
        )
        XCTAssertEqual(registry.renderedState(forTileID: tileID)?.generation, 2)
    }

    @MainActor
    func testRegisterOverwritesExistingTileMappingWhenSurfaceHandleIsReused() {
        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x301)
        let firstTileID = UUID()
        let secondTileID = UUID()
        let first = makeContext(
            tileID: firstTileID,
            target: .local,
            sessionName: "main"
        )
        let second = makeContext(
            tileID: secondTileID,
            target: .remote(hostKey: "ops"),
            sessionName: "release"
        )

        registry.register(surfaceHandle: surfaceHandle, context: first, attachCommand: "tmux attach-session -t main")
        registry.register(surfaceHandle: surfaceHandle, context: second, attachCommand: "tmux attach-session -t release")

        XCTAssertNil(registry.surfaceHandle(forTileID: firstTileID))
        XCTAssertEqual(registry.surfaceHandle(forTileID: secondTileID), surfaceHandle)
        XCTAssertEqual(registry.context(forSurfaceHandle: surfaceHandle), second)
        XCTAssertEqual(registry.renderedState(forSurfaceHandle: surfaceHandle)?.generation, 1)
    }

    @MainActor
    func testGenerationOnlyAdvancesWhenAttachCommandOrTileChanges() {
        let registry = GhosttyTerminalSurfaceRegistry()
        let tileID = UUID()
        let firstHandle = GhosttySurfaceHandle(rawValue: 0x401)
        let secondHandle = GhosttySurfaceHandle(rawValue: 0x402)
        let context = makeContext(
            tileID: tileID,
            target: .local,
            sessionName: "main"
        )

        registry.register(surfaceHandle: firstHandle, context: context, attachCommand: "tmux attach-session -t main")
        registry.register(surfaceHandle: secondHandle, context: context, attachCommand: "tmux attach-session -t main")
        XCTAssertEqual(registry.renderedState(forTileID: tileID)?.generation, 1)

        registry.register(
            surfaceHandle: secondHandle,
            context: context,
            attachCommand: "tmux select-pane -t %5 \\; attach-session -t main"
        )
        XCTAssertEqual(registry.renderedState(forTileID: tileID)?.generation, 2)
    }

    @MainActor
    func testRegisterClientTTYAugmentsRenderedStateWithoutAdvancingGeneration() throws {
        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x501)
        let context = makeContext(
            tileID: UUID(),
            target: .local,
            sessionName: "main"
        )

        registry.register(
            surfaceHandle: surfaceHandle,
            context: context,
            attachCommand: "tmux attach-session -t main"
        )

        try registry.register(clientTTY: "/dev/ttys008", forSurfaceHandle: surfaceHandle)

        let renderedState = try XCTUnwrap(registry.renderedState(forSurfaceHandle: surfaceHandle))
        XCTAssertEqual(renderedState.attachCommand, "tmux attach-session -t main")
        XCTAssertEqual(renderedState.clientTTY, "/dev/ttys008")
        XCTAssertEqual(renderedState.generation, 1)
    }

    private func makeContext(
        tileID: UUID,
        target: TargetRef,
        sessionName: String,
        repoRoot: String? = nil
    ) -> GhosttyTerminalSurfaceContext {
        GhosttyTerminalSurfaceContext(
            workbenchID: UUID(),
            tileID: tileID,
            surfaceKey: "workbench-v2:\(sessionName)",
            sessionRef: SessionRef(
                target: target,
                sessionName: sessionName,
                lastSeenRepoRoot: repoRoot
            )
        )
    }

    private func makeSurfaceTarget(_ surfaceHandle: GhosttySurfaceHandle) -> ghostty_target_s {
        ghostty_target_s(
            tag: GHOSTTY_TARGET_SURFACE,
            target: ghostty_target_u(
                surface: UnsafeMutableRawPointer(bitPattern: surfaceHandle.rawValue)!
            )
        )
    }
}
