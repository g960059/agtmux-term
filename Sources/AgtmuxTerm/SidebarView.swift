import SwiftUI

// MARK: - FilterBarView

/// Horizontal tab bar for switching between StatusFilter modes.
struct FilterBarView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatusFilter.allCases, id: \.self) { filter in
                Button(action: { viewModel.statusFilter = filter }) {
                    ZStack(alignment: .topTrailing) {
                        Text(filter.displayName)
                            .font(.system(size: 12, weight: viewModel.statusFilter == filter ? .semibold : .regular))
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)

                        // Attention badge — only on the .attention tab, only when count > 0
                        if filter == .attention, viewModel.attentionCount > 0 {
                            Text("\(viewModel.attentionCount)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                                .offset(x: 4, y: -2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .background(
                    viewModel.statusFilter == filter
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear
                )
                .cornerRadius(4)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - SourceHeaderView

/// Section header for a source (local or a remote host).
/// Right-click → New Session.
struct SourceHeaderView: View {
    let source: String
    let displayName: String?
    let isOffline: Bool

    @EnvironmentObject private var viewModel: AppViewModel

    var label: String {
        if source == "local" { return "Local" }
        return displayName ?? source
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            if isOffline {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .help("Host offline")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .contextMenu {
            Button("New Session") {
                TmuxManager.shared.createSession(source: source, viewModel: viewModel)
            }
        }
    }
}

// MARK: - SessionBlockView

/// A session block: session header + window sub-blocks.
/// Right-click → New Window / Kill Session.
struct SessionBlockView: View {
    let session: SessionGroup
    let selectedPaneId: String?
    let onSelect: (AgtmuxPane) -> Void

    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Session header
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text(session.sessionName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                WindowStateBadge(panes: session.panes)

                if let branch = session.representativeBranch {
                    Text(branch)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 100, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .contextMenu {
                Button("New Window") {
                    TmuxManager.shared.createWindow(
                        sessionName: session.sessionName, source: session.source, viewModel: viewModel)
                }
                Divider()
                Button("Kill Session", role: .destructive) {
                    TmuxManager.shared.killSession(
                        session.sessionName, source: session.source, viewModel: viewModel)
                }
            }

            // Window sub-blocks
            ForEach(session.windows) { window in
                WindowBlockView(
                    window: window,
                    selectedPaneId: selectedPaneId,
                    onSelect: onSelect
                )
            }
        }
    }
}

// MARK: - WindowBlockView

/// A collapsible window block: window header + pane rows.
/// Right-click → New Pane / Kill Window.
struct WindowBlockView: View {
    let window: WindowGroup
    let selectedPaneId: String?
    let onSelect: (AgtmuxPane) -> Void

    @State private var isExpanded: Bool = true
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(WorkspaceStore.self) private var workspaceStore

    var windowLabel: String {
        if let name = window.windowName, !name.isEmpty {
            if let idx = window.windowIndex { return "\(idx): \(name)" }
            return name
        }
        return window.windowId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Window header row
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 10)

                Image(systemName: "terminal")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                Text(windowLabel)
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                WindowStateBadge(panes: window.panes)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
            .contextMenu {
                Button("Open in Workspace") {
                    Task { await workspaceStore.placeWindow(window) }
                }
                Divider()
                Button("New Pane") {
                    if let pane = window.panes.first {
                        TmuxManager.shared.createPane(
                            pane.paneId, source: window.source, viewModel: viewModel)
                    }
                }
                Divider()
                Button("Kill Window", role: .destructive) {
                    TmuxManager.shared.killWindow(
                        window.windowId, sessionName: window.sessionName,
                        source: window.source, viewModel: viewModel)
                }
            }

            // Pane rows (collapsible)
            if isExpanded {
                ForEach(window.panes) { pane in
                    PaneRowView(
                        pane: pane,
                        isSelected: selectedPaneId == pane.id
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(pane) }
                }
            }
        }
    }
}

// MARK: - PaneRowView

/// A single row representing one tmux pane.
/// Right-click → Kill Pane.
struct PaneRowView: View {
    let pane: AgtmuxPane
    let isSelected: Bool

    @State private var isHovered = false
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            // Activity state indicator (fixed-width slot)
            stateIndicator
                .frame(width: 12, height: 12)

            // Primary label
            Text(pane.primaryLabel)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(pane.isManaged ? .primary : .secondary)

            Spacer()

            // Provider icon (managed panes only)
            if let provider = pane.provider {
                ProviderIcon(provider: provider)
            }

            // Elapsed time since last state change (idle/waiting/error only)
            if pane.isManaged,
               let age = pane.ageSecs,
               pane.activityState != .running {
                FreshnessLabel(ageSecs: age)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .padding(.leading, 8)   // extra indent inside window block
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
        .help(tooltipText)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Kill Pane", role: .destructive) {
                TmuxManager.shared.killPane(pane.paneId, source: pane.source, viewModel: viewModel)
            }
        }
    }

