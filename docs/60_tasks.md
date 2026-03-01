# Task Board

## Phase 0: Build Infrastructure

### T-000 — Ghostty API サーベイ（確認済み 2026-02-28）
- **Status**: DONE
- **Priority**: P0
- **Phase**: 0
- **Description**: `ghostty.h` の公開 API を調査し、Swift バインディングに必要な型・関数を確認する。
- **Acceptance Criteria**:
  - [x] `ghostty_surface_config_s` の全フィールドを確認（`platform_tag`, `platform` union, `command: const char*`, `scale_factor` など）
  - [x] `ghostty_platform_macos_s.nsview` が platform union 経由であることを確認
  - [x] `wakeup_cb` の C シグネチャ（`void (*)(void*)`）を確認
  - [x] `ghostty_surface_key` が `bool`（consumed フラグ）を返すことを確認
  - [x] `ghostty_surface_ime_point` による IME 位置取得 API を確認
- **Notes**: `docs/40_design.md` の `ghostty_surface_config_s` 正確な API セクションに記録済み。

---

### T-001 — GhosttyKit.xcframework ビルド環境構築
- **Status**: DONE
- **Priority**: P0 (blocks everything)
- **Phase**: 0
- **Depends**: T-000
- **Description**: Ghostty リポジトリを vendor/ に追加し、`zig build xcframework` で GhosttyKit.xcframework を生成。Package.swift で binaryTarget として参照する。
- **Acceptance Criteria**:
  - [x] Ghostty ソースが vendor/ghostty/ に git clone されている（submodule 不採用、ADR-20260228b）
  - [x] `cd vendor/ghostty && zig build -Demit-xcframework=true` が成功する（correct flag は `xcframework` ではなく `-Demit-xcframework=true`）
  - [x] GhosttyKit.xcframework が Package.swift の binaryTarget で参照されている
  - [x] `build.zig` / `pkg/macos/build.zig` を参照して必要な linker flags を確定し Package.swift に記載済み（Metal, MetalKit, QuartzCore, CoreGraphics, IOSurface, CoreText, CoreFoundation, CoreVideo, AppKit, Foundation, Carbon, UserNotifications, UniformTypeIdentifiers, iconv）
  - [x] `.gitattributes` に `GhosttyKit/**` の Git LFS 追跡設定が追加されている
  - [x] `git lfs ls-files` で xcframework が LFS 追跡されていることを確認（全 10 ファイル追跡済み）
  - [x] `module.modulemap` が生成され Swift から `import GhosttyKit` できる（xcframework に自動含有）
  - [x] `scripts/build-ghosttykit.sh` が作成されている
  - [x] `swift build` がエラーなしで完了する（Build complete! 2.16s）
  - [x] `ghostty_app_new` シンボルが解決される（`_ghostty_app_new T` 確認済み）
  - [x] macOS entitlements / App Sandbox 設定の要否を確認した（**App Sandbox 不要** — Ghostty 本体も Debug/Release ともに無効。tmux spawn / daemon socket アクセスのため Sandbox は無効で運用）
- **Notes**:
  - zig 0.14.1 (brew install zig@0.14)。build コマンドは `zig build xcframework` ではなく `zig build -Demit-xcframework=true`
  - iterm2_themes 依存が 404 → build.zig.zon の URL を最新リリースに更新が必要（2026-02-28 時点での対処済み）
  - Metal Toolchain 要インストール: `xcodebuild -downloadComponent MetalToolchain`
  - xcframework 出力先は `vendor/ghostty/macos/GhosttyKit.xcframework`（`zig-out/` ではない）
  - xcframework は static lib 形式（`libghostty.a` を直接含む、`.framework` バンドルではない）
  - `vendor/ghostty/` は .gitignore 除外。`scripts/build-ghosttykit.sh` で再ビルド手順を管理。

---

## Phase 1: Terminal Core

### T-002 — GhosttyApp.swift — ghostty_app_t lifecycle
- **Status**: DONE
- **Priority**: P1
- **Phase**: 1
- **Depends**: T-001
- **Description**: `ghostty_app_t` のシングルトン管理。`ghostty_runtime_config_s.wakeup_cb` を設定し、`DispatchQueue.main.async { ghostty_app_tick(app) }` を呼ぶ。
- **Acceptance Criteria**:
  - [x] `GhosttyApp.shared.app` が起動時に非 nil
  - [x] deinit 時に `ghostty_app_free()` が呼ばれる（クラッシュなし）
  - [x] wakeup_cb が `@convention(c)` クロージャとして実装（キャプチャなし）
