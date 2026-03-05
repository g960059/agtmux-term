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

---

## Phase 6: Ghostty + tmux Native Sync

> 設計確定: 2026-03-02

### T-027 — Spike A: 複数 surface 同時表示
- **Status**: DONE (2026-03-02)
- **Priority**: P0 (blocks T-034~)
- **Description**: 2つの GhosttyTerminalView を並べて crash しないか確認。ghostty_surface_set_occlusion の動作確認も含む。
- **Acceptance Criteria**:
  - [x] HSplitView に2つの surface を並べて両方が正常レンダリングされる
  - [x] `ghostty_surface_set_occlusion(surface, false)` でレンダリングが背面化する（SurfacePool.backgrounded の前提）
- **Notes**:
  - `ghostty_surface_set_occlusion(surface, visible: Bool)`: `false` = occluded / backgrounded、`true` = visible。Ghostty 本家と同じセマンティクス。
  - occlusion=false 時、renderer thread が QoS `.utility` に降格、Metal DisplayLink 停止。PTY 接続は維持。
  - `SurfacePool.background()` では `ghostty_surface_set_occlusion(surface, false)` を使う。

### T-028 — Spike B: linked session 独立表示
- **Status**: DONE
- **Priority**: P0 (blocks everything) — **Phase 3 最高リスク**
- **Description**: tmux linked session 経由で2つの独立した surface が異なる pane を表示できるか検証。
- **Acceptance Criteria**:
  - [x] linked session 作成コマンドで独立した tmux client が得られる
  - [x] 2つの surface が同じ session の異なる pane を独立表示できる
  - [x] pane フォーカスが session A に伝播しない（linked session の独立性確認）
- **Notes**:
  - `tmux new-session -d -s "agtmux-{uuid}" -t "parent"` で session group が作成される
  - 同グループの各セッションは **独立した current-window** を持つ → 2つの surface が異なる window を表示できる（互いに干渉しない）
  - **active pane は window レベルで共有**: 同一 window を複数 surface が表示する場合、active pane は共有される（許容範囲 — 各 AI エージェントは通常別 window にいる）
  - `tmux select-window -t "agtmux-{uuid}:WINDOW_INDEX"` で surface ごとに独立した window 選択が可能
  - `tmux switch-client -c CLIENT -t %PANEID` で pane ID から直接 window 移動可能
  - 検証コマンド例: `tmux new-session -d -s b2 -t "vm agtmux" && tmux new-session -d -s b3 -t "vm agtmux" && tmux select-window -t b2:2 && tmux select-window -t b3:3 → b2=pane%587, b3=pane%588 (独立)`

### T-029 — Spike C: tmux control mode イベント観察
- **Status**: DONE
- **Priority**: P0 (blocks T-039)
- **Description**: `tmux -C attach-session` の実際のイベントフォーマットを観察。
- **Acceptance Criteria**:
  - [x] %layout-change のフォーマット確認
  - [x] %pane-exited / %window-add / %window-close の確認
  - [x] list-panes との組み合わせで何が取れるか確認
- **Notes** (実測値 — tmux 3.6a):
  - **sync レスポンス**: `%begin TIMESTAMP CMD_ID 1` … content … `%end TIMESTAMP CMD_ID 1`
  - **async イベント**: `%begin TIMESTAMP CMD_ID 0` / `%end TIMESTAMP CMD_ID 0` (empty)
  - `%session-changed $SESSION_ID SESSION_NAME` — クライアント接続時
  - `%session-window-changed $SESSION_ID @WINDOW_ID` — current window 変更
  - `%window-pane-changed @WINDOW_ID %PANE_ID` — active pane 変更
  - `%layout-change @WINDOW_ID LAYOUT VISIBLE_LAYOUT [*]` — レイアウト変更。`*`=current window
  - `%window-add @WINDOW_ID` — 新 window 作成
  - `%window-renamed @WINDOW_ID NAME` — window 名変更
  - `%unlinked-window-close @WINDOW_ID` — window 削除（linked session context）
  - `%output %PANE_ID TEXT` — pane 出力（--control-mode-output オプション時）
  - **layout 文字列フォーマット** (例: `85e9,80x24,0,0[80x12,0,0,596,80x11,0,13,597]`):
    - `CHECKSUM,WxH,X,Y,PANE_ID` — single pane（例: `2cee,80x24,0,0,599`）
    - `CHECKSUM,WxH,X,Y[P1,P2]` — horizontal split（`[...]`）
    - `CHECKSUM,WxH,X,Y{P1,P2}` — vertical split（`{...}`）
    - pane ID は `%` なしの数値のみ（`599` は `%599`）
  - `list-panes -F '#{pane_id} #{pane_width} #{pane_height} #{pane_top} #{pane_left}'` → `%601 40 24 0 0`
  - `list-windows -F '#{window_id} #{window_index} #{window_name} #{window_panes} #{window_layout}'` → `@510 1 zsh 1 ece4,80x24,0,0,604`

### T-030 — WindowGroup + SessionGroup 拡張
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-027, T-028, T-029
- **Description**: WindowGroup 構造体追加、SessionGroup に windows フィールド追加、RemoteTmuxClient の format 文字列に window_index/window_name を追加。
- **Acceptance Criteria**:
  - [x] `WindowGroup` struct 実装（source, sessionName, windowId, windowIndex?, windowName?, panes）
  - [x] `SessionGroup.windows: [WindowGroup]` 追加（`panes` は後方互換 computed property）
  - [x] `AppViewModel.panesBySession` が4階層グループを返す
  - [x] RemoteTmuxClient の format 文字列に `#{window_id}`, `#{window_index}`, `#{window_name}` 追加

### T-031 — サイドバー 4 階層化
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-030
- **Description**: SidebarView を source → session → window → pane の4階層に変更。WindowBlockView, PaneRowView, WindowStateBadge 追加。
- **Acceptance Criteria**:
  - [x] SourceHeaderView: source ヘッダー（右クリック → New Session）
  - [x] SessionBlockView: session ヘッダー（右クリック → New Window / Kill Session）
  - [x] WindowBlockView: window ヘッダー折りたたみ可（右クリック → New Pane / Kill Window）
  - [x] PaneRowView: pane 行（右クリック → Kill Pane）
  - [x] WindowStateBadge: running 数・attention 数バッジ
- **Notes**: 右クリックアクションは T-041 実装までスタブ（print ログのみ）

### T-032 — macOS 通知（NotificationManager）
- **Status**: TODO
- **Priority**: P1
- **Depends**: なし（T-030 と並行可）
- **Description**: UNUserNotificationCenter を使った通知実装。
- **Acceptance Criteria**:
  - [ ] waiting_approval / waiting_input / error 遷移時に通知発行
  - [ ] 30秒以内の重複通知を抑制
  - [ ] NSApplication.shared.isActive のとき通知しない
  - [ ] 通知クリック → AppViewModel.selectPane() で対象 pane を前面表示

### T-033 — Needs Attention バッジ
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-031
- **Description**: 上部固定セクション案を廃止。"Attention" フィルタタブの右上に青バッジ数字、session/window 行にも running/attention カウンターバッジを追加。
- **Acceptance Criteria**:
  - [x] "Attention" フィルタタブ右上に青いカプセルバッジ（attentionCount > 0 のみ表示）
  - [x] SessionBlockView ヘッダーに running(緑)/attention(青) カウンターバッジ
  - [x] WindowBlockView ヘッダーの WindowStateBadge に attention カウント追加
  - [x] AppViewModel.attentionCount 追加

### T-034 — BSP LayoutNode + WorkspaceStore
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-027, T-028
- **Description**: LayoutNode.swift, WorkspaceStore.swift の新規実装。
- **Acceptance Criteria**:
  - [x] `LayoutNode` indirect enum（Identifiable, Equatable, Codable, Sendable）
  - [x] `LeafPane`（linkedSession: LinkedSessionState enum）
  - [x] `SplitContainer`（setRatio() clamp メソッド付き）
  - [x] `LinkedSessionState` enum（creating/ready/failed）
  - [x] `SplitAxis` enum（horizontal/vertical）
  - [x] LayoutNode utilities: validateUniqueIDs(), replacing(leafID:depth:), splitLeaf(), removingLeaf()
  - [x] `WorkspaceStore` (@Observable, @MainActor): createTab, closeTab, switchTab, placePane (async), updateContainer(), updateLeaf(), removeLeaf()

### T-035 — WorkspaceArea + TabBarView + LayoutNodeView
- **Status**: DONE (2026-03-02)
- **Priority**: P2
- **Depends**: T-034
- **Description**: SwiftUI レイアウト層の実装。CockpitView を WorkspaceArea に切り替え。
- **Acceptance Criteria**:
  - [x] TabBarView: タブ一覧、Cmd+T/W、タブ追加/削除ボタン
  - [x] LayoutNodeView: LayoutNode を再帰的にレンダリング
  - [x] SplitContainerView: GeometryReader + DividerHandle (drag) + Opt+Cmd+Arrow (keyboard resize)
  - [x] GhosttyPaneTile: _GhosttyNSView NSViewRepresentable（LinkedSessionState に応じてローディング/エラー/surface）
  - [x] `main.swift` に WorkspaceStore 作成・inject 追加
  - [x] SidebarView の onSelect が workspaceStore.placePane() を呼ぶ
  - [x] `swift build` → Build complete!、アプリ起動確認
- **Notes**:
  - `onKeyPress` の `modifiers:` パラメータは存在しない。`phases: .down` でオーバーロード確定し、クロージャ内で `.modifiers.contains()` チェック。
  - DividerHandle: `onHover { _ in cursor.push() }` は pop なし（sticky cursor リスク）— Post-MVP で修正
  - placePane() は T-037 stub: `.creating` → `.ready(pane.paneId)` 即時遷移（tmux attach-session -t %PANEID）

