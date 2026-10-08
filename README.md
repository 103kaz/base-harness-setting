# base-harness-setting

新しいプロジェクトの開始時に配る、Claude Code のハーネスとループの共通構成。

## 構成

| 場所 | 入れる先 | 中身 |
|---|---|---|
| `user/` | `~/.claude` | 個人共通のルール (`CLAUDE.md`)、`settings.json` (deny / ask とフックの登録)、ガードなどのフック、スキル (`adversarial-review` と言語別の観点、`doc-code-consistency`) |
| `project/` | 新規プロジェクトのルート | `CLAUDE.md` の雛形、検証ループ (`.claude/settings.json`・`verify.sh`・`hooks/`)、コマンド (`/review-loop`・`/retro`・`/address-comments`)、プロジェクト固有の観点、pre-push |
| `templates/` | `./init.sh lang` が使う | 言語別の観点の雛形 |
| `scripts/` | このリポジトリ内で使う | `test-base.sh` (回帰テスト)、`check-sync.sh` (`~/.claude` と `user/` の一致)、`doctor.sh` (導入の確認) |
| `.github/workflows/test.yml` | このリポジトリの CI | `test-base.sh` を ubuntu で流す (macOS は手元で流す) |

ファイル単位の説明は、各ファイルの冒頭のコメントにある。同梱している言語の観点は `user/skills/adversarial-review/checklists/languages/` にある。

ルートの `CLAUDE.md`・`.claude/`・`.githooks/` は、このリポジトリ自身の開発に使う設定 (雛形を自分自身に入れたもの)。配布物ではない。

## 前提

macOS の bash 3.2 で開発している。回帰テスト (`scripts/test-base.sh`) は、macOS では手元で、Linux (ubuntu) では CI で流す。

| コマンド | 要否 | 用途 |
|---|---|---|
| bash、git | 必須 | フック、`init.sh`、pre-push |
| jq | 必須 | ガードが Claude Code から渡される JSON を読む。無いと、ガードは Bash と MCP の操作をすべて止める (理由と `brew install jq` を表示する) |
| gitleaks | pre-push を使うなら必須 | push するコミットの検査。無いと push を止める (`brew install gitleaks`) |
| gh | GitHub を使うなら | PR、レビューコメント対応、ガードの `gh` の判定 |
| terraform | 任意 | `.tf` の編集後の `terraform fmt`、`terraform` 操作のガード。無ければ fmt は何もしない |

Claude Code のフックと settings の仕組みを使う。配布先の `~/.claude/settings.json` が既にあると、`./init.sh user` は上書きしない。ガードのフックと deny / ask は、`./init.sh user --merge-settings` で既存の設定に足せる (SETUP.md の 1)。

## 保証しないこと

ガードと検証ループは、操作の事故を減らすための仕組みで、安全の保証ではない。

- **ガードはコマンドの文字列を見る判定。** python などを経由した同じ操作や、判定に当たらない書き方は止められない。deny も、ファイル名のパターンに当たるものだけを止める。サンドボックスの代わりにはならない
- **検証ループは自己申告の仕組みで、強制ではない。** 状態は `$TMPDIR` に置き、`VERIFY_MAX_RETRY` で止める回数も変えられる。3 回続けて失敗したまま終わるときは、警告を出して通す
- **プロジェクトのフックは、プロジェクトのルートをメインのフォルダにしてセッションを開いたときだけ読まれる。** 親のディレクトリを開くと、検証ループは何も言わずに無効になる。`doctor.sh` は検出できない (確かめ方は SETUP.md の 6)
- **Claude Code の仕様に依存している。** フックに渡される JSON の形や settings の仕組みが変わると壊れうる。実際のセッションでの確認は、Claude Code 2.1.293、macOS の 1 環境だけで、他の OS やバージョンは確かめていない。回帰テストは macOS と ubuntu の bash で流している

このベースを使って起きたことについて、作者は何も保証せず、責任を負わない (データの消失、意図しない push や削除、機密値の漏えいなどを含む)。使うかどうかと、入れた後の設定の確認は、使う人が判断する。条件は [MIT ライセンス](LICENSE) の無保証の条項に従う。

