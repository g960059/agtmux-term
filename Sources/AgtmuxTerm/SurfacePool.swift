import Foundation
import AppKit
import GhosttyKit
import os

// MARK: - SurfacePool

/// Manages the lifecycle of Ghostty terminal surfaces.
///
/// State transitions:
///   active → backgrounded → pendingGC (5 s grace) → defunct
///
/// Dual index enables event-based lookup:
///   - pane ID ("%250")        → leafIDsByPaneID     [for %pane-exited events]
///
/// GC is timer-driven. The timer runs only while pendingGC entries exist.
/// Tab switches do NOT call gc() directly.
@Observable
@MainActor
final class SurfacePool {
    static let shared = SurfacePool()
    private static let debugLogger = Logger(
        subsystem: "local.agtmux.term",
        category: "SurfacePoolDebug"
    )

    enum SurfaceState: Equatable {
        case active
        case backgrounded
        case pendingGC
        case defunct
    }

    struct ManagedSurface {
        let leafID: UUID
        let surfaceHandle: GhosttySurfaceHandle
        /// The tmux pane ID (e.g. "%250"). Used for markDefunct(byPaneID:).
        let tmuxPaneID: String
        /// Strong reference prevents ARC dealloc during pendingGC grace period.
        let view: GhosttyTerminalView
        var state: SurfaceState
        /// Non-nil when state == .pendingGC.
        var pendingGCDeadline: Date?
    }

    // MARK: - Indexes

    private var pool: [UUID: ManagedSurface] = [:]
    private var leafIDsByPaneID: [String: Set<UUID>] = [:]
    private var leafIDsBySurfaceHandle: [GhosttySurfaceHandle: UUID] = [:]
    private var leafIDsByViewID: [ObjectIdentifier: UUID] = [:]

    // MARK: - Active surface set (maintained incrementally)

    /// ObjectIdentifiers of views currently in the `.active` state.
    /// Maintained incrementally rather than recomputed on every tick().
    private(set) var activeSurfaceViewIDs: Set<ObjectIdentifier> = []
    private(set) var dirtySurfaceViewIDs: Set<ObjectIdentifier> = []

    // MARK: - GC timer

    private var gcTimer: Timer?
    private let debugCountsEnabled = ProcessInfo.processInfo.environment["AGTMUX_SURFACEPOOL_DEBUG_COUNTS"] == "1"
    private var lastDebugLogAt = Date.distantPast
    private var lastRecordedDirtyCount = 0

    private init() {}

    // MARK: - Registration

    /// Register a newly created surface.
    /// Safe to call multiple times for the same leafID (re-attach replaces the entry).
    func register(view: GhosttyTerminalView,
                  leafID: UUID,
                  tmuxPaneID: String,
                  surfaceHandle: GhosttySurfaceHandle) {
        deregisterInternal(leafID: leafID)

        let managed = ManagedSurface(
            leafID: leafID,
            surfaceHandle: surfaceHandle,
            tmuxPaneID: tmuxPaneID,
            view: view,
            state: .active
        )
        pool[leafID] = managed
        leafIDsByPaneID[tmuxPaneID, default: []].insert(leafID)
        leafIDsBySurfaceHandle[surfaceHandle] = leafID
        let viewID = ObjectIdentifier(view)
        leafIDsByViewID[viewID] = leafID
        activeSurfaceViewIDs.insert(viewID)
        dirtySurfaceViewIDs.insert(viewID)
        scheduleTickIfDrawable(view: view)
        debugLogCounts(reason: "register")
    }

    // MARK: - Occlusion

    /// Mark leaf as active (visible). Sets ghostty occlusion = visible.
    /// Idempotent: no-op if already active (avoids @Observable pool mutation → re-render loop).
    func activate(leafID: UUID) {
        guard let managed = pool[leafID],
              managed.state != .pendingGC,
              managed.state != .defunct,
              managed.state != .active else { return }
        pool[leafID]?.state = .active
        activeSurfaceViewIDs.insert(ObjectIdentifier(managed.view))
        if let surface = managed.view.surface {
            ghostty_surface_set_occlusion(surface, true)
        }
        scheduleTickIfDrawable(view: managed.view)
        debugLogCounts(reason: "activate")
    }

