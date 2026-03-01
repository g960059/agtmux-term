# Review Pack — T-006a〜T-008 Phase 2 Sidebar UI

## Objective
- Tasks: T-006a, T-006b, T-006c, T-007, T-008
- Phase: 2 (Sidebar UI Port)
- Acceptance criteria: 全項目実装済み

## Summary
- `DaemonModels.swift`: `AgtmuxPane` (Codable/Identifiable)・`AgtmuxSnapshot`・`StatusFilter` を spec JSON スキーマ準拠で実装。`needsAttention`・`isPinned` computed property 含む。
- `AgtmuxDaemonClient.swift`: `actor` + `terminationHandler + withCheckedThrowingContinuation`（`waitUntilExit()` 不使用）。`AGTMUX_BIN` → PATH 解決。stderr 伝播。`DaemonError` 3 ケース。
- `AppViewModel.swift`: `@MainActor ObservableObject`。1 秒ポーリング、`pollingTask == nil` による多重起動防止、`CancellationError` + `Task.sleep` キャンセルの両方を適切に処理。
- `SidebarView.swift`: `FilterBarView`・`SessionRowView`（activity color、conversationTitle、presence badge）・`SidebarView`（offline banner）の 3 SwiftUI コンポーネント。
- `CockpitView.swift`: `HSplitView { SidebarView, TerminalPanel }`。`@MainActor Coordinator` が `$selectedPane` を購読し `GhosttyApp.shared.newSurface` で surface 切り替え。`shellEscaped()` による POSIX クォートエスケープ。
- `main.swift`: `NSHostingView<CockpitView>` で SwiftUI を NSWindow に埋め込み。`AppViewModel` を EnvironmentObject として注入。

## Change scope
| ファイル | 変更内容 |
|---------|---------|
| `Sources/AgtmuxTerm/DaemonModels.swift` | 新規 (76 行) |
| `Sources/AgtmuxTerm/AgtmuxDaemonClient.swift` | 新規 (105 行) |
| `Sources/AgtmuxTerm/AppViewModel.swift` | 新規 (76 行) |
| `Sources/AgtmuxTerm/SidebarView.swift` | 新規 (~150 行) |
| `Sources/AgtmuxTerm/CockpitView.swift` | 新規 (80 行) |
| `Sources/AgtmuxTerm/main.swift` | 更新（NSHostingView + AppViewModel） |
| `docs/60_tasks.md` | T-006a〜T-008 IN_PROGRESS/DONE に更新 |
| `docs/70_progress.md` | Phase 2 完了記録 |

## Verification evidence
- `swift build` → `Build complete! (8.73s)` PASS（エラーなし・警告なし）
- SourceKit エラーは全て偽陽性（xcframework binary target + cross-file 解決の既知制限）
- `DaemonError.parseError(String)` — design doc の bare `case parseError` は内部矛盾。`String` associated value が正しい（`Fail loudly` ポリシー準拠）
- `@MainActor Coordinator` — SwiftUI の `updateNSView` は常に main thread で呼ばれるため安全。strict concurrency 要件を満たす。

## Risk declaration
- Breaking change: no
- Fallbacks: none（CLAUDE.md 準拠）
- Known gaps / follow-ups:
  - [ ] T-009: 実機 daemon 接続テスト（socketPath のデフォルト値を agtmux-v5 実装と照合）
  - [ ] T-010: pane 選択 → surface 切り替え手動確認
  - [ ] T-011: activity_state リアルタイム反映確認
  - [ ] SidebarView の `FilterBarView` でフィルターテキストが日本語対応かは T-009 時に確認

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
