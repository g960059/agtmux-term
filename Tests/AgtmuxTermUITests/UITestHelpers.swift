import XCTest
import AppKit
import AgtmuxTermCore

enum TestConstants {
    static let surfaceReadyTimeout: TimeInterval = 15.0
    static let sidebarPopulateTimeout: TimeInterval = 10.0
    /// Initial render timeout. Ghostty initialisation + Metal setup can take several seconds.
    static let settleTimeout: TimeInterval = 10.0
}

extension XCUIApplication {
    /// Launch with UITest environment.
    ///
    /// Waits for any stale AgtmuxTerm process to fully exit before calling launch().
    /// This prevents the "Failed to activate (current state: Running Background)" race that
    /// occurs when the previous test's tearDown terminates the app but NSApplication teardown
    /// (Metal/Ghostty dealloc) takes long enough that the process is still alive when the
    /// next test's launch() runs.
    ///
    /// The app installs a SIGTERM handler that calls exit(0) immediately, so the process
    /// should be gone within milliseconds of terminate(). The NSRunningApplication poll below
    /// is a safety net for any residual OS state.
    func launchForUITest() {
        let preserveTmux = launchEnvironment["AGTMUX_UITEST_PRESERVE_TMUX"] == "1"
        if !preserveTmux {
            launchEnvironment["TMUX"] = ""
            launchEnvironment["TMUX_PANE"] = ""
        } else {
            if launchEnvironment["TMUX"] == nil {
                launchEnvironment["TMUX"] = ""
            }
            if launchEnvironment["TMUX_PANE"] == nil {
                launchEnvironment["TMUX_PANE"] = ""
            }
        }
        launchEnvironment["AGTMUX_UITEST"] = "1"

        // 1. Ask XCUITest to terminate any instance it knows about.
        if state != .notRunning {
            terminate()
        }

        // 2. Wait for the OS to fully reap all instances (handles both XCUITest-tracked
        //    instances and orphaned processes launched outside XCUITest).
        //    NSRunningApplication.runningApplications() is a read-only query — allowed
        //    even in sandboxed test runners.
        let bundleID = "local.agtmux.term.app"
        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            let still = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if still.isEmpty { break }
            // Attempt force-terminate (best-effort; may be blocked by sandbox).
            still.forEach { $0.forceTerminate() }
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 3. Small buffer so the OS can fully reap the process entry.
        Thread.sleep(forTimeInterval: 0.5)

        launch()
    }
}