### T-036 — SurfacePool
- **Status**: DONE (2026-03-02)
- **Priority**: P2
- **Depends**: T-035
- **Description**: surface lifecycle 管理。active/backgrounded/pendingGC/defunct の状態遷移。
- **Acceptance Criteria**:
  - [x] LeafPane.id → ManagedSurface マッピング（dual index: paneID + linkedSession）
  - [x] pendingGC (5秒 grace period) → gc() で defunct 遷移（clearSurface() 経由）
  - [x] markDefunct(byPaneID:) + markDefunct(byLinkedSession:) デュアルインデックス
  - [x] gc() はタイマー駆動（pendingGC エントリ存在時のみ Timer 起動、なくなれば停止）
  - [x] _GhosttyNSView が register/activate/background/release を SurfacePool 経由で呼ぶ
  - [x] dismantleNSView が MainActor.assumeIsolated で SurfacePool.release() を呼ぶ
  - [x] GhosttyTerminalView.clearSurface() 追加（SurfacePool gc 経由の surface 解放、deinit の二重解放を防ぐ）
  - [x] swift build → Build complete!

### T-037 — LinkedSessionManager
- **Status**: DONE (2026-03-02)
- **Priority**: P2
- **Depends**: T-028
- **Description**: tmux linked session の作成・破棄。
- **Acceptance Criteria**:
  - [x] `TmuxCommandRunner.shared.run(_:source:)` actor 実装（local / SSH 分岐）
  - [x] `TmuxCommandError` enum（tmuxNotFound/permissionDenied/sshFailed/failed/timeout）
  - [x] `LinkedSessionManager.shared.createSession(parentSession:windowId:source:) async throws -> String`
    - `new-session -d -s agtmux-{uuid} -t parentSession`
    - `select-window -t linked:@windowId`
    - Returns linked session name
  - [x] `destroySession(name:source:) async` — best-effort kill-session
  - [x] `WorkspaceStore.placePane()` が T-037 スタブを LinkedSessionManager に置き換え
  - [x] `.creating` 中はスピナー overlay → `.ready(linkedName)` → surface 接続 → `.failed(err)` → エラー overlay
  - [x] CLI 検証: `new-session` + `select-window` + `kill-session` PASS（agtmux-{uuid}）
  - [x] swift build → Build complete!

### T-038 — Mode A: Cross-session Compose
- **Status**: DONE (2026-03-02)
- **Priority**: P2
- **Depends**: T-036, T-037
- **Description**: サイドバー pane クリック → WorkspaceTab の focused leaf に表示。session をまたいだ配置が可能。
- **Acceptance Criteria**:
  - [x] pane クリック → placePane() async → LinkedSessionManager.createSession() → surface 表示（T-035+T-037 で完成）
  - [x] 異なる session の pane を同じタブに並べられる（BSP LayoutNode により任意の session を並置可能）
  - [x] surface resize → tmux resize 同期: `ghostty_surface_set_size` が TIOCSWINSZ を PTY に送信 → tmux が自動 resize-pane。明示的 `tmux resize-pane` 呼び出し不要（linked session は single client のため tmux が client size をそのまま採用）

### T-039 — TmuxControlMode + TmuxCommandRunner + TmuxCommandError
- **Status**: DONE (2026-03-02)
- **Priority**: P2
- **Depends**: T-029
- **Description**: TmuxControlMode (AsyncStream + reconnect) + TmuxCommandRunner (共有 actor) + TmuxCommandError。
- **Acceptance Criteria**:
  - [x] `TmuxCommandRunner.shared.run(_:source:)` actor 実装（T-037 で既実装）
  - [x] `TmuxCommandError` typed enum（tmuxNotFound/permissionDenied/sshFailed/failed/timeout）
  - [x] `ControlModeEvent` enum（layoutChange/windowPaneChanged/windowAdd/windowClose/sessionChanged/sessionWindowChanged/output/commandResponse）
  - [x] `TmuxControlMode` actor: `events: AsyncStream<ControlModeEvent>`
    - `start()` / `stop()` / `send(command:)`
    - `%begin…%end` ブロックを commandResponse にまとめる
    - 各非同期イベント（%layout-change 等）をパース
    - Pipe + Process で `tmux -C attach-session` を起動
  - [x] 指数バックオフ再接続: 1s→2s→4s→8s→16s (max 5 回) → .degraded
  - [x] connectionState: connected/reconnecting(attempt)/degraded/stopped
  - [x] swift build → Build complete!

### T-040 — Mode B: Within-window Sync
- **Status**: DONE (2026-03-02)
- **Priority**: P2
- **Depends**: T-038, T-039
- **Description**: window block クリック → tmux layout を BSP で再現。control mode で変更追従。
- **Acceptance Criteria**:
  - [x] window 右クリック "Open in Workspace" → `display-message -p '#{window_layout}'` → `TmuxLayoutConverter.convert()` → `LayoutNode` BSP → `WorkspaceStore.placeWindow()`
  - [x] `%layout-change` → `handleLayoutChange()` → `TmuxLayoutConverter.convert()` → `mergeLayout()` (既存 leafID・linkedSession 保持) → surface 追加/削除/リサイズ対応
  - [x] char → pixel 変換: BSP ratio は char 幅/高さの比率で計算するため pixel 変換不要（`SplitContainer.ratio = firstChildChars / totalChars`）
- **Notes**:
  - `TmuxLayoutConverter.swift` (NEW): recursive descent parser for `#{window_layout}` format (`{...}` = hsplit, `[...]` = vsplit). Multiple children (>2) folded right into binary SplitContainers.
  - `WorkspaceStore.placeWindow()`: fetchs layout → converts → sets tab root → creates linked sessions per leaf → starts TmuxControlMode monitoring.
  - `WorkspaceStore.handleLayoutChange()`: re-converts on `%layout-change` event, merges old leaf IDs via `mergeLayout()` to avoid surface recreation.
  - `WorkspaceStore.trackedWindows`, `layoutMonitorTasks`: track active windows for layout re-conversion.
  - `SidebarView.WindowBlockView`: added "Open in Workspace" context menu item → `Task { await workspaceStore.placeWindow(window) }`.
  - swift build → Build complete!

### T-041 — TmuxManager（tmux 管理操作）
- **Status**: DONE (2026-03-02)
- **Priority**: P1
- **Depends**: T-031, T-039
- **Description**: session/window/pane の作成・削除。TmuxCommandRunner を使用。
- **Acceptance Criteria**:
  - [x] createSession(source:viewModel:) — NSAlert でセッション名入力 → `new-session -d -s name`
  - [x] killSession(_:source:viewModel:) — TmuxControlModeRegistry.safeKillSession 経由
  - [x] createWindow(sessionName:source:viewModel:) — `new-window -t session`
  - [x] killWindow(_:sessionName:source:viewModel:) — `kill-window -t session:@windowId`
  - [x] createPane(_:splitAxis:source:viewModel:) — `split-window (-h/-v) -t paneId`
  - [x] killPane(_:source:viewModel:) — `kill-pane -t paneId`
  - [x] 全操作後に `viewModel.fetchAll()` 即実行
  - [x] SidebarView の右クリックスタブが TmuxManager を呼ぶように更新
  - [x] AppViewModel.fetchAll() を internal に変更
  - [x] swift build → Build complete!

### T-042 — TmuxControlModeRegistry
- **Status**: DONE (2026-03-02)
- **Priority**: P1
- **Depends**: T-039
- **Description**: TmuxControlMode のライフサイクル管理。safeKillSession() で kill 前に stop を保証。
- **Acceptance Criteria**:
  - [x] mode(for:source:) でインスタンスを管理（key: "source:sessionName"）
  - [x] startMonitoring(sessionName:source:) / stopMonitoring(sessionName:source:)
  - [x] safeKillSession(_:source:): TmuxControlMode.stop() → 50ms wait → kill-session の順序保証
  - [x] swift build → Build complete!

---

## Phase 6 Review Cycle (R1 → GO 取得まで)

### T-043 — Phase 6 Blocking fixes (Round 1 review 採択)
- **Status**: DONE (2026-03-03)
- **Priority**: P1
- **Depends**: T-034~T-042
- **Description**: 4並列レビュー（全員 NO_GO）の Blocking 指摘を採択・修正。
- **Changes applied**:
  - `TmuxControlModeRegistry.safeKillSession`: `stopMonitoring` (fire-and-forget) の代わりに `await m.stop()` を直接呼ぶ。50ms sleep 削除。TOCTOU 修正。
  - `WorkspaceStore.startLayoutMonitoring`: `tabIdx: Int` キャプチャ → `tabID: UUID` キャプチャ + `handleLayoutChange` でタブ再索引。stale index によるデータ破壊修正。
  - `TmuxControlMode.readLoop`: `availableData` + 10ms busy-poll → `FileHandle.AsyncBytes` push-based読み取り。行バッファリング追加。CPU 浪費解消。
  - `TmuxControlMode.send(command:)`: `handle.write(data)` (throws 無視) → `try handle.write(contentsOf: data)`。
  - `TmuxControlMode.events`: 多重 continuation fan-out パターン (addContinuation Task ＋ ObjectIdentifier struct 比較バグ) → `AsyncStream.makeStream()` で init 時に単一 continuation 生成。race 解消。
  - `WorkspaceArea.DividerHandle.onHover`: `cursor.push()` のみ → `hovering ? cursor.push() : NSCursor.pop()`。cursor stack 汚染修正。
  - `WorkspaceArea.SplitContainerView` / `DividerHandle`: global 座標渡し → `value.translation.width/height` + `dragStartRatio: CGFloat?` state。ratio 計算のミスマッチ修正。
  - `WorkspaceArea._GhosttyNSView.dismantleNSView`: `MainActor.assumeIsolated` → `Task { @MainActor in }`。非 MainActor からの呼び出しで crash しなくなる。
