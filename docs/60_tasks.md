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
- **Status**: DONE
- **Priority**: P1
- **Phase**: 2
- **Description**: `agtmux json` の実際のスキーマに合わせた Codable モデル定義。
  POC の Go daemon スキーマとは異なる点に注意（`docs/20_spec.md` の JSON Schema 参照）。
- **Acceptance Criteria**:
  - [x] `AgtmuxPane` が `pane_id`, `activity_state`, `conversation_title`, `presence`, `session_name`, `window_index`, `pane_index` を持つ（`pane_index` は MVP では使用しないが decode のために保持）
  - [x] `AgtmuxSnapshot` が `{version: 1, panes: [...]}` を decode できる
  - [x] `StatusFilter` enum（all / managed / attention / pinned）が定義されている
  - [x] `AgtmuxPane.needsAttention` computed property が存在する
  - [x] `AgtmuxPane.isPinned` は Post-MVP のため `false` 固定スタブとして実装する（JSON フィールドなし）

### T-006b — AgtmuxDaemonClient.swift — agtmux CLI wrapper
- **Status**: DONE
- **Priority**: P1
- **Phase**: 2
- **Depends**: T-006a
- **Description**: `agtmux json` CLI を async subprocess 実行して JSON を取得・パース。
  `docs/40_design.md` の AgtmuxDaemonClient 設計を実装する。
- **Acceptance Criteria**:
  - [x] `fetchSnapshot()` が `terminationHandler` ベースの非同期実装
  - [x] `AGTMUX_BIN` 環境変数 → PATH 検索の順で agtmux を解決する
  - [x] daemon 未起動時に `DaemonError.daemonUnavailable` を throw する（クラッシュしない）
  - [x] `socketPath` が設定可能

### T-006c — AppViewModel.swift — polling + state management
- **Status**: DONE
- **Priority**: P1
- **Phase**: 2
- **Depends**: T-006a, T-006b
- **Description**: `@MainActor ObservableObject` の AppViewModel。1秒ポーリング、isOffline フラグ、フィルタリング。
  POC の AppViewModel（4,911行）から UI ロジック部分のみ移植（Go daemon 接続コードは除外）。
- **Acceptance Criteria**:
  - [x] `@Published var panes: [AgtmuxPane]` がダミーデータで populated される
  - [x] `isOffline: Bool` が存在し、daemon 未起動時に `true` になる
  - [x] `statusFilter: StatusFilter` が切り替え可能
  - [x] `filteredPanes` が StatusFilter に従ってフィルタリングされる
  - [x] `startPolling()` / `stopPolling()` が実装されている

### T-007 — Sidebar UI port (SidebarView + SessionRowView + FilterBarView)
- **Status**: DONE
- **Priority**: P1
- **Phase**: 2
- **Depends**: T-006c
- **Description**: POC からサイドバー UI を移植。SidebarView、SessionRowView、FilterBarView の3コンポーネント。
- **Acceptance Criteria**:
  - [x] SidebarView に pane 一覧がスクロールリストで表示される
  - [x] SessionRowView に activity_state に対応した色・アイコンが表示される
  - [x] SessionRowView に conversation_title が表示される
  - [x] FilterBarView で All / Managed / Attention タブが切り替え可能

### T-008 — CockpitView.swift — HSplitView レイアウト統合
- **Status**: DONE
- **Priority**: P1
- **Phase**: 2
- **Depends**: T-005, T-007
- **Description**: サイドバー + ターミナルを横並びで表示する root view。HSplitView + NSViewRepresentable で統合。
- **Acceptance Criteria**:
  - [x] ウィンドウにサイドバーとターミナルが並んで表示される
  - [x] サイドバーのリサイズが可能
  - [x] TerminalPanel が GhosttyTerminalView を正しくラップしている

---

## Phase 3: Daemon Integration

