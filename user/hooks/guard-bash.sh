#!/bin/bash
# 個人共通 PreToolUse(Bash) ガード (~/.claude/hooks/guard-bash.sh)
# どのプロジェクトでもエージェントに実行させない操作をブロックする。
# exit 2 + stderr でブロックし、理由が Claude に返る。
#
# 多層防御の 1 層であり、サンドボックスではない (python 等を経由した実行までは防げない)。
# 変更したら ~/.claude/hooks/test-guard.sh にケースを追加して通すこと。
set -uo pipefail

cmd="$(jq -r '.tool_input.command // ""')"

block() {
  echo "BLOCKED by ~/.claude/hooks/guard-bash.sh: $1" >&2
  echo "この操作は人間が行う。必要なら理由と実行すべきコマンドをユーザーに提示すること。回避策は探さないこと。" >&2
  exit 2
}

# コマンド名の直前に来うる文字: 行頭 / 空白 / ; & | ( ` / 引用符 / パス区切り
# (bash -c "terraform ..." や /opt/homebrew/bin/terraform ... も捕捉する)
P="(^|[[:space:];&|(\`\"'/])"

# コマンドが置かれる位置: 行頭 / ; & | ( ` $( の直後、または bash -c・eval・exec の引用符の直後。
# その間にある語 (env・timeout・sudo -u x・VAR="a b" などの前置き。引用符で囲んだ値も 1 語) と、パス (/opt/homebrew/bin/git) は読み飛ばす。
# 語の後ろに引用符の外のコマンド名が続かなければ当たらない (echo "git push" の文面には当たらず、eval "git push" と bash -c "git push" には当たる)
CMDPOS="((^|[;&|(\`]|\\\$\\()|((bash|sh|zsh|dash)[^;&|\"']*-[A-Za-z]*c[[:space:]]+[\"'])|((eval|exec)[[:space:]]+[\"']))[[:space:]]*((([^;&|\"'\`()[:space:]]|\"[^\"]*\"|'[^']*')+[[:space:]]+)*)([^[:space:];&|\"']*/)?"

# ユーザー承認を必須にする (settings の ask と同じ効果をフックから強制する)
ask() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
}
# 承認が必要な操作は、他のブロック判定を全て通過した最後に ask する
pending_ask=""

# --- Terraform ---
TF="${P}terraform([[:space:]]+-[^[:space:]]+)*[[:space:]]+"
if grep -Eq "${TF}(destroy|import|taint|untaint|force-unlock)([[:space:]\"']|$)" <<<"$cmd"; then
  block "terraform destroy/import/taint/untaint/force-unlock は禁止"
fi
# apply は「ユーザーがチャットで OK した、レビュー済みの保存 plan ファイル」の適用に限り、承認付きで許可する
if grep -Eq "${TF}apply([[:space:]\"']|$)" <<<"$cmd"; then
  if grep -Eq "${TF}plan([[:space:]\"']|$)" <<<"$cmd"; then
    block "plan と apply を 1 コマンドで実行しない (plan をユーザーに提示して OK を得てから apply する)"
  fi
  if grep -Eq "${TF}apply([^|;&]*)[[:space:]]-(auto-approve|destroy|target|replace|var|var-file|refresh-only)([[:space:]=]|$)" <<<"$cmd"; then
    block "terraform apply に -auto-approve/-destroy/-target/-replace/-var/-var-file/-refresh-only は使わない (保存した plan ファイルを適用する)"
  fi
  if ! grep -Eq "${TF}apply([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^-[:space:]][^[:space:]]*plan[^[:space:]]*([[:space:]\"';&|]|$)" <<<"$cmd"; then
    block "terraform apply は保存した plan ファイル (名前に plan を含む) を指定する形のみ: terraform apply <planfile>"
  fi
  pending_ask="terraform apply: ユーザーがチャットでこの plan の適用を OK していることを確認して承認してください"
fi
if grep -Eq "${TF}state[[:space:]]+(rm|mv|push|pull|replace-provider)" <<<"$cmd"; then
  block "terraform state の変更/生データ取得は禁止"
fi

