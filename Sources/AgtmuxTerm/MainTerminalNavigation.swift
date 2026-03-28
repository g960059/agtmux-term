import Foundation
import AgtmuxTermCore

struct TerminalLiveTarget: Equatable {
    let sessionName: String
    let windowID: String
    let paneID: String
}

enum MainTerminalNavigationError: LocalizedError, Equatable {
    case missingRemoteHostKey(String)
    case activePaneUnavailable(sessionName: String, output: String)
    case renderedClientUnavailable(sessionName: String, clientTTY: String, output: String)

    var errorDescription: String? {
        switch self {
        case .missingRemoteHostKey(let hostKey):
            return "Navigation sync failed: missing configured remote host '\(hostKey)'"
        case .activePaneUnavailable(let sessionName, let output):
            return "Navigation sync failed: active pane unavailable for session '\(sessionName)' (\(output))"
        case .renderedClientUnavailable(let sessionName, let clientTTY, let output):
            if sessionName.isEmpty {
                return "Navigation sync failed: rendered client '\(clientTTY)' unavailable (\(output))"
            }
            return "Navigation sync failed: rendered client '\(clientTTY)' unavailable for session '\(sessionName)' (\(output))"
        }
    }
}

enum MainTerminalNavigationResolver {
    static func globalNavigationCommands(for activePaneRef: ActivePaneRef) -> [[String]] {
        var commands: [[String]] = []
        let normalizedWindowID = activePaneRef.windowID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPaneID = activePaneRef.paneID.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedWindowID.isEmpty == false {
            commands.append(["select-window", "-t", normalizedWindowID])
        }
        if normalizedPaneID.isEmpty == false {
            commands.append(["select-pane", "-t", normalizedPaneID])
        }

        return commands
    }

    static func applySessionNavigationIntent(
        activePaneRef: ActivePaneRef,
        hostsConfig: HostsConfig,
        localSocketOverride: LocalTmuxSocketOverride? = nil
    ) async throws {
        for command in globalNavigationCommands(for: activePaneRef) {
            _ = try await run(
                command,
                target: activePaneRef.target,
                hostsConfig: hostsConfig,
                localSocketOverride: localSocketOverride
            )
        }
    }

    static func applyNavigationIntent(
        activePaneRef: ActivePaneRef,
        renderedClientTTY: String,
        hostsConfig: HostsConfig,
        localSocketOverride: LocalTmuxSocketOverride? = nil
    ) async throws {
        let normalizedTTY = renderedClientTTY.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTTY.isEmpty == false {
            try await applyRenderedClientNavigationIntent(
                activePaneRef: activePaneRef,
                renderedClientTTY: normalizedTTY,
                hostsConfig: hostsConfig,
                localSocketOverride: localSocketOverride
            )
            return
        }

        try await applySessionNavigationIntent(
            activePaneRef: activePaneRef,
            hostsConfig: hostsConfig,
            localSocketOverride: localSocketOverride
        )
    }

    static func applyRenderedClientNavigationIntent(
        activePaneRef: ActivePaneRef,
        renderedClientTTY: String,
        hostsConfig: HostsConfig,
        localSocketOverride: LocalTmuxSocketOverride? = nil
    ) async throws {
        let tmuxClientName = try await resolveRenderedClientName(
            renderedClientTTY: renderedClientTTY,
            target: activePaneRef.target,
            hostsConfig: hostsConfig,
            localSocketOverride: localSocketOverride
        )
        _ = try await run(
            [
                "switch-client",
                "-c", tmuxClientName,
                "-t", activePaneRef.paneID,
            ],
            target: activePaneRef.target,
            hostsConfig: hostsConfig,
            localSocketOverride: localSocketOverride
        )
    }

    static func liveTarget(
        sessionRef: SessionRef,
        hostsConfig: HostsConfig,
        localSocketOverride: LocalTmuxSocketOverride? = nil
    ) async throws -> TerminalLiveTarget {
        let output = try await run(
            [
                "list-panes",
                "-t", sessionRef.sessionName,
                "-F", "#{session_name}|#{window_id}|#{pane_id}|#{window_active}|#{pane_active}"
            ],
            target: sessionRef.target,
            hostsConfig: hostsConfig,
            localSocketOverride: localSocketOverride
        )
        return try parseLiveTarget(output: output, expectedSessionName: sessionRef.sessionName)
    }

