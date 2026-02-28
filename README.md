# agtmux-term

AI エージェント（Claude Code, Codex など）が動く tmux セッションを管理・監視するための macOS ターミナルアプリケーション。

```
[Screenshot placeholder — will be added after Phase 1 completion]
```

## Features

- **サイドバー**: tmux セッション一覧、エージェント状態（Running / Waiting / Idle）、会話タイトル
- **ターミナル**: libghostty による GPU レンダリング（≈125fps）、ネイティブ IME、正確な VT パーサ
- **リアルタイム状態更新**: agtmux daemon 経由でエージェント状態を1秒間隔で取得

## Status

Current phase: **Planning** — Implementation not yet started.

See [docs/60_tasks.md](docs/60_tasks.md) for the task board and [docs/70_progress.md](docs/70_progress.md) for progress.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 15 or later
- [Zig 0.14.x](https://ziglang.org/download/) — for building GhosttyKit.xcframework
- [agtmux daemon](https://github.com/g960059/agtmux-v5-architecture-blueprint) — for agent state data
- tmux — available in PATH

## Build

```bash
# 1. Clone with submodules (Ghostty source)
git clone --recursive https://github.com/g960059/agtmux-term
cd agtmux-term

# 2. Build GhosttyKit.xcframework from Ghostty source
cd vendor/ghostty
zig build xcframework
cp -r zig-out/lib/GhosttyKit.xcframework ../../GhosttyKit/
cd ../..

# 3. Build the Swift app
swift build

# 4. Run
swift run AgtmuxTerm
```

## Architecture

```
agtmux-term (Swift macOS App)
├── GhosttyKit.xcframework    ← Built from Ghostty source via zig
├── Sidebar (SwiftUI)         ← Agent state, session list
└── Terminal (NSView/Metal)   ← libghostty GPU rendering
        |
        ├── agtmux daemon (UDS JSON-RPC)  ← Agent state
        └── tmux (PTY)                     ← Terminal sessions
```

See [docs/30_architecture.md](docs/30_architecture.md) for details.

## Related

- **agtmux daemon** (state estimation engine): [g960059/agtmux-v5-architecture-blueprint](https://github.com/g960059/agtmux-v5-architecture-blueprint)
- **Ghostty** (terminal emulator, source of libghostty): [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)

## Background

This project replaces a SwiftTerm-based POC (`exp/go-codex-implementation-poc` branch in the agtmux repo) that had fundamental issues: 10fps rendering, unstable IME, and cursor drift. The solution is to use libghostty — the same core library powering the Ghostty terminal emulator — which provides GPU rendering, native IME, and an accurate VT parser.

See [ADR-20260228](docs/80_decisions/ADR-20260228-libghostty-over-swiftterm.md) for the full rationale.

## License

TBD
