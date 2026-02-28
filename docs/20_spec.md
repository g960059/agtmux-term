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
