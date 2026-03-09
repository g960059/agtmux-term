import Foundation
import AgtmuxTermCore

enum LocalMetadataTransportVersion: Equatable {
    case v2
    case v3
}

enum LocalMetadataBootstrapSnapshot {
    case v2(AgtmuxSyncV2Bootstrap)
    case v3(AgtmuxSyncV3Bootstrap)

    var transportVersion: LocalMetadataTransportVersion {
        switch self {
        case .v2:
            return .v2
        case .v3:
            return .v3
        }
    }
}

/// Small transport adapter for required sync-v3 bootstrap fetches.
///
/// Product code no longer consumes any sync-v2 fallback selector here.
/// `AppViewModel` requires sync-v3 and surfaces incompatibility explicitly.
final class LocalMetadataTransportBridge {
    func fetchRequiredBootstrapV3(using client: any LocalMetadataClient) async throws -> AgtmuxSyncV3Bootstrap {
        try await client.fetchUIBootstrapV3()
    }
}
