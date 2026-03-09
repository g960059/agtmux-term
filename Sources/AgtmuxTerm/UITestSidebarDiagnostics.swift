import Foundation
import AgtmuxTermCore

struct UITestSidebarPanePresentationSnapshot: Codable, Equatable {
    let source: String
    let sessionName: String
    let paneID: String
    let presence: String
    let provider: String?
    let primaryState: String
    let freshness: String?
    let currentCommand: String?
    let isManaged: Bool
    let needsAttention: Bool
}

struct UITestBootstrapProbeSummary: Codable, Equatable {
    let ok: Bool
    let transportVersion: String?
    let totalPanes: Int?
    let managedPanes: Int?
    let error: String?
}

struct UITestBootstrapTargetSummary: Codable, Equatable {
    let sessionName: String
    let paneID: String
    let presence: String
    let provider: String?
    let primaryState: String
    let freshness: String?
    let sessionKey: String
    let paneInstanceID: String
}

struct UITestDaemonLaunchRecordSnapshot: Codable, Equatable {
    let binaryPath: String
    let arguments: [String]
    let environment: [String: String]
    let reusedExistingRuntime: Bool
}

struct UITestSidebarStateSnapshot: Codable, Equatable {
    let statusFilter: String
    let panePresentations: [UITestSidebarPanePresentationSnapshot]
    let filteredPanePresentations: [UITestSidebarPanePresentationSnapshot]
    let attentionCount: Int
    let localDaemonIssueTitle: String?
    let localDaemonIssueDetail: String?
    let bootstrapProbeSummary: UITestBootstrapProbeSummary
    let bootstrapTargetSummary: UITestBootstrapTargetSummary?
    let managedDaemonSocketPath: String
    let tmuxSocketArguments: [String]
    let daemonCLIArguments: [String]
    let bootstrapResolvedTmuxSocketPath: String?
    let appDirectResolvedSocketProbe: String?
    let appDirectResolvedSocketProbeError: String?
    let daemonProcessCommands: [String]
    let daemonLaunchRecord: UITestDaemonLaunchRecordSnapshot?
    let managedDaemonStderrTail: String?
}

enum UITestSidebarDiagnostics {
    static func panePresentationSnapshot(
        for pane: AgtmuxPane,
        display: PaneDisplayState
    ) -> UITestSidebarPanePresentationSnapshot {
        UITestSidebarPanePresentationSnapshot(
            source: pane.source,
            sessionName: pane.sessionName,
            paneID: pane.paneId,
            presence: display.presence.rawValue,
            provider: display.provider?.rawValue,
            primaryState: display.primaryState.rawValue,
            freshness: display.freshnessText,
            currentCommand: pane.currentCmd,
            isManaged: display.isManaged,
            needsAttention: display.needsAttention
        )
    }

    static func bootstrapProbeSummary(
        from bootstrap: AgtmuxSyncV3Bootstrap
    ) -> UITestBootstrapProbeSummary {
        UITestBootstrapProbeSummary(
            ok: true,
            transportVersion: "sync-v3",
            totalPanes: bootstrap.panes.count,
            managedPanes: bootstrap.panes.filter { $0.presence == .managed }.count,
            error: nil
        )
    }

    static func bootstrapProbeSummary(
        error: Error
    ) -> UITestBootstrapProbeSummary {
        UITestBootstrapProbeSummary(
            ok: false,
            transportVersion: "sync-v3",
            totalPanes: nil,
            managedPanes: nil,
            error: error.localizedDescription
        )
    }

    static func bootstrapTargetSummary(
        from bootstrap: AgtmuxSyncV3Bootstrap,
        requestedSessionName: String?,
        requestedPaneID: String?
    ) -> UITestBootstrapTargetSummary? {
        guard let requestedSessionName, let requestedPaneID,
              let target = bootstrap.panes.first(where: {
                  $0.sessionName == requestedSessionName && $0.paneID == requestedPaneID
              }) else {
            return nil
        }
        let presentation = PanePresentationState(snapshot: target)
        return UITestBootstrapTargetSummary(
            sessionName: target.sessionName,
            paneID: target.paneID,
            presence: target.presence.rawValue,
            provider: target.provider?.rawValue,
            primaryState: presentation.primaryState.rawValue,
            freshness: presentation.freshnessState.rawValue,
            sessionKey: target.sessionKey,
            paneInstanceID: String(describing: target.paneInstanceID)
        )
    }

