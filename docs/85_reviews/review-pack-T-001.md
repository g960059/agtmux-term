# Review Pack — T-001 GhosttyKit.xcframework ビルド環境構築

## Objective
- Task: T-001
- Phase: 0 (Build Infrastructure)
- Acceptance criteria touched: 全 11 項目

## Summary
- GhosttyKit.xcframework を Ghostty ソースからビルドし、Git LFS で管理する環境を構築した。
- `zig build -Demit-xcframework=true` で macOS universal (arm64+x86_64) + iOS スライスを含む static lib xcframework を生成。
- `Package.swift` で binaryTarget として参照し `swift build` が成功することを確認。
- `ghostty_app_new` など主要シンボルが解決されることを `nm` で確認。
- App Sandbox 不要と判断（Ghostty 本体も無効）。

## Change scope
| ファイル | 変更内容 |
|---------|---------|
| `GhosttyKit/GhosttyKit.xcframework/` | 新規追加（805MB、Git LFS 管理） |
| `Package.swift` | 新規作成（binaryTarget + linkerSettings） |
| `Sources/AgtmuxTerm/main.swift` | 新規作成（最小スタブ、T-002 で上書き） |
| `scripts/build-ghosttykit.sh` | 新規作成（再ビルド手順スクリプト） |
| `.gitattributes` | Git LFS 追跡設定追加（subagent 対応済み） |
| `.gitignore` | vendor/ 追加（subagent 対応済み） |
| `vendor/ghostty/build.zig.zon` | iterm2_themes URL 修正（404 → 最新リリース） |
| `docs/60_tasks.md` | T-001 DONE に更新 |
| `docs/70_progress.md` | T-001 完了記録 |

## Verification evidence
- `zig build -Demit-xcframework=true` → PASS (exit code 0)
- `git lfs ls-files` → PASS (全 10 ファイル LFS 追跡確認)
- `swift build` → PASS (`Build complete! 2.16s`, エラーなし)
- `nm libghostty.a | grep ghostty_app_new` → PASS (`_ghostty_app_new T` 確認)
- `nm libghostty.a | grep ghostty_surface_new` → PASS
- `nm libghostty.a | grep ghostty_config_new` → PASS
- `module.modulemap` 内容確認 → PASS (`module GhosttyKit { umbrella header "ghostty.h" export * }`)
- Sandbox 確認 → GhosttyDebug.entitlements に `com.apple.security.app-sandbox` なし

## Risk declaration
- Breaking change: no（Swift コードはまだ 1 行も存在しない）
- Fallbacks: scripts/build-ghosttykit.sh で再ビルド可能
- Known gaps / follow-ups:
  - [ ] `vendor/ghostty/build.zig.zon` の iterm2_themes URL は定期的に古くなるため、再ビルド時に再度修正が必要な場合がある（lazy 依存なので xcframework ビルド自体には影響しない可能性あり）
  - [ ] linker flags は現時点の pkg/macos/build.zig から導出。T-002 以降で実際に symbol undefined が出た場合に追加する。
  - [ ] vendor/ghostty/build.zig.zon の変更はコミットしない（vendor/ は .gitignore 対象）

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- 確認ポイント:
  1. Package.swift の linker flags が不足していないか（Metal, CoreGraphics, CoreText, QuartzCore, IOSurface, CoreFoundation, CoreVideo, Carbon, AppKit, Foundation, iconv）
  2. Git LFS で .gitattributes の追跡パターンが適切か（`GhosttyKit/**/*.xcframework/**` で全ファイル追跡）
  3. App Sandbox を無効にして運用することへの懸念事項はないか
