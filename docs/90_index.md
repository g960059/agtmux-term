# Project Index

## Repository: agtmux-term

AI エージェント対応ターミナルエミュレーター（macOS）。
agtmux daemon と連携し、tmux セッション内の AI エージェント状態を監視・操作する。

## Documents

| File | Tier | Content |
|------|------|---------|
| `AGENTS.md` | Stable | 実体エージェント運用ルール（role-play禁止、本体のみ） |
| `CLAUDE.md` | Stable | プロセスルール、品質ポリシー、Orchestrator ゲート |
| `docs/00_router.md` | Stable | 非交渉ゲート、Quality Gates、Review プロトコル |
| `docs/10_foundation.md` | Stable | What / For Whom / Why / User Stories / Goals / Non-Goals |
| `docs/20_spec.md` | Design | 機能要件 (FR)、非機能要件 (NFR)、制約 |
| `docs/30_architecture.md` | Design | システムコンテキスト、コンポーネントツリー、データフロー |
| `docs/40_design.md` | Design | 実装設計（GhosttyTerminalView, AgtmuxDaemonClient, pane アタッチ） |
| `docs/50_plan.md` | Design | 4フェーズ実装計画、リスク |
| `docs/60_tasks.md` | Tracking | タスクボード（T-001〜T-014） |
| `docs/70_progress.md` | Tracking | 進捗ログ、フェーズ完了記録 |
| `docs/80_decisions/` | Tracking | ADR 一覧 |
| `docs/85_reviews/` | Tracking | Review Pack（コミット前レビュー） |
| `docs/lessons.md` | Tracking | 修正パターンの記録（後から作成） |

## ADR 一覧

| File | Title | Status |
|------|-------|--------|
| `docs/80_decisions/ADR-20260228-libghostty-over-swiftterm.md` | libghostty を SwiftTerm の代替として採用 | Accepted |
| `docs/80_decisions/ADR-20260228-ghosttykit-distribution.md` | GhosttyKit.xcframework 配布戦略（Git LFS 採用） | Accepted |

## Source Structure

```
agtmux-term/
├── CLAUDE.md
├── README.md
├── Package.swift                        ← Swift Package Manager
├── GhosttyKit/
│   └── GhosttyKit.xcframework           ← zig build xcframework で生成
├── Sources/
│   └── AgtmuxTerm/
│       ├── App/
│       │   ├── AgtmuxTermApp.swift
│       │   └── AppViewModel.swift
│       ├── Terminal/
│       │   ├── GhosttyApp.swift
│       │   ├── GhosttyTerminalView.swift
│       │   └── GhosttyInput.swift
│       ├── Sidebar/
│       │   ├── SidebarView.swift
│       │   ├── SessionRowView.swift
│       │   └── FilterBarView.swift
│       ├── DaemonClient/
│       │   ├── AgtmuxDaemonClient.swift
│       │   └── DaemonModels.swift
│       └── CockpitView.swift
├── vendor/
│   └── ghostty/                         ← Ghostty ソース (git clone、.gitignore 除外)
└── docs/
    ├── 00_router.md
    ├── 10_foundation.md
    ├── 20_spec.md
    ├── 30_architecture.md
    ├── 40_design.md
    ├── 50_plan.md
    ├── 60_tasks.md
    ├── 70_progress.md
    ├── 80_decisions/
    │   └── ADR-20260228-libghostty-over-swiftterm.md
    ├── 85_reviews/
    │   └── _review-pack-template.md
    └── 90_index.md
```

## Quick Start

```bash
# Prerequisites
brew install zig  # Zig 0.14.x
git lfs install   # Git LFS（xcframework 取得に必要）

# Clone（LFS 対応 clone で xcframework も自動取得）
git clone https://github.com/g960059/agtmux-term
cd agtmux-term

# GhosttyKit を再ビルドする場合（通常は LFS から自動取得）
# bash scripts/build-ghosttykit.sh

# Build Swift app
swift build

# Run
swift run AgtmuxTerm
```

## Key External Dependencies

| Dependency | Source | Purpose |
|------------|--------|---------|
| GhosttyKit.xcframework | `vendor/ghostty` (zig build) | libghostty C API — GPU ターミナルレンダリング |
| agtmux daemon | `agtmux-v5-architecture-blueprint` repo | エージェント状態推定エンジン |
| tmux | システム PATH | pane の PTY 提供 |

## Phase Status

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 0 | Build Infrastructure (T-001) | TODO |
| Phase 1 | Terminal Core (T-002〜T-005) | TODO |
| Phase 2 | Sidebar UI Port (T-006〜T-008) | TODO |
| Phase 3 | Daemon Integration (T-009〜T-011) | TODO |
| Phase 4 | Polish / Post-MVP (T-012〜T-014) | TODO |

## Cross-Repo V2 A0
- Final plan output: `/tmp/agtmux-v2-final-plan-20260305-v3.md`
- agtmux handover: `/Users/virtualmachine/ghq/github.com/g960059/agtmux/docs/85_reviews/RP-20260305-agtmux-term-v2-a0-handover.md`
- term execution task: `docs/60_tasks.md` (`T-074a`)
