#!/bin/bash
# ベース自体の回帰テスト: init.sh の配布、検証ループ (verify-on-stop.sh)、pre-push の挙動を確かめる。
# 変更したら必ず実行する。本物の ~/.claude とベースの user/ には書き込まない (一時ディレクトリとベースのコピーで動かす)。
set -uo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# 利用者の git 全体の設定に左右されないよう、作者を環境変数で与え、コミットの署名を切る
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ng() { echo "FAIL: $1"; fail=1; }
expect() { # expect <説明> <条件が成り立つ時 0 を返すコマンド...>
  local desc="$1"; shift
  "$@" >/dev/null 2>&1 || ng "$desc"
}

# --- init.sh project ---
proj="$tmp/My Proj"
"$BASE/init.sh" project "$proj" >/dev/null 2>&1 || ng "init.sh project が失敗"
expect "CLAUDE.md が作られる" test -f "$proj/CLAUDE.md"
expect "プロジェクト名が埋まる" grep -q '^# My Proj$' "$proj/CLAUDE.md"
expect "プレースホルダが残らない" bash -c "! grep -q '{{PROJECT_NAME}}' '$proj/CLAUDE.md'"
expect "verify.sh が実行可能" test -x "$proj/.claude/verify.sh"
expect "verify-on-stop.sh が実行可能" test -x "$proj/.claude/hooks/verify-on-stop.sh"
expect "pre-push が実行可能" test -x "$proj/.githooks/pre-push"
expect "settings.json が JSON" jq -e . "$proj/.claude/settings.json"
expect "/address-comments が配られる" test -f "$proj/.claude/commands/address-comments.md"

# 雛形の verify.sh: 観点のリストが上限以内なら「未設定」(78)、上限を超えたら失敗で止める。
# プロジェクトの観点と ~/.claude の観点 (一時の CLAUDE_HOME) の両方を見て、超えたものを全部表示する
vhome="$tmp/verify-home"
vcl="$vhome/skills/adversarial-review/checklists"
mkdir -p "$vcl/languages"
echo ok >"$vcl/common.md"
verify_tpl() { CLAUDE_HOME="$vhome" bash "$proj/.claude/verify.sh"; }
verify_tpl >/dev/null 2>&1; [ $? = 78 ] || ng "雛形の verify.sh が 78 で終わらない"
cp "$proj/.claude/review/checklist.md" "$tmp/checklist.bak"
head -c 14500 /dev/zero | tr '\0' a >"$proj/.claude/review/checklist.md"
verify_tpl >/dev/null 2>&1; [ $? = 78 ] || ng "観点のリストがちょうど上限なのに止めた"
echo a >>"$proj/.claude/review/checklist.md"
head -c 14501 /dev/zero | tr '\0' a >"$vcl/languages/zz.md"
err="$(verify_tpl 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 1 ] || ng "観点のリストが上限を超えても止めない (rc=$rc)"
grep -q 'checklist.md が .*上限の 14500 バイトを超えています' <<<"$err" || ng "プロジェクトの観点が上限を超えた理由を表示しない"
grep -q 'zz.md が .*上限の 14500 バイトを超えています' <<<"$err" || ng "~/.claude の観点が上限を超えたことを表示しない"
cp "$tmp/checklist.bak" "$proj/.claude/review/checklist.md"
rm -f "$vcl/languages/zz.md"

# 編集していなければ、2 回目は何も skip しない
out="$("$BASE/init.sh" project "$proj" 2>&1)"
grep -q 'skip' <<<"$out" && ng "編集していないのに skip と表示された: $(grep skip <<<"$out")"

# 編集したファイルは skip される
echo "# edited" >>"$proj/CLAUDE.md"
out="$("$BASE/init.sh" project "$proj" 2>&1)"
expect "編集済み CLAUDE.md が上書きされない" grep -q '^# edited$' "$proj/CLAUDE.md"
grep -q 'skip (内容が違う): .*CLAUDE.md' <<<"$out" || ng "編集した CLAUDE.md が skip と表示されない"

