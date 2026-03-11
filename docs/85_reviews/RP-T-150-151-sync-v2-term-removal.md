# Review Pack — T-150 + T-151: agtmux-term sync-v2 compat removal

## Objective
- T-150: Isolate sync-v2 residue from the product metadata boundary (gate for T-151)
- T-151: Remove sync-v2 endpoint compat layer after daemon T-SV2-P2

## Pre-condition: daemon T-SV2-P2 gate
- Daemon commit `9e4fb9e feat: remove ui.bootstrap.v2/ui.changes.v2 RPC endpoints (T-SV2-P2)` DONE
- `ui.bootstrap.v2` and `ui.changes.v2` handlers no longer exist in agtmux daemon

## Change scope

### T-150 (commit `7f2bf36`) — 115 insertions, 113 deletions
| ファイル | 変更内容 |
|---------|---------|
| `LocalMetadataTransportBridge.swift` | `LocalMetadataTransportVersion` now only `case v3`; removed v2 dispatch |
| `LocalMetadataRefreshBoundary.swift` | Product boundary no longer models v2 bootstrap union |
| `LocalMetadataRefreshCoordinator.swift` | Removed `.v2` transport version from coordinator |
| `LocalMetadataClient+Compat.swift` | Created: explicit isolation of v2 compat surfaces with removal comment |
| `AppViewModel.swift` | Updated to use v3-only product path |
| `LocalSnapshotClient.swift` | Removed v2 references |

### T-151 (commit `179c0e7`) — 44 insertions, 1002 deletions
| ファイル | 変更内容 |
|---------|---------|
| `ServiceEndpoint.swift` | `fetchUIBootstrapV2` / `fetchUIChangesV2` handlers removed; `AgtmuxSyncV2Session` property removed |
| `AgtmuxDaemonXPCClient.swift` | v2 XPC client methods removed |
| `LocalMetadataClient+Compat.swift` | Deleted (compat isolation no longer needed) |
| `AgtmuxDaemonClient+SyncV2.swift` | Reduced to only legacy model types |
| `AgtmuxDaemonClient.swift` | v2 methods removed |
| `AgtmuxDaemonXPCContract.swift` | v2 protocol entries removed |
| `AgtmuxSyncV2Models.swift` | Preserved (still used for pane identity compat) |
| `AgtmuxSyncV2Session.swift` | Removed (session management no longer needed) |
| Test files (4) | `AgtmuxSyncV2SessionTests.swift`, `RuntimeHardeningTests.swift`, `AgtmuxDaemonXPCClientTests.swift`, `AgtmuxDaemonXPCServiceBoundaryTests.swift` — v2-specific tests removed |

## NOT changed (intentional)
- `AgtmuxSyncV2Models.swift` preserved — legacy model types still used for pane identity compat
- Wire format unchanged — v3 protocol continues to function normally
- `ui.health.v1` path unchanged

## Verification evidence
- `swift build` PASS
- `swift test` PASS (all suites)
- T-150 acceptance criteria: all 4 checked ✓
- T-151 acceptance criteria: all 3 checked ✓
- No `fetchUIBootstrapV2` / `fetchUIChangesV2` references in product path

## Review Verdict — GO

- Daemon gate (T-SV2-P2) confirmed DONE
- T-150: product path v3-only, v2 compat explicitly isolated and then removed in T-151
- T-151: 1002 deletions of v2 client/XPC/service/test code; only legacy model types preserved
- `swift build` + `swift test` PASS
- T-150 and T-151 ready to push to origin/main
