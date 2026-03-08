import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

@MainActor
final class WorkbenchStoreV2PersistenceTests: XCTestCase {
    func testLaunchLoadsPersistedSnapshotWhenFixtureEnvironmentIsAbsent() throws {
        let persistedTerminalRef = SessionRef(
            target: .remote(hostKey: "edge"),
            sessionName: "backend",
            lastSeenSessionID: "$12",
            lastSeenRepoRoot: "/srv/backend"
        )
        let persistedTerminalTile = WorkbenchTile(
            kind: .terminal(sessionRef: persistedTerminalRef)
        )
        let persistedWorkbenches = [
            Workbench.empty(title: "Inbox"),
            Workbench(
                title: "Persisted",
                root: .tile(persistedTerminalTile),
                focusedTileID: persistedTerminalTile.id
            )
        ]
        let persistence = WorkbenchStoreV2PersistenceSpy()
        try persistence.persistence.save(
            .init(workbenches: persistedWorkbenches, activeWorkbenchIndex: 1)
        )

        let store = try WorkbenchStoreV2(env: [:], persistence: persistence.persistence)

        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertEqual(store.workbenches, persistedWorkbenches)
        XCTAssertEqual(store.activeWorkbenchIndex, 1)

        guard case .tile(let restoredTile)? = store.activeWorkbench?.root,
              case .terminal(let restoredSessionRef) = restoredTile.kind else {
            return XCTFail("Expected the persisted terminal tile to be restored")
        }

        XCTAssertEqual(restoredSessionRef.target, persistedTerminalRef.target)
        XCTAssertEqual(restoredSessionRef.sessionName, persistedTerminalRef.sessionName)
        XCTAssertEqual(restoredSessionRef.lastSeenSessionID, persistedTerminalRef.lastSeenSessionID)
        XCTAssertEqual(restoredSessionRef.lastSeenRepoRoot, persistedTerminalRef.lastSeenRepoRoot)
    }