- **Build**: `swift build` → Build complete! (31.11s) ✅

### T-044 — ghostty_surface_new crash fix (nil window guard)
- **Status**: DONE (2026-03-03)
- **Priority**: P0
- **Description**: pane 選択時のクラッシュ修正。`ghostty_surface_new` は NSView が window hierarchy に挿入済みでないと CAMetalLayer アクセスで crash する。
- **Root cause**: `_GhosttyNSView.updateNSView` が `nsView.window == nil` のタイミングで `GhosttyApp.shared.newSurface()` を呼んでいた。
- **Fix**: `guard nsView.window != nil else { return }` を newSurface 呼び出し前に追加。currentCommand を更新しないまま return することで、次の SwiftUI layout pass で自動リトライ。
- **Build**: `swift build` → Build complete! ✅

### T-045 — SurfacePool pendingGC double-free edge case (follow-up)
- **Status**: TODO
- **Priority**: P2
- **Description**: `SurfacePool.register()` が `pendingGC` 状態のエントリを上書きする際、旧 view.surface を nil にしていないため GC タイマーが新 surface を free する edge case がある。Review Agent 3 の B-1 指摘。
- **Acceptance Criteria**:
  - [ ] `deregisterInternal` が pendingGC 状態エントリに対して `managed.view.clearSurface()` を呼ぶか、surface を nil にする
  - [ ] dismount → remount サイクルで double-free が起きない

### T-046 — GhosttyTerminalView deinit thread safety (follow-up)
- **Status**: TODO
- **Priority**: P2
- **Description**: `GhosttyTerminalView.deinit` が `GhosttyApp.shared.releaseSurface(for: self)` を呼ぶが、deinit は任意スレッドから実行される可能性があり `activeSurfaces (NSHashTable)` がスレッドアンセーフ。
- **Acceptance Criteria**:
  - [ ] `GhosttyTerminalView` に `@MainActor` 追加、または deinit を DispatchQueue.main に dispatch

### T-047 — Swift unit tests for TmuxLayoutConverter + LayoutNode
- **Status**: TODO
- **Priority**: P2
- **Description**: e2e testing 調査結果 (docs/research/e2e-testing.md) に基づく unit test 追加。
- **Acceptance Criteria**:
  - [ ] `Sources/AgtmuxTermCore/` 共有ライブラリターゲット作成（TmuxLayoutConverter, LayoutNode, AgtmuxPane を移動）
  - [ ] `Tests/AgtmuxTermCoreTests/` にテストターゲット追加
  - [ ] TmuxLayoutConverter: leaf, H-split, V-split, 3-pane right-fold, 欠損 pane, 不正入力の6ケース
  - [ ] LayoutNode: splitLeaf, removingLeaf, validateUniqueIDs の5ケース

### T-048 — GhosttyApp @MainActor isolation (follow-up)
- **Status**: TODO
- **Priority**: P2
- **Description**: `GhosttyApp` に `@MainActor` アノテーションを追加し、`activeSurfaces (NSHashTable)` と `ghostty_app_t` へのアクセスをコンパイラレベルで単一スレッド保証する。Review R1 B-002 採択。
- **Acceptance Criteria**:
  - [ ] `GhosttyApp` クラスに `@MainActor` を追加
  - [ ] コンパイラが cross-actor アクセスを検出した箇所を全て修正
  - [ ] `swift build` → Build complete!

### T-049 — TmuxControlMode single-use contract documentation (follow-up)
- **Status**: TODO
- **Priority**: P3
- **Description**: `TmuxControlMode` が single-use (`stop()` 後に `start()` しても events が流れない) であることをコードで明示する。Review R2 B-001 採択。
- **Acceptance Criteria**:
  - [ ] `start()` メソッドに `precondition(!stopped)` を追加、または inline コメントで単一使用制約を文書化
  - [ ] `TmuxControlModeRegistry` が `stopMonitoring` で必ず削除→再作成するパターンを保証することを確認
  - [ ] `swift build` → Build complete!

### T-050 — SIGTERM crash fix: TMUX/TMUX_PANE env var inheritance (2026-03-03)
- **Status**: DONE
- **Priority**: P0
- **Description**: `swift run` を tmux ペイン内から実行すると、ghostty のサブプロセスが `TMUX`/`TMUX_PANE` 環境変数を継承する。`tmux attach-session` が親 tmux クライアントに副作用を起こし SIGTERM で終了する。
- **Root cause**: `GhosttyPaneTile.attachCommand` が `tmux attach-session -t <session>` を直接組み立てており、TMUX 環境変数をアンセットしていなかった。
- **Fix**: `WorkspaceArea.swift:attachCommand` で `env -u TMUX -u TMUX_PANE tmux attach-session -t \(sessionTarget)` に変更。
- **Diagnosis**: Codex が embedded.zig / App.zig / Metal.zig / GhosttyApp.swift を精査し、quit_timer/occlusion/Metal スレッドは無実と確認。環境変数継承が真因。
- **Build**: `swift build` → Build complete! ✅

### T-051 — layer-backing conflict fix: remove wantsLayer/makeBackingLayer overrides (2026-03-03)
- **Status**: DONE
- **Priority**: P0
- **Description**: `GhosttyTerminalView` の `override var wantsLayer` + `override func makeBackingLayer()` が AppKit の "layer-backed" モードを先に確立し、Ghostty の "layer-hosting" (IOSurfaceLayer) 設定と競合。
- **Fix**: 両 override と `import QuartzCore` を削除。コメントに layer-hosting パターンの説明を追記。
- **Build**: `swift build` → Build complete! ✅

### T-052 — Unit test infrastructure: AgtmuxTermCore library target (2026-03-03)
- **Status**: IN_PROGRESS
- **Priority**: P1
- **Description**: Package.swift を library + executable に分割し、純 Swift ロジックを `AgtmuxTermCore` に移動してユニットテストを追加。
- **Review**: Codex (GO) + Orchestrator (GO) = 2/2 GO
- **Key constraints from review**:
  - `package` アクセス修飾子を使用 (`public` ではなく)
  - `StatusFilter` は UI 依存のため AgtmuxTerm 側に残す
  - `AgtmuxDaemonClient` は既に別ファイル (移動不要)
  - Integration tests には `-L/-S` で隔離 tmux サーバを使う
- **Acceptance Criteria**:
  - [ ] `Sources/AgtmuxTermCore/` に LayoutNode.swift, TmuxLayoutConverter.swift, DaemonModels (models) を移動
  - [ ] Package.swift に AgtmuxTermCore target + AgtmuxTermCoreTests testTarget を追加
  - [ ] 移動した型に `package` アクセス修飾子を追加
  - [ ] AgtmuxTerm 側から `import AgtmuxTermCore` で参照可能
  - [ ] `swift test` で TmuxLayoutConverter (6ケース) + LayoutNode (5ケース) が PASS
  - [ ] `swift build` が引き続き成功

### T-053 — XCUITest E2E infrastructure (2026-03-03)
- **Status**: DONE
- **Priority**: P1
- **Description**: XcodeGen を使って .xcodeproj を生成し、XCUITest で pane 選択 → terminal tile 表示を自動検証する。クラッシュ回帰テスト（pane 選択後 app が生存しているか）を主目的とする。
- **Planning**: codex x2 + opus x2 の 4 エージェントが独立計画、比較検討の上 XcodeGen 採用。
- **Key decisions (from multi-agent review)**:
  1. **XcodeGen** 採用（Tuist より簡単、@main リファクタ不要、YAML 1ファイル）
  2. **`package` アクセス問題**: `OTHER_SWIFT_FLAGS: -package-name agtmux_term` を両ターゲットに設定してパッケージ共有
  3. **`Bundle.module` 問題**: SVG リソースに `#if SWIFT_PACKAGE / #else Bundle.main` 条件コンパイル追加
  4. **`@main` リファクタ不要**: XcodeGen app type は top-level main.swift を扱える
  5. **アクセシビリティ識別子**: `AccessibilityID.swift` enum で名前空間管理
