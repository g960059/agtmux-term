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

High-level payload fields:

- protocol version
- action (`open`)
- source target
- current working directory
- raw argument
- resolved kind (`url` or `file`)
- placement
- pin intent

Why OSC:

- works from local or remote shells
- does not require remote shells to reach a local Unix socket
- stays explicit and terminal-native

## Failure Behavior

- if no active agtmux bridge is available, `agt open` fails explicitly
- if `agt open` receives a directory in MVP, it fails explicitly
- there is no silent fallback behavior

## Source Resolution

Default source rules:

- inside a local terminal tile, source defaults to `local`
- inside a remote terminal tile, source defaults to that tile's remote source
- `--source` explicitly overrides the inferred source

Path rules:

- relative paths resolve against shell cwd at emit time
- the resolved path and source are stored in the tile payload

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