### T-009 — daemon 統合テスト（実機接続確認）
- **Status**: DONE
- **Priority**: P1
- **Phase**: 3
- **Description**: T-006b で実装した `AgtmuxDaemonClient` を実際に動作している agtmux daemon に接続して動作確認する。
  T-006b はスタブ/ダミーデータで動作するが、T-009 で実 daemon との統合を検証する。
- **Acceptance Criteria**:
  - [x] `socketPath` のデフォルトを agtmux-v5 実装と照合（正しいデフォルト: `/tmp/agtmux-$USER/agtmuxd.sock`）
  - [x] `agtmux json` サブコマンドが v5 現行仕様であることを確認（T-139 CLI redesign、commit c1f6486）
  - [x] `agtmux json` 出力スキーマを実 daemon で確認: `{"version":1, "panes":[...]}`、`window_id: String`（"@250"形式）
  - [x] `DaemonModels.swift` の `window_index: Int` → `windowId: String` 修正（実フィールド: `window_id`）
  - [x] `DaemonModels.swift` の `pane_index: Int` を削除（実 JSON に存在しない）
  - [x] `AgtmuxDaemonClient` のデフォルト socketPath を修正
  - [x] agtmux daemon 起動中に `fetchSnapshot()` が実際の pane データを返す（生ソケット + 新バイナリで確認）
  - [x] daemon 未起動時は exit code 1 → `DaemonError.processError` → `isOffline = true`（確認済み）
  - [x] `AgtmuxDaemonClient.resolveBinaryURL()` に `~/go/bin`、`~/.cargo/bin`、`/usr/local/bin`、`/opt/homebrew/bin` フォールバック追加（macOS GUI 向け）
  - [x] `go/bin/agtmux` を v5 HEAD（be2dbba）からリビルド（`json` コマンド確認済み）
- **Notes**:
  - agtmux binary: `/Users/virtualmachine/go/bin/agtmux`（Feb 26 ビルド）は `list-panes` コマンド。v5 HEAD（be2dbba 以降）は `json` コマンド。`json` を使用。
  - 実 daemon のデフォルト socketPath: `/tmp/agtmux-$USER/agtmuxd.sock`（macOS、XDG_RUNTIME_DIR 未設定時）
  - `window_id` フォーマット: `"@250"` (tmux window ID) — tmux での指定: `attach-session -t session:@250`

### T-010 — pane 選択 → tmux attach surface 切り替え
- **Status**: DONE
- **Priority**: P1
- **Phase**: 3
- **Depends**: T-008, T-009
- **Description**: サイドバーで pane を選択するとターミナルがその pane を表示する。
- **Acceptance Criteria**:
  - [x] サイドバーで pane を選択するとターミナルが切り替わる
  - [x] `tmux attach-session -t sessionName:@windowId` で正しい window が表示される
  - [x] 旧 surface が適切に解放される
  - [x] セッション名にスペースを含む場合もクォート処理で正常動作（`shellEscaped()` 実装済み）
  - [x] surface 切り替えは Coordinator のみが行い、`selectPane()` は `selectedPane` の更新だけ
- **Notes**:
  - ghostty_config_finalize 未呼び出し → crash を修正（commit 91d4559）
  - action_cb / read_clipboard_cb 等の non-optional Zig fn ptr を nil 設定 → crash を修正（commit b077b7b）
  - scroll 方向反転バグを修正（commit 805d238）: negation 除去 + trackpad 2x multiplier

### T-011 — agent state リアルタイム表示
- **Status**: DONE
- **Priority**: P1
- **Phase**: 3
- **Depends**: T-009, T-010
- **Description**: activity_state が1秒ごとに更新され、サイドバーの色・アイコンに反映される。conversation_title も表示。
- **Acceptance Criteria**:
  - [x] `running` → 緑のインジケーター
  - [x] `waiting_approval` / `waiting_input` → 黄/オレンジのインジケーター
  - [x] `idle` → グレー
  - [x] `error` → 赤
  - [x] `conversation_title` がサイドバーに表示される
  - [x] 状態変化が1秒以内にサイドバーに反映される（ポーリング周期）
