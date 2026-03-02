# Progress Ledger

---

## 2026-02-28 — プロジェクト開始

### 状況
プロジェクト `agtmux-term` を新規作成。GitHub リポジトリ初期化済み。

### POC 分析結果

`exp/go-codex-implementation-poc` ブランチの Swift/SwiftUI POC を分析した結果:

**根本原因の特定**: SwiftTerm がターミナルバックエンドとして使用されていたが、以下の根本的な問題があった:
- **10fps**: SwiftTerm のレンダリングループが遅い（GPU レンダリングなし）
- **IME 不安定**: NSTextInputClient 実装が不完全で、日本語入力で候補ウィンドウ位置がずれる
- **カーソルズレ**: VT パーサの精度問題

**流用可能なコード**:
- `AppViewModel.swift`: 状態管理ロジック（ObservableObject, @Published, StatusFilter）。品質が高く流用可能。
- `AGTMUXDesktopApp.swift` のサイドバー部分: UI レイアウト・デザインは完成している

**削除対象**:
- `NativeTmuxTerminalView.swift`: SwiftTerm ベース（置き換え対象）
- `TTYV2TransportSession.swift`: カスタム TTY ストリーミング（不要になる）

### 技術選定

| 項目 | 選定 | 理由 |
|------|------|------|
| ターミナルバックエンド | libghostty (GhosttyKit.xcframework) | GPU レンダリング・ネイティブ IME・正確な VT パーサ。Ghostty 本体と同じ実装 |
| UI フレームワーク | SwiftUI + AppKit (NSView) | POC と同じ構成。libghostty は NSView としてホスト |
| ビルドツール | Zig 0.14.x + swift build | `zig build xcframework` で GhosttyKit.xcframework を生成 |
| daemon 通信 (Phase 1) | agtmux CLI subprocess | シンプル。UDS JSON-RPC は Phase 3 で移行可能 |

**ADR**: `docs/80_decisions/ADR-20260228-libghostty-over-swiftterm.md`

### 完了事項
- [x] リポジトリ作成
- [x] docs/ 一式作成（00_router〜90_index）
- [x] CLAUDE.md 作成
- [x] ADR-20260228 作成
- [x] README.md 作成
- [x] タスクボード (docs/60_tasks.md) 作成 — T-001〜T-014

### 未解決事項
- [x] GhosttyKit.xcframework 配布戦略 → **ADR-20260228b で Git LFS に決定**
- [ ] agtmux daemon の socket path（デフォルト）の確認（T-009 前に agtmux-v5 実装と照合）

---

## 2026-02-28 — 初期 docs レビュー + API 検証

### 実装計画レビュー（2 subagent 並行）

`docs/` 一式を 2 名の reviewer（Codex-style + Claude）が並行レビュー。
両者 NEEDS_REVISION 判定。主な指摘事項と対処:

| ID | 指摘 | 対処 |
|----|------|------|
| B-1/CI-001 | `ghostty_surface_config_s.command` フィールド未確認 | ghostty.h 直接確認 → `const char*` で存在確認 ✅ |
| B-2/CI-002 | `tmux attach-session` pane 単位制御不可 | 技術的に動作することを確認。pane 単位改善は Phase 4 タスクとして注記 |
| CI-003 | DaemonModels が実際の JSON スキーマと不一致の可能性 | T-006a として独立タスク化 |
| N-2/TR-006 | keyDown 二重送信リスク | `ghostty_surface_key` 戻り値 consumed チェック方式に修正 |
| N-3/TR-007 | `Process.waitUntilExit()` が MainActor をブロック | `terminationHandler + withCheckedThrowingContinuation` に修正 |
| N-4/TR-008 | `/usr/local/bin/agtmux` ハードコード | `AGTMUX_BIN` 環境変数 → PATH 検索方式に変更 |

### ghostty.h API 検証結果（T-000 完了）

- `ghostty_surface_config_s.command: const char*` — 存在確認 ✅
- `platform.macos.nsview` — union 経由で設定 ✅
- `wakeup_cb: void (*)(void*)` — 確認 ✅
- `ghostty_surface_key` — `bool`（consumed フラグ）を返す ✅
- `ghostty_surface_ime_point` — IME 位置取得 API 確認 ✅

