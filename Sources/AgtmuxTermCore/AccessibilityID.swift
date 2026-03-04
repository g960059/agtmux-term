import Foundation

/// Centralised accessibility identifiers for XCUITest.
///
/// All identifiers use a "component.detail" dot-notation so XCUITest predicates
/// like "BEGINSWITH 'sidebar.pane.'" work reliably.
public enum AccessibilityID {
    // MARK: - Sidebar
    public static let sidebar             = "sidebar"
    public static let sidebarFilterBar    = "sidebar.filterBar"
    public static let sidebarEmpty        = "sidebar.emptyState"
    public static let sidebarWindowPrefix = "sidebar.window."    // + source_session_windowID
    public static let sidebarPanePrefix   = "sidebar.pane."      // + source_session_paneID

    // MARK: - Workspace
    public static let workspaceArea       = "workspace"
    public static let workspaceTabBar     = "workspace.tabBar"
    public static let workspaceTabPrefix  = "workspace.tab."     // + tab UUID
    public static let workspaceNewTab     = "workspace.newTabButton"
    public static let workspaceEmpty      = "workspace.emptyState"
    public static let workspaceTilePrefix = "workspace.tile."    // + source_session_paneID
    public static let workspaceLoadingPrefix = "workspace.loading." // + source_session_paneID

    /// Sanitised key combining source/session/pane — safe for use as an identifier.
    public static func paneKey(source: String, sessionName: String, paneID: String) -> String {
        let s = source.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        let n = sessionName.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        let p = paneID.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        return "\(s)_\(n)_\(p)"
    }

    /// Sanitised key combining source/session/window — safe for use as an identifier.
    public static func windowKey(source: String, sessionName: String, windowID: String) -> String {
        let s = source.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        let n = sessionName.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        let w = windowID.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        return "\(s)_\(n)_\(w)"
    }
}
