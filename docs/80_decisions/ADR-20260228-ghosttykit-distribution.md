# ADR-20260228b: GhosttyKit.xcframework 配布戦略

- **Status**: Accepted
- **Date**: 2026-02-28
- **Deciders**: プロジェクトオーナー

## Context

GhosttyKit.xcframework は `zig build xcframework` で生成するバイナリアーティファクト（≈数十〜数百 MB）。
このファイルをリポジトリでどう管理するか、T-001 着手前に決定が必要。

### 選択肢

| 方式 | メリット | デメリット |
|------|----------|------------|
| **A. Git LFS** | clone で自動取得、CI がシンプル | LFS のセットアップが必要（`git lfs install`） |
| **B. .gitignore + ビルドスクリプト** | リポジトリが軽量 | CI に Zig + Ghostty clone が必要、初回ビルドに時間 |
| **C. GitHub Releases で別管理** | クリーンな分離 | Ghostty バージョンとの対応管理が複雑 |

## Decision

**Git LFS を採用する（方式 A）。**

1. `GhosttyKit/GhosttyKit.xcframework` を Git LFS で管理する
2. `vendor/ghostty/` は `.gitignore` で除外する（ビルド専用、コミットしない）
3. `scripts/build-ghosttykit.sh` をリポジトリに置いて再ビルド手順を明文化する

## Rationale

- **開発者体験が最良**: `git clone` だけで環境が完成し、Zig のインストール不要で動作確認できる
- **CI がシンプル**: GitHub Actions の標準 LFS サポートを使えば追加の Zig インストールステップが不要
- **xcframework の更新頻度**: Ghostty upstream の breaking changes がない限り更新しない。LFS のストレージコストは許容範囲
- **ビルドスクリプトを残す**: `scripts/build-ghosttykit.sh` で Ghostty バージョンアップ時の再生成手順を保持する

## Implementation（T-001 手順に追加）

```bash
# 1. Git LFS のセットアップ（リポジトリルートで一度だけ）
git lfs install
git lfs track "GhosttyKit/**/*.a"
git lfs track "GhosttyKit/**/*.framework/**"
git add .gitattributes

# 2. Ghostty ソースでビルド（vendor/ は .gitignore 済み）
git clone https://github.com/ghostty-org/ghostty vendor/ghostty
cd vendor/ghostty && zig build xcframework
cp -r zig-out/lib/GhosttyKit.xcframework ../../GhosttyKit/

# 3. LFS 経由でコミット
cd ../..
git add GhosttyKit/
git commit -m "build: add GhosttyKit.xcframework via Git LFS"
```

## .gitignore 追記内容

```
vendor/ghostty/
vendor/ghostty/**
```

## Consequences

### Positive
- `git clone` 後すぐ `swift build` できる（Zig 不要）
- CI の設定が最小限

### Negative / Tradeoffs
- Git LFS のストレージコスト（GitHub Free: 1GB LFS まで無料）
- LFS を使わず clone した場合、xcframework がポインタファイルになりビルドが失敗する（README に警告必須）
- Ghostty の大幅バージョンアップ時は `build-ghosttykit.sh` で再生成してコミットし直す必要がある
