import Foundation

// MARK: - TmuxCommandRunner

/// Runs tmux subcommands locally or via SSH.
///
/// T-039 will expand this with typed errors, connection pooling, and
/// AsyncStream-based control mode. For T-037 we need only `run()`.
actor TmuxCommandRunner {
    static let shared = TmuxCommandRunner()

    private init() {}

    /// Execute a tmux command and return stdout.
    ///
    /// - Parameters:
    ///   - args: tmux subcommand and arguments (e.g. `["new-session", "-d", "-s", name]`).
    ///   - source: `"local"` runs tmux directly; any other value SSH-es to that host.
    /// - Returns: Trimmed stdout on success.
    /// - Throws: `TmuxCommandError.failed` on non-zero exit.
    func run(_ args: [String], source: String = "local") async throws -> String {
        let process = Process()

        if source == "local" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tmux"] + args
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
        process.standardError  = stderrPipe
        process.standardInput  = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) ?? ""
                guard proc.terminationStatus == 0 else {
                    continuation.resume(throwing: TmuxCommandError.failed(
                        args: args, code: proc.terminationStatus, stderr: stderr))
                    return
                }
                continuation.resume(returning: stdout.trimmingCharacters(in: .newlines))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TmuxCommandError.failed(
                    args: args, code: -1, stderr: error.localizedDescription))
            }
        }
    }
}

// MARK: - TmuxCommandError

enum TmuxCommandError: Error, Sendable {
    case tmuxNotFound(source: String)
    case permissionDenied(source: String, detail: String)
    case sshFailed(host: String, code: Int32, stderr: String)
    case failed(args: [String], code: Int32, stderr: String)
    case timeout(args: [String])
}

// MARK: - LinkedSessionManager

/// Creates and destroys tmux linked sessions ("agtmux-linked-{uuid}") for workspace tiles.
///
/// Each tile gets its own linked session that shares the parent's session group
/// but maintains an independent current-window pointer. This allows multiple
/// tiles to display different windows of the same agent session simultaneously.
///
/// The "agtmux-linked-" prefix (vs the old "agtmux-") avoids collision with real
/// user sessions that the agtmux CLI creates as "agtmux-{UUID}" (T-056).
///
/// Verified in Spike B (T-028):
///   - Sessions in the same group maintain independent current-window pointers.
///   - `select-window -t "linked:@windowId"` navigates without an attached client.
actor LinkedSessionManager {
    static let shared = LinkedSessionManager()

    private init() {}

    /// Create a linked session and navigate it to the target window and pane.
    ///
    /// - Parameters:
    ///   - parentSession: The parent session name (e.g. `"backend-api"`).
    ///   - windowId: The window ID to display initially (e.g. `"@510"`).
    ///   - paneId: The pane ID to focus within the window (e.g. `"%601"`).
    ///   - source: `"local"` or SSH hostname.
    /// - Returns: The linked session name (`"agtmux-linked-{uuid}"`).
    func createSession(parentSession: String,
                       windowId: String,
                       paneId: String,
                       source: String) async throws -> String {
        let name = "agtmux-linked-\(UUID().uuidString)"

        // Step 1: Create linked session sharing the parent's session group.
        // -d = detached (no immediate attach), -s = name, -t = parent session.
        _ = try await TmuxCommandRunner.shared.run(
            ["new-session", "-d", "-s", name, "-t", parentSession],
            source: source
        )

        // Step 1.5: Preserve parent status-left formatting and replace only
        // session-name tokens so linked internal names do not leak to UI.
        //
        // This keeps user theme/style (colors, separators, powerline segments)
        // aligned with their existing tmux/WezTerm configuration.
        let parentStatusLeft = try await effectiveParentSessionOption(
            "status-left",
            parentSession: parentSession,
            source: source
        )
        let rewrittenStatusLeft = rewriteStatusLeftTemplate(parentStatusLeft)
        if rewrittenStatusLeft != parentStatusLeft {
            _ = try await TmuxCommandRunner.shared.run(
                ["set-option", "-t", name, "status-left", rewrittenStatusLeft],
                source: source
            )
        }

        // Keep outer terminal/tab titles aligned with session-group naming too.
        let parentTitleTemplate = try await effectiveParentSessionOption(
            "set-titles-string",
            parentSession: parentSession,
            source: source
        )
        let rewrittenTitleTemplate = rewriteSessionNameTokens(parentTitleTemplate)
        if rewrittenTitleTemplate != parentTitleTemplate {
            _ = try await TmuxCommandRunner.shared.run(
                ["set-option", "-t", name, "set-titles-string", rewrittenTitleTemplate],
                source: source
            )
        }

        // Step 2: Navigate the linked session's current-window to the target.
        // select-window operates on the session pointer, not on an attached client,
        // so it works even before any surface has attached (confirmed Spike B).
        _ = try await TmuxCommandRunner.shared.run(
            ["select-window", "-t", "\(name):\(windowId)"],
            source: source
        )

        // Step 3: Set the active pane within that window.
        // paneId is the global tmux pane ID (e.g. "%601"), unique across all sessions.
        _ = try await TmuxCommandRunner.shared.run(
            ["select-pane", "-t", paneId],
            source: source
        )

        return name
    }

    /// Rewrites status-left template so linked session names do not leak.
    ///
    /// Rules:
    /// - Preserve all existing style directives and text.
    /// - Replace session-name tokens with `#{session_group}`.
    /// - Keep escaped literal `##S` unchanged.
    private func rewriteStatusLeftTemplate(_ template: String) -> String {
        rewriteSessionNameTokens(template)
    }

    private func rewriteSessionNameTokens(_ template: String) -> String {
        let escapedShortToken = "__AGTMUX_ESCAPED_SHORT_SESSION_TOKEN__"
        var rewritten = template.replacingOccurrences(of: "##S", with: escapedShortToken)
        rewritten = rewritten.replacingOccurrences(of: "#{session_name}", with: "#{session_group}")
        rewritten = rewritten.replacingOccurrences(of: "#S", with: "#{session_group}")
        rewritten = rewritten.replacingOccurrences(of: escapedShortToken, with: "##S")
        return rewritten
    }

    /// Resolve a session option template from parent session.
    ///
    /// tmux returns an empty string for many session options when they are not set
    /// locally on the target session (even though a global value exists). For linked
    /// sessions we need the effective template, so fallback to global when local is
    /// empty.
    private func effectiveParentSessionOption(_ option: String,
                                              parentSession: String,
                                              source: String) async throws -> String {
        let local = try await TmuxCommandRunner.shared.run(
            ["show-options", "-v", "-t", parentSession, option],
            source: source
        )
        if !local.isEmpty { return local }
        return try await TmuxCommandRunner.shared.run(
            ["show-options", "-gv", option],
            source: source
        )
    }

    /// Destroy a linked session previously created by this manager.
    ///
    /// Best-effort: errors are swallowed (session may already be gone, e.g.
    /// if the parent session was killed).
    func destroySession(name: String, source: String) async {
        _ = try? await TmuxCommandRunner.shared.run(
            ["kill-session", "-t", name],
            source: source
        )
    }
}