- **Files to create**:
  - `project.yml` — XcodeGen マニフェスト
  - `Sources/AgtmuxTerm/AccessibilityID.swift` — AX identifier 定数
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift` — テスト本体
  - `Tests/AgtmuxTermUITests/UITestHelpers.swift` — 共通ヘルパー
- **Files to modify**:
  - `Sources/AgtmuxTerm/SidebarView.swift` — PaneRowView + SessionBlockView + WindowBlockView に AX identifier 追加
  - `Sources/AgtmuxTerm/WorkspaceArea.swift` — GhosttyPaneTile に AX identifier + value 追加、空状態に identifier 追加
  - `Sources/AgtmuxTerm/CockpitView.swift` — sidebar / workspace-area に identifier 追加
  - `.gitignore` — *.xcodeproj 追加
- **project.yml key settings**:
  ```yaml
  settings.base:
    OTHER_SWIFT_FLAGS: "$(inherited) -package-name agtmux_term"
  AgtmuxTermCore:
    type: framework   # package access 互換のため static library ではなく framework
    dependencies: []
  AgtmuxTerm:
    type: application
    dependencies: [AgtmuxTermCore, GhosttyKit.xcframework, Metal, MetalKit, ...]
  AgtmuxTermUITests:
    type: bundle.ui-testing
    dependencies: [AgtmuxTerm]
  ```
- **Test cases**:
  - `testPaneSelectionShowsLoadingThenTerminal`: pane 行タップ → ProgressView → GhosttyPaneTile (ready) + app.state == .runningForeground
  - `testTabCreation`: Cmd+T → タブ数が増加
  - `testAppLaunchShowsSidebar`: 起動直後に sidebar 確認
  - `testEmptyStateOnLaunch`: pane 未選択時に空状態確認
- **Acceptance Criteria**:
  - [x] `xcodegen generate` が成功する (xcodegen 2.44.1)
  - [x] `xcodebuild build -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm ...` が成功する
  - [x] `xcodebuild build-for-testing` (UITests含む) が成功する — TEST BUILD SUCCEEDED
  - [x] `testAppLaunchShowsSidebar` 実装済み
  - [x] `testPaneSelectionCreatesTerminalTile` クラッシュ回帰テスト実装済み
  - [x] `swift build` が引き続き成功
  - [x] 1/2 review gate 通過 (Codex: Go with changes → 修正後 Go, Claude: Go)
  - **Notes**:
    - AccessibilityID を AgtmuxTermCore (public) に移動 — UITests/App両方から参照
    - project.yml の HEADER_SEARCH_PATHS を削除 (xcframework module redefinition 回避)
    - tearDown: preExistingSessions で差分管理、本番セッション誤削除防止
    - testTabCreation: workspaceTabPrefix定数 + TabButton AX identifier 追加

---

### T-054 — Sidebar multi-highlight fix + split regression test (2026-03-03)
- **Status**: DONE
- **Priority**: P1
- **Description**: 2つのバグを修正しリグレッションテストを追加。
- **Bug 1: Sidebar multi-highlight**:
  - 根本原因: `LinkedSessionManager` が `agtmux-{UUID}` linked session を作成するとき、元セッションの pane ID をすべて共有する。`agtmux json` はその両方のセッションを返すため、同じ `pane.id = "local:%42"` が複数行に現れ、1つを選択すると複数行がハイライトされる。
  - 修正: `AppViewModel.filteredPanes` に `!$0.sessionName.hasPrefix("agtmux-")` フィルタ追加。
- **Bug 2: placePane() split accumulation** (previously fixed in T-053 session):
  - 根本原因: `splitLeaf()` を使っていた（スプリット追加）。`replacing()` が正しい（in-place 置換）。
  - 修正: `WorkspaceStore.placePane()` を `replacing(leafID:with:)` に変更済み。
- **Regression tests added**:
  - `LayoutNodeTests.testReplacingLeafYieldsSingleLeaf`: `replacing()` が split ではなく single leaf を返す
  - `LayoutNodeTests.testTwoReplacementsDoNotAccumulateSplits`: 2回 replacing しても tile count = 1 を維持
  - `PaneFilterTests.testLinkedSessionPanesAreFiltered`: `agtmux-*` セッションが filteredPanes から除外される
  - `PaneFilterTests.testNonLinkedPanesHaveUniqueIDs`: 通常 pane の ID ユニーク性確認
  - `PaneFilterTests.testLinkedPaneSharesPaneIDWithOriginal`: linked pane が root cause (同一 pane.id) を文書化
- **E2E UI tests**: XCUITest on macOS 26 requires either Xcode IDE (has Accessibility/DeveloperTool permissions) or `DevToolsSecurity -enable` (requires sudo). Run via "Cmd+U in Xcode" or `xcodebuild test` after enabling DevToolsSecurity.
  - `testSecondPaneSelectionReplacesNotSplits` — split regression 検出テスト（要 agtmux daemon + ≥2 panes）
  - `setUp`: `split-window -d` で2 pane 作成
  - `main.swift`: `-XCTest` prefix args 検出時 `ghostty_cli_try_action()` をスキップ
- **Acceptance Criteria**:
  - [x] `swift test` — 18 tests, 0 failures (13 既存 + 5 新規リグレッション)
  - [x] `xcodebuild build-for-testing` — TEST BUILD SUCCEEDED
  - [x] Sidebar で pane 選択時、1行のみハイライト（agtmux-* セッション非表示）
  - [x] pane を 2回選択しても tile count = 1 (split 非累積)

### T-055 — Bug fix: Wrong pane shown (select-pane missing)
- **Status**: DONE
- **Priority**: P1
- **Description**: `LinkedSessionManager.createSession` called `select-window` but not `select-pane`. When a window had multiple panes, the linked session showed the wrong (current) pane instead of the user-selected one.
- **Root cause**: Missing `select-pane -t {paneId}` call in createSession.
- **Fix**:
  - `LinkedSessionManager.createSession`: add `paneId: String` parameter, call `select-pane -t {paneId}` after `select-window`
  - `WorkspaceStore.placePane`: pass `pane.paneId` to createSession
  - `WorkspaceStore.placeWindow`: pass `leaf.tmuxPaneID` to createSession
  - `WorkspaceStore.handleLayoutChange`: pass `leaf.tmuxPaneID` to createSession
- **Regression test**: Unit test in `LinkedSessionIntegrationTests.swift`

### T-056 — Bug fix: Status dots hidden (linked session prefix collision)
- **Status**: DONE
- **Priority**: P1
- **Description**: `AppViewModel.filteredPanes` filtered `agtmux-*` sessions to hide linked sessions, but the agtmux CLI also names user sessions `agtmux-{UUID}`. All managed panes (running Claude Code) are in `agtmux-*` sessions, so the filter hid all status dots.
- **Root cause**: Prefix collision between our linked session names (`agtmux-{UUID}`) and real user sessions (`agtmux-{UUID}`).
- **Fix**:
  - `LinkedSessionManager.createSession`: rename prefix from `"agtmux-"` to `"agtmux-linked-"`
  - `AppViewModel.filteredPanes`: update filter from `"agtmux-"` to `"agtmux-linked-"`
  - `PaneFilterTests.swift`: update tests to reflect new prefix
- **Regression tests**: Updated `PaneFilterTests.swift` to verify:
  1. `agtmux-linked-*` sessions ARE filtered (hidden)
  2. `agtmux-{UUID}` (real user sessions) are NOT filtered (visible with status dots)

---

### T-057 — E2E テスト基盤刷新: mock AGTMUX_BIN 方式
- **Status**: DONE
- **Priority**: P1
- **Description**: 既存 E2E テストは setUp で生の tmux セッションを作成し、`agtmux json` が返す managed pane を期待していたが、raw tmux セッションはデーモンに追跡されないため素通りしていた。`AGTMUX_BIN` 環境変数でモックスクリプトを差し込む方式に刷新。
- **Root cause**: `agtmux json` は AI エージェントが動いているペインのみ返す。`new-session` で作った生のセッションは追跡対象外。
- **Fix**:
  - `setUpWithError` から `app.launchForUITest()` を除去 — 各テストが自分で launch する
  - `createMockAgtmux(json:)` helper 追加 — tmp に実行可能スクリプトを生成
  - 新テスト追加:
    - `testSidebarShowsDaemonPanes` (T-E2E-007): mock で既知ペインが sidebar に出現することを確認
    - `testLinkedSessionsHiddenRealSessionsVisible` (T-E2E-008): T-056 リグレッション (linked session フィルタ)
    - `testManagedFilterShowsOnlyManagedPanes` (T-E2E-009): Managed フィルタ動作確認
    - `testPaneSelectionWithMockDaemonAndRealTmux` (T-E2E-010): mock + real tmux でタイル表示確認
- **Acceptance Criteria**:
  - [x] mock を使う Category A テストはデーモン不要で実行可能
  - [x] `xcodebuild build-for-testing` — TEST BUILD SUCCEEDED
  - [x] mock script が引数を無視して valid JSON を出力することを確認 (`python3 -m json.tool` PASS)
  - [ ] `testSidebarShowsDaemonPanes` PASSED (要 DevToolsSecurity -enable or Xcode IDE)
  - [ ] `testLinkedSessionsHiddenRealSessionsVisible` PASSED (T-056 リグレッション検出)
  - [ ] `testAppLaunchShowsSidebar` / `testEmptyStateOnLaunch` / `testTabCreation` 引き続き PASSED
- **Note**: `xcodebuild test` from CLI fails with "Failed to activate (current state: Running Background)" because `DevToolsSecurity` is disabled on this machine. Tests must be run from Xcode IDE or after `sudo DevToolsSecurity -enable`.

---

### T-058 — agtmux daemon 同梱 + 起動/終了ライフサイクル管理 (2026-03-04)
- **Status**: IN_PROGRESS
- **Priority**: P1
- **Description**: `agtmux` を app bundle から解決できるようにし、app 起動時に daemon を自動起動、app 終了時にこの app が起動した daemon を自動停止する。
- **Why**:
  - 初回セットアップ時に「daemon が未起動で空画面」になりやすい
  - 環境依存（PATH / AGTMUX_BIN）を減らして配布時の再現性を上げたい
- **実装方針 (今回着手分)**:
  - `AgtmuxBinaryResolver` 追加
    - 解決順: `AGTMUX_BIN` → bundle `Resources/Tools/agtmux`（SPM flatten fallback: bundle root `agtmux`）→ PATH/fallback
    - 既存 `AgtmuxDaemonClient` からも共通利用
  - `AgtmuxDaemonSupervisor` 追加
    - app 起動時: daemon 到達不能なら `agtmux daemon` を spawn
    - app 終了時: app 管理下 child process を terminate
    - `AGTMUX_AUTOSTART=0` で無効化
    - `AGTMUX_UITEST=1` では自動起動しない
  - `main.swift`
    - SIGTERM handler を child daemon kill 対応版に差し替え
    - event loop 前 `startIfNeeded()`
    - event loop 後 `stopIfOwned()`
  - resources
    - `Sources/AgtmuxTerm/Resources/Tools/README.md` 追加（同梱配置先の明文化）
- **Files (created/updated)**:
  - `Sources/AgtmuxTerm/AgtmuxBinaryResolver.swift` (new)
  - `Sources/AgtmuxTerm/AgtmuxDaemonSupervisor.swift` (new)
  - `Sources/AgtmuxTerm/AgtmuxDaemonClient.swift` (updated)
  - `Sources/AgtmuxTerm/main.swift` (updated)
  - `Sources/AgtmuxTerm/Resources/Tools/README.md` (new)
  - `README.md` (updated)
- **Acceptance Criteria**:
  - [x] bundle binary を含む実行パス解決が実装されている
  - [x] app 起動時に daemon 自動起動ロジックが呼ばれる
  - [x] app 終了時（通常終了 + SIGTERM）に child daemon 停止ロジックがある
  - [x] `AGTMUX_AUTOSTART=0` で明示無効化できる
  - [ ] bundle 同梱バイナリの署名/配布フローを CI に組み込む

---

### T-059 — XPC Service 方式への移行 (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**: local daemon ライフサイクルを app 直下の subprocess 管理から、bundle 同梱 XPC service 経由に移行する。
- **Pre-review gate (Claude x2)**:
  - Reviewer A: GO
  - Reviewer B: GO
  - Decision: **2/2 GO → 採択して実装開始**
- **Post-review gate (Claude x2, round 1)**:
  - Reviewer A: GO_WITH_CONDITIONS
  - Reviewer B: GO_WITH_CONDITIONS
  - 採択した修正:
    - service `startManagedDaemon` が常に success を返す不整合を修正
    - `interruption/invalidation` 二重発火時の connection カウント二重減算を修正
    - XPC service 実行時でも host app bundle の `Resources/Tools/agtmux` を解決可能に修正
- **Post-review gate (Claude x2, round 2)**:
  - Reviewer A: GO
  - Reviewer B: GO_WITH_CONDITIONS
  - Decision: **2/2 GO系 verdict（1/2 gate 通過）で完了**
- **Scope**:
  - shared XPC protocol + wire format定義
  - `AgtmuxDaemonService` ターゲット追加（xpc-service）
  - app側 persistent XPC client + reconnect-on-demand
  - service側 daemon start/stop + snapshot fetch
  - fallback (`AGTMUX_XPC_DISABLED=1`, `AGTMUX_UITEST=1`, XPC失敗時)
- **Wire contract**:
  - `startManagedDaemon(reply: (Bool, NSString?) -> Void)`
  - `fetchSnapshot(reply: (NSData?, NSString?) -> Void)`
  - `stopManagedDaemon(reply: () -> Void)`
  - payload: UTF-8 JSON (`AgtmuxSnapshot`, ISO8601 date)
- **Implementation steps**:
  1. Step 0: xcodegen で `xpc-service` target 生成可否を先に検証（不可なら helper方式へ切替）
  2. Step 1: shared protocol追加
  3. Step 2: service target 実装
  4. Step 3: app-side XPC client 実装
  5. Step 4: AppViewModel/main 統合（fallback維持）
  6. Step 5: build/test + post-review gate (Claude x2, 1/2 GO必須)
- **Risks**:
  - xcodegen `xpc-service` サポート差異
  - XPC invalidation / continuation resume漏れ
  - stdio pipe deadlock（timeout + drainで対策）
- **Files (created/updated)**:
  - `Sources/AgtmuxTermCore/AgtmuxDaemonXPCContract.swift` (new)
  - `Sources/AgtmuxTermCore/AgtmuxBinaryResolver.swift` (new)
  - `Sources/AgtmuxTermCore/AgtmuxDaemonClient.swift` (new; app側実装を移動)
  - `Sources/AgtmuxDaemonService/main.swift` (new)
  - `Sources/AgtmuxTerm/AgtmuxDaemonXPCClient.swift` (new)
  - `Sources/AgtmuxTerm/LocalSnapshotClient.swift` (new)
  - `Sources/AgtmuxTerm/AppViewModel.swift` (updated; local client抽象化)
  - `Sources/AgtmuxTerm/main.swift` (updated; XPC優先 + fallback統合)
  - `Sources/AgtmuxTerm/AgtmuxDaemonSupervisor.swift` (updated)
  - `project.yml` (updated; xpc-service target追加)
  - `README.md` (updated)
- **Verification**:
  - [x] `swift build`
  - [x] `swift test`
  - [x] `xcodebuild -scheme AgtmuxTerm build`
  - [x] `xcodebuild -scheme AgtmuxTerm build-for-testing`
  - [ ] `xcodebuild test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testAppLaunchShowsSidebar`
    - 環境依存の app activation 失敗 (`Running Background`) で再現。XPC migration の build/test gate とは分離して継続調査。

---

### T-060 — E2E cleanup 強化 (tmux session + agent session) (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**: XCUITest の `tearDown` を強化し、テストが生成した tmux session とその内部 agent session (codex/claude) を確実に cleanup する。今後の新規 E2E でも同じ cleanup 契約を強制する。
- **Root cause**:
  - 従来は `preExistingSessions` 差分で `kill-session` するのみで、agent process の明示終了が保証されていなかった。
  - 新規テストが raw `tmux new-session` を直接使うと、cleanup 契約の逸脱をレビュー時に見逃す余地があった。
- **Fix**:
  - `AgtmuxTermUITests.tearDownWithError`
    - `sessionsToKill = (current - preExisting) ∪ ownedSessions` へ拡張
    - test-owned session には `terminateSessionProcesses()` を先行実行
      - `tmux send-keys C-c/C-c/exit`
      - `pane_tty` / `pgid` / `pane_pid` の3経路で終了
        - `pkill -TERM/-KILL -t <pane_tty>`
        - `kill -TERM/-KILL -- -<pgid>`
        - `pkill -TERM/-KILL -P <pane_pid>` + `kill -TERM/-KILL <pane_pid>`
    - session kill 後に leak 再検査し、残存があれば `XCTAssertTrue(finalLeaked.isEmpty)` で fail
  - `createTrackedTmuxSession(prefix:tmux:)` helper 追加
    - 新規 E2E は raw `tmux new-session` ではなくこの helper を必須化
    - `ownedSessions` へ自動登録
    - session 名を `agtmux-e2e-*` に正規化
  - `testPaneSelectionWithMockDaemonAndRealTmux` を helper 利用に変更
  - `Tests/AgtmuxTermUITests/README.md` 新規追加（cleanup 契約・新規テスト追加チェックリスト）
- **Files**:
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift` (updated)
  - `Tests/AgtmuxTermUITests/README.md` (new)
