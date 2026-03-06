# Foundation (stable intent — escalation required to change)

## What

**agtmux-term** は、AI エージェント（Claude Code, Codex など）が動く **real tmux sessions** を管理・監視するための、tmux-first な macOS cockpit アプリケーション。

**主要コンポーネント:**
- **左サイドバー**: real tmux session 一覧、pane/window 由来のエージェント状態（Running / Waiting / Idle / Error など）、会話タイトル
- **右メインパネル**: libghostty による高品質ターミナルと、明示的に開く browser / document companion surfaces
- **Workbench**: terminal と companion surfaces を並べて保存する app-level layout（tmux tab ではない）

**バックエンド接続:**
- tmux / SSH が real session existence の source of truth
- agtmux daemon（Rust 製）は local metadata overlay と agent observability を供給する

## For Whom

**P1 — AI-heavy macOS developer / tmux power user**: Claude Code / Codex などの AI エージェントを複数 tmux session で並行実行する開発者。
- 複数のエージェント session を local / remote をまたいで同時に監視したい
- どのエージェントが Waiting（承認待ち）か即座に分かりたい
- tmux / Ghostty / shell の既存操作感を壊したくない
- PR や設計 docs を terminal の近くに置きたいが、IDE 的な重さは避けたい
- Ghostty 相当のターミナル品質を期待している

## Why Now

agtmux daemon と Ghostty ベースのターミナル基盤が揃い、プロダクトの重心を「tmux を隠す UI」ではなく「tmux-first cockpit」へ切り直せる段階に来た。

- **POC の教訓**: `exp/go-codex-implementation-poc` ブランチで Swift/SwiftUI 製 POC を構築したが、SwiftTerm（ターミナルバックエンド）が根本的な問題を持っていた
  - IME（日本語・CJK）が不安定
  - 10fps のレンダリングレート（実用不可）
  - カーソル位置ズレ
- **解決策**: SwiftTerm → libghostty（Ghostty のコア C ライブラリ）へ置き換え
- **次の課題**: linked-session ベースの workspace は tmux power user の mental model と衝突し、外部 tmux tooling ともズレることが分かった
- **機会**: 既存の Ghostty / tmux / metadata 基盤を活かしつつ、real session と explicit companion surfaces を中心に UX を再定義できる

## User Stories

| ID | Story |
|----|-------|
| US-001 | real tmux session を Workbench 上の terminal tile にすぐ開ける（`tmux attach` を手で打ち直さなくてよい） |
| US-002 | サイドバーで全エージェントの状態（Running / Waiting / Idle / Error）を一目で確認できる |
| US-003 | Waiting または Error の pane を素早く見つけて対応できる |
| US-004 | terminal の操作感は Ghostty / tmux / shell のままで使える |
| US-005 | PR や設計 docs を必要な時だけ terminal の横に開ける |
| US-006 | app の外から SSH / tmux で入っても、同じ real session に自然にアクセスできる |
| US-007 | 日本語 IME で快適に入力できる（候補ウィンドウが正しい位置に表示される） |
| US-008 | remote host / session / path が壊れているとき、silent fallback ではなく明示エラーで気づける |

## Goals

| ID | Goal |
|----|------|
| G-001 | ターミナル品質が Ghostty 同等（IME・GPU レンダリング・正確なカーソル・VT パーサ精度） |
| G-002 | tmux を visible source of truth とし、normal path で hidden tmux namespace pollution を発生させない |
| G-003 | サイドバーの agent observability がリアルタイム更新される（3秒以内の遅延） |
| G-004 | Workbench が real tmux sessions と explicit companion surfaces を saved layout として扱える |
| G-005 | terminal area が普通の terminal として振る舞う（右クリックや主要 shortcut を app が奪わない） |
| G-006 | remote failure や missing target を fail-loudly に surfacing する |

## Non-Goals

| ID | Non-Goal |
|----|----------|
| NG-001 | Linux / Windows 対応（macOS 専用。macOS 14 Sonoma 以上のみ） |
| NG-002 | agtmux daemon 機能の拡張（daemon は `agtmux-v5-architecture-blueprint` リポジトリで管理） |
| NG-003 | IDE-style project indexer / heavyweight explorer / plugin system |
| NG-004 | hidden linked-session を使った same-session multi-view を MVP の中心機能として維持すること |
| NG-005 | terminal を独自ルールで再定義すること（custom shell / shortcut hijack / app-local tmux model） |
| NG-006 | implicit localhost tunneling や silent remote fallback を MVP に入れること |
| NG-007 | Web 版・Electron 版（ネイティブ macOS アプリのみ） |

## Global Acceptance Criteria

- `swift build` がエラーなしで完了する
- libghostty surface が Metal GPU で描画される
- 日本語 IME（候補ウィンドウを含む）が正常動作する
- real tmux session が sidebar / terminal tile の source of truth として扱われる
- Workbench で terminal と explicit browser / document surfaces を並べられる
- normal product path で hidden linked-session に依存しない
- daemon / remote host / session / path の失敗が crash ではなく明示状態として surfacing される