# --force で上書きしても、プロジェクト名は埋まったまま
"$BASE/init.sh" project "$proj" --force >/dev/null 2>&1
expect "--force で上書きされる" bash -c "! grep -q '^# edited$' '$proj/CLAUDE.md'"
expect "--force の後もプロジェクト名が残る" grep -q '^# My Proj$' "$proj/CLAUDE.md"
expect "--force の後にプレースホルダが残らない" bash -c "! grep -q '{{PROJECT_NAME}}' '$proj/CLAUDE.md'"
expect "--force で退避ファイルが残る" bash -c "ls '$proj'/CLAUDE.md.bak.* >/dev/null"

# 値の無いオプションは usage で止まる
"$BASE/init.sh" project "$tmp/x" --name >/dev/null 2>&1; [ $? = 2 ] || ng "--name に値が無いのに usage で止まらない"

# --- init.sh user ---
home="$tmp/claude-home"
CLAUDE_HOME="$home" "$BASE/init.sh" user >/dev/null 2>&1 || ng "init.sh user が失敗"
expect "guard-bash.sh が配布される" test -f "$home/hooks/guard-bash.sh"
expect "skills が配布される" test -f "$home/skills/adversarial-review/SKILL.md"
expect "配布した test-guard.sh が通る" bash "$home/hooks/test-guard.sh"

# --- scripts/doctor.sh ---
doctor_case() { # doctor_case <説明> <期待する終了コード> <出力に含まれる語> <CLAUDE_HOME> [引数...]。終了コードだけでなく理由まで確かめる
  local desc="$1" want="$2" pat="$3" ch="$4" out rc; shift 4
  out="$(CLAUDE_HOME="$ch" bash "$BASE/scripts/doctor.sh" "$@" 2>&1)"; rc=$?
  { [ "$rc" = "$want" ] && grep -qF -- "$pat" <<<"$out"; } || ng "$desc (終了コード $rc)"
}
dh() { rm -rf "$tmp/dh"; cp -R "$home" "$tmp/dh"; } # 配布直後の個人共通を壊す前の状態に戻す
doctor_case "doctor: 配布直後の個人共通とプロジェクトが通る" 0 "問題ありません" "$home" "$proj"
doctor_case "doctor: 雛形のままの verify.sh は warn で止めない" 0 "warn  .claude/verify.sh が雛形のまま" "$home" "$proj"
dh; rm "$tmp/dh/hooks/guard-bash.sh"
doctor_case "doctor: ガードのファイルが無ければ NG" 1 "NG    hooks/guard-bash.sh が無い" "$tmp/dh"
dh; printf '#!/bin/bash\nexit 0\n' >"$tmp/dh/hooks/guard-bash.sh"
doctor_case "doctor: 何も止めないガードは NG" 1 "NG    ガード: main への force push を止める" "$tmp/dh"
dh; printf '#!/bin/bash\nexit 2\n' >"$tmp/dh/hooks/guard-bash.sh"
doctor_case "doctor: 何でも止めるガードは NG" 1 "NG    ガード: 普通のコマンドは通す (ls)" "$tmp/dh"
dh; echo '{"//":"guard-bash.sh guard-mcp.sh remind-adversarial-review.sh","deny":[]' >"$tmp/dh/settings.json"
doctor_case "doctor: 壊れた settings.json は NG (語があるだけでは ok にしない)" 1 "NG    settings.json が JSON として読めない" "$tmp/dh"
dh; echo '{"permissions":{"deny":["Read(x)"],"ask":["Bash(git push)"]}}' >"$tmp/dh/settings.json"
doctor_case "doctor: フックの登録が無い settings.json は NG" 1 "NG    settings.json が PreToolUse に guard-bash.sh を登録していない" "$tmp/dh"
dh; echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"guard-bash.sh guard-mcp.sh"}]}],"UserPromptSubmit":[{"hooks":[{"command":"remind-adversarial-review.sh"}]}]},"permissions":{"deny":[],"ask":["Bash(git push)"]}}' >"$tmp/dh/settings.json"
doctor_case "doctor: deny が空の settings.json は NG" 1 "NG    settings.json の deny が空" "$tmp/dh"
doctor_case "doctor: プロジェクトが無ければ NG" 1 "NG    ディレクトリが無い" "$home" "$tmp/no-such-dir"
doctor_case "doctor: プロジェクトが空文字なら使い方で止まる" 2 "project-dir が空です" "$home" ""
doctor_case "doctor: 引数が多ければ使い方で止まる" 2 "使い方" "$home" a b
cp -R "$proj" "$tmp/proj-bad"; chmod -x "$tmp/proj-bad/.claude/hooks/verify-on-stop.sh"
doctor_case "doctor: 検証ループのフックが実行できなければ NG" 1 "NG    .claude/hooks/verify-on-stop.sh が無い、または実行できない" "$home" "$tmp/proj-bad"
cp -R "$proj" "$tmp/proj-ph"; echo '{{PROJECT_NAME}}' >>"$tmp/proj-ph/CLAUDE.md"
doctor_case "doctor: {{PROJECT_NAME}} が残っていれば NG" 1 "NG    CLAUDE.md に {{PROJECT_NAME}} が残っている" "$home" "$tmp/proj-ph"
cp -R "$proj" "$tmp/proj-gha"; echo 'use ${{ secrets.X }}' >>"$tmp/proj-gha/CLAUDE.md"
doctor_case "doctor: GitHub Actions の式 {{ }} は誤検出しない" 0 "問題ありません" "$home" "$tmp/proj-gha"
# CLAUDE_HOME が相対パスでも、ガードの確認が動く
(cd "$tmp" && CLAUDE_HOME=claude-home bash "$BASE/scripts/doctor.sh" >/dev/null 2>&1) || ng "doctor: CLAUDE_HOME が相対パスだと失敗する"