    static func liveTarget(
        sessionRef: SessionRef,
        windowID: String,
        hostsConfig: HostsConfig,
        localSocketOverride: LocalTmuxSocketOverride? = nil
    ) async throws -> TerminalLiveTarget {
        let output = try await run(
            [
                "list-panes",
                "-t", windowID,
                "-F", "#{session_name}|#{window_id}|#{pane_id}|#{pane_active}"
            ],
            target: sessionRef.target,
            hostsConfig: hostsConfig,
            localSocketOverride: localSocketOverride
        )
        return try parseLiveTarget(
            output: output,
            expectedSessionName: sessionRef.sessionName,
            expectedWindowID: windowID
        )
    }

    static func liveTarget(
        renderedClientTTY: String,
        target: TargetRef,
        hostsConfig: HostsConfig,
        localSocketOverride: LocalTmuxSocketOverride? = nil
    ) async throws -> TerminalLiveTarget {
        let output = try await run(
            [
                "list-clients",
                "-F", "#{client_tty}|#{session_name}|#{window_id}|#{pane_id}"
            ],
            target: target,
            hostsConfig: hostsConfig,
            localSocketOverride: localSocketOverride
        )
        return try parseLiveTarget(
            output: output,
            expectedClientTTY: renderedClientTTY
        )
    }

    static func resolveRenderedClientName(
        renderedClientTTY: String,
        target: TargetRef,
        hostsConfig: HostsConfig,
        localSocketOverride: LocalTmuxSocketOverride? = nil
    ) async throws -> String {
        let output = try await run(
            [
                "list-clients",
                "-F", "#{client_name}|#{client_tty}"
            ],
            target: target,
            hostsConfig: hostsConfig,
            localSocketOverride: localSocketOverride
        )
        return try parseClientName(
            output: output,
            expectedClientTTY: renderedClientTTY
        )
    }

    static func parseLiveTarget(
        output: String,
        expectedSessionName: String
    ) throws -> TerminalLiveTarget {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { continue }
            guard fields[0] == expectedSessionName else { continue }
            guard fields[3] == "1", fields[4] == "1" else { continue }
            return TerminalLiveTarget(
                sessionName: fields[0],
                windowID: fields[1],
                paneID: fields[2]
            )
        }

        throw MainTerminalNavigationError.activePaneUnavailable(
            sessionName: expectedSessionName,
            output: output
        )
    }

    static func parseLiveTarget(
        output: String,
        expectedSessionName: String,
        expectedWindowID: String
    ) throws -> TerminalLiveTarget {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { continue }
            guard fields[0] == expectedSessionName else { continue }
            guard fields[1] == expectedWindowID else { continue }
            guard fields[3] == "1" else { continue }
            return TerminalLiveTarget(
                sessionName: fields[0],
                windowID: fields[1],
                paneID: fields[2]
            )
        }

        throw MainTerminalNavigationError.activePaneUnavailable(
            sessionName: expectedSessionName,
            output: output
        )
    }

    static func parseLiveTarget(
        output: String,
        expectedClientTTY: String
    ) throws -> TerminalLiveTarget {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { continue }
            guard fields[0] == expectedClientTTY else { continue }
            return TerminalLiveTarget(
                sessionName: fields[1],
                windowID: fields[2],
                paneID: fields[3]
            )
        }

        throw MainTerminalNavigationError.renderedClientUnavailable(
            sessionName: "",
            clientTTY: expectedClientTTY,
            output: output
        )
    }

    static func parseClientName(
        output: String,
        expectedClientTTY: String
    ) throws -> String {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2 else { continue }
            guard fields[1] == expectedClientTTY else { continue }
            guard fields[0].isEmpty == false else { continue }
            return fields[0]
        }

        throw MainTerminalNavigationError.renderedClientUnavailable(
            sessionName: "",
            clientTTY: expectedClientTTY,
            output: output
        )
    }

    static func tmuxSource(
        for target: TargetRef,
        hostsConfig: HostsConfig
    ) throws -> String {
        switch target {
        case .local:
            return "local"
        case .remote(let hostKey):
            guard let host = hostsConfig.host(id: hostKey) else {
                throw MainTerminalNavigationError.missingRemoteHostKey(hostKey)
            }
            return host.sshTarget
        }
    }

    private static func run(
        _ args: [String],
        target: TargetRef,
        hostsConfig: HostsConfig,
        localSocketOverride: LocalTmuxSocketOverride?
    ) async throws -> String {
        switch target {
        case .local:
            return try await TmuxCommandRunner.shared.run(
                args,
                source: "local",
                localSocketArguments: localSocketOverride?.tmuxArguments
            )
        case .remote:
            let source = try tmuxSource(for: target, hostsConfig: hostsConfig)
            return try await TmuxCommandRunner.shared.run(args, source: source)
        }
    }
}
