# ADR-20260228: libghostty を SwiftTerm の代替として採用

- **Status**: Accepted
- **Date**: 2026-02-28
- **Deciders**: プロジェクトオーナー

## Context

`exp/go-codex-implementation-poc` ブランチで Swift/SwiftUI 製 POC を構築した際、ターミナルバックエンドに SwiftTerm を使用した。しかし以下の根本的な問題が発生した:

1. **10fps のレンダリングレート**: SwiftTerm は Metal GPU レンダリングを使用しておらず、CPU 描画で実用不可な速度。
2. **IME 不安定**: NSTextInputClient の実装が不完全。日本語・CJK 入力で IME 候補ウィンドウの位置がずれる。変換確定が正しく PTY に送られないケースがある。
3. **カーソルズレ**: VT パーサの精度問題。複雑な ANSI エスケープシーケンス（AI エージェントが多用する）でカーソル位置がずれる。

これらはパッチで修正できるレベルではなく、SwiftTerm の設計上の制約であると判断した。

## Decision

**libghostty（GhosttyKit.xcframework）を採用する。**

- Ghostty リポジトリから `zig build xcframework` で `GhosttyKit.xcframework` を生成する
- C API (`ghostty.h`) を Swift から直接呼ぶ
- **リファレンス実装**: Ghostty 本体の `src/apprt/swift/SurfaceView_AppKit.swift`（NSView + NSTextInputClient の実装パターン）に準拠する
- `Package.swift` の binaryTarget として xcframework を参照する

### 採用理由

| 項目 | SwiftTerm | libghostty |
|------|-----------|------------|
| レンダリング | CPU (≈10fps) | Metal GPU (≈125fps 内部タイマー) |
| IME | 不安定 | ネイティブ AppKit NSTextInputClient |
| VT パーサ | 精度問題あり | Ghostty 本体と同じ高精度パーサ |
| 実績 | OSS ターミナル少数 | Ghostty（高評価ターミナルエミュレータ） |
| Swift 統合 | Swift ネイティブ | C API → Swift ブリッジ（制御可能） |

## Consequences

### Positive
- GPU レンダリング（≈125fps）で Ghostty 同等の描画品質
- ネイティブ IME（`ghostty_surface_preedit` / `ghostty_surface_ime_point`）でカーソル位置精度が高い
- Ghostty の VT パーサ（高精度）を活用できる
- AI エージェントが生成する複雑な ANSI シーケンスでもカーソルズレなし

### Negative / Tradeoffs
- **Zig ビルドチェーン**: 開発環境に Zig 0.14.x が必要。CI の設定が複雑になる
- **API unstable**: libghostty の C API は internal API であり、Ghostty のバージョンアップで breaking changes が発生しうる。Ghostty upstream に追従する責任がある
- **macOS 限定**: libghostty は macOS/Linux をサポートするが、xcframework は macOS 限定（今回の Non-goal と一致）
- **C API ブリッジ**: Swift から C API を直接呼ぶため、型安全性は自前で担保する必要がある

## Alternatives Considered

### GPUI + gpui-ghostty（Rust 書き直し）
- Rust でのフル書き直しが必要
- POC の Swift コードが無駄になる
- 却下: 移行コストが高すぎる

### Tauri + xterm.js（Web 技術）
- xterm.js は SwiftTerm と同様の fps 問題を持つ（GPU アクセラレーションが限定的）
- Web ビューのオーバーヘッドが大きい
- 却下: ターミナル品質が目標 (G-001) を満たさない

### SwiftTerm のフォーク・改修
- Metal レンダリングの追加は SwiftTerm の設計を根本から変える必要がある
- IME 修正も NSTextInputClient を書き直すレベル
- 結果として libghostty を使うのと同等の工数になる
- 却下: 既存の高品質実装（libghostty）を使う方が合理的

## IME 実装パターン（参考: SurfaceView_AppKit.swift）

```swift
// keyDown → interpretKeyEvents → setMarkedText → ghostty_surface_preedit
// insertText → ghostty_surface_text
// firstRect(forCharacterRange:) → ghostty_surface_ime_point で候補ウィンドウ位置
```

## ビルド手順

```bash
# Zig のインストール（0.14.x）
brew install zig

# Ghostty ソースの取得
git submodule add https://github.com/ghostty-org/ghostty vendor/ghostty
# または
git clone https://github.com/ghostty-org/ghostty vendor/ghostty

# xcframework ビルド
cd vendor/ghostty
zig build xcframework

# 生成物: zig-out/lib/GhosttyKit.xcframework
# → プロジェクトの GhosttyKit/ にコピー
```

参照: https://mitchellh.com/writing/zig-and-swiftui
