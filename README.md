# base-harness-setting

新しいプロジェクトの開始時に配る、Claude Code のハーネスとループの共通構成。

## 構成

```
user/       個人共通 (~/.claude に入れるもの)
  CLAUDE.md                個人共通ルール
  settings.json            機密ファイルの deny、push・マージ・apply の ask、フックの登録
  hooks/                   guard-bash.sh・guard-mcp.sh (+ test-guard.sh)、remind-adversarial-review.sh、fmt-terraform.sh
  skills/                  adversarial-review (共通・言語別の観点つき)、doc-code-consistency
                           言語別の観点: swift、python、typescript、shell、php、go、ruby (adversarial-review/checklists/languages/)
project/    プロジェクトの雛形 (新規プロジェクトのルートに入れるもの)
  CLAUDE.md                コマンド・構成・ループの運用の雛形
  .claude/settings.json    検証ループのフック (UserPromptSubmit と Stop) の登録
  .claude/verify.sh        検証コマンドを書く場所 (観点のリストの大きさの検査つき)
  .claude/hooks/           verify-on-stop.sh
  .claude/commands/        /review-loop、/retro、/address-comments
  .claude/review/checklist.md   プロジェクト固有の観点
  .githooks/pre-push       push するコミットの範囲を gitleaks git --redact で検査
templates/                  言語別の観点の雛形 (`./init.sh lang` が使う)
scripts/test-base.sh        init.sh・検証ループ・pre-push の回帰テスト
scripts/check-sync.sh       ~/.claude とこのベースの user/ (フック・スキル) が一致しているかの確認
```

ルートの `CLAUDE.md`・`.claude/`・`.githooks/` は、このリポジトリ自身の開発に使う設定 (雛形を自分自身に入れたもの)。配布物ではない。

## セットアップ

配布の方法 (`./init.sh`) と、雛形を入れた後に新しいプロジェクトで最初にやることは [SETUP.md](SETUP.md) にある。

## ループ

| ループ | 仕組み | 動き |
|---|---|---|
| 開発 | `/review-loop` | 検証 → code-review (medium) → 修正を、指摘が出なくなるまで。続けて CLAUDE.md の「PR 前のテスト」(検証ループに入れない重いテスト) を回す。push / PR の前に敵対的レビューを回すかをユーザーに聞く |
| 検証 | UserPromptSubmit と Stop のフック + `.claude/verify.sh` | 回の始めの作業ツリーを記録し、そこから変わった状態 (回の中のコミットを含む) で応答を終えようとすると verify.sh を走らせる。失敗なら出力を返して直させる。1 回の中で止めるのは 3 回まで (`VERIFY_MAX_RETRY` で変更)。3 回目は「直せなければユーザーに報告して終える」よう Claude に伝え、それでも失敗したまま終わったときは画面に警告を出す |
| 振り返り | `/retro` | 観点に無い指摘とレビュー後のバグを、共通 / 言語 / プロジェクトの観点リストへ一般化して足す。不具合の修正では、`/review-loop` が「以前のレビューを通ったコードのバグか」を確かめて `/retro` に回す。観点のリストが14,500 バイトを超えると、`verify.sh` が失敗する (`~/.claude` の観点は、どのプロジェクトでも) |
| レビューコメント対応 | `/address-comments` | PR のレビューコメントを集め、直す → `/review-loop` → 返信の下書き。push と返信の投稿は、ユーザーの OK を取ってから行う。行のコメントへの返信は、ガードが `gh api` の変更系を止めるので、コマンドを示してユーザーが実行する |

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
- `~/.claude` の側で作ったファイルをベースに戻したいときは、`user/skills/adversarial-review/checklists/languages/` にコピーして、README の構成の一覧に言語名を足す。

## このベース自体を変えるとき

`scripts/test-base.sh` を通す。ガード (`user/hooks/guard-bash.sh`) を変えたら `user/hooks/test-guard.sh` にケースを足して通す。
観点とガードは `~/.claude` で育てる (`/retro` もそこに足す)。変えたら同じ回で `user/` にも同じ変更を入れ、`bash scripts/check-sync.sh` で一致を確かめる。CLAUDE.md と settings.json は `~/.claude` 側に個人固有の記述があるので比較の対象外で、汎用の部分だけを手で反映する。`./init.sh user` は既存のファイルを上書きしないので、`user/` から `~/.claude` へ戻すときは、差分を見て Edit で入れるか `--force` を使う。

## 同梱していないもの

- プロジェクト固有の `autoMode` 設定
- 自走ループ (タスクリスト駆動)。必要になったら足す

## ライセンス

MIT ([LICENSE](LICENSE))
