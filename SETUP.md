# セットアップ

新しいプロジェクトを始めるときに、最初にやること。

## 1. 配布する

引数なしで実行すると、対話式で設定できる。

```bash
./init.sh
```

聞かれる内容は 3 つ。空 Enter は `[ ]` の中か `(Y/n)` の大文字側の既定値になる。

1. 新しい言語のレビュー観点を足すか (言語名、拡張子、ID の接頭辞。何件でも続けて足せる)
2. 個人共通を `~/.claude` に配布するか (マシンに 1 回)
3. プロジェクトの雛形を入れるか (ディレクトリ、プロジェクト名)

最後に、内容が違う既存ファイルを上書きするかを聞き、実行内容を表示して確認してから実行する。実行の順は 言語の観点 → 個人共通 → プロジェクトなので、足した言語は同じ回の個人共通の配布に含まれる。入力が途中で終わった (Ctrl-D など) ときは、何も配布せずに中止する。

スクリプトから使うときは、引数付きで呼ぶ。

個人共通を `~/.claude` に入れる (マシンに 1 回)。

```bash
./init.sh user
```

新しいプロジェクトに雛形を入れる。

```bash
./init.sh project ~/develop/private/my-app --name my-app
```

既存のファイルは上書きしない。内容が違うものは `skip` と表示される。`--force` で上書きする (元のファイルは `.bak.<時刻>` に残る)。
`user` は、`~/.claude/settings.json` が既にあって内容が違うと skip する。そのままではガードのフックが登録されず、ガードは働かない (`doctor.sh` が NG にする)。既存の設定を保ったまま、フックの登録と deny / ask だけを足すには、次を流す。

```bash
./init.sh user --merge-settings
```

足すのは `hooks` (同じイベントに同じスクリプト名が登録済みなら足さない) と `permissions` の `deny` / `ask` だけで、他のキーは変えない。元は `settings.json.bak.<時刻>` に残る。2 回流しても同じ結果になる。`jq` が要る。対話式の `./init.sh` は、既存の `settings.json` があると統合するかを聞く。

## 2. `CLAUDE.md` を埋める

Claude Code が毎回最初に読む、プロジェクトの説明書。雛形の空欄を埋める。コードを読めば分かることは書かず、読んでも分からないことだけを書く。毎回読み込まれるので、長くしない。

| 場所 | 書くこと | 例 |
|---|---|---|
| 冒頭 | 何を作るプロジェクトか (1〜3 行) | 家計簿アプリ。Web と API |
| コマンドの表 | セットアップ・ビルド・テスト・lint・PR 前のテストの実際のコマンド。動くことを確かめてから書く | `npm ci` / `npm run build` / `npm test` / `npm run lint` / `npm run test:e2e` |
| 構成 | ディレクトリの役割と、読み始める場所 | `src/api/` が通信、`src/ui/` が画面。最初に `src/main.ts` |
| 画面の確認 | スクリーンショットの置き場所と、PR 本文からの参照の仕方。画面が無いプロジェクトは節ごと消す | `docs/screens/` に置き、`![](docs/screens/foo.png)` で参照 |
| 約束事 | コードから読み取れない決まり | ブランチ名は `feat/xxx`、日付は UTC で保存、PR は日本語 |

コマンドの表は、人間と Claude が参照する一覧。自動で実行されるのは `.claude/verify.sh` だけなので、表の lint とテストのうち速いものは `verify.sh` にも書く。

## 3. `.claude/verify.sh` を設定する

検証ループ (Stop フック) が、応答の終わりに呼ぶスクリプト。雛形の例から使うものを 1 つ有効にして、他は消す。最後の `exit 78` の行も消す。先頭にある観点のリスト (`.claude/review/checklist.md` と `~/.claude` の共通・言語の観点) の大きさの検査は残す。数十秒以内に終わる検査 (lint、型検査、速いテスト) だけを入れる。フックの時間切れは 600 秒で、超えると検証されないまま応答が終わる。重いテストは `CLAUDE.md` のコマンドの表の「PR 前のテスト」に書く。`/review-loop` が push / PR の前に回す。

