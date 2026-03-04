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
        let leaves = root.leaves.filter { !$0.tmuxPaneID.isEmpty }
        switch leaves.count {
        case 0:
            return "Empty"
        case 1:
            return leaves[0].sessionName
        default:
            let sessions = Set(leaves.map(\.sessionName))
            if sessions.count == 1, let only = sessions.first {
                return only
            }
            return "Mixed (\(leaves.count))"
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
        stopLayoutMonitoring(tabID: id)
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
        let tabID = tabs[idx].id

        // Pane-only placement does not track tmux layout events.
        // Stop any existing window monitor for this tab to avoid stale updates.
        stopLayoutMonitoring(tabID: tabID)

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
                self?.updateLeaf(id: leafID, linkedSession: .ready(linkedName))
            } catch {
                print("[placePane] Linked session FAILED: \(error)")
                self?.updateLeaf(id: leafID,
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
        var monitorSessionName: String
    }

    /// Windows currently displayed in workspace tabs (tabID → metadata).
    private var trackedWindowsByTab: [UUID: TrackedWindow] = [:]

    /// Long-running tasks that subscribe to TmuxControlMode events (tabID → task).
    private var layoutMonitorTasksByTab: [UUID: Task<Void, Never>] = [:]
    /// Placement generation per tab (stale async completions are ignored).
    private var placementGenerationByTab: [UUID: Int] = [:]

    /// Place an entire tmux window into the active tab.
    ///
    /// Root policy (T-066 rework):
    /// - one workspace tile == one tmux window surface
    /// - tmux's native pane layout is rendered inside that single surface
    ///
    /// This avoids duplicated/fragmented rendering caused by creating one
    /// Ghostty surface per tmux pane.
    func placeWindow(_ window: WindowGroup, preferredPaneID: String? = nil) async {
        if tabs.isEmpty { createTab() }
        let idx = activeTabIndex
        guard tabs.indices.contains(idx) else { return }
        let tabID = tabs[idx].id

        let targetPane = window.panes.first(where: { $0.paneId == preferredPaneID })
            ?? window.panes.first
        guard let targetPane else { return }

        // Replace any existing monitor/tree in this tab before opening the new window.
        stopLayoutMonitoring(tabID: tabID)
        let generation = (placementGenerationByTab[tabID] ?? 0) + 1
        placementGenerationByTab[tabID] = generation

        // Single leaf per window. tmux draws its own pane layout internally.
        let leaf = LeafPane(
            tmuxPaneID: targetPane.paneId,
            sessionName: window.sessionName,
            source: window.source,
            linkedSession: .creating
        )
        tabs[idx].root = .leaf(leaf)
        tabs[idx].focusedLeafID = leaf.id

        let leafID = leaf.id
        Task { [weak self] in
            do {
                let linkedName = try await LinkedSessionManager.shared.createSession(
                    parentSession: window.sessionName,
                    windowId:      window.windowId,
                    paneId:        targetPane.paneId,
                    source:        window.source
                )
                await self?.handleLinkedSessionReady(
                    tabID: tabID,
                    generation: generation,
                    leafID: leafID,
                    window: window,
                    linkedSessionName: linkedName
                )
            } catch {
                self?.handleLinkedSessionFailed(
                    tabID: tabID,
                    generation: generation,
                    leafID: leafID,
                    message: error.localizedDescription
                )
            }
        }

        trackedWindowsByTab[tabID] = TrackedWindow(
            sessionName: window.sessionName,
            windowId:    window.windowId,
            source:      window.source,
            panes:       window.panes,
            monitorSessionName: window.sessionName
        )
    }

    /// Update the pane list stored for a tracked window (called by AppViewModel on poll).
    func updateTrackedWindowPanes(windowId: String, panes: [AgtmuxPane]) {
        for (tabID, tracked) in trackedWindowsByTab where tracked.windowId == windowId {
            trackedWindowsByTab[tabID]?.panes = panes
        }
    }

    // MARK: - Layout monitoring (Mode B)

    private func startLayoutMonitoring(tabID: UUID) {
        guard let tracked = trackedWindowsByTab[tabID] else { return }
        let source = tracked.source
        let monitorSessionName = tracked.monitorSessionName

        layoutMonitorTasksByTab[tabID]?.cancel()
        let task = Task { [weak self] in
            var lastPaneID: String?
            while !Task.isCancelled {
                do {
                    let paneID = try await self?.fetchActivePaneID(
                        sessionName: monitorSessionName,
                        source: source
                    )
                    if let paneID, paneID != lastPaneID {
                        lastPaneID = paneID
                        self?.handleWindowPaneChanged(
                            paneId: paneID,
                            tabID: tabID
                        )
                    }
                } catch {
                    // best-effort polling; continue on transient failures
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        layoutMonitorTasksByTab[tabID] = task
    }

    /// Stop monitoring layout changes for a specific workspace tab.
    func stopLayoutMonitoring(tabID: UUID) {
        layoutMonitorTasksByTab[tabID]?.cancel()
        layoutMonitorTasksByTab.removeValue(forKey: tabID)
        trackedWindowsByTab.removeValue(forKey: tabID)
        placementGenerationByTab.removeValue(forKey: tabID)
    }

    /// Stop monitoring a window's layout changes.
    func stopLayoutMonitoring(windowId: String) {
        let tabIDs = trackedWindowsByTab.compactMap { (tabID, tracked) in
            tracked.windowId == windowId ? tabID : nil
        }
        for tabID in tabIDs {
            stopLayoutMonitoring(tabID: tabID)
        }
    }

    /// Sync focused leaf when tmux reports `%window-pane-changed`.
    ///
    /// This keeps workspace focus aligned with interactive pane changes that happen
    /// inside Ghostty/tmux (keyboard or mouse), not only sidebar taps.
    private func handleWindowPaneChanged(paneId: String, tabID: UUID) {
        guard let tabIdx = tabs.firstIndex(where: { $0.id == tabID }),
              let tracked = trackedWindowsByTab[tabID] else { return }

        guard let focusedID = tabs[tabIdx].focusedLeafID,
              let currentLeaf = findLeaf(id: focusedID, in: tabs[tabIdx].root) else { return }
        guard case .ready = currentLeaf.linkedSession else { return }

        let resolvedSessionName = tracked.panes.first(where: { $0.paneId == paneId })?.sessionName
            ?? currentLeaf.sessionName

        let updatedLeaf = LeafPane(
            id: focusedID,
            tmuxPaneID: paneId,
            sessionName: resolvedSessionName,
            source: currentLeaf.source,
            linkedSession: currentLeaf.linkedSession
        )
        if let newRoot = tabs[tabIdx].root.replacing(leafID: focusedID, with: .leaf(updatedLeaf)) {
            tabs[tabIdx].root = newRoot
        }
        tabs[tabIdx].focusedLeafID = focusedID
    }

    private func handleLinkedSessionReady(
        tabID: UUID,
        generation: Int,
        leafID: UUID,
        window: WindowGroup,
        linkedSessionName: String
    ) async {
        guard placementGenerationByTab[tabID] == generation else {
            await LinkedSessionManager.shared.destroySession(name: linkedSessionName, source: window.source)
            return
        }

        updateLeaf(id: leafID, linkedSession: .ready(linkedSessionName))
        if var tracked = trackedWindowsByTab[tabID], tracked.windowId == window.windowId {
            tracked.monitorSessionName = linkedSessionName
            trackedWindowsByTab[tabID] = tracked
            startLayoutMonitoring(tabID: tabID)
        }
    }

    private func handleLinkedSessionFailed(
        tabID: UUID,
        generation: Int,
        leafID: UUID,
        message: String
    ) {
        guard placementGenerationByTab[tabID] == generation else { return }
        updateLeaf(id: leafID, linkedSession: .failed(message))
    }

    private func fetchActivePaneID(sessionName: String, source: String) async throws -> String {
        let displayOutput = try await TmuxCommandRunner.shared.run(
            ["display-message", "-p", "-t", sessionName, "#{pane_id}"],
            source: source
        )
        let paneID = displayOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if paneID.hasPrefix("%") { return paneID }

        // Fallback for environments where `display-message -p "#{pane_id}"` is empty.
        let fallbackOutput = try await TmuxCommandRunner.shared.run(
            ["list-panes", "-t", sessionName, "-F", "#{?pane_active,1,0}\t#{pane_id}"],
            source: source
        )
        for line in fallbackOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            if parts[0] == "1" {
                return String(parts[1])
            }
        }

        throw TmuxCommandError.failed(
            args: ["display-message", "-p", "-t", sessionName, "#{pane_id}"],
            code: -1,
            stderr: "active pane not found"
        )
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
