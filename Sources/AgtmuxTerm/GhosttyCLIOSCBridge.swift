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
    case unsupportedKind(String)
    case unsupportedPlacement(String)
    case emptyTarget
    case emptyCwd
    case emptyArgument
    case emptyClientTTY
    case invalidURL(String)
    case relativeFilePath(String)
    case surfaceResolution(GhosttyTerminalSurfaceRegistryError)
    case dispatch(WorkbenchV2BridgeDispatchError)

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
        case .unsupportedKind(let kind):
            return "CLI bridge kind '\(kind)' is unsupported"
        case .unsupportedPlacement(let placement):
            return "CLI bridge placement '\(placement)' is unsupported"
        case .emptyTarget:
            return "CLI bridge target must be non-empty"
        case .emptyCwd:
            return "CLI bridge cwd must be non-empty"
        case .emptyArgument:
            return "CLI bridge argument must be non-empty"
        case .emptyClientTTY:
            return "CLI bridge rendered client tty must be non-empty"
        case .invalidURL(let argument):
            return "CLI bridge URL argument '\(argument)' is invalid"
        case .relativeFilePath(let argument):
            return "CLI bridge file argument '\(argument)' must be absolute"
        case .surfaceResolution(let error):
            return error.description
        case .dispatch(let error):
            return error.description
        }
    }
}

enum GhosttyCLIOSCBridgeAction: Equatable {
    case open(WorkbenchV2BridgeRequest)
    case bindClientTTY(String)
}

enum GhosttyCLIOSCBridgeResult: Equatable {
    case bridge(WorkbenchV2BridgeDispatchResult)
    case boundClientTTY(String)
}

enum GhosttyCLIOSCBridge {
    static let command: UInt16 = 9911

    @MainActor
    static func dispatchIfBridgeAction(
        target: ghostty_target_s,
        action: ghostty_action_s,
        store: WorkbenchStoreV2,
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

        case .open(let request):
            let surfaceContext: GhosttyTerminalSurfaceContext
            do {
                surfaceContext = try registry.requireContext(forTarget: target)
            } catch let error as GhosttyTerminalSurfaceRegistryError {
                throw GhosttyCLIOSCBridgeError.surfaceResolution(error)
            }
            do {
                let result = try store.dispatchBridgeRequest(request, from: surfaceContext)
                return .bridge(result)
            } catch let error as WorkbenchV2BridgeDispatchError {
                throw GhosttyCLIOSCBridgeError.dispatch(error)
            }
        }
    }

    static func decodeRequest(from data: Data) throws -> WorkbenchV2BridgeRequest {
        switch try decodeAction(from: data) {
        case .open(let request):
            return request
        case .bindClientTTY:
            throw GhosttyCLIOSCBridgeError.unsupportedAction("bind_client")
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
        case "open":
            return .open(try decodeOpenRequest(from: payloadData))
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

    private static func decodeOpenRequest(from payloadData: Data) throws -> WorkbenchV2BridgeRequest {
        let rawPayload: OpenPayload
        do {
            rawPayload = try JSONDecoder().decode(OpenPayload.self, from: payloadData)
        } catch {
            throw GhosttyCLIOSCBridgeError.malformedJSON(error.localizedDescription)
        }

        guard !rawPayload.target.isEmpty else {
            throw GhosttyCLIOSCBridgeError.emptyTarget
        }
        guard !rawPayload.cwd.isEmpty else {
            throw GhosttyCLIOSCBridgeError.emptyCwd
        }
        guard !rawPayload.argument.isEmpty else {
            throw GhosttyCLIOSCBridgeError.emptyArgument
        }

        guard let placement = WorkbenchV2Placement(rawValue: rawPayload.placement) else {
            throw GhosttyCLIOSCBridgeError.unsupportedPlacement(rawPayload.placement)
        }

        let target = targetRef(from: rawPayload.target)
        switch rawPayload.kind {
        case "url":
            guard let url = URL(string: rawPayload.argument), url.scheme != nil else {
                throw GhosttyCLIOSCBridgeError.invalidURL(rawPayload.argument)
            }

            return .browser(
                url: url,
                sourceContext: "\(target.label): \(rawPayload.cwd)",
                placement: placement,
                pin: rawPayload.pin
            )

        case "file":
            guard rawPayload.argument.hasPrefix("/") else {
                throw GhosttyCLIOSCBridgeError.relativeFilePath(rawPayload.argument)
            }

            return .document(
                ref: DocumentRef(target: target, path: rawPayload.argument),
                placement: placement,
                pin: rawPayload.pin
            )

        default:
            throw GhosttyCLIOSCBridgeError.unsupportedKind(rawPayload.kind)
        }
    }

    private static func targetRef(from rawTarget: String) -> TargetRef {
        if rawTarget == "local" {
            return .local
        }

        return .remote(hostKey: rawTarget)
    }

    private struct RawHeader: Decodable {
        let version: Int
        let action: String
    }

    private struct OpenPayload: Decodable {
        let version: Int
        let action: String
        let kind: String
        let target: String
        let cwd: String
        let argument: String
        let placement: String
        let pin: Bool
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
