import AppKit
import GhosttyKit

/// Singleton that owns the ghostty_app_t lifecycle.
///
/// Design constraints:
/// - wakeup_cb must be a @convention(c) function pointer (no captures).
///   We reference GhosttyApp.shared which is a static property and thus
///   not a closure capture in the C-function-pointer sense.
/// - activeSurfaces uses NSHashTable<GhosttyTerminalView>.weakObjects() so that
///   ARC-deallocated views are automatically removed, preventing dangling pointers.
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?

    /// Weak collection of all live terminal views.
    /// NSHashTable.weakObjects() nil-ifies entries when the view is deallocated.
    private var activeSurfaces: NSHashTable<GhosttyTerminalView> = .weakObjects()
    private var tickCount = 0

    private init() {
        var runtimeConfig = ghostty_runtime_config_s()

        // Pass self as userdata (passUnretained — singleton, never deallocated).
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()

        // @convention(c) closure: no captures allowed.
        // GhosttyApp.shared is a static reference, not a capture.
        runtimeConfig.wakeup_cb = { _ in
            // libghostty calls this from an internal timer thread.
            // Marshal tick() to the main thread.
            DispatchQueue.main.async {
                GhosttyApp.shared.tick()
            }
        }

        // action_cb is required by libghostty during surface init.
        runtimeConfig.action_cb = { app, target, action in
            GhosttyApp.handleAction(app, target: target, action: action)
        }
        // Clipboard callbacks: non-optional in Zig (*const fn), so nil → crash
        // if clipboard is ever accessed. Provide no-op stubs for MVP.
        runtimeConfig.read_clipboard_cb = { _, _, _ in }
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.write_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.close_surface_cb = nil   // optional (?*const fn) — nil is safe
        runtimeConfig.supports_selection_clipboard = false

        let config = ghostty_config_new()
        defer { ghostty_config_free(config) }

        // Mirror the loading sequence from Ghostty's own Ghostty.Config.loadConfig():
        //   1. load default files (~/.config/ghostty/config, etc.)
        //   2. load CLI args (skipped — we don't forward CLI args to Ghostty)
        //   3. load recursively-referenced files
        //   4. finalize — populates internal defaults; MUST be called before
        //      ghostty_app_new / ghostty_surface_new, otherwise surface creation
        //      reads uninitialized config fields and crashes.
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        app = ghostty_app_new(&runtimeConfig, config)
    }

    // MARK: - Runtime callbacks

    private static func handleAction(_ app: ghostty_app_t?,
                                     target: ghostty_target_s,
                                     action: ghostty_action_s) -> Bool {
        _ = app
        _ = target

        // These are emitted during surface creation and can be safely ignored
        // in this embedding.
        switch action.tag {
        case GHOSTTY_ACTION_CELL_SIZE,
             GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_INITIAL_SIZE:
            return true

        // QUIT_TIMER fires when libghostty thinks all surfaces have closed and
        // wants to terminate the app. In our embedded design the host app
        // controls lifecycle, so we consume this action and do nothing.
        // Without this, libghostty falls back to NSApp.terminate() -> SIGTERM.
        //
        // SET_TITLE is also consumed. The host window hides the title text and uses
        // workspace tabs as the user-facing title surface, so terminal OSC/tmux
        // titles must never mutate NSWindow chrome.
        case GHOSTTY_ACTION_QUIT_TIMER:
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            return true

        default:
            break
        }

        return false
    }

    deinit {
        if let app { ghostty_app_free(app) }
    }

    // MARK: - Tick

    private func tick() {
        guard let app else { return }
        tickCount += 1
        if tickCount <= 5 || tickCount % 100 == 0 {
            print("[tick] #\(tickCount) activeSurfaces=\(activeSurfaces.count)")
        }
        ghostty_app_tick(app)
        // Trigger a Metal draw on every active surface.
        activeSurfaces.allObjects.forEach { $0.triggerDraw() }
    }

    // MARK: - Surface Management

    /// Create a new ghostty surface for the given view and register it.
    ///
    /// - Parameters:
    ///   - view: The GhosttyTerminalView that will host this surface.
    ///   - command: Shell command string (e.g. "tmux attach-session -t main").
    ///              nil = default shell ($SHELL).
    /// - Returns: The new surface, or nil if ghostty_surface_new failed.
    func newSurface(for view: GhosttyTerminalView,
                    command: String? = nil) -> ghostty_surface_t? {
        guard let app else { return nil }

        // Inner builder; uses withCString scope for safe C-string lifetime.
        func build(_ cmd: UnsafePointer<CChar>?) -> ghostty_surface_t? {
            var cfg = ghostty_surface_config_s()
            cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
            cfg.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(view).toOpaque()
                )
            )
            cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 1.0)
            cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
            cfg.command = cmd       // nil → default shell
            cfg.font_size = 0       // 0 = use Ghostty config default
            cfg.working_directory = nil
            cfg.env_vars = nil
            cfg.env_var_count = 0
            cfg.initial_input = nil
            cfg.wait_after_command = false
            return ghostty_surface_new(app, &cfg)
        }

        let surface: ghostty_surface_t?
        if let command {
            surface = command.withCString { build($0) }
        } else {
            surface = build(nil)
        }

        if surface != nil {
            activeSurfaces.add(view)
        }
        return surface
    }

    /// Remove a view from the active surface set (called from deinit / attachSurface).
    func releaseSurface(for view: GhosttyTerminalView) {
        activeSurfaces.remove(view)
    }
}
