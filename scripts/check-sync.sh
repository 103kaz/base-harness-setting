#!/bin/bash
# ~/.claude (実際に動いている個人共通) と、このベースの user/ のフック・スキルが一致しているかを確かめる。
# 観点やガードは ~/.claude で育て、同じ回で user/ にも同じ変更を入れる。その後にこれを通す。
# CLAUDE.md と settings.json は ~/.claude 側に個人固有の記述があるので比べない (汎用の部分を手で反映する)。
#
#   bash scripts/check-sync.sh     一致しなければ、違うファイルを表示して 1 で終わる
set -uo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
home="${CLAUDE_HOME:-$HOME/.claude}"
status=0

while IFS= read -r f; do
  if [ ! -e "$home/$f" ]; then
    echo "~/.claude に無い: $f"
    status=1
  elif ! cmp -s "$BASE/user/$f" "$home/$f"; then
    echo "内容が違う: $f"
    status=1
  fi
done < <(cd "$BASE/user" && find hooks skills -type f ! -name '.DS_Store' | sort)

# ~/.claude にだけある観点ファイル (ベースに戻し忘れ)
while IFS= read -r f; do
  [ -e "$BASE/user/$f" ] || { echo "ベースに無い: $f"; status=1; }
done < <(cd "$home" && find skills/adversarial-review hooks -type f ! -name '.DS_Store' 2>/dev/null | sort)

[ "$status" = 0 ] && echo "一致しています"
exit "$status"
