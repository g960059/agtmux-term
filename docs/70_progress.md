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
- [ ] `ghostty_surface_config_s` に command/argv を設定する具体的な API の確認（Ghostty 本体 `src/apprt/swift/` を参照）
- [ ] GhosttyKit.xcframework をリポジトリにコミットするか、ビルドスクリプトで再生成するかの決定
- [ ] agtmux daemon の socket path（デフォルト）の確認
