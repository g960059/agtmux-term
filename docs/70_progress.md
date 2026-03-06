# Progress Ledger

This file keeps the recent progress surface small.
Historical progress detail lives in `docs/archive/progress/2026-02-28_to_2026-03-06.md`.

## Current Summary

- V2 mainline docs are aligned and design-locked for MVP
- active implementation has not started yet on the V2 Workbench path
- local daemon runtime hardening and A2 health observability are complete
- next execution milestone is `T-090` through `T-094`

## Recent Entries

## 2026-03-06 — T-089 完了: sync-v2 XPC review blocker closeout

### 事象
- commit review で、packaged-app sync-v2 XPC path に dedicated bootstrap/changes coverage が無いという `NO_GO` を受けた。
- 既存の XPC integration tests は `ui.health.v1` に偏っており、`fetchUIBootstrapV2` / `fetchUIChangesV2` の injected-client と service-boundary の実呼び出しを見ていなかった。
- 併せて、bundled runtime README には PATH/common install location fallback をまだ書いており、resolver 契約とずれていた。

### 実施内容
- `Tests/AgtmuxTermIntegrationTests/AgtmuxDaemonXPCClientTests.swift`
  - injected XPC proxy 向けに `fetchUIBootstrapV2` decode test を追加。
  - `fetchUIChangesV2(limit:)` の decode と `limit` 伝播を検証する test を追加。
- `Tests/AgtmuxTermIntegrationTests/AgtmuxDaemonXPCServiceBoundaryTests.swift`
  - anonymous XPC service boundary で `fetchUIBootstrapV2` 成功系を追加。
  - `fetchUIChangesV2` が bootstrap 前に fail loudly し、その後 bootstrap 済みなら成功する service-boundary test を追加。
  - actual service endpoint 側にも同等の bootstrap/changes coverage を追加。
- `Sources/AgtmuxTerm/Resources/Tools/README.md`
  - runtime resolver の現在の契約に合わせて、PATH/common install location fallback 記述を削除。

### 結果
- 初回 review の `NO_GO` で指摘された sync-v2 XPC/bootstrap/changes coverage gap はコード上で閉じた。
- bundled runtime README と resolver 契約のズレも解消した。
- focused post-fix rerun 後の re-review は `GO` だった。
- current worktree は commit/push 可能状態に戻った。

### 検証
- `swift build` ✅
- `swift test -q --filter AgtmuxDaemonXPCClientTests` ✅
- `swift test -q --filter AgtmuxDaemonXPCServiceBoundaryTests` ✅
- `xcodebuild -project AgtmuxTerm.xcodeproj -target AgtmuxTermCoreTests -configuration Debug build` ✅
- `xcrun xctest -XCTest AgtmuxDaemonServiceEndpointTests build/Debug/AgtmuxTermCoreTests.xctest` ✅

## 2026-03-06 — T-088 完了: fresh verification rerun and review-pack prep

### 事象
- 現 worktree には runtime hardening / health observability のコード変更と V2 docs 再編が同居している。
- commit 前に、最終状態に対する fresh verification を取り直し、その結果で review pack を作る必要があった。

