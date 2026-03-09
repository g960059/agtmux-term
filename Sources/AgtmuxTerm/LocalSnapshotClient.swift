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

protocol ProductLocalMetadataClient: LocalSnapshotClient {
    func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap
    func fetchUIChangesV3(limit: Int) async throws -> AgtmuxSyncV3ChangesResponse
    func resetUIChangesV3() async
}

protocol LocalMetadataClient: ProductLocalMetadataClient {
    func fetchUIBootstrapV2() async throws -> AgtmuxSyncV2Bootstrap
    func fetchUIChangesV2(limit: Int) async throws -> AgtmuxSyncV2ChangesResponse
    func resetUIChangesV2() async
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

extension AgtmuxDaemonClient: LocalMetadataClient, LocalHealthClient {}
extension AgtmuxDaemonXPCClient: LocalHealthClient {}
