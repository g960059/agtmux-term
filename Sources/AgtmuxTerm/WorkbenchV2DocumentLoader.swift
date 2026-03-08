import Foundation
import AgtmuxTermCore

struct WorkbenchV2DocumentSnapshot: Equatable {
    let text: String
    let targetLabel: String
}

enum WorkbenchV2DocumentLoadError: LocalizedError, Equatable {
    case fileNotFound(String)
    case directoryNotSupported(String)
    case unsupportedEncoding(String)
    case missingRemoteHostKey(String)
    case remoteCommandFailed(hostKey: String, message: String)
    case localReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Document load failed: file not found at \(path)"
        case .directoryNotSupported(let path):
            return "Document load failed: directories are not supported in MVP (\(path))"
        case .unsupportedEncoding(let path):
            return "Document load failed: unsupported text encoding at \(path)"
        case .missingRemoteHostKey(let hostKey):
            return "Document load failed: missing configured remote host '\(hostKey)'"
        case .remoteCommandFailed(let hostKey, let message):
            return "Document load failed on \(hostKey): \(message)"
        case .localReadFailed(let message):
            return "Document load failed: \(message)"
        }
    }
}

struct WorkbenchV2RemoteDocumentCommand: Equatable {
    let executableURL: URL
    let arguments: [String]
    let hostKey: String
}

struct WorkbenchV2ProcessResult {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

private struct WorkbenchV2ProcessCapture {
    let directoryURL: URL
    let stdoutURL: URL
    let stderrURL: URL
    let stdoutHandle: FileHandle
    let stderrHandle: FileHandle

    func closeHandles() {
        stdoutHandle.closeFile()
        stderrHandle.closeFile()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

actor WorkbenchV2DocumentLoader {
    typealias ProcessRunner = @Sendable (URL, [String]) async throws -> WorkbenchV2ProcessResult

    private let processRunner: ProcessRunner

    init() {
        self.processRunner = { executableURL, arguments in
            try await Self.runProcess(executableURL: executableURL, arguments: arguments)
        }
    }

    init(processRunner: @escaping ProcessRunner) {
        self.processRunner = processRunner
    }

    func load(
        ref: DocumentRef,
        hostsConfig: HostsConfig
    ) async throws -> WorkbenchV2DocumentSnapshot {
        switch ref.target {
        case .local:
            return try Self.loadLocalDocument(ref: ref)

        case .remote:
            let command = try Self.remoteCommand(ref: ref, hostsConfig: hostsConfig)
            let result = try await processRunner(command.executableURL, command.arguments)
            guard result.exitCode == 0 else {
                let message = Self.processMessage(stderr: result.stderr) ?? "remote fetch exited with code \(result.exitCode)"
                throw WorkbenchV2DocumentLoadError.remoteCommandFailed(
                    hostKey: command.hostKey,
                    message: message
                )
            }

            guard let text = String(data: result.stdout, encoding: .utf8) else {
                throw WorkbenchV2DocumentLoadError.unsupportedEncoding(ref.path)
            }

            return WorkbenchV2DocumentSnapshot(
                text: text,
                targetLabel: ref.target.label
            )
        }
    }

    static func remoteCommand(
        ref: DocumentRef,
        hostsConfig: HostsConfig
    ) throws -> WorkbenchV2RemoteDocumentCommand {
        guard case .remote(let hostKey) = ref.target else {
            preconditionFailure("remoteCommand(ref:hostsConfig:) requires a remote DocumentRef")
        }
        guard let host = hostsConfig.host(id: hostKey) else {
            throw WorkbenchV2DocumentLoadError.missingRemoteHostKey(hostKey)
        }

        let escapedPath = LocalTmuxTarget.shellEscaped(ref.path)
        let script = """
        if [ -d \(escapedPath) ]; then
          printf '%s' 'path is a directory' >&2
          exit 12
        fi
        if [ ! -f \(escapedPath) ]; then
          printf '%s' 'file not found' >&2
          exit 13
        fi
        cat -- \(escapedPath)
        """

        return WorkbenchV2RemoteDocumentCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "StrictHostKeyChecking=accept-new",
                host.sshTarget,
                "sh", "-lc", script
            ],
            hostKey: hostKey
        )
    }

    private static func loadLocalDocument(ref: DocumentRef) throws -> WorkbenchV2DocumentSnapshot {
        let url = URL(fileURLWithPath: ref.path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkbenchV2DocumentLoadError.fileNotFound(ref.path)
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            throw WorkbenchV2DocumentLoadError.directoryNotSupported(ref.path)
        }

        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw WorkbenchV2DocumentLoadError.unsupportedEncoding(ref.path)
            }
            return WorkbenchV2DocumentSnapshot(
                text: text,
                targetLabel: ref.target.label
            )
        } catch let error as WorkbenchV2DocumentLoadError {
            throw error
        } catch {
            throw WorkbenchV2DocumentLoadError.localReadFailed(error.localizedDescription)
        }
    }

    private static func processMessage(stderr: Data) -> String? {
        let trimmed = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return nil
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) async throws -> WorkbenchV2ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let capture: WorkbenchV2ProcessCapture
        do {
            capture = try makeProcessCapture()
        } catch {
            throw WorkbenchV2DocumentLoadError.localReadFailed(error.localizedDescription)
        }

        process.standardOutput = capture.stdoutHandle
        process.standardError = capture.stderrHandle

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                capture.closeHandles()
                defer { capture.cleanup() }

                do {
                    let stdout = try Data(contentsOf: capture.stdoutURL)
                    let stderr = try Data(contentsOf: capture.stderrURL)
                    continuation.resume(
                        returning: WorkbenchV2ProcessResult(
                            stdout: stdout,
                            stderr: stderr,
                            exitCode: proc.terminationStatus
                        )
                    )
                } catch {
                    continuation.resume(
                        throwing: WorkbenchV2DocumentLoadError.localReadFailed(error.localizedDescription)
                    )
                }
            }

            do {
                try process.run()
            } catch {
                capture.closeHandles()
                capture.cleanup()
                continuation.resume(
                    throwing: WorkbenchV2DocumentLoadError.localReadFailed(error.localizedDescription)
                )
            }
        }
    }

    private static func makeProcessCapture() throws -> WorkbenchV2ProcessCapture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agtmux-document-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let stdoutURL = directoryURL.appendingPathComponent("stdout.txt")
        let stderrURL = directoryURL.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: Data())
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())

        return WorkbenchV2ProcessCapture(
            directoryURL: directoryURL,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            stdoutHandle: try FileHandle(forWritingTo: stdoutURL),
            stderrHandle: try FileHandle(forWritingTo: stderrURL)
        )
    }
}