### 実施内容
- `swift build` を rerun。
- `swift test -q --filter RuntimeHardeningTests` を rerun。
- `swift test -q --filter AgtmuxSyncV2DecodingTests` を rerun。
- `swift test -q --filter AgtmuxSyncV2SessionTests` を rerun。
- `swift test -q --filter AppViewModelA0Tests` を rerun。
- `swift test -q --filter AppViewModelLiveManagedAgentTests` を rerun。
- `swift test -q --filter AgtmuxDaemonXPCClientTests` を rerun。
- `swift test -q --filter AgtmuxDaemonXPCServiceBoundaryTests` を rerun。
- `xcodebuild -project AgtmuxTerm.xcodeproj -target AgtmuxTermCoreTests -configuration Debug build` を rerun。
- `xcrun xctest -XCTest AgtmuxDaemonServiceEndpointTests build/Debug/AgtmuxTermCoreTests.xctest` を rerun。
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripShowsMixedHealthStates -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripStaysAbsentWithoutHealthSnapshot` を rerun。
- `docs/85_reviews/` に review pack を追加する準備を行った。

### Files intended for commit
- `Sources/AgtmuxDaemonService/main.swift`
- `Sources/AgtmuxDaemonService/ServiceEndpoint.swift`
- `Sources/AgtmuxTerm/AgtmuxDaemonSupervisor.swift`
- `Sources/AgtmuxTerm/AgtmuxDaemonXPCClient.swift`
- `Sources/AgtmuxTerm/AppViewModel.swift`
- `Sources/AgtmuxTerm/LocalSnapshotClient.swift`
- `Sources/AgtmuxTerm/SidebarView.swift`
- `Sources/AgtmuxTerm/main.swift`
- `Sources/AgtmuxTermCore/AccessibilityID.swift`
- `Sources/AgtmuxTermCore/AgtmuxBinaryResolver.swift`
- `Sources/AgtmuxTermCore/AgtmuxDaemonClient.swift`
- `Sources/AgtmuxTermCore/AgtmuxDaemonClient+SyncV2.swift`
- `Sources/AgtmuxTermCore/AgtmuxDaemonXPCContract.swift`
- `Sources/AgtmuxTermCore/AgtmuxSyncV2Models.swift`
- `Sources/AgtmuxTermCore/AgtmuxSyncV2Session.swift`
- `Sources/AgtmuxTermCore/AgtmuxUIHealthModels.swift`
- `Sources/AgtmuxTermCore/CoreModels.swift`
- `Tests/AgtmuxTermCoreTests/AgtmuxSyncV2DecodingTests.swift`
- `Tests/AgtmuxTermCoreTests/AgtmuxSyncV2SessionTests.swift`
- `Tests/AgtmuxTermCoreTests/RuntimeHardeningTests.swift`
- `Tests/AgtmuxTermIntegrationTests/AgtmuxDaemonXPCClientTests.swift`
- `Tests/AgtmuxTermIntegrationTests/AgtmuxDaemonXPCServiceBoundaryTests.swift`
- `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift`
- `Tests/AgtmuxTermIntegrationTests/AppViewModelLiveManagedAgentTests.swift`
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
- `Tests/AgtmuxTermUITests/UITestHelpers.swift`
- `docs/00_router.md`
- `docs/10_foundation.md`
- `docs/20_spec.md`
- `docs/30_architecture.md`
- `docs/40_design.md`
- `docs/41_design-workbench.md`
- `docs/42_design-cli-bridge.md`
- `docs/43_design-companion-surfaces.md`
- `docs/50_plan.md`
- `docs/60_tasks.md`
- `docs/65_current.md`
- `docs/70_progress.md`
- `docs/80_decisions/ADR-20260306-tmux-first-cockpit-v2.md`
- `docs/85_reviews/RP-20260306-worktree-closeout.md`
- `docs/90_index.md`
- `docs/archive/README.md`
- `docs/archive/progress/2026-02-28_to_2026-03-06.md`
- `docs/archive/tasks/2026-02-28_to_2026-03-06.md`
- `docs/lessons.md`

`build/` is verification output only and is excluded from commit.

### 結果
- fresh build/test evidence はすべて green だった。
- runtime hardening, sync-v2, health, XPC boundary, service endpoint, targeted UI coverage を commit 前の最終状態で再確認できた。

### 検証
- `swift build` ✅
- `swift test -q --filter RuntimeHardeningTests` ✅（8 tests）
- `swift test -q --filter AgtmuxSyncV2DecodingTests` ✅（4 tests）
- `swift test -q --filter AgtmuxSyncV2SessionTests` ✅（4 tests）
- `swift test -q --filter AppViewModelA0Tests` ✅（15 tests）
- `swift test -q --filter AppViewModelLiveManagedAgentTests` ✅（1 test）
- `swift test -q --filter AgtmuxDaemonXPCClientTests` ✅（2 tests）
- `swift test -q --filter AgtmuxDaemonXPCServiceBoundaryTests` ✅（2 tests）
- `xcodebuild -project AgtmuxTerm.xcodeproj -target AgtmuxTermCoreTests -configuration Debug build` ✅
- `xcrun xctest -XCTest AgtmuxDaemonServiceEndpointTests build/Debug/AgtmuxTermCoreTests.xctest` ✅（2 tests）
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripShowsMixedHealthStates -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripStaysAbsentWithoutHealthSnapshot` ✅（2 tests）

