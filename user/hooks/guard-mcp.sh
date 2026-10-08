#!/bin/bash
# 個人共通 PreToolUse(mcp__.*) ガード (~/.claude/hooks/guard-mcp.sh)
# MCP ツールで、外部のリソースを消す・公開する・秘密を変える操作は、ユーザーの承認 (ask) を要する。
# Bash のガード (guard-bash.sh) が CLI (wrangler、gcloud、gh) で止めている操作を、MCP の経路で素通りさせないため。
#
# 判定はツール名 (サーバー名を除いた部分) の語と、SQL を受けるツールの入力の文。サーバーごとの一覧は持たない。
# 変更したら ~/.claude/hooks/test-guard.sh にケースを追加して通すこと。
set -uo pipefail

# jq が無いとツール名を読めず、何も確認しないまま通ってしまう。入れてもらうまで、すべて止める
if ! command -v jq >/dev/null; then
  echo "BLOCKED by ~/.claude/hooks/guard-mcp.sh: jq が見つかりません。ガードが MCP ツールの呼び出しを読めないため、すべて止めます。" >&2
  echo "jq を入れてください (macOS: brew install jq)。" >&2
  exit 2
fi

input="$(cat)"
tool="$(jq -r '.tool_name // ""' <<<"$input")"
name="${tool##*__}"

ask() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
}

# ツール名の語 (_ や - で区切った単位) に、削除・公開・秘密の変更を表す語があるか
if grep -Eiq '(^|[_-])(delete|destroy|drop|purge|remove|truncate|wipe|deploy|publish|rollback|secret|secrets)([_-]|$)' <<<"$name"; then
  ask "MCP ツール $tool: 外部のリソースを消す・公開する・秘密を変える操作です。ユーザーがチャットでこの操作を OK していることを確認して承認してください"
fi

# SQL を実行するツール (query、sql、execute) は、変更系の文なら承認
if grep -Eiq '(^|[_-])(query|sql|execute|exec)([_-]|$)' <<<"$name" \
   && jq -r '.tool_input | tostring' <<<"$input" | grep -Eiq '(^|[^[:alnum:]_])(drop|delete|truncate|alter|update|insert|replace|create)[[:space:]]'; then
  ask "MCP ツール $tool: データベースを変更する SQL です。ユーザーがチャットでこの操作を OK していることを確認して承認してください"
fi

exit 0
