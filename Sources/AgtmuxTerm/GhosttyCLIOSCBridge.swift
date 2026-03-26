import Foundation
import GhosttyKit
import AgtmuxTermCore

enum GhosttyCLIOSCBridgeError: Error, Equatable, CustomStringConvertible {
    case invalidPayloadLength(UInt)
    case missingPayloadBytes
    case invalidUTF8
    case malformedJSON(String)
    case payloadRootMustBeObject
    case unsupportedVersion(Int)
    case unsupportedAction(String)
    case emptyClientTTY
    case surfaceResolution(GhosttyTerminalSurfaceRegistryError)

    var description: String {
        switch self {
        case .invalidPayloadLength(let length):
            return "CLI bridge payload length \(length) exceeds supported bounds"
        case .missingPayloadBytes:
            return "CLI bridge payload bytes were missing"
        case .invalidUTF8:
            return "CLI bridge payload is not valid UTF-8"
        case .malformedJSON(let reason):
            return "CLI bridge payload is malformed JSON: \(reason)"
        case .payloadRootMustBeObject:
            return "CLI bridge payload must be a JSON object"
        case .unsupportedVersion(let version):
            return "CLI bridge payload version \(version) is unsupported"
        case .unsupportedAction(let action):
            return "CLI bridge action '\(action)' is unsupported"
        case .emptyClientTTY:
            return "CLI bridge rendered client tty must be non-empty"
        case .surfaceResolution(let error):
            return error.description
        }
    }
}

enum GhosttyCLIOSCBridgeAction: Equatable {
    case bindClientTTY(String)
}

enum GhosttyCLIOSCBridgeResult: Equatable {
    case boundClientTTY(String)
}

enum GhosttyCLIOSCBridge {
    static let command: UInt16 = 9911

    @MainActor
    static func dispatchIfBridgeAction(
        target: ghostty_target_s,
        action: ghostty_action_s,
        registry: GhosttyTerminalSurfaceRegistry? = nil
    ) throws -> GhosttyCLIOSCBridgeResult? {
        guard action.tag == GHOSTTY_ACTION_CUSTOM_OSC else { return nil }
        let registry = registry ?? .shared

        let customOSC = action.action.custom_osc
        guard customOSC.osc == command else { return nil }

        switch try decodeAction(customOSC) {
        case .bindClientTTY(let clientTTY):
            do {
                try registry.register(clientTTY: clientTTY, forTarget: target)
            } catch let error as GhosttyTerminalSurfaceRegistryError {
                throw GhosttyCLIOSCBridgeError.surfaceResolution(error)
            }
            return .boundClientTTY(clientTTY)
        }
    }

    static func decodeAction(from data: Data) throws -> GhosttyCLIOSCBridgeAction {
        let payloadData = try normalizedPayloadData(from: data)
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: payloadData)
        } catch {
            throw GhosttyCLIOSCBridgeError.malformedJSON(error.localizedDescription)
        }

        guard jsonObject is [String: Any] else {
            throw GhosttyCLIOSCBridgeError.payloadRootMustBeObject
        }

        let header: RawHeader
        do {
            header = try JSONDecoder().decode(RawHeader.self, from: payloadData)
        } catch {
            throw GhosttyCLIOSCBridgeError.malformedJSON(error.localizedDescription)
        }

        guard header.version == 1 else {
            throw GhosttyCLIOSCBridgeError.unsupportedVersion(header.version)
        }

        switch header.action {
        case "bind_client":
            let payload: BindClientPayload
            do {
                payload = try JSONDecoder().decode(BindClientPayload.self, from: payloadData)
            } catch {
                throw GhosttyCLIOSCBridgeError.malformedJSON(error.localizedDescription)
            }
            guard !payload.clientTTY.isEmpty else {
                throw GhosttyCLIOSCBridgeError.emptyClientTTY
            }
            return .bindClientTTY(payload.clientTTY)
        default:
            throw GhosttyCLIOSCBridgeError.unsupportedAction(header.action)
        }
    }

    private static func decodeAction(
        _ customOSC: ghostty_action_custom_osc_s
    ) throws -> GhosttyCLIOSCBridgeAction {
        guard customOSC.len <= Int.max else {
            throw GhosttyCLIOSCBridgeError.invalidPayloadLength(UInt(customOSC.len))
        }

        let length = Int(customOSC.len)
        if length == 0 {
            return try decodeAction(from: Data())
        }

        guard let payload = customOSC.payload else {
            throw GhosttyCLIOSCBridgeError.missingPayloadBytes
        }

        let data = Data(bytes: payload, count: length)
        return try decodeAction(from: data)
    }

    private static func normalizedPayloadData(from data: Data) throws -> Data {
        guard let payloadText = String(data: data, encoding: .utf8) else {
            throw GhosttyCLIOSCBridgeError.invalidUTF8
        }
        return Data(payloadText.utf8)
    }

    private struct RawHeader: Decodable {
        let version: Int
        let action: String
    }

    private struct BindClientPayload: Decodable {
        let version: Int
        let action: String
        let clientTTY: String

        private enum CodingKeys: String, CodingKey {
            case version
            case action
            case clientTTY = "client_tty"
        }
    }
}
