import Foundation
import Darwin
import AgtmuxTermCore

/// Runs tmux subcommands locally or via SSH.
actor TmuxCommandRunner {
    static let shared = TmuxCommandRunner()

    private var cachedLocalTmuxURL: URL?
    private var resolvedLocalTmuxURLOnce = false

    private init() {}

    private func resolveLocalTmuxURL() -> URL? {
        if let cachedLocalTmuxURL { return cachedLocalTmuxURL }
        if resolvedLocalTmuxURLOnce { return nil }
        resolvedLocalTmuxURLOnce = true

        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let explicit = env["TMUX_BIN"], !explicit.isEmpty {
            candidates.append(explicit)
        }

        if let path = env["PATH"], !path.isEmpty {
            for dir in path.split(separator: ":") {
                candidates.append(String(dir) + "/tmux")
            }
        }

        candidates.append(contentsOf: [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
            "/bin/tmux",
        ])

        var seen: Set<String> = []
        for candidate in candidates where !candidate.isEmpty {
            if seen.contains(candidate) { continue }
            seen.insert(candidate)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                let url = URL(fileURLWithPath: candidate)
                cachedLocalTmuxURL = url
                return url
            }
        }

        if let fromShell = resolveLocalTmuxURLFromLoginShell(env: env) {
            cachedLocalTmuxURL = fromShell
            return fromShell
        }
        return nil
    }

    private func resolveLocalTmuxURLFromLoginShell(env: [String: String]) -> URL? {
        let shellPath = "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shellPath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lc", "whence -p tmux"]

        var shellEnv: [String: String] = [:]
        shellEnv["HOME"] = env["HOME"] ?? NSHomeDirectory()
        shellEnv["USER"] = env["USER"] ?? env["LOGNAME"] ?? ""
        shellEnv["LOGNAME"] = env["LOGNAME"] ?? env["USER"] ?? ""
        shellEnv["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = shellEnv

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard let firstLine = output.split(separator: "\n").first else {
            return nil
        }
        let resolvedPath = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedPath.hasPrefix("/") else {
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: resolvedPath) else {
            return nil
        }
        return URL(fileURLWithPath: resolvedPath)
    }

    func run(_ args: [String], source: String = "local") async throws -> String {
        let process = Process()

        if source == "local" {
            let originalEnv = ProcessInfo.processInfo.environment
            guard let tmuxURL = resolveLocalTmuxURL() else {
                throw TmuxCommandError.tmuxNotFound(source: source)
            }
            process.executableURL = tmuxURL
            let socketArgs = LocalTmuxTarget.socketArguments(from: originalEnv)
            process.arguments = socketArgs + args
            var env = originalEnv
            env["TMUX"] = nil
            env["TMUX_PANE"] = nil
            process.environment = env
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                source,
                "tmux",
            ] + args
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let result: ProcessResult
        do {
            result = try Self.runProcess(
                process: process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                timeout: 8.0
            )
        } catch let error as TmuxCommandError {
            throw error
        } catch {
            throw TmuxCommandError.failed(args: args, code: -1, stderr: error.localizedDescription)
        }

        guard result.exitCode == 0 else {
            throw TmuxCommandError.failed(args: args, code: result.exitCode, stderr: result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .newlines)
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        var stdoutData = Data()
        var stderrData = Data()

        let stdoutRead = DispatchSemaphore(value: 0)
        let stderrRead = DispatchSemaphore(value: 0)
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            throw TmuxCommandError.failed(
                args: process.arguments ?? [],
                code: -1,
                stderr: error.localizedDescription
            )
        }

        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutRead.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrRead.signal()
        }

        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = stdoutRead.wait(timeout: .now() + 0.5)
            _ = stderrRead.wait(timeout: .now() + 0.5)
            throw TmuxCommandError.timeout(args: process.arguments ?? [])
        }

        _ = stdoutRead.wait(timeout: .now() + 1.0)
        _ = stderrRead.wait(timeout: .now() + 1.0)

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

enum TmuxCommandError: Error, Sendable {
    case tmuxNotFound(source: String)
    case permissionDenied(source: String, detail: String)
    case sshFailed(host: String, code: Int32, stderr: String)
    case failed(args: [String], code: Int32, stderr: String)
    case timeout(args: [String])
}
