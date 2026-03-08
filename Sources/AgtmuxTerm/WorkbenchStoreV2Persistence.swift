import Foundation
import AgtmuxTermCore

enum WorkbenchStoreV2PersistenceError: Error, Equatable {
    case invalidSnapshot(String)
    case persistenceUnavailable
}

struct WorkbenchStoreV2Persistence {
    struct Snapshot: Codable, Equatable {
        let workbenches: [Workbench]
        let activeWorkbenchIndex: Int

        init(workbenches: [Workbench], activeWorkbenchIndex: Int) {
            self.workbenches = workbenches
            self.activeWorkbenchIndex = activeWorkbenchIndex
        }
    }

    static let snapshotDirectoryName = "AGTMUXDesktop"
    static let snapshotFileName = "workbench-v2.json"

    let snapshotURL: URL
    private let loadData: () throws -> Data?
    private let saveData: (Data) throws -> Void

    init(
        snapshotURL: URL,
        loadData: @escaping () throws -> Data?,
        saveData: @escaping (Data) throws -> Void
    ) {
        self.snapshotURL = snapshotURL
        self.loadData = loadData
        self.saveData = saveData
    }

    static func live(fileManager: FileManager = .default) -> WorkbenchStoreV2Persistence {
        fileStore(snapshotURL: defaultSnapshotURL(fileManager: fileManager), fileManager: fileManager)
    }

    static func fileStore(
        snapshotURL: URL,
        fileManager: FileManager = .default
    ) -> WorkbenchStoreV2Persistence {
        WorkbenchStoreV2Persistence(
            snapshotURL: snapshotURL,
            loadData: {
                guard fileManager.fileExists(atPath: snapshotURL.path(percentEncoded: false)) else {
                    return nil
                }
                return try Data(contentsOf: snapshotURL)
            },
            saveData: { data in
                let directoryURL = snapshotURL.deletingLastPathComponent()
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                try data.write(to: snapshotURL, options: .atomic)
            }
        )
    }

    static func defaultSnapshotURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(snapshotDirectoryName, isDirectory: true)
            .appendingPathComponent(snapshotFileName, isDirectory: false)
    }

    func load() throws -> Snapshot? {
        guard let data = try loadData() else { return nil }
        return try Self.decodeSnapshot(data)
    }

    func save(_ snapshot: Snapshot) throws {
        try saveData(try Self.encodeSnapshot(snapshot))
    }

    private static func decodeSnapshot(_ data: Data) throws -> Snapshot {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard !snapshot.workbenches.isEmpty else {
            throw WorkbenchStoreV2PersistenceError.invalidSnapshot(
                "workbench-v2 snapshot must contain at least one workbench"
            )
        }
        guard snapshot.workbenches.indices.contains(snapshot.activeWorkbenchIndex) else {
            throw WorkbenchStoreV2PersistenceError.invalidSnapshot(
                "workbench-v2 snapshot activeWorkbenchIndex is out of range"
            )
        }
        return snapshot
    }

    private static func encodeSnapshot(_ snapshot: Snapshot) throws -> Data {
        guard !snapshot.workbenches.isEmpty else {
            throw WorkbenchStoreV2PersistenceError.invalidSnapshot(
                "workbench-v2 snapshot must contain at least one workbench"
            )
        }
        guard snapshot.workbenches.indices.contains(snapshot.activeWorkbenchIndex) else {
            throw WorkbenchStoreV2PersistenceError.invalidSnapshot(
                "workbench-v2 snapshot activeWorkbenchIndex is out of range"
            )
        }

        let persistedSnapshot = Snapshot(
            workbenches: snapshot.workbenches.map(\.persistedSnapshot),
            activeWorkbenchIndex: snapshot.activeWorkbenchIndex
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(persistedSnapshot)
    }
}

private extension Workbench {
    var persistedSnapshot: Workbench {
        let persistedRoot = root.persistedSnapshot ?? .empty(WorkbenchEmptyNode(id: root.id))
        let availableTileIDs = Set(persistedRoot.tileIDs)
        let persistedFocusedTileID: UUID?
        if let focusedTileID, availableTileIDs.contains(focusedTileID) {
            persistedFocusedTileID = focusedTileID
        } else {
            persistedFocusedTileID = persistedRoot.tiles.first?.id
        }

        return Workbench(
            id: id,
            title: title,
            root: persistedRoot,
            focusedTileID: persistedFocusedTileID
        )
    }
}

private extension WorkbenchNode {
    var persistedSnapshot: WorkbenchNode? {
        switch self {
        case .empty(let empty):
            return .empty(empty)
        case .tile(let tile):
            return tile.isPersistable ? .tile(tile) : nil
        case .split(var split):
            let persistedFirst = split.first.persistedSnapshot
            let persistedSecond = split.second.persistedSnapshot
            switch (persistedFirst, persistedSecond) {
            case (nil, nil):
                return nil
            case let (first?, nil):
                return first
            case let (nil, second?):
                return second
            case let (first?, second?):
                split.first = first
                split.second = second
                return .split(split)
            }
        }
    }
}

private extension WorkbenchTile {
    var isPersistable: Bool {
        switch kind {
        case .terminal:
            return true
        case .browser, .document:
            return pinned
        }
    }
}
