# Functional & Non-functional Specification

## Functional Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-001 | libghostty surface を NSView として SwiftUI 内に埋め込む | [MVP] |
| FR-002 | サイドバーに local / remote の **real tmux sessions** を表示し、pane/window 由来の metadata を exact pane row 単位で重ねて表示する | [MVP] |
| FR-003 | local tmux inventory を1秒間隔で取得し、agtmux daemon の `ui.bootstrap.v2` / `ui.changes.v2` で local metadata overlay を同期する。local metadata の exact identity は `session_key` + `pane_instance_id` を round-trip し、provider / activity の overlay は current inventory 上の exact pane row にだけ適用する。`session_key` は overlay/session identity 用の opaque key であり、visible tmux `session_name` と同一とは仮定しない。bootstrap correlation は `session_name + window_id + pane_id` を使い、change correlation は bootstrap で学習した exact identity を使う。overlay cache は pane location ではなく exact identity で保持し、current daemon epoch が incompatible になった時点で stale cache を残さず即座に inventory-only publish へ切り替える。`session_key` / `pane_instance_id` / `session_name` / `window_id` のいずれかが欠ける local managed row、または legacy identity field `session_id` を含む local sync-v2 pane payload は invalid とみなし、app はその row を採用せず local metadata path 全体を inventory-only に degrade して `daemon incompatible` を surfacing する | [MVP] |
| FR-004 | pane の activity_state を色・アイコンで表示する（running / idle / waiting_approval / waiting_input / error / unknown） | [MVP] |
| FR-005 | 会話タイトル（conversation_title）をサイドバーに表示する | [MVP] |
| FR-006 | StatusFilter: All / Managed / Attention / Pinned を提供する（Pinned は UI 準備のみでも可） | [MVP] |
| FR-007 | IME（日本語・CJK）がネイティブ動作する（NSTextInputClient 準拠） | [MVP] |
| FR-008 | terminal tile は 1つの **real tmux session** に直接アタッチし、close と kill を分離する | [MVP] |
| FR-009 | daemon unavailable / daemon incompatible / remote offline / session missing / path missing を fail-loudly に surfacing する | [MVP] |
| FR-010 | Workbench は terminal / browser / document companion surfaces を split layout として保存・復元できる | [MVP] |
| FR-011 | 1つの real tmux session は app 全体で1つの visible terminal tile にのみ存在できる | [MVP] |
| FR-012 | terminal からの explicit CLI bridge (`agt open <url-or-file>`) で browser / document companion surfaces を開ける | [MVP] |
| FR-013 | packaged app は bundle 同梱の release `agtmux` binary を app-owned daemon として起動し、local metadata は app-owned UDS socket を使う | [MVP] |
| FR-014 | 開発時の daemon binary 切替は `AGTMUX_BIN` explicit override のみを正式サポートし、PATH 上 `agtmux` への暗黙 fallback は行わない | [MVP] |
| FR-015 | `ui.bootstrap.v2` / `ui.changes.v2` を持たない古い daemon は非互換として明示 surfacing し、silent compatibility mode は持たない | [MVP] |
| FR-016 | local daemon runtime / replay / overlay / focus の health を pane inventory と独立してサイドバーへ surfacing する | [A2] |
| FR-017 | term は daemon の `ui.health.v1` を受け取り、health status / lag / resync reason / freshness を UI に表示できる | [A2] |
| FR-018 | browser / document companion surfaces は pin されたものだけ Workbench 復元対象とし、unpinned は transient とする | [MVP] |
| FR-019 | restore 時の broken reference に対し、`Retry` / `Rebind` / `Remove Tile` を提供する | [MVP] |
| FR-020 | directory tile は MVP では実装しないが、将来 additive extension として追加できる tile model を保つ | [Post-MVP] |
| FR-021 | terminal tile は right click・主要 shortcut・tmux 操作感を app が上書きしない | [MVP] |
| FR-022 | remote URL は指定どおりに開き、implicit localhost rewrite や implicit SSH tunnel は行わない | [MVP] |
| FR-023 | active pane selection は runtime-only の canonical reducer state を single source of truth とし、`desired ActivePaneRef`、`observed ActivePaneRef`、rendered client binding (`client_tty`) を一体で扱う。sidebar click・duplicate reveal は desired 側、terminal-originated pane change・focused tile observation は observed 側を更新し、両者の解決は同じ reducer を通す。pane sync は local metadata overlay の有無に依存してはならず、inventory-only rows しか無いときでも same-session pane retarget と sidebar highlight は current inventory から解決されなければならない。copied pane snapshot、local view state、persisted layout hint を source of truth にしない | [MVP] |

