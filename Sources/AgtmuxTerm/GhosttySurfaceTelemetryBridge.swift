import Foundation
import GhosttyKit

enum GhosttySurfaceTelemetryBridgeError: Error, Equatable, CustomStringConvertible {
    case invalidUTF8
    case emptyClientTTY
    case invalidPayloadLength(UInt)
    case missingPayloadBytes
    case surfaceResolution(GhosttyTerminalSurfaceRegistryError)

    var description: String {
        switch self {
        case .invalidUTF8:
            return "surface telemetry payload must be valid UTF-8"
        case .emptyClientTTY:
            return "surface telemetry client tty must be non-empty"
        case .invalidPayloadLength(let length):
            return "surface telemetry payload length \(length) exceeds Int capacity"
        case .missingPayloadBytes:
            return "surface telemetry payload bytes are missing"
        case .surfaceResolution(let error):
            return error.description
        }
    }
}

enum GhosttySurfaceTelemetryBridge {
    static let command: UInt16 = 9912

    @MainActor
    static func recordIfTelemetryAction(
        target: ghostty_target_s,
        action: ghostty_action_s,
        registry: GhosttyTerminalSurfaceRegistry? = nil
    ) throws -> Bool {
        guard action.tag == GHOSTTY_ACTION_CUSTOM_OSC else { return false }

        let customOSC = action.action.custom_osc
        guard customOSC.osc == command else { return false }

        let clientTTY = try decodeClientTTY(customOSC)
        let registry = registry ?? .shared
        do {
            try registry.register(clientTTY: clientTTY, forTarget: target)
        } catch let error as GhosttyTerminalSurfaceRegistryError {
            throw GhosttySurfaceTelemetryBridgeError.surfaceResolution(error)
        }
        return true
    }

    static func decodeClientTTY(
        _ customOSC: ghostty_action_custom_osc_s
    ) throws -> String {
        guard let length = Int(exactly: customOSC.len) else {
            throw GhosttySurfaceTelemetryBridgeError.invalidPayloadLength(UInt(customOSC.len))
        }
        guard length >= 0 else {
            throw GhosttySurfaceTelemetryBridgeError.invalidPayloadLength(UInt(customOSC.len))
        }
        guard let payload = customOSC.payload else {
            throw GhosttySurfaceTelemetryBridgeError.missingPayloadBytes
        }

        let data = Data(bytes: payload, count: length)
        guard let rawTTY = String(data: data, encoding: .utf8) else {
            throw GhosttySurfaceTelemetryBridgeError.invalidUTF8
        }
        let trimmedTTY = rawTTY.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else {
            throw GhosttySurfaceTelemetryBridgeError.emptyClientTTY
        }
        return trimmedTTY
    }
}