- **Notes**: `ghostty_surface_config_s` に `context` フィールドは存在しない（design doc の記述誤り）。実際のフィールドは header から確認して実装。

### T-003 — GhosttyTerminalView.swift — NSView + Metal + Resize + HiDPI
- **Status**: DONE
- **Priority**: P1
- **Phase**: 1
- **Depends**: T-002
- **Description**: libghostty surface を Metal で描画する NSView。CAMetalLayer、HiDPI スケール対応、resize ハンドリング。
- **Acceptance Criteria**:
  - [x] `makeBackingLayer()` が `CAMetalLayer` を返す
  - [x] `layout()` で `ghostty_surface_set_size()` に正しい pixel サイズが渡る（backingScaleFactor 適用）
  - [x] `triggerDraw()` が `ghostty_surface_draw()` を呼ぶ
  - [x] `attachSurface()` を2回連続で呼んでもクラッシュしない（旧 surface の free + 新 surface の付け替え）
  - [x] `ghostty_surface_mouse_button` のシグネチャ確認（state, button, mods の順 — design doc と逆順）
  - [x] `ghostty_surface_mouse_pos` は 4 引数（x, y, mods）— design doc の記述と相違
- **Notes**: CAMetalLayer ownership は libghostty 側（nsview から内部で保持）。

### T-004 — GhosttyInput.swift — NSEvent → ghostty_input_key_s + NSTextInputClient IME
- **Status**: DONE
- **Priority**: P1
- **Phase**: 1
- **Depends**: T-003
- **Description**: キーボード入力変換と IME サポート。NSTextInputClient プロトコル実装。
- **Acceptance Criteria**:
  - [x] `GhosttyInput.toGhosttyKey()` 実装（完全 keyCode マップ — Ghostty 本家から移植）
  - [x] `GhosttyInput.toMods()` 実装（sided modifier flags 含む）
  - [x] `GhosttyInput.toScrollMods()` 実装
  - [x] `firstRect(forCharacterRange:actualRange:)` 実装
  - [x] `ghostty_input_scroll_mods_t` は `typedef int`（bitmask）と確認
  - [x] `ghostty_input_key_s.keycode` は `uint32_t`（Mac keyCode をそのまま渡す — Ghostty 本家と同じ）
- **Notes**: `keyCodeMap` は定義済みだが未使用（ghostty backend が内部変換する）。Post-MVP で削除またはリファクタリング予定。

### T-005 — HelloWorld 統合確認
- **Status**: DONE (手動確認は T-005 実機テストとして別途)
- **Priority**: P1
- **Phase**: 1
- **Depends**: T-002, T-003, T-004
- **Description**: `$SHELL` が GPU レンダリングされ、基本操作ができることをコンパイルレベルで確認。手動テストは実機起動時。
- **Acceptance Criteria**:
  - [x] NSApplication ベースの HelloWorld main.swift 作成
  - [x] `swift build` が通り 60MB arm64 バイナリが生成される
  - [x] `ghostty_surface_set_focus` など全 API シンボルが解決
  - [ ] **手動確認**: シェルプロンプト表示・文字入力・Ctrl+C・リサイズ・IME（T-009 統合テスト時に実施）

---

## Phase 2: Sidebar UI Port

### T-006a — DaemonModels.swift — AgtmuxSnapshot / AgtmuxPane / StatusFilter
- **Status**: TODO
- **Priority**: P1
- **Phase**: 2
- **Description**: `agtmux json` の実際のスキーマに合わせた Codable モデル定義。
  POC の Go daemon スキーマとは異なる点に注意（`docs/20_spec.md` の JSON Schema 参照）。
- **Acceptance Criteria**:
  - [ ] `AgtmuxPane` が `pane_id`, `activity_state`, `conversation_title`, `presence`, `session_name`, `window_index`, `pane_index` を持つ（`pane_index` は MVP では使用しないが decode のために保持）
  - [ ] `AgtmuxSnapshot` が `{version: 1, panes: [...]}` を decode できる
  - [ ] `StatusFilter` enum（all / managed / attention / pinned）が定義されている
  - [ ] `AgtmuxPane.needsAttention` computed property が存在する
  - [ ] `AgtmuxPane.isPinned` は Post-MVP のため `false` 固定スタブとして実装する（JSON フィールドなし）

