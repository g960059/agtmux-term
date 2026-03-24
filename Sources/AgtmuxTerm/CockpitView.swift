import SwiftUI
import AgtmuxTermCore

private enum CockpitChrome {
    static let windowBase = Color(red: 0.04, green: 0.06, blue: 0.08)
    static let workspaceTintTop = Color(red: 0.08, green: 0.12, blue: 0.18)
    static let workspaceTintBottom = Color(red: 0.03, green: 0.04, blue: 0.07)
    static let workspaceShade = Color.black.opacity(0.18)
    static let topBarFill = Color(red: 0.07, green: 0.09, blue: 0.12).opacity(0.96)
    static let titlebarOcclusion = Color(red: 0.06, green: 0.08, blue: 0.11).opacity(0.98)
}

// MARK: - FullScreenTopBar

/// Persistent top bar shown when the window is in fullscreen mode,
/// replacing the hidden titlebar accessory.
private struct FullScreenTopBar: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(CockpitChromeState.self) private var chromeState
    @Environment(SidebarInventoryStore.self) private var sidebarStore
    @Environment(MainTerminalStore.self) private var mainTerminalStore

    private let sidebarExpandedWidth: CGFloat = 302
    private let iconSize: CGFloat = 20
    private let iconSpacing: CGFloat = 6

    var body: some View {
        HStack(spacing: 0) {
            // Left icon cluster — width matches sidebar when expanded so tab bar aligns with workspace
            leftIcons
                .padding(.leading, 8)
                .frame(
                    width: chromeState.isSidebarCollapsed ? nil : sidebarExpandedWidth,
                    alignment: .leading
                )

            Spacer(minLength: 0)

            Button {
                mainTerminalStore.startPlainShell()
            } label: {
                Label("New Shell", systemImage: "terminal")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.88))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
        }
        .frame(height: 36)
        .background(CockpitChrome.topBarFill)
    }

    @ViewBuilder
    private var leftIcons: some View {
        HStack(spacing: iconSpacing) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    chromeState.isSidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(Color.white.opacity(!chromeState.isSidebarCollapsed ? 0.88 : 0.56))
            }
            .buttonStyle(.plain)

            Button {
                viewModel.statusFilter = sidebarStore.statusFilter == .attention ? .all : .attention
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: sidebarStore.statusFilter == .attention ? "bell.fill" : "bell")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: iconSize, height: iconSize)
                    if sidebarStore.attentionCount > 0 {
                        Text("\(sidebarStore.attentionCount)")
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
        }
    }
}

// MARK: - CockpitView

/// Top-level layout: sidebar pane list + a single main terminal side by side.
struct CockpitView: View {
    @Environment(CockpitChromeState.self) private var chromeState

    private let sidebarExpandedWidth: CGFloat = 302

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [CockpitChrome.workspaceTintTop, CockpitChrome.workspaceTintBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
                .ignoresSafeArea()

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

                    MainTerminalView()
                        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                        .background(CockpitChrome.workspaceShade)
                }
                .padding(.top, chromeState.isFullScreen ? 0 : max(0, chromeState.titlebarHeight))
                .animation(.easeInOut(duration: 0.16), value: chromeState.isSidebarCollapsed)
            }
            .background(CockpitChrome.windowBase)
            .overlay(alignment: .top) {
                if !chromeState.isFullScreen {
                    Rectangle()
                        .fill(CockpitChrome.titlebarOcclusion)
                        .frame(height: max(0, chromeState.titlebarHeight))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .all)
        }
        .background(CockpitChrome.windowBase)
        .preferredColorScheme(.dark)
    }
}
