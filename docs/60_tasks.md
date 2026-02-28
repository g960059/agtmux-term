# Task Board

## Phase 0: Build Infrastructure

### T-001 — GhosttyKit.xcframework ビルド環境構築
- **Status**: TODO
- **Priority**: P0 (blocks everything)
- **Phase**: 0
- **Description**: Ghostty リポジトリを vendor/ に追加し、`zig build xcframework` で GhosttyKit.xcframework を生成。Package.swift で binaryTarget として参照する。
- **Acceptance Criteria**:
  - [ ] Ghostty ソースが vendor/ghostty/ に存在する（submodule or clone）
  - [ ] `cd vendor/ghostty && zig build xcframework` が成功する
  - [ ] GhosttyKit.xcframework が Package.swift の binaryTarget で参照されている
  - [ ] `swift build` がエラーなしで完了する
  - [ ] `ghostty_app_new` シンボルが解決される
- **Notes**: Zig 0.14.x が必要。xcframework は .gitignore に追加してビルドスクリプトで再生成を推奨。

---

## Phase 1: Terminal Core

### T-002 — GhosttyApp.swift — ghostty_app_t lifecycle
- **Status**: TODO
- **Priority**: P1
- **Phase**: 1
- **Depends**: T-001
- **Description**: `ghostty_app_t` のシングルトン管理。`ghostty_runtime_config_s.wakeup_cb` を設定し、`DispatchQueue.main.async { ghostty_app_tick(app) }` を呼ぶ。
- **Acceptance Criteria**:
  - [ ] `GhosttyApp.shared.app` が起動時に非 nil
  - [ ] deinit 時に `ghostty_app_free()` が呼ばれる（クラッシュなし）
  - [ ] wakeup_cb が定期的に呼ばれることをログで確認

### T-003 — GhosttyTerminalView.swift — NSView + Metal + Resize + HiDPI
- **Status**: TODO
- **Priority**: P1
- **Phase**: 1
- **Depends**: T-002
- **Description**: libghostty surface を Metal で描画する NSView。CAMetalLayer、HiDPI スケール対応、resize ハンドリング。
- **Acceptance Criteria**:
  - [ ] `makeBackingLayer()` が `CAMetalLayer` を返す
  - [ ] `layout()` で `ghostty_surface_set_size()` に正しい pixel サイズが渡る（backingScaleFactor 適用）
  - [ ] `triggerDraw()` が `ghostty_surface_draw()` を呼ぶ
  - [ ] ウィンドウリサイズ時に surface サイズが更新される

### T-004 — GhosttyInput.swift — NSEvent → ghostty_input_key_s + NSTextInputClient IME
- **Status**: TODO
- **Priority**: P1
- **Phase**: 1
- **Depends**: T-003
- **Description**: キーボード入力変換と IME サポート。NSTextInputClient プロトコル実装。
- **Acceptance Criteria**:
  - [ ] 英数字・記号の入力が PTY に届く
  - [ ] Enter、Backspace、矢印キー、Ctrl+C が正常動作
  - [ ] 日本語 IME でひらがな入力・変換確定ができる
  - [ ] IME 候補ウィンドウが正しい位置（カーソル付近）に表示される
  - [ ] `firstRect(forCharacterRange:actualRange:)` が実装されている

### T-005 — HelloWorld 統合確認
- **Status**: TODO
- **Priority**: P1
- **Phase**: 1
- **Depends**: T-002, T-003, T-004
- **Description**: `$SHELL` が GPU レンダリングされ、基本操作ができることを手動確認する。
- **Acceptance Criteria**:
  - [ ] シェルプロンプトが表示される
  - [ ] 文字入力・Enter・Ctrl+C が動作する
  - [ ] ウィンドウリサイズに追随する
  - [ ] HiDPI（Retina）で鮮明に描画される
  - [ ] 日本語 IME で候補ウィンドウが正しい位置に出る

---

## Phase 2: Sidebar UI Port