# --- 機密ファイル/値の読み出し ---
# git commit / gh pr・issue の文章 (-m / --body / --title の値と heredoc の本文) は、実行されない文字列なので判定から除く。
# コミットメッセージや PR 本文に ".env.local" や "git config core.hooksPath ..." と書いただけでブロックされるのを防ぐ。
# bash -c / eval / python 等を含むコマンドは、文字列が実行されうるので除かない
cmd_msg="$cmd"
if grep -Eq "${P}(git([[:space:]]+-[^[:space:]]+)*[[:space:]]+(commit|tag)|gh[[:space:]]+(pr|issue)[[:space:]]+(create|edit|comment|review|close)|cat|tee)([[:space:]]|$)" <<<"$cmd" \
   && ! grep -Eq "${P}(bash|sh|zsh|dash|eval|python[0-9.]*|node|perl|ruby|php|lua|osascript|swift|xargs|source|env)([[:space:]]|$)|(^|[;&|(])[[:space:]]*\.[[:space:]]" <<<"$cmd"; then
  cmd_msg="$(awk '{ if (skip != "") { t = $0; if (dash) sub(/^\t+/, "", t); if (t == skip) skip = ""; next }
           print
           if (match($0, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
             s = substr($0, RSTART, RLENGTH); dash = (s ~ /^<<-/)
             gsub(/^<<-?[[:space:]]*["\047]?|["\047]$/, "", s); skip = s } }' <<<"$cmd" \
    | perl -0pe 's/(?<=\s)(-m|--message|--body|-b|--title|-t)([ =])("(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27)/$1$2""/gs' 2>/dev/null)" || cmd_msg="$cmd"
fi
# JS/TS のプロパティ (e.key, event.key, item.key 等) は鍵ファイルではないので、判定の前に除く
cmd_sec="$(sed -E 's#(^|[^[:alnum:]_.-])(e|ev|evt|event|item|props|entry|row|obj|data|node|child|el|prev|next|ctx|opts|options)\.key([^[:alnum:]_.-]|$)#\1\3#g' <<<"$cmd_msg")"
# *.tfvars は名前を問わない (prod.tfvars も)。*.tfvars.example のようにサンプルの拡張子が続くものは可
if grep -Eq '(^|[/[:space:]"'"'"'])([[:alnum:]_*-]+\.tfvars|\.env)([^.[:alnum:]_-]|$)|\.tfvars\.json|[a-z_]*token[a-z_]*\.txt|\.tfstate(\.[a-z]+)?([[:space:]"'"'"';|&)]|$)|\.ssh/|id_(rsa|ed25519|ecdsa)' <<<"$cmd_sec"; then
  block "機密ファイル (*.tfvars / .env / *.tfstate / *token*.txt / 鍵) へのアクセスは禁止"
fi
# *.pem / *.key は、コードの検索パターン (grep "setting.key " Shared/ など) と見分けがつかない。
# grep / rg の引用符の中のパターンのうち、/ を含まないものは見ない (パスに見える "keys/a.key" や、引用符の外の a.key は見る)。
# 見るのは *.pem / *.key だけで、.env や *.tfvars の判定には影響しない
cmd_key="$cmd_sec"
if grep -Eq "${P}(grep|egrep|fgrep|rg|ag)[[:space:]]" <<<"$cmd_sec"; then
  cmd_key="$(sed -E "s/\"[^\"/]*\"//g; s/'[^'/]*'//g" <<<"$cmd_sec")"
fi
if grep -Eq '(^|[^$[:alnum:]_-])[[:alnum:]_-]+\.(pem|key)([[:space:]"'"'"';|&)]|$)' <<<"$cmd_key"; then
  block "機密ファイル (terraform.tfvars / .env / *.tfstate / *token*.txt / 鍵) へのアクセスは禁止"
fi
# .env.local / .env.production など (.env.example / .sample / .template は可) と、wrangler の .dev.vars
if grep -Eq '(^|[/[:space:]"'"'"'])(\.env\.[A-Za-z0-9._-]+|\.dev\.vars(\.[A-Za-z0-9_-]+)?)([[:space:]"'"'"';|&)]|$)' <<<"$(sed -E 's#\.env\.(example|sample|template)#.env-ok#g' <<<"$cmd_msg")"; then
  block "機密ファイル (.env.* / .dev.vars) へのアクセスは禁止"
