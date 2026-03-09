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
}
