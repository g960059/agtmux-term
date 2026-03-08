import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class WorkbenchV2TerminalRestoreTests: XCTestCase {
    func testTileStateDefersToBootstrappingUntilInventoryIsReady() {
        let state = WorkbenchV2TerminalTileState.resolve(
            sessionRef: SessionRef(target: .local, sessionName: "main"),
            hostsConfig: .empty,
            panes: [],
            offlineHostnames: [],
            localDaemonIssue: nil,
            inventoryReady: false
        )

        XCTAssertEqual(state, .bootstrapping)
    }

    func testTileStateStillFailsFastForMissingRemoteHostBeforeInventoryIsReady() {
        let state = WorkbenchV2TerminalTileState.resolve(
            sessionRef: SessionRef(target: .remote(hostKey: "missing"), sessionName: "main"),
            hostsConfig: .empty,
            panes: [],
            offlineHostnames: [],
            localDaemonIssue: nil,
            inventoryReady: false
        )

        XCTAssertEqual(state, .broken(.hostMissing("missing")))
    }

    func testResolveMapsMissingRemoteHostToHostMissing() {
        let issue = WorkbenchV2TerminalRestoreIssue.resolve(
            sessionRef: SessionRef(target: .remote(hostKey: "missing"), sessionName: "main"),
            hostsConfig: .empty,
            panes: [],
            offlineHostnames: [],
            localDaemonIssue: nil
        )

        XCTAssertEqual(issue, .hostMissing("missing"))
    }

    func testResolveMapsOfflineRemoteHostToHostOffline() {
        let hostsConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "edge",
                displayName: "Edge",
                hostname: "edge.example.com",
                user: nil,
                transport: .ssh
            )
        ])

        let issue = WorkbenchV2TerminalRestoreIssue.resolve(
            sessionRef: SessionRef(target: .remote(hostKey: "edge"), sessionName: "main"),
            hostsConfig: hostsConfig,
            panes: [],
            offlineHostnames: ["edge.example.com"],
            localDaemonIssue: nil
        )

        XCTAssertEqual(issue, .hostOffline("edge"))
    }

    func testResolveMapsLocalOfflineWithoutDaemonIssueToTmuxUnavailable() {
        let issue = WorkbenchV2TerminalRestoreIssue.resolve(
            sessionRef: SessionRef(target: .local, sessionName: "main"),
            hostsConfig: .empty,
            panes: [],
            offlineHostnames: ["local"],
            localDaemonIssue: nil
        )

        XCTAssertEqual(issue, .tmuxUnavailable)
    }

    func testResolveMapsMissingLocalSessionWithDaemonUnavailableToDaemonUnavailable() {
        let issue = WorkbenchV2TerminalRestoreIssue.resolve(
            sessionRef: SessionRef(target: .local, sessionName: "main"),
            hostsConfig: .empty,
            panes: [],
            offlineHostnames: [],
            localDaemonIssue: .localDaemonUnavailable(detail: "bundled runtime missing")
        )

        XCTAssertEqual(issue, .daemonUnavailable("bundled runtime missing"))
    }

    func testResolveMapsMissingLocalSessionWithIncompatibleDaemonToDaemonIncompatible() {
        let issue = WorkbenchV2TerminalRestoreIssue.resolve(
            sessionRef: SessionRef(target: .local, sessionName: "main"),
            hostsConfig: .empty,
            panes: [],
            offlineHostnames: [],
            localDaemonIssue: .incompatibleSyncV2(detail: "old protocol")
        )

        XCTAssertEqual(issue, .daemonIncompatible("old protocol"))
    }

    func testResolvePrefersExactLocalSessionPresenceOverDaemonIssue() {
        let issue = WorkbenchV2TerminalRestoreIssue.resolve(
            sessionRef: SessionRef(target: .local, sessionName: "main"),
            hostsConfig: .empty,
            panes: [makePane(source: "local", sessionName: "main")],
            offlineHostnames: [],
            localDaemonIssue: .localDaemonUnavailable(detail: "bundled runtime missing")
        )

        XCTAssertNil(issue)
    }

    func testResolveMapsReachableMissingSessionToSessionMissing() {
        let hostsConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "edge",
                displayName: "Edge",
                hostname: "edge.example.com",
                user: nil,
                transport: .ssh
            )
        ])

        let issue = WorkbenchV2TerminalRestoreIssue.resolve(
            sessionRef: SessionRef(target: .remote(hostKey: "edge"), sessionName: "deploy"),
            hostsConfig: hostsConfig,
            panes: [makePane(source: "edge.example.com", sessionName: "main")],
            offlineHostnames: [],
            localDaemonIssue: nil
        )

        XCTAssertEqual(issue, .sessionMissing("deploy"))
    }

    func testResolveReturnsNilWhenExactRemoteSessionExists() {
        let hostsConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "edge",
                displayName: "Edge",
                hostname: "edge.example.com",
                user: nil,
                transport: .ssh
            )
        ])

        let issue = WorkbenchV2TerminalRestoreIssue.resolve(
            sessionRef: SessionRef(target: .remote(hostKey: "edge"), sessionName: "deploy"),
            hostsConfig: hostsConfig,
            panes: [makePane(source: "edge.example.com", sessionName: "deploy")],
            offlineHostnames: [],
            localDaemonIssue: nil
        )

        XCTAssertNil(issue)
    }

    func testLiveRebindOptionsUseExactTargetRefsAndDeduplicateSessions() {
        let hostsConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "edge",
                displayName: "Edge",
                hostname: "edge.example.com",
                user: nil,
                transport: .ssh
            )
        ])

        let options = WorkbenchV2TerminalRebindOption.liveOptions(
            panes: [
                makePane(source: "edge.example.com", sessionName: "deploy", paneID: "%1"),
                makePane(source: "edge.example.com", sessionName: "deploy", paneID: "%2"),
                makePane(source: "local", sessionName: "main", paneID: "%3")
            ],
            hostsConfig: hostsConfig
        )

        XCTAssertEqual(
            options.map(\.label),
            ["local • main", "edge • deploy"]
        )
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0].ref, SessionRef(target: .local, sessionName: "main"))
        XCTAssertEqual(options[1].ref, SessionRef(target: .remote(hostKey: "edge"), sessionName: "deploy"))
    }

    func testLiveRebindOptionsExcludeOfflineSources() {
        let hostsConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "edge",
                displayName: "Edge",
                hostname: "edge.example.com",
                user: nil,
                transport: .ssh
            )
        ])

        let options = WorkbenchV2TerminalRebindOption.liveOptions(
            panes: [
                makePane(source: "edge.example.com", sessionName: "deploy", paneID: "%1"),
                makePane(source: "local", sessionName: "main", paneID: "%2")
            ],
            hostsConfig: hostsConfig,
            offlineHostnames: ["edge.example.com"]
        )

        XCTAssertEqual(options.map(\.label), ["local • main"])
    }

    func testLiveRebindOptionsStayEmptyUntilInventoryIsReady() {
        let options = WorkbenchV2TerminalRebindOption.liveOptions(
            panes: [makePane(source: "local", sessionName: "main")],
            hostsConfig: .empty,
            inventoryReady: false
        )

        XCTAssertTrue(options.isEmpty)
    }

    private func makePane(
        source: String,
        sessionName: String,
        paneID: String = "%42"
    ) -> AgtmuxPane {
        AgtmuxPane(
            source: source,
            paneId: paneID,
            sessionName: sessionName,
            windowId: "@1"
        )
    }
}
