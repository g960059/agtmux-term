import XCTest
import AppKit
import AgtmuxTermCore
@testable import AgtmuxTerm

@MainActor
final class UITestTmuxBridgeTests: XCTestCase {
    func testTerminalViewInWindowRequirementDoesNotRequireRenderedState() {
        let terminalView = GhosttyTerminalView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        container.addSubview(terminalView)

        XCTAssertTrue(
            TerminalViewRegistrationRequirement.terminalViewInWindow.isSatisfied(
                terminalView: terminalView,
                renderedState: nil
            )
        )
        XCTAssertFalse(
            TerminalViewRegistrationRequirement.terminalViewInWindowAndRenderedState.isSatisfied(
                terminalView: terminalView,
                renderedState: nil
            )
        )
    }

    func testTerminalViewInWindowRequirementStillRequiresWindowAttachment() {
        let surfaceID = UUID()
        let renderedState = GhosttyRenderedTerminalSurfaceState(
            context: GhosttyTerminalSurfaceContext(
                viewportID: UUID(),
                surfaceID: surfaceID,
                surfaceKey: "main-terminal:local:alpha",
                sessionRef: SessionRef(target: .local, sessionName: "alpha")
            ),
            attachCommand: "tmux attach-session -t alpha",
            clientTTY: "/dev/ttys001",
            generation: 1
        )

        XCTAssertFalse(
            TerminalViewRegistrationRequirement.terminalViewInWindow.isSatisfied(
                terminalView: GhosttyTerminalView(),
                renderedState: renderedState
            )
        )
        XCTAssertFalse(
            TerminalViewRegistrationRequirement.terminalViewInWindowAndRenderedState.isSatisfied(
                terminalView: GhosttyTerminalView(),
                renderedState: renderedState
            )
        )
    }
}
