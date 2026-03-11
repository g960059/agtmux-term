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

    /// Accessory view minX measured in window coordinates.
    /// Needed to align tab start to main-panel boundary in global space.
    var titlebarAccessoryMinXInWindow: CGFloat = 0

    /// Right edge of macOS traffic lights in accessory-local coordinates.
    var trafficLightsTrailingXInAccessory: CGFloat = 72

    /// Fine vertical alignment offset between traffic lights and custom row.
    var yOffset: CGFloat = 0

    /// True while the window is in fullscreen mode.
    var isFullScreen: Bool = false
}
