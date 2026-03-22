import Foundation

enum TerminalHostMode: String, Equatable, Codable, CaseIterable {
    case legacy
    case next

    static let environmentKey = "AGTMUX_TERMINAL_HOST_MODE"

    init(environment: [String: String]) {
        self = Self.parse(environment[Self.environmentKey]) ?? .legacy
    }

    static func parse(_ rawValue: String?) -> Self? {
        guard let rawValue else { return nil }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "legacy", "current":
            return .legacy
        case "next", "native", "renderer-owned":
            return .next
        default:
            return nil
        }
    }
}
