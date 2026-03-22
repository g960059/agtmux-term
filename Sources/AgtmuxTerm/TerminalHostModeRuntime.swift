import Foundation
import Combine

@MainActor
final class TerminalHostModeRuntime: ObservableObject {
    static let shared = TerminalHostModeRuntime()

    @Published private(set) var overrideMode: TerminalHostMode?

    private init() {}

    func resolved(environment: [String: String]) -> TerminalHostMode {
        overrideMode ?? TerminalHostMode(environment: environment)
    }

    func setOverride(_ mode: TerminalHostMode?) {
        guard overrideMode != mode else { return }
        overrideMode = mode
    }

    func resetForTesting() {
        overrideMode = nil
    }
}