### 完了事項
- [x] T-000: Ghostty API サーベイ完了
- [x] docs/40_design.md 更新（全レビュー指摘事項を修正）
  - GhosttyApp: platform_tag/platform union, command: const char*, NSHashTable.weakObjects()
  - keyDown: consumed チェック方式
  - AgtmuxDaemonClient: terminationHandler 非同期化 + PATH 解決
  - pane attach: String コマンド形式、注記追加
  - TerminalPanel.Coordinator: selectedPane 購読パターン
- [x] docs/60_tasks.md 更新
  - T-000 追加（DONE）
  - T-001 AC に linker flags / module.modulemap / Sandbox 確認を追加
  - T-006 → T-006a / T-006b / T-006c に分割
  - T-010 pane attach 設計の注記更新

### 次のアクション
- ~~T-001 起動~~ → IN_PROGRESS（subagent 委任）

---

## 2026-02-28 — T-001 GhosttyKit.xcframework ビルド環境構築（IN_PROGRESS）

### 環境確認結果
- brew: 5.0.15 ✅
- Swift: 6.2.4 (arm64-apple-macosx26.0) ✅
- Xcode: /Applications/Xcode.app ✅
- git-lfs: **未インストール** → 要 brew install
- zig: **未インストール** → 要 brew install zig@0.14
- vendor/ghostty: 未存在 → 要 git clone
- GhosttyKit/: 未存在 → zig build 後コピー

### 作業内容・完了事項

| ステップ | 結果 |
|---------|------|
| brew install git-lfs | ✅ (3.7.1) |
| brew install zig@0.14 | ✅ (0.14.1, /opt/homebrew/Cellar/zig@0.14/0.14.1) |
| git lfs install / .gitattributes | ✅ |
| .gitignore に vendor/ 追加 | ✅ (subagent が対応済み) |
| git clone ghostty vendor/ghostty | ✅ |
| build.zig.zon の iterm2_themes URL 修正 | ✅ (404 を最新リリースに更新) |
| xcodebuild -downloadComponent MetalToolchain | ✅ (704.6MB) |
| zig build -Demit-xcframework=true | ✅ (macos-arm64_x86_64 + iOS slices) |
| GhosttyKit/ にコピー | ✅ (805MB) |
| module.modulemap 確認 | ✅ (xcframework に含有) |
| git lfs ls-files 確認 | ✅ (全 10 ファイル追跡) |
| Package.swift 作成 | ✅ (binaryTarget + linkerSettings) |
| scripts/build-ghosttykit.sh 作成 | ✅ |
| swift build | ✅ (Build complete! 2.16s) |
| ghostty_app_new シンボル確認 | ✅ (_ghostty_app_new T) |
| App Sandbox 要否確認 | ✅ 不要（Ghostty 本体も無効） |

### 発見した重要事項
- zig build コマンドは `xcframework` step ではなく `-Demit-xcframework=true` フラグで起動
- xcframework 出力先: `vendor/ghostty/macos/GhosttyKit.xcframework`（handover v2 の `zig-out/lib/` 記述は誤り）
- static lib xcframework（`.framework` バンドルでなく `libghostty.a` を直接含む）
- App Sandbox 不要（tmux spawn + daemon socket アクセスのため）

### 次のアクション
- ~~Review Pack 作成 → commit T-001~~ → **DONE** (7f2f00b)
- ~~T-002〜T-005~~ → **DONE** (下記参照)

---

## 2026-02-28 — T-002〜T-005 Phase 1 Terminal Core（DONE）

### 実装ファイル

| ファイル | 内容 |
|---------|------|
| `Sources/AgtmuxTerm/GhosttyApp.swift` | ghostty_app_t singleton、wakeup_cb、activeSurfaces |
| `Sources/AgtmuxTerm/GhosttyTerminalView.swift` | NSView+NSTextInputClient、CAMetalLayer、IME、マウス |
| `Sources/AgtmuxTerm/GhosttyInput.swift` | keyCode→ghostty変換、modifier flags、scroll mods |
| `Sources/AgtmuxTerm/main.swift` | NSApplication HelloWorld（T-005） |
| `Package.swift` | `.linkedLibrary("c++")` 追加（libghostty.a の C++ 依存） |