## 2026-03-06 — T-087 完了: docs を active-context 向けに compaction

### 事象
- `docs/60_tasks.md` と `docs/70_progress.md` が肥大化し、日常の再読コストが高くなっていた。
- `docs/40_design.md` も mainline truth と detail が1枚に混在しており、毎回の読込量が大きかった。
- Router の読み順も、active summary より先に長い tracking files を要求していた。

### 実施内容
- `docs/archive/tasks/2026-02-28_to_2026-03-06.md`
  - compaction 前の full task board を退避。
- `docs/archive/progress/2026-02-28_to_2026-03-06.md`
  - compaction 前の full progress ledger を退避。
- `docs/archive/README.md`
  - archive の役割を明記。
- `docs/65_current.md`
  - current phase, locked decisions, next tasks, read-next path をまとめた current summary を新設。
- `docs/60_tasks.md`
  - active/next tasks と recent completions だけを残す構成へ再編。
- `docs/70_progress.md`
  - current summary と recent entries だけを残す構成へ再編。
- `docs/40_design.md`
  - compact MVP summary に縮約。
- `docs/41_design-workbench.md`
  - Workbench / terminal tile / duplicate / restore details を分離。
- `docs/42_design-cli-bridge.md`
  - `agt open`, OSC bridge, remote semantics を分離。
- `docs/43_design-companion-surfaces.md`
  - browser/document/future directory surface と lightweight guardrails を分離。
- `docs/00_router.md`
  - read order を `65_current -> 60_tasks -> 10 -> 20 -> 40 -> 41/42/43 -> 30 -> 50 -> 70 -> archive` へ更新。
- `docs/90_index.md`
  - current/design/archive 構成に合わせて read order と documents table を更新。

### 結果
- active implementation context を短い読み順で辿れるようになった。
- history は消さずに archive へ退避された。
- design truth は維持しつつ、summary と detail を分離できた。

### 検証
- docs-only 変更のため build / runtime verification は未実施。
- `65_current / 60_tasks / 70_progress / 40/41/42/43 / router / index` の相互参照を手動確認。

## 2026-03-06 — T-086 完了: V2 design lock を mainline docs に統合

### 結果
- `TargetRef`, OSC bridge, autosave/pinning, duplicate open, manual `Rebind`, directory-tile future scope が main docs に固定された。

### 検証
- docs-only 変更のため build / runtime verification は未実施。

## 2026-03-06 — T-085 完了: V2 docs realignment to tmux-first cockpit baseline

### 結果
- `docs/10` through `docs/50` の mainline truth は V2 direction に揃った。
- linked-session path は implementation history としてのみ扱う位置づけになった。

### 検証
- docs-only 変更のため build / runtime verification は未実施。

## 2026-03-06 — T-076 through T-084 完了: local daemon runtime + A2 health track closeout

### 結果
- local daemon runtime hardening, sync-v2 path, health strip, XPC coverage が完了。
- この implementation track は完了済みで、次の main focus は Workbench V2 である。

### 検証
- 詳細な build/test evidence は archive progress を参照。

## Archive

- Full historical progress ledger:
  `docs/archive/progress/2026-02-28_to_2026-03-06.md`
