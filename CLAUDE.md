# Project Rules — Claude Code

---
## 全エージェント共通

**Source of Truth**: `docs/` only. `.claude/plans/` は scratch — docs に同期するまで有効ではない。
詳細プロトコル → `docs/00_router.md`。

**Code Quality Policy**:
- **Fail loudly**: 実装レベルの silent fallback 禁止。エラーは surfacing する。
- **後方互換性**: 明示的な指示がない限り不要。patch より clean break を選ぶ。
- **Fallback**: エラーを暗黙に握りつぶす実装禁止。失敗は呼び出し元に伝播させる。
- **Elegance**: non-trivial な変更は「より elegant な解法がないか」を必ず問う。hacky に感じたら redesign。

**Verification Before Done**:
- 動作証明なしに完了マークをつけない。テスト実行・ログ確認・正しさの実証を行う。
- 「Staff engineer がこれを approve するか？」と自問する。

**Self-Improvement**:
- ユーザーから修正を受けたら `docs/lessons.md` にパターンを記録する。
- セッション開始時、関連 lessons があれば確認する。

---
## Orchestrator のみ — Task tool で起動された場合（subagent）はこのセクションを無視する

### Orchestrator の役割
直接行うこと：`docs/*` の更新 / subagent への委任と評価 / 最終 GO/STOP 判断
委任すること：**コード実装** / **テスト実行** / **コードレビュー**

### docs/* 更新タイミング

| Tier | ファイル | 更新タイミング |
|------|----------|----------------|
| **Stable** | CLAUDE.md / router.md / foundation.md | 変更は escalation のみ |
| **Design** | spec / architecture / design / plan | Plan 承認時、コードより前 |
| **Tracking** | tasks / progress / decisions / reviews / lessons | タスク・フェーズごと（Orchestrator 専有） |

### Plan & Subagent Strategy
- non-trivial タスク（3ステップ以上 or 設計判断）は必ず plan mode に入る。問題発生時は即 re-plan。
- subagent を積極的に使い、main context を守る。**1 subagent = 1 task**。
- 複雑な問題ほど subagent へのコンピュート配分を増やす。リサーチ・探索・並列分析は subagent へ。

### Hard Gates (structural — cannot skip)

1. **Delegate**: コード実装 / テスト実行 / コードレビューは subagent に委任。
   Orchestrator は**コードを**直接書かない・実行しない（`docs/*` 編集は Orchestrator の責務）。

2. **Plan → docs first**: Plan 承認後、コード1行書く前に：
   - Design tier：変更があれば更新
   - `docs/60_tasks.md`：タスクエントリを追加・更新
   - `.claude/plans/<承認されたプランファイル>` を削除する

3. **Phase checkpoint**: Multi-phase task — 各フェーズ完了直後に `docs/70_progress.md` 更新。
   タスク完了まで defer 禁止。

4. **Review before commit**:
   - Orchestrator が `docs/85_reviews/` に Review Pack を作成（テンプレート: `docs/85_reviews/_review-pack-template.md`）
   - Review subagent が 4-tier verdict (GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO) を出す
   - `GO_WITH_CONDITIONS`：全条件を `docs/60_tasks.md` に follow-up task 登録してから commit
   - `NO_GO`：必ず修正してから再レビュー。3回連続 NO_GO はユーザーにエスカレーション
   - `NEED_INFO` が 2回連続：別 reviewer に交代 or `GO_WITH_CONDITIONS` + follow-up task 化
   - **前提**: ビルド確認後でないと Review Pack 作成禁止
   - commit / push は Orchestrator の GO 決定後のみ

### Task Management
1. **Plan First**: `docs/60_tasks.md` にチェック可能なタスクとして書く
2. **Verify Plan**: 実装開始前にレビューし、根本原因を特定してから着手する
3. **Track Progress**: 完了したものを都度マーク。推測で進めず、確認してから次へ
4. **Explain Changes**: 各ステップで高レベルのサマリをユーザーに提供する
5. **Capture Lessons**: 修正を受けたら `docs/lessons.md` にパターンを記録する

### やらないこと
- docs 更新前にコードから書き始める
- フェーズをまたいで docs 更新を後回しにする
- Stable tier を escalation なしに変更する
- 根本原因を特定せず一時的な fix を適用する
- ユーザーに不要なガイダンスを求める（バグ報告を受けたら自律的に調査・修正する）
