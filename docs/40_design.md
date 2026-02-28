# Design

## GhosttyTerminalView 設計 [MVP]

`NSView` + `NSTextInputClient` を実装するターミナル描画ビュー。libghostty の Metal GPU レンダリングをホストする。

```swift
class GhosttyTerminalView: NSView, NSTextInputClient {
    private var surface: ghostty_surface_t?
    private var markedText = NSMutableAttributedString()
    // insertText が呼ばれる前に keyDown で蓄積するテキスト
    // interpretKeyEvents の呼び出し中は inKeyDown = true
    private var keyTextAccumulator = ""
    private var inKeyDown = false

    // Metal layer を要求する
    override var wantsLayer: Bool { get { true } set {} }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    // MARK: - Lifecycle

    func attachSurface(_ newSurface: ghostty_surface_t) {
        surface?.free()  // 旧 surface を解放
        surface = newSurface
        // libghostty が layer に直接描画する。layer は ghostty_surface_new 時に設定済み
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 1.0
        ghostty_surface_set_size(surface,
                                 UInt32(bounds.width * scale),
                                 UInt32(bounds.height * scale))
    }

    // MARK: - Draw

    // libghostty が wakeup_cb から呼び出す draw トリガー
    func triggerDraw() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    // MARK: - NSTextInputClient (IME)

    func setMarkedText(_ string: Any,
                       selectedRange: NSRange,
                       replacementRange: NSRange) {
        // preedit テキストを libghostty に送る
        let str: String
        if let attributed = string as? NSAttributedString {
            str = attributed.string
        } else {
            str = string as? String ?? ""
        }
        markedText = NSMutableAttributedString(string: str)
        guard let surface else { return }
        str.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let str: String
        if let attributed = string as? NSAttributedString {
            str = attributed.string
        } else {
            str = string as? String ?? ""
        }
        markedText = NSMutableAttributedString()
        if inKeyDown {
            // keyDown の interpretKeyEvents 中は蓄積する
            keyTextAccumulator += str
        } else {
            // IME確定など keyDown の外から呼ばれた場合は即送信
            sendText(str)
        }
    }

    private func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        // ghostty 座標（左上原点） → NSScreen 座標（左下原点）変換
        guard let screen = window?.screen else { return .zero }
        let screenH = screen.frame.height
        return NSRect(x: x, y: screenH - y - h, width: w, height: h)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(0..<markedText.length) : .notFound
    }
    func selectedRange() -> NSRange { .notFound }
    func unmarkText() { markedText = NSMutableAttributedString() }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange,
                              actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        inKeyDown = true
        keyTextAccumulator = ""
        interpretKeyEvents([event])
        // ghostty_surface_key でも送る（Ctrl+C など特殊キー用）
        if let surface {
            let key = GhosttyInput.toGhosttyKey(event)
            _ = ghostty_surface_key(surface, key)
        }
        if !keyTextAccumulator.isEmpty {
            sendText(keyTextAccumulator)
        }
        inKeyDown = false
        keyTextAccumulator = ""
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        let loc = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_button(surface,
                                     GHOSTTY_MOUSE_LEFT,
                                     GHOSTTY_MOUSE_PRESS,
                                     GhosttyInput.toMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let loc = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, loc.x, bounds.height - loc.y)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface,
                                     event.scrollingDeltaX,
                                     -event.scrollingDeltaY,
                                     GhosttyInput.toScrollMods(event))
    }

    override var acceptsFirstResponder: Bool { true }
}
```

## GhosttyApp 設計 [MVP]

`ghostty_app_t` のライフサイクルを管理するシングルトン。`wakeup_cb` を C 関数ポインタとして渡す。

