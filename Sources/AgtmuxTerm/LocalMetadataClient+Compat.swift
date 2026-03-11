import Foundation
import AgtmuxTermCore

/// sync-v2 compat: remove after daemon drops v2 endpoints.
///
/// Product `AppViewModel` code must not depend on this surface.
protocol LocalMetadataClient: ProductLocalMetadataClient {
    func fetchUIBootstrapV2() async throws -> AgtmuxSyncV2Bootstrap
    func fetchUIChangesV2(limit: Int) async throws -> AgtmuxSyncV2ChangesResponse
    func resetUIChangesV2() async
}
