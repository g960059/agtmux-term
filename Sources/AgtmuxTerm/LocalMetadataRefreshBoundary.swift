import Foundation
import AgtmuxTermCore

struct LocalMetadataRefreshState: Equatable {
    let syncPrimed: Bool
    let transportVersion: LocalMetadataTransportVersion?
    let daemonIssue: LocalDaemonIssue?
    let nextRefreshAt: Date
}

struct LocalBootstrapMetadataPayload: Equatable {
    let cache: LocalMetadataOverlayCache
    let transportVersion: LocalMetadataTransportVersion

    var metadataByPaneKey: [String: AgtmuxPane] { cache.metadataByPaneKey }
    var presentationByPaneKey: [String: PanePresentationState] { cache.presentationByPaneKey }
}

enum LocalMetadataCacheAction: Equatable {
    case replace(LocalMetadataOverlayCache)
    case clear
}

struct LocalMetadataRefreshPlan: Equatable {
    let state: LocalMetadataRefreshState
    let cacheAction: LocalMetadataCacheAction
    let shouldPublishSnapshotCache: Bool
    let replayResetVersion: LocalMetadataTransportVersion?
    let logMessage: String?
}

enum LocalBootstrapMetadataResult: Equatable {
    case metadata(LocalBootstrapMetadataPayload)
    case deferred(LocalMetadataRefreshPlan)
}

enum LocalMetadataRefreshBoundary {
    static func bootstrapResult(
        from bootstrap: AgtmuxSyncV3Bootstrap,
        cache: LocalMetadataOverlayCache,
        inventoryCount: Int,
        bootstrapNotReadyBackoff: TimeInterval,
        now: Date = Date()
    ) -> LocalBootstrapMetadataResult {
        if inventoryCount > 0, bootstrap.panes.isEmpty {
            let state = LocalMetadataRefreshState(
                syncPrimed: false,
                transportVersion: nil,
                daemonIssue: nil,
                nextRefreshAt: now.addingTimeInterval(bootstrapNotReadyBackoff)
            )
            return .deferred(
                LocalMetadataRefreshPlan(
                    state: state,
                    cacheAction: .clear,
                    shouldPublishSnapshotCache: true,
                    replayResetVersion: .v3,
                    logMessage: "sync-v3 bootstrap not ready; local inventory has \(inventoryCount) panes but bootstrap returned panes=0"
                )
            )
        }

        return .metadata(
            LocalBootstrapMetadataPayload(
                cache: cache,
                transportVersion: .v3
            )
        )
    }

    static func publishPlan(
        cache: LocalMetadataOverlayCache,
        inventoryCount: Int,
        successInterval: TimeInterval,
        syncPrimed: Bool,
        transportVersion: LocalMetadataTransportVersion?,
        daemonIssue: LocalDaemonIssue?,
        now: Date = Date()
    ) -> LocalMetadataRefreshPlan {
        LocalMetadataRefreshPlan(
            state: LocalMetadataRefreshState(
                syncPrimed: syncPrimed,
                transportVersion: transportVersion,
                daemonIssue: daemonIssue,
                nextRefreshAt: now.addingTimeInterval(successInterval)
            ),
            cacheAction: .replace(cache),
            shouldPublishSnapshotCache: inventoryCount > 0,
            replayResetVersion: nil,
            logMessage: nil
        )
    }

    static func clearPlan(
        inventoryCount: Int,
        nextRefreshAt: Date,
        syncPrimed: Bool,
        transportVersion: LocalMetadataTransportVersion?,
        daemonIssue: LocalDaemonIssue?
    ) -> LocalMetadataRefreshPlan {
        LocalMetadataRefreshPlan(
            state: LocalMetadataRefreshState(
                syncPrimed: syncPrimed,
                transportVersion: transportVersion,
                daemonIssue: daemonIssue,
                nextRefreshAt: nextRefreshAt
            ),
            cacheAction: .clear,
            shouldPublishSnapshotCache: inventoryCount > 0,
            replayResetVersion: nil,
            logMessage: nil
        )
    }
}
