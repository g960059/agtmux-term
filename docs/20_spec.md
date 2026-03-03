# Functional & Non-functional Specification

## Functional Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-001 | libghostty surface を NSView として SwiftUI 内に埋め込む | [MVP] |
| FR-002 | サイドバーで tmux pane を選択 → その pane を surface でアタッチ | [MVP] |
| FR-003 | agtmux daemon から `agtmux json` 相当のデータを定期取得（1秒間隔） | [MVP] |
| FR-004 | pane の activity_state を色・アイコンで表示（running/idle/waiting_approval/waiting_input/error） | [MVP] |
| FR-005 | 会話タイトル（conversation_title）をサイドバーに表示 | [MVP] |
| FR-006 | StatusFilter: All / Managed / Attention (waiting/error) / Pinned | [MVP] |
| FR-007 | IME（日本語・CJK）がネイティブ動作する（NSTextInputClient 準拠） | [MVP] |
| FR-008 | `tmux attach-session -t <session>` を surface 内で起動してペイン表示 | [MVP] |
| FR-009 | daemon 未起動時はオフラインモードで graceful degradation（クラッシュしない） | [MVP] |
| FR-010 | マルチサーフェス：複数 pane をタブ or 分割で同時表示 | [Post-MVP] |
| FR-011 | キーボードショートカットで pane 切り替え | [Post-MVP] |
| FR-012 | Pinned pane 機能（特定 pane を常に上位表示） | [Post-MVP] |

## Non-functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-Performance | ターミナルレンダリングフレームレート | ≥120fps（libghostty 内部タイマー駆動） |
| NFR-Latency | エージェント状態更新遅延 | ≤3秒 |
| NFR-Compatibility | 対応 macOS バージョン | macOS 14 (Sonoma) 以上 |
| NFR-Build | ビルド手順の完結性 | `swift build` + Zig 事前ビルド xcframework で完結 |
| NFR-Memory | メモリ使用量（idle 時） | ≤200MB（目安） |

## Constraints

| ID | Constraint |
|----|------------|
| CON-001 | libghostty API は unstable (internal API)。Ghostty 本体の Swift コードが常にリファレンス。破壊的変更に追従する責任がある |
| CON-002 | Zig 0.14.x が開発環境に必要（GhosttyKit.xcframework のビルドに使用） |
| CON-003 | agtmux daemon が起動していることが前提。daemon 未起動時はオフラインモード（UI は表示するが状態は空） |
| CON-004 | macOS 専用。Catalyst / iPad 対応は Non-goal |
| CON-005 | tmux が PATH で利用可能であること（pane アタッチに必要） |

## Activity State 定義

| State | 表示色 | 意味 |
|-------|--------|------|
| `running` | 緑 | エージェントがアクティブに処理中 |
| `idle` | グレー | 待機中（ユーザー入力待ちではない） |
| `waiting_approval` | 黄/オレンジ | ユーザーの承認を待っている（要注意） |
| `waiting_input` | 黄 | ユーザーの入力を待っている |
| `error` | 赤 | エラー発生 |
| `unknown` | グレー | 状態不明（daemon から情報なし） |

## StatusFilter 定義

| Filter | 表示対象 |
|--------|---------|
| `All` | 全 pane |
| `Managed` | agtmux が追跡している pane のみ（shell 除く） |
| `Attention` | `waiting_approval` / `waiting_input` / `error` のいずれか |
| `Pinned` | ユーザーがピン留めした pane [Post-MVP] |

## agtmux daemon JSON スキーマ（参考）

```json
{
  "version": 1,
  "panes": [
    {
      "pane_id": "%42",
      "session_name": "work",
      "window_index": 0,
      "pane_index": 0,
      "activity_state": "running",
      "presence": "claude",
      "evidence_mode": "deterministic",
      "conversation_title": "Fix auth bug in login flow",
      "cwd": "/home/user/project"
    }
  ]
}
```

---

# Phase 3: Ghostty + tmux Native Sync

> 設計確定: 2026-03-02 (4-agent parallel review 経由)

