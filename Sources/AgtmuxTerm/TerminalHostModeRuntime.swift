import Foundation
import Combine

@MainActor
final class TerminalHostModeRuntime: ObservableObject {
    static let shared = TerminalHostModeRuntime()

    @Published private(set) var overrideMode: TerminalHostMode?
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func resolved(environment: [String: String]) -> TerminalHostMode {
        if let overrideMode {
            return overrideMode
        }
        if let environmentMode = TerminalHostMode.parse(environment[TerminalHostMode.environmentKey]) {
            return environmentMode
        }
        if let defaultsMode = TerminalHostMode.parse(userDefaults.string(forKey: TerminalHostMode.userDefaultsKey)) {
            return defaultsMode
        }
        return .legacy
    }

    func setOverride(_ mode: TerminalHostMode?) {
        guard overrideMode != mode else { return }
        overrideMode = mode
    }

    func resetForTesting() {
        overrideMode = nil
    }
}
