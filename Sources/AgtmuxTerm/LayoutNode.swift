import Foundation

// MARK: - SplitAxis

/// Orientation of a BSP split.
///
/// Naming follows SwiftUI / tmux convention:
///   - horizontal = Left | Right  (divider is a vertical bar, tmux split-window -h)
///   - vertical   = Top  / Bottom (divider is a horizontal bar, tmux split-window -v)
enum SplitAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

// MARK: - LinkedSessionState

/// State of the tmux linked session backing a LeafPane.
///
/// - creating: async creation in progress — GhosttyPaneTile shows a spinner
/// - ready:    linked session name is known (e.g. "agtmux-c4f3a91b") — surface can be created
/// - failed:   creation failed — GhosttyPaneTile shows an error + retry button
enum LinkedSessionState: Codable, Equatable, Sendable {
    case creating
    case ready(String)   // linked session name, e.g. "agtmux-c4f3a91b"
    case failed(String)  // human-readable error description
}

// MARK: - LeafPane

/// Terminal tile occupying a leaf of the BSP tree.
struct LeafPane: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let tmuxPaneID: String      // "%250"
    let sessionName: String     // original tmux session name, e.g. "backend-api"
    let source: String          // "local" or remote hostname

    /// Linked session state (created by LinkedSessionManager in T-037).
    /// Starts as `.creating`; transitions to `.ready` or `.failed`.
    var linkedSession: LinkedSessionState

    init(id: UUID = UUID(),
         tmuxPaneID: String,
         sessionName: String,
         source: String,
         linkedSession: LinkedSessionState = .creating) {
        self.id             = id
        self.tmuxPaneID     = tmuxPaneID
        self.sessionName    = sessionName
        self.source         = source
        self.linkedSession  = linkedSession
    }
}

// MARK: - SplitContainer

/// An interior node of the BSP tree representing a split region.
struct SplitContainer: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let axis: SplitAxis
    /// Proportion assigned to `first`. Clamped to 0.1…0.9 by `setRatio()`.
    var ratio: CGFloat
    var first: LayoutNode
    var second: LayoutNode

    init(id: UUID = UUID(),
         axis: SplitAxis,
         ratio: CGFloat = 0.5,
         first: LayoutNode,
         second: LayoutNode) {
        self.id     = id
        self.axis   = axis
        self.ratio  = max(0.1, min(0.9, ratio))
        self.first  = first
        self.second = second
    }

    /// Update ratio, clamped to 0.1…0.9. Call this from UI drag handlers.
    mutating func setRatio(_ newRatio: CGFloat) {
        ratio = max(0.1, min(0.9, newRatio))
    }
}

// MARK: - LayoutNode

/// Binary Space Partition tree representing the workspace layout.
///
/// Value type: copying a LayoutNode is safe and cheap for SwiftUI diffing.
indirect enum LayoutNode: Identifiable, Equatable, Codable, Sendable {
    case leaf(LeafPane)
    case split(SplitContainer)

    var id: UUID {
        switch self {
        case .leaf(let p):  return p.id
        case .split(let s): return s.id
        }
    }
}

// MARK: - LayoutError

enum LayoutError: Error, Sendable {
    case duplicateID(UUID)
    case maxDepthExceeded
}

// MARK: - LayoutNode utilities

extension LayoutNode {
    // MARK: Validation

    /// Verify that all node IDs in the tree are unique. Throws on first duplicate.
    func validateUniqueIDs() throws {
        var seen = Set<UUID>()
        try _validateUniqueIDs(into: &seen)
    }

    private func _validateUniqueIDs(into seen: inout Set<UUID>) throws {
        guard seen.insert(id).inserted else {
            throw LayoutError.duplicateID(id)
        }
        if case .split(let c) = self {
            try c.first._validateUniqueIDs(into: &seen)
            try c.second._validateUniqueIDs(into: &seen)
        }
    }

    // MARK: Leaf enumeration

    /// All leaf IDs in tree order.
    var leafIDs: [UUID] {
        switch self {
        case .leaf(let p):
            return [p.id]
        case .split(let c):
            return c.first.leafIDs + c.second.leafIDs
        }
    }

    /// All leaves in tree order.
    var leaves: [LeafPane] {
        switch self {
        case .leaf(let p):
            return [p]
        case .split(let c):
            return c.first.leaves + c.second.leaves
        }
    }

    // MARK: Node replacement

    /// Return a new tree with the leaf matching `leafID` replaced by `newNode`.
    /// Returns `nil` if no leaf with that ID is found.
    /// Depth guard prevents stack overflow from malformed trees.
    func replacing(leafID: UUID, with newNode: LayoutNode, depth: Int = 0) -> LayoutNode? {
        guard depth < 256 else { return nil }
        switch self {
        case .leaf(let p) where p.id == leafID:
            return newNode
        case .leaf:
            return nil
        case .split(var c):
            if let updated = c.first.replacing(leafID: leafID, with: newNode, depth: depth + 1) {
                c.first = updated
                return .split(c)
            }
            if let updated = c.second.replacing(leafID: leafID, with: newNode, depth: depth + 1) {
                c.second = updated
                return .split(c)
            }
            return nil
        }
    }

    // MARK: Split

    /// Return a new tree where the leaf matching `id` is split into
    /// a SplitContainer containing the original leaf (first) and `newLeaf` (second).
    func splitLeaf(id: UUID, axis: SplitAxis, newLeaf: LeafPane) -> LayoutNode? {
        guard case .leaf(let p) = self, p.id == id else {
            // recurse
            if case .split(var c) = self {
                if let updated = c.first.splitLeaf(id: id, axis: axis, newLeaf: newLeaf) {
                    c.first = updated
                    return .split(c)
                }
                if let updated = c.second.splitLeaf(id: id, axis: axis, newLeaf: newLeaf) {
                    c.second = updated
                    return .split(c)
                }
            }
            return nil
        }
        let container = SplitContainer(axis: axis, ratio: 0.5,
                                       first: .leaf(p),
                                       second: .leaf(newLeaf))
        return .split(container)
    }

    // MARK: Remove

    /// Return a new tree with the leaf matching `id` removed.
    /// - If the leaf's sibling is a leaf/split, the sibling replaces the parent container.
    /// - Returns `nil` if this node IS the leaf to remove (caller should handle).
    func removingLeaf(id: UUID) -> LayoutNode? {
        switch self {
        case .leaf(let p):
            return p.id == id ? nil : self
        case .split(let c):
            // If first is the target, return second (unwrapped)
            if case .leaf(let p) = c.first, p.id == id {
                return c.second
            }
            // If second is the target, return first (unwrapped)
            if case .leaf(let p) = c.second, p.id == id {
                return c.first
            }
            // Recurse into subtrees
            var updated = c
            if let newFirst = c.first.removingLeaf(id: id) {
                updated.first = newFirst
                return .split(updated)
            }
            if let newSecond = c.second.removingLeaf(id: id) {
                updated.second = newSecond
                return .split(updated)
            }
            return self
        }
    }
}
