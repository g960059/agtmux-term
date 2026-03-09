import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AgtmuxTermCore

private enum SidebarRowStyle {
    static let rowFill = Color.white.opacity(0.045)
    static let hoverBackground = Color.white.opacity(0.085)
    static let hoverStroke = Color.white.opacity(0.16)
    // Keep selection visually identical to hover so it feels persistent, not "blue-selected".
    static let selectedBackground = hoverBackground
    static let selectedStroke = hoverStroke
    static let sidebarFill = Color(red: 0.10, green: 0.22, blue: 0.33).opacity(0.34)
    static let sidebarDivider = Color.white.opacity(0.06)
    static let cornerRadius: CGFloat = 9
}

// MARK: - FilterBarView

/// Horizontal tab bar for switching between StatusFilter modes.
struct FilterBarView: View {
    let onToggleSidebar: () -> Void
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.78))
            .help("Toggle Sidebar")

            filterPill(isActive: viewModel.statusFilter == .managed) {
                ProviderIcon(provider: .codex, size: 13)
                    .frame(width: 13, height: 13)
            } action: {
                toggleFilter(.managed)
            }
            .help("Managed")

            filterPill(isActive: viewModel.statusFilter == .attention) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.statusFilter == .attention ? "bell.fill" : "bell")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 13, height: 13)
                    if viewModel.attentionCount > 0 {
                        Text("\(viewModel.attentionCount)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                            .offset(x: 7, y: -6)
                    }
                }
            } action: {
                toggleFilter(.attention)
            }
            .help("Attention")

            filterPill(isActive: viewModel.statusFilter == .pinned) {
                Image(systemName: viewModel.statusFilter == .pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 13, height: 13)
            } action: {
                toggleFilter(.pinned)
            }
            .help("Pinned")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.clear)
        .accessibilityIdentifier(AccessibilityID.sidebarFilterBar)
    }

    private func toggleFilter(_ filter: StatusFilter) {
        if viewModel.statusFilter == filter {
            viewModel.statusFilter = .all
        } else {
            viewModel.statusFilter = filter
        }
    }

    private func filterPill<Content: View>(
        isActive: Bool,
        @ViewBuilder content: () -> Content,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            content()
                .foregroundStyle(isActive ? Color.white.opacity(0.95) : Color.white.opacity(0.78))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? SidebarRowStyle.selectedBackground : SidebarRowStyle.rowFill)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(isActive ? SidebarRowStyle.selectedStroke : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.56))

            if isOffline {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .help("Host offline")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .contextMenu {
            Button("New Session") {
                TmuxManager.shared.createSession(source: source, viewModel: viewModel)
            }
        }
    }
}

// MARK: - SessionBlockView

struct DraggedSession: Equatable {
    let source: String
    let sessionName: String
}

private func paneScrollRowID(_ pane: AgtmuxPane) -> String {
    "pane:\(pane.id)"
}

/// A session block: session header + window sub-blocks.
/// Right-click → New Window / Kill Session.
struct SessionBlockView: View {
    let session: SessionGroup
    let selectedPaneId: String?
    @Binding var highlightedRowID: String?
    @Binding var draggedSession: DraggedSession?
    let onSelect: (AgtmuxPane, AgtmuxTermCore.WindowGroup) -> Void

    @EnvironmentObject private var viewModel: AppViewModel

