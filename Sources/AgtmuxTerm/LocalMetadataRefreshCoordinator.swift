import Foundation
import AgtmuxTermCore

struct LocalMetadataRefreshContext: Equatable {
    let syncPrimed: Bool
    let transportVersion: LocalMetadataTransportVersion?
    let inventoryCount: Int
    let successInterval: TimeInterval
    let failureBackoff: TimeInterval
    let bootstrapNotReadyBackoff: TimeInterval
    let changeLimit: Int
}

struct LocalMetadataRefreshExecution: Equatable {
    let preApplyLogMessages: [String]
    let replayResetVersions: [LocalMetadataTransportVersion]
    let plan: LocalMetadataRefreshPlan
    let postApplyLogMessages: [String]
}

final class LocalMetadataRefreshCoordinator {
    private let client: any LocalMetadataClient
    private let transportBridge: LocalMetadataTransportBridge
    private let now: () -> Date

    init(
        client: any LocalMetadataClient,
        transportBridge: LocalMetadataTransportBridge,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.transportBridge = transportBridge
        self.now = now
    }

    func runStep(
        context: LocalMetadataRefreshContext,
        overlayStore: LocalMetadataOverlayStore
    ) async throws -> LocalMetadataRefreshExecution {
        if !context.syncPrimed {
            return try await bootstrapExecution(
                context: context,
                overlayStore: overlayStore,
                preApplyLogMessages: [],
                additionalResetVersions: []
            )
        }

        switch context.transportVersion ?? .v2 {
        case .v2:
            let response = try await client.fetchUIChangesV2(limit: context.changeLimit)
            switch response {
            case let .changes(payload):
                return LocalMetadataRefreshExecution(
                    preApplyLogMessages: [],
                    replayResetVersions: [],
                    plan: LocalMetadataRefreshBoundary.publishPlan(
                        cache: LocalMetadataOverlayCache(
                            metadataByPaneKey: overlayStore.apply(payload),
                            presentationByPaneKey: [:]
                        ),
                        inventoryCount: context.inventoryCount,
                        successInterval: context.successInterval,
                        syncPrimed: true,
                        transportVersion: .v2,
                        daemonIssue: nil,
                        now: now()
                    ),
                    postApplyLogMessages: []
                )
            case let .resyncRequired(payload):
                return try await bootstrapExecution(
                    context: context,
                    overlayStore: overlayStore,
                    preApplyLogMessages: [
                        "sync-v2 resync required; reason=\(payload.reason) epoch=\(payload.currentEpoch) snapshot_seq=\(payload.latestSnapshotSeq)"
                    ],
                    additionalResetVersions: [.v2]
                )
            }
        case .v3:
            do {
                let response = try await client.fetchUIChangesV3(limit: context.changeLimit)
                switch response {
                case let .changes(payload):
                    return LocalMetadataRefreshExecution(
                        preApplyLogMessages: [],
                        replayResetVersions: [],
                        plan: LocalMetadataRefreshBoundary.publishPlan(
                            cache: overlayStore.apply(payload),
                            inventoryCount: context.inventoryCount,
                            successInterval: context.successInterval,
                            syncPrimed: true,
                            transportVersion: .v3,
                            daemonIssue: nil,
                            now: now()
                        ),
                        postApplyLogMessages: []
                    )
                case let .resyncRequired(payload):
                    return try await bootstrapExecution(
                        context: context,
                        overlayStore: overlayStore,
                        preApplyLogMessages: [
                            "sync-v3 resync required; reason=\(payload.reason) latest_snapshot_seq=\(payload.latestSnapshotSeq)"
                        ],
                        additionalResetVersions: [.v3]
                    )
                }
            } catch {
                guard transportBridge.markV3UnsupportedIfNeeded(error) else {
                    throw error
                }
                return try await bootstrapExecution(
                    context: context,
                    overlayStore: overlayStore,
                    preApplyLogMessages: [],
                    additionalResetVersions: [.v3]
                )
            }
        }
    }

    func failureExecution(
        context: LocalMetadataRefreshContext,
        error: any Error,
        classifyLocalDaemonIssue: (any Error) -> LocalDaemonIssue?
    ) -> LocalMetadataRefreshExecution {
        LocalMetadataRefreshExecution(
            preApplyLogMessages: [],
            replayResetVersions: [activeReplayResetVersion(for: context.transportVersion)],
            plan: LocalMetadataRefreshBoundary.clearPlan(
                inventoryCount: context.inventoryCount,
                nextRefreshAt: now().addingTimeInterval(context.failureBackoff),
                syncPrimed: false,
                transportVersion: nil,
                daemonIssue: classifyLocalDaemonIssue(error)
            ),
            postApplyLogMessages: [
                "sync metadata unavailable; cleared cached overlay: \(error)"
            ]
        )
    }

    private func bootstrapExecution(
        context: LocalMetadataRefreshContext,
        overlayStore: LocalMetadataOverlayStore,
        preApplyLogMessages: [String],
        additionalResetVersions: [LocalMetadataTransportVersion]
    ) async throws -> LocalMetadataRefreshExecution {
        let bootstrap = try await transportBridge.fetchBootstrap(using: client)
        let cache: LocalMetadataOverlayCache
        switch bootstrap {
        case .v3(let snapshot):
            cache = try overlayStore.bootstrapCaches(from: snapshot)
        case .v2(let snapshot):
            cache = LocalMetadataOverlayCache(
                metadataByPaneKey: try overlayStore.bootstrapMetadataMap(from: snapshot.panes),
                presentationByPaneKey: [:]
            )
        }

        switch LocalMetadataRefreshBoundary.bootstrapResult(
            from: bootstrap,
            cache: cache,
            inventoryCount: context.inventoryCount,
            bootstrapNotReadyBackoff: context.bootstrapNotReadyBackoff,
            now: now()
        ) {
        case let .metadata(payload):
            return LocalMetadataRefreshExecution(
                preApplyLogMessages: preApplyLogMessages,
                replayResetVersions: additionalResetVersions,
                plan: LocalMetadataRefreshBoundary.publishPlan(
                    cache: payload.cache,
                    inventoryCount: context.inventoryCount,
                    successInterval: context.successInterval,
                    syncPrimed: true,
                    transportVersion: payload.transportVersion,
                    daemonIssue: nil,
                    now: now()
                ),
                postApplyLogMessages: []
            )
        case let .deferred(plan):
            var resets = additionalResetVersions
            if let replayResetVersion = plan.replayResetVersion {
                resets.append(replayResetVersion)
            }
            return LocalMetadataRefreshExecution(
                preApplyLogMessages: preApplyLogMessages,
                replayResetVersions: resets,
                plan: plan,
                postApplyLogMessages: []
            )
        }
    }

    private func activeReplayResetVersion(for transportVersion: LocalMetadataTransportVersion?) -> LocalMetadataTransportVersion {
        switch transportVersion {
        case .v3:
            return .v3
        case .v2:
            return .v2
        case nil:
            return transportBridge.prefersSyncV3 ? .v3 : .v2
        }
    }
}