fi
# iOS の署名資産 (*.p8 *.p12 *.mobileprovision AuthKey_*) と、Firebase / GCP のサービスアカウント鍵 (*firebase-adminsdk*.json、*service-account*.json)
if grep -Eq '(^|[/[:space:]"'"'"'])AuthKey_[[:alnum:]_]+|(^|[^$[:alnum:]_*-])[[:alnum:]_-]+\.(p8|p12|mobileprovision)([[:space:]"'"'"';|&)]|$)|firebase-adminsdk[^[:space:]]*\.json|[Ss]ervice-?[Aa]ccount[^[:space:]]*\.json' <<<"$cmd"; then
  block "署名資産 (*.p8 / *.p12 / *.mobileprovision / AuthKey_*) とサービスアカウント鍵 (*firebase-adminsdk*.json / *service-account*.json) へのアクセスは禁止"
fi
if grep -Eq 'gcloud([^|;&]*)(secrets[[:space:]]+versions[[:space:]]+access|auth[[:space:]]+(application-default[[:space:]]+)?print-(access|identity)-token)' <<<"$cmd"; then
  block "Secret Manager の値 / アクセストークンの出力は禁止"
fi
# CLI の認証情報: クラウド (~/.aws、~/.config/gcloud)、GitHub (gh のトークン)、コンテナと Kubernetes、ホームの .netrc / .npmrc / .pypirc、
# macOS のキーチェーンの値。プロジェクトの .npmrc (レジストリの設定) は対象外
if grep -Eq '\.aws/(credentials|config)|\.config/(gh/hosts\.yml|gcloud/)|\.kube/config|\.docker/config\.json|(~|\$HOME|\$\{HOME\}|/Users/[^/[:space:]]+|/home/[^/[:space:]]+)/\.(netrc|npmrc|pypirc)([^[:alnum:]_.-]|$)' <<<"$cmd_sec" \
   || grep -Eq "${P}gh[[:space:]]+auth[[:space:]]+(token|status([^|;&]*)[[:space:]](-t|--show-token))([[:space:]\"']|$)" <<<"$cmd" \
   || grep -Eq "${P}security[[:space:]]+(find-(generic|internet)-password([^|;&]*)[[:space:]]-[a-zA-Z]*[wg]([[:space:]]|$)|dump-keychain)" <<<"$cmd"; then
  block "CLI の認証情報 (~/.aws、~/.config/gcloud、gh のトークン、~/.kube、~/.docker、~/.netrc など、キーチェーンの値) の読み出しは禁止"
fi

# --- データを失うクラウド操作 ---
if grep -Eq 'gcloud([^|;&]*)(compute[[:space:]]+(disks|instances|snapshots|resource-policies|images)[[:space:]]+delete|projects[[:space:]]+delete|storage[[:space:]]+(rm|buckets[[:space:]]+delete)|sql[[:space:]]+instances[[:space:]]+delete)' <<<"$cmd" \
   || grep -Eq "${P}gsutil([^|;&]*)[[:space:]](rm|rb)([[:space:]]|$)" <<<"$cmd"; then
  block "クラウド上のディスク/インスタンス/プロジェクト/ストレージの削除は禁止"
fi

# Cloudflare (wrangler): Git を通さない本番デプロイと、リソース・シークレットの削除/変更は人間が行う
if grep -Eq "${P}wrangler([[:space:]]+-[^[:space:]]+)*[[:space:]]+(deploy|publish|delete|rollback|versions[[:space:]]+deploy|pages[[:space:]]+(deploy|publish)|pages[[:space:]]+(project|deployment)[[:space:]]+delete|(r2|kv|d1|queues|vectorize|hyperdrive)([[:space:]]+[^|;&[:space:]]+)*[[:space:]]+delete|secret[[:space:]]+(put|delete|bulk))([[:space:]\"']|$)" <<<"$cmd"; then
  block "wrangler の deploy / delete / secret 変更は禁止 (本番は main へのマージで Cloudflare Pages が行う)"
fi

