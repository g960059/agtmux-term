import XCTest
@testable import AgtmuxTermCore

final class AgtmuxSyncV3SessionTests: XCTestCase {
    private enum StubError: Error {
        case exhausted
    }

    private actor StubTransport: AgtmuxSyncV3Transport {
        private let bootstrapResult: AgtmuxSyncV3Bootstrap
        private var changeResults: [AgtmuxSyncV3ChangesResponse]
        private(set) var requestedCursors: [AgtmuxSyncV3Cursor] = []

        init(bootstrapResult: AgtmuxSyncV3Bootstrap, changeResults: [AgtmuxSyncV3ChangesResponse]) {
            self.bootstrapResult = bootstrapResult
            self.changeResults = changeResults
        }

        func fetchBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
            bootstrapResult
        }

        func fetchChangesV3(cursor: AgtmuxSyncV3Cursor, limit: Int) async throws -> AgtmuxSyncV3ChangesResponse {
            requestedCursors.append(cursor)
            guard !changeResults.isEmpty else {
                throw StubError.exhausted
            }
            return changeResults.removeFirst()
        }

        func cursors() -> [AgtmuxSyncV3Cursor] {
            requestedCursors
        }
    }

    private func bootstrap(replayCursor: AgtmuxSyncV3Cursor = .init(seq: 11)) -> AgtmuxSyncV3Bootstrap {
        AgtmuxSyncV3Bootstrap(
            version: 3,
            panes: [],
            generatedAt: Date(timeIntervalSince1970: 1_778_822_260),
            replayCursor: replayCursor
        )
    }

    private func changes(nextCursor: AgtmuxSyncV3Cursor) -> AgtmuxSyncV3ChangesResponse {
        .changes(
            AgtmuxSyncV3Changes(
                fromSeq: nextCursor.seq,
                toSeq: nextCursor.seq,
                nextCursor: nextCursor,
                changes: []
            )
        )
    }

    @MainActor
    func testPollChangesRequiresBootstrapFirst() async throws {
        let transport = StubTransport(bootstrapResult: bootstrap(), changeResults: [])
        let session = AgtmuxSyncV3Session(transport: transport)

        do {
            _ = try await session.pollChanges()
            XCTFail("expected bootstrapRequired")
        } catch let error as AgtmuxSyncV3SessionError {
            XCTAssertEqual(error, .bootstrapRequired)
        }
    }

    @MainActor
    func testBootstrapStoresReplayCursor() async throws {
        let transport = StubTransport(bootstrapResult: bootstrap(), changeResults: [])
        let session = AgtmuxSyncV3Session(transport: transport)

        let result = try await session.bootstrap()
        let currentCursor = await session.currentCursor()

        XCTAssertEqual(result.replayCursor, AgtmuxSyncV3Cursor(seq: 11))
        XCTAssertEqual(currentCursor, AgtmuxSyncV3Cursor(seq: 11))
    }

    @MainActor
    func testSuccessfulChangesAdvanceCursor() async throws {
        let transport = StubTransport(
            bootstrapResult: bootstrap(),
            changeResults: [changes(nextCursor: .init(seq: 12))]
        )
        let session = AgtmuxSyncV3Session(transport: transport)
        _ = try await session.bootstrap()

        let response = try await session.pollChanges()
        let currentCursor = await session.currentCursor()
        let requestedCursors = await transport.cursors()

        guard case .changes = response else {
            return XCTFail("expected changes response")
        }
        XCTAssertEqual(currentCursor, AgtmuxSyncV3Cursor(seq: 12))
        XCTAssertEqual(requestedCursors, [AgtmuxSyncV3Cursor(seq: 11)])
    }

    @MainActor
    func testResyncClearsCursorAndRequiresBootstrapAgain() async throws {
        let transport = StubTransport(
            bootstrapResult: bootstrap(),
            changeResults: [
                .resyncRequired(
                    AgtmuxSyncV3ResyncRequired(
                        latestSnapshotSeq: 99,
                        reason: "trimmed_cursor"
                    )
                )
            ]
        )
        let session = AgtmuxSyncV3Session(transport: transport)
        _ = try await session.bootstrap()

        let response = try await session.pollChanges()
        let currentCursor = await session.currentCursor()
        guard case let .resyncRequired(payload) = response else {
            return XCTFail("expected resync response")
        }
        XCTAssertEqual(payload.reason, "trimmed_cursor")
        XCTAssertNil(currentCursor)

        do {
            _ = try await session.pollChanges()
            XCTFail("expected bootstrapRequired after resync")
        } catch let error as AgtmuxSyncV3SessionError {
            XCTAssertEqual(error, .bootstrapRequired)
        }
    }
}
