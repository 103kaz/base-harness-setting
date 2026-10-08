#!/bin/bash
# 導入の確認。前提のコマンド、~/.claude に入った個人共通、(指定すれば) プロジェクトの雛形を調べる。
# ガードは実際に動かして、止めるべき操作を止めるかまで確かめる。何も書き換えない。
#
#   bash scripts/doctor.sh                 前提のコマンドと個人共通 (環境変数 CLAUDE_HOME で置き場所を変えられる)
#   bash scripts/doctor.sh <project-dir>   上に加えて、プロジェクトの雛形
#
# NG があれば 1 で終わる。warn は直したほうがよいが、動きは止めない。
set -uo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
home="${CLAUDE_HOME:-$HOME/.claude}"
[ $# -le 1 ] || { echo "使い方: bash scripts/doctor.sh [project-dir]" >&2; exit 2; }
if [ $# -eq 1 ] && [ -z "$1" ]; then echo "project-dir が空です。使い方: bash scripts/doctor.sh [project-dir]" >&2; exit 2; fi
proj="${1:-}"
# サブシェルで cd した後でも使えるよう、絶対パスにする
if [ -d "$home" ]; then home="$(cd "$home" && pwd)"; fi
fail=0
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

ok()   { echo "  ok    $1"; }
ng()   { echo "  NG    $1"; fail=1; }
warn() { echo "  warn  $1"; }

echo "[前提のコマンド]"
ok "bash $BASH_VERSION"
for c in git jq; do
  if command -v "$c" >/dev/null; then ok "$c"; else ng "$c が無い (必須)。jq が無いと、ガードは Bash と MCP の操作をすべて止める"; fi
done
for c in gitleaks gh; do
  if command -v "$c" >/dev/null; then ok "$c"; else warn "$c が無い。gitleaks が無いと pre-push は push を止める。gh は GitHub を使うときに要る"; fi
done
if command -v terraform >/dev/null; then ok "terraform"; else ok "terraform は無い (任意)"; fi

echo "[個人共通 ($home)]"
for f in hooks/guard-bash.sh hooks/guard-mcp.sh hooks/remind-adversarial-review.sh hooks/fmt-terraform.sh hooks/test-guard.sh \
         skills/adversarial-review/SKILL.md skills/doc-code-consistency/SKILL.md; do
  if [ -f "$home/$f" ]; then ok "$f"; else ng "$f が無い。./init.sh user で配布する"; fi
done

settings="$home/settings.json"
# settings.json は JSON として読み、フックの登録 (イベントごとの command) と deny / ask の中身を見る
if [ ! -f "$settings" ]; then
  ng "settings.json が無い。./init.sh user で配布する"
elif ! command -v jq >/dev/null || ! jq -e . "$settings" >/dev/null 2>&1; then
  ng "settings.json が JSON として読めない (または jq が無い)"
else
  # 登録済みとみなすのは、同じイベントの同じ matcher に、そのスクリプトを実行する command があるとき (名前が文字列に入るだけでは数えない)
  hooked() { # hooked <イベント> <スクリプト名> <matcher>
    jq -e --arg ev "$1" --arg n "$2" --arg m "$3" '
      [ .hooks[$ev][]? | select((.matcher // "") == $m) | .hooks[]? | (.command? // "") | select(type == "string")
        | select(test("^(bash +|sh +)?\"?([^ \"]*/)?" + ($n | gsub("\\."; "\\.")) + "\"?( .*)?$")) ] | length > 0' "$settings" >/dev/null 2>&1
  }
  hooked PreToolUse guard-bash.sh Bash && ok "settings.json が PreToolUse (Bash) に guard-bash.sh を登録している" \
    || ng "settings.json が PreToolUse (matcher: Bash) に guard-bash.sh を登録していない。./init.sh user --merge-settings で足す"
  hooked PreToolUse guard-mcp.sh 'mcp__.*' && ok "settings.json が PreToolUse (mcp__.*) に guard-mcp.sh を登録している" \
    || ng "settings.json が PreToolUse (matcher: mcp__.*) に guard-mcp.sh を登録していない。./init.sh user --merge-settings で足す"
  hooked UserPromptSubmit remind-adversarial-review.sh '' && ok "settings.json が UserPromptSubmit に remind-adversarial-review.sh を登録している" \
    || ng "settings.json が UserPromptSubmit に remind-adversarial-review.sh を登録していない。./init.sh user --merge-settings で足す"
  if jq -e '(.permissions.deny | length) > 0' "$settings" >/dev/null 2>&1; then ok "settings.json の deny に項目がある"
  else ng "settings.json の deny が空 (機密ファイルを読める)"; fi
  if jq -e '.permissions.ask | index("Bash(git push)") != null' "$settings" >/dev/null 2>&1; then ok "settings.json の ask に git push がある"
  else ng "settings.json の ask に Bash(git push) が無い (push が確認なしで通る)"; fi
fi

# ガードを実際に動かす。cwd の git の状態に左右されないよう、空のディレクトリで動かす
if [ -f "$home/hooks/guard-bash.sh" ] && command -v jq >/dev/null; then
  mkdir -p "$tmp/cwd"
  # 入力はパイプでなくファイルから渡す。標準入力を読まずに終わるガードだと、パイプでは jq が書き込みに失敗して
  # (終了コード 2)、pipefail のもとで「ガードが 2 で止めた」と誤って読める
  gcase() { # gcase <説明> <期待する終了コード> <コマンド>
    local rc
    jq -n --arg c "$3" '{tool_input:{command:$c}}' >"$tmp/in.json"
    (cd "$tmp/cwd" && bash "$home/hooks/guard-bash.sh" <"$tmp/in.json" >/dev/null 2>&1); rc=$?
    if [ "$rc" = "$2" ]; then ok "ガード: $1"; else ng "ガード: $1 (終了コード $rc、期待は $2)"; fi
  }
  gcase "普通のコマンドは通す (ls)"                      0 'ls'
  gcase "普通のコマンドは通す (git status)"              0 'git status'
  gcase "普通のコマンドは通す (git commit)"              0 'git commit -m x'
  gcase "普通のコマンドは通す (gh pr view)"              0 'gh pr view 1'
  gcase "普通のコマンドは通す (terraform plan)"          0 'terraform plan'
  gcase "main への force push を止める"                  2 'git push --force origin main'
  gcase ".env の読み出しを止める"                        2 'cat .env'
  gcase "terraform destroy を止める"                     2 'terraform destroy'
  gcase "gh api の変更系 (設定の経路の外) を止める"       2 'gh api -X PUT repos/o/r/pulls/1/merge'
  if [ -f "$home/hooks/guard-mcp.sh" ]; then
    jq -n '{tool_name:"mcp__x__delete_thing",tool_input:{}}' >"$tmp/in.json"
    out="$(bash "$home/hooks/guard-mcp.sh" <"$tmp/in.json" 2>/dev/null)"
    if grep -q '"ask"' <<<"$out"; then ok "ガード: MCP の削除系は確認に回す"; else ng "ガード: MCP の削除系を確認に回さない"; fi
    jq -n '{tool_name:"mcp__x__list_things",tool_input:{}}' >"$tmp/in.json"
    out="$(bash "$home/hooks/guard-mcp.sh" <"$tmp/in.json" 2>/dev/null)"
    if [ -z "$out" ]; then ok "ガード: MCP の読み取り系は通す"; else ng "ガード: MCP の読み取り系を止める"; fi
  fi
fi

# ベースの user/ との差。ベースが更新された、またはこのマシン独自の変更。どちらかは見て決める
if [ -d "$BASE/user" ] && [ -d "$home/hooks" ]; then
  if diffs="$(CLAUDE_HOME="$home" bash "$BASE/scripts/check-sync.sh" 2>&1)"; then
    ok "ベースの user/ と一致している"
  else
    warn "ベースの user/ と違う (ベースの更新か、このマシン独自の変更)。差分を見て取り込む:"
    sed 's/^/          /' <<<"$diffs"
  fi
fi

if [ -n "$proj" ]; then
  echo "[プロジェクト ($proj)]"
  if [ ! -d "$proj" ]; then
    ng "ディレクトリが無い"
  else
    if [ -f "$proj/CLAUDE.md" ]; then ok "CLAUDE.md"; else ng "CLAUDE.md が無い。./init.sh project で入れる"; fi
    if [ -f "$proj/CLAUDE.md" ] && grep -q '{{PROJECT_NAME}}' "$proj/CLAUDE.md"; then ng "CLAUDE.md に {{PROJECT_NAME}} が残っている"; fi
    ps="$proj/.claude/settings.json"
    if [ -f "$ps" ] && jq -e . "$ps" >/dev/null 2>&1; then
      for ev in UserPromptSubmit Stop; do
        if jq -e --arg ev "$ev" '[.hooks[$ev][]?.hooks[]?.command] | any(contains("verify-on-stop.sh"))' "$ps" >/dev/null 2>&1; then
          ok "検証ループのフック ($ev) が登録されている"
        else
          ng "settings.json が $ev に verify-on-stop.sh を登録していない"
        fi
      done
    else
      ng ".claude/settings.json が無い、または JSON でない"
    fi
    if [ -x "$proj/.claude/hooks/verify-on-stop.sh" ]; then ok ".claude/hooks/verify-on-stop.sh"; else ng ".claude/hooks/verify-on-stop.sh が無い、または実行できない (検証ループが働かない)"; fi
    if [ -x "$proj/.claude/verify.sh" ]; then
      if grep -q '^exit 78' "$proj/.claude/verify.sh"; then warn ".claude/verify.sh が雛形のまま (exit 78)。検証は何も走らない。SETUP.md の 3"
      else ok ".claude/verify.sh を設定済み"; fi
    else
      ng ".claude/verify.sh が無い、または実行できない"
    fi
    if git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
      if [ "$(git -C "$proj" config core.hooksPath 2>/dev/null)" = ".githooks" ]; then
        ok "core.hooksPath が .githooks"
        command -v gitleaks >/dev/null || ng "pre-push が有効なのに gitleaks が無い (push が止まる)。brew install gitleaks"
      else
        warn "core.hooksPath が .githooks でない。pre-push が働かない: git config core.hooksPath .githooks"
      fi
    else
      warn "git のリポジトリではない。git init してから、core.hooksPath を設定する"
    fi
    if [ -x "$proj/.githooks/pre-push" ]; then ok ".githooks/pre-push"; else ng ".githooks/pre-push が無い、または実行できない"; fi

    # 雛形との差 (自分で埋めるファイル CLAUDE.md・verify.sh・checklist.md は比べない)
    while IFS= read -r f; do
      case "$f" in CLAUDE.md|.claude/verify.sh|.claude/review/checklist.md) continue ;; esac
      if [ ! -e "$proj/$f" ]; then warn "雛形のファイルが無い: $f"
      elif ! cmp -s "$BASE/project/$f" "$proj/$f"; then warn "雛形と違う: $f (編集済み、またはベースが更新された)"; fi
    done < <(cd "$BASE/project" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' | sort)
  fi
fi

echo
if [ "$fail" = 0 ]; then echo "問題ありません"; else echo "NG があります。上の指示に従って直してください"; fi
exit "$fail"