### API 差異（design doc との相違）

| 項目 | design doc | 実際の ghostty.h |
|-----|-----------|----------------|
| `ghostty_surface_config_s.context` | 存在 | **存在しない** |
| `ghostty_surface_mouse_button` 引数順 | `button, state, mods` | **`state, button, mods`** |
| `ghostty_surface_mouse_pos` 引数数 | 3（x, y） | **4（x, y, mods）** |
| `ghostty_input_scroll_mods_s` | struct | **`typedef int`（bitmask）** |
| `ghostty_input_key_s.keycode` 型 | `ghostty_input_key_e` | **`uint32_t`（Mac keyCode 直渡し）** |

### ビルド確認
- `swift build` → Build complete! 0.13s（全 T-002〜T-005 実装後）
- バイナリサイズ: 60MB arm64 Mach-O

### 次のアクション
- ~~Review Pack 作成 → commit T-002〜T-005~~ → **DONE** (f5c390c)
- ~~T-006a〜T-008~~ → **DONE** (下記参照)

---

## 2026-02-28 — T-006a〜T-008 Phase 2 Sidebar UI（DONE）

### 実装ファイル

| ファイル | 内容 | 行数 |
|---------|------|------|
| `Sources/AgtmuxTerm/DaemonModels.swift` | AgtmuxPane/Snapshot/StatusFilter Codable モデル | 76 |
| `Sources/AgtmuxTerm/AgtmuxDaemonClient.swift` | agtmux CLI subprocess wrapper (actor) | 105 |
| `Sources/AgtmuxTerm/AppViewModel.swift` | @MainActor ObservableObject、1秒ポーリング | 76 |
| `Sources/AgtmuxTerm/SidebarView.swift` | FilterBarView / SessionRowView / SidebarView | ~150 |
| `Sources/AgtmuxTerm/CockpitView.swift` | HSplitView + TerminalPanel + @MainActor Coordinator | 80 |
| `Sources/AgtmuxTerm/main.swift` | NSHostingView<CockpitView> + AppViewModel 注入 | 更新 |

### ビルド確認
- `swift build` → Build complete! (8.73s) — エラーなし・警告なし
- SourceKit false-positive（xcframework binary target + cross-file 解決）は既知の制限

### レビュー結果（GO_WITH_CONDITIONS）
- 全ファイル concurrency safety 正常（actor, @MainActor, weak 参照によるサイクル防止）
- "Fail loudly" ポリシー準拠（DaemonError 3ケース、全て呼び出し元に伝播）
- **Condition**: T-010 manual test で `GhosttyApp.shared.newSurface(command:)` が shell 経由か直接 args か確認。`shellEscaped()` の必要性を T-010 で検証。

### 次のアクション
- ~~T-009: daemon 統合テスト~~ → コード修正完了（下記参照）
- T-010: pane 選択 → surface 切り替え + shellEscaped 検証（手動）
- T-011: agent state リアルタイム表示確認（手動）

---

## 2026-03-01 — T-009 コード修正（daemon 統合確認の前提）

### agtmux-v5 API 照合結果

| 項目 | 実装 (T-006b) | agtmux-v5 実際の値 | 修正 |
|------|-------------|-------------------|------|
| デフォルト socketPath | `~/.local/share/agtmux/daemon.sock` | `/tmp/agtmux-$USER/agtmuxd.sock` | ✅ 修正済み |
| CLI サブコマンド | `json` | `json`（v5 T-139 CLI redesign 以降） | ✅ 正しい |
| 出力形式 | `{"version":1, "panes":[...]}` | 同じ（`build_json_v1` の実装と一致） | ✅ 正しい |
| `window_index: Int` | `CodingKey: window_index` | フィールド不存在。実際: `window_id: String` ("@250") | ✅ 修正済み |
| `pane_index: Int` | `CodingKey: pane_index` | フィールド不存在 | ✅ 削除済み |
| `activity_state` 値 | lowercase ("running") | lowercase（cmd_json.rs の normalize 関数） | ✅ 正しい |

