#!/bin/bash
# 検証ループの中身。Stop フック (.claude/hooks/verify-on-stop.sh) が、回の始めから作業ツリーが変わった状態で
# 応答を終えようとするたびに呼ぶ。失敗 (0 と 78 以外) で終えると、出力が Claude に返り、直すまで終われない。
set -euo pipefail
cd "$(dirname "$0")/.."

# ~/.claude とベースの user/ (フック・スキル) の一致。~/.claude に配布していない環境では飛ばす
if [ -f "${CLAUDE_HOME:-$HOME/.claude}/hooks/guard-bash.sh" ]; then
  bash scripts/check-sync.sh
fi

# 観点のリストの大きさ。レビューのたびに読み込まれるので、14,500 バイトを超えたら統合・削除する。
# .md だけの変更でも走らせる (観点の追加は .md の変更なので)
over=0
for f in .claude/review/checklist.md user/skills/adversarial-review/checklists/*.md user/skills/adversarial-review/checklists/languages/*.md; do
  [ -f "$f" ] || continue
  size="$(wc -c <"$f" | tr -d ' ')"
  if [ "$size" -gt 14500 ]; then
    echo "verify.sh: $f が $size バイトで、上限の 14500 バイトを超えています。項目を統合・削除してください" >&2
    over=1
  fi
done
[ "$over" = 0 ] || exit 1

# ブランチの差分と作業ツリーの変更が .md だけなら、テストは飛ばす (観点ファイルやドキュメントの編集)
changed="$( { git diff --name-only origin/main...HEAD 2>/dev/null || true; git diff --name-only HEAD 2>/dev/null || true; git ls-files -o --exclude-standard; } | sort -u)"
if [ -n "$changed" ] && ! grep -qv '\.md$' <<<"$changed"; then
  echo "verify.sh: 変更が .md だけなので、テストを飛ばしました" >&2
  exit 0
fi

# 配布 (init.sh)、検証ループ、pre-push の回帰テスト。配布した user/hooks/test-guard.sh (ガードのテスト) もこの中で走る
bash scripts/test-base.sh