- **Acceptance Criteria**:
  - [x] teardown が tmux session cleanup に加えて agent process cleanup を実施
  - [x] cleanup 後に session leak を fail-fast で検知
  - [x] 既存 tmux E2E (`testPaneSelectionWithMockDaemonAndRealTmux`) が tracked session helper を使う
  - [x] 新規 E2E 作成時の cleanup 契約が docs に明文化されている

---

### T-061 — linked session title leak 修正 + E2E 追加 (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**: linked session (`agtmux-linked-*`) に attach した際、tmux status 上の session title が内部名で表示される問題を修正。親 session 名（session group）を表示する。
- **Root cause**:
  - 各 terminal tile は独立表示のため linked session に attach する設計。
  - tmux の既定 status title (`#S`) は linked session 名を表示するため、`agtmux-linked-UUID` が露出していた。
- **Fix**:
  - `LinkedSessionManager.createSession` で parent session の `status-left` / `set-titles-string` template を取得し、session-name token のみを `#{session_group}` に置換して linked session に適用:
    - 置換対象: `#S`, `#{session_name}`
    - `##S`（literal token）は保持
  - parent session に local option が未設定（global 継承）でも漏れないように、template 取得は「session local -> 空なら global」へフォールバック
  - これにより user の tmux/wezterm 設定由来の背景色・装飾・separator を維持したまま、内部 `agtmux-linked-*` 名の露出だけを防ぐ。
  - E2E 追加: `testLinkedSessionStatusTitleUsesParentSessionGroup`
    - pane 選択で生成された linked session の `status-left` と `set-titles-string` が「parent template を保持しつつ session token だけ置換」になることを検証
    - tmux socket にアクセスできない runner 環境では `XCTSkip`（環境依存 fail を回避）
  - E2E 追加: `testLinkedSessionStatusTitleFallsBackToGlobalTemplate`
    - parent local option を unset し、global template 継承ケースでも linked 側が `session_group` 置換されることを検証