## Non-functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-Performance | ターミナルレンダリングフレームレート | ≥120fps（libghostty 内部タイマー駆動） |
| NFR-Latency | エージェント状態更新遅延 | ≤3秒 |
| NFR-Compatibility | 対応 macOS バージョン | macOS 14 (Sonoma) 以上 |
| NFR-Build | ビルド手順の完結性 | `swift build` + Zig 事前ビルド xcframework で完結 |
| NFR-Memory | メモリ使用量（idle 時） | ≤250MB（目安。companion surfaces を含む） |
| NFR-Lightweight | IDE-like background load を持たない | no project indexer / no heavyweight explorer / lazy companion loading |

## Constraints

| ID | Constraint |
|----|------------|
| CON-001 | libghostty API は unstable (internal API)。Ghostty 本体の Swift コードが常にリファレンス。破壊的変更に追従する責任がある |
| CON-002 | Zig 0.14.x が開発環境に必要（GhosttyKit.xcframework のビルドに使用） |
| CON-003 | tmux / SSH が real session existence の source of truth。agtmux daemon は metadata / observability overlay として扱う |
| CON-004 | macOS 専用。Catalyst / iPad 対応は Non-goal |
| CON-005 | tmux が PATH で利用可能であること（real session attach に必要） |
| CON-006 | terminal tile は normal Ghostty/tmux view として振る舞い、独自 terminal UX を持ち込まない |
| CON-007 | hidden linked-session を normal product path の前提にしない |

## MVP Semantics

### Terminal Tile

- `1 terminal tile = 1 real tmux session`
- terminal tile close は Workbench から外すだけで、tmux session を kill しない
- kill session は explicit action
- duplicate session open は existing tile を reveal / focus する
- same-session の別 pane row を選んだ場合は、existing tile を再利用したまま runtime active-pane intent を更新し、exact window / pane へ navigate する
- active pane selection は copied pane snapshot ではなく canonical active-pane state として保持する
- reducer は `desired` と `observed` の pane state を分離し、古い observed state が新しい desired selection を上書きしない
- terminal 内で pane が変わった場合も、sidebar highlight は同じ active-pane state に追従する
- Workbench persistence は terminal session identity を保存するが、live pane focus は autosave しない
- same-session multi-view は MVP では不採用

### Workbench

- Workbench は app-level saved layout であり、tmux tab / tmux window ではない
- Workbench は split tree、focused tile、terminal session refs、pinned companion surfaces を保存する
- Workbench は autosave を前提とする

### Companion Surfaces

- MVP の first-class companion surface は browser と document
- browser / document は explicit action でのみ開く
- browser / document は duplicate 可
- pin された browser / document のみ restore 対象
- directory tile は Post-MVP extension

### Restore / Error Semantics

- restore は missing target を silent fallback しない
- missing target は placeholder error state として残す
- `Rebind` は manual exact-target reassignment のみを意味する

Visible error states:

- `daemon unavailable`
- `daemon incompatible`
- `Host offline`
- `tmux unavailable`
- `Session missing`
- `Path missing`
- `Access failed`

### Remote URL Semantics

- URL は指定どおりに開く
- remote `http://localhost:3000` を local reachable URL に rewrite しない
- implicit SSH tunnel を張らない

## Activity State 定義

| State | 表示色 | 意味 |
|-------|--------|------|
| `running` | 緑 | エージェントがアクティブに処理中 |
| `idle` | グレー | 待機中（ユーザー入力待ちではない） |
| `waiting_approval` | 黄/オレンジ | ユーザーの承認を待っている（要注意） |
| `waiting_input` | 黄 | ユーザーの入力を待っている |
| `error` | 赤 | エラー発生 |
| `unknown` | グレー | 状態不明（metadata なし） |

## StatusFilter 定義

| Filter | 表示対象 |
|--------|---------|
| `All` | 全 pane |
| `Managed` | agtmux が追跡している pane のみ（shell 除く） |
| `Attention` | `waiting_approval` / `waiting_input` / `error` のいずれか |
| `Pinned` | ユーザーが pin した項目 [Post-MVP UI拡張可] |

## Workbench Acceptance Criteria [MVP]

### AC-001: Real Session Sidebar
- [ ] local / remote real tmux sessions が表示される
- [ ] pane/window 由来 metadata が session browser として surfacing される
- [ ] hidden linked-session を normal path で作らないため、`tmux ls` と app の session view が矛盾しない

