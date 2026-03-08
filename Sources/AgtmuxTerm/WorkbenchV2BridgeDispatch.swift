import Foundation
import AgtmuxTermCore

enum WorkbenchV2Placement: String, Equatable, Hashable, Sendable {
    case left
    case right
    case up
    case down
    case replace
}

enum WorkbenchV2BridgeRequestPayload: Equatable, Hashable, Sendable {
    case browser(url: URL, sourceContext: String?)
    case document(ref: DocumentRef)
}

struct WorkbenchV2BridgeRequest: Equatable, Hashable, Sendable {
    let payload: WorkbenchV2BridgeRequestPayload
    let placement: WorkbenchV2Placement
    let pin: Bool

    init(
        payload: WorkbenchV2BridgeRequestPayload,
        placement: WorkbenchV2Placement = .replace,
        pin: Bool = false
    ) {
        self.payload = payload
        self.placement = placement
        self.pin = pin
    }

    static func browser(
        url: URL,
        sourceContext: String? = nil,
        placement: WorkbenchV2Placement = .replace,
        pin: Bool = false
    ) -> WorkbenchV2BridgeRequest {
        WorkbenchV2BridgeRequest(
            payload: .browser(url: url, sourceContext: sourceContext),
            placement: placement,
            pin: pin
        )
    }

    static func document(
        ref: DocumentRef,
        placement: WorkbenchV2Placement = .replace,
        pin: Bool = false
    ) -> WorkbenchV2BridgeRequest {
        WorkbenchV2BridgeRequest(
            payload: .document(ref: ref),
            placement: placement,
            pin: pin
        )
    }
}

enum WorkbenchV2BridgeDispatchResult: Equatable {
    case openedBrowser(workbenchID: UUID, tileID: UUID)
    case openedDocument(workbenchID: UUID, tileID: UUID)

    var workbenchID: UUID {
        switch self {
        case .openedBrowser(let workbenchID, _), .openedDocument(let workbenchID, _):
            return workbenchID
        }
    }

    var tileID: UUID {
        switch self {
        case .openedBrowser(_, let tileID), .openedDocument(_, let tileID):
            return tileID
        }
    }
}

enum WorkbenchV2BridgeDispatchError: Error, Equatable, CustomStringConvertible {
    case workbenchNotFound(UUID)
    case sourceTileNotFound(workbenchID: UUID, tileID: UUID)

    var description: String {
        switch self {
        case .workbenchNotFound(let workbenchID):
            return "CLI bridge could not find workbench \(workbenchID)"
        case .sourceTileNotFound(let workbenchID, let tileID):
            return "CLI bridge could not find source tile \(tileID) in workbench \(workbenchID)"
        }
    }
}

extension WorkbenchStoreV2 {
    @discardableResult
    func dispatchBridgeRequest(
        _ request: WorkbenchV2BridgeRequest
    ) -> WorkbenchV2BridgeDispatchResult {
        let workbenchID = workbenches[activeWorkbenchIndex].id

        switch request.payload {
        case .browser(let url, let sourceContext):
            let tileID = openBrowserPlaceholder(
                url: url,
                sourceContext: sourceContext,
                placement: request.placement,
                pinned: request.pin
            )
            return .openedBrowser(workbenchID: workbenchID, tileID: tileID)

        case .document(let ref):
            let tileID = openDocumentPlaceholder(
                ref: ref,
                placement: request.placement,
                pinned: request.pin
            )
            return .openedDocument(workbenchID: workbenchID, tileID: tileID)
        }
    }

    @discardableResult
    func dispatchBridgeRequest(
        _ request: WorkbenchV2BridgeRequest,
        from surfaceContext: GhosttyTerminalSurfaceContext
    ) throws -> WorkbenchV2BridgeDispatchResult {
        try dispatchBridgeRequest(
            request,
            inWorkbenchID: surfaceContext.workbenchID,
            adjacentToTileID: surfaceContext.tileID
        )
    }

