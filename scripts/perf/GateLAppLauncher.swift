import AppKit
import Foundation

struct GateLAppLaunchResult: Encodable {
    let appBundlePath: String
    let pid: pid_t?
    let isActive: Bool
    let error: String?
}

func parseArguments() throws -> (appBundlePath: String, launchArguments: [String]) {
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    guard let appBundlePath = iterator.next(), appBundlePath.isEmpty == false else {
        throw NSError(
            domain: "GateLAppLauncher",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "usage: gate_l_app_launcher <app-bundle-path> [--args ...]"]
        )
    }

    var launchArguments: [String] = []
    if let marker = iterator.next() {
        guard marker == "--args" else {
            throw NSError(
                domain: "GateLAppLauncher",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "unexpected argument: \(marker)"]
            )
        }
        launchArguments.append(contentsOf: iterator)
    }

    return (appBundlePath, launchArguments)
}

@main
enum GateLAppLauncherMain {
    static func main() {
        do {
            let parsed = try parseArguments()
            let appURL = URL(fileURLWithPath: parsed.appBundlePath, isDirectory: true)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.arguments = parsed.launchArguments
            configuration.promptsUserIfNeeded = false
            configuration.addsToRecentItems = false

            let semaphore = DispatchSemaphore(value: 0)
            var launchedApplication: NSRunningApplication?
            var launchError: Error?

            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
                launchedApplication = app
                launchError = error
                semaphore.signal()
            }

            if semaphore.wait(timeout: .now() + 20.0) == .timedOut {
                let result = GateLAppLaunchResult(
                    appBundlePath: parsed.appBundlePath,
                    pid: nil,
                    isActive: false,
                    error: "timed out waiting for NSWorkspace.openApplication"
                )
                emit(result, exitCode: 1)
            }

            if let launchError {
                let result = GateLAppLaunchResult(
                    appBundlePath: parsed.appBundlePath,
                    pid: nil,
                    isActive: false,
                    error: launchError.localizedDescription
                )
                emit(result, exitCode: 1)
            }

            guard let launchedApplication else {
                let result = GateLAppLaunchResult(
                    appBundlePath: parsed.appBundlePath,
                    pid: nil,
                    isActive: false,
                    error: "NSWorkspace.openApplication returned no app"
                )
                emit(result, exitCode: 1)
            }

            let deadline = Date().addingTimeInterval(5.0)
            while Date() < deadline {
                if launchedApplication.isActive {
                    break
                }
                _ = launchedApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                if let bundleIdentifier = launchedApplication.bundleIdentifier {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", "tell application id \"\(bundleIdentifier)\" to activate"]
                    process.standardOutput = Pipe()
                    process.standardError = Pipe()
                    try? process.run()
                    process.waitUntilExit()
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }

            let result = GateLAppLaunchResult(
                appBundlePath: parsed.appBundlePath,
                pid: launchedApplication.processIdentifier,
                isActive: launchedApplication.isActive,
                error: nil
            )
            emit(result, exitCode: 0)
        } catch {
            let fallbackPath = CommandLine.arguments.dropFirst().first ?? ""
            let result = GateLAppLaunchResult(
                appBundlePath: fallbackPath,
                pid: nil,
                isActive: false,
                error: error.localizedDescription
            )
            emit(result, exitCode: 1)
        }
    }

    static func emit(_ result: GateLAppLaunchResult, exitCode: Int32) -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(result)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
        Foundation.exit(exitCode)
    }
}
