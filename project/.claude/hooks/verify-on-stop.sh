#!/bin/bash
# 検証ループ。2 つのフックから呼ぶ。
#   verify-on-stop.sh mark   UserPromptSubmit: 回の始めの作業ツリーの状態を記録し、失敗回数を 0 に戻す
#   verify-on-stop.sh        Stop: 回の始めから変わっていれば .claude/verify.sh (lint・テスト・ビルド) を走らせる。
#                            失敗したら exit 2 + stderr で止め、出力を Claude に返して直させる
#
# - 「変わったか」は、HEAD・追跡中のファイルの差分・追跡外のファイルをまとめた指紋で比べる。回の中でコミットした変更も対象になり、
#   回の前からある (Claude が触っていない) 変更だけでは走らない。mark の記録が無いときは、作業ツリーに変更があれば走らせる
# - 1 回の中で止めるのは MAX_RETRY 回まで。最後の 1 回では、直せなければユーザーに報告して終わるよう Claude に伝える。
#   それでも失敗したまま終わるときは、ユーザーに systemMessage で知らせて通す
# - verify.sh が 78 で終わったら「未設定」とみなし、セッションで 1 回だけユーザーに知らせる
# - 自己申告の仕組みで、強制ではない (状態は $TMPDIR に置き、VERIFY_MAX_RETRY も変えられる)
# - 変更したら scripts/test-base.sh にケースを追加して通すこと
set -uo pipefail

MAX_RETRY="${VERIFY_MAX_RETRY:-3}"
UNCONFIGURED=78
mode="${1:-stop}"

input="$(cat)"
session="$(jq -r '.session_id // "nosession"' <<<"$input" 2>/dev/null || echo nosession)"
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$root" || exit 0

state_dir="${TMPDIR:-/tmp}/claude-verify"
mkdir -p "$state_dir"
key="$(printf '%s' "$session" | tr -c 'A-Za-z0-9_-' '_')"
count_file="$state_dir/$key.count"
mark_file="$state_dir/$key.mark"
notice_file="$state_dir/$key.unconfigured"

in_git() { git rev-parse --git-dir >/dev/null 2>&1; }

# 作業ツリーの指紋: HEAD、追跡中のファイルの差分、追跡外のファイル (名前と中身)
fingerprint() {
  {
    git rev-parse -q --verify HEAD 2>/dev/null
    git diff HEAD --binary 2>/dev/null || git diff --binary 2>/dev/null
    git ls-files -o --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' f; do
      printf '%s ' "$f"
      git hash-object -- "$f" 2>/dev/null
    done
  } | git hash-object --stdin
}

# ユーザーに見える通知 (Claude には渡らない)
system_message() {
  if command -v jq >/dev/null; then
    jq -n --arg m "$1" '{systemMessage: $m}'
  else
    echo "$1" >&2
  fi
}

if [ "$mode" = mark ]; then
  rm -f "$count_file"
  if in_git; then fingerprint >"$mark_file"; else rm -f "$mark_file"; fi
  exit 0
fi

verify="$root/.claude/verify.sh"
[ -f "$verify" ] || exit 0

# 回の始めから変わっていなければ検証しない
if in_git; then
  if [ -f "$mark_file" ]; then
    [ "$(fingerprint)" != "$(cat "$mark_file")" ] || exit 0
  else
    [ -n "$(git status --porcelain 2>/dev/null)" ] || exit 0
  fi
fi

# 実行権限が落ちていても走らせる
out="$(bash "$verify" 2>&1)"
rc=$?

if [ "$rc" = 0 ]; then
  rm -f "$count_file"
  exit 0
fi

if [ "$rc" = "$UNCONFIGURED" ]; then
  if [ ! -e "$notice_file" ]; then
    : >"$notice_file"
    system_message "verify-on-stop: .claude/verify.sh の検証コマンドが未設定のため、検証ループは何も確かめていません。"
  fi
  exit 0
fi

count="$(cat "$count_file" 2>/dev/null || true)"
case "$count" in
  ''|*[!0-9]*) count=0 ;;
esac
count=$((count + 1))

if [ "$count" -gt "$MAX_RETRY" ]; then
  rm -f "$count_file"
  system_message "verify-on-stop: .claude/verify.sh が ${MAX_RETRY} 回続けて失敗したまま、応答を終えました。"
  exit 0
fi
echo "$count" >"$count_file"

{
  echo "verify-on-stop: .claude/verify.sh が失敗しました (${count}/${MAX_RETRY} 回目)。原因を直してから終わってください。"
  if [ "$count" = "$MAX_RETRY" ]; then
    echo "これが最後の検証です。直せないときは、失敗している検査と残っている問題をユーザーに報告してから終わってください。"
  fi
  echo "--- 出力 (末尾 80 行) ---"
  tail -n 80 <<<"$out"
} >&2
exit 2
