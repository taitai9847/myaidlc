# myaidlc

myaidlc は、Claude Code で既存プロジェクトへの機能追加とバグ修正を進めるためのワークフローです。AI-DLC（AI-Driven Development Life Cycle）を最小限に組み直したもので、プロジェクトの `.claude/` にコピーするだけで使えます。

- **人が制御する**：何を作るかを決め、各ゲートで結果を承認します。スキップ・前の工程への戻り・中断はいつでもできます。
- **エンジンが帳簿をつける**：bash + jq のスクリプトが次のステップを決め、状態・監査ログ・承認の証跡・レビュー記録・コードのガードを管理します。
- **コンダクターが作業する**：`/myaidlc` skill が 1 ステップずつ進めます。
  - コードは、変更箇所の付近だけを Explore（Haiku）で読みます。
  - 設計とコード変更はすべて Opus でレビューし、P0 と P1 の指摘はすべて反映します。

5 フェーズ・10 ステージ・3 agent・2 スコープ（`feature` と `bugfix`）で構成しています。

- 設計の考え方は [AI-DLC（awslabs/aidlc-workflows）](https://github.com/awslabs/aidlc-workflows) を参考にしています。
- 特定の言語・フレームワーク・ブランチ運用を前提にしません。
- 必要なのは bash 3.2 以降、jq、git です。

## 構成

```
myaidlc/
├── claude/                        # .claude/ に置く中身
│   ├── CLAUDE.md                  # 個人の全体指示（配布しない）
│   ├── settings.json              # 個人設定（git 管理外、配布しない）
│   ├── docs/myaidlc.md            # myaidlc の仕様書（原則・ステージ・記録・レビュー・ガード）
│   ├── docs/dev-guideline.md      # コードを変えるステップが読む開発ガイドライン
│   ├── agents/myaidlc-*.md        # product・architect・developer
│   ├── commands/, hooks/          # 空（その種類の項目用に残している）
│   └── skills/
│       ├── myaidlc/               # コンダクター
│       │   ├── SKILL.md
│       │   ├── scripts/myaidlc-engine.sh   # エンジンと hook
│       │   ├── stages/<phase>/<slug>.md    # 各ステップの内容（frontmatter = 経路、本文 = 手順）
│       │   ├── scopes/{feature,bugfix}.md  # 作業の種類ごとに通るステップ
│       │   ├── protocol/                   # 全ステップとレビューの進め方
│       │   ├── rules/defaults.md           # 既定のルール
│       │   └── templates/                  # 成果物の既定テンプレート
│       ├── myaidlc-setup/         # hook とプロジェクトの docs/myaidlc/ を用意する
│       └── create-skill/          # このリポジトリ用（配布しない）
├── bundles/core.txt               # まとめて配布する claude/ 以下の項目
├── USAGE.md                       # プロジェクトでの myaidlc の使い方
├── templates/skill/               # 新しい skill のテンプレート
└── scripts/
    ├── apply.sh                   # bundle や項目を対象プロジェクトの .claude/ にコピーする
    ├── validate.sh                # skill・agent・bundle・スクリプト・README の表・myaidlc の定義・エンジンのテストを検査する
    └── test-myaidlc.sh            # エンジンのエンドツーエンドテスト（bash 3.2 以降）
```

myaidlc は、利用先プロジェクトの `docs/myaidlc/` に記録を残します。設定・プロジェクトのルール・テンプレートの上書きと、作業ごとのフォルダ（状態・監査ログ・成果物）です。

## プロジェクトへの適用

導入・セットアップ・機能追加やバグ修正の進め方・カスタマイズ・更新・削除の手順は [USAGE.md](USAGE.md) にあります。

```sh
./scripts/apply.sh --dry-run <project> core   # 作成・置き換えされるものを確認する
./scripts/apply.sh <project> core             # myaidlc を <project>/.claude/ にコピーする
./scripts/apply.sh --force <project> core     # 最新版に更新する
```

その後、プロジェクトで `/myaidlc-setup` を実行します。

- 項目は `skills/<name>`、`agents/<file>`、`commands/<file>`、`hooks/<file>`、`docs/<file>` のいずれかです。
- 既存の項目は、`--force` を付けない限り置き換えません。`--force` を付けると、前の版は `.claude/.myaidlc-backup/<timestamp>/` に移ります。
- `apply.sh` が書き込むのは `.claude/` の中だけです。`settings.json`・`AGENTS.md`・`CLAUDE.md`・プロジェクトの `docs/` には触れません。
- 実行するたびに、コピー元のコミットとコピーした項目を `.claude/.myaidlc-manifest` に追記します。

## skill の追加

```sh
cp -r templates/skill claude/skills/my-skill   # name をディレクトリ名と同じにする
./scripts/validate.sh
```

`validate.sh` の前に、下の Skills の表に行を足してください。`validate.sh` は、表と `claude/skills/` の中身が一致するかを検査します。プロジェクトに配布する skill は `bundles/core.txt` にも足します。

myaidlc の工程を変えるときは、ステージかスコープのファイルを編集します。frontmatter が経路そのものなので、エンジンには手を入れずに経路を変えられます。変更後は `./scripts/validate.sh` を実行してください。`myaidlc-engine.sh check` とエンジンのテストもあわせて実行されます。

## Skills

| Name | Description |
|---|---|
| `create-skill` | テンプレートから新しい skill を作り、検査を実行する |
| `myaidlc` | コンダクター。既存プロジェクトの機能追加やバグ修正を、エンジンの指示どおり 1 ステップずつ進める。各ゲートで人が承認し、フェーズごとにレビューを挟む |
| `myaidlc-setup` | プロジェクトに myaidlc を用意する。`docs/myaidlc/` を作り、差分を見せたうえで `.claude/settings.json` に hook と許可ルールを入れ、プロジェクトの検証コマンドを記録する |

## Agents

| Name | Description |
|---|---|
| `myaidlc-architect-agent` | 既存のコードの中でどう作るか。Reverse Engineering・Delivery Planning・Functional Design を担当する |
| `myaidlc-developer-agent` | 承認済みのコード計画を、テスト付きで実装する。Code Generation の実装段階で起動され、コード計画と Build and Test ではその役割で作業する |
| `myaidlc-product-agent` | 何を作るか。Intent Capture・Requirements Analysis・Handoff を担当する |
