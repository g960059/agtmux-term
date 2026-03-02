import SwiftUI

// MARK: - FilterBarView

/// Horizontal tab bar for switching between StatusFilter modes.
struct FilterBarView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatusFilter.allCases, id: \.self) { filter in
                Button(action: { viewModel.statusFilter = filter }) {
                    Text(filter.displayName)
                        .font(.system(size: 12, weight: viewModel.statusFilter == filter ? .semibold : .regular))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
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
struct SourceHeaderView: View {
    let source: String
    let displayName: String?
    let isOffline: Bool

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
    }
}

// MARK: - SessionBlockView

/// A session block: header row (folder icon + name + branch) followed by a flat list of pane rows.
struct SessionBlockView: View {
    let session: SessionGroup
    @Binding var selectedPaneId: String?
    let onSelect: (AgtmuxPane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Session header — folder icon + session name + branch
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

                if let branch = session.representativeBranch {
                    Text(branch)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 120, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)

            // Pane rows
            ForEach(session.panes) { pane in
                SessionRowView(
                    pane: pane,
                    isSelected: selectedPaneId == pane.id
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect(pane) }
            }
        }
    }
}

// MARK: - SessionRowView

/// A single row representing one tmux pane.
struct SessionRowView: View {
    let pane: AgtmuxPane
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Activity state indicator (fixed-width slot for alignment)
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
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
        .help(tooltipText)
        .onHover { isHovered = $0 }
    }

    /// State indicator slot:
    ///   running         → green spinner
    ///   waitingApproval → orange raised-hand icon
    ///   waitingInput    → yellow ellipsis-circle icon
    ///   error           → red xmark-circle icon
    ///   idle / unknown / unmanaged → empty (no dot)
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
/// Loaded from bundled SVG resources via NSImage.
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
    /// Load the bundled SVG for this provider.
    /// - `currentColor` SVGs (openai, copilot) are returned as template images
    ///   so they automatically adapt to light/dark mode (label color).
    /// - Colored SVGs (claude, gemini) are returned as-is.
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

    /// Template rendering makes `currentColor` icons follow the system label color.
    private var usesTemplateRendering: Bool {
        switch self {
        case .claude, .gemini: return false
        case .codex, .copilot: return true
        }
    }
}

// MARK: - FreshnessLabel

/// Elapsed time since last daemon update. Always gray — no color-coding.
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

/// Scrollable pane list with filter bar, grouped by source → session.
struct SidebarView: View {
    @EnvironmentObject var viewModel: AppViewModel

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
                                selectedPaneId: Binding(
                                    get: { viewModel.selectedPane?.id },
                                    set: { _ in }
                                ),
                                onSelect: { viewModel.selectPane($0) }
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
