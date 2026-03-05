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

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(width: controlsSlotWidth, alignment: .leading)

            TabBarView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, iconLeading)
        .padding(.trailing, 6)
        .offset(y: chromeState.yOffset)
        .animation(.easeInOut(duration: 0.16), value: chromeState.isSidebarCollapsed)
    }

    private var iconLeading: CGFloat {
        max(
            0,
            chromeState.trafficLightsTrailingXInAccessory + TitlebarChromeMetrics.trafficLightGap
        )
    }

    private var controlsSlotWidth: CGFloat {
        if chromeState.isSidebarCollapsed {
            return controlsContentWidth
        }

        let boundaryInAccessory = max(
            0,
            sidebarExpandedWidth - chromeState.titlebarAccessoryMinXInWindow
        )
        return max(controlsContentWidth, boundaryInAccessory - iconLeading)
    }

    private var controlsContentWidth: CGFloat {
        let iconCount = chromeState.isSidebarCollapsed ? 2 : 4
        let button = TitlebarChromeMetrics.iconButtonSize
        let spacing = TitlebarChromeMetrics.iconSpacing
        return (CGFloat(iconCount) * button) + (CGFloat(max(0, iconCount - 1)) * spacing)
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
                accessibilityLabel: "Toggle Sidebar",
                accessibilityID: AccessibilityID.sidebarFilterToggle
            ) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: TitlebarChromeMetrics.iconGlyphSize, weight: .semibold))
                    .frame(width: TitlebarChromeMetrics.iconGlyphSize, height: TitlebarChromeMetrics.iconGlyphSize)
            }

            if !chromeState.isSidebarCollapsed {
                TitlebarIconButton(
                    isActive: viewModel.statusFilter == .managed,
                    action: { toggleFilter(.managed) },
                    accessibilityLabel: "Managed",
                    accessibilityID: AccessibilityID.sidebarFilterManaged
                ) {
                    ProviderIcon(provider: .codex, size: TitlebarChromeMetrics.iconGlyphSize)
                        .frame(width: TitlebarChromeMetrics.iconGlyphSize, height: TitlebarChromeMetrics.iconGlyphSize)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            TitlebarIconButton(
                isActive: viewModel.statusFilter == .attention,
                action: { toggleFilter(.attention) },
                accessibilityLabel: "Attention",
                accessibilityID: AccessibilityID.sidebarFilterAttention
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
                    accessibilityLabel: "Pinned",
                    accessibilityID: AccessibilityID.sidebarFilterPinned
                ) {
                    Image(systemName: viewModel.statusFilter == .pinned ? "pin.fill" : "pin")
                        .font(.system(size: TitlebarChromeMetrics.iconGlyphSize, weight: .semibold))
                        .frame(width: TitlebarChromeMetrics.iconGlyphSize, height: TitlebarChromeMetrics.iconGlyphSize)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.sidebarFilterBar)
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
    let accessibilityID: String?
    let label: () -> Label

    @State private var isHovered = false

    init(
        isActive: Bool,
        action: @escaping () -> Void,
        accessibilityLabel: String,
        accessibilityID: String? = nil,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.isActive = isActive
        self.action = action
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityID = accessibilityID
        self.label = label
    }

    var body: some View {
        let button = Button(action: action) {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)

        if let accessibilityID {
            button.accessibilityIdentifier(accessibilityID)
        } else {
            button
        }
    }

    private var background: Color {
        if isActive { return TitlebarChromeMetrics.controlActive }
        if isHovered { return TitlebarChromeMetrics.controlHover }
        return .clear
    }
}