    /// Mark leaf as backgrounded. Sets ghostty occlusion = occluded (stops Metal render).
    /// Idempotent: no-op if already backgrounded.
    func background(leafID: UUID) {
        guard let managed = pool[leafID],
              managed.state == .active else { return }
        pool[leafID]?.state = .backgrounded
        activeSurfaceViewIDs.remove(ObjectIdentifier(managed.view))
        if let surface = managed.view.surface {
            ghostty_surface_set_occlusion(surface, false)
        }
        debugLogCounts(reason: "background")
    }

    // MARK: - GC scheduling

    /// Begin 5-second grace period before freeing the surface.
    /// Called when a leaf is removed from the layout.
    func scheduleGC(leafID: UUID) {
        guard var managed = pool[leafID],
              managed.state != .pendingGC,
              managed.state != .defunct else { return }
        // Remove from active set before transitioning away from .active
        if managed.state == .active {
            activeSurfaceViewIDs.remove(ObjectIdentifier(managed.view))
        }
        managed.state = .pendingGC
        managed.pendingGCDeadline = Date().addingTimeInterval(5)
        pool[leafID] = managed
        startGCTimerIfNeeded()
        debugLogCounts(reason: "scheduleGC")
    }

    /// Schedule GC for all leaves attached to a given tmux pane ID.
    /// Called when a %pane-exited event is received (T-039).
    func markDefunct(byPaneID paneID: String) {
        for leafID in leafIDsByPaneID[paneID] ?? [] {
            scheduleGC(leafID: leafID)
        }
    }

    /// Called by _GhosttyNSView.dismantleNSView to start the grace period.
    func release(leafID: UUID, expectedViewID: ObjectIdentifier? = nil) {
        // If there is no pool entry (view never got a surface), just return.
        guard let managed = pool[leafID] else { return }
        if let expectedViewID,
           ObjectIdentifier(managed.view) != expectedViewID {
            return
        }
        scheduleGC(leafID: leafID)
    }

    // MARK: - GC execution

    func gc() {
        let now = Date()
        let expired = pool.filter { _, m in
            m.state == .pendingGC && (m.pendingGCDeadline ?? now) <= now
        }
        for (leafID, managed) in expired {
            // Free the surface via clearSurface() — sets view.surface = nil before
            // releasing the strong reference so deinit won't double-free.
            managed.view.clearSurface()
            deregisterInternal(leafID: leafID)
        }

        if !pool.values.contains(where: { $0.state == .pendingGC }) {
            gcTimer?.invalidate()
            gcTimer = nil
        }

        if !expired.isEmpty {
            debugLogCounts(reason: "gc")
        }
    }

    /// Logs active/background/pending counts plus the latest draw-pass count under a
    /// feature flag. Today `dirtyCount` is the current draw-pass count; future dirty-only
    /// draw work can start passing the true dirty-surface count through the same seam.
    func recordDrawPassCount(_ dirtyCount: Int) {
        lastRecordedDirtyCount = dirtyCount
        debugLogCounts(reason: "tick", throttle: true)
    }

    /// Marks the surface targeted by a Ghostty render action as needing a host draw pass.
    /// Backgrounded surfaces retain their dirty bit until they become active again.
    func markDirty(surfaceHandle: GhosttySurfaceHandle) {
        guard let leafID = leafIDsBySurfaceHandle[surfaceHandle],
              let managed = pool[leafID],
              managed.state != .pendingGC,
              managed.state != .defunct else { return }
        markDirty(viewID: ObjectIdentifier(managed.view), view: managed.view)
    }

    func markDirty(view: GhosttyTerminalView) {
        guard let leafID = leafIDsByViewID[ObjectIdentifier(view)],
              let managed = pool[leafID],
              managed.state != .pendingGC,
              managed.state != .defunct else { return }
        markDirty(viewID: ObjectIdentifier(managed.view), view: managed.view)
    }