- **Files**:
  - `Sources/AgtmuxTerm/LinkedSessionManager.swift` (updated)
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift` (updated)
  - `Tests/AgtmuxTermUITests/README.md` (updated)
- **Acceptance Criteria**:
  - [x] linked session title が内部名ではなく親 session group 名で表示される（status bar / terminal title の両方）
  - [x] title leak の回帰を検知する E2E が追加されている
  - [x] tmux socket 非許可環境でも E2E が skip で安定する

---

### T-062 — UI title source-of-truth 統一 (window/title bar + tab) (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**: sidebar の選択 session と、window title (traffic-light 横) / tab title の不一致を根本解消。内部 linked-session 名を user-facing title に使わない。
- **Root cause**:
  - `GhosttyApp` が terminal 側 `SET_TITLE` action をそのまま NSWindow に反映していた。
  - terminal は linked session (`agtmux-linked-*`) に attach するため、window title が内部名に汚染された。
  - 初期 tab が固定 `"Main"` だったため、選択 pane/session と tab 表示が同期しなかった。
- **Fix**:
  - `GhosttyApp.handleAction`
    - `GHOSTTY_ACTION_SET_TITLE` を consume し、window title 更新を停止
  - `main.swift`
    - NSWindow title は `AppViewModel.selectedPane.sessionName` を source-of-truth として更新
    - pane 未選択時は `"agtmux-term"`
    - 初期 tab の固定タイトル `"Main"` を廃止
  - `WorkspaceStore.WorkspaceTab.displayTitle`
    - placeholder leaf (`tmuxPaneID == ""`) を除外してタイトル導出
    - 単一 session はその session 名、複数混在は `Mixed (N)`
  - `WorkspaceArea.TabButton`
    - AX を `.contain` から `.combine` に変更（tab title の E2E 観測性を改善）
  - E2E 追加: `testSelectedPaneSessionNameShownInTabTitle`
    - pane 選択で tab title が選択 session 名に追従し、`"Main"` 固定が残らないことを検証
- **Files**:
  - `Sources/AgtmuxTerm/GhosttyApp.swift` (updated)
  - `Sources/AgtmuxTerm/main.swift` (updated)
  - `Sources/AgtmuxTerm/WorkspaceStore.swift` (updated)
  - `Sources/AgtmuxTerm/WorkspaceArea.swift` (updated)
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift` (updated)
- **Acceptance Criteria**:
  - [x] window title に `agtmux-linked-*` が出ない設計になっている
  - [x] tab title が固定 `"Main"` ではなく選択 session 文脈に追従
  - [x] tab title 同期の E2E が追加されている

---

### T-063 — session-group alias 重複の根本解消 (sidebar selection / naming) (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**: sidebar で同一 pane が複数 session alias (`agtmux-*`) に重複表示され、複数行同時ハイライト・誤選択になる問題を修正。session-group 基準で canonicalize して 1 行に収束させる。
- **Root cause**:
  - daemon snapshot に同一 `pane_id` が複数 session alias として含まれるケースがある。
  - 旧実装は `AgtmuxPane.id = source:pane` と AX key も `source+pane` だったため、session alias 衝突で同時ハイライト/同一pane選択が発生。
  - `agtmux-linked-*` prefix だけでは alias 重複（`agtmux-*`）を除去できなかった。
- **Fix**:
  - `AgtmuxPane.id` を `source:session:pane` に変更（session 文脈込み）
  - `AccessibilityID.paneKey` を `source+session+pane` に変更
  - `AppViewModel.fetchAll` に正規化フェーズ追加:
    - local `tmux list-sessions -F "#{session_name}\t#{session_group}\t#{session_attached}"` から alias→canonical map を生成
    - canonical priority: attached > group名一致 > lexical
    - `session_group` field がある場合は fallback として利用
    - `agtmux-linked-*` は除外
    - canonical後に `(source, session, window, pane)` 単位で dedupe
  - `RemoteTmuxClient` を `session_group` 取得対応
  - E2E 追加: `testSessionGroupAliasSessionsAreDeduplicated`
    - alias session 2件 + 同一pane を mock し、canonical key 1件のみ表示されることを検証
    - raw alias key が残らないことを検証
- **Files**:
  - `Sources/AgtmuxTermCore/CoreModels.swift` (updated)
  - `Sources/AgtmuxTermCore/AccessibilityID.swift` (updated)
  - `Sources/AgtmuxTerm/AppViewModel.swift` (updated)
  - `Sources/AgtmuxTerm/RemoteTmuxClient.swift` (updated)
  - `Sources/AgtmuxTerm/SidebarView.swift` (updated)
  - `Sources/AgtmuxTerm/WorkspaceArea.swift` (updated)
  - `Tests/AgtmuxTermCoreTests/PaneFilterTests.swift` (updated)
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift` (updated)
  - `Tests/AgtmuxTermUITests/README.md` (updated)
- **Acceptance Criteria**:
  - [x] session alias 重複が sidebar で 1 行に収束する
  - [x] pane 選択ハイライトが session alias 衝突で多重化しない
  - [x] canonical化の回帰を検知する E2E が追加されている

---

### T-064 — Sidebar UX安定化と操作面積統一 (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - polling 中に sidebar が一瞬空になるフリッカーを根本解消
  - 選択 pane を白ハイライトへ統一
  - session / window / pane の hover 時ハイライトを統一
  - context menu 発火位置を title 文字列ではなく list item 全体へ拡張
- **Root cause**:
  - fetch 失敗タイミングで source の pane 配列が空として反映される設計のため、再取得完了まで空表示が発生
  - hover/selected 背景仕様が pane のみ部分的で、session/window は未統一
  - context menu が row 全体ではなく見かけ上 title 近傍に偏る
- **Fix**:
  - `AppViewModel.fetchAll`
    - source 単位 `lastSuccessfulPanesBySource` cache を導入
    - fetch 成功 source のみ cache 更新、失敗 source は前回成功値を保持
    - offline source の一時失敗で sidebar 全消去されないように変更
  - `SidebarView`
    - `SidebarRowStyle` を追加し、hover / selected 背景を白系で統一
    - pane 選択背景を `accentColor` 系から白ハイライトへ変更
    - session / window / pane row を `frame(maxWidth: .infinity)` + `contentShape(Rectangle())` 化
    - context menu を row container（list item 全体）で発火するよう統一
- **Files**:
  - `Sources/AgtmuxTerm/AppViewModel.swift` (updated)
  - `Sources/AgtmuxTerm/SidebarView.swift` (updated)
- **Acceptance Criteria**:
  - [x] 一時的 fetch 失敗で sidebar が空表示へフラッシュしない
  - [x] 選択 pane が白ハイライトで表示される
  - [x] session/window/pane row の hover 背景が白系で統一される
  - [x] session/window/pane の context menu が row 全体の右クリックで開く

---

### T-065 — Sidebar item 出没（消える/戻る）再発の根本解消 (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - polling 中に selected pane / session / window が一瞬消えて再出現する揺れを解消する。
- **Root cause**:
  - session canonical化が `session_attached` 優先で動的に変わる設計だったため、pollごとに alias の代表名が揺れる余地があった。
  - canonical化結果が `agtmux-linked-*` 側へ寄ると、後段 filter で行が消える経路が存在した。
  - local `tmux list-sessions` の一時失敗時に alias map が空になり、表示名・グルーピングが揺れる余地があった。
- **Fix**:
  - local alias map を「`session_group` 固定 canonical」に変更（`attached` 優先ロジックを廃止）
  - alias map 取得失敗時は `lastSuccessfulLocalSessionAliasMap` を再利用して揺れを抑制
  - `filteredPanes` の linked-prefix 再フィルタを撤去し、normalize済み `panes` を直接利用
  - canonical化優先順位を `pane.sessionGroup` > aliasMap > raw sessionName に変更
- **Files**:
  - `Sources/AgtmuxTerm/AppViewModel.swift` (updated)
- **Acceptance Criteria**:
  - [x] poll中に selected pane/session の行が消える・戻る揺れが再発しない
  - [x] canonical session 名が poll ごとに不安定に変化しない
  - [x] local tmux 一時失敗時も前回成功 map で安定表示を維持

---

### T-066 — Main panel pane focus → Sidebar highlight 逆同期 (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - main panel（workspace 内 tmux window）で pane フォーカスが変わったとき、sidebar の selected pane ハイライトを同じ pane へ追従させる。
- **Root cause**:
  - 通常の pane クリック経路が `workspaceStore.placePane()` を呼んでおり、window monitor (`startLayoutMonitoring`) が開始されないため `%window-pane-changed` を受け取れなかった。
  - monitor 管理が `windowId` 単位だったため、`@1` などの共通 window ID が別 session/source/tab と衝突する設計だった。
  - sidebar 選択状態 (`AppViewModel.selectedPane`) は sidebar click 起点でしか更新されず、workspace 側 focus と片方向同期だった。
- **Fix**:
  - pane row クリック経路を `placePane()` から `placeWindow(window, preferredPaneID:)` へ切替。
    - 選択 pane の `paneId` を preferred として tab 初期フォーカスに反映。
    - これにより通常操作でも必ず window monitor が有効になる。
  - window 表示モデルを「BSP で pane ごとに複製表示」から「single-surface で tmux window をそのまま表示」に変更。
    - 1 workspace tile = 1 tmux window
    - pane の分割描画は tmux 本体に委譲
    - 2pane→4pane の重複表示とレイアウト破綻を根本解消
  - `WorkspaceStore` の tracking を `windowId` キーから `tabID` キーへ刷新:
    - `trackedWindowsByTab`
    - `layoutMonitorTasksByTab`
    - tab 単位で monitor lifecycle を管理し、window ID 衝突を根絶。
  - `placePane()` 実行時は同 tab の monitor を明示停止し、stale event 混入を防止。
  - `WorkspaceStore.startLayoutMonitoring` を session-scoped active-pane poll に統一。
    - `display-message -p -t <monitorSession> "#{pane_id}"` を主経路にして、windowId 依存を除去。
    - fallback として `list-panes -t <monitorSession>` 解析を保持。
  - `WorkspaceStore.handleWindowPaneChanged(paneId:tabID:)` で、対象 `tabID` の leaf `tmuxPaneID` を更新し `focusedLeafID` を同期。
  - `WorkspaceArea` に `syncSelectedPaneToFocusedLeaf()` を追加し、以下イベントで `focusedLeaf` → `selectedPane` を同期:
    - `onAppear`
    - `activeTabIndex` 変更
    - `activeTab.focusedLeafID` 変更
    - `viewModel.panes` 更新
  - E2E 検証向けに AX 契約を拡張:
    - window row ID: `sidebar.window.<source_session_window>`
    - pane row value: `selected` / `unselected`
  - E2E 追加: `testMainPanelPaneFocusSyncsSidebarSelection`
    - sidebar pane row クリック（実ユーザー経路）で window を開いた後、`tmux select-pane` による focus 変更で selected 行が追従することを検証
    - linked session 生成後に parent session を kill しても同期が継続することを検証（monitor が linked runtime に追従）
    - tmux 作成不可環境では `XCTSkip` で安全にスキップ
- **Files**:
  - `Sources/AgtmuxTerm/WorkspaceStore.swift` (updated)
  - `Sources/AgtmuxTerm/WorkspaceArea.swift` (updated)
  - `Sources/AgtmuxTerm/SidebarView.swift` (updated)
  - `Sources/AgtmuxTermCore/AccessibilityID.swift` (updated)
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift` (updated)
  - `Tests/AgtmuxTermUITests/README.md` (updated)