## セットアップ

配布の方法 (`./init.sh`) と、雛形を入れた後に新しいプロジェクトで最初にやることは [SETUP.md](SETUP.md) にある。入れた後は `bash scripts/doctor.sh <project-dir>` で確かめる (SETUP.md の 6)。自分向けに変える範囲と、ベースを更新したときの取り込み方も SETUP.md に書いてある。

## ループ

| ループ | 仕組み | 動き |
|---|---|---|
| 開発 | `/review-loop` | 検証 → code-review (medium) → 修正を、指摘が出なくなるまで。続けて CLAUDE.md の「PR 前のテスト」(検証ループに入れない重いテスト) を回す。push / PR の前に敵対的レビューを回すかをユーザーに聞く |
| 検証 | UserPromptSubmit と Stop のフック + `.claude/verify.sh` | 回の始めの作業ツリーを記録し、そこから変わった状態 (回の中のコミットを含む) で応答を終えようとすると verify.sh を走らせる。失敗なら出力を返して直させる。1 回の中で止めるのは 3 回まで (`VERIFY_MAX_RETRY` で変更)。3 回目は「直せなければユーザーに報告して終える」よう Claude に伝え、それでも失敗したまま終わったときは画面に警告を出す |
| 振り返り | `/retro` | 観点に無い指摘とレビュー後のバグを、共通 / 言語 / プロジェクトの観点リストへ一般化して足す。不具合の修正では、`/review-loop` が「以前のレビューを通ったコードのバグか」を確かめて `/retro` に回す。観点のリストが14,500 バイトを超えると、`verify.sh` が失敗する (`~/.claude` の観点は、どのプロジェクトでも) |
| レビューコメント対応 | `/address-comments` | PR のレビューコメントを集め、直す → `/review-loop` → 返信の下書き。push と返信の投稿は、ユーザーの OK を取ってから行う。行のコメントへの返信は、ガードが `gh api` の変更系 (リポジトリ設定の経路を除く) を止めるので、コマンドを示してユーザーが実行する |

## ガードの一覧

`./init.sh user` で `~/.claude` に入るフックと settings が、Claude Code の操作を次のように扱う。止めた操作は、理由と「人間が実行するコマンド」を Claude に返すので、Claude は回避せず、あなたに実行を頼む。「確認」の操作は、確認の画面が出るので、チャットで対象を指して OK してから承認する。

**止める (承認でも通らない)**

| 分類 | 操作 |
|---|---|
| 機密値 | `.env`、`*.tfvars`、`*.tfstate`、`*token*.txt`、鍵、署名資産、サービスアカウント鍵、`~/.ssh`、`~/.aws`、`~/.config/gcloud`、`~/.config/gh`、`~/.kube`、`~/.docker`、`~/.netrc` などの読み出し。Secret Manager の値の出力 |
| git | `main` / `master` への push (初回を除く)。`--no-verify`、`--mirror`、`--delete`、`--all`。`core.hooksPath` の変更。alias / include の設定 |
| GitHub | `gh secret set/delete`、`gh repo delete`、`gh release delete`、`gh pr merge --admin/--auto`。`gh api` の変更系 (リポジトリ設定の経路への単独の呼び出しを除く) |
| terraform | `destroy`、`import`、`taint`、`state` の変更。`apply` の `-auto-approve`、`-target`、`-var` など |
| クラウド | ディスク・インスタンス・プロジェクトなどの削除。`wrangler` の deploy / delete / secret の変更 |
| その他 | `curl` / `wget` の出力を sh に渡す実行。ルートやホームを対象にした `rm -r`。`~/.claude/hooks`・`settings*`・`.githooks`・`.git/config`・`.git/hooks` の Bash での書き換え |

**確認する (あなたが承認すれば通る)**

