import AppKit
import SwiftUI
import AgtmuxTermCore

private enum CockpitChrome {
    static let workspaceTintTop = Color(red: 0.05, green: 0.09, blue: 0.14).opacity(0.18)
    static let workspaceTintBottom = Color(red: 0.02, green: 0.03, blue: 0.06).opacity(0.12)
    static let workspaceShade = Color.black.opacity(0.14)
    static let controlHover = Color.white.opacity(0.08)
    static let controlActive = Color.white.opacity(0.12)
    static let topBarHeight: CGFloat = 28
    static let iconButtonSize: CGFloat = 20
    static let iconGlyphSize: CGFloat = 13
}

// MARK: - CockpitView

/// Top-level layout: sidebar pane list + workspace area side by side.
struct CockpitView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var windowTopInset: CGFloat = 0
    @State private var isSidebarCollapsed = false

    private let sidebarExpandedWidth: CGFloat = 252
    private let collapsedControlsWidth: CGFloat = 56

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
                    Color.clear
                        .frame(height: max(0, (windowTopInset - CockpitChrome.topBarHeight) * 0.5))
                        .allowsHitTesting(false)

                    topChrome

                    HStack(spacing: 0) {
                        if !isSidebarCollapsed {
                            SidebarView()
                                .frame(width: sidebarExpandedWidth)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }

                        WorkspaceArea()
                            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                            .background(CockpitChrome.workspaceShade)
                    }
                    .animation(.easeInOut(duration: 0.18), value: isSidebarCollapsed)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .all)
        }
        .background(WindowStyleConfigurator { inset in
            let normalized = max(0, min(80, inset))
            if abs(normalized - windowTopInset) > 0.5 {
                windowTopInset = normalized
            }
        })
        .preferredColorScheme(.dark)
    }

    private var controlsSlotWidth: CGFloat {
        if isSidebarCollapsed { return collapsedControlsWidth }
        return sidebarExpandedWidth
    }

    private var topChrome: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                IconPillButton(
                    isActive: !isSidebarCollapsed,
                    action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSidebarCollapsed.toggle()
                        }
                    },
                    accessibilityLabel: "Toggle Sidebar"
                ) {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: CockpitChrome.iconGlyphSize, weight: .semibold))
                        .frame(width: CockpitChrome.iconGlyphSize, height: CockpitChrome.iconGlyphSize)
                }

                if !isSidebarCollapsed {
                    IconPillButton(
                        isActive: viewModel.statusFilter == .managed,
                        action: { toggleFilter(.managed) },
                        accessibilityLabel: "Managed"
                    ) {
                        ProviderIcon(provider: .codex, size: CockpitChrome.iconGlyphSize)
                            .frame(width: CockpitChrome.iconGlyphSize, height: CockpitChrome.iconGlyphSize)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }

                IconPillButton(
                    isActive: viewModel.statusFilter == .attention,
                    action: { toggleFilter(.attention) },
                    accessibilityLabel: "Attention"
                ) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: viewModel.statusFilter == .attention ? "bell.fill" : "bell")
                            .font(.system(size: CockpitChrome.iconGlyphSize, weight: .semibold))
                            .frame(width: CockpitChrome.iconGlyphSize, height: CockpitChrome.iconGlyphSize)
                        if viewModel.attentionCount > 0 {
                            Text("\(viewModel.attentionCount)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 2)
                                .padding(.vertical, 0.5)
                                .background(Color.accentColor)
                                .clipShape(Capsule(style: .continuous))
                                .offset(x: 7, y: -6)
                        }
                    }
                }

                if !isSidebarCollapsed {
                    IconPillButton(
                        isActive: viewModel.statusFilter == .pinned,
                        action: { toggleFilter(.pinned) },
                        accessibilityLabel: "Pinned"
                    ) {
                        Image(systemName: viewModel.statusFilter == .pinned ? "pin.fill" : "pin")
                            .font(.system(size: CockpitChrome.iconGlyphSize, weight: .semibold))
                            .frame(width: CockpitChrome.iconGlyphSize, height: CockpitChrome.iconGlyphSize)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .frame(width: controlsSlotWidth, alignment: .leading)
            .contentShape(Rectangle())
            .allowsHitTesting(true)
            .zIndex(3)

            TabBarView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(1)
        }
        .frame(height: CockpitChrome.topBarHeight, alignment: .center)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .accessibilityIdentifier(AccessibilityID.sidebarFilterBar)
        .animation(.easeInOut(duration: 0.18), value: isSidebarCollapsed)
    }

    private func toggleFilter(_ filter: StatusFilter) {
        if viewModel.statusFilter == filter {
            viewModel.statusFilter = .all
        } else {
            viewModel.statusFilter = filter
        }
    }
}

private struct IconPillButton<Label: View>: View {
    let isActive: Bool
    let action: () -> Void
    let label: () -> Label
    let accessibilityLabel: String

    @State private var isHovered = false

    init(
        isActive: Bool,
        action: @escaping () -> Void,
        accessibilityLabel: String,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.isActive = isActive
        self.action = action
        self.label = label
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(backgroundColor)
                label()
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .frame(width: CockpitChrome.iconButtonSize, height: CockpitChrome.iconButtonSize)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }

    private var backgroundColor: Color {
        if isActive { return CockpitChrome.controlActive }
        if isHovered { return CockpitChrome.controlHover }
        return .clear
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

private struct WindowStyleConfigurator: NSViewRepresentable {
    let onInsetChanged: (CGFloat) -> Void

    init(onInsetChanged: @escaping (CGFloat) -> Void = { _ in }) {
        self.onInsetChanged = onInsetChanged
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        let inset = max(0, window.frame.height - window.contentLayoutRect.height)
        onInsetChanged(inset)
    }
}
