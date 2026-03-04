import Foundation
import AppKit
import GhosttyKit

// MARK: - SurfacePool

/// Manages the lifecycle of Ghostty terminal surfaces.
///
/// State transitions:
///   active → backgrounded → pendingGC (5 s grace) → defunct
///
/// Dual index enables event-based lookup:
///   - pane ID ("%250")        → leafIDsByPaneID     [for %pane-exited events]
///   - linked session name     → leafIDByLinkedSession [for session destroy events]
///
/// GC is timer-driven. The timer runs only while pendingGC entries exist.
/// Tab switches do NOT call gc() directly.
@Observable
@MainActor
final class SurfacePool {
    static let shared = SurfacePool()

    enum SurfaceState: Equatable {
        case active
        case backgrounded
        case pendingGC
        case defunct
    }

    struct ManagedSurface {
        let leafID: UUID
        /// The tmux pane ID (e.g. "%250"). Used for markDefunct(byPaneID:).
        let tmuxPaneID: String
        /// Set when T-037 LinkedSessionManager is in use.
        var linkedSessionName: String?
        /// Strong reference prevents ARC dealloc during pendingGC grace period.
        let view: GhosttyTerminalView
        var state: SurfaceState
        /// Non-nil when state == .pendingGC.
        var pendingGCDeadline: Date?
    }

    // MARK: - Indexes

    private var pool: [UUID: ManagedSurface] = [:]
    private var leafIDsByPaneID: [String: Set<UUID>] = [:]
    private var leafIDByLinkedSession: [String: UUID] = [:]

    // MARK: - GC timer

    private var gcTimer: Timer?

    private init() {}

    // MARK: - Registration

    /// Register a newly created surface.
    /// Safe to call multiple times for the same leafID (re-attach replaces the entry).
    func register(view: GhosttyTerminalView,
                  leafID: UUID,
                  tmuxPaneID: String,
                  linkedSessionName: String? = nil) {
        deregisterInternal(leafID: leafID)

        let managed = ManagedSurface(
            leafID: leafID,
            tmuxPaneID: tmuxPaneID,
            linkedSessionName: linkedSessionName,
            view: view,
            state: .active
        )
        pool[leafID] = managed
        leafIDsByPaneID[tmuxPaneID, default: []].insert(leafID)
        if let name = linkedSessionName {
            leafIDByLinkedSession[name] = leafID
        }
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
        if let surface = managed.view.surface {
            ghostty_surface_set_occlusion(surface, true)
        }
    }

    /// Mark leaf as backgrounded. Sets ghostty occlusion = occluded (stops Metal render).
    /// Idempotent: no-op if already backgrounded.
    func background(leafID: UUID) {
        guard let managed = pool[leafID],
              managed.state == .active else { return }
        pool[leafID]?.state = .backgrounded
        if let surface = managed.view.surface {
            ghostty_surface_set_occlusion(surface, false)
        }
    }

    // MARK: - GC scheduling

    /// Begin 5-second grace period before freeing the surface.
    /// Called when a leaf is removed from the layout.
    func scheduleGC(leafID: UUID) {
        guard var managed = pool[leafID],
              managed.state != .pendingGC,
              managed.state != .defunct else { return }
        managed.state = .pendingGC
        managed.pendingGCDeadline = Date().addingTimeInterval(5)
        pool[leafID] = managed
        startGCTimerIfNeeded()
    }

    /// Schedule GC for all leaves attached to a given tmux pane ID.
    /// Called when a %pane-exited event is received (T-039).
    func markDefunct(byPaneID paneID: String) {
        for leafID in leafIDsByPaneID[paneID] ?? [] {
            scheduleGC(leafID: leafID)
        }
    }

    /// Schedule GC for the leaf attached to a linked session.
    /// Called when a linked session is destroyed (T-037).
    func markDefunct(byLinkedSession sessionName: String) {
        if let leafID = leafIDByLinkedSession[sessionName] {
            scheduleGC(leafID: leafID)
        }
    }

    /// Called by _GhosttyNSView.dismantleNSView to start the grace period.
    func release(leafID: UUID) {
        // If there is no pool entry (view never got a surface), just return.
        guard pool[leafID] != nil else { return }
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
        leafIDsByPaneID[managed.tmuxPaneID]?.remove(leafID)
        if leafIDsByPaneID[managed.tmuxPaneID]?.isEmpty == true {
            leafIDsByPaneID.removeValue(forKey: managed.tmuxPaneID)
        }
        if let name = managed.linkedSessionName {
            leafIDByLinkedSession.removeValue(forKey: name)
        }
        pool.removeValue(forKey: leafID)
    }
}
