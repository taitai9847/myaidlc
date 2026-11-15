# myaidlc の使い方

このリポジトリの myaidlc を、自分のプロジェクトで使う方法です。既存プロジェクトでも新規プロジェクトでも使えます。仕様の全体は [claude/docs/myaidlc.md](claude/docs/myaidlc.md)（英語）にあります。

## 目次

1. [導入とセットアップ](#1-導入とセットアップ)
2. [機能追加・バグ修正を進める](#2-機能追加バグ修正を進める)
3. [ゲート・レビュー・ガード](#3-ゲートレビューガード)
4. [プロジェクトに合わせたカスタマイズ](#4-プロジェクトに合わせたカスタマイズ)
5. [更新・ロールバック・削除](#5-更新ロールバック削除)
6. [困ったとき](#6-困ったとき)

## 1. 導入とセットアップ

前提：プロジェクトが git リポジトリで、`bash` と `jq` が入っていること。

1. 内容を確認してからコピーします。
   ```sh
   ./scripts/apply.sh --dry-run <project> core
   ./scripts/apply.sh <project> core
   ```
   - コピーされるもの：`myaidlc` と `myaidlc-setup` の skill、`myaidlc-*` の agent 3 つ、`docs/myaidlc.md`、`docs/dev-guideline.md`。コピー先は `<project>/.claude/` です。
   - 既存の項目が 1 つでもあると、何もコピーしません。
2. プロジェクトで Claude Code を起動し、`/myaidlc-setup` を実行します。setup は次のことをします。
   - 定義の整合を検査する（`myaidlc-engine.sh check`）。
   - `.claude/settings.json` に追加する内容を見せる。追加するのは hook と、Claude が毎回確認を求めずに myaidlc のエンジンを実行できる許可ルール（`Bash(.claude/skills/myaidlc/scripts/myaidlc-engine.sh:*)`）です。あなたが同意してから追加します。
   - `docs/myaidlc/` を作る。中身は `config.json`、`memory/project.md`、`memory/phases/`、`memory/templates/`、`intents/`、git 管理外の `.runtime/` です。
   - Build and Test で使う、プロジェクトの検証コマンド（build・lint・test）を確認する。
   - `AGENTS.md` に myaidlc の短い区画を足すかを聞く。
3. hook を有効にするため、Claude Code の新しいセッションを開きます。hook は共有の `.claude/settings.json` に入るので、このプロジェクトで Claude Code を使うチーム全員に `jq` が必要です。
4. `.claude/` と `docs/myaidlc/` を、いつものやり方でコミットします。
   - `.claude/.myaidlc-backup/` はコミットしないでください（`.gitignore` に足す）。
   - `docs/myaidlc/.runtime/` は、はじめから git 管理外です。

### 新規の空のプロジェクトで始める

myaidlc は、まだコードのないプロジェクトでも動きます。リポジトリにコミットがなくてもかまいません。

1. プロジェクトのフォルダを作り、git リポジトリにします。
   ```sh
   mkdir <project> && cd <project> && git init
   ```
2. `apply.sh` で myaidlc をコピーします。
   ```sh
   <myaidlc>/scripts/apply.sh . core   # <myaidlc> はこのリポジトリを clone した場所
   ```
3. 上の手順 2 から続けます。`/myaidlc-setup` を実行し、新しいセッションを開きます。
4. `/myaidlc <依頼>` で作業を始めます。

`apply.sh` を使わずに、`claude/` の中身を手で `<project>/.claude/` にコピーしても動きます。ただし、プロジェクトに要らないファイルも一緒に入るので、コピーした後で消してください。

| 手でコピーすると入るもの | 要らない理由 | 対処 |
|---|---|---|
| `settings.json` | このリポジトリに置いている、あなたの個人用の Claude Code 設定（git 管理外） | 消す。プロジェクト用の `settings.json` は `/myaidlc-setup` が作る |
| `CLAUDE.md` | あなた個人の全体指示。`.claude/CLAUDE.md` に置くと、プロジェクトで作業する全員への指示になる | 消す |
| `skills/create-skill/` | このリポジトリで作業するための skill | 消す |
| `commands/`、`hooks/` | 空のフォルダ | 消す |

手でのコピーより `apply.sh` を勧めます。
- `bundles/core.txt` にある項目だけをコピーします。
- `settings.json` と `CLAUDE.md` には触れません。
- コピーした内容を `.claude/.myaidlc-manifest` に記録するので、後で `--force` を付けて更新するときも安全です。

myaidlc は既存のコードに手を入れる前提で作っています。コードのないプロジェクトでは、最初の作業で Reverse Engineering が読むものがほとんどないため、コードマップはほぼ空になります。これは想定どおりです。

## 2. 機能追加・バグ修正を進める

```
/myaidlc 商品一覧に保存済み検索を追加したい
```

myaidlc がスコープを提案するので、確認します。

| スコープ | 向いている作業 | ステップ |
|---|---|---|
| Feature | 新しい振る舞いの追加 | 意図 → コードの読み込み → 要件 → 実装計画（Unit 分割）→ Unit ごとに設計・コード計画・コード → ビルドとテスト → 引き継ぎ |
| Bugfix | 既知の不具合の修正 | 意図（症状と再現手順）→ コードの読み込み（原因の候補）→ 回帰テスト付きの修正計画と修正 → ビルドとテスト → 引き継ぎ |

各ステップの成果物は `docs/myaidlc/intents/<YYMMDD>-<label>/` に書かれます。コードは、変更する箇所の付近だけを読みます。

| したいこと | 言い方 |
|---|---|
| 続きから再開する | `/myaidlc` |
| 現在地を見る | `/myaidlc status` |
| 一時停止する | `/myaidlc park`（ゲートで「今日はここまで」と言ってもよい） |
| 前の工程に戻る、先に飛ぶ | `/myaidlc jump requirements-analysis`、または言葉で頼む |
| 別の作業に切り替える（急ぎのバグ修正など） | `/myaidlc <依頼>` で始め、`/myaidlc intent <name>` で戻る |
| 今のステップの外で Claude にコードを変えさせる | ガードを外すよう頼み、後で戻す。あなた自身がエディタで直すのは止められない |

作業の成果物は、自分で編集してもかまいません。次のステップがその変更を読み込みます。

## 3. ゲート・レビュー・ガード

**ゲート**
- 承認を求められるのは、次のものです。
  - 意図
  - 要件
  - 実装計画
  - Unit ごとのコード計画と、その Unit の結果
  - テスト結果
  - 引き継ぎ
- **Approve**（承認）か **Request changes**（変更を依頼）で答えるか、自分の言葉で答えます（「良さそう。ただしハンドラ名は変えて」など）。
- 返答は、その作業の `audit.md` に記録されます。

**レビュー**
- 設計かコードを作るフェーズは、そのフェーズの最後の承認の前に必ずレビューします。
- 文書は `general-purpose`（Opus）がレビューします。フェーズの途中で承認した文書がレビューで変わったときは、その承認の場で変更点が示されます。
- コードは `feature-dev:code-reviewer`（Opus）がレビューします。そのプラグインがない環境では `general-purpose`（Opus）が代わりにレビューします。レビュアーは編集しません。
- 指摘は P0〜P3 に分けられます。
  - P0 と P1 は、ゲートに来る前にすべて直されます。
  - P2 と P3 は、直すかどうかをあなたが決めます。
- 修正を見送ることも、レビューを省くこともできます。

**ガード**
- 作業中は、Claude がプロダクトのコードを変えられるのは、コード計画が承認された後と、Build and Test の実行中だけです。`docs/` と `.claude/` はいつでも書き込めます。
- エンジン自身の記録（`state.json`、`state.md`、`audit.md`）は、Claude も編集しません。あなたも編集しないでください。例外は、これらのファイルで git のマージ競合が起きたときで、通常どおり解消してかまいません（「困ったとき」を参照）。
- 今の作業についてだけ、ガードを外すことができます。

## 4. プロジェクトに合わせたカスタマイズ

| 何を | どこに |
|---|---|
| このプロジェクトのルール | `docs/myaidlc/memory/project.md` |
| 特定のフェーズのルール | `docs/myaidlc/memory/phases/<phase>.md`（`ideation`、`inception`、`construction`、`operation`） |
| 成果物の書式 | `docs/myaidlc/memory/templates/<file>.md`（例：`requirements.md`）。同じ名前の既定テンプレートを置き換える |
| 検証コマンド・既定のスコープ・ガード | `docs/myaidlc/config.json` |

ルールは次の順に読まれ、食い違うときは後のファイルが優先されます。
1. myaidlc の既定
2. `AGENTS.md`
3. `project.md`
4. フェーズ別のファイル

ステップの途中で myaidlc の作業を訂正すると、その訂正をルールとして残すかどうかを一度だけ聞かれます。残すと答えると、`project.md` に追記されます。

## 5. 更新・ロールバック・削除

**更新**
- `./scripts/apply.sh --force <project> core` を実行します。前の版は `.claude/.myaidlc-backup/<timestamp>/` に移ります。
- `docs/myaidlc/` には触れません。ただし、コピーした項目は `.claude/docs/dev-guideline.md` も含めてすべて置き換わります。プロジェクトの規約は、コピーした項目ではなく `AGENTS.md` か `docs/myaidlc/memory/` に書いてください。
- 更新した後は `/myaidlc-setup` をもう一度実行します。足りないものだけを足します。

**ロールバック**
- `.claude/.myaidlc-backup/<timestamp>/` から、項目を元の場所に戻します。

**削除**
1. 次のものを消します。
   - `.claude/skills/myaidlc`、`.claude/skills/myaidlc-setup`
   - `.claude/agents/myaidlc-*.md`
   - `.claude/docs/myaidlc.md`
   - `.claude/docs/dev-guideline.md`（ほかで使っていなければ）
2. `.claude/settings.json` から、次のものを消します。
   - `myaidlc-engine.sh hook` を実行する hook 3 つ
   - `permissions.allow` の `Bash(.claude/skills/myaidlc/scripts/myaidlc-engine.sh:*)`
3. `AGENTS.md` の `<!-- myaidlc:begin -->` の区画を消します。
4. `docs/myaidlc/` は記録なので、残しても消してもかまいません。

## 6. 困ったとき

| 症状 | 対処 |
|---|---|
| 「The myaidlc hooks are not installed」と出る | `/myaidlc-setup` を実行し、新しいセッションを開く |
| コードの編集が止められる | コード計画がまだ承認されていないか、コードを変えないステップにいる。計画を承認するか、ガードを外すよう頼む |
| 「myaidlc is busy」と出る | 別の myaidlc のコマンドが実行中。1 分待つ（古いロックは 1 分で自動的に外れる）。それでも続くときは `docs/myaidlc/.runtime/lock.d` を消す |
| 以前は hook が動いていたのに、返答が受け付けられない | `/myaidlc-setup` を実行し、新しいセッションを開く。意図して hook を外したときは `docs/myaidlc/.runtime/hooks-alive` を消す |
| `state.json` で git の競合が起きた | 通常の競合と同じように解消する。正しい JSON になるように、たいていは新しい方を残す。`git checkout -- <path>` で戻してもよい。`state.md` は次のステップで作り直される |
| `state.md` のステップの状態がおかしい | `/myaidlc status` を実行する。ステップをやり直すときは、そのステップに戻る |
| `feature-dev:code-reviewer` が使えない | 対処は不要。代わりに `general-purpose`（Opus）がコードをレビューする |
