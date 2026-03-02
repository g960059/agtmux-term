import AppKit
import SwiftUI
import Combine
import GhosttyKit

// MARK: - CockpitView

/// Top-level layout: sidebar pane list + terminal panel side by side.
struct CockpitView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            TerminalPanel()
                .frame(minWidth: 400)
        }
    }
}

// MARK: - TerminalPanel

/// NSViewRepresentable that hosts a GhosttyTerminalView.
///
/// Surface switching is handled entirely in the Coordinator so that
/// AppViewModel.selectPane() only needs to update selectedPane.
struct TerminalPanel: NSViewRepresentable {
    @EnvironmentObject var viewModel: AppViewModel

    func makeNSView(context: Context) -> GhosttyTerminalView {
        let view = GhosttyTerminalView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        // Delegate selectedPane observation to the Coordinator.
        context.coordinator.observe(viewModel)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Coordinator

    @MainActor
    class Coordinator: NSObject {
        weak var view: GhosttyTerminalView?

        private weak var observedViewModel: AppViewModel?
        private var cancellable: AnyCancellable?

        /// Re-subscribe to $selectedPane only when the viewModel instance changes.
        func observe(_ viewModel: AppViewModel) {
            guard observedViewModel !== viewModel else { return }
            observedViewModel = viewModel
            cancellable = viewModel.$selectedPane
                // Skip the initial nil value at launch.
                .dropFirst()
                .sink { [weak self] pane in
                    guard let self, let view = self.view, let pane = pane else { return }
                    let hostsConfig = viewModel.hostsConfig
                    let command = self.attachCommand(for: pane, hostsConfig: hostsConfig)
                    if let surface = GhosttyApp.shared.newSurface(for: view, command: command) {
                        view.attachSurface(surface)
                    }
                }
        }

        // MARK: - Command builders

        /// Build the shell command to attach to the given pane directly.
        ///
        /// Targets the pane by its tmux pane ID (e.g. `%42`) so that tmux navigates
        /// to the correct session/window and focuses the exact pane.
        ///
        /// - Local pane: `tmux attach-session -t %42`
        /// - Remote SSH:  `ssh -t user@host tmux attach-session -t %42`
        /// - Remote mosh: `mosh user@host -- tmux attach-session -t %42`
        private func attachCommand(for pane: AgtmuxPane, hostsConfig: HostsConfig) -> String {
            let attach = "tmux attach-session -t \(pane.paneId)"

            guard pane.source != "local",
                  let host = hostsConfig.host(for: pane.source) else {
                return attach
            }

            switch host.transport {
            case .ssh:
                return "ssh -t \(host.sshTarget) \(attach)"
            case .mosh:
                return "mosh \(host.sshTarget) -- \(attach)"
            }
        }
    }
}