    func testFixtureEnvironmentOverridesPersistedSnapshot() throws {
        let persistedTerminalTile = WorkbenchTile(
            kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "persisted"))
        )
        let persistedWorkbench = Workbench(
            title: "Persisted",
            root: .tile(persistedTerminalTile),
            focusedTileID: persistedTerminalTile.id
        )
        let fixtureTile = WorkbenchTile(
            kind: .browser(
                url: URL(string: "https://example.com/fixture")!,
                sourceContext: "/tmp/fixture"
            ),
            pinned: true
        )
        let fixtureWorkbench = Workbench(
            title: "Fixture",
            root: .tile(fixtureTile),
            focusedTileID: fixtureTile.id
        )
        let fixtureJSON = try fixtureJSON(workbenches: [fixtureWorkbench])
        let persistence = WorkbenchStoreV2PersistenceSpy()
        try persistence.persistence.save(
            .init(workbenches: [persistedWorkbench], activeWorkbenchIndex: 0)
        )

        let store = try WorkbenchStoreV2(
            env: [WorkbenchStoreV2.fixtureEnvironmentKey: fixtureJSON],
            persistence: persistence.persistence
        )

        XCTAssertEqual(persistence.loadCount, 0)
        XCTAssertEqual(store.workbenches, [fixtureWorkbench])
        XCTAssertEqual(store.activeWorkbenchIndex, 0)
    }

    func testFixtureEnvironmentDisablesPersistenceForLaterMutations() throws {
        let persistedTerminalTile = WorkbenchTile(
            kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "persisted"))
        )
        let persistedWorkbench = Workbench(
            title: "Persisted",
            root: .tile(persistedTerminalTile),
            focusedTileID: persistedTerminalTile.id
        )
        let fixtureTerminalTile = WorkbenchTile(
            kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "fixture"))
        )
        let fixtureWorkbench = Workbench(
            title: "Fixture",
            root: .tile(fixtureTerminalTile),
            focusedTileID: fixtureTerminalTile.id
        )
        let fixtureJSON = try fixtureJSON(workbenches: [fixtureWorkbench])
        let persistence = WorkbenchStoreV2PersistenceSpy()
        try persistence.persistence.save(
            .init(workbenches: [persistedWorkbench], activeWorkbenchIndex: 0)
        )

        let store = try WorkbenchStoreV2(
            env: [WorkbenchStoreV2.fixtureEnvironmentKey: fixtureJSON],
            persistence: persistence.persistence
        )

        store.createWorkbench(title: "Transient fixture mutation")

        XCTAssertEqual(persistence.loadCount, 0)
        XCTAssertEqual(persistence.saveCount, 1, "Only the seed save should have run")
        let snapshot = try XCTUnwrap(try persistence.persistence.load())
        XCTAssertEqual(snapshot.workbenches, [persistedWorkbench])
        XCTAssertEqual(snapshot.activeWorkbenchIndex, 0)
        XCTAssertThrowsError(try store.save()) { error in
            XCTAssertEqual(
                error as? WorkbenchStoreV2PersistenceError,
                .persistenceUnavailable
            )
        }
    }

    func testSavePrunesUnpinnedCompanionTilesButKeepsPinnedCompanionsAndTerminals() throws {
        let terminalTile = WorkbenchTile(
            kind: .terminal(
                sessionRef: SessionRef(
                    target: .local,
                    sessionName: "main",
                    lastSeenSessionID: "$1",
                    lastSeenRepoRoot: "/tmp/repo"
                )
            )
        )
        let pinnedBrowserTile = WorkbenchTile(
            kind: .browser(
                url: URL(string: "https://example.com/pinned")!,
                sourceContext: "/tmp/pinned"
            ),
            pinned: true
        )
        let unpinnedBrowserTile = WorkbenchTile(
            kind: .browser(
                url: URL(string: "https://example.com/transient")!,
                sourceContext: "/tmp/transient"
            ),
            pinned: false
        )
        let pinnedDocumentTile = WorkbenchTile(
            kind: .document(ref: DocumentRef(target: .local, path: "/tmp/pinned.md")),
            pinned: true
        )
        let unpinnedDocumentTile = WorkbenchTile(
            kind: .document(ref: DocumentRef(target: .local, path: "/tmp/transient.md")),
            pinned: false
        )
        let workbench = Workbench(
            title: "Mixed",
            root: .split(
                WorkbenchSplit(
                    axis: .horizontal,
                    first: .split(
                        WorkbenchSplit(
                            axis: .vertical,
                            first: .tile(terminalTile),
                            second: .tile(unpinnedBrowserTile)
                        )
                    ),
                    second: .split(
                        WorkbenchSplit(
                            axis: .vertical,
                            first: .tile(pinnedBrowserTile),
                            second: .split(
                                WorkbenchSplit(
                                    axis: .horizontal,
                                    first: .tile(pinnedDocumentTile),
                                    second: .tile(unpinnedDocumentTile)
                                )
                            )
                        )
                    )
                )
            ),
            focusedTileID: unpinnedDocumentTile.id
        )
        let persistence = WorkbenchStoreV2PersistenceSpy()
        let store = WorkbenchStoreV2(
            workbenches: [workbench],
            persistence: persistence.persistence
        )

        try store.save()
        let snapshot = try XCTUnwrap(try persistence.persistence.load())
        let persistedWorkbench = try XCTUnwrap(snapshot.workbenches.first)
        let persistedTileIDs = Set(persistedWorkbench.tiles.map(\.id))

        XCTAssertEqual(store.workbenches[0].tiles.count, 5)
        XCTAssertEqual(persistedWorkbench.tiles.count, 3)
        XCTAssertTrue(persistedTileIDs.contains(terminalTile.id))
        XCTAssertTrue(persistedTileIDs.contains(pinnedBrowserTile.id))
        XCTAssertTrue(persistedTileIDs.contains(pinnedDocumentTile.id))
        XCTAssertFalse(persistedTileIDs.contains(unpinnedBrowserTile.id))
        XCTAssertFalse(persistedTileIDs.contains(unpinnedDocumentTile.id))
        XCTAssertEqual(persistedWorkbench.focusedTileID, terminalTile.id)
    }

    func testAutosaveRunsForRepresentativeMutations() throws {
        let persistence = WorkbenchStoreV2PersistenceSpy()
        let store = WorkbenchStoreV2(persistence: persistence.persistence)

        let terminalResult = store.openTerminal(
            sessionRef: SessionRef(target: .local, sessionName: "main")
        )
        let browserTileID = store.openBrowserPlaceholder(
            url: URL(string: "https://example.com/docs")!,
            placement: .right,
            pinned: true
        )
        store.focusTile(id: terminalResult.tileID)
        let createdWorkbench = store.createWorkbench(title: "Docs")

        let snapshot = try XCTUnwrap(try persistence.persistence.load())

        XCTAssertEqual(persistence.saveCount, 4)
        XCTAssertEqual(snapshot.workbenches.count, 2)
        XCTAssertEqual(snapshot.activeWorkbenchIndex, 1)
        XCTAssertEqual(snapshot.workbenches[0].focusedTileID, terminalResult.tileID)
        XCTAssertTrue(snapshot.workbenches[0].tiles.contains(where: { $0.id == browserTileID }))
        XCTAssertEqual(snapshot.workbenches[1].id, createdWorkbench.id)
    }

    func testBridgeDispatchAutosavesPinnedCompanionIntoPersistedSnapshot() throws {
        let sessionRef = SessionRef(
            target: .local,
            sessionName: "main",
            lastSeenSessionID: "$1",
            lastSeenRepoRoot: "/tmp/repo"
        )
        let terminalTile = WorkbenchTile(kind: .terminal(sessionRef: sessionRef))
        let workbench = Workbench(
            title: "Main",
            root: .tile(terminalTile),
            focusedTileID: terminalTile.id
        )
        let persistence = WorkbenchStoreV2PersistenceSpy()
        let store = WorkbenchStoreV2(
            workbenches: [workbench],
            persistence: persistence.persistence
        )
        let request = WorkbenchV2BridgeRequest.browser(
            url: URL(string: "https://example.com/companion")!,
            sourceContext: "local: /tmp/repo",
            placement: .right,
            pin: true
        )

        let result = try store.dispatchBridgeRequest(
            request,
            from: GhosttyTerminalSurfaceContext(
                workbenchID: workbench.id,
                tileID: terminalTile.id,
                surfaceKey: "workbench-v2:local:main",
                sessionRef: sessionRef
            )
        )
        let snapshot = try XCTUnwrap(try persistence.persistence.load())
        let persistedWorkbench = try XCTUnwrap(snapshot.workbenches.first)
        let persistedBrowserTile = try XCTUnwrap(
            persistedWorkbench.tiles.first(where: { $0.id == result.tileID })
        )

        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertEqual(result, .openedBrowser(workbenchID: workbench.id, tileID: persistedBrowserTile.id))
        XCTAssertEqual(snapshot.activeWorkbenchIndex, 0)
        XCTAssertEqual(persistedWorkbench.id, workbench.id)
        XCTAssertEqual(persistedWorkbench.tiles.count, 2)
        XCTAssertEqual(persistedWorkbench.focusedTileID, persistedBrowserTile.id)
        XCTAssertTrue(persistedWorkbench.tiles.contains(where: { $0.id == terminalTile.id }))

        guard case .browser(let url, let sourceContext) = persistedBrowserTile.kind else {
            return XCTFail("Expected bridge-opened pinned companion to persist as a browser tile")
        }

        XCTAssertEqual(url, URL(string: "https://example.com/companion")!)
        XCTAssertEqual(sourceContext, "local: /tmp/repo")
        XCTAssertTrue(persistedBrowserTile.pinned)
    }

    // MARK: - Autosave on remove / rebind

    func testRemoveTileAutosavesWhenPersistenceConfigured() throws {
        let terminalTile = WorkbenchTile(
            kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "main"))
        )
        let extraTile = WorkbenchTile(
            kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "extra"))
        )
        let workbench = Workbench(
            title: "Test",
            root: .split(WorkbenchSplit(
                axis: .horizontal,
                first: .tile(terminalTile),
                second: .tile(extraTile)
            )),
            focusedTileID: terminalTile.id
        )
        let persistence = WorkbenchStoreV2PersistenceSpy()
        let store = WorkbenchStoreV2(workbenches: [workbench], persistence: persistence.persistence)
        let savesBefore = persistence.saveCount

        store.removeTile(id: extraTile.id)

        XCTAssertEqual(persistence.saveCount, savesBefore + 1)
        let snapshot = try XCTUnwrap(try persistence.persistence.load())
        let persistedIDs = Set(snapshot.workbenches[0].tiles.map(\.id))
        XCTAssertFalse(persistedIDs.contains(extraTile.id))
        XCTAssertTrue(persistedIDs.contains(terminalTile.id))
    }

    func testRebindTerminalAutosavesWhenPersistenceConfigured() throws {
        let original = SessionRef(target: .local, sessionName: "old")
        let terminalTile = WorkbenchTile(kind: .terminal(sessionRef: original))
        let workbench = Workbench(
            title: "Test",
            root: .tile(terminalTile),
            focusedTileID: terminalTile.id
        )
        let persistence = WorkbenchStoreV2PersistenceSpy()
        let store = WorkbenchStoreV2(workbenches: [workbench], persistence: persistence.persistence)
        let savesBefore = persistence.saveCount

        store.rebindTerminal(
            tileID: terminalTile.id,
            to: SessionRef(target: .remote(hostKey: "prod"), sessionName: "deploy")
        )

        XCTAssertEqual(persistence.saveCount, savesBefore + 1)
        let snapshot = try XCTUnwrap(try persistence.persistence.load())
        let persistedTile = try XCTUnwrap(snapshot.workbenches[0].tiles.first)
        guard case .terminal(let stored) = persistedTile.kind else {
            return XCTFail("Expected persisted terminal tile")
        }
        XCTAssertEqual(stored.target, .remote(hostKey: "prod"))
        XCTAssertEqual(stored.sessionName, "deploy")
    }

    func testRebindDocumentAutosavesWhenPersistenceConfigured() throws {
        let originalRef = DocumentRef(target: .local, path: "/tmp/spec.md")
        let docTile = WorkbenchTile(kind: .document(ref: originalRef), pinned: true)
        let workbench = Workbench(
            title: "Test",
            root: .tile(docTile),
            focusedTileID: docTile.id
        )
        let persistence = WorkbenchStoreV2PersistenceSpy()
        let store = WorkbenchStoreV2(workbenches: [workbench], persistence: persistence.persistence)
        let savesBefore = persistence.saveCount

        let newRef = DocumentRef(target: .remote(hostKey: "staging"), path: "/srv/README.md")
        store.rebindDocument(tileID: docTile.id, to: newRef)

        XCTAssertEqual(persistence.saveCount, savesBefore + 1)
        let snapshot = try XCTUnwrap(try persistence.persistence.load())
        let persistedTile = try XCTUnwrap(snapshot.workbenches[0].tiles.first)
        guard case .document(let stored) = persistedTile.kind else {
            return XCTFail("Expected persisted document tile")
        }
        XCTAssertEqual(stored, newRef)
        XCTAssertTrue(persistedTile.pinned, "Pinning must survive rebind and persist")
    }

    func testExplicitSaveThrowsWhenPersistenceIsNotConfigured() {
        let store = WorkbenchStoreV2()

        XCTAssertThrowsError(try store.save()) { error in
            XCTAssertEqual(
                error as? WorkbenchStoreV2PersistenceError,
                .persistenceUnavailable
            )
        }
    }

    private func fixtureJSON(workbenches: [Workbench]) throws -> String {
        let data = try JSONEncoder().encode(workbenches)
        return String(decoding: data, as: UTF8.self)
    }
}

private final class WorkbenchStoreV2PersistenceSpy {
    var storedData: Data?
    var loadCount = 0
    var saveCount = 0

    lazy var persistence = WorkbenchStoreV2Persistence(
        snapshotURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-workbench-v2.json"),
        loadData: { [self] in
            loadCount += 1
            return storedData
        },
        saveData: { [self] data in
            saveCount += 1
            storedData = data
        }
    )
}
