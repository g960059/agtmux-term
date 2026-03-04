import AppKit
import SwiftUI
import GhosttyKit
import AgtmuxTermCore

// MARK: - WorkspaceArea

/// Top-level workspace view: tab bar + recursive BSP layout.
struct WorkspaceArea: View {
    @Environment(WorkspaceStore.self) private var store
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            TabBarView()
            Divider()
            if let tab = store.activeTab,
               tab.root.leaves.contains(where: { !$0.tmuxPaneID.isEmpty }) {
                @Bindable var bindableStore = store
                LayoutNodeView(
                    node: tab.root,
                    focusedLeafID: $bindableStore.tabs[store.activeTabIndex].focusedLeafID,
                    hostsConfig: viewModel.hostsConfig
                )
            } else {
                emptyState
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.workspaceArea)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Select a pane from the sidebar")
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.workspaceEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - TabBarView

/// Horizontal tab strip with keyboard shortcuts.
struct TabBarView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        @Bindable var bindableStore = store

        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(store.tabs.enumerated()), id: \.element.id) { idx, tab in
                        TabButton(
                            tab: tab,
                            isActive: idx == store.activeTabIndex,
                            onSelect: { store.switchTab(to: tab.id) },
                            onClose: { store.closeTab(id: tab.id) }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            // New tab button
            Button(action: { store.createTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("New Tab")
            .accessibilityIdentifier(AccessibilityID.workspaceNewTab)
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .padding(.trailing, 4)
        }
        .accessibilityIdentifier(AccessibilityID.workspaceTabBar)
        .background(Color(NSColor.windowBackgroundColor))
        // Keyboard shortcuts: Cmd+T, Cmd+W
        .onKeyPress("t", phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            store.createTab(); return .handled
        }
        .onKeyPress("w", phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            if let tab = store.activeTab { store.closeTab(id: tab.id) }
            return .handled
        }
    }
}

/// A single tab button with close button on hover.
private struct TabButton: View {
    let tab: WorkspaceTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 120, alignment: .leading)

            if isHovered || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            } else {
                Spacer().frame(width: 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.workspaceTabPrefix + tab.id.uuidString)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}

// MARK: - LayoutNodeView

/// Recursively renders a LayoutNode as either a terminal tile or a split container.
struct LayoutNodeView: View {
    let node: LayoutNode
    @Binding var focusedLeafID: UUID?
    let hostsConfig: HostsConfig

    var body: some View {
        switch node {
        case .leaf(let pane):
            GhosttyPaneTile(
                leaf: pane,
                isFocused: focusedLeafID == pane.id,
                hostsConfig: hostsConfig
            )
            .contentShape(Rectangle())
            .onTapGesture { focusedLeafID = pane.id }
            .overlay(
                // Focus ring on focused tile
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor.opacity(focusedLeafID == pane.id ? 0.6 : 0), lineWidth: 2)
            )

        case .split(let container):
            SplitContainerView(
                container: container,
                focusedLeafID: $focusedLeafID,
                hostsConfig: hostsConfig
            )
        }
    }
}

// MARK: - SplitContainerView

/// Renders a SplitContainer with a draggable divider.
/// Uses a callback to notify the store of ratio changes.
struct SplitContainerView: View {
    let container: SplitContainer
    @Binding var focusedLeafID: UUID?
    let hostsConfig: HostsConfig

    @Environment(WorkspaceStore.self) private var store
    @State private var dragStartRatio: CGFloat?

    var body: some View {
        GeometryReader { geo in
            splitLayout(totalSize: container.axis == .horizontal ? geo.size.width : geo.size.height)
        }
        // Keyboard resize: Opt+Cmd+Arrow (5% steps)
        .onKeyPress(.leftArrow, phases: .down) { kp in
            guard kp.modifiers.contains([.option, .command]) else { return .ignored }
            return nudge(-0.05, axis: .horizontal)
        }
        .onKeyPress(.rightArrow, phases: .down) { kp in
            guard kp.modifiers.contains([.option, .command]) else { return .ignored }
            return nudge(+0.05, axis: .horizontal)
        }
        .onKeyPress(.upArrow, phases: .down) { kp in
            guard kp.modifiers.contains([.option, .command]) else { return .ignored }
            return nudge(-0.05, axis: .vertical)
        }
        .onKeyPress(.downArrow, phases: .down) { kp in
            guard kp.modifiers.contains([.option, .command]) else { return .ignored }
            return nudge(+0.05, axis: .vertical)
        }
    }

