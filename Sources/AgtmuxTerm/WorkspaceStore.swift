import Foundation
import Observation
import AgtmuxTermCore

// MARK: - WorkspaceTab

/// A single workspace tab containing a BSP layout tree.
struct WorkspaceTab: Identifiable {
    let id: UUID
    /// User-defined title. nil = auto-derived from pane context.
    var title: String?
    var root: LayoutNode
    /// The leaf ID that has keyboard focus.
    var focusedLeafID: UUID?

    /// Displayed title: user-set title, otherwise derived from the layout.
    var displayTitle: String {
        if let t = title { return t }
        let leaves = root.leaves
        switch leaves.count {
        case 0:   return "Empty"
        case 1:   return leaves[0].sessionName
        default:  return "Mixed (\(leaves.count))"
        }
    }

    init(id: UUID = UUID(), title: String? = nil, root: LayoutNode, focusedLeafID: UUID? = nil) {
        self.id            = id
        self.title         = title
        self.root          = root
        self.focusedLeafID = focusedLeafID
    }
}

// MARK: - WorkspaceStore

/// Central store for the workspace layout (tabs + BSP trees).
///
/// Uses Swift Observation (`@Observable`) — requires macOS 14+.
///
/// Design notes:
/// - `tabs` is the single source of truth for layout state.
/// - To get a Binding<SplitContainer> for a drag handle:
///     `$workspaceStore.tabs[workspaceStore.activeTabIndex]...`
///   Use `updateContainer(id:to:)` when direct index access is impractical.
/// - `placePane()` is async so LinkedSessionManager (T-037) can be awaited inside.
@Observable
@MainActor
final class WorkspaceStore {
    var tabs: [WorkspaceTab] = []
    var activeTabIndex: Int = 0