    private func markDirty(viewID: ObjectIdentifier, view: GhosttyTerminalView) {
        let inserted = dirtySurfaceViewIDs.insert(viewID).inserted
        if inserted {
            scheduleTickIfDrawable(view: view)
        }
    }

    /// Returns and clears the dirty subset that is currently drawable.
    /// Backgrounded dirty surfaces remain queued until a later activation.
    func consumeDirtyActiveSurfaceViewIDs() -> Set<ObjectIdentifier> {
        let drawable = dirtySurfaceViewIDs.intersection(activeSurfaceViewIDs)
        dirtySurfaceViewIDs.subtract(drawable)
        return drawable
    }

    func consumeDirtyActiveSurfaceViews() -> [GhosttyTerminalView] {
        let drawableViewIDs = consumeDirtyActiveSurfaceViewIDs()
        guard drawableViewIDs.isEmpty == false else { return [] }
        return pool.values.compactMap { managed in
            let viewID = ObjectIdentifier(managed.view)
            guard drawableViewIDs.contains(viewID) else { return nil }
            return managed.view
        }
    }

    func resetForTesting() {
        gcTimer?.invalidate()
        gcTimer = nil
        pool.removeAll()
        leafIDsByPaneID.removeAll()
        leafIDsBySurfaceHandle.removeAll()
        leafIDsByViewID.removeAll()
        activeSurfaceViewIDs.removeAll()
        dirtySurfaceViewIDs.removeAll()
        lastDebugLogAt = .distantPast
        lastRecordedDirtyCount = 0
    }

    // MARK: - Helpers

    private func startGCTimerIfNeeded() {
        guard gcTimer == nil else { return }
        gcTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.gc() }
        }
    }

    private func deregisterInternal(leafID: UUID) {
        guard let managed = pool[leafID] else { return }
        // Remove from active set if this entry was active
        if managed.state == .active {
            activeSurfaceViewIDs.remove(ObjectIdentifier(managed.view))
        }
        dirtySurfaceViewIDs.remove(ObjectIdentifier(managed.view))
        leafIDsByPaneID[managed.tmuxPaneID]?.remove(leafID)
        if leafIDsByPaneID[managed.tmuxPaneID]?.isEmpty == true {
            leafIDsByPaneID.removeValue(forKey: managed.tmuxPaneID)
        }
        leafIDsBySurfaceHandle.removeValue(forKey: managed.surfaceHandle)
        leafIDsByViewID.removeValue(forKey: ObjectIdentifier(managed.view))
        pool.removeValue(forKey: leafID)
        debugLogCounts(reason: "deregister")
    }

    private func debugLogCounts(reason: String, throttle: Bool = false) {
        guard debugCountsEnabled else { return }

        let now = Date()
        if throttle, now.timeIntervalSince(lastDebugLogAt) < 1.0 {
            return
        }
        lastDebugLogAt = now

        let backgroundedCount = pool.values.filter { $0.state == .backgrounded }.count
        let pendingGCCount = pool.values.filter { $0.state == .pendingGC }.count
        let defunctCount = pool.values.filter { $0.state == .defunct }.count

        Self.debugLogger.log(
            "reason=\(reason, privacy: .public) active=\(self.activeSurfaceViewIDs.count, privacy: .public) backgrounded=\(backgroundedCount, privacy: .public) pendingGC=\(pendingGCCount, privacy: .public) defunct=\(defunctCount, privacy: .public) dirty=\(self.lastRecordedDirtyCount, privacy: .public)"
        )
    }

    private func scheduleTickIfDrawable(view: GhosttyTerminalView) {
        let viewID = ObjectIdentifier(view)
        guard activeSurfaceViewIDs.contains(viewID),
              dirtySurfaceViewIDs.contains(viewID) else { return }
        GhosttyApp.scheduleTickIfInitialized()
    }
}
