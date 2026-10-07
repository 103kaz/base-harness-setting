#!/bin/bash
# 検証ループの中身。Stop フック (.claude/hooks/verify-on-stop.sh) が、回の始めから作業ツリーが変わった状態で
# 応答を終えようとするたびに呼ぶ。失敗 (0 と 78 以外) で終えると、出力が Claude に返り、直すまで終われない。
# 速く終わるものだけを入れる (フックの時間切れは 600 秒。目安は数十秒以内)。重いテストは CLAUDE.md の「PR 前のテスト」に書く (/review-loop が回す)。
#
# プロジェクトに合わせて、下の例を 1 つ選んで有効にし、他は消す。最後の `exit 78` の 2 行も消す。
set -euo pipefail
cd "$(dirname "$0")/.."

# 観点のリストの大きさ。レビューのたびに読み込まれるので、14,500 バイトを超えたら統合・削除する。
# プロジェクトの観点と、/retro が足す ~/.claude の共通・言語の観点を見る。~/.claude の観点は全プロジェクトで共有するので、
# 超えたらどのプロジェクトでも止める (超えたまま使い続けると、すべてのレビューの利用枠を食う)。この検査は、下の例を選んだ後も残す
over=0
for f in .claude/review/checklist.md "${CLAUDE_HOME:-$HOME/.claude}"/skills/adversarial-review/checklists/*.md "${CLAUDE_HOME:-$HOME/.claude}"/skills/adversarial-review/checklists/languages/*.md; do
  [ -f "$f" ] || continue
  size="$(wc -c <"$f" | tr -d ' ')"
  if [ "$size" -gt 14500 ]; then
    echo "verify.sh: $f が $size バイトで、上限の 14500 バイトを超えています。項目を統合・削除してください" >&2
    over=1
  fi
done
[ "$over" = 0 ] || exit 1

# --- Node / TypeScript ---
# npm run lint
# npm run typecheck
# npm test -- --run

# --- Python ---
# ruff check .
# pytest -q -x

# --- Swift (XcodeGen + xcodebuild) ---
# swiftlint --quiet
# xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' -quiet

# --- シェルスクリプト ---
# shellcheck scripts/*.sh

# 未設定の印。78 で終えると、フックは「未設定」とみなし、セッションで 1 回だけユーザーに知らせる
exit 78
