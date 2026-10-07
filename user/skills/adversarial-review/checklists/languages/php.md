# PHP の観点

拡張子 `.php`、`.phtml` のファイルに当てる。Web アプリ (フレームワークあり・なし) と、運用スクリプトを想定している。バージョン依存の挙動は、プロジェクトの `composer.json` の `php` の要求を見て判断する。

### PHP-01 緩い比較と型の自動変換
- 観点: `==` / `!=` / `in_array` / `array_search` / `switch` が、型を変換して比較していないか。`"0e123" == "0e456"` や `"abc" == 0` (PHP 8 未満)、`null == false == 0 == ""` で、認証、権限、トークンの比較が通らないか。`strpos` などが `0` と `false` を返し分けるのに、`if (strpos(...))` で判定していないか。`===`、`in_array(..., true)`、`!== false` を使っているか
- 確かめ方: 比較の両辺に `0`、`"0"`、`""`、`null`、`"0e1"`、`[]` を入れて結果を見る

### PHP-02 SQL の組み立て
- 観点: SQL を文字列の連結や変数の埋め込みで作っていないか。PDO / mysqli のプレースホルダで値を渡し、エミュレーションを切っているか (`ATTR_EMULATE_PREPARES`)。`ORDER BY` や列名、テーブル名、`LIMIT` は値にできないので、許可する名前の一覧と照合しているか。`LIKE` の `%` と `_` をエスケープしているか
- 確かめ方: 値に `' OR '1'='1`、`\`、`%` を入れて、実際に発行される SQL を見る

### PHP-03 出力のエスケープ (XSS)
- 観点: 外から来る値を HTML に出す箇所が、`htmlspecialchars($s, ENT_QUOTES, 'UTF-8')` を通っているか。出力する場所 (HTML の本文、属性、`<script>` の中、URL、CSS) ごとにエスケープの方法が違うことを守っているか。テンプレートエンジンの「エスケープしない」指定 (`{!! !!}`、`|raw`) を使う箇所の値は、信頼できるか
- 確かめ方: `"><script>x</script>`、`' onmouseover='x`、`javascript:x` を入れて、出力された HTML を見る

### PHP-04 ファイルの取り込みとパス
- 観点: `include` / `require` / `file_get_contents` / `fopen` / `readfile` / `unlink` に、外から来る値を渡していないか。`..`、絶対パス、NUL、`php://`・`data://`・`http://` などのラッパーで、意図しないファイルや URL を読まないか。`realpath` の結果が許可するディレクトリの下にあることを確かめているか
- 確かめ方: `../../etc/passwd`、`php://filter/...`、`http://example.com/x` を入れて、開かれるパスを見る

### PHP-05 デシリアライズとコードの実行
- 観点: `unserialize`、`eval`、`assert` (文字列)、`create_function`、`preg_replace` の `e` 修飾子、`extract($_GET)`、`$$var` に外の値を流していないか。`unserialize` は `allowed_classes` を絞るか JSON に替える
- 確かめ方: 読み込むデータの出どころを遡る。外から来るものがあれば、安全な形式に替えられるかを見る

### PHP-06 パスワードと乱数
- 観点: パスワードを `md5` / `sha1` / `hash` で保存していないか。`password_hash` と `password_verify` を使い、`password_needs_rehash` で更新しているか。トークンやセッション ID に `rand` / `mt_rand` / `uniqid` を使っていないか (`random_bytes` / `random_int`)。秘密の値の比較に `==` を使っていないか (`hash_equals`)
- 確かめ方: 保存、比較、トークン生成の関数を挙げて、上の関数と照合する

### PHP-07 セッション・CSRF・ヘッダ
- 観点: ログイン時に `session_regenerate_id(true)` しているか。Cookie に `HttpOnly`・`Secure`・`SameSite` が付いているか。状態を変える操作 (POST など) に CSRF トークンがあるか。`header("Location: " . $url)` の `$url` が外から来る値のとき、オープンリダイレクトや改行によるヘッダの注入が起きないか
- 確かめ方: ログインの前後でセッション ID が変わるか。他のサイトからの POST が通らないか。`$url` に `//evil.example` と `%0d%0a` を入れる

### PHP-08 ファイルのアップロード
- 観点: 拡張子、MIME (`$_FILES['x']['type']` は利用者の自己申告)、中身の検査 (`finfo`) を組み合わせているか。保存先が公開ディレクトリの中で、`.php` として実行されないか。保存名を利用者の指定にしていないか。サイズの上限 (`upload_max_filesize`、`post_max_size`) と、`$_FILES['x']['error']` を検査しているか
- 確かめ方: `a.php`、`a.php.jpg`、中身が PHP で拡張子が `.png` のファイルを上げて、保存先と実行されるかを見る

### PHP-09 エラー処理と null
- 観点: 本番で `display_errors` が On のままになって、パスや SQL が画面に出ないか。`@` による抑制が、失敗を隠していないか。関数が `false` / `null` を返す失敗 (`file_get_contents`、`json_decode`、`preg_match`) を検査せずに次へ流していないか (`json_decode` は `JSON_THROW_ON_ERROR`)。`declare(strict_types=1)` の有無で、型の違う値が黙って変換されないか。PHP 8 の `null` を非対応の組み込み関数に渡す非推奨の警告
- 確かめ方: 存在しないファイル、壊れた JSON、`null` を入れて、画面とログに何が出るかを見る

### PHP-10 時刻・数値・文字コード
- 観点: `date_default_timezone_set` またはサーバー設定への依存で、時刻帯がずれないか (`DateTimeImmutable` と時刻帯の明示)。金額を `float` で計算していないか (整数の最小単位か `bcmath`)。`strlen` / `substr` / `strtoupper` が、マルチバイトの文字を壊さないか (`mb_*`)。`intval` と整数の桁あふれ (32 ビット環境) で、大きな ID が丸められないか
- 確かめ方: 日本語・絵文字を含む文字列、`0.1 + 0.2`、`PHP_INT_MAX` 付近の値、月末・年末の日付で試す
