# myaidlc

プロジェクトの `.claude/` に置く内容を作るためのリポジトリ。`claude/` 以下が `.claude/` の中身にあたる。

## 方針
- 特定の言語・フレームワーク・ブランチ運用・リポジトリ構成を前提にしない
- 前提が必要なものは、書く代わりに利用側のプロジェクトの AGENTS.md（CLAUDE.md から `@AGENTS.md` で読み込まれる）を読ませる
- 秘密情報・絶対パス・個人環境依存の記述を入れない（git 管理のため）
- `ref/` は参考資料（git 管理外）。内容を転記せず、読んで設計の参考にするだけにする

## 作成ルール
- skill は `templates/skill/` をコピーして作り、name はディレクトリ名と一致させる
- description は「いつ使うか」を具体的に書く
- 1つの skill / agent は1つの責務だけ持たせる
- 実装系の skill は、最初に `.claude/docs/dev-guideline.md`（`claude/docs/dev-guideline.md`）を読むよう SKILL.md に書く。skill 側にガイドラインを複製しない
- 作成・変更後、特定のスタックに依存していないか自己チェックし、依存があれば直すか報告する
- プロジェクトに配布する skill / agent は `bundles/core.txt` に追加する
- 変更後は README の Skills・Agents 表を更新してから `./scripts/validate.sh` を通す

## myaidlc を変更するとき
- 仕様は `claude/docs/myaidlc.md`。設計思想（4 つの原則）に反する変更をしない
- 経路・状態遷移・承認・レビュー・ガードの判定は `claude/skills/myaidlc/scripts/myaidlc-engine.sh` だけが持つ。同じ判定を SKILL.md やステージ本文に書かない
- ステージ・スコープは frontmatter（`key: value` / `key: [a, b]` のみ）を変えるだけで経路が変わる。追加・変更後は `myaidlc-engine.sh check` を通す
- エンジンを変えたら `./scripts/test-myaidlc.sh` を通す（bash 3.2 でも実行される）。新しい挙動にはテストを足す
- 挙動・形式を変えたら `claude/docs/myaidlc.md` の Spec version を上げ、USAGE.md も合わせて直す