    private var rowID: String { "session:\(session.id)" }
    private var isHighlighted: Bool { highlightedRowID == rowID }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Session header
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.56))

                Text(session.sessionName)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                WindowStateBadge(panes: session.panes)

                if let branch = session.representativeBranch {
                    Text(branch)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 100, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                    .fill(isHighlighted ? SidebarRowStyle.hoverBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                    .stroke(isHighlighted ? SidebarRowStyle.hoverStroke : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    highlightedRowID = rowID
                } else if highlightedRowID == rowID {
                    highlightedRowID = nil
                }
            }
            .onTapGesture {
                highlightedRowID = rowID
                guard let window = session.windows.first,
                      let pane = window.panes.first else { return }
                onSelect(pane, window)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                AccessibilityID.sidebarSessionPrefix +
                AccessibilityID.sessionKey(source: session.source, sessionName: session.sessionName)
            )
            .onDrag {
                highlightedRowID = rowID
                draggedSession = DraggedSession(source: session.source, sessionName: session.sessionName)
                return NSItemProvider(object: session.id as NSString)
            }
            .onDrop(
                of: [UTType.text],
                delegate: SessionReorderDropDelegate(
                    targetSession: session,
                    draggedSession: $draggedSession,
                    viewModel: viewModel
                )
            )
            .contextMenu {
                let allPinned = viewModel.areAllPanesPinned(in: session)
                Button {
                    guard let window = session.windows.first,
                          let pane = window.panes.first else { return }
                    onSelect(pane, window)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                Button {
                    TmuxManager.shared.renameSession(
                        session.sessionName,
                        source: session.source,
                        viewModel: viewModel
                    )
                } label: {
                    Label("Rename Session", systemImage: "pencil")
                }
                Button {
                    viewModel.setSessionPinned(session, pinned: !allPinned)
                } label: {
                    Label(allPinned ? "Unpin Session" : "Pin Session",
                          systemImage: allPinned ? "pin.slash" : "pin")
                }
                Button {
                    TmuxManager.shared.createWindow(
                        sessionName: session.sessionName, source: session.source, viewModel: viewModel)
                } label: {
                    Label("New Window", systemImage: "plus.rectangle.on.rectangle")
                }
                Divider()
                Button(role: .destructive) {
                    TmuxManager.shared.killSession(
                        session.sessionName, source: session.source, viewModel: viewModel)
                } label: {
                    Label("Kill Session", systemImage: "trash")
                }
            }

            // Window sub-blocks
            ForEach(session.windows) { window in
                WindowBlockView(
                    window: window,
                    selectedPaneId: selectedPaneId,
                    highlightedRowID: $highlightedRowID,
                    onSelect: onSelect
                )
            }
        }
    }
}

private struct SessionReorderDropDelegate: DropDelegate {
    let targetSession: SessionGroup
    @Binding var draggedSession: DraggedSession?
    let viewModel: AppViewModel

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggedSession else { return false }
        return draggedSession.source == targetSession.source
    }

    func dropEntered(info: DropInfo) {
        guard let draggedSession else { return }
        guard draggedSession.source == targetSession.source else { return }
        viewModel.moveSession(
            source: targetSession.source,
            draggedSessionName: draggedSession.sessionName,
            targetSessionName: targetSession.sessionName
        )
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedSession = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Keep drag state alive until performDrop so hover transitions stay smooth.
    }
}

// MARK: - WindowBlockView

/// A collapsible window block: window header + pane rows.
/// Right-click → New Pane / Kill Window.
struct WindowBlockView: View {
    let window: AgtmuxTermCore.WindowGroup
    let selectedPaneId: String?
    @Binding var highlightedRowID: String?
    let onSelect: (AgtmuxPane, AgtmuxTermCore.WindowGroup) -> Void

    @State private var isExpanded: Bool = true
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(WorkbenchStoreV2.self) private var workbenchStoreV2

