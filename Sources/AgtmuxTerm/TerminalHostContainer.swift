import SwiftUI

struct TerminalHostRenderModel: Equatable {
    let surfaceID: UUID
    let poolKey: String
    let attachCommand: String?
    let surfaceContext: GhosttyTerminalSurfaceContext?
    let visiblePaneIdentity: String?
    let isFocused: Bool
    let focusRestoreNonce: UInt64
}

struct TerminalHostContainer: View, Equatable {
    let mode: TerminalHostMode
    let model: TerminalHostRenderModel

    static func hostViewIdentity(surfaceID: UUID, mode: TerminalHostMode) -> String {
        "terminal-host:\(mode.rawValue):\(surfaceID.uuidString)"
    }

    @ViewBuilder
    var body: some View {
        switch mode {
        case .legacy:
            GhosttyIslandRepresentable(
                surfaceID: model.surfaceID,
                poolKey: model.poolKey,
                attachCommand: model.attachCommand,
                surfaceContext: model.surfaceContext,
                visiblePaneIdentity: model.visiblePaneIdentity,
                isFocused: model.isFocused,
                focusRestoreNonce: model.focusRestoreNonce
            )
            .equatable()

        case .next:
            NextGhosttyIslandRepresentable(model: model)
                .equatable()
        }
    }
}

/// Phase 1 boundary: the next host keeps legacy behavior while we split
/// ownership and cadence in later phases.
struct NextGhosttyIslandRepresentable: NSViewControllerRepresentable, Equatable {
    let model: TerminalHostRenderModel

    func makeNSViewController(context: Context) -> GhosttyIslandViewController {
        GhosttyIslandViewController(
            surfaceID: model.surfaceID,
            poolKey: model.poolKey,
            attachCommand: model.attachCommand,
            surfaceContext: model.surfaceContext,
            visiblePaneIdentity: model.visiblePaneIdentity
        )
    }

    func updateNSViewController(_ controller: GhosttyIslandViewController, context: Context) {
        controller.update(
            attachCommand: model.attachCommand,
            surfaceContext: model.surfaceContext,
            visiblePaneIdentity: model.visiblePaneIdentity,
            isFocused: model.isFocused,
            focusRestoreNonce: model.focusRestoreNonce
        )
    }
}