# --- ハーネス自体の改変 (ガードの無効化) ---
# 無害なリダイレクト (>/dev/null, 2>&1) を除いてから書き込み操作を判定する
cmd_nr="$(sed -E 's#[0-9]*>>?[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9-]##g' <<<"$cmd")"
# grep / rg の検索パターン (オプションの直後の、引用符で囲んだ最初の引数) は書き込み先ではないので、判定から除く
# (grep -n '>' .claude/settings.json や grep 'a\|rm -f x' を、書き込みと見ない)。引用符の外の > や、パターンの後ろの引数は残る
cmd_nr="$(perl -pe 's/((?:^|[\s;&|(])(?:grep|egrep|fgrep|rg|ag)(?:\s+-[^\s\x27"]+)*\s+(?:-e\s+)?)("(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27)/$1""/g' <<<"$cmd_nr" 2>/dev/null)" || cmd_nr="$cmd"
# 個人共通の ~/.claude (フック・settings) は今までどおり禁止。プロジェクトの .claude/hooks は、ユーザーの承認 (ask) を経て可。
# .claude/settings* と .githooks は、プロジェクトのものも禁止のまま
# 誤検知を減らすため、(1) heredoc の本文 (書き込む中身で、書き込み先ではない) を除き、
# (2) && / || / 改行で分けた区間ごとに「書き込み操作」と「保護パス」が同じ区間にあるかを見る。
# 区間の分割は引用符を見ない粗いもので、; と | では分けない (sed -i 's/a/b/;s/c/d/' .githooks/x や xargs sed -i を見逃さないため)。
# 行末の \ は先に連結する。引用符の中の << を heredoc と見て後続を読み飛ばす抜けはある (多層防御の 1 層で、サンドボックスではない)
cmd_home="$(sed -E 's#(~|\$HOME|\$\{HOME\}|'"$HOME"')/\.claude/#HOMECLAUDE/#g' <<<"$cmd_nr" \
  | awk '{ if (skip != "") { t = $0; if (dash) sub(/^\t+/, "", t); if (t == skip) skip = ""; next }
           print
           if (match($0, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
             s = substr($0, RSTART, RLENGTH); dash = (s ~ /^<<-/)
             gsub(/^<<-?[[:space:]]*["\047]?|["\047]$/, "", s); skip = s } }' \
  | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' \
  | awk '{ gsub(/&&|\|\|/, "\n"); print }')"
while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  # 実行権限の付与 (chmod +x) は内容を変えないので、書き込みとみなさない。引数は ; & | < > の手前まで。
  # リダイレクト (chmod +x f > .githooks/x) は残るので、書き込みとして判定される
  seg_w="$(sed -E 's#(^|[[:space:];&|])chmod[[:space:]]+[ugoa]*\+x([[:space:]]+[^;&|<>[:space:]]+)*##g' <<<"$seg")"
  if grep -Eq '>[[:space:]]*[^&[:space:]]|sed[[:space:]]+(-[a-zA-Z]*i|--in-place)|(^|[[:space:];&|])(rm|mv|cp|tee|chmod|ln|truncate|install)[[:space:]]' <<<"$seg_w"; then
    if grep -Eq 'HOMECLAUDE/(hooks|settings)|\.claude/settings|\.githooks|\.git/(config|hooks)' <<<"$seg_w"; then
      block "ハーネス (~/.claude/hooks, ~/.claude/settings*, .claude/settings*, .githooks, .git/config, .git/hooks) を Bash で書き換えることは禁止 (実行権限の付与 chmod +x だけは可)"
    elif grep -Eq '\.claude/(hooks|verify\.sh)' <<<"$seg_w"; then
      pending_ask=".claude/hooks / .claude/verify.sh の変更: ユーザーがチャットでこの変更を OK していることを確認して承認してください"
    elif grep -Eq '\.github/workflows|(^|[/[:space:]])firebase\.json' <<<"$seg_w"; then
      pending_ask=".github/workflows または firebase.json の変更: Secrets を使う公開の経路なので、ユーザーがチャットでこの変更を OK していることを確認して承認してください"
    fi
  fi
done <<<"$cmd_home"
# 承認 (ask) は確認が増えるだけなので、区間に分けず、コマンド全体で見る (git add .claude/hooks && git commit -m "<a@b>" を拾う)
if [ -z "$pending_ask" ] \
   && grep -Eq '>[[:space:]]*[^&[:space:]]|sed[[:space:]]+(-[a-zA-Z]*i|--in-place)|(^|[[:space:];&|])(rm|mv|cp|tee|chmod|ln|truncate|install)[[:space:]]' <<<"$cmd_home" \
   && grep -Eq '\.claude/(hooks|verify\.sh)|\.github/workflows|(^|[/[:space:]])firebase\.json' <<<"$cmd_home"; then
  pending_ask=".claude/hooks / .claude/verify.sh / .github/workflows / firebase.json の変更: ユーザーがチャットでこの変更を OK していることを確認して承認してください"
