# Implementation Plan

## Overview

4フェーズで段階的に実装する。各フェーズに明確な Exit Criteria を設定し、動作確認してから次フェーズに進む。

```
Phase 0: Build Infrastructure
  └── T-001: GhosttyKit.xcframework ビルド環境構築

Phase 1: Terminal Core
  ├── T-002: GhosttyApp.swift (app lifecycle)
  ├── T-003: GhosttyTerminalView.swift (NSView + Metal + Resize + HiDPI)
  ├── T-004: GhosttyInput.swift (NSEvent mapping + NSTextInputClient IME)
  └── T-005: HelloWorld 統合確認

Phase 2: Sidebar UI Port
  ├── T-006: AppViewModel.swift port from POC
  ├── T-007: Sidebar UI port (SidebarView + SessionRowView + FilterBarView)
  └── T-008: CockpitView.swift (HSplitView 統合)

Phase 3: Daemon Integration
  ├── T-009: AgtmuxDaemonClient.swift (agtmux CLI wrapper)
  ├── T-010: pane 選択 → tmux attach surface 切り替え
  └── T-011: agent state リアルタイム表示

Phase 4: Polish [Post-MVP]
  ├── T-012: マルチサーフェス（タブ切り替え）
  ├── T-013: キーボードショートカット
  └── T-014: libghostty-full public API リリース後の移行
```

---

## Phase 0: Build Infrastructure

### T-001: GhosttyKit.xcframework ビルド環境構築

**目標**: `swift build` が GhosttyKit.xcframework を参照してコンパイルできる状態にする

**手順:**
1. Ghostty リポジトリを取得（vendor/ サブディレクトリまたは git submodule）
   ```bash
   git submodule add https://github.com/ghostty-org/ghostty vendor/ghostty
   # または
   git clone https://github.com/ghostty-org/ghostty vendor/ghostty
   ```
2. `zig build xcframework` を実行して `GhosttyKit.xcframework` を生成
   ```bash
   cd vendor/ghostty
   zig build xcframework
   # 生成物: zig-out/lib/GhosttyKit.xcframework
   ```
3. xcframework を `GhosttyKit/` にコピー
4. `Package.swift` で binaryTarget として参照
   ```swift
   .binaryTarget(
       name: "GhosttyKit",
       path: "GhosttyKit/GhosttyKit.xcframework"
   )
   ```
5. `Package.swift` に依存として追加し、ターゲットに link

**Exit Criteria**: `swift build` が GhosttyKit をリンクしてコンパイルできる（`ghostty_app_new` が解決される）

**Risks:**
- R-001: Zig バージョン不一致 → `zig version` が 0.14.x であること確認
- R-002: xcframework を git に追加するとサイズ大 → `.gitignore` で除外し、ビルドスクリプトで再生成

---

## Phase 1: Terminal Core

### T-002: GhosttyApp.swift — ghostty_app_t lifecycle

**目標**: `ghostty_app_t` のシングルトン管理と wakeup_cb のセットアップ

**実装内容:**
- `GhosttyApp` クラス（`final class`、`static let shared`）
- `ghostty_runtime_config_s` に `wakeup_cb` を設定
- `wakeup_cb` 内で `DispatchQueue.main.async { ghostty_app_tick(app) }`
- `ghostty_config_new()` / `ghostty_app_new()` / `ghostty_app_free()` ライフサイクル管理

**Exit Criteria**: アプリ起動時に `ghostty_app_t` が生成され、deinit 時に解放される（クラッシュなし）

### T-003: GhosttyTerminalView.swift — NSView + Metal + Resize + HiDPI

**目標**: libghostty surface を Metal で描画する NSView

**実装内容:**
- `GhosttyTerminalView: NSView` クラス
- `wantsLayer = true`、`makeBackingLayer()` で `CAMetalLayer` を返す
- `layout()` で `ghostty_surface_set_size()` に HiDPI スケール適用
- `ghostty_surface_draw()` を呼ぶ `triggerDraw()` メソッド
- `ghostty_surface_new()` / `ghostty_surface_free()` の surface lifecycle

**Exit Criteria**: NSView 上に黒いターミナル画面が表示される（文字はまだ出なくてよい）

### T-004: GhosttyInput.swift — NSEvent → ghostty_input_key_s + NSTextInputClient IME

**目標**: キーボード入力と IME をターミナルに渡す

**実装内容:**
- `GhosttyInput` 構造体（namespace）
  - `toGhosttyKey(_:NSEvent) -> ghostty_input_key_s`（キーコード変換テーブル）
  - `toMods(_:NSEvent.ModifierFlags) -> ghostty_input_mods_s`
  - `toScrollMods(_:NSEvent) -> ghostty_input_scroll_mods_s`
- `NSTextInputClient` 実装（`setMarkedText`, `insertText`, `firstRect` など）
- `keyDown(with:)` のオーバーライド

**Exit Criteria**: `a`, `Enter`, `Ctrl+C`, 日本語入力（ひらがな変換）が正常動作する

### T-005: HelloWorld 統合確認

**目標**: `$SHELL` が GPU レンダリングされ、基本操作ができることを確認

