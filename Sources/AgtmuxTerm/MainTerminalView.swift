import SwiftUI
import AgtmuxTermCore

private enum MainTerminalChrome {
    static let panelFill = Color.black.opacity(0.22)
    static let panelStroke = Color.white.opacity(0.06)
    static let statusFill = Color.white.opacity(0.055)
    static let statusStroke = Color.white.opacity(0.09)
    static let errorFill = Color.red.opacity(0.12)
    static let errorStroke = Color.red.opacity(0.18)
}

struct MainTerminalView: View {
    @Environment(MainTerminalStore.self) private var terminalStore

    private var hostViewIdentity: String {
        "main-terminal:\(terminalStore.surfaceID.uuidString):\(terminalStore.attachSurfaceGeneration)"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(MainTerminalChrome.panelFill)

            terminalSurface

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    MainTerminalStatusChip(
                        title: terminalStore.statusTitle,
                        detail: terminalStore.statusDetail
                    )
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.terminalMainStatus)

                if let diagnosticMessage = terminalStore.diagnosticMessage,
                   !diagnosticMessage.isEmpty {
                    Text(diagnosticMessage)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(MainTerminalChrome.errorFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(MainTerminalChrome.errorStroke, lineWidth: 1)
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(AccessibilityID.terminalMainDiagnostic)
                }
            }
            .padding(12)
            .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .stroke(MainTerminalChrome.panelStroke, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.terminalMain)
    }

    @ViewBuilder
    private var terminalSurface: some View {
        switch terminalStore.mode {
        case .plainShell:
            GhosttyIslandRepresentable(
                surfaceID: terminalStore.surfaceID,
                poolKey: "main-terminal:plain-shell",
                attachCommand: nil,
                surfaceContext: nil,
                visiblePaneIdentity: nil,
                isFocused: true,
                focusRestoreNonce: terminalStore.focusRequestNonce
            )
            .id(hostViewIdentity)
            .accessibilityIdentifier(AccessibilityID.terminalMainSurface)

        case .tmux(let sessionRef, _, _):
            switch terminalStore.attachResolution {
            case .success(let plan):
                MainTerminalFastHostContainer(
                    model: TerminalHostRenderModel(
                        surfaceID: terminalStore.surfaceID,
                        poolKey: plan.surfaceKey,
                        attachCommand: plan.command,
                        surfaceContext: GhosttyTerminalSurfaceContext(
                            viewportID: terminalStore.viewportID,
                            surfaceID: terminalStore.surfaceID,
                            surfaceKey: plan.surfaceKey,
                            sessionRef: sessionRef
                        ),
                        visiblePaneIdentity: terminalStore.visiblePaneIdentity,
                        isFocused: true,
                        focusRestoreNonce: terminalStore.focusRequestNonce
                    )
                )
                .id(hostViewIdentity)
                .accessibilityIdentifier(AccessibilityID.terminalMainSurface)

            case .failure(let error):
                MainTerminalFailureState(message: error.localizedDescription)

            case .none:
                MainTerminalFailureState(message: "Attach plan unavailable.")
            }
        }
    }
}

private struct MainTerminalFastHostContainer: View, Equatable {
    let model: TerminalHostRenderModel

    var body: some View {
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
    }
}

private struct MainTerminalStatusChip: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))
            Text(detail)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.56))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(MainTerminalChrome.statusFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(MainTerminalChrome.statusStroke, lineWidth: 1)
        )
    }
}

private struct MainTerminalFailureState: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terminal unavailable")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.88))
            Text(message)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }
}