fi
# 読み取り (git config core.hooksPath / --get) は可。値の設定 (.githooks 以外) と --unset を禁止
# git の設定キーは大文字小文字を区別しない (core.hookspath も同じキー)
if grep -Eiq "${P}git([[:space:]]+-[^[:space:]]+)*[[:space:]]+config([^|;&]*)core\.hooksPath" <<<"$cmd_msg" \
   && { grep -Eq "config([^|;&]*)--(unset|unset-all|remove-section)" <<<"$cmd_msg" \
        || grep -Eiq 'core\.hooksPath[[:space:]]+[^[:space:];&|]' <<<"$cmd_msg"; } \
   && ! grep -Eiq 'core\.hooksPath[[:space:]]+\.githooks([[:space:];&|]|$)' <<<"$cmd_msg"; then
  block "core.hooksPath の変更は禁止 (pre-push フックが無効になる)"
fi
# 1 回だけの上書きでもフックは外れる: git -c / --config-env、環境変数 GIT_CONFIG_*、別の設定ファイルの読み込み (include)。
# alias は push や --no-verify を別名に隠せる (git -c alias.p='push --no-verify' p は push の判定もすり抜ける)
GITCFG_KEY="[\"']?(core\.hookspath|include(if)?\.|alias\.)"
if grep -Eiq "${P}git[^|;&]*[[:space:]](-c[[:space:]]*|--config-env[[:space:]=]+)${GITCFG_KEY}" <<<"$cmd" \
   || grep -Eiq "GIT_CONFIG_(KEY_[0-9]+=|PARAMETERS=[^;&|]*)${GITCFG_KEY}|GIT_CONFIG(_GLOBAL|_SYSTEM)?=" <<<"$cmd"; then
  block "git -c / --config-env / GIT_CONFIG_* で core.hooksPath・include・alias を変えることは禁止 (フックや push の判定を外せる)"
fi
# 永続の alias / include も同じ理由で、値の設定を禁止する (読み取り git config --get alias.x は可)
if grep -Eiq "${P}git([[:space:]]+-[^[:space:]]+)*[[:space:]]+config([^|;&]*)[[:space:]](alias\.[^[:space:]]+|include(if)?\.[^[:space:]]+)[[:space:]]+[^[:space:];&|]" <<<"$cmd"; then
  block "git config で alias / include を設定することは禁止 (フックや push の判定を外せる)"
fi

# --- git push: 保護ブランチへの直接 push / force push / フック回避の禁止 ---
GIT_PUSH="${CMDPOS}git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+push"
if grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]](--no-verify|--mirror|--delete|--all)([^[:alnum:]-]|$)" <<<"$cmd_msg"; then
  block "git push の --no-verify / --mirror / --delete / --all は禁止"
fi
if grep -Eq "${GIT_PUSH}([[:space:]\"']|$)" <<<"$cmd_msg"; then
  # push する先が main/master か: refspec に書かれている場合と、main/master にいて refspec が無い・HEAD の場合 (git push、git push origin HEAD)
  push_main=0
  if grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]:+](refs/heads/)?(main|master)([[:space:]\"']|$)" <<<"$cmd_msg"; then
    push_main=1
  fi
  push_dir="$(grep -Eo "git[[:space:]]+-C[[:space:]]+[^[:space:];&|]+" <<<"$cmd_msg" | head -n 1 | awk '{print $3}' | tr -d "\"'")"
  cur_branch="$(git -C "${push_dir:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ "$push_main" = 0 ] && { [ "$cur_branch" = main ] || [ "$cur_branch" = master ]; }; then
    # push の後の語から、オプションとその値を除いた位置引数 (リモート、refspec...)
    push_args="$(perl -ne 'if (/\bpush\b([^;&|]*)/) { my @w = split " ", $1; my @p; while (@w) { my $x = shift @w; if ($x =~ /^(-o|--push-option|--repo|--receive-pack|--exec)$/) { shift @w; next } next if $x =~ /^-/; push @p, $x } print join(" ", @p) }' <<<"$cmd_msg")"
    read -r -a push_pos <<<"$push_args"
    if [ "${#push_pos[@]}" -le 1 ]; then
      push_main=1
    else
      for r in "${push_pos[@]:1}"; do
        case "$r" in HEAD|+HEAD|@|+@) push_main=1 ;; esac
      done
    fi
  fi
  if [ "$push_main" = 1 ]; then
    # 初回 push の例外: リモートの追跡 ref が 1 つも無い (空のリポジトリへの最初の push) なら、force 無しに限り承認付きで許す
    if [ -z "$(git -C "${push_dir:-.}" for-each-ref --count=1 refs/remotes 2>/dev/null)" ] \
       && ! grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]](-f|--force|--force-with-lease)([[:space:]=]|$)|[[:space:]]\+[^[:space:]]" <<<"$cmd_msg"; then
      pending_ask="git push (main/master への初回 push): リモートにまだ何も無いリポジトリへの最初の push です。ユーザーがチャットでこのリポジトリとブランチへの初回 push を OK していることを確認して承認してください"
    else
      block "main/master への push (force を含む) は禁止 (ブランチを切って PR を作る)"
    fi
  fi
