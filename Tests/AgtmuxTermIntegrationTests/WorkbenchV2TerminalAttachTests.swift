import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class WorkbenchV2TerminalAttachTests: XCTestCase {
    func testLocalAttachCommandTargetsExactSessionName() throws {
        let sessionRef = SessionRef(target: .local, sessionName: "feature branch")
        let expectedBaseCommand =
            "env -u TMUX -u TMUX_PANE tmux -L workbench-v2-test attach-session -t 'feature branch'"

        let plan = try XCTUnwrap(
            try? WorkbenchV2TerminalAttachResolver.resolve(
                sessionRef: sessionRef,
                hostsConfig: .empty,
                env: ["AGTMUX_TMUX_SOCKET_NAME": "workbench-v2-test"]
            ).get()
        )

        XCTAssertEqual(plan.transport, .local)
        XCTAssertEqual(plan.displayTarget, "local")
        XCTAssertEqual(plan.surfaceKey, "workbench-v2:local:feature branch")
        assertTelemetryWrappedCommand(plan.command, baseCommand: expectedBaseCommand)
    }

    func testSSHAttachCommandUsesConfiguredHostIDAndPreservesExactSessionName() throws {
        let hostsConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "edge",
                displayName: "Edge",
                hostname: "edge.example.com",
                user: "alice",
                transport: .ssh
            )
        ])
        let sessionRef = SessionRef(
            target: .remote(hostKey: "edge"),
            sessionName: "feature branch"
        )

        let plan = try XCTUnwrap(
            try? WorkbenchV2TerminalAttachResolver.resolve(
                sessionRef: sessionRef,
                hostsConfig: hostsConfig
            ).get()
        )

        XCTAssertEqual(plan.transport, .ssh)
        XCTAssertEqual(plan.displayTarget, "edge")
        XCTAssertEqual(plan.surfaceKey, "workbench-v2:remote:edge:feature branch")
        assertTelemetryWrapperScaffold(
            plan.command,
            transportPrefix: "ssh -t alice@edge.example.com "
        )
        let normalized = normalizeWrappedCommand(plan.command)
        XCTAssertTrue(normalized.contains("exec env -u TMUX -u TMUX_PANE tmux"))
        XCTAssertTrue(normalized.contains("attach-session -t"))
        XCTAssertTrue(normalized.contains("feature branch"))
    }

    func testAttachCommandRemainsSessionScopedWhenCanonicalActivePaneExists() throws {
        let sessionRef = SessionRef(target: .local, sessionName: "feature branch")
        let activePaneRef = ActivePaneRef(
            target: .local,
            sessionName: "feature branch",
            windowID: "@12",
            paneID: "%34"
        )

        let plan = try XCTUnwrap(
            try? WorkbenchV2TerminalAttachResolver.resolve(
                sessionRef: sessionRef,
                activePaneRef: activePaneRef,
                hostsConfig: .empty,
                env: ["AGTMUX_TMUX_SOCKET_NAME": "workbench-v2-test"]
            ).get()
        )

        assertTelemetryWrappedCommand(
            plan.command,
            baseCommand: "env -u TMUX -u TMUX_PANE tmux -L workbench-v2-test attach-session -t 'feature branch'"
        )
    }

    func testNavigationCommandTargetsExactRenderedClientTTY() {
        let activePaneRef = ActivePaneRef(
            target: .local,
            sessionName: "feature branch",
            windowID: "@12",
            paneID: "%34"
        )

        XCTAssertEqual(
            WorkbenchV2TerminalNavigationResolver.navigationCommand(
                for: activePaneRef,
                renderedClientTTY: "/dev/ttys008"
            ),
            ["switch-client", "-c", "/dev/ttys008", "-t", "%34"]
        )
    }

    func testParseLiveTargetRequiresActiveWindowAndPaneForExpectedSession() throws {
        let output = """
        feature branch|@12|%34|1|0
        feature branch|@12|%35|1|1
        scratch|@99|%88|1|1
        """

        let target = try WorkbenchV2TerminalNavigationResolver.parseLiveTarget(
            output: output,
            expectedSessionName: "feature branch"
        )

        XCTAssertEqual(
            target,
            WorkbenchV2TerminalLiveTarget(
                sessionName: "feature branch",
                windowID: "@12",
                paneID: "%35"
            )
        )
    }

    func testParseLiveTargetResolvesExactRenderedClientTTY() throws {
        let output = """
        /dev/ttys000|feature branch|@12|%34
        /dev/ttys008|feature branch|@12|%35
        /dev/ttys010|scratch|@99|%88
        """

        let target = try WorkbenchV2TerminalNavigationResolver.parseLiveTarget(
            output: output,
            expectedSessionName: "feature branch",
            expectedClientTTY: "/dev/ttys008"
        )

        XCTAssertEqual(
            target,
            WorkbenchV2TerminalLiveTarget(
                sessionName: "feature branch",
                windowID: "@12",
                paneID: "%35"
            )
        )
    }

    func testMoshAttachCommandUsesConfiguredHostIDAndPreservesExactSessionName() throws {
        let hostsConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "ops",
                displayName: "Ops",
                hostname: "ops.example.com",
                user: nil,
                transport: .mosh
            )
        ])
        let sessionRef = SessionRef(
            target: .remote(hostKey: "ops"),
            sessionName: "release prep"
        )

        let plan = try XCTUnwrap(
            try? WorkbenchV2TerminalAttachResolver.resolve(
                sessionRef: sessionRef,
                hostsConfig: hostsConfig
            ).get()
        )

        XCTAssertEqual(plan.transport, .mosh)
        XCTAssertEqual(plan.displayTarget, "ops")
        XCTAssertEqual(plan.surfaceKey, "workbench-v2:remote:ops:release prep")
        assertTelemetryWrapperScaffold(
            plan.command,
            transportPrefix: "mosh ops.example.com -- "
        )
        let normalized = normalizeWrappedCommand(plan.command)
        XCTAssertTrue(normalized.contains("exec env -u TMUX -u TMUX_PANE tmux"))
        XCTAssertTrue(normalized.contains("attach-session -t"))
        XCTAssertTrue(normalized.contains("release prep"))
    }

    func testMissingRemoteHostKeyFailsLoudly() {
        let sessionRef = SessionRef(
            target: .remote(hostKey: "missing-host"),
            sessionName: "orphan"
        )

        let result = WorkbenchV2TerminalAttachResolver.resolve(
            sessionRef: sessionRef,
            hostsConfig: .empty
        )

        XCTAssertEqual(result, .failure(.missingRemoteHostKey("missing-host")))
    }

    private func assertTelemetryWrappedCommand(
        _ command: String,
        baseCommand: String,
        transportPrefix: String = ""
    ) {
        let normalizedCommand = normalizeWrappedCommand(command)
        assertTelemetryWrapperScaffold(command, transportPrefix: transportPrefix)
        XCTAssertTrue(normalizedCommand.contains("exec \(baseCommand)"), "command must still exec the original tmux attach command")
    }

    private func assertTelemetryWrapperScaffold(
        _ command: String,
        transportPrefix: String = ""
    ) {
        XCTAssertTrue(command.hasPrefix(transportPrefix), "command must preserve transport prefix")
        XCTAssertTrue(command.contains("/bin/sh -lc"), "command must execute through the telemetry shell wrapper")
        XCTAssertTrue(command.contains("tty_path=$(tty 2>/dev/null || true)"), "command must capture the rendered surface tty")
        XCTAssertTrue(command.contains("9911"), "command must emit over the supported host bridge OSC")
        XCTAssertTrue(command.contains("\"action\":\"bind_client\""), "command must bind the rendered tmux client tty before exec")
    }

    private func normalizeWrappedCommand(_ command: String) -> String {
        command
            .replacingOccurrences(of: "'\\''", with: "'")
            .replacingOccurrences(of: "'\"'\"'", with: "'")
    }
}