### 修正ファイル

| ファイル | 変更内容 |
|---------|---------|
| `DaemonModels.swift` | `windowIndex: Int` → `windowId: String`（CodingKey: `window_id`）、`paneIndex` 削除 |
| `AgtmuxDaemonClient.swift` | デフォルト socketPath を `/tmp/agtmux-$USER/agtmuxd.sock` に修正 |
| `CockpitView.swift` | `pane.windowIndex` → `pane.windowId` |
| `SidebarView.swift` | `pane.windowIndex` → `pane.windowId`（コンパイルエラー修正） |

### ビルド確認
- `swift build` → Build complete! 0.14s

### 残り T-009 作業（手動）
- agtmux daemon 起動後に `fetchSnapshot()` が実際データを返すか確認
- installed binary (`go/bin/agtmux`, Feb 26) は `list-panes` サブコマンド。v5 HEAD は `json`。**`json` を使う場合は `cargo install` で最新バイナリのリビルドが必要**

---

## 2026-03-01 — T-009〜T-011 完了 + クラッシュ修正多数

### 完了事項
- **T-009 DONE**: agtmux daemon 実機接続確認。`activity_state: null` の pane が `parseError` になるバグを修正（custom `init(from:)` + `decodeIfPresent ?? .unknown`）。commit `6a0f446`
- **T-010 DONE**: pane 選択 → tmux attach surface 切り替え動作確認。以下のクラッシュを修正:
  - `ghostty_config_finalize` 未呼び出しによる SIGSEGV（commit `91d4559`）
  - `action_cb` / clipboard callbacks の non-optional Zig fn ptr に nil 設定 → SIGSEGV（commit `b077b7b`）
  - スクロール方向反転（negation 除去 + trackpad 2x multiplier）（commit `805d238`）
- **T-011 DONE**: activity_state 表示はポーリングで動作確認済み。ユーザー確認完了。

### 発見した重要事項（lessons）

| 事象 | 根本原因 | 修正 |
|------|---------|------|
| `ghostty_surface_new` SIGSEGV | `ghostty_config_finalize` 未呼び出し — config 内部 defaults が未初期化のまま surface 作成 | `ghostty_app_new` 前に `load_default_files` + `load_recursive_files` + `finalize` を呼ぶ |
| `action_cb = nil` SIGSEGV | Zig `*const fn`（non-nullable）フィールドに nil → `CoreSurface.init` 内 `performAction(.cell_size)` で null call | 全 non-optional fn ptr（action, read_clipboard, confirm_read_clipboard, write_clipboard）をスタブで埋める |
| `close_surface_cb = nil` は OK | Zig で `?*const fn`（nullable optional）として宣言されているため nil が安全 | そのまま nil でよい |
| スクロール方向反転 | `scrollingDeltaY` を negation していた — Ghostty 本家 SurfaceView は raw で渡す | negation 除去 + `hasPreciseScrollingDeltas` 時に 2x multiplier |

### 次のアクション
- T-015〜T-021: SSH remote tmux feature（plan 承認済み）

---

## 2026-03-01 — T-015〜T-021 SSH Remote tmux（DONE）

### 設計方針
- リモート discovery: `ssh host tmux list-panes -a -F "..."` — **agtmux 不要**
- リモート VM に必要なのは tmux + SSH アクセスのみ
- agent state はリモート pane では `.unknown`（agtmux なし）
- terminal 接続: `ssh -t host tmux attach` または `mosh host -- tmux attach`
- config: `~/.config/agtmux-term/hosts.json`

### 実装済みファイル
| ファイル | 変更種別 |
|---------|---------|
| `Sources/AgtmuxTerm/RemoteHostsConfig.swift` | 新規作成 |
| `Sources/AgtmuxTerm/RemoteTmuxClient.swift` | 新規作成 |
| `Sources/AgtmuxTerm/DaemonModels.swift` | source フィールド追加、composite id |
| `Sources/AgtmuxTerm/AgtmuxDaemonClient.swift` | source = "local" タグ付け |
| `Sources/AgtmuxTerm/AppViewModel.swift` | マルチソースポーリング、offlineHosts |
| `Sources/AgtmuxTerm/SidebarView.swift` | ホスト別セクション表示 |
| `Sources/AgtmuxTerm/CockpitView.swift` | SSH/mosh コマンドビルダー |

