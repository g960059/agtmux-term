import Foundation
import AgtmuxTermCore

enum WorkbenchV2TerminalTransport: String, Equatable {
    case local
    case ssh
    case mosh
}

struct WorkbenchV2TerminalAttachPlan: Equatable {
    let command: String
    let surfaceKey: String
    let transport: WorkbenchV2TerminalTransport
    let displayTarget: String
}

enum WorkbenchV2TerminalAttachError: LocalizedError, Equatable {
    case missingRemoteHostKey(String)

    var errorDescription: String? {
        switch self {
        case .missingRemoteHostKey(let hostKey):
            return "Attach failed: missing configured remote host '\(hostKey)'"
        }
    }
}

enum WorkbenchV2TerminalAttachResolver {
    static func resolve(
        sessionRef: SessionRef,
        activePaneRef: ActivePaneRef? = nil,
        hostsConfig: HostsConfig,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<WorkbenchV2TerminalAttachPlan, WorkbenchV2TerminalAttachError> {
        let _ = activePaneRef
        let baseCommand = telemetryWrappedCommand(
            directAttachCommand(sessionRef: sessionRef, env: env)
        )

        switch sessionRef.target {
        case .local:
            return .success(
                WorkbenchV2TerminalAttachPlan(
                    command: baseCommand,
                    surfaceKey: surfaceKey(for: sessionRef),
                    transport: .local,
                    displayTarget: "local"
                )
            )

        case .remote(let hostKey):
            guard let host = hostsConfig.host(id: hostKey) else {
                return .failure(.missingRemoteHostKey(hostKey))
            }

            let remoteCommand = LocalTmuxTarget.shellEscaped(baseCommand)
            let command: String
            let transport: WorkbenchV2TerminalTransport

            switch host.transport {
            case .ssh:
                command = "ssh -t \(host.sshTarget) \(remoteCommand)"
                transport = .ssh
            case .mosh:
                command = "mosh \(host.sshTarget) -- \(remoteCommand)"
                transport = .mosh
            }

            return .success(
                WorkbenchV2TerminalAttachPlan(
                    command: command,
                    surfaceKey: surfaceKey(for: sessionRef),
                    transport: transport,
                    displayTarget: host.id
                )
            )
        }
    }

    private static func directAttachCommand(
        sessionRef: SessionRef,
        env: [String: String]
    ) -> String {
        let socketSegment = LocalTmuxTarget.shellEscapedSocketArguments(from: env)
        let socketArgs = socketSegment.isEmpty ? "" : " " + socketSegment
        let escapedSessionName = LocalTmuxTarget.shellEscaped(sessionRef.sessionName)
        var command = "env -u TMUX -u TMUX_PANE tmux\(socketArgs)"
        command += " attach-session -t \(escapedSessionName)"
        return command
    }

    private static func telemetryWrappedCommand(_ command: String) -> String {
        let telemetryScript = """
        tty_path=$(tty 2>/dev/null || true)
        if [ -n "$tty_path" ]; then
          printf '\\033]\(GhosttyCLIOSCBridge.command);{"version":1,"action":"bind_client","client_tty":"%s"}\\007' "$tty_path"
        fi
        exec \(command)
        """
        return "/bin/sh -lc \(LocalTmuxTarget.shellEscaped(telemetryScript))"
    }

    private static func surfaceKey(for sessionRef: SessionRef) -> String {
        switch sessionRef.target {
        case .local:
            return "workbench-v2:local:\(sessionRef.sessionName)"
        case .remote(let hostKey):
            return "workbench-v2:remote:\(hostKey):\(sessionRef.sessionName)"
        }
    }
}
