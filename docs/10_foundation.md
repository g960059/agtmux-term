# Foundation (stable intent — escalation required to change)

## What

**agtmux-term** は、AI エージェント（Claude Code, Codex など）が動く tmux セッションを管理・監視するための macOS ターミナルアプリケーション。

**主要コンポーネント:**
- **左サイドバー**: tmux セッション一覧、エージェント状態（Running / Waiting / Idle など）、会話タイトル
- **右メインパネル**: libghostty による高品質ターミナル（GPU レンダリング、ネイティブ IME、正確な VT パーサ）

**バックエンド接続**: agtmux daemon（Rust 製）から UDS JSON-RPC 経由で状態を取得。

## For Whom

**P1 — AI-heavy macOS developer**: Claude Code / Codex などの AI エージェントを複数 tmux session で並行実行する開発者。
- 複数のエージェントセッションを同時に監視したい
- どのエージェントが Waiting（承認待ち）か即座に分かりたい
- Ghostty 相当のターミナル品質を期待している

## Why Now

agtmux daemon（エージェント状態推定エンジン）が完成した。あとは UI だけ。

- **POC の教訓**: `exp/go-codex-implementation-poc` ブランチで Swift/SwiftUI 製 POC を構築したが、SwiftTerm（ターミナルバックエンド）が根本的な問題を持っていた
  - IME（日本語・CJK）が不安定
  - 10fps のレンダリングレート（実用不可）
  - カーソル位置ズレ
- **解決策**: SwiftTerm → libghostty（Ghostty のコア C ライブラリ）へ置き換え
- **POC の資産**: サイドバーの AppViewModel・UI コードは品質が高く流用可能

## User Stories

| ID | Story |
|----|-------|
| US-001 | pane 選択でそのターミナルに即フォーカス（`tmux attach` コマンドを手動実行不要） |
| US-002 | サイドバーで全エージェントの状態（Running/Waiting/Idle）を一目で確認できる |
| US-003 | Waiting（承認待ち）または Error の pane を素早く見つけて対応できる |
| US-004 | 会話タイトル（conversation_title）がサイドバーに表示され、どの作業をしているか分かる |
| US-005 | 日本語 IME で快適に入力できる（候補ウィンドウが正しい位置に表示される） |

## Goals

| ID | Goal |
|----|------|
| G-001 | ターミナル品質が Ghostty 同等（IME・GPU レンダリング・正確なカーソル・VT パーサ精度） |
| G-002 | サイドバーのエージェント状態がリアルタイム更新（3秒以内の遅延） |
| G-003 | サイドバーで pane を選択したら対応するターミナルが即座に表示される |

## Non-Goals

| ID | Non-Goal |
|----|----------|
| NG-001 | Linux / Windows 対応（macOS 専用。macOS 14 Sonoma 以上のみ） |
| NG-002 | agtmux daemon 機能の拡張（daemon は `agtmux-v5-architecture-blueprint` リポジトリで管理） |
| NG-003 | 独自シェル機能・プラグインシステム（ターミナル以外の UI は最小限） |
| NG-004 | Windows/Linux TMux の汎用 UI ツール（AI エージェント監視に特化） |
| NG-005 | Web 版・Electron 版（ネイティブ macOS アプリのみ） |

## Global Acceptance Criteria

- `swift build` がエラーなしで完了する
- libghostty surface が Metal GPU で描画される
- 日本語 IME（候補ウィンドウを含む）が正常動作する
- agtmux daemon が起動していれば、pane 一覧がサイドバーに表示される
- daemon 未起動時はオフラインモードで graceful degradation する（クラッシュしない）
