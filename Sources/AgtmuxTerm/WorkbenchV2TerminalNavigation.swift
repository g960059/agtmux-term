import Foundation
import AgtmuxTermCore

struct WorkbenchV2TerminalLiveTarget: Equatable {
    let sessionName: String
    let windowID: String
    let paneID: String
}

enum WorkbenchV2TerminalNavigationError: LocalizedError, Equatable {
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
            return "Navigation sync failed: rendered client '\(clientTTY)' unavailable for session '\(sessionName)' (\(output))"
        }
    }
}

enum WorkbenchV2TerminalNavigationResolver {
    static func navigationCommand(
        for activePaneRef: ActivePaneRef,
        renderedClientTTY: String
    ) -> [String] {
        [
            "switch-client",
            "-c", renderedClientTTY,
            "-t", activePaneRef.paneID,
        ]
    }

    static func applyNavigationIntent(
        activePaneRef: ActivePaneRef,
        renderedClientTTY: String,
        hostsConfig: HostsConfig
    ) async throws {
        let source = try tmuxSource(for: activePaneRef.target, hostsConfig: hostsConfig)
        _ = try await TmuxCommandRunner.shared.run(
            navigationCommand(for: activePaneRef, renderedClientTTY: renderedClientTTY),
            source: source
        )
    }

    static func liveTarget(
        sessionRef: SessionRef,
        hostsConfig: HostsConfig
    ) async throws -> WorkbenchV2TerminalLiveTarget {
        let source = try tmuxSource(for: sessionRef.target, hostsConfig: hostsConfig)
        let output = try await TmuxCommandRunner.shared.run(
            [
                "list-panes",
                "-t", sessionRef.sessionName,
                "-F", "#{session_name}|#{window_id}|#{pane_id}|#{window_active}|#{pane_active}"
            ],
            source: source
        )
        return try parseLiveTarget(output: output, expectedSessionName: sessionRef.sessionName)
    }

    static func liveTarget(
        sessionRef: SessionRef,
        renderedClientTTY: String,
        hostsConfig: HostsConfig
    ) async throws -> WorkbenchV2TerminalLiveTarget {
        let source = try tmuxSource(for: sessionRef.target, hostsConfig: hostsConfig)
        let output = try await TmuxCommandRunner.shared.run(
            [
                "list-clients",
                "-F", "#{client_tty}|#{session_name}|#{window_id}|#{pane_id}"
            ],
            source: source
        )
        return try parseLiveTarget(
            output: output,
            expectedSessionName: sessionRef.sessionName,
            expectedClientTTY: renderedClientTTY
        )
    }

    static func parseLiveTarget(
        output: String,
        expectedSessionName: String
    ) throws -> WorkbenchV2TerminalLiveTarget {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { continue }
            guard fields[0] == expectedSessionName else { continue }
            guard fields[3] == "1", fields[4] == "1" else { continue }
            return WorkbenchV2TerminalLiveTarget(
                sessionName: fields[0],
                windowID: fields[1],
                paneID: fields[2]
            )
        }

        throw WorkbenchV2TerminalNavigationError.activePaneUnavailable(
            sessionName: expectedSessionName,
            output: output
        )
    }

    static func parseLiveTarget(
        output: String,
        expectedSessionName: String,
        expectedClientTTY: String
    ) throws -> WorkbenchV2TerminalLiveTarget {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { continue }
            guard fields[0] == expectedClientTTY else { continue }
            guard fields[1] == expectedSessionName else { continue }
            return WorkbenchV2TerminalLiveTarget(
                sessionName: fields[1],
                windowID: fields[2],
                paneID: fields[3]
            )
        }

        throw WorkbenchV2TerminalNavigationError.renderedClientUnavailable(
            sessionName: expectedSessionName,
            clientTTY: expectedClientTTY,
            output: output
        )
    }

    static func sourceHostname(
        for target: TargetRef,
        hostsConfig: HostsConfig
    ) throws -> String {
        switch target {
        case .local:
            return "local"
        case .remote(let hostKey):
            guard let host = hostsConfig.host(id: hostKey) else {
                throw WorkbenchV2TerminalNavigationError.missingRemoteHostKey(hostKey)
            }
            return host.hostname
        }
    }

    private static func tmuxSource(
        for target: TargetRef,
        hostsConfig: HostsConfig
    ) throws -> String {
        switch target {
        case .local:
            return "local"
        case .remote(let hostKey):
            guard let host = hostsConfig.host(id: hostKey) else {
                throw WorkbenchV2TerminalNavigationError.missingRemoteHostKey(hostKey)
            }
            return host.sshTarget
        }
    }
}
