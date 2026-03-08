# CLI Bridge Design Details

## Scope

This document defines the MVP CLI bridge and remote semantics for companion surfaces.

Read this after `docs/40_design.md`.

## Purpose

Allow users and agents to open companion surfaces from the terminal itself while keeping terminal interaction normal.

## MVP Command Surface

```sh
agt open <url-or-file> [--left|--right|--up|--down|--replace] [--pin] [--source <source>]
```

Behavior:

- URL -> browser tile
- file -> document tile
- directory -> rejected in MVP

Reserved future extension only:

```sh
agt reveal <dir> [--left|--right|--up|--down|--replace]
```

`agt reveal` is not implemented in MVP.

## Bridge Transport

Primary bridge path:

- terminal-scoped custom OSC message carrying a structured request

Chosen private command number:

- `OSC 9911`

Reserved host-owned internal telemetry:

- no second OSC number is reserved
  - rendered-surface client-tty bind is carried over the same `OSC 9911` channel as a host-owned structured action
  - same-session pane sync must not depend on a second private OSC channel such as `9912`

High-level payload fields:

- protocol version
- action (`open`)
- source target
- current working directory
- argument payload
- resolved kind (`url` or `file`)
- placement
- pin intent

Host-owned bridge extension:

- the same `OSC 9911` channel also carries terminal-host telemetry actions that are not user CLI contract
- current required host-owned action:
  - `bind_client`
    - payload includes the rendered tmux `client_tty`
    - emitted by the terminal attach wrapper before `exec tmux ...`
    - consumed only by the embedded host so same-session exact-client navigation and reverse sync can bind to the visible rendered client

## Payload Schema

MVP payload encoding:

- `OSC 9911` body is UTF-8 JSON
- top-level value must be a single object
- no secondary framing or fallback encoding exists

MVP JSON object:

```json
{
  "version": 1,
  "action": "open",
  "kind": "url",
  "target": "local",
  "argument": "https://example.com/docs",
  "cwd": "/Users/alice/project",
  "placement": "right",
  "pin": false
}
```

Field contract:

- `version`
  - must be `1`
- `action`
  - must be `"open"`
- `kind`
  - must be `"url"` or `"file"`
- `target`
  - `"local"` or a stable app-level remote host key
- `argument`
  - for `url`: exact URL string to open
  - for `file`: absolute path already resolved by the emitter against shell cwd
- `cwd`
  - absolute shell working directory at emit time
- `placement`
  - `"left"`, `"right"`, `"up"`, `"down"`, or `"replace"`
- `pin`
  - boolean pin intent for the opened companion tile

Host-side validation rules:

- non-JSON payload, non-object payload, unknown `version`, unknown `action`, unknown `kind`, unknown `placement`, empty `target`, empty `cwd`, and empty `argument` are all explicit bridge failures
- the host app does not guess relative paths and does not silently coerce malformed values
- `kind == "file"` requires the emitter to send an absolute path; relative file input is an emitter bug, not a host-side normalization path
- `kind == "directory"` is unsupported in MVP and fails explicitly

Why OSC:

- works from local or remote shells
- does not require remote shells to reach a local Unix socket
- stays explicit and terminal-native

## Implementation Constraint

Current implementation reality:

- the vendored GhosttyKit C API currently exposes only fixed runtime callbacks and typed `ghostty_action_s` payloads
- it does not expose a raw/generic custom OSC callback to the host app

Implication:

- the MVP bridge contract remains terminal-scoped custom OSC
- the implementation path is to expand the vendored Ghostty embedded runtime and `GhosttyKit.xcframework` in-repo so that custom OSC reaches the host app as a typed `ghostty_action_s` case through the existing `action_cb`

Rejected interim direction:

- piggybacking the bridge payload on unrelated typed actions such as title, notification, or open-url callbacks is not the mainline plan
- that would be a semantic overload, weaken explicitness, and make verification/reasoning worse

## Required Host Capability

The host-side terminal integration must provide all of the following:

- surface-scoped delivery
  the app must know which terminal surface emitted the bridge payload
- raw bridge payload visibility
  the app must receive the custom OSC payload itself, or an equivalent lossless decode, without semantic overloading onto unrelated action types
- explicit consume/dispatch boundary
  the host app must be able to consume the payload, decode it, and dispatch it into the emitting terminal's Workbench without hidden fallback
- local/remote symmetry
  the same terminal-originated carrier must work for local and remote shells because both arrive through the terminal surface output path

If the vendored GhosttyKit cannot provide these properties, `T-099` remains blocked.

## Current Execution Path

The narrowest viable host-side addition is:

- keep using the existing `ghostty_runtime_action_cb`
- add one new typed `ghostty_action_s` case for custom OSC payloads
- include the raw payload bytes, and preferably the OSC numeric command, in that typed action

This keeps the carrier explicit and surface-scoped without introducing a second unrelated callback surface.

For MVP, Ghostty only needs to surface `OSC 9911` payloads to the host app. The payload body itself remains agtmux-owned structured data that `T-103` will decode.

## Verification Strategy

Required proof once the carrier is available:

- payload decode / validation tests
  malformed or unsupported bridge payloads fail explicitly
- dispatch tests
  a surface-scoped bridge request reaches the correct Workbench open path with source/cwd context
- product-level proof
  executed UI or integration proof that a terminal-originated request opens the expected browser/document tile

## Failure Behavior

- if no active agtmux bridge is available, `agt open` fails explicitly
- if `agt open` receives a directory in MVP, it fails explicitly
- there is no silent fallback behavior

## Source Resolution

Default source rules:

- inside a local terminal tile, target defaults to `local`
- inside a remote terminal tile, target defaults to that tile's emitting surface target
- `--source` explicitly overrides the inferred target and is carried as payload field `target`

Path rules:

- relative paths resolve against shell cwd at emit time
- the resolved path and target are stored in the tile payload

## Remote Design

Target identity:

- `TargetRef` must be a stable app-level target identity
- use `local` or a stable configured remote-host key
- do not use guessed hostname strings as primary identity

Remote document behavior:

- fetch lazily
- use configured remote identity
- keep errors visible

Remote non-goals in MVP:

- implicit SSH tunnels
- automatic host/path/session substitution
- remote directory explorer as first-class MVP feature

## Remote URL Semantics

- URLs open exactly as requested
- remote `http://localhost:3000` is not rewritten
- implicit SSH tunnel is not created

If a URL is unreachable from the local app context, that failure stays visible.
