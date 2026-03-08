import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class WorkbenchV2BridgeDispatchTests: XCTestCase {
    func testBridgeRequestFactoriesPreserveResolvedBrowserAndDocumentPayloads() {
        let browserRequest = WorkbenchV2BridgeRequest.browser(
            url: URL(string: "https://example.com/docs")!,
            sourceContext: "docs: /srv/docs",
            placement: .left,
            pin: true
        )
        let documentRef = DocumentRef(target: .remote(hostKey: "docs"), path: "/srv/docs/spec.md")
        let documentRequest = WorkbenchV2BridgeRequest.document(
            ref: documentRef,
            placement: .down,
            pin: false
        )
        let defaultPlacementRequest = WorkbenchV2BridgeRequest.document(ref: documentRef)

        XCTAssertEqual(
            browserRequest.payload,
            .browser(
                url: URL(string: "https://example.com/docs")!,
                sourceContext: "docs: /srv/docs"
            )
        )
        XCTAssertEqual(browserRequest.placement, .left)
        XCTAssertTrue(browserRequest.pin)
        XCTAssertEqual(documentRequest.payload, .document(ref: documentRef))
        XCTAssertEqual(documentRequest.placement, .down)
        XCTAssertFalse(documentRequest.pin)
        XCTAssertEqual(defaultPlacementRequest.placement, .replace)
    }

    @MainActor
    func testDispatchBridgeRequestPlacesBrowserTileInActiveWorkbench() {
        let store = WorkbenchStoreV2()
        let firstWorkbenchID = store.workbenches[0].id
        let activeWorkbench = store.createWorkbench(title: "Docs")
        let request = WorkbenchV2BridgeRequest.browser(
            url: URL(string: "https://example.com/workbench")!,
            sourceContext: "docs: /srv/docs",
            pin: true
        )

        let result = store.dispatchBridgeRequest(request)

        XCTAssertEqual(result.workbenchID, activeWorkbench.id)
        XCTAssertNotEqual(result.workbenchID, firstWorkbenchID)
        XCTAssertEqual(store.activeWorkbench?.id, activeWorkbench.id)

        guard case .tile(let tile)? = store.activeWorkbench?.root,
              case .browser(let url, let sourceContext) = tile.kind else {
            return XCTFail("Expected a browser tile in the active workbench")
        }

        XCTAssertEqual(result, .openedBrowser(workbenchID: activeWorkbench.id, tileID: tile.id))
        XCTAssertEqual(result.tileID, tile.id)
        XCTAssertEqual(url, URL(string: "https://example.com/workbench")!)
        XCTAssertEqual(sourceContext, "docs: /srv/docs")
        XCTAssertTrue(tile.pinned)
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, tile.id)
    }

    @MainActor
    func testDispatchBridgeRequestStoresResolvedDocumentRef() {
        let store = WorkbenchStoreV2()
        let request = WorkbenchV2BridgeRequest.document(
            ref: DocumentRef(target: .local, path: "/tmp/spec.md"),
            placement: .replace,
            pin: false
        )

        let result = store.dispatchBridgeRequest(request)

        guard case .tile(let tile)? = store.activeWorkbench?.root,
              case .document(let ref) = tile.kind else {
            return XCTFail("Expected a document tile in the active workbench")
        }

        XCTAssertEqual(result, .openedDocument(workbenchID: store.workbenches[0].id, tileID: tile.id))
        XCTAssertEqual(ref, DocumentRef(target: .local, path: "/tmp/spec.md"))
        XCTAssertFalse(tile.pinned)
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, tile.id)
    }

    @MainActor
    func testDispatchBridgeRequestReplacePlacementPreservesFocusedTileReplacementSemantics() {
        let store = WorkbenchStoreV2()
        let originalRef = DocumentRef(target: .local, path: "/tmp/original.md")
        let originalTileID = store.openDocumentPlaceholder(ref: originalRef, pinned: true)
        let request = WorkbenchV2BridgeRequest.browser(
            url: URL(string: "https://example.com/replacement")!,
            sourceContext: "local: /tmp",
            placement: .replace,
            pin: false
        )

        let result = store.dispatchBridgeRequest(request)

        guard case .tile(let tile)? = store.activeWorkbench?.root,
              case .browser(let url, let sourceContext) = tile.kind else {
            return XCTFail("Expected replace placement to keep a single browser tile")
        }

        XCTAssertEqual(result, .openedBrowser(workbenchID: store.workbenches[0].id, tileID: tile.id))
        XCTAssertEqual(url, URL(string: "https://example.com/replacement")!)
        XCTAssertEqual(sourceContext, "local: /tmp")
        XCTAssertEqual(store.activeWorkbench?.tiles.count, 1)
        XCTAssertNotEqual(tile.id, originalTileID)
        XCTAssertFalse(store.activeWorkbench?.tiles.contains(where: { $0.id == originalTileID }) == true)
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, tile.id)
    }

    @MainActor
    func testDispatchBridgeRequestReplacePlacementNormalizesUnfocusedWorkbenchDeterministically() {
        let fixture = makeUnfocusedSplitWorkbench()
        let store = WorkbenchStoreV2(workbenches: [fixture.workbench])
        let request = WorkbenchV2BridgeRequest.browser(
            url: URL(string: "https://example.com/unfocused-replace")!,
            sourceContext: "fixture=replace",
            placement: .replace,
            pin: true
        )

        let result = store.dispatchBridgeRequest(request)

        guard case .split(let split)? = store.activeWorkbench?.root else {
            return XCTFail("Expected replace placement to preserve the sibling branch")
        }
        guard case .tile(let insertedTile) = split.first,
              case .tile(let untouchedTile) = split.second else {
            return XCTFail("Expected replace placement to replace only the deterministic fallback tile")
        }
        guard case .browser(let url, let sourceContext) = insertedTile.kind else {
            return XCTFail("Expected replace placement to insert the browser request tile")
        }

        XCTAssertEqual(split.axis, .horizontal)
        XCTAssertEqual(result, .openedBrowser(workbenchID: fixture.workbench.id, tileID: insertedTile.id))
        XCTAssertEqual(url, URL(string: "https://example.com/unfocused-replace")!)
        XCTAssertEqual(sourceContext, "fixture=replace")
        XCTAssertTrue(insertedTile.pinned)
        XCTAssertEqual(untouchedTile, fixture.untouchedTile)
        XCTAssertEqual(store.activeWorkbench?.tiles.count, 2)
        XCTAssertFalse(store.activeWorkbench?.tiles.contains(where: { $0.id == fixture.fallbackTile.id }) == true)
        XCTAssertTrue(store.activeWorkbench?.tiles.contains(where: { $0.id == fixture.untouchedTile.id }) == true)
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, insertedTile.id)
    }

    @MainActor
    func testDispatchBridgeRequestDirectionalPlacementNormalizesUnfocusedWorkbenchDeterministically() {
        let cases: [(placement: WorkbenchV2Placement, axis: SplitAxis, insertedFirst: Bool)] = [
            (.left, .horizontal, true),
            (.right, .horizontal, false),
            (.up, .vertical, true),
            (.down, .vertical, false)
        ]

        for (placement, axis, insertedFirst) in cases {
            let fixture = makeUnfocusedSplitWorkbench()
            let store = WorkbenchStoreV2(workbenches: [fixture.workbench])
            let request = WorkbenchV2BridgeRequest.browser(
                url: URL(string: "https://example.com/unfocused-\(placement.rawValue)")!,
                sourceContext: "fixture=\(placement.rawValue)",
                placement: placement,
                pin: false
            )

            let result = store.dispatchBridgeRequest(request)

            guard case .split(let outerSplit)? = store.activeWorkbench?.root else {
                return XCTFail("Expected \(placement.rawValue) placement to preserve the outer split")
            }
            guard case .split(let nestedSplit) = outerSplit.first,
                  case .tile(let untouchedTile) = outerSplit.second,
                  case .tile(let nestedFirstTile) = nestedSplit.first,
                  case .tile(let nestedSecondTile) = nestedSplit.second else {
                return XCTFail("Expected \(placement.rawValue) placement to split around the deterministic fallback tile")
            }

            let insertedTile = insertedFirst ? nestedFirstTile : nestedSecondTile
            let originalTile = insertedFirst ? nestedSecondTile : nestedFirstTile

            XCTAssertEqual(outerSplit.axis, .horizontal)
            XCTAssertEqual(nestedSplit.axis, axis)
            XCTAssertEqual(result, .openedBrowser(workbenchID: fixture.workbench.id, tileID: insertedTile.id))
            XCTAssertEqual(store.activeWorkbench?.tiles.count, 3)
            XCTAssertEqual(store.activeWorkbench?.focusedTileID, insertedTile.id)
            XCTAssertEqual(untouchedTile, fixture.untouchedTile)
            XCTAssertEqual(originalTile, fixture.fallbackTile)

            guard case .browser(let url, let sourceContext) = insertedTile.kind else {
                return XCTFail("Expected \(placement.rawValue) placement to insert the browser request tile")
            }

            XCTAssertEqual(url, URL(string: "https://example.com/unfocused-\(placement.rawValue)")!)
            XCTAssertEqual(sourceContext, "fixture=\(placement.rawValue)")
            XCTAssertFalse(insertedTile.pinned)
        }
    }

    @MainActor
    func testDispatchBridgeRequestDirectionalPlacementsCreateExpectedSplitAroundFocusedTile() {
        let cases: [(placement: WorkbenchV2Placement, axis: SplitAxis, insertedFirst: Bool)] = [
            (.left, .horizontal, true),
            (.right, .horizontal, false),
            (.up, .vertical, true),
            (.down, .vertical, false)
        ]

        for (placement, axis, insertedFirst) in cases {
            let store = WorkbenchStoreV2()
            let originalRef = DocumentRef(target: .local, path: "/tmp/\(placement.rawValue)-seed.md")
            let originalTileID = store.openDocumentPlaceholder(ref: originalRef, pinned: false)
            let request = WorkbenchV2BridgeRequest.browser(
                url: URL(string: "https://example.com/\(placement.rawValue)")!,
                sourceContext: "placement=\(placement.rawValue)",
                placement: placement,
                pin: true
            )

            let result = store.dispatchBridgeRequest(request)

            guard case .split(let split)? = store.activeWorkbench?.root else {
                return XCTFail("Expected \(placement.rawValue) placement to create a split")
            }
            guard case .tile(let firstTile) = split.first,
                  case .tile(let secondTile) = split.second else {
                return XCTFail("Expected \(placement.rawValue) placement to split around tile nodes")
            }

            let insertedTile = insertedFirst ? firstTile : secondTile
            let originalTile = insertedFirst ? secondTile : firstTile

            XCTAssertEqual(split.axis, axis, "Placement \(placement.rawValue) must preserve the expected split axis")
            XCTAssertEqual(result, .openedBrowser(workbenchID: store.workbenches[0].id, tileID: insertedTile.id))
            XCTAssertEqual(store.activeWorkbench?.tiles.count, 2)
            XCTAssertEqual(store.activeWorkbench?.focusedTileID, insertedTile.id)

            guard case .browser(let url, let sourceContext) = insertedTile.kind else {
                return XCTFail("Expected \(placement.rawValue) placement to insert the browser request tile")
            }
            guard case .document(let ref) = originalTile.kind else {
                return XCTFail("Expected \(placement.rawValue) placement to retain the original focused tile")
            }

            XCTAssertEqual(url, URL(string: "https://example.com/\(placement.rawValue)")!)
            XCTAssertEqual(sourceContext, "placement=\(placement.rawValue)")
            XCTAssertTrue(insertedTile.pinned)
            XCTAssertEqual(ref, originalRef)
            XCTAssertEqual(originalTile.id, originalTileID)
        }
    }

    private func makeUnfocusedSplitWorkbench() -> (
        workbench: Workbench,
        fallbackTile: WorkbenchTile,
        untouchedTile: WorkbenchTile
    ) {
        let fallbackTile = WorkbenchTile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            kind: .document(ref: DocumentRef(target: .local, path: "/tmp/fallback.md"))
        )
        let untouchedTile = WorkbenchTile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            kind: .document(ref: DocumentRef(target: .local, path: "/tmp/untouched.md"))
        )
        let workbench = Workbench(
            title: "Unfocused",
            root: .split(
                WorkbenchSplit(
                    axis: .horizontal,
                    first: .tile(fallbackTile),
                    second: .tile(untouchedTile)
                )
            ),
            focusedTileID: nil
        )
        return (workbench, fallbackTile, untouchedTile)
    }
}
