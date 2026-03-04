# agtmux-term

AI エージェント（Claude Code, Codex など）が動く tmux セッションを管理・監視するための macOS ターミナルアプリケーション。

```
[Screenshot placeholder — will be added after Phase 1 completion]
```

## Features

- **サイドバー**: tmux セッション一覧、エージェント状態（Running / Waiting / Idle）、会話タイトル
- **ターミナル**: libghostty による GPU レンダリング（≈125fps）、ネイティブ IME、正確な VT パーサ
- **リアルタイム状態更新**: agtmux daemon 経由でエージェント状態を1秒間隔で取得
- **daemon 自動起動 (XPC service)**: app 起動時に bundled XPC service 経由で agtmux daemon を必要時のみ起動し、app 終了時に自動停止

## Status

Current phase: **Implementation in progress**.

See [docs/60_tasks.md](docs/60_tasks.md) for the task board and [docs/70_progress.md](docs/70_progress.md) for progress.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 15 or later
- [Zig 0.14.x](https://ziglang.org/download/) — for building GhosttyKit.xcframework
- tmux — available in PATH
- [agtmux daemon](https://github.com/g960059/agtmux-v5-architecture-blueprint) binary
  - 推奨: `Sources/AgtmuxTerm/Resources/Tools/agtmux` に同梱（app bundle に `Contents/Resources/Tools/agtmux` として入る）
  - 代替: `AGTMUX_BIN` または PATH 上の `agtmux`

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

# 4. (Optional) Bundle agtmux binary
# cp /opt/homebrew/bin/agtmux Sources/AgtmuxTerm/Resources/Tools/agtmux
# chmod +x Sources/AgtmuxTerm/Resources/Tools/agtmux

# 5. Run
swift run AgtmuxTerm
```

## Daemon Startup

デフォルトでは app は bundled XPC service (`AgtmuxDaemonService.xpc`) を使って local daemon を管理します。
`swift run AgtmuxTerm` のように `.app` 外で実行した場合は、XPC service が同梱されないため自動的に legacy fallback へ切り替わります。

Bundle 形式:

1. `AgtmuxTerm.app/Contents/XPCServices/AgtmuxDaemonService.xpc`
2. `AgtmuxTerm.app/Contents/Resources/Tools/agtmux` (optional, bundled daemon binary)

`agtmux` 実行ファイルは以下の順で解決します。

1. `AGTMUX_BIN`（明示指定）
2. bundle 内 `Resources/Tools/agtmux`（SwiftPM では bundle ルート `agtmux` にフラット化される場合あり）
3. PATH と既知ディレクトリ（`~/go/bin`, `~/.cargo/bin`, `/usr/local/bin`, `/opt/homebrew/bin`）

起動時に既存 daemon が見つからない場合のみ `agtmux daemon` を自動起動し、アプリ終了時にこのアプリが起動した daemon を停止します。

動作切替:

```bash
# daemon 自動起動を無効化
AGTMUX_AUTOSTART=0 swift run AgtmuxTerm

# XPC service を無効化して legacy fallback を使う
AGTMUX_XPC_DISABLED=1 swift run AgtmuxTerm
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
