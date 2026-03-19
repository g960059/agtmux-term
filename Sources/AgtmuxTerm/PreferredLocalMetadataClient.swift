import Foundation
import AgtmuxTermCore

actor PreferredLocalMetadataClient: LocalMetadataHealthClient {
    private enum State {
        case primary
        case fallback
    }

    private let primary: (any LocalMetadataHealthClient)?
    private let fallback: any LocalMetadataHealthClient
    private let startFallbackRuntimeIfNeeded: @Sendable () async -> Void
    private let log: @Sendable (String) -> Void
    private var state: State

    init(
        primary: (any LocalMetadataHealthClient)?,
        fallback: any LocalMetadataHealthClient,
        startFallbackRuntimeIfNeeded: @escaping @Sendable () async -> Void = {},
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.startFallbackRuntimeIfNeeded = startFallbackRuntimeIfNeeded
        self.log = log
        self.state = primary == nil ? .fallback : .primary
    }

    func fetchSnapshot() async throws -> AgtmuxSnapshot {
        try await perform(operation: "fetchSnapshot") { client in
            try await client.fetchSnapshot()
        }
    }

    func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
        try await perform(operation: "fetchUIBootstrapV3") { client in
            try await client.fetchUIBootstrapV3()
        }
    }

    func fetchUIChangesV3(limit: Int) async throws -> AgtmuxSyncV3ChangesResponse {
        try await perform(operation: "fetchUIChangesV3") { client in
            try await client.fetchUIChangesV3(limit: limit)
        }
    }

    func waitForUIChangesV1(timeoutMs: UInt64) async throws -> AgtmuxSyncV3ChangesResponse {
        try await perform(operation: "waitForUIChangesV1") { client in
            try await client.waitForUIChangesV1(timeoutMs: timeoutMs)
        }
    }

    func fetchUIHealthV1() async throws -> AgtmuxUIHealthV1 {
        try await perform(operation: "fetchUIHealthV1") { client in
            try await client.fetchUIHealthV1()
        }
    }

    func resetUIChangesV3() async {
        if let primary {
            await primary.resetUIChangesV3()
        }
        await fallback.resetUIChangesV3()
    }

    private func perform<T>(
        operation: String,
        _ body: @escaping @Sendable (any LocalMetadataHealthClient) async throws -> T
    ) async throws -> T {
        switch state {
        case .fallback:
            await startFallbackRuntimeIfNeeded()
            return try await body(fallback)
        case .primary:
            guard let primary else {
                state = .fallback
                await startFallbackRuntimeIfNeeded()
                return try await body(fallback)
            }

            do {
                return try await body(primary)
            } catch {
                guard shouldFallback(from: error) else {
                    throw error
                }
                state = .fallback
                log(
                    "AgtmuxTerm: XPC daemon client failed during \(operation) (\(fallbackLogMessage(for: error))); falling back to socket daemon runtime.\n"
                )
                await startFallbackRuntimeIfNeeded()
                return try await body(fallback)
            }
        }
    }

    private func shouldFallback(from error: Error) -> Bool {
        if let xpcError = error as? XPCClientError {
            switch xpcError {
            case .unavailable, .proxyUnavailable, .timeout:
                return true
            case let .remote(message), let .decode(message):
                return looksLikeUnavailable(message)
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           Set([4097, 4099]).contains(nsError.code) {
            return true
        }

        return looksLikeUnavailable(fallbackLogMessage(for: error))
    }

    private func looksLikeUnavailable(_ message: String) -> Bool {
        let normalized = message.lowercased()
        let needles = [
            "daemonservice",
            "xpc",
            "no such process",
            "connection invalid",
            "connection interrupted",
            "service name",
        ]
        return needles.contains(where: normalized.contains)
    }

    private func fallbackLogMessage(for error: Error) -> String {
        let nsError = error as NSError
        if !nsError.localizedDescription.isEmpty,
           nsError.localizedDescription != String(describing: error) {
            return nsError.localizedDescription
        }
        return String(describing: error)
    }
}
