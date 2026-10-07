# Ruby の観点

拡張子 `.rb`、`.rake`、`Gemfile`、`Rakefile`、shebang が `ruby` のファイルに当てる。Rails を使う箇所は、Rails の項目 (RB-08〜) も見る。

### RB-01 nil と空の扱い
- 観点: `nil` に対するメソッド呼び出し (`NoMethodError`) の経路が無いか。`a.b.c` の途中の `nil`、`Hash#[]` の欠け、`find` / `first` / `detect` の結果、`ENV["X"]` の未設定。`&.` で `nil` を流しすぎて、本来の失敗を隠していないか。`if x` が `0` と `""` を真とみなす (他の言語と違う) ことを前提にしているか。空文字・空配列・`nil` を同じに扱ってよいか
- 確かめ方: 各変数に `nil`、`""`、`[]`、`{}` を入れて通す

### RB-02 例外の捕まえ方
- 観点: `rescue => e` / `rescue Exception` が、本来は上に伝えるべき失敗を飲んでいないか (`Exception` は `SystemExit` と `Interrupt` まで捕まえる)。`rescue` の後に何もせず `nil` を返す箇所。`ensure` の中の `return` が例外を打ち消さないか。`retry` に上限があるか。再送出で元のバックトレースが残るか (`raise` と `raise e` の違い)
- 確かめ方: `begin` の中で起こりうる例外を挙げ、`rescue` の後の戻り値と、呼び出し側が見る結果を書く

### RB-03 コマンドの実行と外から来る文字列
- 観点: `system` / `exec` / `` ` ` `` / `%x` / `Open3` / `IO.popen` に、外の値を文字列の中へ埋めていないか。引数を別々に渡す形 (`system("cmd", arg)`) にして、`-` で始まる値はオプションとして解釈されないよう `--` を挟む。`eval` / `instance_eval` / `send` / `public_send` / `constantize` / `Object.const_get` に外の値を渡していないか
- 確かめ方: `a; touch x`、`$(id)`、`-rf`、任意のクラス名やメソッド名を入れて、実行されるものを見る

### RB-04 デシリアライズとファイル
- 観点: `YAML.load` (Psych 4 未満では任意のオブジェクトを作る)、`Marshal.load`、`ERB.new(外の値)` を外から来るデータに使っていないか (`YAML.safe_load`、JSON)。`File.join` / `File.read` / `send_file` に外の値を渡したとき、`..` や絶対パスで外へ出ないか。`open("| cmd")` のように、パイプ始まりの文字列でコマンドが実行されないか (`File.open` / `URI.open` を使う)
- 確かめ方: `../../etc/passwd`、`| id` を入れて、開かれるものを見る

### RB-05 ミュータブルな値と共有状態
- 観点: 文字列リテラルを破壊的メソッド (`<<`、`gsub!`、`upcase!`) で変えて、定数や別の呼び出しへ波及しないか (`# frozen_string_literal: true` の有無)。`Array.new(3, [])` / `Hash.new([])` のように、同じオブジェクトが全要素で共有されないか (`Array.new(3) { [] }`、`Hash.new { |h, k| h[k] = [] }`)。メソッドの引数を破壊的に変えて、呼び出し側が影響を受けないか。クラス変数 `@@x` とクラスのインスタンス変数が、スレッド間・サブクラス間で共有される
- 確かめ方: 同じ関数を 2 回呼び、2 回目に 1 回目の値が見えないか

### RB-06 比較・ハッシュ・数値
- 観点: `==` / `eql?` / `equal?` の違い (`1 == 1.0` は真、`1.eql?(1.0)` は偽)。ハッシュのキーに可変のオブジェクトを使っていないか。`Float` で金額を計算していないか (`BigDecimal` か整数の最小単位)。整数の割り算 `7 / 2 == 3`。`Time.now` のタイムゾーン (`Time.zone` と `Time.now` の取り違え)。`String#to_i` は不正な文字列を黙って `0` にする (`Integer("x")` は例外)
- 確かめ方: `0`、負数、小数、巨大値、`"abc"`、`"12abc"`、年末年始と夏時間の境界で試す

### RB-07 ブロック・Enumerable・遅延
- 観点: `each` の中で、反復中の配列を変更していないか。`map` の結果を使わず副作用だけにしていないか (`each` を使う)。`select` / `map` を何重にも重ねて、大きなデータを何度も走査していないか。ブロックの中の `return` と `next` と `break` の違い (`proc` の `return` は外側のメソッドを抜ける)。`Enumerator::Lazy` の評価タイミング
- 確かめ方: 空、1 件、重複を含むデータで通す。ブロック内の `return` が意図した範囲で止まるか

### RB-08 Rails: 一括代入と権限
- 観点: strong parameters で `permit` する項目に、権限や所有者 (`admin`、`user_id`、`role`) を含めていないか。`params` を `to_unsafe_h` や `permit!` で通していないか。コントローラーで、対象のレコードを `Model.find(params[:id])` で引き、現在の利用者のものか確かめているか (`current_user.items.find`)。認可を 1 つの経路にだけ付けて、同じ操作をする別の経路 (API、一括更新、`update_all`) で抜けないか
- 確かめ方: 他人の ID と、`admin=true` を付けたリクエストを送る

### RB-09 Rails: SQL・N+1・コールバック
- 観点: `where("name = '#{x}'")` / `order(params[:sort])` / `find_by_sql` に外の値を埋めていないか (`where(name: x)`、`where("name = ?", x)`、並び替えは許可する列の一覧と照合)。一覧で関連を 1 件ずつ引く N+1 (`includes`)。`update_all` / `delete_all` / `update_column` がバリデーションとコールバックを飛ばす。`after_save` の中で外部の呼び出しをして、トランザクションが戻っても残る (`after_commit`)。`find_or_create_by` の競合 (一意制約とリトライ)
- 確かめ方: `' OR 1=1 --` を `sort` に入れる。一覧のクエリ数をログで数える。同じ作成を並行に 2 回呼ぶ

### RB-10 Rails: ビュー・リダイレクト・設定
- 観点: `html_safe` / `raw` / `<%== %>` に外の値を渡していないか。`redirect_to params[:url]` がオープンリダイレクトにならないか (`allow_other_host: false`)。`protect_from_forgery` を外した経路。ログに `params` のパスワードやトークンが出ていないか (`filter_parameters`)。`credentials` / `secrets` と `.env` を、リポジトリに入れていないか。マイグレーションが、大きなテーブルで長いロックを取らないか
- 確かめ方: `<script>` を含む値を表示させる。`//evil.example` を `url` に入れる
