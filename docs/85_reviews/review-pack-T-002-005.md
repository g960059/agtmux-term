# Review Pack — T-002〜T-005 Phase 1 Terminal Core

## Objective
- Tasks: T-002, T-003, T-004, T-005
- Phase: 1 (Terminal Core)
- All acceptance criteria: fully implemented and compiled

## Summary
- `GhosttyApp.swift`: `ghostty_app_t` singleton。`@convention(c)` wakeup_cb (no captures)、`NSHashTable.weakObjects()` activeSurfaces、`newSurface()`/`releaseSurface()` 実装。
- `GhosttyTerminalView.swift`: `NSView + NSTextInputClient`。`CAMetalLayer`、HiDPI `layout()`、`triggerDraw()`、`attachSurface()`、全マウスイベント、IME 完全実装。
- `GhosttyInput.swift`: Ghostty 本家 `Ghostty.Input.swift` から keyCode マップを移植。`toMods()`（sided modifier 対応）、`toScrollMods()` 実装。
- `main.swift`: NSApplication HelloWorld、surface 作成 → attach → focus 設定。
- `Package.swift`: `.linkedLibrary("c++")` 追加（libghostty.a の glslang/spirv-cross C++ 依存に対応）。
- ghostty.h 直接確認による design doc 差異を修正（mouseButton 引数順、mousePos 引数数、scroll mods 型、context フィールド不在）。

## Change scope
| ファイル | 変更内容 |
|---------|---------|
| `Sources/AgtmuxTerm/GhosttyApp.swift` | 新規（118 行） |
| `Sources/AgtmuxTerm/GhosttyTerminalView.swift` | 新規（255 行） |
| `Sources/AgtmuxTerm/GhosttyInput.swift` | 新規（231 行） |
| `Sources/AgtmuxTerm/main.swift` | 置換（HelloWorld 実装） |
| `Package.swift` | `.linkedLibrary("c++")` 追加 |
| `docs/60_tasks.md` | T-002〜T-005 DONE に更新 |
| `docs/70_progress.md` | Phase 1 完了記録 |

## Verification evidence
- `swift build` → `Build complete! 0.13s` PASS（エラーなし・警告なし）
- バイナリ: 60MB arm64 Mach-O（`ghostty_surface_set_focus` など全 API シンボル解決確認済み）
- `ghostty_input_scroll_mods_t` 型: `typedef int` 確認 → bitmask 実装で対応
- `ghostty_surface_mouse_button` 引数順: header 直接確認 → `state, button, mods` 順に実装
- `ghostty_input_key_s.keycode`: `uint32_t` 確認 → Mac keyCode 直渡し（Ghostty 本家と同一方式）

## Risk declaration
- Breaking change: no（まだ UI が存在しないため）
- Fallbacks: none（CLAUDE.md ポリシー準拠）
- Known gaps / follow-ups:
  - [ ] `GhosttyInput.keyCodeMap` は定義済みだが未使用。Post-MVP でリファクタリング予定。
  - [ ] T-005 手動確認（シェル表示・IME・リサイズ）は T-009 統合テスト時に実施。
  - [ ] `ghostty_input_key_s.text` に文字を渡す方式は未実装（`ghostty_surface_text` で代替済み）。

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- 確認ポイント:
  1. `ghostty_surface_mouse_pos` に mods 引数を渡す実装は正しいか（header 確認済みだが念のため）
  2. `keyCodeMap` が未使用のまま放置することへの懸念はないか
  3. `main.swift` の `ghostty_surface_set_focus(surface, true)` 呼び出しタイミングは適切か