    /// State indicator:
    ///   running         → green spinner
    ///   waitingApproval → orange raised-hand icon
    ///   waitingInput    → yellow ellipsis-circle icon
    ///   error           → red xmark-circle icon
    ///   idle / unknown / unmanaged → empty
    @ViewBuilder
    private var stateIndicator: some View {
        if pane.isManaged {
            switch pane.activityState {
            case .running:
                SpinnerView(color: .green, size: 11)
            case .waitingApproval:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            case .waitingInput:
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
            case .error:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            case .idle, .unknown:
                Color.clear
            }
        } else {
            Color.clear
        }
    }

    private var tooltipText: String {
        var parts: [String] = []
        if let branch = pane.gitBranch   { parts.append("⎇ \(branch)") }
        if let path = pane.currentPath   { parts.append("  \(path)") }
        if pane.isManaged {
            parts.append("evidence: \(pane.evidenceMode.rawValue)")
        }
        if let cmd = pane.currentCmd     { parts.append("cmd: \(cmd)") }
        return parts.joined(separator: "\n")
    }
}

// MARK: - WindowStateBadge

/// Compact badge row for running/attention counts within a window or session.
struct WindowStateBadge: View {
    let panes: [AgtmuxPane]

    private var runningCount: Int {
        panes.filter { $0.activityState == .running }.count
    }

    private var attentionCount: Int {
        panes.filter { $0.needsAttention }.count
    }

    var body: some View {
        HStack(spacing: 4) {
            if runningCount > 0 {
                StatBadge(count: runningCount, color: .green)
            }
            if attentionCount > 0 {
                StatBadge(count: attentionCount, color: Color.accentColor)
            }
        }
    }
}

/// A single colored dot + count badge (used in sidebar hierarchy rows).
private struct StatBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text("\(count)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - SpinnerView

/// Continuously rotating arc — used for the "running" activity state.
struct SpinnerView: View {
    let color: Color
    let size: CGFloat

    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

// MARK: - ProviderIcon

/// Brand-accurate SVG icon for each AI provider.
struct ProviderIcon: View {
    let provider: AgtmuxPane.Provider
    var size: CGFloat = 16

    var body: some View {
        if let img = provider.svgImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: size, height: size)
        }
    }
}

private extension AgtmuxPane.Provider {
    var svgImage: NSImage? {
        guard let url = Bundle.module.url(forResource: svgResourceName, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        if usesTemplateRendering { img.isTemplate = true }
        return img
    }

    private var svgResourceName: String {
        switch self {
        case .claude:  return "icon-claude"
        case .codex:   return "icon-openai"
        case .gemini:  return "icon-gemini"
        case .copilot: return "icon-copilot"
        }
    }

    private var usesTemplateRendering: Bool {
        switch self {
        case .claude, .gemini: return false
        case .codex, .copilot: return true
        }
    }
}

// MARK: - FreshnessLabel

/// Elapsed time since last daemon update.
struct FreshnessLabel: View {
    let ageSecs: Int

    var body: some View {
        Text(formatted)
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(.secondary)
    }

    private var formatted: String {
        switch ageSecs {
        case 0..<60:    return "\(ageSecs)s"
        case 60..<3600: return "\(ageSecs / 60)m"
        default:        return "\(ageSecs / 3600)h"
        }
    }
}

// MARK: - SidebarView

/// Scrollable pane list with filter bar, grouped by source → session → window → pane.
struct SidebarView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(WorkspaceStore.self) private var workspaceStore

    var body: some View {
        VStack(spacing: 0) {
            FilterBarView()
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(viewModel.panesBySession, id: \.source) { group in
                        SourceHeaderView(
                            source: group.source,
                            displayName: viewModel.hostsConfig.displayName(for: group.source),
                            isOffline: viewModel.offlineHosts.contains(group.source)
                        )

                        ForEach(group.sessions) { session in
                            SessionBlockView(
                                session: session,
                                selectedPaneId: viewModel.selectedPane?.id,
                                onSelect: { pane in
                                    viewModel.selectPane(pane)
                                    Task { await workspaceStore.placePane(pane) }
                                }
                            )
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - StatusFilter display helpers

private extension StatusFilter {
    var displayName: String {
        switch self {
        case .all:       return "All"
        case .managed:   return "Managed"
        case .attention: return "Attention"
        case .pinned:    return "Pinned"
        }
    }
}