fi
# main/master 以外への force push は、ユーザーの承認 (ask) を経て可。履歴を書き換えるので、ユーザーがチャットで対象を指して OK したときだけ
if grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]](-f|--force|--force-with-lease)" <<<"$cmd_msg"; then
  pending_ask="git push --force: リモートの履歴を上書きします。ユーザーがチャットでこのブランチの force push を OK していることを確認して承認してください"
fi

# --- GitHub ---
if grep -Eq 'gh([^|;&]*)[[:space:]](secret[[:space:]]+(set|delete)|variable[[:space:]]+delete|repo[[:space:]]+delete|release[[:space:]]+delete)' <<<"$cmd"; then
  block "GitHub secret 変更 / repo・release の削除は禁止"
fi
# workflow の手動実行 (apply 等) はユーザーがチャットで OK したものに限り、承認付きで許可する
if grep -Eq 'gh([^|;&]*)[[:space:]]workflow[[:space:]]+run' <<<"$cmd"; then
  pending_ask="gh workflow run: ユーザーがチャットでこの実行を OK していることを確認して承認してください"
fi
if grep -Eq 'gh([^|;&]*)[[:space:]]pr[[:space:]]+merge([^|;&]*)[[:space:]](--admin|--auto)' <<<"$cmd"; then
  block "gh pr merge --admin / --auto は禁止 (確認済みの PR を通常マージする)"
