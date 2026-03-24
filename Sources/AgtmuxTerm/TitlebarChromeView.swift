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
    @Environment(SidebarInventoryStore.self) private var sidebarStore
    @Environment(MainTerminalStore.self) private var mainTerminalStore

    private let sidebarExpandedWidth: CGFloat = 302

    var body: some View {
        if chromeState.isFullScreen {
            EmptyView()
        } else {
            HStack(spacing: 0) {
                controls
                    .frame(width: controlsSlotWidth, alignment: .leading)

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mainTerminalStore.statusTitle)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.9))
                        Text(mainTerminalStore.statusDetail)
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.52))
                    }

                    if let diagnosticMessage = mainTerminalStore.diagnosticInlineText,
                       !diagnosticMessage.isEmpty {
                        Text(diagnosticMessage)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.66))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, iconLeading)
            .padding(.trailing, 6)
            .offset(y: chromeState.yOffset)
            .animation(.easeInOut(duration: 0.16), value: chromeState.isSidebarCollapsed)
        }
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
        let iconCount = 4
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

            TitlebarIconButton(
                isActive: sidebarStore.statusFilter == .managed,
                action: { toggleFilter(.managed) },
                accessibilityLabel: "Agents Only",
                accessibilityID: AccessibilityID.sidebarFilterManaged
            ) {
                Image(systemName: sidebarStore.statusFilter == .managed ? "sparkle" : "sparkle")
                    .font(.system(size: TitlebarChromeMetrics.iconGlyphSize, weight: .semibold))
                    .frame(width: TitlebarChromeMetrics.iconGlyphSize, height: TitlebarChromeMetrics.iconGlyphSize)
            }

            TitlebarIconButton(
                isActive: sidebarStore.statusFilter == .attention,
                action: { toggleFilter(.attention) },
                accessibilityLabel: "Attention",
                ignoreAccessibilityChildren: false,
                accessibilityID: AccessibilityID.sidebarFilterAttention
            ) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: sidebarStore.statusFilter == .attention ? "bell.fill" : "bell")
                        .font(.system(size: TitlebarChromeMetrics.iconGlyphSize, weight: .semibold))
                        .frame(width: TitlebarChromeMetrics.iconGlyphSize, height: TitlebarChromeMetrics.iconGlyphSize)
                    if sidebarStore.attentionCount > 0 {
                        Text("\(sidebarStore.attentionCount)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 0.5)
                            .background(Color.accentColor)
                            .clipShape(Capsule(style: .continuous))
                            .offset(x: 7, y: -6)
                            .accessibilityIdentifier(AccessibilityID.sidebarFilterAttentionBadge)
                    }
                }
            }

            TitlebarNewShellButton()
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
    let ignoreAccessibilityChildren: Bool
    let accessibilityID: String?
    let label: () -> Label

    @State private var isHovered = false

    init(
        isActive: Bool,
        action: @escaping () -> Void,
        accessibilityLabel: String,
        ignoreAccessibilityChildren: Bool = true,
        accessibilityID: String? = nil,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.isActive = isActive
        self.action = action
        self.accessibilityLabel = accessibilityLabel
        self.ignoreAccessibilityChildren = ignoreAccessibilityChildren
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
        .accessibilityElement(children: ignoreAccessibilityChildren ? .ignore : .contain)
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

private struct TitlebarNewShellButton: View {
    @Environment(MainTerminalStore.self) private var mainTerminalStore
    @State private var isHovered = false

    var body: some View {
        Button(action: { mainTerminalStore.startPlainShell() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered ? TitlebarChromeMetrics.controlHover : Color.clear)
                Image(systemName: "terminal")
                    .font(.system(size: TitlebarChromeMetrics.iconGlyphSize, weight: .semibold))
                    .frame(width: TitlebarChromeMetrics.iconGlyphSize, height: TitlebarChromeMetrics.iconGlyphSize)
                    .foregroundStyle(Color.white.opacity(0.88))
            }
            .frame(
                width: TitlebarChromeMetrics.iconButtonSize,
                height: TitlebarChromeMetrics.iconButtonSize
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("New Shell")
        .accessibilityLabel("New Shell")
        .accessibilityIdentifier(AccessibilityID.terminalMainNewShell)
    }
}
