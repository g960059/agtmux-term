import Foundation
import AgtmuxTermCore

enum LocalMetadataTransportVersion: Equatable {
    case v3
}

/// Small transport adapter for required sync-v3 bootstrap fetches.
///
/// Product code no longer consumes any sync-v2 fallback selector here.
/// `AppViewModel` requires sync-v3 and surfaces incompatibility explicitly.
final class LocalMetadataTransportBridge {
    func fetchRequiredBootstrapV3(using client: any ProductLocalMetadataClient) async throws -> AgtmuxSyncV3Bootstrap {
        try await client.fetchUIBootstrapV3()
    }
}
