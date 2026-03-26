import Foundation
import AgtmuxTermCore

enum TerminalPaneIdentity {
    static func normalized(_ paneRef: ActivePaneRef?) -> ActivePaneRef? {
        guard let paneRef else { return nil }
        let windowID = paneRef.windowID.trimmingCharacters(in: .whitespacesAndNewlines)
        let paneID = paneRef.paneID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !windowID.isEmpty, !paneID.isEmpty else { return nil }
        return ActivePaneRef(
            target: paneRef.target,
            sessionName: paneRef.sessionName,
            windowID: windowID,
            paneID: paneID,
            paneInstanceID: paneRef.paneInstanceID
        )
    }

    static func visiblePaneIdentity(for paneRef: ActivePaneRef?) -> String? {
        guard let paneRef = normalized(paneRef) else { return nil }
        let paneInstanceIdentity: String
        if let paneInstanceID = paneRef.paneInstanceID {
            let generation = paneInstanceID.generation.map(String.init) ?? ""
            let birthTimestamp = paneInstanceID.birthTs.map {
                String($0.timeIntervalSince1970)
            } ?? ""
            paneInstanceIdentity = [
                paneInstanceID.paneId,
                generation,
                birthTimestamp,
            ].joined(separator: "@")
        } else {
            paneInstanceIdentity = ""
        }

        return [
            paneRef.sessionName,
            paneRef.windowID,
            paneRef.paneID,
            paneInstanceIdentity,
        ].joined(separator: "|")
    }
}