    @ViewBuilder
    private func splitLayout(totalSize: CGFloat) -> some View {
        switch container.axis {
        case .horizontal:
            HStack(spacing: 0) {
                LayoutNodeView(node: container.first,
                               focusedLeafID: $focusedLeafID,
                               hostsConfig: hostsConfig)
                    .frame(width: max(1, totalSize * container.ratio - 2))

                DividerHandle(axis: .horizontal, onDrag: { delta in
                    let startRatio = dragStartRatio ?? container.ratio
                    if dragStartRatio == nil { dragStartRatio = container.ratio }
                    var updated = container
                    updated.setRatio(startRatio + delta / max(1, totalSize))
                    store.updateContainer(id: container.id, to: updated)
                }, onDragEnd: {
                    dragStartRatio = nil
                })

                LayoutNodeView(node: container.second,
                               focusedLeafID: $focusedLeafID,
                               hostsConfig: hostsConfig)
                    .frame(width: max(1, totalSize * (1 - container.ratio) - 2))
            }

        case .vertical:
            VStack(spacing: 0) {
                LayoutNodeView(node: container.first,
                               focusedLeafID: $focusedLeafID,
                               hostsConfig: hostsConfig)
                    .frame(height: max(1, totalSize * container.ratio - 2))

                DividerHandle(axis: .vertical, onDrag: { delta in
                    let startRatio = dragStartRatio ?? container.ratio
                    if dragStartRatio == nil { dragStartRatio = container.ratio }
                    var updated = container
                    updated.setRatio(startRatio + delta / max(1, totalSize))
                    store.updateContainer(id: container.id, to: updated)
                }, onDragEnd: {
                    dragStartRatio = nil
                })

                LayoutNodeView(node: container.second,
                               focusedLeafID: $focusedLeafID,
                               hostsConfig: hostsConfig)
                    .frame(height: max(1, totalSize * (1 - container.ratio) - 2))
            }
        }
    }

    private func nudge(_ delta: CGFloat, axis: SplitAxis) -> KeyPress.Result {
        guard container.axis == axis else { return .ignored }
        var updated = container
        updated.setRatio(container.ratio + delta)
        store.updateContainer(id: container.id, to: updated)
        return .handled
    }
}

// MARK: - DividerHandle

/// Thin drag target between two layout panes.
struct DividerHandle: View {
    let axis: SplitAxis
    /// Called with the translation delta (width for horizontal, height for vertical).
    let onDrag: (CGFloat) -> Void
    /// Called when the drag ends so the caller can reset drag-start state.
    let onDragEnd: () -> Void

    @State private var isDragging = false

    private var thickness: CGFloat { 4 }