    private var rowID: String { "window:\(window.id)" }
    private var isHighlighted: Bool { highlightedRowID == rowID }

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
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(width: 10)

                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.72))

                Text(windowLabel)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                WindowStateBadge(panes: window.panes)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                AccessibilityID.sidebarWindowPrefix +
                AccessibilityID.windowKey(
                    source: window.source,
                    sessionName: window.sessionName,
                    windowID: window.windowId
                )
            )
            .background(
                RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                    .fill(isHighlighted ? SidebarRowStyle.hoverBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                    .stroke(isHighlighted ? SidebarRowStyle.hoverStroke : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    highlightedRowID = rowID
                } else if highlightedRowID == rowID {
                    highlightedRowID = nil
                }
            }
            .onTapGesture {
                highlightedRowID = rowID
                isExpanded.toggle()
            }
            .contextMenu {
                let allPinned = viewModel.areAllPanesPinned(in: window)
                Button {
                    guard let pane = window.panes.first else { return }
                    workbenchStoreV2.openTerminal(for: pane, hostsConfig: viewModel.hostsConfig)
                } label: {
                    Label("Open in Workspace", systemImage: "rectangle.3.group")
                }
                Button {
                    TmuxManager.shared.renameWindow(
                        window.windowId,
                        sessionName: window.sessionName,
                        source: window.source,
                        viewModel: viewModel
                    )
                } label: {
                    Label("Rename Window", systemImage: "pencil")
                }
                Button {
                    viewModel.setWindowPinned(window, pinned: !allPinned)
                } label: {
                    Label(allPinned ? "Unpin Window" : "Pin Window",
                          systemImage: allPinned ? "pin.slash" : "pin")
                }
                Divider()
                Button {
                    if let pane = window.panes.first {
                        TmuxManager.shared.createPane(
                            pane.paneId, source: window.source, viewModel: viewModel)
                    }
                } label: {
                    Label("Split Right", systemImage: "rectangle.split.2x1")
                }
                Button {
                    if let pane = window.panes.first {
                        TmuxManager.shared.createPane(
                            pane.paneId, splitAxis: .vertical, source: window.source, viewModel: viewModel)
                    }
                } label: {
                    Label("Split Below", systemImage: "rectangle.split.1x2")
                }
                Divider()
                Button(role: .destructive) {
                    TmuxManager.shared.killWindow(
                        window.windowId, sessionName: window.sessionName,
                        source: window.source, viewModel: viewModel)
                } label: {
                    Label("Kill Window", systemImage: "trash")
                }
            }

            // Pane rows (collapsible)
            if isExpanded {
                ForEach(window.panes) { pane in
                    paneRow(pane)
                }
            }
        }
        .onAppear {
            if containsSelectedPane(selectedPaneId) {
                isExpanded = true
            }
        }
        .onChange(of: selectedPaneId) { _, newValue in
            if containsSelectedPane(newValue) {
                isExpanded = true
            }
        }
    }

    private func containsSelectedPane(_ paneID: String?) -> Bool {
        if window.panes.contains(where: isPaneSelected) {
            return true
        }
        guard let paneID else { return false }
        return window.panes.contains(where: { $0.id == paneID })
    }

    @ViewBuilder
    private func paneRow(_ pane: AgtmuxPane) -> some View {
        let isSelected = isPaneSelected(pane)
        Button(action: { selectPaneRow(pane) }) {
            PaneRowView(
                pane: pane,
                isSelected: isSelected,
                highlightedRowID: $highlightedRowID
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            AccessibilityID.sidebarPanePrefix +
            AccessibilityID.paneKey(
                source: pane.source,
                sessionName: pane.sessionName,
                paneID: pane.paneId
            )
        )
        .accessibilityLabel(Text(viewModel.paneDisplayTitle(for: pane)))
        .accessibilityValue(Text(
            PaneRowAccessibility.summary(
                for: pane,
                presentation: viewModel.panePresentation(for: pane),
                isSelected: isSelected
            )
        ))
        .accessibilityAddTraits(.isButton)
        .id(paneScrollRowID(pane))
        .overlay(alignment: .trailing) {
            if isSelected {
                Color.clear
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityIdentifier(selectedMarkerID(for: pane))
            }
        }
    }

    private func selectPaneRow(_ pane: AgtmuxPane) {
        highlightedRowID = "pane:\(pane.id)"
        onSelect(pane, window)
    }

    private func selectedMarkerID(for pane: AgtmuxPane) -> String {
        "sidebar.pane.selected." +
        AccessibilityID.paneKey(
            source: pane.source,
            sessionName: pane.sessionName,
            paneID: pane.paneId
        )
    }

    private func isPaneSelected(_ pane: AgtmuxPane) -> Bool {
        selectedPaneId == pane.id
    }
}

// MARK: - PaneRowView

