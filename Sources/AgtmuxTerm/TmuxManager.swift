import AppKit
import Foundation

// MARK: - TmuxManager

/// Provides tmux session/window/pane management operations.
///
/// All mutating operations call `TmuxCommandRunner.shared.run()` and then
/// trigger an immediate `AppViewModel.fetchAll()` so the sidebar refreshes
/// without waiting for the next 1-second polling cycle.
///
/// Kill operations that involve a session with an active TmuxControlMode
/// go through `TmuxControlModeRegistry.safeKillSession()` to prevent SIGPIPE.
@MainActor
final class TmuxManager {
    static let shared = TmuxManager()

    private init() {}

    // MARK: - Session

    /// Create a new tmux session, prompting the user for a name via NSAlert.
    ///
    /// - Parameters:
    ///   - source: `"local"` or SSH hostname.
    ///   - viewModel: Used to trigger an immediate sidebar refresh on success.
    func createSession(source: String = "local", viewModel: AppViewModel) {
        guard let name = promptForName(title: "New Session",
                                       message: "Enter a name for the new tmux session:",
                                       placeholder: "session-name"),
              !name.isEmpty else { return }
        Task {
            do {
                _ = try await TmuxCommandRunner.shared.run(
                    ["new-session", "-d", "-s", name],
                    source: source
                )
                await viewModel.fetchAll()
            } catch {
                showError(error, context: "create session")
            }
        }
    }

    /// Kill a tmux session safely (stops any active TmuxControlMode first).
    func killSession(_ sessionName: String, source: String = "local", viewModel: AppViewModel) {
        Task {
            do {
                try await TmuxControlModeRegistry.shared.safeKillSession(sessionName, source: source)
                await viewModel.fetchAll()
            } catch {
                showError(error, context: "kill session \(sessionName)")
            }
        }
    }

    // MARK: - Window

    /// Create a new window in the given session.
    func createWindow(sessionName: String, source: String = "local", viewModel: AppViewModel) {
        Task {
            do {
                _ = try await TmuxCommandRunner.shared.run(
                    ["new-window", "-t", sessionName],
                    source: source
                )
                await viewModel.fetchAll()
            } catch {
                showError(error, context: "create window")
            }
        }
    }

    /// Kill the window identified by `windowId` (e.g. `"@510"`) in `sessionName`.
    func killWindow(_ windowId: String, sessionName: String,
                    source: String = "local", viewModel: AppViewModel) {
        Task {
            do {
                _ = try await TmuxCommandRunner.shared.run(
                    ["kill-window", "-t", "\(sessionName):\(windowId)"],
                    source: source
                )
                await viewModel.fetchAll()
            } catch {
                showError(error, context: "kill window \(windowId)")
            }
        }
    }

    // MARK: - Pane

    /// Split the pane identified by `paneId` horizontally or vertically.
    func createPane(_ paneId: String,
                    splitAxis: SplitAxis = .horizontal,
                    source: String = "local",
                    viewModel: AppViewModel) {
        let flag = splitAxis == .horizontal ? "-h" : "-v"
        Task {
            do {
                _ = try await TmuxCommandRunner.shared.run(
                    ["split-window", flag, "-t", paneId],
                    source: source
                )
                await viewModel.fetchAll()
            } catch {
                showError(error, context: "create pane")
            }
        }
    }

    /// Kill the pane identified by `paneId`.
    func killPane(_ paneId: String, source: String = "local", viewModel: AppViewModel) {
        Task {
            do {
                _ = try await TmuxCommandRunner.shared.run(
                    ["kill-pane", "-t", paneId],
                    source: source
                )
                await viewModel.fetchAll()
            } catch {
                showError(error, context: "kill pane \(paneId)")
            }
        }
    }

    // MARK: - Helpers

    /// Present a text-field alert and return the entered string (nil if cancelled).
    private func promptForName(title: String, message: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func showError(_ error: Error, context: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "tmux error: \(context)"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
