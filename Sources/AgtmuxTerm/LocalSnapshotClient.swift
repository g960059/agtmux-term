import Foundation
import AgtmuxTermCore

enum LocalHealthClientError: Error, Equatable {
    case unsupportedMethod(String)
}

enum LocalMetadataClientError: Error, Equatable {
    case unsupportedMethod(String)
}

protocol LocalSnapshotClient {
    func fetchSnapshot() async throws -> AgtmuxSnapshot
}

protocol LocalHealthClient {
    func fetchUIHealthV1() async throws -> AgtmuxUIHealthV1
}

/// Product-facing local metadata surface.
/// Product code should consume snapshot + sync-v3 metadata + health only.
protocol ProductLocalMetadataClient: LocalSnapshotClient {
    func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap
    func fetchUIChangesV3(limit: Int) async throws -> AgtmuxSyncV3ChangesResponse
    func resetUIChangesV3() async
}

extension ProductLocalMetadataClient {
    func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
        throw LocalMetadataClientError.unsupportedMethod("ui.bootstrap.v3")
    }

    func fetchUIChangesV3(limit: Int) async throws -> AgtmuxSyncV3ChangesResponse {
        throw LocalMetadataClientError.unsupportedMethod("ui.changes.v3")
    }

    func resetUIChangesV3() async {}
}

extension AgtmuxDaemonClient: ProductLocalMetadataClient, LocalHealthClient {}
extension AgtmuxDaemonXPCClient: LocalHealthClient {}