### AC-002: Terminal Tile
- [ ] session 選択で real tmux session が terminal tile に表示される
- [ ] terminal は Ghostty/tmux の通常操作感を保つ
- [ ] close tile と kill session が分離される
- [ ] 同じ session 内の別 pane row を選ぶと、visible terminal tile は増えずに exact pane へ切り替わる
- [ ] main terminal 内で pane が変わると、sidebar highlight も exact pane row に追従する

### AC-003: Workbench Layout
- [ ] terminal / browser / document を同一 Workbench に配置できる
- [ ] Workbench は split layout と focused tile を保存できる
- [ ] app 再起動後に Workbench が復元される

### AC-004: Duplicate Session Prevention
- [ ] 同じ real tmux session を 2つの visible terminal tile として同時に開けない
- [ ] duplicate open は existing tile を reveal / focus する
- [ ] duplicate open に exact pane intent がある場合は、その intent を existing tile に適用する

### AC-005: CLI Bridge
- [ ] `agt open <url-or-file>` で browser / document tile を開ける
- [ ] bridge unavailable 時は明示エラーになる
- [ ] remote shell からでも terminal-scoped bridge で同じ操作モデルを使える

### AC-006: Restore / Failure Handling
- [ ] missing session / missing path / host offline を placeholder state として表示する
- [ ] `Retry` / `Rebind` / `Remove Tile` を提供する
- [ ] restore 時に silent retarget / silent downgrade をしない

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

## agtmux daemon local metadata contract（A1）

- bootstrap:
  - `ui.bootstrap.v2` は `epoch` / `snapshot_seq` / `panes` / `sessions` / `generated_at` / `replay_cursor` を返す
- changes:
  - `ui.changes.v2` は `epoch` / `changes` / `from_seq` / `to_seq` / `next_cursor` を返す
  - continuity を維持できない場合は `resync_required: { current_epoch, latest_snapshot_seq, reason }` を返す
- exact identity:
  - local sync-v2 pane payload は `session_key` と `pane_instance_id` を bootstrap / changes / XPC transport で round-trip する
  - app は missing exact-identity fields を silent fallback しない
  - exact-identity field が欠ける row は managed/provider/activity overlay 対象にしない
  - local sync-v2 pane payload に legacy identity field `session_id` が混ざる場合、app は additive compatibility とみなさず payload 全体を incompatible として reject する
  - bootstrap / changes payload に exact-identity field 欠落がある場合、app は stale overlay cache を保持せず inventory-only に degrade し、`daemon incompatible` として surfacing する
- cursor ownership:
  - app process は raw cursor を保持しない
  - bundled XPC service もしくは in-process `AgtmuxSyncV2Session` が cursor owner になる
- daemon ownership:
  - packaged app は app bundle `Contents/Resources/Tools/agtmux` を正とする
  - local daemon socket は `~/Library/Application Support/AGTMUXDesktop/agtmuxd.sock` を使い、global `/tmp/agtmux-$USER/agtmuxd.sock` は共有しない
  - 開発時は `AGTMUX_BIN=/abs/path/to/source/build/agtmux` で source build override を行う
- incompatibility handling:
  - bundled daemon が存在せず、かつ `AGTMUX_BIN` override も無い場合、term は managed local daemon runtime unavailable として明示 surfacing する
  - daemon が `ui.bootstrap.v2` / `ui.changes.v2` を実装していない場合、term はその daemon を互換対象とみなさない
  - 表示は fail-loudly とし、missing runtime は `daemon unavailable`、old protocol は `daemon incompatible` として区別して surfacing する

## Local health-strip contract

- `ui.health.v1` is observability only; it never invents or removes tmux panes/sessions
- if local tmux inventory goes offline after a health snapshot was published, the sidebar keeps showing the last known health strip instead of clearing it
- while local inventory is offline, the app continues refreshing `ui.health.v1`; newer health snapshots replace the strip even if pane inventory is still stale/offline
- if no health snapshot is available, the app keeps the health strip absent rather than rendering guessed or stale placeholder health UI
- A2 observability:
  - daemon は additive RPC `ui.health.v1` を提供し、`runtime` / `replay` / `overlay` / `focus` health を返す
  - health payload は pane inventory や `ui.bootstrap.v2` / `ui.changes.v2` の成功有無と独立に取得できる
  - term は health を UI annotation として扱い、pane row の existence contract は変えない