# --- init.sh lang (ベースのコピーで試す) ---
cp -R "$BASE" "$tmp/base-copy"
lc="$tmp/base-copy"
lf="$lc/user/skills/adversarial-review/checklists/languages/rust.md"
"$lc/init.sh" lang rust --ext .rs --prefix RS >/dev/null 2>&1 || ng "init.sh lang が失敗"
expect "言語のファイルが作られる" test -f "$lf"
expect "言語名が埋まる" grep -q '^# rust の観点$' "$lf"
expect "拡張子が埋まる" grep -q '拡張子 `.rs`' "$lf"
expect "接頭辞が埋まる" grep -q '^### RS-01 ' "$lf"
expect "プレースホルダが残らない" bash -c "! grep -q '{{' '$lf'"
"$lc/init.sh" lang rust >/dev/null 2>&1 && ng "既存の言語を上書きしようとした"
"$lc/init.sh" lang 'Bad/Name' >/dev/null 2>&1 && ng "不正な言語名を受け付けた"
"$lc/init.sh" lang zig --ext 'a|b' >/dev/null 2>&1 && ng "不正な拡張子を受け付けた"
"$lc/init.sh" lang zig --ext >/dev/null 2>&1; [ $? = 2 ] || ng "--ext に値が無いのに usage で止まらない"
"$lc/init.sh" lang kotlin >/dev/null 2>&1
# ルートの verify.sh: 共通・言語の観点が上限を超えたら、テストより前に止める (check-sync は CLAUDE_HOME を空の場所にして飛ばす)
head -c 14501 /dev/zero | tr '\0' a >"$lf"
err="$(CLAUDE_HOME="$tmp/no-such-home" bash "$lc/.claude/verify.sh" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 1 ] || ng "ルートの verify.sh が、上限を超えた言語の観点で止めない (rc=$rc)"
grep -q 'rust.md が .*上限の 14500 バイトを超えています' <<<"$err" || ng "ルートの verify.sh が、上限を超えた理由を表示しない"
expect "接頭辞の既定値 (KOT)" grep -q '^### KOT-01 ' "$lc/user/skills/adversarial-review/checklists/languages/kotlin.md"

# --- 対話式 (ベースのコピーと一時の CLAUDE_HOME で試す) ---
ic="$tmp/base-interactive"
cp -R "$BASE" "$ic"
ihome="$tmp/interactive-home"
iproj="$tmp/interactive-proj"
# zig を足す → zig をもう一度 (別の接頭辞) → 重複で却下 → Bad は却下 → 終わり / 個人共通 y / プロジェクト y / 上書き n / 実行 y
printf '%s\n' y zig '' '' y zig .zz ZZ y Bad '' '' n y y "$iproj" myapp n y \
  | CLAUDE_HOME="$ihome" "$ic/init.sh" >"$tmp/interactive.out" 2>&1 || ng "対話式が失敗"