    @discardableResult
    func dispatchBridgeRequest(
        _ request: WorkbenchV2BridgeRequest,
        inWorkbenchID workbenchID: UUID,
        adjacentToTileID sourceTileID: UUID
    ) throws -> WorkbenchV2BridgeDispatchResult {
        guard let workbenchIndex = workbenches.firstIndex(where: { $0.id == workbenchID }) else {
            throw WorkbenchV2BridgeDispatchError.workbenchNotFound(workbenchID)
        }

        var workbench = workbenches[workbenchIndex]
        guard let sourceTile = workbench.tiles.first(where: { $0.id == sourceTileID }) else {
            throw WorkbenchV2BridgeDispatchError.sourceTileNotFound(
                workbenchID: workbenchID,
                tileID: sourceTileID
            )
        }

        let insertedTile = bridgeTile(for: request)
        let replacementNode = bridgeReplacementNode(
            for: request.placement,
            replacing: sourceTile,
            with: insertedTile
        )

        guard let updatedRoot = workbench.root.replacing(
            tileID: sourceTile.id,
            with: replacementNode
        ) else {
            throw WorkbenchV2BridgeDispatchError.sourceTileNotFound(
                workbenchID: workbenchID,
                tileID: sourceTileID
            )
        }

        workbench.root = updatedRoot
        workbench.focusedTileID = insertedTile.id
        workbenches[workbenchIndex] = workbench
        activeWorkbenchIndex = workbenchIndex
        autosaveAfterBridgeMutation()

        return bridgeResult(
            for: request.payload,
            workbenchID: workbenchID,
            tileID: insertedTile.id
        )
    }

    private func bridgeTile(for request: WorkbenchV2BridgeRequest) -> WorkbenchTile {
        switch request.payload {
        case .browser(let url, let sourceContext):
            return WorkbenchTile(
                kind: .browser(url: url, sourceContext: sourceContext),
                pinned: request.pin
            )
        case .document(let ref):
            return WorkbenchTile(
                kind: .document(ref: ref),
                pinned: request.pin
            )
        }
    }

    private func bridgeReplacementNode(
        for placement: WorkbenchV2Placement,
        replacing sourceTile: WorkbenchTile,
        with insertedTile: WorkbenchTile
    ) -> WorkbenchNode {
        switch placement {
        case .replace:
            return .tile(insertedTile)
        case .left:
            return bridgeSplitNode(axis: .horizontal, first: insertedTile, second: sourceTile)
        case .right:
            return bridgeSplitNode(axis: .horizontal, first: sourceTile, second: insertedTile)
        case .up:
            return bridgeSplitNode(axis: .vertical, first: insertedTile, second: sourceTile)
        case .down:
            return bridgeSplitNode(axis: .vertical, first: sourceTile, second: insertedTile)
        }
    }

    private func bridgeSplitNode(
        axis: SplitAxis,
        first: WorkbenchTile,
        second: WorkbenchTile
    ) -> WorkbenchNode {
        .split(
            WorkbenchSplit(
                axis: axis,
                first: .tile(first),
                second: .tile(second)
            )
        )
    }

    private func bridgeResult(
        for payload: WorkbenchV2BridgeRequestPayload,
        workbenchID: UUID,
        tileID: UUID
    ) -> WorkbenchV2BridgeDispatchResult {
        switch payload {
        case .browser:
            return .openedBrowser(workbenchID: workbenchID, tileID: tileID)
        case .document:
            return .openedDocument(workbenchID: workbenchID, tileID: tileID)
        }
    }

    private func autosaveAfterBridgeMutation() {
        do {
            try save()
        } catch WorkbenchStoreV2PersistenceError.persistenceUnavailable {
            return
        } catch {
            fatalError("WorkbenchStoreV2 autosave failed: \(error)")
        }
    }
}
