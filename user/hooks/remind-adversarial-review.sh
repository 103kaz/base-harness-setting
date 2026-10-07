#!/bin/bash
# 個人共通 UserPromptSubmit フック: プロンプトがレビュー依頼らしいとき、敵対的レビューの方針を文脈に足す。
# ブロックはしない (リマインドのみ)。「レビュー」「review」を含むプロンプトが対象で、
# コードのレビュー依頼でない場合は本文の但し書きどおり無視される。
# 変更したら ~/.claude/hooks/test-guard.sh にケースを追加して通すこと。
set -uo pipefail

prompt="$(jq -r '.prompt // ""')"
# パスやファイル名の中の review (skills/adversarial-review/...、remind-adversarial-review.sh) はレビューの依頼ではないので除く。
# 単独のスラッシュコマンド (/code-review) は残す
prompt_words="$(perl -pe 's{\S*(?:\S/\S*review|review/|review\.[A-Za-z]+)\S*}{}gi' <<<"$prompt" 2>/dev/null)" || prompt_words="$prompt"
grep -Eiq 'レビュー|review' <<<"$prompt_words" || exit 0

ctx='個人ルール (レビュー): コードのレビュー依頼なら、次の 2 段で行う。明示的に指示されない限り、範囲は差分だけ (コードベース全体は見ない)。
- 普段のレビュー: このセッションで code-review スキル (effort は medium)。
- 敵対的レビュー: 回すかどうかは AskUserQuestion でユーザーに聞いて決める (選択肢に「必要 / 不要」の所見を添える。聞かずに省かない)。回すときは、サブエージェントに adversarial-review スキルで読み取り専用で見させる。実装の経緯は渡さない。スキルは共通・言語ごと・プロジェクトごと (.claude/review/checklist.md) の観点のリストを当てる。観点に無い指摘は、このセッションがリストに足す。
- 敵対的レビューの読み方と報告の形は、adversarial-review スキルの SKILL.md に従う。
- 差分が .md のみなら、上の代わりに doc-code-consistency スキルで「書かれた内容が実装と合っているか」を確認する。
- レビューコメントへの返信や、レビュー以外の依頼なら、このルールは適用しない。'

jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
exit 0
