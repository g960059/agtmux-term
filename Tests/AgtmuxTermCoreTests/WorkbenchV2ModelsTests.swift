import XCTest
@testable import AgtmuxTermCore

final class WorkbenchV2ModelsTests: XCTestCase {
    func testWorkbenchCodableRoundTripPreservesSplitTree() throws {
        let terminal = WorkbenchTile(
            kind: .terminal(
                sessionRef: SessionRef(
                    target: .local,
                    sessionName: "dev",
                    lastSeenSessionID: "$1",
                    lastSeenRepoRoot: "/tmp/dev"
                )
            )
        )
        let browser = WorkbenchTile(
            kind: .browser(
                url: URL(string: "https://example.com/docs")!,
                sourceContext: "/tmp/dev"
            ),
            pinned: true
        )
        let document = WorkbenchTile(
            kind: .document(
                ref: DocumentRef(
                    target: .remote(hostKey: "staging"),
                    path: "/srv/app/README.md"
                )
            ),
            pinned: true
        )

        let root = WorkbenchNode.split(
            WorkbenchSplit(
                axis: .horizontal,
                ratio: 0.6,
                first: .tile(terminal),
                second: .split(
                    WorkbenchSplit(
                        axis: .vertical,
                        ratio: 0.5,
                        first: .tile(browser),
                        second: .tile(document)
                    )
                )
            )
        )

        let workbench = Workbench(
            title: "Docs",
            root: root,
            focusedTileID: document.id
        )

        let data = try JSONEncoder().encode(workbench)
        let decoded = try JSONDecoder().decode(Workbench.self, from: data)

        XCTAssertEqual(decoded, workbench)
        XCTAssertEqual(decoded.tiles.map(\.id), [terminal.id, browser.id, document.id])
    }

    func testTerminalTileNeverStaysPinned() {
        let tile = WorkbenchTile(
            kind: .terminal(
                sessionRef: SessionRef(target: .local, sessionName: "ops")
            ),
            pinned: true
        )

        XCTAssertFalse(tile.pinned)
    }

    func testReplacingTileReturnsUpdatedTree() {
        let first = WorkbenchTile(kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "one")))
        let second = WorkbenchTile(
            kind: .document(
                ref: DocumentRef(target: .local, path: "/tmp/spec.md")
            ),
            pinned: true
        )
        let replacement = WorkbenchTile(
            kind: .browser(
                url: URL(string: "https://example.com")!,
                sourceContext: nil
            ),
            pinned: true
        )

        let node = WorkbenchNode.split(
            WorkbenchSplit(
                axis: .horizontal,
                first: .tile(first),
                second: .tile(second)
            )
        )

        let updated = node.replacing(tileID: second.id, with: .tile(replacement))

        XCTAssertEqual(updated?.tiles.map(\.id), [first.id, replacement.id])
    }
}
