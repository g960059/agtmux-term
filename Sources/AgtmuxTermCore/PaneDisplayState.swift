import Foundation

/// Product-facing display adapter for one pane row.
///
/// This keeps legacy `AgtmuxPane` fallback collapse in one place while the
/// product-facing UI moves toward `PanePresentationState`.
package struct PaneDisplayState: Equatable, Sendable {
    package let provider: Provider?
    package let presence: PanePresence
    package let primaryState: PanePresentationPrimaryState
    package let freshnessText: String?
    package let titleText: String
    package let subtitleText: String?
    package let isManaged: Bool
    package let needsAttention: Bool

    package init(pane: AgtmuxPane, presentation: PanePresentationState?) {
        if let presentation {
            self.provider = presentation.provider
            self.presence = presentation.presence == .managed ? .managed : .unmanaged
            self.primaryState = Self.primaryState(from: pane, presentation: presentation)
            self.freshnessText = Self.freshnessText(ageSecs: pane.ageSecs, pane: pane, presentation: presentation)
            self.isManaged = presentation.presence == .managed
            self.titleText = Self.titleText(for: pane, provider: presentation.provider, isManaged: presentation.presence == .managed)
            self.subtitleText = Self.subtitleText(for: pane, isManaged: presentation.presence == .managed)
            self.needsAttention = Self.needsAttention(from: presentation)
            return
        }

        let legacyPrimary = PaneDisplayCompatFallback.primaryState(for: pane)
        self.provider = pane.provider
        self.presence = pane.presence
        self.primaryState = legacyPrimary
        self.freshnessText = PaneDisplayCompatFallback.freshnessText(for: pane)
        self.isManaged = pane.isManaged
        self.titleText = Self.titleText(for: pane, provider: pane.provider, isManaged: pane.isManaged)
        self.subtitleText = Self.subtitleText(for: pane, isManaged: pane.isManaged)
        self.needsAttention = PaneDisplayCompatFallback.needsAttention(for: pane)
    }

    private static func primaryState(from pane: AgtmuxPane, presentation: PanePresentationState) -> PanePresentationPrimaryState {
        switch presentation.primaryState {
        case .completedIdle:
            // Keep current low-risk UI behavior: completed idle still renders through
            // the existing idle visual state until the broader cutover lands.
            return .completedIdle
        default:
            return presentation.primaryState
        }
    }

    private static func needsAttention(from presentation: PanePresentationState) -> Bool {
        switch presentation.primaryState {
        case .waitingApproval, .waitingUserInput, .error:
            return true
        case .running, .completedIdle, .idle, .inactive:
            return false
        }
    }

    private static func freshnessText(
        ageSecs: Int?,
        pane: AgtmuxPane,
        presentation: PanePresentationState
    ) -> String? {
        switch presentation.freshnessState {
        case .down, .degraded:
            return nil
        case .fresh:
            break
        }

        // Daemon does not send age_secs; compute from updatedAt when available.
        let effectiveAgeSecs = ageSecs ?? pane.updatedAt.map { max(0, Int(-$0.timeIntervalSinceNow)) }
        return PaneDisplayCompatFallback.freshnessText(ageSecs: effectiveAgeSecs, activityState: pane.activityState)
    }

    private static func titleText(
        for pane: AgtmuxPane,
        provider: Provider?,
        isManaged: Bool
    ) -> String {
        if isManaged {
            if let conversationTitle = normalizedLabelText(pane.conversationTitle) {
                return conversationTitle
            }
            if let sessionSubtitle = normalizedLabelText(pane.sessionSubtitle) {
                return sessionSubtitle
            }
            if let providerName = provider?.rawValue, !providerName.isEmpty {
                return providerName
            }
            return pane.paneId
        }

        return normalizedLabelText(pane.currentCmd) ?? pane.paneId
    }

    private static func subtitleText(for pane: AgtmuxPane, isManaged: Bool) -> String? {
        guard isManaged else { return nil }
        return normalizedLabelText(pane.sessionSubtitle)
    }

    private static func normalizedLabelText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    package var trailingTimestampText: String? {
        guard isManaged, primaryState != .running else { return nil }
        return freshnessText
    }
}
