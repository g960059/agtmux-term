import Foundation

package protocol AgtmuxSyncV3Transport: Sendable {
    func fetchBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap
    func fetchChangesV3(cursor: AgtmuxSyncV3Cursor, limit: Int) async throws -> AgtmuxSyncV3ChangesResponse
    func waitForChangesV1(cursor: AgtmuxSyncV3Cursor, timeoutMs: UInt64) async throws -> AgtmuxSyncV3ChangesResponse
}

extension AgtmuxSyncV3Transport {
    package func waitForChangesV1(cursor: AgtmuxSyncV3Cursor, timeoutMs: UInt64) async throws -> AgtmuxSyncV3ChangesResponse {
        try await fetchChangesV3(cursor: cursor, limit: 256)
    }
}

package enum AgtmuxSyncV3SessionError: Error, Equatable {
    case bootstrapRequired
}

package actor AgtmuxSyncV3Session {
    private let transport: any AgtmuxSyncV3Transport
    private var nextCursor: AgtmuxSyncV3Cursor?

    package init(transport: any AgtmuxSyncV3Transport) {
        self.transport = transport
    }

    package func bootstrap() async throws -> AgtmuxSyncV3Bootstrap {
        let bootstrap = try await transport.fetchBootstrapV3()
        nextCursor = bootstrap.replayCursor
        return bootstrap
    }

    package func pollChanges(limit: Int = 256) async throws -> AgtmuxSyncV3ChangesResponse {
        guard let nextCursor else {
            throw AgtmuxSyncV3SessionError.bootstrapRequired
        }

        let response = try await transport.fetchChangesV3(cursor: nextCursor, limit: limit)
        switch response {
        case let .changes(payload):
            self.nextCursor = payload.nextCursor
        case .resyncRequired:
            self.nextCursor = nil
        }
        return response
    }

    package func waitForChangesV1(timeoutMs: UInt64) async throws -> AgtmuxSyncV3ChangesResponse {
        guard let nextCursor else {
            throw AgtmuxSyncV3SessionError.bootstrapRequired
        }
        let response = try await transport.waitForChangesV1(cursor: nextCursor, timeoutMs: timeoutMs)
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

    package func currentCursor() -> AgtmuxSyncV3Cursor? {
        nextCursor
    }
}