    var body: some View {
        ZStack {
            Color(NSColor.separatorColor).opacity(isDragging ? 0.8 : 0.3)
        }
        .frame(
            width:  axis == .horizontal ? thickness : nil,
            height: axis == .vertical   ? thickness : nil
        )
        .contentShape(
            Rectangle().inset(by: -(thickness + 2))  // wider hit-test area
        )
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    isDragging = true
                    let delta = axis == .horizontal ? value.translation.width : value.translation.height
                    onDrag(delta)
                }
                .onEnded { _ in
                    isDragging = false
                    onDragEnd()
                }
        )
        .onHover { hovering in
            if hovering {
                let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - GhosttyPaneTile

/// Terminal tile for a single LeafPane.
/// Shows loading/error overlays based on LinkedSessionState.
struct GhosttyPaneTile: View {
    let leaf: LeafPane
    let isFocused: Bool
    let hostsConfig: HostsConfig

    private var linkedStateLabel: String {
        switch leaf.linkedSession {
        case .creating:        return "creating"
        case .ready:           return "ready"
        case .failed(let err): return "failed: \(err)"
        }
    }

    private var attachCommand: String? {
        guard case .ready(let sessionTarget) = leaf.linkedSession else { return nil }
        // sessionTarget is either a pane ID ("%250") or a linked session name ("agtmux-uuid")
        //
        // Important: the host app may itself run inside tmux (`swift run` from a tmux pane).
        // If we inherit TMUX/TMUX_PANE into the embedded shell, `tmux attach-session` can
        // target/switch the parent client instead of creating an independent client in this pty.
        // We explicitly unset both vars for the command we launch in Ghostty.
        let base = "env -u TMUX -u TMUX_PANE tmux attach-session -t \(sessionTarget)"
        guard leaf.source != "local",
              let host = hostsConfig.host(for: leaf.source) else { return base }
        switch host.transport {
        case .ssh:  return "ssh -t \(host.sshTarget) \(base)"
        case .mosh: return "mosh \(host.sshTarget) -- \(base)"
        }
    }

    var body: some View {
        ZStack {
            // Underlying terminal view (always present but may show nothing until ready)
            _GhosttyNSView(leafID: leaf.id,
                           tmuxPaneID: leaf.tmuxPaneID,
                           attachCommand: attachCommand,
                           isFocused: isFocused)

            // State overlay
            switch leaf.linkedSession {
            case .creating:
                Color(NSColor.textBackgroundColor)
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .accessibilityIdentifier(
                        AccessibilityID.workspaceLoadingPrefix +
                        AccessibilityID.paneKey(source: leaf.source, paneID: leaf.tmuxPaneID)
                    )

            case .failed(let err):
                Color(NSColor.textBackgroundColor)
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.title2)
                    Text(err)
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }

            case .ready:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            AccessibilityID.workspaceTilePrefix +
            AccessibilityID.paneKey(source: leaf.source, paneID: leaf.tmuxPaneID)
        )
        .accessibilityValue(Text(linkedStateLabel))
    }
}

// MARK: - _GhosttyNSView (private)

/// NSViewRepresentable that hosts a single GhosttyTerminalView.
///
/// - Creates / recreates the surface whenever `attachCommand` changes.
/// - Registers new surfaces with SurfacePool for lifecycle management.
/// - Occlusion is delegated to SurfacePool (ghostty_surface_set_occlusion).
/// - dismantleNSView schedules a 5-second grace-period GC via SurfacePool.
private struct _GhosttyNSView: NSViewRepresentable {
    let leafID: UUID
    let tmuxPaneID: String
    let attachCommand: String?
    let isFocused: Bool

    func makeNSView(context: Context) -> GhosttyTerminalView {
        let view = GhosttyTerminalView()
        context.coordinator.leafID = leafID
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        let cmd = attachCommand
        let commandChanged = context.coordinator.currentCommand != cmd

        // Only recreate surface when the command changes.
        if commandChanged {
            // Reset lastAppliedFocus so occlusion is re-applied after surface recreate.
            context.coordinator.lastAppliedFocus = nil
            if let cmd {
                // ghostty_surface_new requires the view to be in a window hierarchy.
                // If window is nil, defer by NOT updating currentCommand — SwiftUI
                // will call updateNSView again after the next layout pass.
                guard nsView.window != nil else { return }
                context.coordinator.currentCommand = cmd
                print("[updateNSView] Creating surface for leaf \(leafID) cmd=\(cmd)")
                if let surface = GhosttyApp.shared.newSurface(for: nsView, command: cmd) {
                    nsView.attachSurface(surface)
                    SurfacePool.shared.register(view: nsView,
                                                leafID: leafID,
                                                tmuxPaneID: tmuxPaneID)
                    print("[updateNSView] Surface created: true")
                } else {
                    print("[updateNSView] Surface created: false")
                }
            } else {
                context.coordinator.currentCommand = nil
            }
        }

        // Only delegate occlusion to SurfacePool when isFocused actually changes.
        // Calling activate/background unconditionally every render mutates @Observable
        // SurfacePool.pool, which triggers a SwiftUI re-render → infinite loop.
        guard context.coordinator.lastAppliedFocus != isFocused else { return }
        context.coordinator.lastAppliedFocus = isFocused
        if isFocused {
            SurfacePool.shared.activate(leafID: leafID)
            nsView.window?.makeFirstResponder(nsView)
        } else {
            SurfacePool.shared.background(leafID: leafID)
        }
    }

    static func dismantleNSView(_ nsView: GhosttyTerminalView, coordinator: Coordinator) {
        // Start 5-second grace period. SurfacePool keeps a strong reference
        // to nsView so ARC doesn't free it (and the surface) prematurely.
        if let leafID = coordinator.leafID {
            Task { @MainActor in
                SurfacePool.shared.release(leafID: leafID)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var currentCommand: String?
        var leafID: UUID?
        /// Tracks the last occlusion state applied to SurfacePool.
        /// nil = not yet applied (forces first application).
        var lastAppliedFocus: Bool? = nil
    }
}