**確認事項:**
- シェルプロンプトが表示される
- 文字入力・Enter・Ctrl+C が動作する
- ウィンドウリサイズに追随する
- HiDPI（Retina）で鮮明に描画される
- 日本語 IME で候補ウィンドウが正しい位置に出る

**Exit Criteria**: 上記全項目を手動確認

---

## Phase 2: Sidebar UI Port

### T-006: AppViewModel.swift port from POC

**目標**: POC の AppViewModel を agtmux daemon 対応に移植

**POC 参照**: `exp/go-codex-implementation-poc/macapp/Sources/AppViewModel.swift`

**変更点:**
- Go 製 daemon への接続 → `AgtmuxDaemonClient` (agtmux CLI) に変更
- データモデルを `DaemonModels.swift` の型に合わせる
- `isOffline` 状態の追加

**Exit Criteria**: `@Published var panes` がダミーデータで populated される

### T-007: Sidebar UI port

**目標**: サイドバー UI を POC から移植

**POC 参照**:
- `exp/go-codex-implementation-poc/macapp/Sources/AGTMUXDesktopApp.swift`（SidebarView 部分）

**コンポーネント:**
- `SidebarView.swift`: pane 一覧のスクロールリスト
- `SessionRowView.swift`: 各行（pane_id、activity_state アイコン、conversation_title）
- `FilterBarView.swift`: All / Managed / Attention / Pinned タブ

**Exit Criteria**: サイドバーにダミーデータの pane 一覧が表示される

### T-008: CockpitView.swift — HSplitView 統合

**目標**: サイドバー + ターミナルを横並びで表示する root view

**実装内容:**
- `CockpitView: View` (SwiftUI)
- `HSplitView { SidebarView() + TerminalPanel() }`
- `TerminalPanel: NSViewRepresentable` で `GhosttyTerminalView` をラップ

**Exit Criteria**: ウィンドウにサイドバーとターミナルが並んで表示される

---

## Phase 3: Daemon Integration

### T-009: AgtmuxDaemonClient.swift — agtmux CLI wrapper

**目標**: `agtmux json` CLI を subprocess 実行して JSON を取得・パース

**実装内容:**
- `AgtmuxDaemonClient` actor
- `Process()` で `agtmux --socket-path <path> json` を実行
- stdout を JSON デコード → `AgtmuxSnapshot`
- `DaemonError.daemonUnavailable` で daemon 未起動を graceful に処理

**Exit Criteria**: agtmux daemon 起動中に `fetchSnapshot()` が正常データを返す。未起動時は `DaemonError.daemonUnavailable` を throw する

### T-010: pane 選択 → tmux attach surface 切り替え

**目標**: サイドバーで pane を選択するとターミナルがその pane を表示する

**実装内容:**
- `AppViewModel.selectPane(_:)` で `GhosttyApp.shared.newSurface(command: ["tmux", "attach-session", "-t", sessionName])`
- 既存 surface の解放と新 surface のアタッチ

**Exit Criteria**: サイドバーで別の session を選ぶとターミナルが切り替わる

### T-011: agent state リアルタイム表示

**目標**: activity_state が1秒ごとに更新され、サイドバーの色・アイコンに反映される

**確認事項:**
- `running` → 緑のインジケーター
- `waiting_approval` → 黄/オレンジのインジケーター
- `idle` → グレー
- `conversation_title` がサイドバーに表示される

**Exit Criteria**: Claude Code を動かしている pane の状態変化がリアルタイムにサイドバーに反映される

---

## Phase 4: Polish [Post-MVP]

### T-012: マルチサーフェス（タブ切り替え）
複数 pane を同時に表示するタブ UI。

### T-013: キーボードショートカット
`Cmd+1`〜`Cmd+9` で pane 切り替えなど。

### T-014: libghostty-full public API リリース後の移行
現在 internal API を使っているため、Ghostty が public API を提供した際に移行する。

---

## Risks & Mitigations

| ID | Risk | Mitigation |
|----|------|------------|
| R-001 | libghostty API breaking changes | Ghostty upstream に追従。xcframework を再ビルド。`build-ghosttykit.sh` でバージョンを固定管理 |
| R-002 | xcframework の配布 | **Git LFS 採用**（ADR-20260228b）。`git lfs install` が必要。LFS 未設定の clone はポインタファイルが残る点を README に記載 |
| R-003 | ghostty_surface_config_s の command 設定方法 | T-000 で確認済み（`const char*`）。Ghostty 本体 `src/apprt/swift/SurfaceView_AppKit.swift` が常にリファレンス |
| R-004 | POC の AppViewModel が古い agtmux API を使っている | DaemonModels.swift（T-006a）に新 API スキーマを定義し、AppViewModel を適応させる |
| R-005 | `tmux attach-session` が既存クライアントを共有セッションにする | 複数 agtmux-term ウィンドウを同一セッションに attach すると detach 時に両方切れる。Phase 4 で `tmux new-session -t` 方式に移行。MVP では既知の制限として許容 |
| R-006 | surface lifecycle: `ghostty_surface_free()` 後の同一 NSView への再 attach | T-003 で `SurfaceView_AppKit.swift` の deinit パターンを確認し、CAMetalLayer の再利用可否を検証する |