- **Notes**: ユーザー確認済み（2026-03-01）。`activity_state: null` の pane は `.unknown` として扱う（custom init で decodeIfPresent 使用）。

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

---

## Phase 3b: SSH Remote tmux

### T-015 — RemoteHostsConfig.swift — hosts.json ローダー
- **Status**: DONE
- **Priority**: P1
- **Phase**: 3b
- **Notes**: `Sources/AgtmuxTerm/RemoteHostsConfig.swift` として実装済み（2026-03-01）

### T-016 — DaemonModels.swift — source フィールド追加
- **Status**: DONE
- **Priority**: P1
- **Phase**: 3b
- **Notes**: `AgtmuxPane.source` + composite id + `tagged()` factory 実装済み

### T-017 — AgtmuxDaemonClient.swift — ローカル pane に source タグ付け
- **Status**: DONE
- **Priority**: P1
- **Phase**: 3b

### T-018 — RemoteTmuxClient.swift — SSH + tmux list-panes パーサ
- **Status**: DONE
- **Priority**: P1
- **Phase**: 3b
- **Notes**: `Sources/AgtmuxTerm/RemoteTmuxClient.swift` として実装済み

### T-019 — AppViewModel.swift — マルチソースポーリング
- **Status**: DONE
- **Priority**: P1
- **Phase**: 3b
- **Notes**: `offlineHosts: Set<String>` + `panesBySource` + `withTaskGroup` 並行ポーリング実装済み

### T-020 — SidebarView.swift — ホスト別セクション表示
- **Status**: DONE
- **Priority**: P1
- **Phase**: 3b

### T-021 — CockpitView.swift — マルチトランスポートコマンドビルダー
- **Status**: DONE
- **Priority**: P1
- **Phase**: 3b

---

### T-025 — バグ修正 + UI細改善
- **Status**: DONE
- **Priority**: P1
- **Phase**: 5
- **Description**: スクリーンショット確認後の修正。
- **Changes**:
  - `primaryLabel`: managed pane の title fallback を `conversationTitle ?? provider?.rawValue ?? paneId` に変更（`%280` → `"claude"` 表示）。NOTE: managed pane では `currentCmd` は使わない（Claude Code は Node.js プロセスのため `node` が返り非有益）
  - age 表示: running 状態では非表示、idle/error/waiting のみ表示（「idle になってから X 時間」の意味を明確化）
  - `ProviderIcon`: SF Symbol から colored rounded rectangle + 頭文字バッジに変更（C/✦/G/P）
  - `attachCommand`: `tmux attach-session -t session:@window` → `tmux attach-session -t %paneId` に変更（直接 pane ターゲット）
  - `shellEscaped()` helper は不要になったため削除

---

## Phase 5: GUI Redesign (agtmux v5 対応)

### T-022 — DaemonModels.swift — agtmux v5 スキーマ対応
- **Status**: DONE
- **Priority**: P1
- **Phase**: 5
- **Description**: agtmux v5 の新 JSON フィールドを追加。`presence` のセマンティクス変更（"managed"/"unmanaged"）に対応。
- **Acceptance Criteria**:
  - [x] `AgtmuxPane.Provider` enum: `claude | codex | gemini | copilot`
  - [x] `AgtmuxPane.EvidenceMode` enum: `deterministic | heuristic | none`
  - [x] `AgtmuxPane.PanePresence` enum: `managed | unmanaged`（`presence: String?` を置き換え）
  - [x] `AgtmuxPane` に新フィールド追加: `provider: Provider?`, `evidenceMode: EvidenceMode`, `gitBranch: String?`, `currentCmd: String?`, `updatedAt: Date?`, `ageSecs: Int?`
  - [x] `cwd: String?` → `currentPath: String?`（CodingKey: `"current_path"`）
  - [x] `RawPane` の CodingKeys 更新（`current_path`, `git_branch`, `current_cmd`, `evidence_mode`, `updated_at`, `age_secs`）
  - [x] `AgtmuxSnapshot.decode` でフィールドを正しくマップ
  - [x] `tagged()` factory が全新フィールドを伝播する
  - [x] `AgtmuxPane.isManaged: Bool { presence == .managed }` computed property 追加
  - [x] `AppViewModel.filteredPanes` の `.managed` フィルタを `$0.isManaged` に修正