/// A single row representing one tmux pane.
/// Right-click → Kill Pane.
struct PaneRowView: View {
    let pane: AgtmuxPane
    let isSelected: Bool
    @Binding var highlightedRowID: String?

    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(WorkbenchStoreV2.self) private var workbenchStoreV2

    private var rowID: String { "pane:\(pane.id)" }
    private var isHighlighted: Bool { highlightedRowID == rowID }
    private var paneAXKey: String {
        AccessibilityID.paneKey(
            source: pane.source,
            sessionName: pane.sessionName,
            paneID: pane.paneId
        )
    }
    private var displayState: PaneDisplayState { viewModel.paneDisplayState(for: pane) }
    private var provider: Provider? { displayState.provider }
    private var primaryState: PanePresentationPrimaryState { displayState.primaryState }
    private var freshnessText: String? { displayState.freshnessText }
    private var isManaged: Bool { displayState.isManaged }

    var body: some View {
        HStack(spacing: 10) {
            // Activity state indicator (fixed-width slot)
            stateIndicator
                .frame(width: 10, height: 10)

            // Primary label
            Text(viewModel.paneDisplayTitle(for: pane))
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isManaged ? Color.white.opacity(0.95) : Color.white.opacity(0.82))

            Spacer()

            // Provider icon (managed panes only)
            if let provider {
                ProviderIcon(provider: provider)
            }

            // Elapsed time since last state change (idle/waiting/error only)
            if isManaged,
               let freshnessText {
                FreshnessLabel(text: freshnessText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                .stroke(rowStroke, lineWidth: 1)
        )
        .overlay(alignment: .trailing) {
            accessibilityMetadataMarkers
        }
        .contentShape(Rectangle())
        .help(tooltipText)
        .onHover { hovering in
            if hovering {
                highlightedRowID = rowID
            } else if highlightedRowID == rowID {
                highlightedRowID = nil
            }
        }
        .contextMenu {
            let isPinned = viewModel.isPanePinned(pane)
            Button {
                workbenchStoreV2.openTerminal(for: pane, hostsConfig: viewModel.hostsConfig)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            Button {
                TmuxManager.shared.renamePane(pane, source: pane.source, viewModel: viewModel)
            } label: {
                Label("Rename Pane", systemImage: "pencil")
            }
            Button {
                viewModel.setPanePinned(pane, pinned: !isPinned)
            } label: {
                Label(isPinned ? "Unpin Pane" : "Pin Pane",
                      systemImage: isPinned ? "pin.slash" : "pin")
            }
            Divider()
            Button {
                TmuxManager.shared.createPane(
                    pane.paneId,
                    splitAxis: .horizontal,
                    source: pane.source,
                    viewModel: viewModel
                )
            } label: {
                Label("Split Right", systemImage: "rectangle.split.2x1")
            }
            Button {
                TmuxManager.shared.createPane(
                    pane.paneId,
                    splitAxis: .vertical,
                    source: pane.source,
                    viewModel: viewModel
                )
            } label: {
                Label("Split Below", systemImage: "rectangle.split.1x2")
            }
            Divider()
            Button {
                copyPanePath()
            } label: {
                Label("Copy Pane Path", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                TmuxManager.shared.killPane(pane.paneId, source: pane.source, viewModel: viewModel)
            } label: {
                Label("Kill Pane", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var accessibilityMetadataMarkers: some View {
        HStack(spacing: 0) {
            if let provider {
                Color.clear
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityIdentifier(AccessibilityID.sidebarPaneProviderPrefix + paneAXKey)
                    .accessibilityLabel(provider.rawValue)
            }

            if isManaged {
                Color.clear
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityIdentifier(AccessibilityID.sidebarPaneActivityPrefix + paneAXKey)
                    .accessibilityLabel(primaryState.rawValue)
            }
        }
    }

    private var rowBackground: Color {
        if isSelected || isHighlighted { return SidebarRowStyle.selectedBackground }
        return .clear
    }

    private var rowStroke: Color {
        if isSelected || isHighlighted { return SidebarRowStyle.selectedStroke }
        return .clear
    }

    /// State indicator:
    ///   running         → green spinner
    ///   waitingApproval → orange raised-hand icon
    ///   waitingInput    → yellow ellipsis-circle icon
    ///   error           → red xmark-circle icon
    ///   completed-idle / idle / inactive / unmanaged → empty
    @ViewBuilder
    private var stateIndicator: some View {
        if isManaged {
            switch primaryState {
            case .running:
                SpinnerView(color: .green, size: 11)
            case .waitingApproval:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            case .waitingUserInput:
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
            case .error:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            case .completedIdle, .idle, .inactive:
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
        if displayState.isManaged {
            parts.append("evidence: \(pane.evidenceMode.rawValue)")
        }
        if let cmd = pane.currentCmd     { parts.append("cmd: \(cmd)") }
        return parts.joined(separator: "\n")
    }

    private func copyPanePath() {
        let value = "\(pane.source)/\(pane.sessionName)/\(pane.windowId)/\(pane.paneId)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

// MARK: - WindowStateBadge

/// Compact badge row for running/attention counts within a window or session.
struct WindowStateBadge: View {
    let panes: [AgtmuxPane]
    @EnvironmentObject private var viewModel: AppViewModel

    private var runningCount: Int {
        panes.filter { viewModel.paneDisplayState(for: $0).primaryState == .running }.count
    }

    private var attentionCount: Int {
        panes.filter { viewModel.paneDisplayState(for: $0).needsAttention }.count
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
                .foregroundStyle(Color.white.opacity(0.72))
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
    let provider: Provider
    var size: CGFloat = 16

    var body: some View {
        if let img = provider.svgImage {
            if provider.usesTemplateRendering {
                Image(nsImage: img)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .foregroundStyle(Color.white.opacity(0.78))
                    .frame(width: size, height: size)
            } else {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: size, height: size)
            }
        }
    }
}

private extension Provider {
    var svgImage: NSImage? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: svgResourceName, withExtension: "svg"),
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

    var usesTemplateRendering: Bool {
        switch self {
        case .claude, .gemini: return false
        case .codex, .copilot: return true
        }
    }
}

// MARK: - FreshnessLabel

/// Elapsed time since last daemon update.
struct FreshnessLabel: View {
    let text: String

    init(text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .rounded).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.56))
    }
}

private struct LocalDaemonIssueBanner: View {
    let issue: LocalDaemonIssue

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange.opacity(0.92))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.bannerTitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(issue.bannerMessage)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                .stroke(Color.orange.opacity(0.24), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .help(issue.detail)
        .accessibilityElement(children: .combine)
    }
}

private struct LocalDaemonHealthBadgeModel: Identifiable {
    let id: String
    let title: String
    let value: String?
    let status: AgtmuxUIHealthStatus
    let helpText: String

    var accessibilityValue: String {
        if let value, !value.isEmpty {
            return "\(status.displayName), \(value)"
        }
        return status.displayName
    }
}

private struct LocalDaemonHealthStrip: View {
    let health: AgtmuxUIHealthV1
    let topPadding: CGFloat

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 6),
        GridItem(.flexible(minimum: 0), spacing: 6),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("HEALTH")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.56))

                Spacer(minLength: 0)

                Text(health.generatedAtLabel)
                    .font(.system(size: 10, weight: .regular, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.48))
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(health.badgeModels) { badge in
                    LocalDaemonHealthBadge(badge: badge)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                .fill(SidebarRowStyle.rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                .stroke(SidebarRowStyle.sidebarDivider, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.top, topPadding)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.sidebarHealthStrip)
        .accessibilityLabel("Local daemon health")
        .accessibilityValue(health.accessibilitySummary)
    }
}

private struct LocalDaemonHealthBadge: View {
    let badge: LocalDaemonHealthBadgeModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: badge.status.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(badge.status.tint)

            Text(badge.title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.86))
                .lineLimit(1)

            Spacer(minLength: 0)

            if let value = badge.value {
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced).monospacedDigit())
                    .foregroundStyle(badge.status.tint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                .fill(badge.status.tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                .stroke(badge.status.tint.opacity(0.24), lineWidth: 1)
        )
        .help(badge.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.sidebarHealthBadgePrefix + badge.id)
        .accessibilityLabel("\(badge.title) health")
        .accessibilityValue(badge.accessibilityValue)
        .accessibilityHint(badge.helpText)
    }
}

private extension AgtmuxUIHealthStatus {
    var displayName: String {
        switch self {
        case .ok:
            return "ok"
        case .degraded:
            return "degraded"
        case .unavailable:
            return "unavailable"
        }
    }

