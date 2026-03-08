import Foundation

/// Orientation of a split in tmux/workbench layout models.
///
/// Naming follows SwiftUI / tmux convention:
///   - horizontal = Left | Right  (divider is a vertical bar, tmux split-window -h)
///   - vertical   = Top  / Bottom (divider is a horizontal bar, tmux split-window -v)
package enum SplitAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}
