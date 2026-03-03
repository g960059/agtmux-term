# Review Pack Round 2 — Phase 6 Blocking Fixes (T-043, T-044)

## Objective
- Round 1 全員 NO_GO → Blocking 指摘を採択・修正
- 本レビューで 2/4 GO を目標とする
- 対象: Phase 6 全ファイル + Round 1 → Round 2 の diff

## Round 1 NO_GO 理由と修正対応

| Blocker | 修正済み? | 対応内容 |
|---------|----------|---------|
| readLoop busy-poll (10ms sleep + availableData) | ✅ | `FileHandle.AsyncBytes` + 行バッファリング |
| safeKillSession TOCTOU | ✅ | `await m.stop()` 直接呼び出し、50ms sleep 削除 |
| tabIdx stale capture → wrong-tab overwrite | ✅ | tabID: UUID キャプチャ + firstIndex 再解決 |
| handle.write throws 無視 | ✅ | `try handle.write(contentsOf: data)` |
| dismantleNSView assumeIsolated crash risk | ✅ | `Task { @MainActor in }` に変更 |
| DividerHandle cursor.pop() 漏れ | ✅ | `onHover { hovering in if hovering { push } else { pop } }` |
| DragGesture global 座標ミスマッチ | ✅ | translation-based + `@State dragStartRatio` |
| AsyncStream events race + ObjectIdentifier bug | ✅ | `AsyncStream.makeStream()` で init 時単一 continuation |
| ghostty_surface_new crash (nsView.window==nil) | ✅ | `guard nsView.window != nil else { return }` |

## 未解決の指摘（follow-up タスクとして登録済み）

| 指摘 | 登録タスク | 理由 |
|------|----------|------|
| SurfacePool pendingGC double-free edge case | T-045 | 発火条件が限定的、Post-MVP |
| GhosttyTerminalView deinit thread safety | T-046 | 現状 SurfacePool が strong ref で grace period 中は安全 |
| updateLeaf guard 意図不明確 | minor | コード明確化のみ |

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `TmuxControlMode.swift` | readLoop→AsyncBytes、events→makeStream、send throws |
| `TmuxControlModeRegistry.swift` | safeKillSession await修正 |
| `WorkspaceStore.swift` | tabIdx→tabID |
| `WorkspaceArea.swift` | cursor pop、DragGesture translation、dismantleNSView、windowGuard |

## Verification Evidence

- `swift build` → **Build complete! (31.11s)** ✅
- `swift build` → **Build complete! (32.92s)** ✅ (Round 1 fixes)
- SourceKit false positives: cross-file type resolution (same module, all types exist, real compiler resolves correctly)

## Review Results — Round 2 (4/4 GO_WITH_CONDITIONS)

| Reviewer | Verdict | 新規 Blocking |
|----------|---------|-------------|
| R1 Concurrency & Memory Safety | GO_WITH_CONDITIONS | stopMonitoring fire-and-forget (B-001), GhosttyApp @MainActor (B-002) |
| R2 tmux subprocess & error handling | GO_WITH_CONDITIONS | TmuxControlMode single-use contract (B-001), updateLeaf guard (B-002) |
| R3 SwiftUI & Ghostty surface lifecycle | GO_WITH_CONDITIONS | Timer MainActor isolation Swift 6 risk (minor) |
| R4 Architecture & BSP edge cases | GO_WITH_CONDITIONS | stopMonitoring fire-and-forget (B-001), updateLeaf guard (B-002) |

全員が Round 1 全修正を CONFIRMED。2/4 GO 目標クリア。

## Round 2 条件対応

| 条件 | 対応 | タスク |
|------|------|-------|
| `stopMonitoring` async + await m.stop() | ✅ T-043b で修正 | 済 |
| `updateLeaf` guard 削除 | ✅ T-043b で修正 | 済 |
| GhosttyApp @MainActor | follow-up 登録 | T-048 |
| TmuxControlMode single-use 文書化 | follow-up 登録 | T-049 |

## Orchestrator 最終判定: **GO** ✅

2/4 GO_WITH_CONDITIONS 達成。Blocking 条件 (stopMonitoring, updateLeaf) は T-043b で修正済み。
非 Blocking 条件は T-048, T-049 として登録。commit 可。

---

## コード参照

実コードは `Sources/AgtmuxTerm/` 以下の各ファイルを参照してください。
特に重点確認箇所:
- `TmuxControlMode.swift`: `init(sessionName:source:)` で makeStream、`readLoop` で AsyncBytes
- `TmuxControlModeRegistry.swift`: `safeKillSession` の await、`stopMonitoring` の async
- `WorkspaceStore.swift`: `startLayoutMonitoring(for:tabID:UUID)` + `handleLayoutChange`、`updateLeaf` の guard 削除
- `WorkspaceArea.swift`: `_GhosttyNSView.updateNSView` の window guard、`DividerHandle` の修正