    var symbolName: String {
        switch self {
        case .ok:
            return "checkmark.circle.fill"
        case .degraded:
            return "exclamationmark.circle.fill"
        case .unavailable:
            return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ok:
            return Color.green.opacity(0.88)
        case .degraded:
            return Color.orange.opacity(0.92)
        case .unavailable:
            return Color.red.opacity(0.92)
        }
    }
}

private extension AgtmuxUIHealthV1 {
    var generatedAtLabel: String {
        "Updated \(generatedAt.sidebarHealthTimestamp)"
    }

    var badgeModels: [LocalDaemonHealthBadgeModel] {
        [
            LocalDaemonHealthBadgeModel(
                id: "runtime",
                title: "Runtime",
                value: runtime.sidebarValue,
                status: runtime.status,
                helpText: componentHelpText(
                    title: "Runtime",
                    status: runtime.status,
                    detail: runtime.detail,
                    lastEventLabel: "Last updated",
                    lastEventDate: runtime.lastUpdatedAt
                )
            ),
            LocalDaemonHealthBadgeModel(
                id: "replay",
                title: "Replay",
                value: replay.sidebarValue,
                status: replay.status,
                helpText: replayHelpText
            ),
            LocalDaemonHealthBadgeModel(
                id: "overlay",
                title: "Overlay",
                value: overlay.sidebarValue,
                status: overlay.status,
                helpText: componentHelpText(
                    title: "Overlay",
                    status: overlay.status,
                    detail: overlay.detail,
                    lastEventLabel: "Last updated",
                    lastEventDate: overlay.lastUpdatedAt
                )
            ),
            LocalDaemonHealthBadgeModel(
                id: "focus",
                title: "Focus",
                value: focus.sidebarValue,
                status: focus.status,
                helpText: focusHelpText
            ),
        ]
    }

