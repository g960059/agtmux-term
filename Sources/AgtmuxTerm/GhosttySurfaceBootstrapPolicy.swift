import AppKit

enum GhosttySurfaceBootstrapPolicy {
    static func shouldDeferInitialAttach(
        windowIsVisible: Bool,
        windowIsKey: Bool,
        appIsActive: Bool,
        hasExistingSurface: Bool,
        allowBackgroundAttach: Bool = false
    ) -> Bool {
        guard hasExistingSurface == false else { return false }
        guard allowBackgroundAttach == false else { return false }
        guard windowIsVisible else { return true }
        return appIsActive == false || windowIsKey == false
    }

    static func allowBackgroundInitialAttach(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        UITestTmuxBridge.automationRequested(environment: environment, userDefaults: userDefaults)
            || UITestTmuxBridge.bridgeRequested(environment: environment, userDefaults: userDefaults)
    }

    @MainActor
    static func shouldDeferInitialAttach(
        window: NSWindow?,
        appIsActive: Bool,
        hasExistingSurface: Bool,
        allowBackgroundAttach: Bool = allowBackgroundInitialAttach()
    ) -> Bool {
        shouldDeferInitialAttach(
            windowIsVisible: window?.isVisible ?? false,
            windowIsKey: window?.isKeyWindow ?? false,
            appIsActive: appIsActive,
            hasExistingSurface: hasExistingSurface,
            allowBackgroundAttach: allowBackgroundAttach
        )
    }
}
