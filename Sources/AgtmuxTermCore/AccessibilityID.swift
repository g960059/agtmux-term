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
    public static let sidebarPanePrefix   = "sidebar.pane."      // + source_paneID

    // MARK: - Workspace
    public static let workspaceArea       = "workspace"
    public static let workspaceTabBar     = "workspace.tabBar"
    public static let workspaceTabPrefix  = "workspace.tab."     // + tab UUID
    public static let workspaceNewTab     = "workspace.newTabButton"
    public static let workspaceEmpty      = "workspace.emptyState"
    public static let workspaceTilePrefix = "workspace.tile."    // + source_paneID
    public static let workspaceLoadingPrefix = "workspace.loading." // + source_paneID

    /// Sanitised key combining source and pane ID — safe for use as an identifier.
    public static func paneKey(source: String, paneID: String) -> String {
        let s = source.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        let p = paneID.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        return "\(s)_\(p)"
    }
}
