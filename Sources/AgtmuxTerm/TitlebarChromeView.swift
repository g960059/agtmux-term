import SwiftUI
import AgtmuxTermCore

private enum TitlebarChromeMetrics {
    static let iconButtonSize: CGFloat = 20
    static let iconGlyphSize: CGFloat = 13
    static let iconSpacing: CGFloat = 6
    static let trafficLightGap: CGFloat = iconSpacing
    static let controlHover = Color.white.opacity(0.08)
    static let controlActive = Color.white.opacity(0.12)
}

struct TitlebarChromeView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(CockpitChromeState.self) private var chromeState

    private let sidebarExpandedWidth: CGFloat = 252
    private let collapsedControlsWidth: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(width: controlsSlotWidth, alignment: .leading)
                .accessibilityIdentifier(AccessibilityID.sidebarFilterBar)

            TabBarView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, leadingInset)
        .padding(.trailing, 6)
        .offset(y: chromeState.yOffset)
        .animation(.easeInOut(duration: 0.16), value: chromeState.isSidebarCollapsed)
    }

    private var leadingInset: CGFloat {
        let raw = max(0, chromeState.trafficLightsTrailingX + TitlebarChromeMetrics.trafficLightGap)
        // Keep icons close to traffic lights, but never push workspace tabs right
        // beyond the main-panel boundary in sidebar-open mode.
        let cap = sidebarExpandedWidth - collapsedControlsWidth
        return min(raw, cap)
    }

    private var controlsSlotWidth: CGFloat {
        if chromeState.isSidebarCollapsed {
            return collapsedControlsWidth
        }
        // Keep first workspace tab aligned with the content split boundary.
        // Since the whole row is shifted right to avoid traffic lights,
        // subtract that inset from the sidebar slot width.
        let adjusted = sidebarExpandedWidth - leadingInset
        return max(collapsedControlsWidth, adjusted)
    }

    private var controls: some View {
        HStack(spacing: TitlebarChromeMetrics.iconSpacing) {
            TitlebarIconButton(
                isActive: !chromeState.isSidebarCollapsed,
                action: {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        chromeState.isSidebarCollapsed.toggle()
                    }
                },
                accessibilityLabel: "Toggle Sidebar"
            ) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: TitlebarChromeMetrics.iconGlyphSize, weight: .semibold))
                    .frame(width: TitlebarChromeMetrics.iconGlyphSize, height: TitlebarChromeMetrics.iconGlyphSize)
            }

            if !chromeState.isSidebarCollapsed {
                TitlebarIconButton(
                    isActive: viewModel.statusFilter == .managed,
                    action: { toggleFilter(.managed) },
                    accessibilityLabel: "Managed"
                ) {
                    ProviderIcon(provider: .codex, size: TitlebarChromeMetrics.iconGlyphSize)
                        .frame(width: TitlebarChromeMetrics.iconGlyphSize, height: TitlebarChromeMetrics.iconGlyphSize)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            TitlebarIconButton(
                isActive: viewModel.statusFilter == .attention,
                action: { toggleFilter(.attention) },
                accessibilityLabel: "Attention"
            ) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.statusFilter == .attention ? "bell.fill" : "bell")
                        .font(.system(size: TitlebarChromeMetrics.iconGlyphSize, weight: .semibold))
                        .frame(width: TitlebarChromeMetrics.iconGlyphSize, height: TitlebarChromeMetrics.iconGlyphSize)
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

            if !chromeState.isSidebarCollapsed {
                TitlebarIconButton(
                    isActive: viewModel.statusFilter == .pinned,
                    action: { toggleFilter(.pinned) },
                    accessibilityLabel: "Pinned"
                ) {
                    Image(systemName: viewModel.statusFilter == .pinned ? "pin.fill" : "pin")
                        .font(.system(size: TitlebarChromeMetrics.iconGlyphSize, weight: .semibold))
                        .frame(width: TitlebarChromeMetrics.iconGlyphSize, height: TitlebarChromeMetrics.iconGlyphSize)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private func toggleFilter(_ filter: StatusFilter) {
        if viewModel.statusFilter == filter {
            viewModel.statusFilter = .all
        } else {
            viewModel.statusFilter = filter
        }
    }
}

private struct TitlebarIconButton<Label: View>: View {
    let isActive: Bool
    let action: () -> Void
    let accessibilityLabel: String
    let label: () -> Label

    @State private var isHovered = false

    init(
        isActive: Bool,
        action: @escaping () -> Void,
        accessibilityLabel: String,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.isActive = isActive
        self.action = action
        self.accessibilityLabel = accessibilityLabel
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(background)
                label()
                    .foregroundStyle(Color.white.opacity(0.88))
            }
            .frame(
                width: TitlebarChromeMetrics.iconButtonSize,
                height: TitlebarChromeMetrics.iconButtonSize
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }

    private var background: Color {
        if isActive { return TitlebarChromeMetrics.controlActive }
        if isHovered { return TitlebarChromeMetrics.controlHover }
        return .clear
    }
}
