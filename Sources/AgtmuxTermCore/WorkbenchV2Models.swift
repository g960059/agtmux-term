import Foundation

package struct Workbench: Identifiable, Codable, Equatable, Hashable, Sendable {
    package let id: UUID
    package var title: String
    package var root: WorkbenchNode
    package var focusedTileID: UUID?
    package var activePaneRef: ActivePaneRef?

    package init(
        id: UUID = UUID(),
        title: String = "",
        root: WorkbenchNode = .empty(WorkbenchEmptyNode()),
        focusedTileID: UUID? = nil,
        activePaneRef: ActivePaneRef? = nil
    ) {
        self.id = id
        self.title = title
        self.root = root
        self.focusedTileID = focusedTileID
        self.activePaneRef = activePaneRef
    }

    package static func empty(title: String = "") -> Workbench {
        Workbench(title: title)
    }

    package var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        switch root {
        case .empty:
            return "Empty"
        case .tile(let tile):
            return tile.kind.displayTitle
        case .split:
            return "Workbench"
        }
    }
}

package struct WorkbenchEmptyNode: Identifiable, Codable, Equatable, Hashable, Sendable {
    package let id: UUID

    package init(id: UUID = UUID()) {
        self.id = id
    }
}

package struct WorkbenchSplit: Identifiable, Codable, Equatable, Hashable, Sendable {
    package let id: UUID
    package let axis: SplitAxis
    package var ratio: CGFloat
    package var first: WorkbenchNode
    package var second: WorkbenchNode

    package init(
        id: UUID = UUID(),
        axis: SplitAxis,
        ratio: CGFloat = 0.5,
        first: WorkbenchNode,
        second: WorkbenchNode
    ) {
        self.id = id
        self.axis = axis
        self.ratio = max(0.1, min(0.9, ratio))
        self.first = first
        self.second = second
    }

    package mutating func setRatio(_ newRatio: CGFloat) {
        ratio = max(0.1, min(0.9, newRatio))
    }
}

package indirect enum WorkbenchNode: Identifiable, Codable, Equatable, Hashable, Sendable {
    case empty(WorkbenchEmptyNode)
    case tile(WorkbenchTile)
    case split(WorkbenchSplit)

    package var id: UUID {
        switch self {
        case .empty(let emptyNode):
            return emptyNode.id
        case .tile(let tile):
            return tile.id
        case .split(let split):
            return split.id
        }
    }
}

package struct WorkbenchTile: Identifiable, Codable, Equatable, Hashable, Sendable {
    package let id: UUID
    package var kind: TileKind
    package var pinned: Bool

    package init(id: UUID = UUID(), kind: TileKind, pinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.pinned = kind.supportsPinning ? pinned : false
    }
}

package enum TileKind: Codable, Equatable, Hashable, Sendable {
    case terminal(sessionRef: SessionRef)
    case browser(url: URL, sourceContext: String?)
    case document(ref: DocumentRef)
}

package struct SessionRef: Codable, Equatable, Hashable, Sendable {
    package var target: TargetRef
    package var sessionName: String
    package var lastSeenSessionID: String?
    package var lastSeenRepoRoot: String?

    package init(
        target: TargetRef,
        sessionName: String,
        lastSeenSessionID: String? = nil,
        lastSeenRepoRoot: String? = nil
    ) {
        self.target = target
        self.sessionName = sessionName
        self.lastSeenSessionID = lastSeenSessionID
        self.lastSeenRepoRoot = lastSeenRepoRoot
    }

    package static func == (lhs: SessionRef, rhs: SessionRef) -> Bool {
        lhs.target == rhs.target && lhs.sessionName == rhs.sessionName
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(target)
        hasher.combine(sessionName)
    }

    package func mergingStoredHints(from incoming: SessionRef) -> SessionRef {
        precondition(
            target == incoming.target && sessionName == incoming.sessionName,
            "SessionRef.mergingNavigationIntent requires the same tile identity"
        )

        var merged = self
        if let lastSeenSessionID = incoming.lastSeenSessionID {
            merged.lastSeenSessionID = lastSeenSessionID
        }
        if let lastSeenRepoRoot = incoming.lastSeenRepoRoot {
            merged.lastSeenRepoRoot = lastSeenRepoRoot
        }
        return merged
    }
}

package struct ActivePaneRef: Codable, Equatable, Hashable, Sendable {
    package var target: TargetRef
    package var sessionName: String
    package var windowID: String
    package var paneID: String
    package var paneInstanceID: AgtmuxSyncV2PaneInstanceID?

    package init(
        target: TargetRef,
        sessionName: String,
        windowID: String,
        paneID: String,
        paneInstanceID: AgtmuxSyncV2PaneInstanceID? = nil
    ) {
        self.target = target
        self.sessionName = sessionName
        self.windowID = windowID
        self.paneID = paneID
        self.paneInstanceID = paneInstanceID
    }

    package func matches(sessionRef: SessionRef) -> Bool {
        target == sessionRef.target && sessionName == sessionRef.sessionName
    }
}

package struct DocumentRef: Codable, Equatable, Hashable, Sendable {
    package var target: TargetRef
    package var path: String

    package init(target: TargetRef, path: String) {
        self.target = target
        self.path = path
    }
}

package enum TargetRef: Codable, Equatable, Hashable, Sendable {
    case local
    case remote(hostKey: String)
}

extension Workbench {
    package var tiles: [WorkbenchTile] {
        root.tiles
    }
}

extension WorkbenchNode {
    package var isEmpty: Bool {
        if case .empty = self {
            return true
        }
        return false
    }

    package var tiles: [WorkbenchTile] {
        switch self {
        case .empty:
            return []
        case .tile(let tile):
            return [tile]
        case .split(let split):
            return split.first.tiles + split.second.tiles
        }
    }

    package var tileIDs: [UUID] {
        tiles.map(\.id)
    }

    package func replacing(
        tileID: UUID,
        with newNode: WorkbenchNode,
        depth: Int = 0
    ) -> WorkbenchNode? {
        guard depth < 256 else { return nil }

        switch self {
        case .empty:
            return nil
        case .tile(let tile) where tile.id == tileID:
            return newNode
        case .tile:
            return nil
        case .split(var split):
            if let updated = split.first.replacing(tileID: tileID, with: newNode, depth: depth + 1) {
                split.first = updated
                return .split(split)
            }
            if let updated = split.second.replacing(tileID: tileID, with: newNode, depth: depth + 1) {
                split.second = updated
                return .split(split)
            }
            return nil
        }
    }
}

extension TileKind {
    package var supportsPinning: Bool {
        switch self {
        case .terminal:
            return false
        case .browser, .document:
            return true
        }
    }

    package var displayTitle: String {
        switch self {
        case .terminal(let sessionRef):
            return sessionRef.sessionName
        case .browser(let url, _):
            return url.host(percentEncoded: false) ?? url.absoluteString
        case .document(let ref):
            let name = URL(fileURLWithPath: ref.path).lastPathComponent
            return name.isEmpty ? ref.path : name
        }
    }

    package var detailText: String {
        switch self {
        case .terminal(let sessionRef):
            return sessionRef.target.label
        case .browser(let url, let sourceContext):
            return sourceContext ?? url.absoluteString
        case .document(let ref):
            return "\(ref.target.label): \(ref.path)"
        }
    }
}

extension TargetRef {
    package var label: String {
        switch self {
        case .local:
            return "local"
        case .remote(let hostKey):
            return hostKey
        }
    }
}