    var accessibilitySummary: String {
        badgeModels
            .map { "\($0.title.lowercased()) \($0.status.displayName)" }
            .joined(separator: ", ")
    }

    private func componentHelpText(
        title: String,
        status: AgtmuxUIHealthStatus,
        detail: String?,
        lastEventLabel: String,
        lastEventDate: Date?
    ) -> String {
        var lines = ["\(title): \(status.displayName)"]
        if let lastEventDate {
            lines.append("\(lastEventLabel): \(lastEventDate.sidebarHealthTimestamp)")
        }
        if let detail, !detail.isEmpty {
            lines.append(detail)
        }
        lines.append("Snapshot generated: \(generatedAt.sidebarHealthTimestamp)")
        return lines.joined(separator: "\n")
    }

    var replayHelpText: String {
        var lines = ["Replay: \(replay.status.displayName)"]
        if let lag = replay.lag {
            lines.append("Lag: \(lag)")
        }
        if let currentEpoch = replay.currentEpoch {
            lines.append("Epoch: \(currentEpoch)")
        }
        if let cursorSeq = replay.cursorSeq {
            lines.append("Cursor seq: \(cursorSeq)")
        }
        if let headSeq = replay.headSeq {
            lines.append("Head seq: \(headSeq)")
        }
        if let reason = replay.lastResyncReason, !reason.isEmpty {
            lines.append("Last resync reason: \(reason)")
        }
        if let lastResyncAt = replay.lastResyncAt {
            lines.append("Last resync at: \(lastResyncAt.sidebarHealthTimestamp)")
        }
        if let detail = replay.detail, !detail.isEmpty {
            lines.append(detail)
        }
        lines.append("Snapshot generated: \(generatedAt.sidebarHealthTimestamp)")
        return lines.joined(separator: "\n")
    }