## Goals (Phase 3)

| ID | Goal | Priority |
|----|------|----------|
| G-001 | サイドバーを source → session → window → pane の4階層に変更 | 必須 |
| G-002 | macOS ネイティブ通知（waiting_approval / waiting_input / error 遷移時） | 必須 |
| G-003 | 複数 ghostty_surface_t を BSP レイアウトで同時表示する WorkspaceTab | 必須 |
| G-004 | WorkspaceTab 内で session をまたいで pane を配置できる | 必須 |
| G-005 | tmux window クリック → その window 内の pane 構成を Ghostty native splits で表示 | 必須 |
| G-006 | tmux control mode (`tmux -C`) で layout 変更をリアルタイムに Ghostty に反映 | 必須 |
| G-007 | サイドバーから tmux session/window/pane を作成・削除（右クリックメニュー） | 必須 |

## Non-Goals (Phase 3)

| ID | Non-Goal |
|----|----------|
| NG-001 | tmux window を隠蔽してアプリ独自の抽象だけを見せること |
| NG-002 | Ghostty ネイティブ tab/split API の使用（アプリが独自レイアウトエンジンを持つ） |
| NG-004 | Ghostty → tmux への resize 書き戻し（Phase 3 は tmux→Ghostty 一方向のみ） |
| NG-005 | DnD による BSP ツリー編集（Phase 4 以降） |
| NG-006 | 一般ユーザーへの公開 |
| NG-007 | 固定4プリセット（tmux の実際の layout を dynamic に反映するため不要） |

## Acceptance Criteria (Phase 3)

### AC-001: サイドバー 4 階層
- [ ] source → session → window → pane の4階層表示
- [ ] window block に running 数・attention 数バッジ
- [ ] window が1つのみの session では window block を省略可能

### AC-002: macOS 通知
- [ ] waiting_approval / waiting_input / error 遷移時に UNUserNotificationCenter 通知
- [ ] 通知クリック → 対象 pane を前面表示
- [ ] 30秒以内の重複通知は抑制
- [ ] アプリがフォアグラウンド（NSApplication.shared.isActive）のとき通知しない

### AC-003: WorkspaceTab
- [ ] タブバー表示（Cmd+T 新規, Cmd+W 閉じる, Cmd+1~9 切り替え）
- [ ] BSP レイアウトで複数 surface を配置
- [ ] 異なる session の pane を同じタブ内に配置可能

### AC-004: BSP レイアウト
- [ ] `LayoutNode: indirect enum { .leaf(LeafPane), .split(SplitContainer) }` で実装
- [ ] Divider ドラッグで ratio を 10%〜90% で調整（clamp はモデル側）
- [ ] Opt+Cmd+Arrow でキーボードリサイズ（5% 刻み）
- [ ] leaf を閉じると sibling が parent に promote

### AC-005: Ghostty + tmux Sync
- [ ] linked session (`tmux new-session -s agtmux-{uuid} -t {session}`) 経由で独立表示
- [ ] tmux control mode でレイアウト変更をリアルタイム受信
- [ ] pane 追加・終了が Ghostty side に反映

### AC-006: リサイズ整合
- [ ] Ghostty surface resize → `tmux resize-pane -t %paneId -x cols -y rows`（16ms debounce）
- [ ] Phase 3 は tmux→Ghostty 一方向のみ

### AC-007: tmux 管理
- [ ] 右クリック: pane → Kill Pane（即実行）
- [ ] 右クリック: window → New Pane / Kill Window（Kill は確認あり）
- [ ] 右クリック: session → New Window / Kill Session（Kill は確認あり）
- [ ] 右クリック: source ヘッダー → New Session（名前入力シート）
- [ ] kill-session 前に TmuxControlMode.stop() を呼ぶ（SIGPIPE 防止）

### AC-008: クロスセッション配置
- [ ] WorkspaceTab BSP 内で異なる session の window/pane を並べられる
- [ ] sidebar pane クリック → 現在の focused leaf に表示
- [ ] sidebar window クリック → その window 全 pane を BSP で表示