### T-006b — AgtmuxDaemonClient.swift — agtmux CLI wrapper
- **Status**: TODO
- **Priority**: P1
- **Phase**: 2
- **Depends**: T-006a
- **Description**: `agtmux json` CLI を async subprocess 実行して JSON を取得・パース。
  `docs/40_design.md` の AgtmuxDaemonClient 設計を実装する。
- **Acceptance Criteria**:
  - [ ] `fetchSnapshot()` が `terminationHandler` ベースの非同期実装
  - [ ] `AGTMUX_BIN` 環境変数 → PATH 検索の順で agtmux を解決する
  - [ ] daemon 未起動時に `DaemonError.daemonUnavailable` を throw する（クラッシュしない）
  - [ ] `socketPath` が設定可能

### T-006c — AppViewModel.swift — polling + state management
- **Status**: TODO
- **Priority**: P1
- **Phase**: 2
- **Depends**: T-006a, T-006b
- **Description**: `@MainActor ObservableObject` の AppViewModel。1秒ポーリング、isOffline フラグ、フィルタリング。
  POC の AppViewModel（4,911行）から UI ロジック部分のみ移植（Go daemon 接続コードは除外）。
- **Acceptance Criteria**:
  - [ ] `@Published var panes: [AgtmuxPane]` がダミーデータで populated される
  - [ ] `isOffline: Bool` が存在し、daemon 未起動時に `true` になる
  - [ ] `statusFilter: StatusFilter` が切り替え可能
  - [ ] `filteredPanes` が StatusFilter に従ってフィルタリングされる
  - [ ] `startPolling()` / `stopPolling()` が実装されている

### T-007 — Sidebar UI port (SidebarView + SessionRowView + FilterBarView)
- **Status**: TODO
- **Priority**: P1
- **Phase**: 2
- **Depends**: T-006c
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

### T-009 — daemon 統合テスト（実機接続確認）
- **Status**: TODO
- **Priority**: P1
- **Phase**: 3
- **Description**: T-006b で実装した `AgtmuxDaemonClient` を実際に動作している agtmux daemon に接続して動作確認する。
  T-006b はスタブ/ダミーデータで動作するが、T-009 で実 daemon との統合を検証する。
- **Acceptance Criteria**:
  - [ ] agtmux daemon 起動中に `fetchSnapshot()` が実際の pane データを返す
  - [ ] daemon 未起動時は `DaemonError.processError` を throw し、UI が isOffline = true になる
  - [ ] `AgtmuxSnapshot` / `AgtmuxPane` が実際の `agtmux json` 出力と一致する
  - [ ] `socketPath` が設定可能で、デフォルトが `~/.local/share/agtmux/daemon.sock` であることを agtmux-v5 の実装と照合して確認
- **Notes**: T-006b との違い: T-006b は実装（ダミーデータで単体テスト可）、T-009 は実環境での統合確認。

### T-010 — pane 選択 → tmux attach surface 切り替え
- **Status**: TODO
- **Priority**: P1
- **Phase**: 3
- **Depends**: T-008, T-009
- **Description**: サイドバーで pane を選択するとターミナルがその pane を表示する。
  `AppViewModel.selectPane()` は `selectedPane` の更新のみ行う。
  `TerminalPanel.Coordinator` が `$selectedPane` を観測し、`"tmux attach-session -t <sessionName:windowIndex>"` を
  `GhosttyApp.newSurface(command:)` に渡して surface を切り替える。
- **Acceptance Criteria**:
  - [ ] サイドバーで pane を選択するとターミナルが切り替わる
  - [ ] `tmux attach-session -t sessionName:windowIndex` で正しい window が表示される（複数 window があるセッションで確認）
  - [ ] 旧 surface が適切に解放される（`GhosttyApp.shared.releaseSurface` 呼び出し確認）
  - [ ] tmux セッションが存在しない pane を選択した際にエラーが適切に処理される
  - [ ] セッション名にスペースを含む場合もクォート処理で正常動作
  - [ ] surface 切り替えは Coordinator のみが行い、`selectPane()` は `selectedPane` の更新だけ
- **Notes**: pane 単位での viewport 制御は Phase 4+ で `tmux new-session -t` 方式に移行予定。

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
