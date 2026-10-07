# TypeScript / React (Vite) の観点

拡張子 `.ts` `.tsx` のファイルと、`tsconfig*.json`・`vite.config.ts`・`eslint.config.js`・`index.html` に当てる。ブラウザ API と React の癖もここに入れる。

## ブラウザ API と失敗

### TS-01 ブラウザ API の失敗を利用者に伝える
- 観点: `navigator.clipboard`、`fetch`、`localStorage`、`share` などの失敗 (非 HTTPS、権限の拒否、古い WebView、未定義) を `console.error` だけで握りつぶしていないか。ボタンを押しても何も変わらない状態になっていないか
- 確かめ方: 各 `try` / `.catch` で、失敗したときに画面がどう変わるかを追う。API が undefined の場合も TypeError が `try` の中に入るか見る

### TS-02 アンマウント後と連続操作
- 観点: `setTimeout`・`setInterval`・イベントリスナー・購読が、アンマウントや再実行のときに解除されるか。連続クリックで前のタイマーが残って、状態が早く戻らないか。`async` の完了後にアンマウント済みの状態を更新しないか
- 確かめ方: `useEffect` の cleanup を読み、クリックを素早く 2 回繰り返したときの順序を追う

### TS-03 React 19 StrictMode の二重実行
- 観点: 開発時に effect が 2 回走る。1 回目の副作用 (購読、fetch、タイマー) が 2 回目で重複しないか、cleanup が対になっているか
- 確かめ方: effect の中身を「実行 → cleanup → 再実行」の順で読む

## アクセシビリティ

### TS-04 aria-label が表示ラベルと状態変化を隠す
- 観点: `aria-label` を付けたボタンで、表示ラベルが状態によって変わる (`Copy` → `Copied!`) とき、読み上げは `aria-label` のままで変化が伝わらないか。状態の通知が必要なら `aria-live` などがあるか
- 確かめ方: 状態で変わる文言を持つ要素に `aria-label` / `aria-live` があるか探す

### TS-05 画像だけで情報を伝えていないか
- 観点: 文字として読ませたい情報 (連絡先、価格、手順) を画像にしていないか。`alt` が中身を伝えているか (`alt="email address"` ではアドレスが分からない)。画像が表示されない環境で、情報を得る別の手段があるか
- 確かめ方: `<img>` の `alt` を読み、画像の中身を文字で言えるか確かめる

### TS-06 reduced-motion が一部だけになっていないか
- 観点: CSS のアニメーションに `@media (prefers-reduced-motion: reduce)` があっても、JS の `scrollIntoView({ behavior: 'smooth' })` やアニメーションの開始が見ていないことがある
- 確かめ方: `behavior: 'smooth'`、`animation`、`transition` を探し、reduced-motion の対応が同じ画面の中でそろっているか見る

### TS-07 見出しと HTML の入れ子
- 観点: 見出しの階層 (h1 の次が h2 で、副題が h2 になっていないか)、`<summary>` の中に `<div>` (phrasing content 以外) を入れていないか、クリックできる要素に `<div>` を使っていないか
- 確かめ方: JSX の入れ子を読み、HTML の仕様で許される入れ子か見る

## React と型

### TS-08 key の安定性
- 観点: `key` に `index` や、重複しうる値 (表示名、タグ名) を使っていないか。データに同じ値を足すと警告や表示の取り違えが起きないか
- 確かめ方: `.map` の `key` を見て、データ側で一意が保証されているか確かめる

### TS-09 データの値を鍵にした分岐
- 観点: 表示名やタイトルの文字列比較 (`title === '...'`) で見た目や挙動を変えていないか。データ側の文言を直すと、比較が黙って効かなくなる。型にフラグを持たせるほうが安全
- 確かめ方: JSX 内の文字列リテラルとの `===` を探し、データ側の現在の値と一致しているか確かめる

### TS-10 型に足した項目が使われているか
- 観点: ViewModel や data の型に足したフィールド (`description`、`displayName`) が、表示側で参照されているか。変換関数でコピーしただけで、誰も読まない項目になっていないか
- 確かめ方: 足したフィールド名を grep し、画面を作る側 (`.tsx`) で参照されているか見る

## ビルドと設定

### TS-11 テストファイルとビルドの設定
- 観点: `*.test.ts(x)` が `tsc -b` の対象 (`tsconfig.app.json` の `include`) に入り、本番ビルドを巻き込んでいないか。`types` に `vitest/globals` などが必要な書き方 (import 無しの `describe`) になっていないか。`vite.config.ts` を `vitest/config` に変えたとき、`tsconfig.node.json` で解決できるか
- 確かめ方: `npm run build` と `npm test` と `npm run lint` を実際に通す

### TS-12 バンドルに入る値は公開される
- 観点: `src/` に書いた値 (メールアドレス、キー、URL) や `VITE_` で始まる環境変数は、ビルド後の JS に平文で入る。画像化や難読化は秘匿にならない
- 確かめ方: 秘匿したい値が `src/` や `VITE_*` にないか探す。あれば、公開されても困らないか判断する

### TS-13 画像・SVG の中身
- 観点: `.svg` の中身が `<image href="data:image/png;base64,...">` で、実体は PNG になっていないか。表示サイズに比べてファイルが重くないか
- 確かめ方: `ls -l` でサイズを見て、SVG の先頭を読む

### TS-14 スタイルの競合
- 観点: 要素セレクタ (`button { }`) のグローバル CSS と、部品のクラス (`.uiButton`) が同じプロパティを指定していないか。今は詳細度で勝っていても、順序や `!important` で崩れる。同じセレクタを別ファイルで 2 度書き、後のものが前のものを黙って上書きしていないか
- 確かめ方: 変えたセレクタを `grep -rn` で全 CSS から探し、同じプロパティの重複を見る

### TS-15 CI と手元のツールのバージョン
- 観点: CI の Node のバージョン (`node-version: 24` など) が、手元やデプロイ先 (Cloudflare Pages など) と同じ出所 (`.nvmrc`、`package.json` の `engines`) で決まっているか。minor の更新で CI だけ落ちる・差が出ることがないか。`.nvmrc` を足すとデプロイ先のビルドの Node も変わりうるので、足す変更はデプロイへの影響も見る
- 確かめ方: workflow、`.nvmrc`、`engines`、デプロイ先の設定の 4 か所の版を並べる

### TS-16 テストの間で DOM が残らないか
- 観点: Vitest で `globals: true` を使っていないと、Testing Library の自動 cleanup が登録されず、前のテストの描画が次のテストに残る。同じ文言や role を持つテストを足した時点で、`getBy*` が「複数見つかった」で落ちる (単独では通る)
- 確かめ方: セットアップに `afterEach(cleanup)` があるか見る。同じ部品を描画するテストを 2 件にして実行する

### TS-17 jsdom で通るが実ブラウザと違うテスト
- 観点: jsdom は閉じた `<details>` の中身を隠さない。折りたたみの中身を `getBy*` で読むテストは、`details` を外しても `summary` を消しても通る。クラス名で「無いこと」を確かめる (`querySelector('.x')` が null) テストは、クラスを改名すると空振りする。同じ props を取る複数のリンクで、片方にしか `target`・`rel` を確かめていないテストは、もう片方の属性を消しても通る
- 確かめ方: 開閉する部品は、閉じた状態の属性 (`open`) と、操作後の状態の両方を確かめているか見る。「無いこと」は文言や role、子要素の数で確かめる。似た要素は `it.each` で全部に当てる
