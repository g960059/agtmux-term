import AppKit
import SwiftUI
import AgtmuxTermCore

private enum CockpitChrome {
    static let workspaceTintTop = Color(red: 0.05, green: 0.09, blue: 0.14).opacity(0.18)
    static let workspaceTintBottom = Color(red: 0.02, green: 0.03, blue: 0.06).opacity(0.12)
    static let workspaceShade = Color.black.opacity(0.14)
}

// MARK: - CockpitView

/// Top-level layout: sidebar pane list + workspace area side by side.
struct CockpitView: View {
    @Environment(CockpitChromeState.self) private var chromeState

    private let sidebarExpandedWidth: CGFloat = 252

    var body: some View {
        ZStack {
            WindowBackdropView()
                .ignoresSafeArea()

            ZStack {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).opacity(0.18)
                    LinearGradient(
                        colors: [CockpitChrome.workspaceTintTop, CockpitChrome.workspaceTintBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                HStack(spacing: 0) {
                    if !chromeState.isSidebarCollapsed {
                        SidebarView()
                            .frame(width: sidebarExpandedWidth)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    WorkspaceArea()
                        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                        .background(CockpitChrome.workspaceShade)
                }
                .padding(.top, max(0, chromeState.titlebarHeight))
                .animation(.easeInOut(duration: 0.16), value: chromeState.isSidebarCollapsed)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .all)
        }
        .preferredColorScheme(.dark)
    }
}

private struct WindowBackdropView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}
