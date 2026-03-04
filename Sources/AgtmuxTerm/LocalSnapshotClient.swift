import AgtmuxTermCore

protocol LocalSnapshotClient {
    func fetchSnapshot() async throws -> AgtmuxSnapshot
}

extension AgtmuxDaemonClient: LocalSnapshotClient {}
