#!/bin/bash
# ベースのハーネス構成を配布する。引数なしで実行すると、対話式で設定する。
#
#   ./init.sh                                     対話式 (言語の追加、個人共通の配布、プロジェクトの雛形の配布をまとめて行う)
#   ./init.sh user [--force]                      個人共通 (user/) を ~/.claude へ。環境変数 CLAUDE_HOME で置き場所を変えられる
#   ./init.sh project <dir> [--name N] [--force]  プロジェクトの雛形 (project/) を <dir> へ
#   ./init.sh lang <言語名> [--ext .xx] [--prefix XX]  言語別のレビュー観点の雛形をベースに作る
#                                                 (user/skills/adversarial-review/checklists/languages/<言語名>.md)
#
# 既存のファイルは上書きしない。内容が違うものは「skip」と表示するので、差分を見て手で取り込む。
# --force を付けたときだけ上書きする (上書き前のファイルは <file>.bak.<時刻> に残す)。
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
LANG_DIR="$BASE/user/skills/adversarial-review/checklists/languages"
force=0
created=()
skipped=()

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# copy_file <src> <dst>: 無ければ作る / 同じなら何もしない / 違えば skip (--force なら退避して上書き)
copy_file() {
  local src="$1" dst="$2"
  if [ ! -e "$dst" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
    created+=("$dst")
  elif cmp -s "$src" "$dst"; then
    :
  elif [ "$force" = 1 ]; then
    cp -p "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$src" "$dst"
    created+=("$dst (上書き)")
  else
    skipped+=("$dst")
  fi
}

copy_tree() {
  local src="$1" dst="$2" f
  while IFS= read -r f; do
    copy_file "$src/$f" "$dst/$f"
  done < <(cd "$src" && find . -type f ! -name '.DS_Store' | sed 's#^\./##' | sort)
}

# 結果を表示して、次の配布のために作成/skip の記録を空にする
report() {
  local f
  for f in "${created[@]+"${created[@]}"}"; do echo "  作成: $f"; done
  for f in "${skipped[@]+"${skipped[@]}"}"; do echo "  skip (内容が違う): $f"; done
  if [ "${#skipped[@]}" -gt 0 ]; then
    echo "  skip したファイルは diff で確かめて手で取り込むか、--force で上書きする。"
  fi
  created=()
  skipped=()
}

# --- 配布の本体 ---

do_user() {
  local dst="${CLAUDE_HOME:-$HOME/.claude}"
  echo "個人共通を $dst へ配布します"
  copy_tree "$BASE/user" "$dst"
  chmod +x "$dst"/hooks/*.sh 2>/dev/null || true
  report
  echo "確認: bash $dst/hooks/test-guard.sh"
}

# do_project <dir> <name>
do_project() {
  local target="$1" name="$2" esc staging
  mkdir -p "$target"
  target="$(cd "$target" && pwd)"
  [ -n "$name" ] || name="$(basename "$target")"
  echo "プロジェクトの雛形を $target へ配布します"
  # プロジェクト名を埋めた雛形を作ってから配る。既存のファイルとの比較も、--force の上書きも、埋めた後の内容で行う
  staging="$(mktemp -d)"
  cp -Rp "$BASE/project/." "$staging/"
  esc="$(printf '%s' "$name" | sed 's/[&|\\]/\\&/g')"
  sed -i.tmp "s|{{PROJECT_NAME}}|$esc|g" "$staging/CLAUDE.md" && rm -f "$staging/CLAUDE.md.tmp"
  copy_tree "$staging" "$target"
  rm -rf "$staging"
  chmod +x "$target"/.claude/hooks/*.sh "$target"/.claude/verify.sh "$target"/.githooks/* 2>/dev/null || true
  report
  cat <<EOF

次にやること (詳しくは SETUP.md):
  1. $target/CLAUDE.md の TODO を埋める
  2. $target/.claude/verify.sh に、このプロジェクトの lint・テスト・ビルドを書く
  3. $target/.claude/review/checklist.md の領域の索引を、プロジェクトに合わせて直す
  4. git リポジトリなら有効にする: git -C "$target" config core.hooksPath .githooks
EOF
}

# validate_lang <言語名> <拡張子> <接頭辞>: 問題があれば理由を stderr に出して 1 を返す
validate_lang() {
  local lang="$1" ext="$2" prefix="$3"
  if ! [[ "$lang" =~ ^[a-z0-9][a-z0-9_+-]*$ ]]; then
    echo "言語名は小文字の英数字と _ + - だけ (例: rust、java、kotlin、cpp)" >&2
    return 1
  fi
  if ! [[ "$ext" =~ ^\.[A-Za-z0-9_+.,\ -]+$ ]]; then
    echo "拡張子は .xx の形 (例: .rs、\".php, .phtml\")" >&2
    return 1
  fi
  if ! [[ "$prefix" =~ ^[A-Z0-9]+$ ]]; then
    echo "接頭辞は大文字の英数字だけ (例: RS)" >&2
    return 1
  fi
  if [ -e "$LANG_DIR/$lang.md" ]; then
    echo "既にあります: $LANG_DIR/$lang.md" >&2
    return 1
  fi
}

default_ext() { printf '.%s' "$1"; }
default_prefix() { printf '%s' "$1" | tr -cd 'a-z0-9' | cut -c1-3 | tr 'a-z' 'A-Z'; }

# do_lang <言語名> <拡張子> <接頭辞>: 呼び出す側で validate_lang を通しておく
do_lang() {
  local lang="$1" ext="$2" prefix="$3" out="$LANG_DIR/$1.md"
  sed -e "s|{{LANG}}|$lang|g" -e "s|{{EXT}}|$ext|g" -e "s|{{PREFIX}}|$prefix|g" \
    "$BASE/templates/language-checklist.md" >"$out"
  echo "作成: $out"
}

# --- 引数付きの呼び出し ---

cmd_user() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      *) usage ;;
    esac
    shift
  done
  do_user
  echo "プロジェクトの雛形は: ./init.sh project <dir>"
}

cmd_project() {
  local target="${1:-}" name=""
  [ -n "$target" ] || usage
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      --name) [ $# -ge 2 ] || usage; shift; name="$1" ;;
      *) usage ;;
    esac
    shift
  done
  do_project "$target" "$name"
  echo "  5. 個人共通 (~/.claude) が未配布なら: ./init.sh user"
}

cmd_lang() {
  local lang="${1:-}" ext="" prefix=""
  [ -n "$lang" ] || usage
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --ext) [ $# -ge 2 ] || usage; shift; ext="$1" ;;
      --prefix) [ $# -ge 2 ] || usage; shift; prefix="$1" ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$ext" ] || ext="$(default_ext "$lang")"
  [ -n "$prefix" ] || prefix="$(default_prefix "$lang")"
  validate_lang "$lang" "$ext" "$prefix" || exit 2
  do_lang "$lang" "$ext" "$prefix"
  cat <<EOF

次にやること:
  1. 観点を書く (言語や標準ライブラリ、実行環境に固有のものだけ。1 ファイル約 14KB まで)
  2. README の構成の一覧に言語名を足す
  3. ~/.claude に反映する: ./init.sh user
EOF
}

# --- 対話式 ---

# ask <質問> <既定値>: 答えを ANSWER に入れる。空 Enter は既定値。入力が途中で終わったら中止する
ask() {
  local prompt="$1" default="${2:-}" line=""
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default"
  else
    printf '%s: ' "$prompt"
  fi
  if ! IFS= read -r line; then
    echo
    echo "入力が終わったので中止しました。" >&2
    exit 1
  fi
  ANSWER="${line:-$default}"
}

# confirm <質問> <y|n>: 既定値を [Y/n] か [y/N] で示す。yes なら 0
confirm() {
  local prompt="$1" default="$2" hint ans
  if [ "$default" = y ]; then hint="Y/n"; else hint="y/N"; fi
  ask "$prompt ($hint)" ""
  ans="$ANSWER"
  [ -n "$ans" ] || ans="$default"
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

interactive() {
  local langs_new=() do_u=0 do_p=0 target="" pname="" lang ext prefix existing plan

  echo "ベースのハーネス構成を設定します。空 Enter は [ ] の中の既定値です。"
  echo

  # 1. 言語
  existing="$(cd "$LANG_DIR" && ls *.md 2>/dev/null | sed 's/\.md$//' | paste -sd' ' -)" || existing=""
  echo "[1/3] 言語別のレビュー観点"
  echo "  今ある言語: ${existing:-なし}"
  while confirm "  新しい言語の観点ファイルを足しますか?" n; do
    ask "    言語名 (小文字。例: rust、java、kotlin)" ""
    lang="$ANSWER"
    [ -n "$lang" ] || break
    ask "    拡張子" "$(default_ext "$lang")"
    ext="$ANSWER"
    ask "    ID の接頭辞 (大文字)" "$(default_prefix "$lang")"
    prefix="$ANSWER"
    if printf '%s\n' "${langs_new[@]+"${langs_new[@]}"}" | grep -q "^$lang|"; then
      echo "    -> この回で既に足しています: $lang"
      echo "    -> 追加しません"
    elif validate_lang "$lang" "$ext" "$prefix"; then
      langs_new+=("$lang|$ext|$prefix")
      echo "    -> 追加します: $lang ($ext, $prefix-01)"
    else
      echo "    -> 追加しません"
    fi
  done
  echo

  # 2. 個人共通
  echo "[2/3] 個人共通 (ハーネスのフック・スキル・CLAUDE.md・settings)"
  if confirm "  ${CLAUDE_HOME:-$HOME/.claude} へ配布しますか?" y; then do_u=1; fi
  echo

  # 3. プロジェクト
  echo "[3/3] プロジェクトの雛形"
  if confirm "  プロジェクトに雛形を入れますか?" n; then
    ask "    プロジェクトのディレクトリ" ""
    target="$ANSWER"
    if [ -n "$target" ]; then
      target="${target/#\~/$HOME}"
      ask "    プロジェクト名" "$(basename "$target")"
      pname="$ANSWER"
      do_p=1
    fi
  fi
  echo

  if [ "$do_u" = 1 ] || [ "$do_p" = 1 ]; then
    if confirm "内容が違う既存ファイルを上書きしますか? (上書き前のファイルは .bak に残します)" n; then force=1; fi
    echo
  fi

  if [ "${#langs_new[@]}" = 0 ] && [ "$do_u" = 0 ] && [ "$do_p" = 0 ]; then
    echo "することがありません。終了します。"
    return 0
  fi

  # 実行前の確認
  plan="実行する内容:"
  for l in "${langs_new[@]+"${langs_new[@]}"}"; do plan+=$'\n'"  - 言語の観点を作る: ${l%%|*}"; done
  if [ "$do_u" = 1 ]; then plan+=$'\n'"  - 個人共通を配布: ${CLAUDE_HOME:-$HOME/.claude}"; fi
  if [ "$do_p" = 1 ]; then plan+=$'\n'"  - プロジェクトの雛形を配布: $target (名前: $pname)"; fi
  if [ "$force" = 1 ]; then plan+=$'\n'"  - 既存ファイルは上書き (.bak を残す)"; fi
  echo "$plan"
  confirm "実行しますか?" y || { echo "中止しました。"; return 0; }
  echo

  # 言語 -> 個人共通 -> プロジェクトの順 (個人共通に新しい言語を含めるため)
  for l in "${langs_new[@]+"${langs_new[@]}"}"; do
    IFS='|' read -r lang ext prefix <<<"$l"
    do_lang "$lang" "$ext" "$prefix"
  done
  if [ "$do_u" = 1 ]; then do_user; echo; fi
  if [ "$do_p" = 1 ]; then do_project "$target" "$pname"; echo; fi

  if [ "${#langs_new[@]}" -gt 0 ]; then
    echo "言語の観点ファイルは雛形のままです。観点を書いてください (1 ファイル約 14KB まで)。"
    if [ "$do_u" = 0 ]; then echo "~/.claude に反映するには: ./init.sh user"; fi
  fi
}

# --- 入口 ---

if [ $# -eq 0 ]; then
  interactive
  exit 0
fi

cmd="$1"
shift
case "$cmd" in
  user) cmd_user "$@" ;;
  project) cmd_project "$@" ;;
  lang) cmd_lang "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