    /// Convenience read-only accessor for the currently active tab.
    var activeTab: WorkspaceTab? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex]
    }

    // MARK: - Tab management

    /// Create a new empty tab and make it active. Returns the created tab.
    @discardableResult
    func createTab(title: String? = nil) -> WorkspaceTab {
        let leaf = LeafPane(tmuxPaneID: "", sessionName: "new", source: "local",
                            linkedSession: .creating)
        let tab = WorkspaceTab(title: title, root: .leaf(leaf), focusedLeafID: leaf.id)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        return tab
    }

    /// Close the tab with the given ID. Switches to an adjacent tab if needed.
    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if tabs.isEmpty {
            // Always keep at least one tab
            createTab()
        } else {
            activeTabIndex = max(0, min(activeTabIndex, tabs.count - 1))
        }
    }

    /// Switch to the tab with the given ID.
    func switchTab(to id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        activeTabIndex = idx
    }

    // MARK: - Pane placement

    /// Place an AgtmuxPane into the active tab.
    ///
    /// Flow (T-037 — LinkedSessionManager integrated):
    ///   1. Create a LeafPane with `.creating` state and insert into layout.
    ///   2. Spin up a detached Task to call LinkedSessionManager.createSession().
    ///   3. On success, transition leaf to `.ready(linkedSessionName)`.
    ///   4. On failure, transition leaf to `.failed(errorDescription)`.
    ///
    /// The GhosttyPaneTile shows a spinner while `.creating`, then attaches
    /// the surface when `.ready`. The linked session gives each tile its own
    /// independent tmux client (Spike B confirmed this works).
    ///
    /// If no tabs exist, creates one first.
    /// Returns the UUID of the newly created leaf.
    @discardableResult
    func placePane(_ pane: AgtmuxPane,
                   axis: SplitAxis = .horizontal) async -> UUID {
        if tabs.isEmpty { createTab() }

        let newLeaf = LeafPane(
            tmuxPaneID:  pane.paneId,
            sessionName: pane.sessionName,
            source:      pane.source,
            linkedSession: .creating
        )

        let idx = activeTabIndex
        guard tabs.indices.contains(idx) else { return newLeaf.id }

        // Always replace the focused leaf in-place (not split).
        // "Click pane in sidebar" = navigate to that pane in the current tile,
        // not add a new split column.
        if let focusedID = tabs[idx].focusedLeafID,
           let updated = tabs[idx].root.replacing(leafID: focusedID, with: .leaf(newLeaf)) {
            tabs[idx].root = updated
        } else {
            // No focused leaf found (e.g. empty tab): replace root.
            tabs[idx].root = .leaf(newLeaf)
        }

        tabs[idx].focusedLeafID = newLeaf.id

        // Capture values for the async task before returning.
        let leafID      = newLeaf.id
        let sessionName = pane.sessionName
        let windowId    = pane.windowId
        let paneId      = pane.paneId
        let source      = pane.source

        print("[placePane] Creating linked session for pane \(pane.paneId) session=\(sessionName) window=\(windowId)")

        // Create linked session asynchronously so UI isn't blocked.
        // The leaf stays in .creating (shows spinner) until this resolves.
        Task { [weak self] in
            print("[placePane] Task started: calling LinkedSessionManager.createSession()")
            do {
                let linkedName = try await LinkedSessionManager.shared.createSession(
                    parentSession: sessionName,
                    windowId:      windowId,
                    paneId:        paneId,
                    source:        source
                )
                print("[placePane] Linked session created: \(linkedName) → updating leaf \(leafID)")
                await self?.updateLeaf(id: leafID, linkedSession: .ready(linkedName))
            } catch {
                print("[placePane] Linked session FAILED: \(error)")
                await self?.updateLeaf(id: leafID,
                                       linkedSession: .failed(error.localizedDescription))
            }
        }

        return newLeaf.id
    }

    // MARK: - Container update (for SplitContainerView drag)

    /// Update a SplitContainer in-place by ID.
    ///
    /// Used by SplitContainerView when LayoutNode enum prevents direct @Binding extraction.
    /// Example:
    ///   DividerHandle drag → store.updateContainer(id: c.id, to: newContainer)
    func updateContainer(id: UUID, to newContainer: SplitContainer) {
        guard tabs.indices.contains(activeTabIndex) else { return }
        let replacement: LayoutNode = .split(newContainer)
        if let updated = tabs[activeTabIndex].root.replacing(leafID: id, with: replacement) {
            tabs[activeTabIndex].root = updated
        } else {
            // id is a split node, not a leaf — walk and replace
            tabs[activeTabIndex].root = _replaceSplitNode(
                in: tabs[activeTabIndex].root, id: id, with: newContainer)
        }
    }

    // MARK: - Leaf update (for LinkedSessionState transitions)

    /// Update a LeafPane's linkedSession state.
    /// Called by LinkedSessionManager (T-037) when session creation completes.
    func updateLeaf(id: UUID, linkedSession: LinkedSessionState) {
        for tabIdx in tabs.indices {
            if let leaf = findLeaf(id: id, in: tabs[tabIdx].root) {
                var updated = leaf
                updated.linkedSession = linkedSession
                if let newRoot = tabs[tabIdx].root.replacing(leafID: id, with: .leaf(updated)) {
                    tabs[tabIdx].root = newRoot
                    return
                }
            }
        }
    }

    // MARK: - Window placement (Mode B)

    /// Metadata stored per tracked window for layout-change re-conversion.
    private struct TrackedWindow {
        let sessionName: String
        let windowId: String
        let source: String
        var panes: [AgtmuxPane]
    }

    /// Windows currently displayed in workspace tabs (windowId → metadata).
    private var trackedWindows: [String: TrackedWindow] = [:]

    /// Long-running tasks that subscribe to TmuxControlMode layout-change events.
    private var layoutMonitorTasks: [String: Task<Void, Never>] = [:]

    /// Place an entire tmux window into the active tab as a BSP layout.
    ///
    /// Flow:
    ///   1. Fetch `#{window_layout}` from tmux.
    ///   2. Parse into `LayoutNode` BSP via `TmuxLayoutConverter`.
    ///   3. Replace the active tab's root with the new BSP.
    ///   4. Create linked sessions asynchronously for each leaf.
    ///   5. Subscribe to `%layout-change` events to keep the BSP in sync.
    ///
    /// On any error, falls back to placing the window's first pane (Mode A).
    func placeWindow(_ window: WindowGroup) async {
        if tabs.isEmpty { createTab() }
        let idx = activeTabIndex
        guard tabs.indices.contains(idx) else { return }

        do {
            // 1. Fetch layout string from tmux.
            let target = "\(window.sessionName):\(window.windowId)"
            let layoutString = try await TmuxCommandRunner.shared.run(
                ["display-message", "-p", "-t", target, "#{window_layout}"],
                source: window.source
            )

            // 2. Convert to BSP.
            guard let bspRoot = TmuxLayoutConverter.convert(
                layoutString: layoutString,
                windowPanes:  window.panes,
                source:       window.source
            ) else {
                fallbackToFirstPane(window: window, idx: idx)
                return
            }

            // 3. Set as tab root and focus the first leaf.
            tabs[idx].root = bspRoot
            tabs[idx].focusedLeafID = bspRoot.leafIDs.first

            // 4. Create a linked session for each leaf asynchronously.
            for leaf in bspRoot.leaves {
                let leafID      = leaf.id
                let sessionName = leaf.sessionName
                let source      = leaf.source
                let windowId    = window.windowId
                let paneId      = leaf.tmuxPaneID
                Task { [weak self] in
                    do {
                        let name = try await LinkedSessionManager.shared.createSession(
                            parentSession: sessionName,
                            windowId:      windowId,
                            paneId:        paneId,
                            source:        source
                        )
                        await self?.updateLeaf(id: leafID, linkedSession: .ready(name))
                    } catch {
                        await self?.updateLeaf(id: leafID, linkedSession: .failed(error.localizedDescription))
                    }
                }
            }

            // 5. Track and subscribe to layout-change events.
            trackedWindows[window.windowId] = TrackedWindow(
                sessionName: window.sessionName,
                windowId:    window.windowId,
                source:      window.source,
                panes:       window.panes
            )
            startLayoutMonitoring(for: window, tabID: tabs[idx].id)

        } catch {
            fallbackToFirstPane(window: window, idx: idx)
        }
    }

    /// Update the pane list stored for a tracked window (called by AppViewModel on poll).
    func updateTrackedWindowPanes(windowId: String, panes: [AgtmuxPane]) {
        trackedWindows[windowId]?.panes = panes
    }

    // MARK: - Layout monitoring (Mode B)

    private func startLayoutMonitoring(for window: WindowGroup, tabID: UUID) {
        let windowId    = window.windowId
        let sessionName = window.sessionName
        let source      = window.source

        layoutMonitorTasks[windowId]?.cancel()
        TmuxControlModeRegistry.shared.startMonitoring(sessionName: sessionName, source: source)

        // Capture the TmuxControlMode actor reference before entering the Task.
        let mode = TmuxControlModeRegistry.shared.mode(for: sessionName, source: source)

        let task = Task { [weak self] in
            for await event in await mode.events {
                guard !Task.isCancelled else { break }
                if case .layoutChange(let wid, let layout, _) = event, wid == windowId {
                    await self?.handleLayoutChange(layout: layout,
                                                   windowId: windowId,
                                                   tabID: tabID)
                }
            }
        }
        layoutMonitorTasks[windowId] = task
    }

    /// Stop monitoring a window's layout changes.
    func stopLayoutMonitoring(windowId: String) {
        layoutMonitorTasks[windowId]?.cancel()
        layoutMonitorTasks.removeValue(forKey: windowId)
        trackedWindows.removeValue(forKey: windowId)
    }

    private func handleLayoutChange(layout: String, windowId: String, tabID: UUID) async {
        // Resolve tabID → tabIdx at the point of use to avoid stale index captures.
        guard let tabIdx = tabs.firstIndex(where: { $0.id == tabID }),
              let tracked = trackedWindows[windowId] else { return }

        guard let newRoot = TmuxLayoutConverter.convert(
            layoutString: layout,
            windowPanes:  tracked.panes,
            source:       tracked.source
        ) else { return }

        // Merge: preserve leaf IDs + linked-session state where pane IDs match.
        let oldLeaves  = tabs[tabIdx].root.leaves
        let mergedRoot = mergeLayout(newRoot: newRoot, oldLeaves: oldLeaves)
        tabs[tabIdx].root = mergedRoot

        // Keep focused leaf valid.
        if let focusedID = tabs[tabIdx].focusedLeafID,
           !mergedRoot.leafIDs.contains(focusedID) {
            tabs[tabIdx].focusedLeafID = mergedRoot.leafIDs.first
        }

        // Create linked sessions for new leaves (those that are still .creating).
        for leaf in mergedRoot.leaves {
            if case .creating = leaf.linkedSession {
                let leafID      = leaf.id
                let sessionName = leaf.sessionName
                let source      = leaf.source
                let paneId      = leaf.tmuxPaneID
                Task { [weak self] in
                    do {
                        let name = try await LinkedSessionManager.shared.createSession(
                            parentSession: sessionName,
                            windowId:      windowId,
                            paneId:        paneId,
                            source:        source
                        )
                        await self?.updateLeaf(id: leafID, linkedSession: .ready(name))
                    } catch {
                        await self?.updateLeaf(id: leafID, linkedSession: .failed(error.localizedDescription))
                    }
                }
            }
        }
    }

    /// Merge a freshly-converted BSP with the existing leaves.
    ///
    /// For leaves whose `tmuxPaneID` already exists in `oldLeaves`, the old leaf's
    /// `id` and `linkedSession` state are preserved so the Ghostty surface is not
    /// needlessly recreated.  Leaves with unknown pane IDs start as `.creating`.
    private func mergeLayout(newRoot: LayoutNode, oldLeaves: [LeafPane]) -> LayoutNode {
        var oldByPaneID: [String: LeafPane] = [:]
        for leaf in oldLeaves { oldByPaneID[leaf.tmuxPaneID] = leaf }

        func merge(_ node: LayoutNode) -> LayoutNode {
            switch node {
            case .leaf(let leaf):
                if let existing = oldByPaneID[leaf.tmuxPaneID] {
                    return .leaf(LeafPane(id:            existing.id,
                                         tmuxPaneID:    leaf.tmuxPaneID,
                                         sessionName:   leaf.sessionName,
                                         source:        leaf.source,
                                         linkedSession: existing.linkedSession))
                }
                return node   // new pane → starts .creating

            case .split(var c):
                c.first  = merge(c.first)
                c.second = merge(c.second)
                return .split(c)
            }
        }

        return merge(newRoot)
    }

    // MARK: - Private helpers

    private func fallbackToFirstPane(window: WindowGroup, idx: Int) {
        guard let pane = window.panes.first else { return }
        Task { [weak self] in
            _ = await self?.placePane(pane)
        }
    }

    // MARK: - Leaf removal

    /// Remove the leaf with the given ID from the active tab's layout.
    func removeLeaf(id: UUID) {
        guard tabs.indices.contains(activeTabIndex) else { return }
        if let newRoot = tabs[activeTabIndex].root.removingLeaf(id: id) {
            tabs[activeTabIndex].root = newRoot
            // If the removed leaf was focused, move focus to first remaining leaf
            if tabs[activeTabIndex].focusedLeafID == id {
                tabs[activeTabIndex].focusedLeafID = tabs[activeTabIndex].root.leafIDs.first
            }
        } else {
            // Was the only leaf — reset to empty placeholder
            let placeholder = LeafPane(tmuxPaneID: "", sessionName: "new",
                                       source: "local", linkedSession: .creating)
            tabs[activeTabIndex].root = .leaf(placeholder)
            tabs[activeTabIndex].focusedLeafID = placeholder.id
        }
    }

    // MARK: - Private helpers

    private func _replaceSplitNode(in node: LayoutNode,
                                   id: UUID,
                                   with container: SplitContainer) -> LayoutNode {
        switch node {
        case .leaf:
            return node
        case .split(var c):
            if c.id == id { return .split(container) }
            c.first  = _replaceSplitNode(in: c.first, id: id, with: container)
            c.second = _replaceSplitNode(in: c.second, id: id, with: container)
            return .split(c)
        }
    }

    private func findLeaf(id: UUID, in node: LayoutNode) -> LeafPane? {
        switch node {
        case .leaf(let p):
            return p.id == id ? p : nil
        case .split(let c):
            return findLeaf(id: id, in: c.first) ?? findLeaf(id: id, in: c.second)
        }
    }
}
