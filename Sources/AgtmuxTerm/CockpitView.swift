import AppKit
import SwiftUI
import AgtmuxTermCore

private enum CockpitChrome {
    static let workspaceTintTop = Color(red: 0.05, green: 0.09, blue: 0.14).opacity(0.18)
    static let workspaceTintBottom = Color(red: 0.02, green: 0.03, blue: 0.06).opacity(0.12)
    static let workspaceShade = Color.black.opacity(0.14)
    static let floatingOcclusionOpacity: CGFloat = 0.82
}

// MARK: - FullScreenTopBar

/// Persistent top bar shown when the window is in fullscreen mode,
/// replacing the hidden titlebar accessory.
private struct FullScreenTopBar: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(CockpitChromeState.self) private var chromeState
    @Environment(WorkbenchStoreV2.self) private var workbenchStoreV2

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar toggle
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    chromeState.isSidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Color.white.opacity(!chromeState.isSidebarCollapsed ? 0.88 : 0.56))
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)

            // Attention bell
            Button {
                if viewModel.statusFilter == .attention {
                    viewModel.statusFilter = .all
                } else {
                    viewModel.statusFilter = .attention
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.statusFilter == .attention ? "bell.fill" : "bell")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 20, height: 20)
                    if viewModel.attentionCount > 0 {
                        Text("\(viewModel.attentionCount)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 0.5)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                            .offset(x: 7, y: -6)
                    }
                }
                .foregroundStyle(Color.white.opacity(0.88))
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)

            // Tab bar fills remaining width
            WorkbenchTabBarV2()
                .frame(maxWidth: .infinity)
        }
        .frame(height: 36)
        .background(.ultraThinMaterial.opacity(0.3))
    }
}

// MARK: - CockpitView

/// Top-level layout: sidebar pane list + workspace area side by side.
struct CockpitView: View {
    @Environment(CockpitChromeState.self) private var chromeState

    private let sidebarExpandedWidth: CGFloat = 302

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

                VStack(spacing: 0) {
                    if chromeState.isFullScreen {
                        FullScreenTopBar()
                    }

                    HStack(spacing: 0) {
                        if !chromeState.isSidebarCollapsed {
                            SidebarView()
                                .frame(width: sidebarExpandedWidth)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }

                        WorkbenchAreaV2()
                            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                            .background(CockpitChrome.workspaceShade)
                    }
                    .padding(.top, chromeState.isFullScreen ? 0 : max(0, chromeState.titlebarHeight))
                    .animation(.easeInOut(duration: 0.16), value: chromeState.isSidebarCollapsed)
                }
            }
            .overlay(alignment: .top) {
                if !chromeState.isFullScreen {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(CockpitChrome.floatingOcclusionOpacity)
                        .frame(height: max(0, chromeState.titlebarHeight))
                        .allowsHitTesting(false)
                }
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