雛形のまま (`exit 78` が残っている間) は、何も検証されない。そのことは、セッションごとに 1 回、画面に表示される。

検証ループは Claude に直させるための仕組みで、強制ではない。状態は `$TMPDIR/claude-verify/` に置いている。

## 4. `.claude/review/checklist.md` を直す

プロジェクト固有のレビュー観点を置くファイル。最初は領域の索引 (データ保存、画面など) を、プロジェクトに合わせて直すだけでよい。項目は、レビューで観点に無い指摘が出たときに `/retro` で足していく。

## 5. pre-push を有効にする

```bash
git config core.hooksPath .githooks
```

push の前に、push するコミットの範囲 (新しいブランチは、まだどのリモートにも無いコミット) だけを `gitleaks git --redact` で検査する。検出、gitleaks のエラー、範囲を解決できない (fetch していない) ときは push を止める。gitleaks が無い環境でも止まる (`brew install gitleaks`)。誤検知は `.gitleaksignore` に fingerprint を足して除く。

## 6. 動作を確かめる

```bash
bash scripts/doctor.sh ~/develop/private/my-app
```

前提のコマンド、`~/.claude` の配布物と settings の登録、ガードの実際の動き (普通のコマンドは通り、main への force push、`.env` の読み出し、`terraform destroy`、設定の経路の外の `gh api` の変更系、MCP の削除系を止めるか)、プロジェクトの雛形を調べる。何も書き換えない。NG があると 1 で終わり、直し方を表示する。warn は動きを止めないが、`verify.sh` が雛形のままのとき (検証が何も走らない)、`core.hooksPath` が未設定のとき (pre-push が働かない) などを知らせる。プロジェクトを渡さなければ、個人共通までを調べる。

Claude Code から確かめるなら、「`.env` を読んで」「main に force push して」は拒否され、「`git push`」は確認の画面が出る。

## 自分向けに変える

| 場所 | 変えてよいか |
|---|---|
| `~/.claude/CLAUDE.md` (元は `user/CLAUDE.md`) | 変える前提。PR とコミットの言語、承認が要る操作の範囲を自分の運用に合わせる |
| `~/.claude/settings.json` | deny / ask に足すのは自由。`hooks` の登録は消さない (消すとガードが働かない。`doctor.sh` が NG にする) |
| `~/.claude/hooks/guard-*.sh` | 足す・緩めるときは `test-guard.sh` にケースを足して通す。緩めた結果、`doctor.sh` のガードの確認が NG になる場合は、その確認の期待を見直す |
| 観点のリスト (`skills/adversarial-review/checklists/`) | 足してよい (`/retro`)。1 ファイル 14,500 バイトまで |
| プロジェクトの `CLAUDE.md`・`verify.sh`・`review/checklist.md` | 埋めて使うもの。比べる対象にしない |
| プロジェクトの `hooks`・`commands`・`pre-push` | 変えなくてよい。変えるとベースの更新を取り込みにくくなる |

個人名やプロジェクト名を入れた変更は、このベースには戻さない (公開リポジトリ)。

## ベースを更新したとき

ベースのリポジトリを `git pull` した後に行う。

1. **個人共通**: `bash scripts/doctor.sh` が、ベースの `user/` と違うファイルを warn で一覧にする。差分を見て取り込む。

   ```bash
   diff -ru ~/.claude/hooks user/hooks
   ```

   自分で変えていないなら、`./init.sh user --force` で上書きする (元のファイルは `.bak.<時刻>` に残る)。`--force` は、内容が違うファイルすべて (`CLAUDE.md` と `settings.json` を含む) を上書きするので、自分で編集したものがあるときは、差分を見て手で取り込む。
2. **プロジェクト**: `bash scripts/doctor.sh <project-dir>` の「雛形と違う」が、`hooks`・`commands`・`pre-push` の更新を知らせる。次のように見て取り込む。

   ```bash
   diff -u project/.claude/hooks/verify-on-stop.sh <project-dir>/.claude/hooks/verify-on-stop.sh
   ```
3. 最後に `doctor.sh` をもう一度流し、`ok` になったことを確かめる。