```swift
final class GhosttyApp {
    static let shared = GhosttyApp()
    private(set) var app: ghostty_app_t?

    private init() {
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.wakeup_cb = { appUD in
            // libghostty が 8ms ごとに呼ぶ。DispatchQueue.main で tick。
            DispatchQueue.main.async {
                guard let app = GhosttyApp.shared.app else { return }
                ghostty_app_tick(app)
                // 全 surface に draw を要求
                GhosttyApp.shared.activeSurfaces.forEach { $0.triggerDraw() }
            }
        }
        let config = ghostty_config_new()
        defer { ghostty_config_free(config) }
        app = ghostty_app_new(&runtimeConfig, config)
    }

    deinit {
        if let app { ghostty_app_free(app) }
    }

    func newSurface(for view: GhosttyTerminalView,
                    command: [String]? = nil) -> ghostty_surface_t? {
        guard let app else { return nil }
        var cfg = ghostty_surface_config_s()
        cfg.nsview = Unmanaged.passUnretained(view).toOpaque()
        // command が指定されていれば起動コマンドを設定
        // (ghostty_surface_config_s の command/argv フィールド)
        return ghostty_surface_new(app, &cfg)
    }

    var activeSurfaces: [GhosttyTerminalView] = []
}
```

## AgtmuxDaemonClient 設計 [MVP]

Phase 1 では `agtmux json` CLI を subprocess として呼ぶシンプルな実装。

```swift
actor AgtmuxDaemonClient {
    private let socketPath: String

    init(socketPath: String = "\(NSHomeDirectory())/.local/share/agtmux/daemon.sock") {
        self.socketPath = socketPath
    }

    /// agtmux CLI を実行して JSON スナップショットを取得する
    func fetchSnapshot() async throws -> AgtmuxSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/agtmux")
        process.arguments = ["--socket-path", socketPath, "json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // エラーは捨てる（daemon 未起動時はオフラインモード）

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DaemonError.daemonUnavailable
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return try JSONDecoder().decode(AgtmuxSnapshot.self, from: data)
    }
}

enum DaemonError: Error {
    case daemonUnavailable
    case parseError(String)
}
```

**Phase 3 移行計画**: UDS JSON-RPC を直接叩く方式（`AgtmuxDaemonClient` の内部実装を変更するだけでインターフェースは同一）。

## pane アタッチ設計 [MVP]

```swift
// AppViewModel 内
func selectPane(_ pane: AgtmuxPane) {
    selectedPane = pane
    // tmux attach-session で対象 session に接続する surface を作る
    let command = ["tmux", "attach-session", "-t", pane.sessionName]
    guard let surface = GhosttyApp.shared.newSurface(for: terminalView,
                                                      command: command) else {
        return
    }
    terminalView.attachSurface(surface)
}
```

**注意**: `tmux attach-session` は既存のクライアントがいれば共有セッションになる（同一セッションへの複数アタッチは tmux の標準動作）。

## CockpitView 設計 [MVP]

```swift
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

struct TerminalPanel: NSViewRepresentable {
    @EnvironmentObject var viewModel: AppViewModel

    func makeNSView(context: Context) -> GhosttyTerminalView {
        let view = GhosttyTerminalView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        // selectedPane 変更時に surface を切り替える
        // (AppViewModel.objectWillChange を観測してコーディネータで処理)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var view: GhosttyTerminalView?
    }
}
```

## AppViewModel 設計 [MVP]

POC (`exp/go-codex-implementation-poc/macapp/Sources/AppViewModel.swift`) から移植。
主な変更点: Go 製の別 daemon への接続 → agtmux daemon CLI 呼び出しに変更。

```swift
@MainActor
final class AppViewModel: ObservableObject {
    @Published var panes: [AgtmuxPane] = []
    @Published var selectedPane: AgtmuxPane?
    @Published var isOffline: Bool = false
    @Published var statusFilter: StatusFilter = .all

    private let daemonClient = AgtmuxDaemonClient()
    private var pollingTask: Task<Void, Never>?

    var filteredPanes: [AgtmuxPane] {
        switch statusFilter {
        case .all: return panes
        case .managed: return panes.filter { $0.presence != nil }
        case .attention: return panes.filter { $0.needsAttention }
        case .pinned: return panes.filter { $0.isPinned }
        }
    }

    func startPolling() {
        pollingTask = Task {
            while !Task.isCancelled {
                do {
                    let snapshot = try await daemonClient.fetchSnapshot()
                    panes = snapshot.panes
                    isOffline = false
                } catch {
                    isOffline = true
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() { pollingTask?.cancel() }
}
```
