import XCTest
import AppKit
import Darwin
import AgtmuxTermCore

enum TestConstants {
    static let surfaceReadyTimeout: TimeInterval = 15.0
    static let sidebarPopulateTimeout: TimeInterval = 10.0
    /// Initial render timeout. Ghostty initialisation + Metal setup can take several seconds.
    static let settleTimeout: TimeInterval = 10.0
    /// SLA for temporary pane switching inside the same window.
    /// 0.5s proved too tight under live XCUITest event-loop jitter, so keep
    /// a realistic but still strict budget.
    static let paneSwitchLatencyBudget: TimeInterval = 0.8
    /// Reverse-sync from tmux focus change to sidebar highlight can include
    /// a polling hop; keep a looser budget than direct sidebar clicks.
    static let focusSyncLatencyBudget: TimeInterval = 2.0
}

extension XCUIApplication {
    private func testedAppBundleURL(
        bundleID: String = "com.g960059.agtmux.term"
    ) -> URL? {
        let appName = "AgtmuxTerm.app"
        let runnerBundleURL = Bundle.main.bundleURL
        let candidateDirectories = [
            runnerBundleURL.deletingLastPathComponent(),
            runnerBundleURL.deletingLastPathComponent().deletingLastPathComponent()
        ]

        for directory in candidateDirectories {
            let candidate = directory.appendingPathComponent(appName, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private func launchViaWorkspaceForUITest(
        bundleID: String = "com.g960059.agtmux.term",
        requireForegroundAttachment: Bool
    ) {
        guard let appBundleURL = testedAppBundleURL(bundleID: bundleID) else {
            XCTFail("Failed to resolve tested app bundle URL for \(bundleID)")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = launchArguments
        configuration.environment = launchEnvironment
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        var launchedApplication: NSRunningApplication?

        NSWorkspace.shared.openApplication(at: appBundleURL, configuration: configuration) { app, error in
            launchedApplication = app
            launchError = error
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 15.0) == .timedOut {
            XCTFail("Timed out launching tested app bundle via NSWorkspace at \(appBundleURL.path)")
            return
        }

        if let launchError {
            XCTFail("Failed to launch tested app bundle via NSWorkspace: \(launchError.localizedDescription)")
            return
        }

        if let launchedApplication {
            _ = launchedApplication.activate(options: [.activateAllWindows])
        }

        guard requireForegroundAttachment else { return }
        activate()
        stabilizeForegroundForUITest(bundleID: bundleID)
    }

    private func runningExecutableProcessIDs(
        matching pattern: String
    ) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", pattern]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return []
        }

        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        return raw
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func stabilizeForegroundForUITest(
        bundleID: String = "com.g960059.agtmux.term",
        timeout: TimeInterval = 5.0
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .runningForeground {
                return
            }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if let app = running.first {
                _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                if app.isActive {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

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
        launchForUITest(inventoryOnly: true, requireForegroundAttachment: true)
    }

    /// Launch with UITest environment but keep metadata/health polling enabled.
    ///
    /// This is intended for focused UI coverage that needs inline metadata or
    /// `ui.health.v1` surfacing. Existing tests should keep using
    /// `launchForUITest()` unless they explicitly need metadata-enabled behavior.
    func launchForMetadataUITest() {
        launchForUITest(inventoryOnly: false, requireForegroundAttachment: true)
    }

    /// Launch with UITest environment through LaunchServices but do not ask XCUI
    /// to foreground-attach the app. This keeps bridge-driven real-surface tests
    /// runnable in sessions where `XCUIApplication.launch()` or `activate()` still
    /// fail with `Running Background`.
    func launchForBridgeDrivenUITest() {
        launchForUITest(inventoryOnly: true, requireForegroundAttachment: false)
    }

    private func launchForUITest(
        inventoryOnly: Bool,
        requireForegroundAttachment: Bool
    ) {
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
        if inventoryOnly {
            // Avoid `agtmux json` metadata subprocess during UI tests: inventory-only is
            // enough for sidebar/session/window/pane contracts and keeps launch responsive.
            launchEnvironment["AGTMUX_UITEST_INVENTORY_ONLY"] = "1"
            if launchEnvironment["AGTMUX_UITEST_ENABLE_MANAGED_DAEMON"] != "1" {
                launchEnvironment.removeValue(forKey: "AGTMUX_UITEST_ENABLE_MANAGED_DAEMON")
            }
        } else {
            launchEnvironment.removeValue(forKey: "AGTMUX_UITEST_INVENTORY_ONLY")
            launchEnvironment["AGTMUX_UITEST_ENABLE_MANAGED_DAEMON"] = "1"
        }
        if !launchArguments.contains("-ApplePersistenceIgnoreState") {
            launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        }
        if !launchArguments.contains("-NSQuitAlwaysKeepsWindows") {
            launchArguments += ["-NSQuitAlwaysKeepsWindows", "NO"]
        }

        // 1. Ask XCUITest to terminate any instance it knows about.
        if state != .notRunning {
            terminate()
        }

        // 2. Wait for the OS to fully reap all instances (handles both XCUITest-tracked
        //    instances and orphaned processes launched outside XCUITest).
        //    NSRunningApplication.runningApplications() is a read-only query — allowed
        //    even in sandboxed test runners.
        let bundleID = "com.g960059.agtmux.term"
        let gracefulDeadline = Date().addingTimeInterval(4.0)
        while Date() < gracefulDeadline {
            let still = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if still.isEmpty { break }
            still.forEach { _ = $0.terminate() }
            Thread.sleep(forTimeInterval: 0.2)
        }

        let forceDeadline = Date().addingTimeInterval(4.0)
        while Date() < forceDeadline {
            let still = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if still.isEmpty { break }
            still.forEach { _ = $0.forceTerminate() }
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Last-resort cleanup for "Running Background" zombies that still block activation.
        let stubborn = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if !stubborn.isEmpty {
            stubborn.forEach { app in
                _ = kill(pid_t(app.processIdentifier), SIGKILL)
            }
            let killVerifyDeadline = Date().addingTimeInterval(2.0)
            while Date() < killVerifyDeadline {
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        let executablePattern = "AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm"
        let stubbornPIDs = runningExecutableProcessIDs(matching: executablePattern)
        if !stubbornPIDs.isEmpty {
            stubbornPIDs.forEach { pid in
                _ = kill(pid, SIGKILL)
            }
            let pgrepVerifyDeadline = Date().addingTimeInterval(2.0)
            while Date() < pgrepVerifyDeadline {
                if runningExecutableProcessIDs(matching: executablePattern).isEmpty {
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        // 3. Small buffer so the OS can fully reap the process entry.
        Thread.sleep(forTimeInterval: 0.5)

        launchViaWorkspaceForUITest(
            bundleID: bundleID,
            requireForegroundAttachment: requireForegroundAttachment
        )
    }
}