### T-006 — AppViewModel.swift port from POC
- **Status**: TODO
- **Priority**: P1
- **Phase**: 2
- **Description**: POC の AppViewModel を agtmux daemon 対応に移植。Go daemon 接続 → AgtmuxDaemonClient (agtmux CLI) に変更。
- **Acceptance Criteria**:
  - [ ] `AppViewModel` が `ObservableObject` として動作する
  - [ ] `@Published var panes: [AgtmuxPane]` がダミーデータで populated される
  - [ ] `isOffline: Bool` が存在する
  - [ ] `statusFilter: StatusFilter` が切り替え可能
  - [ ] `filteredPanes` が StatusFilter に従ってフィルタリングされる

### T-007 — Sidebar UI port (SidebarView + SessionRowView + FilterBarView)
- **Status**: TODO
- **Priority**: P1
- **Phase**: 2
- **Depends**: T-006
- **Description**: POC からサイドバー UI を移植。SidebarView、SessionRowView、FilterBarView の3コンポーネント。
- **Acceptance Criteria**:
  - [ ] SidebarView に pane 一覧がスクロールリストで表示される
  - [ ] SessionRowView に activity_state に対応した色・アイコンが表示される
  - [ ] SessionRowView に conversation_title が表示される
  - [ ] FilterBarView で All / Managed / Attention タブが切り替え可能

### T-008 — CockpitView.swift — HSplitView レイアウト統合
- **Status**: TODO
- **Priority**: P1
- **Phase**: 2
- **Depends**: T-005, T-007
- **Description**: サイドバー + ターミナルを横並びで表示する root view。HSplitView + NSViewRepresentable で統合。
- **Acceptance Criteria**:
  - [ ] ウィンドウにサイドバーとターミナルが並んで表示される
  - [ ] サイドバーのリサイズが可能
  - [ ] TerminalPanel が GhosttyTerminalView を正しくラップしている

---

## Phase 3: Daemon Integration

### T-009 — AgtmuxDaemonClient.swift — agtmux CLI wrapper
- **Status**: TODO
- **Priority**: P1
- **Phase**: 3
- **Description**: `agtmux json` CLI を subprocess 実行して JSON を取得・パース。daemon 未起動時は DaemonError.daemonUnavailable。
- **Acceptance Criteria**:
  - [ ] `fetchSnapshot()` が agtmux daemon 起動中に正常データを返す
  - [ ] daemon 未起動時は `DaemonError.daemonUnavailable` を throw する（クラッシュしない）
  - [ ] `AgtmuxSnapshot` / `AgtmuxPane` が正しく decode される
  - [ ] `socketPath` が設定可能

### T-010 — pane 選択 → tmux attach surface 切り替え
- **Status**: TODO
- **Priority**: P1
- **Phase**: 3
- **Depends**: T-008, T-009
- **Description**: サイドバーで pane を選択するとターミナルがその pane を表示する。`tmux attach-session` を surface のコマンドとして実行。
- **Acceptance Criteria**:
  - [ ] サイドバーで pane を選択するとターミナルが切り替わる
  - [ ] 旧 surface が適切に解放される（メモリリークなし）
  - [ ] tmux セッションが存在しない pane を選択した際にエラーが適切に処理される

### T-011 — agent state リアルタイム表示
- **Status**: TODO
- **Priority**: P1
- **Phase**: 3
- **Depends**: T-009, T-010
- **Description**: activity_state が1秒ごとに更新され、サイドバーの色・アイコンに反映される。conversation_title も表示。
- **Acceptance Criteria**:
  - [ ] `running` → 緑のインジケーター
  - [ ] `waiting_approval` / `waiting_input` → 黄/オレンジのインジケーター
  - [ ] `idle` → グレー
  - [ ] `error` → 赤
  - [ ] `conversation_title` がサイドバーに表示される
  - [ ] 状態変化が3秒以内にサイドバーに反映される
  - [ ] Claude Code を実際に動かして手動確認済み

---

## Phase 4: Polish [Post-MVP]

### T-012 — マルチサーフェス（タブ切り替え）
- **Status**: TODO
- **Priority**: P2
- **Phase**: 4
- **Description**: 複数 pane を同時に表示するタブ UI。

### T-013 — キーボードショートカット
- **Status**: TODO
- **Priority**: P2
- **Phase**: 4
- **Description**: `Cmd+1`〜`Cmd+9` などで pane 切り替え。

### T-014 — libghostty public API 移行
- **Status**: TODO
- **Priority**: P3
- **Phase**: 4
- **Description**: libghostty-full public API リリース後、internal API の使用を廃止して公式 API に移行する。
