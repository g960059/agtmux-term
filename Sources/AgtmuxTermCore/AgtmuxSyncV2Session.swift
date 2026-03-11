import Foundation

/// sync-v2 compat: remove after daemon drops v2 endpoints.
package protocol AgtmuxSyncV2Transport: Sendable {
    func fetchBootstrapV2() async throws -> AgtmuxSyncV2Bootstrap
    func fetchChangesV2(cursor: AgtmuxSyncV2Cursor, limit: Int) async throws -> AgtmuxSyncV2ChangesResponse
}

package enum AgtmuxSyncV2SessionError: Error, Equatable {
    case bootstrapRequired
}

package actor AgtmuxSyncV2Session {
    private let transport: any AgtmuxSyncV2Transport
    private var nextCursor: AgtmuxSyncV2Cursor?

    package init(transport: any AgtmuxSyncV2Transport) {
        self.transport = transport
    }

    package func bootstrap() async throws -> AgtmuxSyncV2Bootstrap {
        let bootstrap = try await transport.fetchBootstrapV2()
        nextCursor = bootstrap.replayCursor
        return bootstrap
    }

    package func pollChanges(limit: Int = 256) async throws -> AgtmuxSyncV2ChangesResponse {
        guard let nextCursor else {
            throw AgtmuxSyncV2SessionError.bootstrapRequired
        }

        let response = try await transport.fetchChangesV2(cursor: nextCursor, limit: limit)
        switch response {
        case let .changes(payload):
            self.nextCursor = payload.nextCursor
        case .resyncRequired:
            self.nextCursor = nil
        }
        return response
    }

    package func reset() {
        nextCursor = nil
    }

    package func currentCursor() -> AgtmuxSyncV2Cursor? {
        nextCursor
    }
}
