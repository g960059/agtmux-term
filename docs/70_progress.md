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

### 次のアクション
- T-001: GhosttyKit.xcframework ビルド環境構築から着手
- Ghostty リポジトリの取得方法を決定（submodule vs clone）
- Zig 0.14.x のインストール確認

### 未解決事項
- [ ] GhosttyKit.xcframework をリポジトリにコミットするか、ビルドスクリプトで再生成するかの決定
- [ ] agtmux daemon の socket path（デフォルト）の確認

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
- T-001: GhosttyKit.xcframework ビルド環境構築から着手
- Ghostty リポジトリの取得方法を決定（submodule vs clone）
- Zig 0.14.x のインストール確認
