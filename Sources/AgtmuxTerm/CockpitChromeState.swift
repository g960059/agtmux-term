import Foundation
import Observation
import CoreGraphics

@Observable
@MainActor
final class CockpitChromeState {
    /// Collapses the sidebar in content and hides non-essential titlebar icons.
    var isSidebarCollapsed = false

    /// Measured titlebar height used to keep chrome vertically centered.
    var titlebarHeight: CGFloat = 28
    /// Right edge of macOS traffic lights in titlebar coordinates.
    var trafficLightsTrailingX: CGFloat = 72
    /// Fine vertical alignment offset between traffic lights and custom row.
    var yOffset: CGFloat = 0
}
