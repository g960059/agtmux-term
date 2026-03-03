# Review Pack — Phase 6: Workspace BSP + Ghostty Surface Management (T-034〜T-042)

## Objective
- Tasks: T-034, T-035, T-036, T-037, T-038, T-039, T-040, T-041, T-042
- Phase: 6 (Workspace BSP + tmux control infrastructure)
- 全 acceptance criteria: 実装済み・ビルド確認済み

## Summary
Phase 6 で追加した全コンポーネントのレビュー。

1. **LayoutNode.swift** (NEW) — BSP ツリー型 (`LayoutNode`, `LeafPane`, `SplitContainer`, `SplitAxis`, `LinkedSessionState`) + ユーティリティ (splitLeaf, removingLeaf, replacing)
2. **WorkspaceStore.swift** (NEW) — `@Observable @MainActor` タブ管理・BSP 操作。`placePane()` (Mode A)、`placeWindow()` (Mode B)、`%layout-change` 追従
3. **WorkspaceArea.swift** (NEW) — SwiftUI レイアウト: TabBarView / LayoutNodeView / SplitContainerView / GhosttyPaneTile / _GhosttyNSView (NSViewRepresentable)
4. **SurfacePool.swift** (NEW) — Ghostty surface ライフサイクル管理 (`active→backgrounded→pendingGC(5s)→defunct`)
5. **LinkedSessionManager.swift** (NEW) — tmux linked session 作成・破棄 (TmuxCommandRunner actor + TmuxCommandError)
6. **TmuxControlMode.swift** (NEW) — `tmux -C attach-session` subprocess + AsyncStream + 指数バックオフ再接続
7. **TmuxControlModeRegistry.swift** (NEW) — TmuxControlMode ライフサイクル管理 + `safeKillSession()`
8. **TmuxManager.swift** (NEW) — session/window/pane 作成・削除操作
9. **TmuxLayoutConverter.swift** (NEW) — tmux `#{window_layout}` 文字列 → LayoutNode BSP パーサ
10. **AppViewModel.swift** (MOD) — `WindowGroup`/`SessionGroup` 追加、`panesBySession` 4階層グループ、`fetchAll()` internal化
11. **SidebarView.swift** (MOD) — 4 階層 UI (SourceHeaderView/SessionBlockView/WindowBlockView/PaneRowView)、TmuxManager 配線
12. **GhosttyTerminalView.swift** (MOD) — `clearSurface()` 追加
13. **CockpitView.swift** (MOD) — WorkspaceArea 統合
14. **main.swift** (MOD) — WorkspaceStore 生成・inject

## Change scope
| ファイル | 変更種別 | 行数目安 |
|---------|---------|---------|
| `Sources/AgtmuxTerm/LayoutNode.swift` | NEW | 230 行 |
| `Sources/AgtmuxTerm/WorkspaceStore.swift` | NEW | 420 行 |
| `Sources/AgtmuxTerm/WorkspaceArea.swift` | NEW | 420 行 |
| `Sources/AgtmuxTerm/SurfacePool.swift` | NEW | ~250 行 |
| `Sources/AgtmuxTerm/LinkedSessionManager.swift` | NEW | 130 行 |
| `Sources/AgtmuxTerm/TmuxControlMode.swift` | NEW | 310 行 |
| `Sources/AgtmuxTerm/TmuxControlModeRegistry.swift` | NEW | 65 行 |
| `Sources/AgtmuxTerm/TmuxManager.swift` | NEW | 155 行 |
| `Sources/AgtmuxTerm/TmuxLayoutConverter.swift` | NEW | 200 行 |
| `Sources/AgtmuxTerm/AppViewModel.swift` | MOD (全面改訂) | 220 行 |
| `Sources/AgtmuxTerm/SidebarView.swift` | MOD | 510 行 |
| `Sources/AgtmuxTerm/GhosttyTerminalView.swift` | MOD (clearSurface追加) | 小 |
| `Sources/AgtmuxTerm/CockpitView.swift` | MOD | 小 |
| `Sources/AgtmuxTerm/main.swift` | MOD | 小 |

## Verification evidence
- `swift build` → **Build complete! (32.92s)** ✅
- `swift run` → アプリ起動確認、サイドバー pane 一覧表示確認 ✅
- LinkedSessionManager CLI 検証: `tmux new-session -d -s "agtmux-{uuid}" -t main` → `select-window` → `kill-session` 全 PASS ✅
- TmuxLayoutConverter: 手動トレース確認 (`{...}` / `[...]` 両パターン) ✅

## Risk declaration
- **Breaking change**: no（既存機能は CockpitView → WorkspaceArea に統合、後方互換性を維持）
- **Fallbacks**: none（CLAUDE.md 方針通り）
- **Known gaps / follow-ups**:
  - T-032 (macOS 通知) が唯一の P1 未実装タスク
  - DividerHandle の onHover に `cursor.pop()` なし（cursor が sticky になるリスク、Post-MVP）
  - SurfacePool の GC タイマーは Timer ベース（MainActor での連続実行）
  - TmuxControlMode の readLoop が `availableData` ポーリング（10ms sleep）— pipe が閉じてもすぐ終わらないリスク
  - `onKeyPress` の `phases: .down` workaround（modifiers パラメータ非存在）

## Reviewer request
- Verdict: **GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO**
- 重点確認: 並行処理の安全性 (actor isolation)、メモリ安全性 (surface free / dangling pointer)、tmux subprocess ライフサイクル
- NEED_INFO の場合: 最大 3 件・具体的な不足情報のみ（広範探索不可）

---

## コード全文（参照用）

### LayoutNode.swift
```swift
// 略（docs/85_reviews/ 参照 — 実ファイルは Sources/AgtmuxTerm/LayoutNode.swift）
```

> 実コードは `Sources/AgtmuxTerm/` 以下の各ファイルを参照してください。