- **Acceptance Criteria**:
  - [x] 1 window を開いたとき workspace tile は常に 1つで、tmux pane は内部描画される
  - [x] main panel の pane focus 変更で sidebar selected 行が追従する
  - [x] 通常の pane row クリック経路でも monitor が有効化される
  - [x] window ID 衝突で monitor が誤配線されない
  - [x] monitor が `session:windowId` 固定参照に依存せず active pane を取得できる
  - [x] reverse-sync の E2E が追加されている（環境非対応時は skip）

---

### T-067 — local tmux inventory 統合 + session DnD reorder + live reflection E2E (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - terminal 内で新規作成した tmux session / window / pane が sidebar に反映されない問題を根本解消する。
  - session block の drag-and-drop 並び替えを追加する。
  - 上記の回帰を検知する cleanup-safe な E2E を追加する。
- **Background / Root cause**:
  - local source は `agtmux json` のみをデータ源にしているため、daemon が未収集の tmux entity が UI に出ない。
  - `panesBySession` は毎 poll で alphabetical sort しており、ユーザー操作による session 並び替え状態を保持できない。
- **Adopted design (Claude/Codex比較後の採択)**:
  - local existence の truth source を `tmux list-panes -a` にする（inventory）。
  - `agtmux json` は managed metadata overlay として扱う。
  - local inventory failure / metadata failure を分離し、metadata failure で row visibility を落とさない。
  - session order は source ごとに state 化し、DnD で更新。poll 後の session reconcile で order を維持する。
- **Planned Files**:
  - `Sources/AgtmuxTerm/RemoteTmuxClient.swift` (updated: LocalTmuxInventoryClient actor added)
  - `Sources/AgtmuxTerm/AppViewModel.swift` (updated: local merge + session order state/reorder)
  - `Sources/AgtmuxTerm/SidebarView.swift` (updated: SessionBlock DnD)
  - `Sources/AgtmuxTerm/LinkedSessionManager.swift` (updated: local tmux command env hardening)
  - `Sources/AgtmuxTermCore/AccessibilityID.swift` (updated: session AX identifiers)
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift` (updated: live reflection + DnD E2E)
  - `Tests/AgtmuxTermUITests/README.md` (updated: cleanup/accessibility contracts)
- **Acceptance Criteria**:
  - [x] local tmux で作成した session が 1 poll 周期以内に sidebar へ反映される設計になっている（inventory truth）
  - [x] 同一 session 内の window / pane 追加削除が sidebar に追従する経路を実装
  - [x] metadata 取得失敗時も local inventory row は維持される（overlay 失敗は空metadata扱い）
  - [x] session block の DnD 並び替えが source 内で機能し、poll 後に維持される
  - [x] 新規 E2E が cleanup helper (`createTrackedTmuxSession`) を利用し leak を発生させない

---

### T-068 — Sidebar session load 不達 + titlebar icon click 不達の根本修正 (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - 「terminal内で作成した session が sidebar に出ない」回帰を根本修正する。
  - 「titlebar の sidebar toggle icon が効かない」回帰を根本修正する。
  - それぞれ cleanup-safe な E2E を追加し、再発防止する。
- **Root cause hypotheses (Claude/Codex独立提案比較結果)**:
  - session load: local 表示の一次データ源が不安定で、inventory 取得失敗時に silent に空表示化し得る経路がある。
  - icon click: traffic-light exclusion hit-test 矩形が first icon のクリック領域と重なり、イベントが drop される経路がある。
- **Adopted plan**:
  - local fetch を stage 化:
    - stage1: `tmux list-panes -a` inventory を一次ソース
    - stage2: `agtmux json` metadata overlay
    - stage3: inventory 失敗時のみ metadata へ明示フォールバック（理由を記録、握りつぶし最小化）
  - titlebar hit-test を厳密化:
    - exclusion rect の不必要な膨張を廃止
    - accessory bounds で clip し、first icon と exclusion の重複を禁止
  - E2E 追加:
    - `testLocalSessionCreatedAfterLaunchAppearsInSidebar`
    - `testSidebarToggleIconTogglesSidebarVisibility`
- **Files**:
  - `Sources/AgtmuxTerm/AppViewModel.swift`
  - `Sources/AgtmuxTerm/TitlebarChromeView.swift`
  - `Sources/AgtmuxTerm/WindowChromeController.swift`
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
  - `Tests/AgtmuxTermUITests/README.md`
  - `docs/60_tasks.md`
  - `docs/70_progress.md`
- **Acceptance Criteria**:
  - [x] 起動後に新規作成した local tmux session が sidebar に表示される経路を実装し、E2Eを追加（この実行環境では tmux socket 制約により skip）
  - [x] titlebar の sidebar toggle icon click で sidebar が開閉する（E2E `testSidebarToggleIconTogglesSidebarVisibility` PASS）
  - [x] 追加 E2E が cleanup 契約を満たし、tmux residue を残さない
  - [x] fallback は明示的・最小限で、stage ごとの失敗理由を追跡できる（`AgtmuxTerm local-fetch:` ログ）

---

### T-069 — Local tmux socket override の一貫適用 + 隔離E2E追加 (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - local tmux socket override（`AGTMUX_TMUX_SOCKET_NAME` / `AGTMUX_TMUX_SOCKET`）を inventory だけでなく attach/control-mode まで一貫適用する。
  - 「一時tmux session/window/pane作成→sidebar反映」を隔離socketで検証するE2Eを追加し、環境制約時は明示skipにする。
- **Root cause**:
  - 既存実装では local inventory fetch 側のみ socket override を参照しており、workspace attach と control mode が default socket へ接続し得た。
  - その結果、sidebarの表示ソースと実際の接続先が不一致になる経路があった。
  - さらに、XCUITest runner の sandbox 制約で live tmux socket が利用できない環境では live E2E が不安定だった。
- **Fix**:
  - `LocalTmuxTarget` を新規追加し、socket選択優先順位を共通化:
    1. `AGTMUX_TMUX_SOCKET_NAME` (`tmux -L`)
    2. `AGTMUX_TMUX_SOCKET` (`tmux -S`)
    3. `TMUX` 由来 socket (`tmux -S`)
    4. default socket
  - `TmuxCommandRunner`（`LinkedSessionManager.swift`）は `LocalTmuxTarget.socketArguments` を利用。
  - `WorkspaceArea` の `tmux attach-session` コマンド生成に同 socket args を適用。
  - `TmuxControlMode` の local 接続（`tmux -C attach-session`）にも同 socket args を適用し、`TMUX/TMUX_PANE` を除去。
  - 隔離E2E `testIsolatedSocketSessionWindowPaneAppearInSidebar` を追加し、`AGTMUX_TMUX_SOCKET_NAME` で app を起動。
    - sandboxで隔離session維持不能な場合は `XCTSkip` による明示スキップ。
- **Files**:
  - `Sources/AgtmuxTerm/LocalTmuxTarget.swift` (new)
  - `Sources/AgtmuxTerm/LinkedSessionManager.swift` (updated)
  - `Sources/AgtmuxTerm/TmuxControlMode.swift` (updated)
  - `Sources/AgtmuxTerm/WorkspaceArea.swift` (updated)
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift` (updated)
  - `Tests/AgtmuxTermUITests/README.md` (updated)
  - `AgtmuxTerm.xcodeproj/project.pbxproj` (regenerated by `xcodegen`)
- **Acceptance Criteria**:
  - [x] local socket override が inventory/attach/control-mode で一貫適用される
  - [x] 隔離tmux E2E（session/window/pane）が追加される
  - [x] sandbox制約環境では skip 理由が明示される（silent failなし）
  - [x] build と主要E2E（toggle + isolated）が成功（isolated はこの環境で skip）

---

### T-070 — Red/Green/Refactor: stale TMUX env で local sidebar が空になる回帰の予防 (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - local tmux target 解決で inherited `TMUX` に依存していた経路を廃止し、stale socket による no-load 回帰を予防する。
  - Red-Green-Refactor で resolver 仕様をテスト先行で固定する。
- **Red**:
  - `LocalTmuxTargetTests.testInheritedTMUXIsIgnoredWithoutExplicitOverride` を追加。
  - 既存実装（TMUX由来 `-S` を採用）では fail を確認。
- **Green**:
  - `LocalTmuxTarget` を `AgtmuxTermCore` へ集約。
  - precedence を `AGTMUX_TMUX_SOCKET_NAME` > `AGTMUX_TMUX_SOCKET` > default に変更。
  - inherited `TMUX` は明示的に無視。
  - app 側 callsite（`TmuxCommandRunner`/`TmuxControlMode`/`WorkspaceArea`）は core resolver を利用。
