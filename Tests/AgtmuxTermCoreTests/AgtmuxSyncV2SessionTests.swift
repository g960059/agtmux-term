import XCTest
@testable import AgtmuxTermCore

final class AgtmuxSyncV2SessionTests: XCTestCase {
    private enum StubError: Error {
        case exhausted
    }

    private actor StubTransport: AgtmuxSyncV2Transport {
        private let bootstrapResult: AgtmuxSyncV2Bootstrap
        private var changeResults: [AgtmuxSyncV2ChangesResponse]
        private(set) var requestedCursors: [AgtmuxSyncV2Cursor] = []

        init(bootstrapResult: AgtmuxSyncV2Bootstrap, changeResults: [AgtmuxSyncV2ChangesResponse]) {
            self.bootstrapResult = bootstrapResult
            self.changeResults = changeResults
        }

        func fetchBootstrapV2() async throws -> AgtmuxSyncV2Bootstrap {
            bootstrapResult
        }

        func fetchChangesV2(cursor: AgtmuxSyncV2Cursor, limit: Int) async throws -> AgtmuxSyncV2ChangesResponse {
            requestedCursors.append(cursor)
            guard !changeResults.isEmpty else {
                throw StubError.exhausted
            }
            return changeResults.removeFirst()
        }

        func cursors() -> [AgtmuxSyncV2Cursor] {
            requestedCursors
        }
    }

    private func bootstrap(replayCursor: AgtmuxSyncV2Cursor = .init(epoch: 3, seq: 11)) -> AgtmuxSyncV2Bootstrap {
        AgtmuxSyncV2Bootstrap(
            epoch: 3,
            snapshotSeq: 10,
            panes: [],
            sessions: [],
            generatedAt: Date(timeIntervalSince1970: 1_778_822_260),
            replayCursor: replayCursor
        )
    }

    private func changes(nextCursor: AgtmuxSyncV2Cursor) -> AgtmuxSyncV2ChangesResponse {
        .changes(
            AgtmuxSyncV2Changes(
                epoch: nextCursor.epoch,
                changes: [
                    AgtmuxSyncV2ChangeRef(
                        seq: nextCursor.seq - 1,
                        sessionKey: "dev",
                        paneId: "%42",
                        timestamp: Date(timeIntervalSince1970: 1_778_822_320)
                    )
                ],
                fromSeq: nextCursor.seq - 1,
                toSeq: nextCursor.seq - 1,
                nextCursor: nextCursor
            )
        )
    }

    @MainActor
    func testPollChangesRequiresBootstrapFirst() async throws {
        let transport = StubTransport(bootstrapResult: bootstrap(), changeResults: [])
        let session = AgtmuxSyncV2Session(transport: transport)

        do {
            _ = try await session.pollChanges()
            XCTFail("expected bootstrapRequired")
        } catch let error as AgtmuxSyncV2SessionError {
            XCTAssertEqual(error, .bootstrapRequired)
        }
    }

    @MainActor
    func testBootstrapStoresReplayCursor() async throws {
        let transport = StubTransport(bootstrapResult: bootstrap(), changeResults: [])
        let session = AgtmuxSyncV2Session(transport: transport)

        let result = try await session.bootstrap()
        let currentCursor = await session.currentCursor()

        XCTAssertEqual(result.replayCursor, AgtmuxSyncV2Cursor(epoch: 3, seq: 11))
        XCTAssertEqual(currentCursor, AgtmuxSyncV2Cursor(epoch: 3, seq: 11))
    }

    @MainActor
    func testSuccessfulChangesAdvanceCursor() async throws {
        let transport = StubTransport(
            bootstrapResult: bootstrap(),
            changeResults: [changes(nextCursor: .init(epoch: 3, seq: 12))]
        )
        let session = AgtmuxSyncV2Session(transport: transport)
        _ = try await session.bootstrap()

        let response = try await session.pollChanges()
        let currentCursor = await session.currentCursor()
        let requestedCursors = await transport.cursors()

        guard case .changes = response else {
            return XCTFail("expected changes response")
        }
        XCTAssertEqual(currentCursor, AgtmuxSyncV2Cursor(epoch: 3, seq: 12))
        XCTAssertEqual(requestedCursors, [AgtmuxSyncV2Cursor(epoch: 3, seq: 11)])
    }

    @MainActor
    func testResyncClearsCursorAndRequiresBootstrapAgain() async throws {
        let transport = StubTransport(
            bootstrapResult: bootstrap(),
            changeResults: [
                .resyncRequired(
                    AgtmuxSyncV2ResyncRequired(
                        currentEpoch: 4,
                        latestSnapshotSeq: 99,
                        reason: "epoch_mismatch"
                    )
                )
            ]
        )
        let session = AgtmuxSyncV2Session(transport: transport)
        _ = try await session.bootstrap()

        let response = try await session.pollChanges()
        let currentCursor = await session.currentCursor()
        guard case let .resyncRequired(payload) = response else {
            return XCTFail("expected resync response")
        }
        XCTAssertEqual(payload.reason, "epoch_mismatch")
        XCTAssertNil(currentCursor)

        do {
            _ = try await session.pollChanges()
            XCTFail("expected bootstrapRequired after resync")
        } catch let error as AgtmuxSyncV2SessionError {
            XCTAssertEqual(error, .bootstrapRequired)
        }
    }
}
