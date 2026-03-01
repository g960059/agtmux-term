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
- T-009: daemon 統合テスト（socketPath を agtmux-v5 実装と照合）
- T-010: pane 選択 → surface 切り替え + shellEscaped 検証
- T-011: agent state リアルタイム表示確認
