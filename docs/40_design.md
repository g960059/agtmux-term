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

    deinit {
        // View 破棄時に surface と activeSurfaces 登録を確実に解放する
        if let surface { ghostty_surface_free(surface) }
        GhosttyApp.shared.releaseSurface(for: self)
    }

    func attachSurface(_ newSurface: ghostty_surface_t) {
        // 旧 surface を解放してから activeSurfaces から除去
        // surface?.free() は不可（ghostty_surface_t は OpaquePointer 相当で .free() メソッドを持たない）
        if let old = surface {
            ghostty_surface_free(old)
            GhosttyApp.shared.releaseSurface(for: self)
        }
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
        // ghostty_surface_key を先に呼ぶ。consumed = true なら ghostty 側で処理済み。
        // consumed = false の場合のみ interpretKeyEvents で IME pipeline を通す。
        // これにより通常キーが ghostty_surface_key + sendText で二重送信されるのを防ぐ。
        // 注意: IME 変換中は ghostty_surface_key が false を返すことを前提とする（T-004 で確認）。
        var consumed = false
        if let surface {
            let key = GhosttyInput.toGhosttyKey(event)
            consumed = ghostty_surface_key(surface, key)
        }
        if !consumed {
            interpretKeyEvents([event])
            if !keyTextAccumulator.isEmpty {
                sendText(keyTextAccumulator)
            }
        }
        inKeyDown = false
        keyTextAccumulator = ""
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
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

### ghostty_surface_config_s の正確な API（ghostty.h 確認済み 2026-02-28）

```c
// ghostty_surface_config_s の実際の定義
typedef struct {
  ghostty_platform_e platform_tag;   // GHOSTTY_PLATFORM_MACOS
  ghostty_platform_u platform;       // union { ghostty_platform_macos_s macos; }
  void*              userdata;
  double             scale_factor;
  float              font_size;
  const char*        working_directory;
  const char*        command;        // 単一文字列。引数は /bin/sh -c 経由
  ghostty_env_var_s* env_vars;
  size_t             env_var_count;
  const char*        initial_input;
  bool               wait_after_command;
  ghostty_surface_context_e context;
} ghostty_surface_config_s;

// NSView は platform.macos.nsview に入れる（直接フィールドではない）
typedef struct { void* nsview; } ghostty_platform_macos_s;
```

**重要**: `command` は `const char*`（argv 配列ではない）。複数引数は文字列に含める。`nsview` は `ghostty_platform_macos_s.nsview` 経由。

```swift
final class GhosttyApp {
    static let shared = GhosttyApp()
    private(set) var app: ghostty_app_t?
    // Swift 標準に弱参照コレクションがないため NSHashTable.weakObjects() を使用。
    // これにより view が ARC で解放されると自動的にコレクションから除去され dangling pointer を防ぐ。
    private var activeSurfaces: NSHashTable<GhosttyTerminalView> = .weakObjects()

    private init() {
        var runtimeConfig = ghostty_runtime_config_s()
        // userdata に self を渡し、クロージャ内で参照（シングルトンなので実質同等だが明示）
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        // @convention(c) 制約: C 関数ポインタに代入できるのはキャプチャなしのクロージャのみ。
        // GhosttyApp.shared はスタティック参照なのでキャプチャに該当せず、コンパイルが通る。
        // クロージャ内で self や他のローカル変数をキャプチャした場合はコンパイルエラーになる。
        runtimeConfig.wakeup_cb = { ud in
            // libghostty internal timer thread から呼ばれる。main で tick。
            DispatchQueue.main.async {
                GhosttyApp.shared.tick()
            }
        }
        let config = ghostty_config_new()
        defer { ghostty_config_free(config) }
        app = ghostty_app_new(&runtimeConfig, config)
    }

    private func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
        activeSurfaces.allObjects.forEach { $0.triggerDraw() }
    }

    deinit {
        if let app { ghostty_app_free(app) }
    }

    /// surface を作成して activeSurfaces に登録する。
    /// command は "tmux attach-session -t sessionName" のような shell コマンド文字列。
    func newSurface(for view: GhosttyTerminalView,
                    command: String? = nil) -> ghostty_surface_t? {
        guard let app else { return nil }
        // command を C 文字列として withCString でスタック上に確保（スコープ外は無効）
        func build(_ cmd: UnsafePointer<CChar>?) -> ghostty_surface_t? {
            var cfg = ghostty_surface_config_s()
            cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
            cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            ))
            cfg.scale_factor = NSScreen.main?.backingScaleFactor ?? 1.0
            cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
            cfg.command = cmd  // nil = デフォルトシェル
            cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
            return ghostty_surface_new(app, &cfg)
        }
        let surface: ghostty_surface_t?
        if let command {
            surface = command.withCString { build($0) }
        } else {
            surface = build(nil)
        }
        if surface != nil { activeSurfaces.add(view) }
        return surface
    }

    /// surface 解放時に activeSurfaces から削除する
    func releaseSurface(for view: GhosttyTerminalView) {
        activeSurfaces.remove(view)
    }
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
    /// waitUntilExit() はスレッドブロッキングのため terminationHandler + continuation を使用
    func fetchSnapshot() async throws -> AgtmuxSnapshot {
        guard let agtmuxURL = Self.resolveBinaryURL() else {
            throw DaemonError.daemonUnavailable
        }
        let process = Process()
        process.executableURL = agtmuxURL
        process.arguments = ["--socket-path", socketPath, "json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else {
                    // CLAUDE.md "Fail loudly": stderr を捨てずに伝播させる
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: DaemonError.processError(
                        exitCode: proc.terminationStatus, stderr: stderrStr))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                do {
                    let snapshot = try JSONDecoder().decode(AgtmuxSnapshot.self, from: data)
                    continuation.resume(returning: snapshot)
                } catch {
                    continuation.resume(throwing: DaemonError.parseError(error.localizedDescription))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: DaemonError.processError(exitCode: -1, stderr: error.localizedDescription))
            }
        }
    }

    /// AGTMUX_BIN 環境変数 → PATH 検索の順で agtmux バイナリを探す
    private static func resolveBinaryURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let envPath = env["AGTMUX_BIN"] {
            return URL(fileURLWithPath: envPath)
        }
        let searchPaths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in searchPaths {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("agtmux")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

enum DaemonError: Error {
    /// agtmux バイナリが AGTMUX_BIN / PATH のいずれにも見つからない
    case daemonUnavailable
    /// バイナリは実行できたが非ゼロで終了（daemon 未起動・クラッシュ・スキーマ不一致を含む）
    case processError(exitCode: Int32, stderr: String)
    /// プロセスは正常終了したが JSON デコードに失敗
    case parseError(String)
}
```

**Phase 3 移行計画**: UDS JSON-RPC を直接叩く方式（`AgtmuxDaemonClient` の内部実装を変更するだけでインターフェースは同一）。

## pane アタッチ設計 [MVP]

surface の切り替えは **`TerminalPanel.Coordinator` に一本化**する。
`AppViewModel.selectPane()` は `selectedPane` を更新するだけ。Coordinator が `$selectedPane` を観測して surface 操作を実行する。

```swift
// AppViewModel — selectedPane を更新するだけ（surface 操作しない）
func selectPane(_ pane: AgtmuxPane) {
    selectedPane = pane
}
```

```swift
// TerminalPanel.Coordinator — surface 切り替えの責務をここに集約
// shellEscaped() は Coordinator のプライベートメソッドとして定義する（CockpitView 設計セクション参照）
func observe(_ viewModel: AppViewModel) {
    guard observedViewModel !== viewModel else { return }
    observedViewModel = viewModel
    cancellable = viewModel.$selectedPane
        .dropFirst()
        .sink { [weak self] pane in
            guard let self, let view, let pane else { return }
            // window_index を含めて正しい window を指定（H-002 対応）
            // セッション名はシェルメタ文字対応のため POSIX クォートエスケープを適用
            let command = "tmux attach-session -t \(shellEscaped(pane.sessionName)):\(pane.windowIndex)"
            if let surface = GhosttyApp.shared.newSurface(for: view, command: command) {
                view.attachSurface(surface)
            }
        }
}
```

**設計上の注意**:
- `tmux attach-session -t sessionName:windowIndex` でセッション内の特定 window を表示する（`windowIndex` なしだとカレント window になり、意図した pane が表示されないケースがある）
- `tmux attach-session` は既存のクライアントがいれば共有セッションになる（同一セッションへの複数アタッチは tmux の標準動作）
- 複数の `agtmux-term` ウィンドウを開くと同じセッションを共有するため、どちらかで `detach` するともう一方も切断される（Phase 4 で `tmux new-session -t` 方式に移行予定）

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
        // selectedPane 変更を Coordinator 経由で観測する
        context.coordinator.observe(viewModel)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        weak var view: GhosttyTerminalView?
        private weak var observedViewModel: AppViewModel?
        private var cancellable: AnyCancellable?

        /// viewModel が変わった場合のみ購読を張り直す
        func observe(_ viewModel: AppViewModel) {
            guard observedViewModel !== viewModel else { return }
            observedViewModel = viewModel
            cancellable = viewModel.$selectedPane
                // 起動時の初期値は nil なので dropFirst() で skip しても問題なし。
                // sink 内の `guard let pane` が nil ガードとして機能するため安全。
                // ※ 起動時に前回の selectedPane を復元する場合は dropFirst() を外して要検討。
                .dropFirst()
                .sink { [weak self] pane in
                    guard let self, let view, let pane else { return }
                    let command = "tmux attach-session -t \(shellEscaped(pane.sessionName)):\(pane.windowIndex)"
                    if let surface = GhosttyApp.shared.newSurface(for: view, command: command) {
                        view.attachSurface(surface)
                    }
                }
        }

        /// tmux コマンド引数用 POSIX シェルエスケープ
        /// スペース・$・\・' などのメタ文字を含むセッション名を安全にクォートする
        private func shellEscaped(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
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
        guard pollingTask == nil else { return }  // 多重起動防止
        pollingTask = Task {
            while !Task.isCancelled {
                do {
                    let snapshot = try await daemonClient.fetchSnapshot()
                    panes = snapshot.panes
                    isOffline = false
                } catch is CancellationError {
                    break  // キャンセル時は即座にループを抜ける
                } catch {
                    isOffline = true
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break  // sleep のキャンセルも明示的に終了
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil  // nil 化して startPolling() の再呼び出しを可能にする
    }
}
```

---

# Phase 3 Design

> 設計確定: 2026-03-02

## Core Data Types

### LayoutNode (BSP tree)

```swift
indirect enum LayoutNode: Identifiable, Equatable, Codable {
    case leaf(LeafPane)
    case split(SplitContainer)
    var id: UUID { ... }
}

struct LeafPane: Identifiable, Equatable, Codable {
    let id: UUID
    let tmuxPaneID: String       // "%250"
    let sessionName: String      // "backend-api"
    let source: String           // "local" or hostname
    var linkedSession: LinkedSessionState
}

enum LinkedSessionState: Codable, Equatable, Sendable {
    case creating
    case ready(String)           // "agtmux-{uuid}"
    case failed(String)          // error description
}

struct SplitContainer: Identifiable, Equatable, Codable {
    let id: UUID
    let axis: SplitAxis          // .horizontal (左右) / .vertical (上下)
    var ratio: CGFloat           // 0.1 〜 0.9
    var first: LayoutNode
    var second: LayoutNode
    mutating func setRatio(_ r: CGFloat) { ratio = max(0.1, min(0.9, r)) }
}

enum SplitAxis: String, Codable, Equatable {
    case horizontal   // Left | Right — divider is a vertical bar  (tmux split-window -h)
    case vertical     // Top / Bottom — divider is a horizontal bar (tmux split-window -v)
}
```

LayoutNode ユーティリティ:
- `validateUniqueIDs()` — 重複 UUID を early-fail で検出
- `replacing(leafID:with:depth:)` — depth < 256 ガード付き
- `splitLeaf`, `removingLeaf`, `allLeafIDs`, `allPaneIDs`

WorkspaceStore には `updateContainer(id:to:)` を追加して SplitContainerView の @Binding を提供する:
```swift
// SplitContainerView での利用
SplitContainerView(
    container: Binding(
        get: { c },
        set: { store.updateContainer(id: $0.id, to: $0) }
    ), ...
)
```

### SurfacePool

状態遷移: `active → backgrounded → pendingGC (5s grace) → defunct`

デュアルインデックス:
- `leafIDsByPaneID: [String: Set<UUID>]` — %pane-exited イベント用
- `leafIDByLinkedSession: [String: UUID]` — linked session 破棄用

gc() はタイマー駆動（タブ切り替え時に呼ばない）。

### TmuxCommandRunner / TmuxCommandError

```swift
actor TmuxCommandRunner {
    static let shared = TmuxCommandRunner()
    func run(_ args: [String], source: String) async throws -> String
}

enum TmuxCommandError: Error, Sendable {
    case tmuxNotFound(source: String)
    case permissionDenied(source: String, detail: String)
    case sshFailed(host: String, code: Int32, stderr: String)
    case failed(args: [String], code: Int32, stderr: String)
    case timeout(args: [String])
}
```

### TmuxControlMode + Registry

```swift
actor TmuxControlMode {
    var events: AsyncStream<ControlModeEvent> { get }
    enum ConnectionState { case connected, reconnecting(attempt: Int), degraded, stopped }
    // 再接続: 1s/2s/4s/8s/16s backoff, maxRetries=5
}

@MainActor
final class TmuxControlModeRegistry {
    static let shared = TmuxControlModeRegistry()
    func safeKillSession(_ name: String, source: String) async throws
    // stop TmuxControlMode → kill-session の順序を保証
}
```

WorkspaceController での AsyncStream 消費:
```swift
func startMonitoring(sessionName: String, source: String) {
    controlModeTasks[sessionName] = Task { [weak self] in
        for await event in await mode.events {
            guard let self else { break }
            await self.handle(event: event, sessionName: sessionName)
        }
    }
}
```

## ghostty_surface_config_s フィールド（Phase 3 確認済み）

| フィールド | 型 | 用途 |
|-----------|-----|------|
| platform_tag | ghostty_platform_tag_e | GHOSTTY_PLATFORM_MACOS |
| platform.macos.nsview | void* | NSView* として渡す |
| scale_factor | double | backingScaleFactor |
| userdata | void* | GhosttyTerminalView* |
| command | const char* | "tmux attach-session -t agtmux-{uuid}" |