| 分類 | 操作 |
|---|---|
| push・マージ | `git push` (すべて)、`main` / `master` への初回 push、force push。`gh pr merge`。`gh workflow run` |
| GitHub の設定 | `gh api` の、リポジトリ本体・rulesets・vulnerability-alerts・actions/permissions などへの単独の呼び出し (経路ごとにメソッドとフィールドを絞る) |
| terraform | `terraform apply` (保存した plan ファイルを指定する形のみ) |
| 作業の破棄 | `git clean`、`reset --hard`、`restore`、`checkout --`、`stash drop`、`branch -D`。ビルド生成物でないディレクトリの `rm -r` |
| マシンの設定 | `sudo`。`launchctl` の `bootstrap` / `load` / `enable`。`crontab` (`-l` を除く)。`defaults write` / `delete` |
| ハーネスの編集 | `.claude/hooks`、`.claude/verify.sh`、`.claude/settings*`、`.githooks`、`~/.claude` の Edit。`.github/workflows`、`firebase.json` の編集 |
| MCP | 外部のリソースを消す・公開する・秘密を変えるツール。データベースを変更する SQL |

「確認する」のうち、`git push`、`gh pr merge`、`gh workflow run`、`terraform apply`、ハーネスの Edit は `settings.json` の ask が確認の画面を出す。それ以外はガード (`guard-*.sh`) が出す。

ガードの限界は「保証しないこと」に書いた。ガードを変えたら `user/hooks/test-guard.sh` にケースを足して通す。

## 同梱していない言語の観点を足す

観点のファイルが無い言語は、共通の観点 (`common.md`) とプロジェクトの観点だけでレビューされる。言語のファイルが勝手に作られることはない。足し方は 2 通り。

**レビューの結果から足す (`/retro`)**
敵対的レビューで、どの観点にも当たらない指摘が「新規」として出たとき、または、レビューを通った後でバグが見つかったときに、実装したセッションが `/retro` で言語の観点に一般化して足す。その言語のファイルが無ければ、このとき新しく作る。最初は指摘が出た分だけの小さなファイルで始まり、使うほど育つ。

**先に作っておく**
対話式の `./init.sh` の最初の質問で足せる。1 言語だけなら、直接呼ぶこともできる。

```bash
./init.sh lang rust --ext .rs --prefix RS
```

`user/skills/adversarial-review/checklists/languages/rust.md` が、`templates/language-checklist.md` から作られる。`--ext` と `--prefix` は省略できる (拡張子は `.<言語名>`、接頭辞は言語名の先頭 3 文字の大文字)。既にあるファイルは上書きしない。作った後に観点を書き、`./init.sh user` で `~/.claude` に反映する。手で作るときの形式は次のとおり。

```markdown
# <言語> の観点

拡張子 `.xx` のファイルに当てる。想定する用途を一行で。

### XX-01 観点の見出し
- 観点: 何が壊れうるか。壊れる入力・状態・順序
- 確かめ方: 実際に再現するか、確かめるための手順
```

- ID は言語ごとの接頭辞 + 連番 (`GO-01`、`RB-01` など)。
- 観点は、言語やその標準ライブラリ、実行環境に固有のものだけを書く。言語に依存しないものは `common.md` に、そのプロジェクトの仕様に依存するものはプロジェクトの `.claude/review/checklist.md` に置く。
- 1 ファイルは約 14KB までにする。毎回読み込まれるので、超えたら統合・削除する。
- `~/.claude` の側で作ったファイルをベースに戻したいときは、`user/skills/adversarial-review/checklists/languages/` にコピーする。

## このベース自体を変えるとき

`scripts/test-base.sh` を通す。ガード (`user/hooks/guard-bash.sh`) を変えたら `user/hooks/test-guard.sh` にケースを足して通す。
観点とガードは `~/.claude` で育てる (`/retro` もそこに足す)。変えたら同じ回で `user/` にも同じ変更を入れ、`bash scripts/check-sync.sh` で一致を確かめる。CLAUDE.md と settings.json は `~/.claude` 側に個人固有の記述があるので比較の対象外で、汎用の部分だけを手で反映する。`./init.sh user` は既存のファイルを上書きしないので、`user/` から `~/.claude` へ戻すときは、差分を見て Edit で入れるか `--force` を使う。

## 同梱していないもの

- プロジェクト固有の `autoMode` 設定
- 自走ループ (タスクリスト駆動)。必要になったら足す

## ライセンス

MIT ([LICENSE](LICENSE))
