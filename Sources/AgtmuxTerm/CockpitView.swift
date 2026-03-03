import AppKit
import SwiftUI

// MARK: - CockpitView

/// Top-level layout: sidebar pane list + workspace area side by side.
struct CockpitView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            WorkspaceArea()
                .frame(minWidth: 400)
        }
    }
}