---

## 2026-03-01 — Phase 5 GUI Redesign 開始（T-022〜T-024）

### 背景
agtmux 本体が v5 アーキテクチャに更新され、以下の新フィールドが `agtmux json` に追加された：
- `provider`: "claude" | "codex" | "gemini" | "copilot" | null
- `evidence_mode`: "deterministic" | "heuristic" | "none"
- `git_branch`: String?（cwd から自動導出）
- `current_cmd`: String?（実行中プロセス名）
- `current_path`: String?（旧 `cwd` フィールドのリネーム）
- `updated_at`: ISO 8601 文字列
- `age_secs`: Int?
- `presence` セマンティクス変更: 旧 "claude"|nil → 新 "managed"|"unmanaged"

### 確定 UI/UX 方針（ユーザー承認済み 2026-03-01）
| 方針 | 詳細 |
|------|------|
| ビューモード | by-session のみ（by-status 廃止、filter/sort で代替） |
| window grouping | なし（flat pane list within session）|
| session ヘッダー | sessionName + 代表 gitBranch 表示 |
| pane 行 | state dot + title + provider icon + age（グレー固定、色変化なし）|
| subtitle | なし |
| branch/cwd | hover tooltip で表示（常時非表示）|
| provider 表示 | SF Symbol アイコン（sparkles/terminal.fill/star.fill/airplane）|

### 対象タスク
- **T-022**: DaemonModels.swift — v5 スキーマ対応（Provider/EvidenceMode/PanePresence enum、新フィールド追加）
- **T-023**: AppViewModel.swift — panesBySession computed property 追加
- **T-024**: SidebarView.swift — by-session リデザイン（SessionBlockView、新 SessionRowView、tooltip）

---

## 2026-03-01 — T-022〜T-024 GUI Redesign（DONE）

### 実装ファイル

| ファイル | 変更内容 |
|---------|---------|
| `DaemonModels.swift` | Provider / PanePresence / EvidenceMode enum 追加；presence セマンティクス修正；gitBranch / currentCmd / evidenceMode / provider / updatedAt / ageSecs / currentPath フィールド追加；ISO 8601 dateDecodingStrategy 設定 |
| `AppViewModel.swift` | SessionGroup struct 追加；panesBySession computed property 追加；filteredPanes の .managed フィルタ修正（$0.isManaged）；sortedSources private helper 追加 |
| `SidebarView.swift` | SessionBlockView 新規（セッションヘッダー + flat pane list）；SessionRowView リデザイン（provider icon + age、subtitle なし、hover tooltip）；ProviderIcon / FreshnessLabel 新規；ActivityState/Provider 表示 helpers 更新 |
| `RemoteTmuxClient.swift` | `cwd:` → `currentPath:` リネーム対応 |

### 設計方針（確定）
- サイドバーは by-session のみ（window grouping なし）
- session ヘッダーに代表 gitBranch 表示
- pane 行: state dot + title + provider SF Symbol + age（グレー固定）
- branch/cwd/evidenceMode は `.help()` tooltip で表示
- provider icons: sparkles(claude) / terminal.fill(codex) / star.fill(gemini) / airplane(copilot)

### ビルド確認
- `swift build` → Build complete! (12.91s) エラーなし

---

## 2026-03-01 — T-025 バグ修正 + UI細改善（DONE）

### 背景
スクリーンショット確認で判明した問題の修正。

### 修正内容

| ファイル | 変更内容 |
|---------|---------|
| `DaemonModels.swift` | `primaryLabel` fallback: managed pane は `conversationTitle ?? currentCmd ?? paneId`（以前は `paneId` 直落ち） |
| `SidebarView.swift` | age 表示を running 状態で非表示に変更（idle/error/waiting のみ）。`ProviderIcon` を colored rounded rect + 頭文字（C/✦/G/P）に変更 |
| `CockpitView.swift` | `attachCommand` を `tmux attach-session -t %paneId` に変更。`shellEscaped()` 不要につき削除 |

