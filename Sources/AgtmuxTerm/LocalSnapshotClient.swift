import Foundation
import AgtmuxTermCore

enum LocalHealthClientError: Error, Equatable {
    case unsupportedMethod(String)
}

protocol LocalSnapshotClient {
    func fetchSnapshot() async throws -> AgtmuxSnapshot
}

protocol LocalHealthClient {
    func fetchUIHealthV1() async throws -> AgtmuxUIHealthV1
}

protocol LocalMetadataClient: LocalSnapshotClient {
    func fetchUIBootstrapV2() async throws -> AgtmuxSyncV2Bootstrap
    func fetchUIChangesV2(limit: Int) async throws -> AgtmuxSyncV2ChangesResponse
    func resetUIChangesV2() async
}

extension AgtmuxDaemonClient: LocalMetadataClient, LocalHealthClient {}
extension AgtmuxDaemonXPCClient: LocalHealthClient {}