izig="$ic/user/skills/adversarial-review/checklists/languages/zig.md"
expect "対話式: 言語のファイルが作られる" test -f "$izig"
expect "対話式: 最初に入れた接頭辞 (ZIG) が残る" grep -q '^### ZIG-01 ' "$izig"
expect "対話式: 同じ言語の 2 回目は却下される" grep -q 'この回で既に足しています: zig' "$tmp/interactive.out"
expect "対話式: 不正な言語名は作られない" bash -c "! test -e '$ic/user/skills/adversarial-review/checklists/languages/Bad.md'"
expect "対話式: 新しい言語が個人共通に入る" test -f "$ihome/skills/adversarial-review/checklists/languages/zig.md"
expect "対話式: プロジェクトの雛形が入る" test -f "$iproj/.claude/verify.sh"
expect "対話式: プロジェクト名が入る" grep -q '^# myapp$' "$iproj/CLAUDE.md"
# 入力が途中で終わったら何も配布しない
ehome="$tmp/eof-home"
printf '' | CLAUDE_HOME="$ehome" "$ic/init.sh" >/dev/null 2>&1 && ng "入力が空でも成功した"
expect "対話式: 入力が空なら何も配布しない" bash -c "! test -e '$ehome'"
# 実行前の確認で n なら何も配布しない
nhome="$tmp/no-home"
printf '%s\n' n y n n | CLAUDE_HOME="$nhome" "$ic/init.sh" >/dev/null 2>&1
expect "対話式: 実行を断ると配布しない" bash -c "! test -e '$nhome'"
# 観点のファイルが 1 つも無くても、対話式が始められる
rm -f "$ic"/user/skills/adversarial-review/checklists/languages/*.md
printf '%s\n' n n n | CLAUDE_HOME="$tmp/empty-home" "$ic/init.sh" >"$tmp/empty.out" 2>&1 || ng "観点のファイルが無いと対話式が落ちる"

# --- 検証ループ ---
repo="$tmp/repo"
mkdir -p "$repo"
"$BASE/init.sh" project "$repo" >/dev/null 2>&1
git -C "$repo" init -q
git -C "$repo" add -A && git -C "$repo" -c commit.gpgsign=false commit -qm init
hook="$repo/.claude/hooks/verify-on-stop.sh"
state="$tmp/claude-verify"

# hook <session> [mark]: 結果を RC / OUT (stdout) / ERR (stderr) に入れる。~/.claude は一時の $vhome に差し替える (本物の観点の大きさに左右されない)
hook() {
  OUT="$(printf '{"session_id":"%s"}' "$1" | CLAUDE_HOME="$vhome" CLAUDE_PROJECT_DIR="$repo" TMPDIR="$tmp" bash "$hook" ${2:-} 2>"$tmp/hook.err")"
  RC=$?
  ERR="$(cat "$tmp/hook.err")"
}
set_verify() { printf '#!/bin/bash\n%s\n' "$1" >"$repo/.claude/verify.sh"; chmod +x "$repo/.claude/verify.sh"; }
commit_all() { git -C "$repo" add -A && git -C "$repo" -c commit.gpgsign=false commit -qm "$1"; }

# 雛形のまま (未設定): 止めず、ユーザーに 1 回だけ知らせる
echo a >"$repo/a.txt"
hook u1
[ "$RC" = 0 ] || ng "未設定の verify.sh で止めた"
grep -q 'systemMessage' <<<"$OUT" || ng "未設定がユーザーに知らされない"
hook u1
[ -z "$OUT" ] || ng "未設定の通知が 2 回出た"
rm -f "$repo/a.txt"

set_verify 'exit 1'
commit_all verify

# 回の始めから変わっていなければ走らない
hook s1 mark; hook s1
[ "$RC" = 0 ] || ng "変更が無いのに検証が走った"

# 回の中でコミットした変更も検証する
hook s1 mark
echo c >"$repo/committed.txt"; commit_all committed
hook s1
[ "$RC" = 2 ] || ng "回の中でコミットした変更を検証しない"

# 回の前からある変更だけなら走らない
echo pre >"$repo/pre-existing.txt"
hook s2 mark; hook s2
[ "$RC" = 0 ] || ng "回の前からある変更だけで止めた"
# その回に変更を足したら走る
echo more >>"$repo/pre-existing.txt"
hook s2
[ "$RC" = 2 ] || ng "回の中で足した変更を検証しない"
rm -f "$repo/pre-existing.txt"

# mark の記録が無ければ、作業ツリーに変更があるときだけ走る
echo x >"$repo/change.txt"
hook s3
[ "$RC" = 2 ] || ng "mark が無いとき、変更があっても検証しない"

# 回の中では 3 回まで止め、最後の回で報告を促し、4 回目はユーザーに知らせて通す
hook s4 mark
echo y >>"$repo/change.txt"
hook s4; [ "$RC" = 2 ] || ng "失敗した検証で止まらない (1 回目)"
hook s4; [ "$RC" = 2 ] || ng "失敗した検証で止まらない (2 回目)"
hook s4; [ "$RC" = 2 ] || ng "失敗した検証で止まらない (3 回目)"
grep -q '最後の検証' <<<"$ERR" || ng "最後の回で報告を促していない"
hook s4; [ "$RC" = 0 ] || ng "4 回目で通していない (無限ループの防止)"
grep -q 'systemMessage' <<<"$OUT" || ng "上限を超えたことがユーザーに知らされない"

# 回が変わったら、失敗回数は 0 から数え直す
hook s5 mark; echo z >>"$repo/change.txt"
hook s5; hook s5
hook s5 mark; echo w >>"$repo/change.txt"
hook s5
grep -q '(1/3 回目)' <<<"$ERR" || ng "回が変わっても失敗回数が持ち越された"

# 別のセッションの回数は混ざらない
hook s6 mark; echo v >>"$repo/change.txt"
hook s6
grep -q '(1/3 回目)' <<<"$ERR" || ng "別セッションの回数が混ざっている"

# 回数の記録が壊れていても止める
echo abc >"$state/s6.count"
hook s6
[ "$RC" = 2 ] || ng "回数の記録が壊れていると素通りする"

# 実行権限が無くても走らせる
chmod -x "$repo/.claude/verify.sh"
hook s7
[ "$RC" = 2 ] || ng "実行権限の無い verify.sh を飛ばした"

# 成功したら通し、出力は失敗のときに Claude に返る
set_verify 'exit 0'
hook s7; [ "$RC" = 0 ] || ng "成功した検証で通らない"
set_verify 'echo "boom line" >&2; exit 1'
hook s8
grep -q 'boom line' <<<"$ERR" || ng "検証の出力が Claude に返らない"

# --- pre-push ---
if command -v gitleaks >/dev/null; then
  pp="$repo/.githooks/pre-push"
  head_sha="$(git -C "$repo" rev-parse HEAD)"
  zero=0000000000000000000000000000000000000000
  (cd "$repo" && printf 'refs/heads/b %s refs/heads/b %s\n' "$head_sha" "$zero" | bash "$pp" >/dev/null 2>&1) \
    || ng "pre-push: 機密値の無いコミットで止まった"
  (cd "$repo" && printf 'refs/heads/b %s refs/heads/b %s\n' "$zero" "$head_sha" | bash "$pp" >/dev/null 2>&1) \
    || ng "pre-push: ブランチの削除で止まった"
  # 解決できない範囲 (gitleaks に渡すと 0 commits で通ってしまう) は止める
  err="$(cd "$repo" && printf 'refs/heads/b %s refs/heads/b %s\n' "$head_sha" 1111111111111111111111111111111111111111 | bash "$pp" 2>&1 >/dev/null)"
  [ $? != 0 ] || ng "pre-push: 解決できない範囲を検査しないまま通した"
  grep -q '解決できません' <<<"$err" || ng "pre-push: 解決できない範囲の理由を表示しない"
else
  echo "SKIP: gitleaks が無いので pre-push のテストを飛ばした"
fi

[ "$fail" = 0 ] && echo "OK" || { echo "NG"; exit 1; }
