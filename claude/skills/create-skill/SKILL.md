---
name: create-skill
description: 新しい skill を作成するときに使う。「skill を作りたい」「〜する skill を追加して」と言われたら、テンプレートから SKILL.md を作り、validate まで行う。
argument-hint: "[作りたい skill の目的]"
---

# create-skill

新しい skill を `claude/skills/<name>/SKILL.md` として作成する。

## 手順

1. 目的を確認する。不明なら「何をするか」「どんなときに使うか」「実装系か（コードを書き換えるか）」を質問する
2. kebab-case の `name` を決める。既存の `claude/skills/` と重複しないことを確認する
3. `templates/skill/` を `claude/skills/<name>/` にコピーする
4. SKILL.md を編集する
   - frontmatter の `name` をディレクトリ名と一致させる
   - `description` に「何をするか」と「いつ使うか」を具体的に書く
   - 1つの skill には1つの責務だけ持たせる。複数に分かれるなら skill を分割する
   - 長い資料は `references/`、実行スクリプトは `scripts/` に分ける
   - 使わないコメントやプレースホルダを残さない
5. 実装系の skill なら、手順の最初に `.claude/docs/dev-guideline.md` を読む旨を書く。ガイドラインの内容は複製しない
6. 特定の言語・フレームワーク・ブランチ運用に依存していないか自己チェックする。依存があれば汎用的に直すか、利用側の AGENTS.md を読ませる形にする
7. README の Skills 表に追記する。プロジェクトに配布する skill なら `bundles/core.txt` にも追加する
8. `./scripts/validate.sh` を実行する（README の表と実体の一致も検査される）。NG が出たら直して再実行し、すべて OK になるまで繰り返す
9. 作成した skill の名前・目的・validate の結果を報告する
