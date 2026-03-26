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

    func testAttachCommandPreselectsCanonicalActivePaneWhenProvided() throws {
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

        assertTelemetryWrapperScaffold(plan.command)
        let normalized = normalizeWrappedCommand(plan.command)
        XCTAssertTrue(normalized.contains("exec env -u TMUX -u TMUX_PANE tmux -L workbench-v2-test"))
        XCTAssertTrue(normalized.contains("select-window -t"))
        XCTAssertTrue(normalized.contains("@12"))
        XCTAssertTrue(normalized.contains("select-pane -t"))
        XCTAssertTrue(normalized.contains("%34"))
        XCTAssertTrue(normalized.contains("attach-session -t 'feature branch'"))
    }

    func testAttachCommandIgnoresCanonicalActivePaneFromDifferentSession() throws {
        let sessionRef = SessionRef(target: .local, sessionName: "feature branch")
        let activePaneRef = ActivePaneRef(
            target: .local,
            sessionName: "other",
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

    func testAttachCommandFallsBackToSessionOnlyWhenCanonicalPaneCoordinatesAreBlank() throws {
        let sessionRef = SessionRef(target: .local, sessionName: "feature branch")
        let activePaneRef = ActivePaneRef(
            target: .local,
            sessionName: "feature branch",
            windowID: "",
            paneID: ""
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

    func testLocalAttachCommandHonorsUITestTmuxConfigPath() throws {
        let sessionRef = SessionRef(target: .local, sessionName: "feature branch")
        let expectedBaseCommand =
            "env -u TMUX -u TMUX_PANE tmux -f /dev/null -L workbench-v2-test attach-session -t 'feature branch'"

        let plan = try XCTUnwrap(
            try? WorkbenchV2TerminalAttachResolver.resolve(
                sessionRef: sessionRef,
                hostsConfig: .empty,
                env: [
                    "AGTMUX_TMUX_SOCKET_NAME": "workbench-v2-test",
                    "AGTMUX_UITEST_TMUX_CONFIG_PATH": "/dev/null",
                ]
            ).get()
        )

        assertTelemetryWrappedCommand(plan.command, baseCommand: expectedBaseCommand)
    }

    func testNavigationCommandTargetsExactTmuxClientName() {
        let activePaneRef = ActivePaneRef(
            target: .local,
            sessionName: "feature branch",
            windowID: "@12",
            paneID: "%34"
        )

        XCTAssertEqual(
            WorkbenchV2TerminalNavigationResolver.navigationCommand(
                for: activePaneRef,
                tmuxClientName: "client-8"
            ),
            ["switch-client", "-c", "client-8", "-t", "%34"]
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

    func testParseLiveTargetRequiresActivePaneForExpectedWindow() throws {
        let output = """
        feature branch|@12|%34|0
        feature branch|@12|%35|1
        feature branch|@13|%36|1
        scratch|@12|%88|1
        """

        let target = try WorkbenchV2TerminalNavigationResolver.parseLiveTarget(
            output: output,
            expectedSessionName: "feature branch",
            expectedWindowID: "@12"
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

    func testParseClientNameResolvesExactRenderedClientTTY() throws {
        let output = """
        client-0|/dev/ttys000
        client-8|/dev/ttys008
        client-10|/dev/ttys010
        """

        let clientName = try WorkbenchV2TerminalNavigationResolver.parseClientName(
            output: output,
            expectedClientTTY: "/dev/ttys008"
        )

        XCTAssertEqual(clientName, "client-8")
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

    func testAttachPlanFreezeIdentityChangesWhenRemoteSSHTargetChanges() {
        let sessionRef = SessionRef(
            target: .remote(hostKey: "edge"),
            sessionName: "shared"
        )
        let originalConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "edge",
                displayName: "Edge",
                hostname: "edge.example.com",
                user: "alice",
                transport: .ssh
            )
        ])
        let updatedConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "edge",
                displayName: "Edge",
                hostname: "edge.example.com",
                user: "bob",
                transport: .ssh
            )
        ])

        let originalIdentity = WorkbenchTerminalAttachPlanFreezeIdentity.make(
            sessionRef: sessionRef,
            desiredPaneRef: nil,
            observedPaneRef: nil,
            terminalState: .ready,
            hostsConfig: originalConfig
        )
        let updatedIdentity = WorkbenchTerminalAttachPlanFreezeIdentity.make(
            sessionRef: sessionRef,
            desiredPaneRef: nil,
            observedPaneRef: nil,
            terminalState: .ready,
            hostsConfig: updatedConfig
        )

        XCTAssertNotEqual(
            originalIdentity,
            updatedIdentity,
            "remote attach-plan identity must change when the configured SSH target changes"
        )
    }

    func testAttachPlanFreezeIdentityIgnoresSameSessionPaneRetarget() {
        let sessionRef = SessionRef(target: .local, sessionName: "shared")
        let firstPaneRef = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@1",
            paneID: "%1"
        )
        let secondPaneRef = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@2",
            paneID: "%9"
        )

        let firstIdentity = WorkbenchTerminalAttachPlanFreezeIdentity.make(
            sessionRef: sessionRef,
            desiredPaneRef: firstPaneRef,
            observedPaneRef: firstPaneRef,
            terminalState: .ready,
            hostsConfig: .empty
        )
        let secondIdentity = WorkbenchTerminalAttachPlanFreezeIdentity.make(
            sessionRef: sessionRef,
            desiredPaneRef: secondPaneRef,
            observedPaneRef: secondPaneRef,
            terminalState: .ready,
            hostsConfig: .empty
        )

        XCTAssertEqual(
            firstIdentity,
            secondIdentity,
            "same-session pane retarget must not invalidate the frozen attach plan"
        )
    }

    func testAttachPlanFreezeIdentityIgnoresSameHostSessionRetarget() {
        let originalSessionRef = SessionRef(target: .local, sessionName: "shared")
        let updatedSessionRef = SessionRef(target: .local, sessionName: "shared-next")

        let originalIdentity = WorkbenchTerminalAttachPlanFreezeIdentity.make(
            sessionRef: originalSessionRef,
            desiredPaneRef: nil,
            observedPaneRef: nil,
            terminalState: .ready,
            hostsConfig: .empty
        )
        let updatedIdentity = WorkbenchTerminalAttachPlanFreezeIdentity.make(
            sessionRef: updatedSessionRef,
            desiredPaneRef: nil,
            observedPaneRef: nil,
            terminalState: .ready,
            hostsConfig: .empty
        )

        XCTAssertEqual(
            originalIdentity,
            updatedIdentity,
            "same-host session retarget must not invalidate the frozen attach plan"
        )
    }

    func testFrozenAttachPlanFallsBackToLiveResolutionWhenRemoteSSHTargetChanges() throws {
        let sessionRef = SessionRef(
            target: .remote(hostKey: "edge"),
            sessionName: "shared"
        )
        let originalConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "edge",
                displayName: "Edge",
                hostname: "edge.example.com",
                user: "alice",
                transport: .ssh
            )
        ])
        let updatedConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "edge",
                displayName: "Edge",
                hostname: "edge.example.com",
                user: "bob",
                transport: .ssh
            )
        ])
        let originalIdentity = WorkbenchTerminalAttachPlanFreezeIdentity.make(
            sessionRef: sessionRef,
            desiredPaneRef: nil,
            observedPaneRef: nil,
            terminalState: .ready,
            hostsConfig: originalConfig
        )
        let updatedIdentity = WorkbenchTerminalAttachPlanFreezeIdentity.make(
            sessionRef: sessionRef,
            desiredPaneRef: nil,
            observedPaneRef: nil,
            terminalState: .ready,
            hostsConfig: updatedConfig
        )
        let originalPlan = try XCTUnwrap(
            try? WorkbenchV2TerminalAttachResolver.resolve(
                sessionRef: sessionRef,
                hostsConfig: originalConfig
            ).get()
        )
        let updatedPlan = try XCTUnwrap(
            try? WorkbenchV2TerminalAttachResolver.resolve(
                sessionRef: sessionRef,
                hostsConfig: updatedConfig
            ).get()
        )
        let frozenPlan = WorkbenchFrozenAttachPlan(
            identity: originalIdentity,
            plan: originalPlan
        )

        let resolvedPlan = try XCTUnwrap(
            try? frozenPlan.resolved(
                currentIdentity: updatedIdentity,
                liveResolution: .success(updatedPlan)
            ).get()
        )

        XCTAssertEqual(resolvedPlan, updatedPlan)
        XCTAssertNotEqual(resolvedPlan.command, originalPlan.command)
        XCTAssertTrue(resolvedPlan.command.contains("bob@edge.example.com"))
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