    static func sidebarStateSummary(
        _ snapshot: UITestSidebarStateSnapshot?,
        sessionName: String,
        paneID: String
    ) -> String {
        guard let snapshot else { return "nil" }

        func summarize(_ pane: UITestSidebarPanePresentationSnapshot?) -> String {
            guard let pane else { return "nil" }
            return [
                "presence=\(pane.presence)",
                "provider=\(pane.provider ?? "nil")",
                "primary=\(pane.primaryState)",
                "freshness=\(pane.freshness ?? "nil")",
                "managed=\(pane.isManaged)",
                "attention=\(pane.needsAttention)",
                "current_cmd=\(pane.currentCommand ?? "nil")"
            ].joined(separator: ",")
        }

        let visiblePresentation = snapshot.panePresentations.first {
            $0.source == "local" && $0.sessionName == sessionName && $0.paneID == paneID
        }
        let filteredPresentation = snapshot.filteredPanePresentations.first {
            $0.source == "local" && $0.sessionName == sessionName && $0.paneID == paneID
        }
        let visibleSummary = summarize(visiblePresentation)
        let filteredSummary = summarize(filteredPresentation)

        let issueSummary: String
        if let title = snapshot.localDaemonIssueTitle {
            let detail = snapshot.localDaemonIssueDetail ?? ""
            issueSummary = "\(title):\(detail)"
        } else {
            issueSummary = "nil"
        }

        let probe = snapshot.bootstrapProbeSummary
        let probeSummary = probe.ok
            ? "ok transport=\(probe.transportVersion ?? "nil") total=\(probe.totalPanes ?? -1) managed=\(probe.managedPanes ?? -1)"
            : "error=\(probe.error ?? "unknown")"
        let targetSummary: String
        if let target = snapshot.bootstrapTargetSummary {
            targetSummary = [
                "presence=\(target.presence)",
                "provider=\(target.provider ?? "nil")",
                "primary=\(target.primaryState)",
                "freshness=\(target.freshness ?? "nil")",
                "session_key=\(target.sessionKey)",
                "pane_instance=\(target.paneInstanceID)"
            ].joined(separator: ",")
        } else {
            targetSummary = "nil"
        }
        let daemonLaunchSummary = snapshot.daemonLaunchRecord.map {
            "\($0.reusedExistingRuntime ? "reused" : "spawned"):\($0.binaryPath):\($0.arguments.joined(separator: ","))"
        } ?? "nil"
        let daemonEnvSummary = snapshot.daemonLaunchRecord.map { launch in
            launch.environment
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "|")
        } ?? "nil"

        return [
            "filter=\(snapshot.statusFilter)",
            "attentionCount=\(snapshot.attentionCount)",
            "issue=\(issueSummary)",
            "probe=\(probeSummary)",
            "probeTarget=\(targetSummary)",
            "managedSocket=\(snapshot.managedDaemonSocketPath)",
            "tmuxArgs=\(snapshot.tmuxSocketArguments.joined(separator: ","))",
            "daemonArgs=\(snapshot.daemonCLIArguments.joined(separator: ","))",
            "bootstrapTmuxSocket=\(snapshot.bootstrapResolvedTmuxSocketPath ?? "nil")",
            "appDirectSocketProbe=\(snapshot.appDirectResolvedSocketProbe ?? "nil")",
            "appDirectSocketProbeErr=\(snapshot.appDirectResolvedSocketProbeError ?? "nil")",
            "daemonProc=\(snapshot.daemonProcessCommands.joined(separator: " || "))",
            "daemonLaunch=\(daemonLaunchSummary)",
            "daemonEnv=\(daemonEnvSummary)",
            "daemonErr=\(snapshot.managedDaemonStderrTail ?? "nil")",
            "all=\(visibleSummary)",
            "filtered=\(filteredSummary)",
            "filteredCount=\(snapshot.filteredPanePresentations.count)"
        ].joined(separator: " ")
    }
}
