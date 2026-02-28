# Architecture

## System Context

```
┌─────────────────────────────────────────────────────────┐
│                     macOS Developer                      │
└────────────────────────────┬────────────────────────────┘
                             │ uses
                             ▼
┌─────────────────────────────────────────────────────────┐
│                     agtmux-term                          │
│          (Swift macOS App, this repository)              │
│                                                          │
│  ┌──────────────┐    ┌────────────────────────────────┐  │
│  │   Sidebar    │    │    GhosttyTerminalView          │  │
│  │  (SwiftUI)   │    │    (NSView + Metal GPU)        │  │
│  └──────┬───────┘    └──────────────┬─────────────────┘  │
│         │                           │                     │
└─────────┼───────────────────────────┼─────────────────────┘
          │                           │
          │ UDS JSON-RPC / CLI        │ PTY (via tmux)
          ▼                           ▼
┌─────────────────────┐   ┌──────────────────────────────┐
│   agtmux daemon     │   │   GhosttyKit.xcframework     │
│   (Rust process)    │   │   (libghostty C API)         │
│   agtmux-v5 repo    │   │   Built from Ghostty source  │
└─────────────────────┘   └──────────────────────────────┘
          │                           │
          ▼                           ▼
┌─────────────────────┐   ┌──────────────────────────────┐
│   tmux sessions     │   │   Metal GPU                  │
│   (AI agent panes)  │   │   (GPU-accelerated render)   │
└─────────────────────┘   └──────────────────────────────┘
```

**External Systems:**
- **agtmux daemon**: エージェント状態推定エンジン（別リポジトリ `agtmux-v5-architecture-blueprint`）。UDS JSON-RPC または CLI (`agtmux json`) で状態を提供
- **tmux**: ターミナルマルチプレクサ。pane の PTY を提供
- **GhosttyKit.xcframework**: Ghostty リポジトリから `zig build xcframework` で生成する xcframework。libghostty C API を提供

## Component Tree

```
agtmux-term (Swift macOS App)
├── GhosttyKit.xcframework          ← Ghostty repo から zig build で生成
│   └── ghostty.h                   ← C API ヘッダー
└── Sources/
    ├── App/
    │   ├── AgtmuxTermApp.swift     (@main, WindowGroup, AppDelegate)
    │   └── AppViewModel.swift      (ObservableObject — POC から流用・調整)
    ├── Terminal/
    │   ├── GhosttyApp.swift        (ghostty_app_t lifecycle + wakeup_cb)
    │   ├── GhosttyTerminalView.swift (NSView + Metal + NSTextInputClient)
    │   └── GhosttyInput.swift      (NSEvent → ghostty_input_key_s mapping)
    ├── Sidebar/
    │   ├── SidebarView.swift       (POC から流用)
    │   ├── SessionRowView.swift    (pane 行 UI)
    │   └── FilterBarView.swift     (StatusFilter タブバー)
    ├── DaemonClient/
    │   ├── AgtmuxDaemonClient.swift (agtmux CLI wrapper / UDS client)
    │   └── DaemonModels.swift      (JSON decode 用の型定義)
    └── CockpitView.swift           (HSplitView: sidebar + terminal panel)
```

## Data Flows

### Flow-001: エージェント状態取得

```
AgtmuxDaemonClient
  → Process("agtmux", ["--socket-path", path, "json"])
  → stdout: JSON { version, panes: [...] }
  → DaemonModels.AgtmuxSnapshot (Codable decode)
  → AppViewModel.panes (Published)
  → SidebarView (SwiftUI bindings)
```

**更新間隔**: 1秒ポーリング（Task.sleep ループ）。将来的に UDS push 通知へ移行可能。

### Flow-002: ターミナル表示

```
User selects pane in SidebarView
  → AppViewModel.selectedPane = pane
  → CockpitView observes change
  → GhosttyApp.newSurface(command: ["tmux", "attach-session", "-t", sessionName])
  → ghostty_surface_new(app, &cfg) where cfg.command = argv
  → GhosttyTerminalView.surface = new surface
  → ghostty_surface_draw(surface) [Metal GPU render loop]
```

### Flow-003: キーボード入力

```
NSEvent (keyDown)
  → GhosttyTerminalView.keyDown(_:)
  → interpretKeyEvents([event])          ← NSTextInputClient プロトコル
    ↓ (IME なし)
  → insertText(_:replacementRange:)
  → GhosttyInput.toGhosttyKey(event)
  → ghostty_surface_key(surface, key)    ← PTY へ送信
    ↓ (IME あり)
  → setMarkedText(_:selectedRange:replacementRange:)
  → ghostty_surface_preedit(surface, text, len)
  → insertText → ghostty_surface_text(surface, text, len)
```

### Flow-004: IME 候補ウィンドウ位置

```
IME system calls firstRect(forCharacterRange:actualRange:)
  → ghostty_surface_ime_point(surface, &x, &y, &w, &h)
  → Convert ghostty coords → NSScreen coords
  → return NSRect (IME candidate window position)
```

## Key Design Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| ADR-001 | libghostty を SwiftTerm の代替として採用 | GPU/IME/精度。詳細: `docs/80_decisions/ADR-20260228-libghostty-over-swiftterm.md` |
| ADR-002 | Phase 1 は CLI (`agtmux json`) 経由でデータ取得 | 実装シンプル。UDS JSON-RPC は Phase 3 で移行 |
| ADR-003 | POC の AppViewModel・Sidebar UI を流用 | ロジックは完成している。ターミナルバックエンドのみ置き換え |

## libghostty C API 概要

参照: `ghostty.h` (GhosttyKit.xcframework/Headers/)
参照: Ghostty 本体 `src/apprt/swift/` (SurfaceView_AppKit.swift がリファレンス実装)

```c
// App lifecycle
ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t);
void ghostty_app_free(ghostty_app_t);
void ghostty_app_tick(ghostty_app_t);           // wakeup_cb から呼ぶ

// Surface (terminal view instance)
ghostty_surface_t ghostty_surface_new(ghostty_app_t, const ghostty_surface_config_s*);
void ghostty_surface_free(ghostty_surface_t);
void ghostty_surface_draw(ghostty_surface_t);   // Metal GPU render

// Resize
void ghostty_surface_set_size(ghostty_surface_t, uint32_t w, uint32_t h);

// Input
bool ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);
void ghostty_surface_mouse_button(ghostty_surface_t, ghostty_input_mouse_button_e,
                                  ghostty_input_action_e, ghostty_input_mods_s);
void ghostty_surface_mouse_pos(ghostty_surface_t, double x, double y);
void ghostty_surface_mouse_scroll(ghostty_surface_t, double x, double y,
                                  ghostty_input_scroll_mods_s);
void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);

// IME
void ghostty_surface_preedit(ghostty_surface_t, const char*, uintptr_t);
void ghostty_surface_ime_point(ghostty_surface_t, double* x, double* y,
                               double* w, double* h);
```

**フレームレート**: libghostty 内部 8ms タイマー自律駆動（≈125fps）。Swift 側は `wakeup_cb` を受け取り `ghostty_app_tick()` を呼ぶだけ。
