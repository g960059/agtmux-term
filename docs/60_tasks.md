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
