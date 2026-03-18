# Requirements

## Problem

The original macOS app icon was visually busy and did not immediately read as a
terminal-focused app, especially at smaller launcher sizes.

## Goals

- make the icon read as a terminal app at a glance
- keep the silhouette legible from 16px through 1024px
- preserve a subtle connection to agtmux-term's tmux/cockpit identity without visual clutter
- keep the result compatible with the existing macOS AppIcon asset set

## Non-Goals

- redesigning unrelated app branding or in-app UI
- changing runtime behavior, packaging flow, or asset catalog structure

## Acceptance

- [x] a final icon direction has been selected
- [x] the AppIcon asset set has been regenerated from that direction
- [x] the updated asset set builds successfully in the macOS app target
