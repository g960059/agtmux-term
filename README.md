# agtmux-term

macOS tmux cockpit for AI-agent sessions with a terminal-first embedded
Ghostty terminal and a tmux/agent sidebar overlay in the same window.

![App Icon](Sources/AgtmuxTerm/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

## Features

- **Terminal-first main panel** — the main terminal starts as a plain shell and stays in the same app window as the sidebar
- **Sidebar overlay** — live tmux session list grouped by session/window/pane, plus agent status (Running / Waiting / Idle / Attention) and conversation titles
- **Retarget current terminal** — clicking a session or pane reuses the main terminal in place instead of jumping to a separate Ghostty window
- **Native Ghostty runtime** — terminal rendering, input, and IME behavior come from GhosttyKit/libghostty rather than a custom terminal implementation
- **Real-time state** — agtmux daemon pushes agent state every second over Unix socket JSON-RPC
- **SSH targets** — connect to remote hosts (SSH/Mosh) and manage their sessions from one window
- **Claude hooks** — register/unregister/verify Claude Code hooks directly from the Settings sheet
- **Optional auto-launch** — can create a configured tmux session automatically when no local sessions are running
- **Daemon bundled** — XPC service manages the agtmux daemon lifecycle; zero manual setup

## Install

### Homebrew (recommended)

```bash
brew tap g960059/tap
brew install --cask agtmux-term
```

The daemon (`agtmux`) is bundled inside the app — no separate install needed.
Power users who want the CLI standalone:

```bash
brew install agtmux
```

### DMG

Download the latest `AgtmuxTerm-vx.y.z.dmg` from [Releases](https://github.com/g960059/agtmux-term/releases), open it, and drag `AgtmuxTerm.app` to Applications.

> **Note:** While Apple Developer signing is still pending, release CI falls back to an unsigned, non-notarized DMG. On first launch, right-click → Open, or run:
> ```bash
> xattr -dr com.apple.quarantine /Applications/AgtmuxTerm.app
> ```
> Once signing secrets are configured, the same workflow returns to the fully notarized path.

## Requirements

- macOS 14 (Sonoma) or later
- tmux available in PATH (for local sessions)

## Build from Source

```bash
# 1. Clone the repo
git clone https://github.com/g960059/agtmux-term
cd agtmux-term

# 2. Prepare GhosttyKit.xcframework
brew install zig
./scripts/dev/prepare-ghosttykit.sh

# 3. Generate Xcode project
brew install xcodegen
xcodegen generate --spec project.yml

# 4. Install repo-managed git hooks
./scripts/install-git-hooks.sh

# 5. Build agtmux daemon (optional — app falls back to PATH)
cd ../agtmux && cargo build --release
export AGTMUX_BIN=$PWD/target/release/agtmux
cd ../agtmux-term

# 6. Open in Xcode or build via command line
open AgtmuxTerm.xcodeproj
# or: xcodebuild build -scheme AgtmuxTerm -destination "platform=macOS" AGTMUX_BIN=$AGTMUX_BIN
```

## Setup

### Claude Code Hooks

For live agent state updates, agtmux hooks into Claude Code's event system:

1. Open agtmux-term
2. Go to **Settings** (gear icon at sidebar bottom)
3. Click **Register** under "Claude Hooks"

Or from the CLI:

```bash
agtmux setup-hooks
```

### SSH Targets

Add remote hosts to monitor their tmux sessions over SSH/Mosh:

1. Settings → SSH Targets → Add Target
2. Enter hostname, username (optional), display name, and transport

### Auto-launch Session

Settings → Session → configure the session name to create on startup.
Leave empty to keep the default plain-shell startup.

## Daemon Resolution

The `agtmux` binary is resolved in this order:

1. `AGTMUX_BIN` env var (explicit override)
2. `AgtmuxTerm.app/Contents/Resources/Tools/agtmux` (bundled)
3. PATH and known directories (`~/.cargo/bin`, `/opt/homebrew/bin`, etc.)

## Architecture

```
agtmux-term (Swift macOS tmux cockpit)
├── Sidebar / inventory / diagnostics
├── Main embedded terminal + sidebar overlay
├── Session retarget / restore state
├── AgtmuxDaemonService.xpc        ← XPC service managing daemon lifecycle
├── agtmux daemon (UDS RPC)        ← Agent state estimation engine
├── tmux (PTY / SSH target truth)  ← Session multiplexer and source of session existence
└── GhosttyKit / libghostty        ← Terminal runtime engine inside the app
```

The repository still contains generic workbench and migration-only paths, but
the mainline product direction is a terminal-first embedded Ghostty cockpit
with a supplementary tmux/agent sidebar, not separate Ghostty app windows.

## Documentation and Workflow

Durable docs live in:

- `docs/product/` for product intent
- `docs/decisions/` for ADRs
- `docs/runbooks/` for operating procedures
- `docs/research/` for dated, non-authoritative research notes

Active multi-step work lives in `docs/changes/<issue-id>-slug/` and is removed
from the default branch after merge. Read order for contributors and agents is:

1. `README.md`
2. `docs/README.md`
3. `docs/product/`
4. `docs/decisions/`
5. `docs/runbooks/`
6. the active GitHub Issue / PR
7. the active change pack under `docs/changes/`, if the work uses one

Normal GitHub flow is:

`Discussion -> Issue -> docs/changes/<issue-id>-slug/ -> branch -> PR -> merge -> retire change pack`

## Release / CI

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| `ci.yml` | push / PR | Build + unit tests |
| `docs-validate.yml` | push / PR / merge queue | Validate docs layout, ADR naming, research naming, and change-pack completeness |
| `release.yml` | `v*` tag | Build universal binary → sign/notarize when secrets exist, otherwise fall back to unsigned DMG → GitHub Release; update Homebrew only for signed releases |

To release a new version:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The workflow builds a universal (arm64 + x86_64) app with the `agtmux` daemon bundled. When Apple signing secrets are present it signs, notarizes, creates a DMG, publishes a GitHub Release, and updates the Homebrew tap cask. When those Apple secrets are absent it still publishes a GitHub Release with an unsigned, non-notarized DMG and skips the Homebrew tap update.

`prepare-ghosttykit.sh` rebuilds from pinned upstream Ghostty `v1.2.3` when
needed and applies the repo's aggregate Ghostty patch
(`scripts/patches/ghostty-agtmux.patch`) before producing the checked-in
`GhosttyKit.xcframework`. That patch carries the custom OSC bridge, the current
embedded-scroll renderer optimizations, and the minimal `build.zig.zon`
dependency refresh required because upstream `v1.2.3` now points at a dead
theme tarball URL.

Required GitHub secrets:

| Secret | Description |
|--------|-------------|
| `APPLE_DEVELOPER_CERTIFICATE_P12` | Base64-encoded Developer ID .p12 for signed/notarized releases |
| `APPLE_DEVELOPER_CERTIFICATE_PASSWORD` | Password for the .p12 |
| `APPLE_TEAM_ID` | 10-character Apple Team ID |
| `APPLE_ID` | Apple ID email for notarytool |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarytool |
| `HOMEBREW_TAP_TOKEN` | GitHub PAT with write access to `g960059/homebrew-tap` for signed releases |

## Related

- **[agtmux](https://github.com/g960059/agtmux)** — Rust daemon that tracks AI agent state via Claude Code hooks, JSONL parsing, and tmux polling
- **[Ghostty](https://github.com/ghostty-org/ghostty)** — Terminal emulator providing libghostty (GPU rendering core)

## License

TBD