### T-023 — AppViewModel.swift — panesBySession 追加
- **Status**: DONE
- **Priority**: P1
- **Phase**: 5
- **Depends**: T-022
- **Description**: セッション別グループ表示用の computed property を追加。
- **Acceptance Criteria**:
  - [x] `SessionGroup` struct: `id`, `source`, `sessionName`, `panes: [AgtmuxPane]`, `representativeBranch`
  - [x] `panesBySession: [(source: String, sessions: [SessionGroup])]` computed property 実装
    - source 順: "local" 先頭、remote アルファベット順
    - session 内 pane は `paneId` でソート
  - [x] `representativeBranch`: managed pane 優先で非 nil な最初の gitBranch を返す

### T-024 — SidebarView.swift — by-session リデザイン
- **Status**: DONE
- **Priority**: P1
- **Phase**: 5
- **Depends**: T-022, T-023
- **Description**: セッション別表示にリデザイン。provider アイコン・age 表示・hover tooltip を追加。
  window grouping なし。source header（ホスト名）の下にセッションブロックを並べる。
- **Acceptance Criteria**:
  - [x] `SessionBlockView`: セッションヘッダー（sessionName + gitBranch）+ flat pane 一覧
  - [x] `SessionRowView` リデザイン（state indicator + primaryLabel + provider icon + age）
  - [x] `FreshnessLabel`: `ageSecs` → "Xs" / "Xm" / "Xh"、常にグレー（色変化なし）
  - [x] hover tooltip（`.help()`）: gitBranch / currentPath / evidenceMode / currentCmd
  - [x] `SourceHeaderView` を維持（ホスト名ヘッダー、offline ドット）
  - [x] `SidebarView.body` が `panesBySession` を使って SessionBlockView を ForEach

---

### T-026 — UI アイコン刷新（state indicator + provider icon）
- **Status**: DONE
- **Priority**: P1
- **Phase**: 5
- **Description**: state indicator をアイコン化（running=スピナー, waiting=手/省略記号, error=バツ, idle/unmanaged=なし）。provider icon を実際のブランドロゴ SVG に変更。session ヘッダーにフォルダアイコン追加。
- **Changes**:
  - `SpinnerView`: 新規。回転アニメーション付き部分円弧（running 状態用）
  - `stateIndicator`: idle / unknown / unmanaged は非表示。running=緑スピナー、waitingApproval=`hand.raised.fill`(orange)、waitingInput=`ellipsis.circle.fill`(yellow)、error=`xmark.circle.fill`(red)
  - `SessionBlockView`: session 名の前に `folder.fill` アイコン追加
  - `ProviderIcon`: NSImage でバンドル内 SVG を読み込む方式に変更（macOS ネイティブ SVG 描画）
    - `icon-claude.svg`: 8本腕アスタリスク（orange #D97749）
    - `icon-openai.svg`: OpenAI スワールロゴ（simple-icons より、currentColor/template）
    - `icon-gemini.svg`: Gemini 4尖星（simple-icons より、blue gradient）
    - `icon-copilot.svg`: GitHub Copilot ゴーストアイコン（simple-icons より、currentColor/template）
  - `Package.swift`: `.process("Resources")` 追加
  - codex/copilot は `isTemplate = true` → ダーク/ライトモード自動追従
- **Build**: `swift build` → Build complete!
