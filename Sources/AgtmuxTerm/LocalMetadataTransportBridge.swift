import Foundation
import AgtmuxTermCore

enum LocalMetadataTransportVersion: Equatable {
    case v2
    case v3
}

enum LocalMetadataBootstrapSnapshot {
    case v2(AgtmuxSyncV2Bootstrap)
    case v3(AgtmuxSyncV3Bootstrap)

    var transportVersion: LocalMetadataTransportVersion {
        switch self {
        case .v2:
            return .v2
        case .v3:
            return .v3
        }
    }
}

/// Small transport/fallback adapter for local metadata bootstrap/replay selection.
///
/// The daemon remains authoritative for payload truth. This adapter only decides
/// whether the term client should stay on sync-v3 or drop to sync-v2 when the
/// daemon explicitly reports that the v3 methods are unavailable.
final class LocalMetadataTransportBridge {
    private(set) var prefersSyncV3 = true

    func fetchBootstrap(using client: any LocalMetadataClient) async throws -> LocalMetadataBootstrapSnapshot {
        if prefersSyncV3 {
            do {
                return .v3(try await client.fetchUIBootstrapV3())
            } catch {
                guard markV3UnsupportedIfNeeded(error) else {
                    throw error
                }
            }
        }

        return .v2(try await client.fetchUIBootstrapV2())
    }

    @discardableResult
    func markV3UnsupportedIfNeeded(_ error: any Error) -> Bool {
        guard Self.shouldFallbackToSyncV2(from: error) else {
            return false
        }
        prefersSyncV3 = false
        return true
    }

    static func shouldFallbackToSyncV2(from error: any Error) -> Bool {
        if let metadataError = error as? LocalMetadataClientError {
            if case let .unsupportedMethod(method) = metadataError,
               method == "ui.bootstrap.v3" || method == "ui.changes.v3" {
                return true
            }
        }

        if let daemonError = error as? DaemonError {
            switch daemonError {
            case .daemonUnavailable:
                break
            case let .processError(_, stderr):
                if DaemonError.decodeUIErrorEnvelope(from: stderr)?.code == DaemonUIErrorCode.syncV3MethodNotFound.rawValue {
                    return true
                }
            case let .parseError(message):
                if DaemonError.decodeUIErrorEnvelope(from: message)?.code == DaemonUIErrorCode.syncV3MethodNotFound.rawValue {
                    return true
                }
            }
        }

        if let xpcError = error as? XPCClientError {
            switch xpcError {
            case .unavailable, .proxyUnavailable:
                break
            case let .remote(message), let .decode(message), let .timeout(message):
                if DaemonError.decodeUIErrorEnvelope(from: message)?.code == DaemonUIErrorCode.syncV3MethodNotFound.rawValue {
                    return true
                }
            }
        }

        let normalized = String(describing: error).lowercased()
        let referencesV3Method = normalized.contains("ui.bootstrap.v3") || normalized.contains("ui.changes.v3")
        return referencesV3Method
            && (normalized.contains("-32601") || normalized.contains("method not found"))
    }
}