### ビルド確認
- `swift build` → Build complete! (45.72s) エラーなし

---

## 2026-03-02 — バイナリ署名修正 + conversation_title 確認 + T-026 UI アイコン刷新

### agtmux バイナリ署名修正

| 事象 | 原因 | 修正 |
|------|------|------|
| AgtmuxTerm アプリが `~/go/bin/agtmux` を spawn すると exit 137 (SIGKILL) | "Code Signature Invalid" — アプリコンテキストはターミナルより厳格な署名検証を行うため、cargo install 後に再署名されていなかったバイナリが拒否された | `codesign --force --sign - /Users/virtualmachine/go/bin/agtmux` で ad-hoc 再署名 |

- CI/CD 通過後、agtmux が `brew install` で `/opt/homebrew/bin/agtmux` にインストール済み（Homebrew 管理バイナリは署名済み）

### conversation_title 動作確認

テスト daemon (`/tmp/agtmux-e2e-codex-title-*/agtmuxd.sock`) で確認:
- `%493`: `"claudeのOSC sequencesについて..."` — Claude Code セッションの実タイトル表示 ✅
- `%566/%578/%584`: `"Updated E2E Title"` — JSONL `customTitle` フィールド反映 ✅
- `%579/%585`: `"Custom Title Wins Over Summary"` — カスタムタイトル優先 ✅
- 実環境の Claude Code pane は JSONL `customTitle` が emit されるまで `conversation_title: null`（正常動作）

### T-026 UI アイコン刷新（DONE）

#### 変更内容

| 項目 | 変更前 | 変更後 |
|------|--------|--------|
| state indicator (idle/unmanaged) | グレードット | **非表示（Color.clear）** |
| state indicator (running) | 緑ドット | **SpinnerView（回転アニメーション付き緑弧）** |
| state indicator (waitingApproval) | オレンジドット | **`hand.raised.fill` (orange)** |
| state indicator (waitingInput) | 黄ドット | **`ellipsis.circle.fill` (yellow)** |
| state indicator (error) | 赤ドット | **`xmark.circle.fill` (red)** |
| session ヘッダー | sessionName のみ | **`folder.fill` アイコン + sessionName** |
| provider icon | colored rect + 頭文字 (C/✦/G/P) | **SVG バンドルから NSImage で描画** |

#### SVG ファイル（新規作成: `Sources/AgtmuxTerm/Resources/`）

| ファイル | 内容 | レンダリング |
|---------|------|------------|
| `icon-claude.svg` | 8本腕アスタリスク（orange #D97749）カスタム作成 | カラー |
| `icon-openai.svg` | OpenAI スワールロゴ（simple-icons `openai`） | `isTemplate=true`（ダーク/ライト追従） |
| `icon-gemini.svg` | Gemini 4尖星（simple-icons `googlegemini`、blue gradient） | カラー |
| `icon-copilot.svg` | GitHub Copilot アイコン（simple-icons `githubcopilot`） | `isTemplate=true`（ダーク/ライト追従） |

#### Package.swift 変更
- `resources: [.process("Resources")]` 追加 → `Bundle.module` でリソース参照可能に

#### ビルド確認
- `swift build` → Build complete! エラーなし

#### 発見した実装上の注意点（lessons）

| 問題 | 根本原因 | 修正 |
|------|---------|------|
| SwiftUI type-check timeout（Canvas closure） | Canvas 内に複雑な数式クロージャ → コンパイラがタイムアウト | `Canvas(renderer: codexRenderer)` として別メソッドに抽出 |
| `LinearGradient` type-check timeout | インライン `LinearGradient` が型推論を爆発させる | `private static let gradient` として切り出し |
| `cos` ambiguous reference | `CGFloat` 変数に `Double` 引数の `cos()` → 型推論失敗 | `CGFloat(cos(a))` と明示キャスト |