fi
# gh_api_settings_ok <コマンド>: リポジトリ設定の経路への、単独の gh api の変更系呼び出しなら 0。
# 引用符・パイプ・変数展開などを含まない安全な文字だけのコマンドを、トークンに分けて (メソッド × パス × フィールド) で照合する。
# 位置引数はちょうど 1 つで、フラグの値や他の語では判定しない。分からないフラグは拒否する
gh_api_settings_ok() {
  local c=" $1 " a m="" path="" input=0 i=2 key
  local -a t keys=()
  c="${c// 2>&1 / }"; c="${c// 2>&1 / }"   # 独立した語の 2>&1 だけ除く (語に連結したものを作り替えない)
  [[ "$c" =~ ^[][[:alnum:]_./=:@,[:space:]-]+$ ]] || return 1
  read -ra t <<<"$c"
  [ "${t[0]:-}" = gh ] && [ "${t[1]:-}" = api ] || return 1
  while [ "$i" -lt "${#t[@]}" ]; do
    a="${t[$i]}"; i=$((i + 1))
    case "$a" in
      -X|--method) m="${t[$i]:-}"; i=$((i + 1)) ;;
      --method=*) m="${a#*=}" ;;
      -f|-F|--field|--raw-field) key="${t[$i]:-}"; i=$((i + 1)); [[ "${key#*=}" != @* ]] || return 1; keys+=("${key%%=*}") ;;
      --field=*|--raw-field=*) key="${a#*=}"; [[ "${key#*=}" != @* ]] || return 1; keys+=("${key%%=*}") ;;   # 値の @ファイル は、手元のファイルを送れるので拒否
      --input) input=1; i=$((i + 1)) ;;
      --input=*) input=1 ;;
      -H|--header|-q|--jq|-t|--template) i=$((i + 1)) ;;
      --header=*|--jq=*|--template=*|-i|--include|--silent|--verbose) ;;
      -*) return 1 ;;
      *) [ -z "$path" ] || return 1; path="$a" ;;
    esac
  done
  m="$(tr '[:lower:]' '[:upper:]' <<<"$m")"
  if [ -z "$m" ]; then
    { [ "${#keys[@]}" -gt 0 ] || [ "$input" = 1 ]; } && m=POST || return 1
  fi
  local rest
  [[ "$path" =~ ^repos/[^/]+/[^/]+(/.*)?$ ]] || return 1
  rest="${BASH_REMATCH[1]}"
  case "$rest" in
    "")
      # リポジトリ本体: PATCH だけ。許可するキーは機能・マージ方法・説明・セキュリティ設定のみ (公開範囲・改名・既定ブランチ・アーカイブは除く)
      [ "$m" = PATCH ] && [ "$input" = 0 ] || return 1
      for key in ${keys[@]+"${keys[@]}"}; do
        [[ "$key" =~ ^(delete_branch_on_merge|allow_[a-z_]+|has_[a-z_]+|description|homepage|web_commit_signoff_required|(squash_)?merge_commit_(title|message)|security_and_analysis\[[a-z_]+\]\[status\])$ ]] || return 1
      done ;;
    /rulesets) [ "$m" = POST ] ;;
    /rulesets/[0-9]*) [[ "$rest" =~ ^/rulesets/[0-9]+$ ]] && { [ "$m" = PUT ] || [ "$m" = DELETE ]; } ;;
    /private-vulnerability-reporting|/vulnerability-alerts) [ "$m" = PUT ] || [ "$m" = DELETE ] ;;
    /actions/permissions|/actions/permissions/*) [[ "$rest" =~ ^/actions/permissions(/[A-Za-z0-9_-]+)*$ ]] && [ "$m" = PUT ] ;;
    *) return 1 ;;
  esac
}
# gh api の変更系呼び出しは承認 (ask) やブロックを迂回できるため禁止 (GET のみ可)。
# 例外: リポジトリの設定の経路 (リポジトリ本体・rulesets・private-vulnerability-reporting・vulnerability-alerts・actions/permissions) への
# 単独の呼び出しは、ユーザーの承認 (ask) を経て可。経路ごとに許すメソッドとフィールドを絞る (gh_api_settings_ok)
if grep -Eq "${P}gh[[:space:]]+api([^|;&]*)[[:space:]](-X|--method)[[:space:]=]*[\"']?(POST|PUT|PATCH|DELETE|post|put|patch|delete)" <<<"$cmd" \
   || { grep -Eq "${P}gh[[:space:]]+api([^|;&]*)[[:space:]](-f|-F|--field|--raw-field|--input)([[:space:]=]|$)" <<<"$cmd" \
        && ! { grep -Eq "${P}gh[[:space:]]+api[[:space:]]+graphql([[:space:]]|$)" <<<"$cmd" \
               && ! grep -Eiq 'mutation|--input' <<<"$cmd"; }; }; then
  if [ "$(wc -l <<<"$cmd" | tr -d ' ')" -le 1 ] && gh_api_settings_ok "$cmd"; then
    pending_ask="gh api (リポジトリ設定の変更): ユーザーがチャットで対象のリポジトリと設定を指して OK していることを確認して承認してください"
  else
    block "gh api の変更系リクエスト (POST/PUT/PATCH/DELETE、-f/-F/--input) は禁止 (リポジトリ設定の経路への単独の呼び出しを除く)"
  fi
fi

# --- コミットしていない作業を消す git 操作 (承認) ---
# 未追跡のファイルは git の履歴に無く、clean や reset --hard で戻せない
GIT="${CMDPOS}git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+"
if grep -Eq "${GIT}clean([[:space:]\"']|$)" <<<"$cmd_msg" && ! grep -Eq "${GIT}clean([^|;&]*)[[:space:]](-[a-zA-Z]*n[a-zA-Z]*|--dry-run)([[:space:]]|$)" <<<"$cmd_msg"; then
  pending_ask="git clean: 未追跡のファイルを消します。ユーザーがチャットでこの操作を OK していることを確認して承認してください"
elif grep -Eq "${GIT}(reset([^|;&]*)[[:space:]]--hard|stash[[:space:]]+(drop|clear)|branch([^|;&]*)[[:space:]]-D|checkout[[:space:]]+(-f|--force|--|\.)|switch([^|;&]*)[[:space:]](-f|--force|--discard-changes))([[:space:]\"']|$)" <<<"$cmd_msg"; then
  pending_ask="git の破壊的な操作 (reset --hard / checkout -- / stash drop / branch -D など): コミットしていない変更や、ブランチを失います。ユーザーがチャットでこの操作を OK していることを確認して承認してください"
elif grep -Eq "${GIT}restore([[:space:]\"']|$)" <<<"$cmd_msg" \
     && ! { grep -Eq "${GIT}restore([^|;&]*)[[:space:]](--staged|-S)([[:space:]]|$)" <<<"$cmd_msg" && ! grep -Eq "${GIT}restore([^|;&]*)[[:space:]](--worktree|-W)([[:space:]]|$)" <<<"$cmd_msg"; }; then
  pending_ask="git restore: 作業ツリーの変更を捨てます。ユーザーがチャットでこの操作を OK していることを確認して承認してください"
fi

# --- マシンの設定を残す、外のコードを実行する、ホームを消す操作 ---
if grep -Eq "(curl|wget)([^;&]*)\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]\"']|$)" <<<"$cmd"; then
  block "curl/wget の出力を sh に渡す実行は禁止 (信頼できない取得元のコードを実行しない)"
fi
if grep -Eq "${P}rm[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*[rR][A-Za-z]*[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(/|~|\\\$HOME|\\\$\\{HOME\\}|\"\\\$HOME\")/?\*?([[:space:]\"';&|]|$)" <<<"$cmd"; then
  block "ルートやホームを対象にした rm -r は禁止"
fi
# 作業ツリーを消す rm -r は承認 (未追跡のファイルは git でも戻せない。git clean と同じ扱い)。
# 対象がすべてビルドの生成物か一時ディレクトリなら確認しない。変数 ($dir) は中身が分からないので承認に回す
rm_targets="$(perl -ne 'while (/(?:^|[\s;&|(])rm\s+((?:-\S+\s+)*)([^;&|<>]*)/g) { my ($o, $a) = ($1, $2); next unless $o =~ /(^|\s)(-[A-Za-z]*[rR]|--recursive)/; for (split " ", $a) { s/^["\x27]|["\x27]$//g; print "$_\n" } }' <<<"$cmd_msg" 2>/dev/null)"
if [ -n "$rm_targets" ]; then
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    if ! grep -Eq '^(\./)?([^/]+/)*(node_modules|dist|build|out|coverage|\.next|\.nuxt|\.turbo|\.cache|\.parcel-cache|target|DerivedData|\.build|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.tox|\.venv|venv)/?$|^/(private/)?tmp/|^/var/folders/|^(~|\$HOME|\$\{HOME\})/Library/(Caches|Developer/Xcode/DerivedData)/' <<<"$t"; then
      pending_ask="rm -r: ビルドの生成物でないディレクトリ ($t) を消します。未追跡のファイルは戻せません。ユーザーがチャットでこの操作を OK していることを確認して承認してください"
      break
    fi
  done <<<"$rm_targets"
fi
if grep -Eq "${P}sudo[[:space:]]" <<<"$cmd"; then
  pending_ask="sudo: 管理者権限の操作です。ユーザーがチャットでこの操作を OK していることを確認して承認してください"
elif grep -Eq "${P}launchctl[[:space:]]+(bootstrap|load|enable)([[:space:]]|$)" <<<"$cmd" \
     || { grep -Eq "${P}crontab([[:space:]]|$)" <<<"$cmd" && ! grep -Eq "${P}crontab[[:space:]]+-l([[:space:]]|$)" <<<"$cmd"; } \
     || grep -Eq "${P}defaults[[:space:]]+(-currentHost[[:space:]]+)?(write|delete)([[:space:]]|$)" <<<"$cmd"; then
  pending_ask="launchctl の登録 / crontab / defaults write: マシンの設定が残ります。ユーザーがチャットでこの操作を OK していることを確認して承認してください"
fi

[ -n "$pending_ask" ] && ask "$pending_ask"
exit 0
