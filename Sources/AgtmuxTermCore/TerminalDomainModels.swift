import Foundation

package enum TargetRef: Codable, Equatable, Hashable, Sendable {
    case local
    case remote(hostKey: String)
}

package struct SessionRef: Codable, Equatable, Hashable, Sendable {
    package var target: TargetRef
    package var sessionName: String
    package var lastSeenSessionID: String?
    package var lastSeenRepoRoot: String?

    package init(
        target: TargetRef,
        sessionName: String,
        lastSeenSessionID: String? = nil,
        lastSeenRepoRoot: String? = nil
    ) {
        self.target = target
        self.sessionName = sessionName
        self.lastSeenSessionID = lastSeenSessionID
        self.lastSeenRepoRoot = lastSeenRepoRoot
    }

    package static func == (lhs: SessionRef, rhs: SessionRef) -> Bool {
        lhs.target == rhs.target && lhs.sessionName == rhs.sessionName
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(target)
        hasher.combine(sessionName)
    }

    package func mergingStoredHints(from incoming: SessionRef) -> SessionRef {
        precondition(
            target == incoming.target && sessionName == incoming.sessionName,
            "SessionRef.mergingStoredHints requires the same session identity"
        )

        var merged = self
        if let lastSeenSessionID = incoming.lastSeenSessionID {
            merged.lastSeenSessionID = lastSeenSessionID
        }
        if let lastSeenRepoRoot = incoming.lastSeenRepoRoot {
            merged.lastSeenRepoRoot = lastSeenRepoRoot
        }
        return merged
    }
}

package struct ActivePaneRef: Codable, Equatable, Hashable, Sendable {
    package var target: TargetRef
    package var sessionName: String
    package var windowID: String
    package var paneID: String
    package var paneInstanceID: AgtmuxSyncV2PaneInstanceID?

    package init(
        target: TargetRef,
        sessionName: String,
        windowID: String,
        paneID: String,
        paneInstanceID: AgtmuxSyncV2PaneInstanceID? = nil
    ) {
        self.target = target
        self.sessionName = sessionName
        self.windowID = windowID
        self.paneID = paneID
        self.paneInstanceID = paneInstanceID
    }

    package func matches(sessionRef: SessionRef) -> Bool {
        target == sessionRef.target && sessionName == sessionRef.sessionName
    }
}

package struct DocumentRef: Codable, Equatable, Hashable, Sendable {
    package var target: TargetRef
    package var path: String

    package init(target: TargetRef, path: String) {
        self.target = target
        self.path = path
    }
}

extension TargetRef {
    package var label: String {
        switch self {
        case .local:
            return "local"
        case .remote(let hostKey):
            return hostKey
        }
    }
}