- **Refactor**:
  - UI test helper に `AGTMUX_UITEST_PRESERVE_TMUX` を追加し、TMUX継承挙動のテスト制御を明確化。
  - isolated socket E2E に stale `TMUX` launch env を注入し、explicit socket 指定の優先を回帰ガード化。
  - `xcodegen generate` で project を再生成し、resolver 移動を反映。
- **Files**:
  - `Sources/AgtmuxTermCore/LocalTmuxTarget.swift` (new)
  - `Tests/AgtmuxTermCoreTests/LocalTmuxTargetTests.swift` (new)
  - `Sources/AgtmuxTerm/LocalTmuxTarget.swift` (deleted)
  - `Sources/AgtmuxTerm/LinkedSessionManager.swift` (updated)
  - `Sources/AgtmuxTerm/TmuxControlMode.swift` (updated)
  - `Tests/AgtmuxTermUITests/UITestHelpers.swift` (updated)
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift` (updated)
  - `Tests/AgtmuxTermUITests/README.md` (updated)
  - `AgtmuxTerm.xcodeproj/project.pbxproj` (regenerated)
- **Acceptance Criteria**:
  - [x] Redテストが fail を再現できる
  - [x] Green実装で `LocalTmuxTargetTests` が pass
  - [x] full `swift test` が pass
  - [x] `xcodebuild ... build` が pass
  - [x] 主要UI test（toggle）が pass、isolated は環境制約時のみ明示 skip

---

### T-071 — Sidebar pane selection sync + auto-scroll + same-window fast switch (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - terminal内で pane が切り替わったとき、sidebar の該当 pane row が確実に selected になること。
  - selected pane row が見切れている場合、sidebar が自動スクロールすること。
  - sidebar から同一 session/window 内の pane を選んだとき、linked session 再作成による loading を出さず高速切替すること。
  - temporary pane switch latency <= 0.5s の E2Eを追加すること（cleanup契約準拠）。
- **Independent review summary (codex x2 / claude x2)**:
  - 共通結論:
    - loading の主因は `placeWindow()` が同一windowでも毎回 linked session を再作成していること。
    - sidebar 側は `ScrollViewReader` がなく selected row への auto-scroll がないこと。
  - 採択:
    - `placeWindow()` に same-window fast path を追加し、existing linked session を `retarget` して再利用。
    - sidebar に auto-scroll + selected pane 所属 window の auto-expand を追加。
    - E2Eで 0.5s SLA を検証。
- **Planned Files**:
  - `Sources/AgtmuxTerm/LinkedSessionManager.swift`
  - `Sources/AgtmuxTerm/WorkspaceStore.swift`
  - `Sources/AgtmuxTerm/SidebarView.swift`
  - `Sources/AgtmuxTerm/WorkspaceArea.swift`
  - `Tests/AgtmuxTermUITests/UITestHelpers.swift`
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
  - `Tests/AgtmuxTermUITests/README.md`
  - `docs/60_tasks.md`
  - `docs/70_progress.md`
- **Acceptance Criteria**:
  - [x] same-window pane switch で `.creating` 遷移を避け、loading overlay が出ない
  - [x] terminal pane focus change で sidebar selected row が追従し、0.5s以内をE2Eで検証（runner socket制約時はskip）
  - [x] selected pane row が表示領域外でも auto-scroll される
  - [x] 追加E2Eが cleanup 契約に従い residue を残さない

---

### T-072 — Runner tmux socket判定の明確化 + pane switch latency改善第2弾 (2026-03-04)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - `tmux socket not accessible from runner` の判定を整理し、`no server running` と真の socket 非アクセスを区別する。
  - sidebar pane click の fast path をさらに短縮し、同一window切替の体感遅延を削減する。
  - クリック連打時に古い切替結果が UI に反映される競合を抑止する。
- **Independent review summary (codex/claude style x4)**:
  - 共通結論:
    - same-window retarget は `select-window + select-pane` 2往復より `select-pane` 単体が速い。
    - runner 事前チェックが default socket 前提だと、sandbox/no-server を同一メッセージで誤分類しやすい。
    - 高頻度クリックは latest-intent 優先の世代管理が必要。
  - 採択:
    - same-window は `select-pane` 単発化。
    - fast switch に generation gate を追加し stale completion を無効化。
    - UI test helper で tmux access preflight を typed 判定し skip 理由を明確化。
- **Planned Files**:
  - `Sources/AgtmuxTerm/LinkedSessionManager.swift`
  - `Sources/AgtmuxTerm/WorkspaceStore.swift`
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
  - `Tests/AgtmuxTermUITests/README.md`
  - `docs/60_tasks.md`
  - `docs/70_progress.md`
- **Acceptance Criteria**:
  - [x] same-window pane switch で tmux command roundtrip を1回に短縮
  - [x] 連続pane選択で stale switch が final selection を上書きしない
  - [x] `tmux socket not accessible from runner` が誤分類されず、skip理由が具体化される
  - [x] 既存 0.5s SLA E2E 契約を維持し、cleanup 契約を満たす（live tmux testはrunner制約時skip）

---

### T-073 — live tmux UI E2Eの runner-tmux 依存排除（app-side bridge化） (2026-03-05)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - sandboxed XCUITest runner が tmux socket を直接操作しなくても、live tmux UI E2E を実行できるようにする。
  - tmux command 実行を app プロセス側へ移し、runner は file command channel のみを使う。
- **Root cause**:
  - UI test runner は App Sandbox 有効で、default tmux socket へのアクセスが `Operation not permitted` になり得る。
  - 既存 live E2E は runner 側で `tmux` を直接実行しており、この制約の影響を受けていた。
- **Fix**:
  - `Sources/AgtmuxTerm/UITestTmuxBridge.swift` を追加。
    - `AGTMUX_UITEST_TMUX_SCENARIO` で app 起動時の tmux bootstrap を実行。
    - `AGTMUX_UITEST_TMUX_COMMAND_PATH` / `..._RESULT_PATH` で file command channel を提供。
    - `AGTMUX_UITEST_TMUX_AUTO_CLEANUP=1` + `...KILL_SERVER=1` で app 終了時 cleanup。
  - `main.swift` で bridge の start/shutdown を連携。
  - live UI tests 3件を app-driven command 経路へ移行:
    - `testLocalSessionCreatedAfterLaunchAppearsInSidebar`
    - `testMainPanelPaneFocusSyncsSidebarSelection`
    - `testSidebarSameWindowPaneSwitchUnderHalfSecondWithoutLoading`
  - `Tests/AgtmuxTermUITests/README.md` に app-driven contract を追記。
- **Files**:
  - `Sources/AgtmuxTerm/UITestTmuxBridge.swift` (new)
  - `Sources/AgtmuxTerm/main.swift` (updated)
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift` (updated)
  - `Tests/AgtmuxTermUITests/README.md` (updated)
  - `AgtmuxTerm.xcodeproj/project.pbxproj` (regenerated by `xcodegen`)
  - `docs/60_tasks.md`
  - `docs/70_progress.md`
- **Acceptance Criteria**:
  - [x] live tmux UI E2E の tmux command が runner shell ではなく app-side bridge 経由で実行される
  - [x] isolated socket を app 側で bootstrap/command/cleanup できる
  - [x] focus-sync / same-window fast-switch テストが bridge command で実行可能
  - [x] docs に新しい E2E 契約が反映される

---

### T-074a — Local fetch A0再設計: inventory-first + metadata非ブロッキングoverlay (2026-03-05)
- **Status**: DONE
- **Priority**: P0
- **Description**:
  - local pane 表示を metadata fetch から分離し、`tmux list-panes` 成功時点で即時描画する。
  - `agtmux json` は background refresh に移し、成功時のみ metadata cache を更新して overlay を再適用する。
  - metadata timeout/error は row existence に影響させない（inventory canonical）。
- **Design constraints**:
  - 後方互換よりUX優先（no backward compatibility）。
  - fallback を最小化し、失敗を握りつぶさずログ/状態で明示。
  - source境界を厳守（local metadata は local pane のみを更新）。
- **Planned Files**:
  - `Sources/AgtmuxTerm/AppViewModel.swift`
  - `Sources/AgtmuxTerm/LocalTmuxInventoryClient.swift`
  - `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift`
  - `Package.swift`
  - `docs/60_tasks.md`
  - `docs/70_progress.md`
- **Acceptance Criteria**:
  - [x] metadata timeout時でも local inventory rows が消えない
  - [x] `fetchLocalPanes()` が metadata完了を待たずに戻る
  - [x] metadata成功後は次回poll待ちなしでoverlay再適用できる
  - [x] `swift build` と `swift test -q` が通る

### T-074b — Cross-repo A0 受け入れ確認（agtmux新snapshot契約） (2026-03-05)
- **Status**: DONE
- **Priority**: P0
- **Description**:
  - agtmux 側の snapshot-aware `json`（top-level cache / pane metadata_stale 等）を受けても agtmux-term が安定動作することを確認する。
  - inventory-first + metadata non-blocking の term実装が cross-repo 接続で成立することを確認する。
- **Implemented**:
  - decode互換テスト追加: `AgtmuxSnapshotDecodeCompatibilityTests`
    - unknown top-level/pane fields を無視してdecode可能
    - `activity_state: null` を `.unknown` として取り扱い
  - isolated smoke:
    - `agtmux daemon` + isolated tmux socket を user配下 socket path で起動
    - `tmux split-window` 後に `agtmux json` pane count が 1→2 へ反映されることを確認
- **Acceptance Criteria**:
  - [x] snapshot-aware JSONの追加フィールドで decode が壊れない
  - [x] cross-repo 実機で inventory反映が継続して確認できる
  - [x] `swift test -q` / `swift build` が通る