    var focusHelpText: String {
        var lines = ["Focus: \(focus.status.displayName)"]
        if let focusedPaneID = focus.focusedPaneID, !focusedPaneID.isEmpty {
            lines.append("Focused pane: \(focusedPaneID)")
        }
        if let mismatchCount = focus.mismatchCount {
            lines.append("Mismatch count: \(mismatchCount)")
        }
        if let lastSyncAt = focus.lastSyncAt {
            lines.append("Last sync at: \(lastSyncAt.sidebarHealthTimestamp)")
        }
        if let detail = focus.detail, !detail.isEmpty {
            lines.append(detail)
        }
        lines.append("Snapshot generated: \(generatedAt.sidebarHealthTimestamp)")
        return lines.joined(separator: "\n")
    }
}

private extension AgtmuxUIComponentHealth {
    var sidebarValue: String? {
        switch status {
        case .ok:
            return nil
        case .degraded:
            return "warn"
        case .unavailable:
            return "down"
        }
    }
}

private extension AgtmuxUIReplayHealth {
    var sidebarValue: String? {
        if let lag, lag > 0 {
            return "+\(lag)"
        }
        switch status {
        case .ok:
            return nil
        case .degraded:
            return "lag"
        case .unavailable:
            return "down"
        }
    }
}

private extension AgtmuxUIFocusHealth {
    var sidebarValue: String? {
        if let mismatchCount, mismatchCount > 0 {
            return "x\(mismatchCount)"
        }
        switch status {
        case .ok:
            return nil
        case .degraded:
            return "sync"
        case .unavailable:
            return "down"
        }
    }
}

private extension Date {
    var sidebarHealthTimestamp: String {
        formatted(date: .omitted, time: .standard)
    }
}

// MARK: - SidebarView

/// Scrollable pane list, grouped by source → session → window → pane.
struct SidebarView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(WorkbenchStoreV2.self) private var workbenchStoreV2
    @State private var highlightedRowID: String?
    @State private var draggedSession: DraggedSession?

    private var selectedPaneID: String? {
        workbenchStoreV2.activePaneSelection(
            panes: viewModel.panes,
            hostsConfig: viewModel.hostsConfig
        )?.paneInventoryID
    }

    var body: some View {
        VStack(spacing: 0) {
            if let issue = viewModel.localDaemonIssue,
               !viewModel.panesBySession.isEmpty {
                LocalDaemonIssueBanner(issue: issue)
            }

            if let health = viewModel.localDaemonHealth {
                LocalDaemonHealthStrip(
                    health: health,
                    topPadding: viewModel.localDaemonIssue == nil || viewModel.panesBySession.isEmpty ? 8 : 4
                )
            }

            if viewModel.panesBySession.isEmpty {
                sidebarEmptyState
            } else {
                ScrollViewReader { proxy in
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
                                        selectedPaneId: selectedPaneID,
                                        highlightedRowID: $highlightedRowID,
                                        draggedSession: $draggedSession,
                                        onSelect: { pane, _ in
                                            workbenchStoreV2.openTerminal(
                                                for: pane,
                                                hostsConfig: viewModel.hostsConfig
                                            )
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                    .onAppear {
                        scrollToSelectedPane(with: proxy, animated: false)
                    }
                    .onChange(of: selectedPaneID) { _, _ in
                        scrollToSelectedPane(with: proxy, animated: true)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.sidebar)
    }

    private func scrollToSelectedPane(with proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedPaneID else { return }
        let targetID = "pane:\(selectedPaneID)"
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            } else {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }

    private var sidebarEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No panes loaded")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.82))
            Text(emptyStateDetail)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.56))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.sidebarEmpty)
    }

    private var emptyStateDetail: String {
        if let issue = viewModel.localDaemonIssue {
            return issue.emptyStateMessage
        }
        if viewModel.offlineHosts.contains("local") {
            return "Local agtmux daemon is unavailable. Check AGTMUX_BIN or daemon startup."
        }
        return "No tracked panes are currently available."
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
