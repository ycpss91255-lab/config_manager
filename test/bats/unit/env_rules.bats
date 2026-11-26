#!/usr/bin/env bats
#
# script/claude-hooks/env-rules.sh —— Claude Code 的 PreToolUse hook：docker 先問、不碰 cm_verify_* 驗證環境、不讀 token 檔、
# 不在主 checkout 切換分支、指令說明用中文（T19、#412）。
#
# hook 在主機上跑，只讀工具呼叫的輸入（#412 的 Q1）：不呼叫 git、不跑專案程式、不掃檔案系統；讀的檔只有入口清單與往上找到的
# .git。看不到、判斷不了的時候擋下並寫出下一步（Q8）。
#
# 測的是公開行為：照 Claude Code 給 hook 的形狀把 JSON 餵進標準輸入，看判定——結束碼 2 是擋下（deny），結束碼 0 而標準輸出
# 是 permissionDecision 為 ask 的 JSON 是先問，結束碼 0 而沒有輸出是放行。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  HOOK="${REPO_ROOT}/script/claude-hooks/env-rules.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  STEP_READ="要讀單一檔案就用 Read"
  STEP_GIT_GREP="跨檔搜尋內容用 git grep"
  STEP_RUNNER="不經 xargs、parallel，直接下 git grep"
  STEP_LITERAL="git 的選項與子指令寫成字面"
  STEP_CONFIG="前面不加 git -c、--config-env 或 GIT_CONFIG… 的設定"
  STEP_GREP_ARGS="git grep 的選項寫成字面"
  STEP_VAR_PATTERN="要搜的字串來自變數時寫成 -e"
  STEP_XARGS="xargs 後面的 git 寫明字面的子指令"
  STEP_SHELL_RUNNER="不經 watch、parallel，直接下 git"
  STEP_PROGRAM="程式名稱寫成字面"
  STEP_PAGER="用 git grep -l 列出檔名，再用 Read 讀"
  STEP_NO_PAGER="跨檔搜尋內容用 git grep：不加 --no-index、--untracked、-O"
  STEP_WORKTREE="改到 worktree 裡做"
  STEP_DIR="改到 worktree 裡做，或寫明目錄"
  STEP_VERIFY="不碰 cm_verify_* 驗證環境"
  STEP_DESCRIPTION="用繁體中文寫指令說明"
}

teardown() {
  rm -rf "${WORK}"
}

# call <工具> <tool_input 的 JSON> [<cwd>]：照 Claude Code 給 PreToolUse hook 的形狀餵給 hook。結束碼放 code，
# 標準輸出、標準錯誤各自放在 out.txt、err.txt。
call() {
  python3 -c '
import json, sys
print(json.dumps({
    "session_id": "spec",
    "hook_event_name": "PreToolUse",
    "tool_name": sys.argv[1],
    "tool_input": json.loads(sys.argv[2]),
    "cwd": sys.argv[3],
}))' "$1" "$2" "${3:-${WORK}}" >"${WORK}/input.json"
  code=0
  "${HOOK}" <"${WORK}/input.json" >"${WORK}/out.txt" 2>"${WORK}/err.txt" || code=$?
}

# verdict：上一次 call 的判定，印 deny、ask、allow，或 other:<結束碼>。
verdict() {
  if [ "${code}" -eq 2 ]; then
    echo deny
  elif [ "${code}" -eq 0 ] && [ ! -s "${WORK}/out.txt" ]; then
    echo allow
  elif [ "${code}" -eq 0 ] && python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]
sys.exit(0 if data["hookEventName"] == "PreToolUse" and data["permissionDecision"] == "ask" else 1)' "${WORK}/out.txt"; then
    echo ask
  else
    echo "other:${code}"
  fi
}

# bash_call <指令> [<cwd>] [<description>]：Bash 工具的呼叫，description 預設是中文。
bash_call() {
  local input
  input="$(python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1], "description": sys.argv[2]}))' \
    "$1" "${3-在 worktree 裡跑規格}")"
  call Bash "${input}" "${2:-${WORK}}"
}

# bash_verdict <指令> [<cwd>]：印出那條 Bash 指令的判定。
bash_verdict() {
  bash_call "$@"
  verdict
}

# expect <判定> <工具> <tool_input 的 JSON>…：每一個呼叫的判定都是 <判定>；不是的印出來並失敗。
expect() {
  local want="$1" tool="$2" input got failed=0
  shift 2
  for input in "$@"; do
    call "${tool}" "${input}"
    got="$(verdict)"
    if [ "${got}" != "${want}" ]; then
      printf '%s %s => %s（預期 %s）\n' "${tool}" "${input}" "${got}" "${want}"
      failed=1
    fi
  done
  return "${failed}"
}

# expect_bash <判定> <cwd> <指令>…：同上，Bash 工具。
expect_bash() {
  local want="$1" cwd="$2" command got failed=0
  shift 2
  for command in "$@"; do
    got="$(bash_verdict "${command}" "${cwd}")"
    if [ "${got}" != "${want}" ]; then
      printf '%s => %s（預期 %s）\n' "${command}" "${got}" "${want}"
      failed=1
    fi
  done
  return "${failed}"
}

# expect_bash_step <下一步的片段> <cwd> <指令>…：每一條都被擋（deny），而且標準錯誤有 <下一步的片段>（字面比對）；不是的印出來
# 並失敗。
expect_bash_step() {
  local step="$1" cwd="$2" command got failed=0
  shift 2
  for command in "$@"; do
    bash_call "${command}" "${cwd}"
    got="$(verdict)"
    if [ "${got}" != deny ]; then
      printf '%s => %s（預期 deny）\n' "${command}" "${got}"
      failed=1
    elif ! grep -qF -- "${step}" "${WORK}/err.txt"; then
      printf '%s 被擋，但下一步沒有「%s」：\n' "${command}" "${step}"
      cat "${WORK}/err.txt"
      failed=1
    fi
  done
  return "${failed}"
}

# blocked_searches：Bash 的 grep -r x .、rg x、find . -exec grep x {} + 與 Grep 工具各呼叫一次，標準錯誤依序存成
# search-1.txt～search-4.txt。
blocked_searches() {
  local i=0 command
  for command in "grep -r x ." "rg x" "find . -exec grep x {} +"; do
    i=$((i + 1))
    bash_call "${command}"
    cp "${WORK}/err.txt" "${WORK}/search-${i}.txt"
  done
  call Grep '{"pattern": "x"}'
  cp "${WORK}/err.txt" "${WORK}/search-4.txt"
}

# commit <repo>：在 <repo> 留一個空的 commit（只有規格自己呼叫 git；hook 不呼叫）。
commit() {
  git -C "$1" -c user.name=spec -c user.email=spec@example.invalid commit -q --allow-empty -m init
}

# checkouts：在 ${WORK} 建主 checkout、它的 linked worktree、bare repo 與它的 worktree、分離 git 目錄的主 checkout 與它的
# worktree、主 checkout 裡的 submodule。
checkouts() {
  git init -q "${WORK}/main-checkout"
  commit "${WORK}/main-checkout"
  git -C "${WORK}/main-checkout" worktree add -q -b feat/linked "${WORK}/linked"
  git init -q --bare "${WORK}/bare.git"
  git -C "${WORK}/main-checkout" push -q "${WORK}/bare.git" HEAD:refs/heads/main
  git -C "${WORK}/bare.git" worktree add -q "${WORK}/bare-wt" main
  git init -q --separate-git-dir="${WORK}/separate.git" "${WORK}/separate"
  commit "${WORK}/separate"
  git -C "${WORK}/separate" worktree add -q -b feat/sep "${WORK}/separate-wt"
  git init -q "${WORK}/lib"
  commit "${WORK}/lib"
  git -C "${WORK}/main-checkout" -c protocol.file.allow=always submodule add -q "${WORK}/lib" sub
}

# ── 第 1 點：docker 先問 ──────────────────────────────────────────────────

@test "docker ps 回傳 ask" {
  [ "$(bash_verdict "docker ps")" = ask ]
}

@test "cd x && ./script/test.sh --lint 回傳 ask" {
  [ "$(bash_verdict "cd x && ./script/test.sh --lint")" = ask ]
}

@test "bash script/run.sh 回傳 ask" {
  [ "$(bash_verdict "bash script/run.sh")" = ask ]
}

@test "子目錄裡的入口 script/hooks/pre/run.sh 回傳 ask" {
  [ "$(bash_verdict "script/hooks/pre/run.sh")" = ask ]
}

@test "just docker run 回傳 ask" {
  [ "$(bash_verdict "just docker run")" = ask ]
}

@test "just test 回傳 ask" {
  [ "$(bash_verdict "just test")" = ask ]
}

@test "命令列模式的 script/check_file.sh src/a.py 回傳 ask" {
  [ "$(bash_verdict "script/check_file.sh src/a.py")" = ask ]
}

@test "just setup hooks 不問" {
  [ "$(bash_verdict "just setup hooks")" = allow ]
}

@test "放在 &&、||、;、| 後面、指令替換裡、變數設定後面、以路徑或變數前綴呼叫的入口都回傳 ask" {
  run expect_bash ask "${WORK}" \
    "ls && docker ps" \
    "false || docker compose ps" \
    "ls; just docker build" \
    "printf x | docker load" \
    "echo \"\$(docker ps -q)\"" \
    "CM_TEST_LOCAL=1 ./script/test.sh" \
    "env CM_TEST_LOCAL=1 script/test.sh --lint" \
    "\"\${REPO}\"/script/test.sh --lint" \
    "/usr/local/bin/docker ps" \
    "sudo docker ps" \
    "sh -c './script/stop.sh'" \
    "cd script && ./release.sh v1.0.0" \
    "just --justfile justfile test lint" \
    "just docker::run" \
    "docker-compose ps"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "ask 的原因指名入口、寫明 docker 先問" {
  bash_call "just test"

  grep -q '"permissionDecisionReason": "env-rules: docker 先問（#412）：.*（just test）' "${WORK}/out.txt"
}

@test "不執行 docker 的指令不問：command -v docker、提到 docker 的 grep 與 commit 訊息、just 的其他 recipe" {
  run expect_bash allow "${WORK}" \
    "command -v docker" \
    "grep -n docker README.md" \
    "git commit -m 'docker ps 先問'" \
    "just" \
    "just setup hooks-off" \
    "ls script/test.sh"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "讀不到入口清單時擋下並寫出下一步" {
  mkdir -p "${WORK}/hooks"
  cp "${HOOK}" "${REPO_ROOT}/script/claude-hooks/shell-parse.sh" "${WORK}/hooks/"
  HOOK="${WORK}/hooks/env-rules.sh"
  bash_call "docker ps"

  [ "$(verdict)" = deny ]
  grep -q "下一步：" "${WORK}/err.txt"
}

# ── 第 3 點：cm_verify ────────────────────────────────────────────────────

@test "docker compose -p cm_verify_x down 被擋（deny），不是 ask" {
  bash_call "docker compose -p cm_verify_x down"

  [ "$(verdict)" = deny ]
}

@test "just docker stop cm_verify_x 被擋（deny）" {
  bash_call "just docker stop cm_verify_x"

  [ "$(verdict)" = deny ]
}

@test "COMPOSE_PROJECT_NAME=cm_verify_x script/stop.sh 被擋（deny），下一步寫不碰 cm_verify_* 驗證環境" {
  bash_call "COMPOSE_PROJECT_NAME=cm_verify_x script/stop.sh"

  [ "$(verdict)" = deny ]
  grep -qF "${STEP_VERIFY}" "${WORK}/err.txt"
}

@test "不是入口的指令提到 cm_verify 不擋（依連接埠連進驗證環境這類擋不住）" {
  [ "$(bash_verdict "echo cm_verify_x")" = allow ]
}

# ── 第 4 點：token 檔 ─────────────────────────────────────────────────────

@test "Read ../api token.md 被擋" {
  call Read '{"file_path": "../api token.md"}'

  [ "$(verdict)" = deny ]
}

@test "Bash 的 cat \"~/x/My Token.md\" 被擋" {
  [ "$(bash_verdict 'cat "~/x/My Token.md"')" = deny ]
}

@test "Glob 的 pattern 是 **/*token*.md 被擋" {
  call Glob '{"pattern": "**/*token*.md"}'

  [ "$(verdict)" = deny ]
}

@test "Read doc/README.md 放行" {
  call Read '{"file_path": "doc/README.md"}'

  [ "$(verdict)" = allow ]
}

@test "指名的路徑不分大小寫：Read doc/API-Token.md 被擋" {
  call Read '{"file_path": "doc/API-Token.md"}'

  [ "$(verdict)" = deny ]
}

@test "Edit、Write 指名 token 檔也被擋" {
  run expect deny Edit '{"file_path": "/x/git token.md", "old_string": "a", "new_string": "b"}'
  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
  run expect deny Write '{"file_path": "notes/Token.MD", "content": "x"}'
  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "Grep 工具一律擋：沒有 glob、glob 是 md 或不是寫死的副檔名、只給 type、path 不是 repo 裡的相對路徑的都被擋" {
  run expect deny Grep \
    '{"pattern": "ghp_"}' \
    '{"pattern": "ghp_", "glob": "**/*.md"}' \
    '{"pattern": "ghp_", "glob": "*.{py,md}"}' \
    '{"pattern": "ghp_", "type": "py"}' \
    '{"pattern": "ghp_", "path": "..", "glob": "**/*.py"}' \
    '{"pattern": "ghp_", "path": "/tmp", "glob": "**/*.py"}' \
    '{"pattern": "ghp_", "path": "src/a.py"}' \
    '{"pattern": "ghp_", "path": "~/x", "glob": "**/*.py"}' \
    '{"pattern": "ghp_", "glob": "*.p[y]"}' \
    '{"pattern": "ghp_", "glob": "!*.py"}' \
    '{"pattern": "ghp_", "glob": "*.*"}'

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "Grep 被擋時下一步寫要讀單一檔案就用 Read" {
  call Grep '{"pattern": "ghp_", "path": "src/a.py"}'

  grep -qF "${STEP_READ}" "${WORK}/err.txt"
}

@test "Grep 工具一律擋：原本放行的 glob 寫死不是 md 的副檔名、path 是 repo 裡的目錄或檔案也被擋（#412 本文 11/25 改，照 Q8）" {
  run expect deny Grep \
    '{"pattern": "ghp_", "path": "src", "glob": "**/*.py"}' \
    '{"pattern": "ghp_", "path": "src/a.py", "glob": "**/*.py"}' \
    '{"pattern": "ghp_", "glob": "*.sh"}'

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "Glob：**/*、**/*.md、**/*.sh 放行（只回傳路徑）" {
  run expect allow Glob '{"pattern": "**/*"}' '{"pattern": "**/*.md"}' '{"pattern": "**/*.sh", "path": "script"}'

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "Bash 的遞迴搜尋：grep -r、--include 的 grep -r、rg、rg -t、find -exec grep 都被擋，下一步寫要讀單一檔案就用 Read" {
  run expect_bash deny "${WORK}" \
    "grep -r ghp_ ." \
    "grep -r --include='*.py' x src" \
    "rg ghp_" \
    "rg -t py x" \
    "find . -name '*' -exec grep ghp_ {} +"
  [ "${status}" -eq 0 ] || { echo "${output}"; false; }

  bash_call "grep -r ghp_ ."
  grep -qF "${STEP_READ}" "${WORK}/err.txt"
}

@test "Bash 的遞迴搜尋與 Grep 被擋時，下一步不再叫人改用 Grep 工具" {
  bash_call "rg ghp_"
  cp "${WORK}/err.txt" "${WORK}/err-bash.txt"
  call Grep '{"pattern": "ghp_", "glob": "*.py"}'

  [ -s "${WORK}/err-bash.txt" ]
  [ -s "${WORK}/err.txt" ]
  run grep -qF "改用 Grep 工具" "${WORK}/err-bash.txt" "${WORK}/err.txt"

  [ "${status}" -eq 1 ]
}

@test "Bash 的其他遞迴寫法也被擋：-R、連寫的 -rn、--recursive、-d recurse、xargs grep" {
  run expect_bash deny "${WORK}" \
    "grep -R x ." \
    "grep -rn x src" \
    "grep --recursive x ." \
    "grep -d recurse x ." \
    "git ls-files | xargs grep x"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "Bash 搜尋指名的檔、-e 的值是 r 時不擋" {
  run expect_bash allow "${WORK}" "grep -n x README.md" "grep -e r README.md" "find . -name '*.py'"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

# ── 第 4 點：跨檔搜尋用 git grep（#426） ─────────────────────────────────

@test "git grep 帶 --no-index、--untracked 與它們的縮寫被擋（含 git -C、find -exec、sudo、caffeinate 執行的），下一步有跨檔搜尋內容用 git grep（#426）" {
  run expect_bash_step "${STEP_GIT_GREP}" "${WORK}" \
    "git grep --no-index x" \
    "git grep --untracked x" \
    "git grep --untrack x" \
    "git grep --no-ind x" \
    "git -C .. grep --no-index x" \
    "find . -exec git grep --untracked x {} +" \
    "sudo git grep --no-index x" \
    "caffeinate git grep --no-index x"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "縮寫到 --n、--u，寫在 -e 的值後面、連寫在 -O 後面，經 doas、watch、stdbuf、unbuffer 與 env、nice、timeout、nohup 執行的 git grep --no-index、--untracked 也被擋（#426）" {
  run expect_bash_step "${STEP_GIT_GREP}" "${WORK}" \
    "git grep --n x" \
    "git grep --u x" \
    "git grep -n -e x --untracked" \
    "git grep -Oe --no-index x" \
    "doas git grep --untracked x" \
    "watch git grep --no-index x" \
    "stdbuf -oL git grep --no-index x" \
    "unbuffer git grep --untracked x" \
    "env git grep --no-index x" \
    "nice git grep --no-index x" \
    "timeout 5 git grep --untracked x" \
    "nohup git grep --no-index x"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "經 xargs、parallel 執行的 git grep 一律被擋，下一步有不經 xargs、parallel，直接下 git grep（#426）" {
  run expect_bash_step "${STEP_RUNNER}" "${WORK}" \
    "xargs git grep -n x" \
    "xargs git grep --no-index x" \
    "parallel git grep -n x ::: src"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "git 的全域選項或子指令來自 shell 展開的 git \$OPTS grep x、git \$SUB --no-index x 被擋，下一步有 git 的選項與子指令寫成字面（#426）" {
  run expect_bash_step "${STEP_LITERAL}" "${WORK}" \
    'git $OPTS grep x' \
    'git $SUB --no-index x'

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "改 git 設定的 git -c、--config-env 與 GIT_CONFIG 開頭的變數設定（含 env 後面的）加在 git grep 前面被擋，下一步有前面不加這些設定（#426）" {
  run expect_bash_step "${STEP_CONFIG}" "${WORK}" \
    "git -c grep.fallbackToNoIndex=true grep x" \
    "git -c color.ui=never grep -n x" \
    "git --config-env=grep.fallbackToNoIndex=V grep x" \
    "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=grep.fallbackToNoIndex GIT_CONFIG_VALUE_0=true git grep x" \
    "env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=grep.fallbackToNoIndex GIT_CONFIG_VALUE_0=true git grep x"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "不帶這些寫法的 git grep 放行：grep 的計數選項 -c、-e 的值與 -- 之後的字不算，sudo 執行的照同樣的規則（#426）" {
  run expect_bash allow "${WORK}" \
    "git grep -n x" \
    "git grep -n x -- '*.py'" \
    "git -C ../wt grep -n x" \
    "git grep -c x" \
    "git grep -n -e --no-index" \
    "git grep -n x -- --untracked" \
    "sudo git grep -n x"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "-f 的值、連寫的 -ne 的值、不是 --no-index 前綴的 --null 與 --name-only、--no-untracked，與 grep 以外的 git 子指令前面的 -c、GIT_CONFIG 放行（#426）" {
  run expect_bash allow "${WORK}" \
    "git grep -n -f --untracked" \
    "git grep -ne --no-index" \
    "git grep --null -l x" \
    "git grep --name-only x" \
    "git grep --no-untracked x" \
    'git $OPTS log -n 1' \
    "git -c color.ui=never log -n 1" \
    "GIT_CONFIG_COUNT=0 git log -n 1"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "find -exec、sudo 執行的 git grep 照直接下 git grep 的規則：find . -exec git grep -n x {} +、sudo git grep -r x 放行，不再當成 find、sudo 執行的 grep（#426）" {
  run expect_bash allow "${WORK}" \
    "find . -exec git grep -n x {} +" \
    "sudo git grep -r x"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "grep -r、rg、find -exec grep 與 Grep 工具被擋時，下一步同時有要讀單一檔案就用 Read 與跨檔搜尋內容用 git grep（#426）" {
  local file failed=0
  blocked_searches

  for file in "${WORK}"/search-[1-4].txt; do
    if ! grep -qF "${STEP_READ}" "${file}" || ! grep -qF "${STEP_GIT_GREP}" "${file}"; then
      printf '%s 的下一步少了其中一句：\n' "${file##*/}"
      cat "${file}"
      failed=1
    fi
  done
  [ "${failed}" -eq 0 ]
}

@test "grep -r、rg、find -exec grep 與 Grep 工具被擋時，下一步沒有不分種類的「Bash 的遞迴搜尋一律擋」（#426）" {
  local file failed=0
  blocked_searches

  for file in "${WORK}"/search-[1-4].txt; do
    if [ ! -s "${file}" ] || grep -qF "Bash 的遞迴搜尋一律擋" "${file}"; then
      printf '%s 是空的，或下一步還有不分種類的那句：\n' "${file##*/}"
      cat "${file}"
      failed=1
    fi
  done
  [ "${failed}" -eq 0 ]
}

@test "grep -r、rg、find -exec grep 與 Grep 工具被擋時，hook 印的下一步裡沒有日期與工作階段的清單（#426）" {
  local file steps failed=0
  blocked_searches

  for file in "${WORK}"/search-[1-4].txt; do
    steps="$(sed -n '/下一步：/,$p' "${file}")"
    if [ -z "${steps}" ] || printf '%s\n' "${steps}" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}|工作階段'; then
      printf '%s 沒有下一步，或下一步裡有日期或工作階段：\n' "${file##*/}"
      cat "${file}"
      failed=1
    fi
  done
  [ "${failed}" -eq 0 ]
}

@test "git grep 要搜的字串是含 token 的 .md 檔名（git grep -n 'token*.md'）時照 token 檔的規則被擋（#426）" {
  [ "$(bash_verdict "git grep -n 'token*.md'")" = deny ]
}

@test "git grep 改搜不含副檔名的片段 git grep -n 'token\\*' 放行（#426）" {
  [ "$(bash_verdict "git grep -n 'token\\*'")" = allow ]
}

# ── 第 4 點：看不出內容的 git 寫法與 git grep -O（#436） ─────────────────

@test "git grep 的參數來自 shell 展開（會拆成好幾個字的，與展開前的字面部分看不出是不是選項的）被擋，下一步有 git grep 的選項寫成字面（#436）" {
  run expect_bash_step "${STEP_GREP_ARGS}" "${WORK}" \
    'git grep $OPTS x' \
    'git grep "$@"' \
    'git grep -n "$PATTERN"' \
    'git grep -n x "$DIR"' \
    'git grep -n"$X" x' \
    'git grep -n -e $P' \
    'git grep -n -e "$@"' \
    'git grep -n x src/$DIR' \
    'git grep -n foo$X' \
    'git grep -n x src/*.py' \
    'git grep -n x {--untracked,.}' \
    'git grep -n x src/{a,b}.py' \
    'git grep -C "$N" x' \
    'sudo git grep $OPTS x'

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "會拆成好幾個字的其他展開當 -e 的值也被擋：沒加雙引號的指令替換、反引號、算術展開，雙引號裡的 \"\${A[@]}\" 這類陣列與 zsh 的寫法，萬用字元 ? 與 [，{1..3}（#436）" {
  run expect_bash_step "${STEP_GREP_ARGS}" "${WORK}" \
    'git grep -e $(cat p)' \
    'git grep -e `cat p`' \
    'git grep -e $((1 + 1))' \
    'git grep -e "${A[@]}"' \
    'git grep -e "${@}"' \
    'git grep -e "${A[@]:1}"' \
    'git grep -e "${!A[@]}"' \
    'git grep -e "${(@)A}"' \
    'git grep -e "$A[@]"' \
    'git grep -e x?' \
    'git grep -e [ab]' \
    'git grep -e {1..3}'

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "不會拆成好幾個字的寫法當 -e、-f 的值放行：\$'…'、~使用者、程序替換、雙引號裡的 \"\$*\" 與 \"\${A}\"、加了引號或跳脫的大括號、沒有 , 或 .. 的大括號（#436）" {
  run expect_bash allow "${WORK}" \
    "git grep -n -e \$'\\t'" \
    'git grep -n -e ~bob' \
    'git grep -n -f <(printf x)' \
    'git grep -n -e "$*"' \
    'git grep -n -e "${A}"' \
    "git grep -n -e '{a,b}'" \
    'git grep -n -e "{a,b}"' \
    'git grep -n -e \{a,b\}' \
    'git grep -n -e {a}' \
    'git grep -n -e {}'

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "確定不會變成選項、也不會拆字的展開放行：-e、-f 的值，-- 之後的字，字面部分不以 - 開頭，--名稱=\"\$值\"，-C、-m 連寫的值，git -C \"\$DIR\"（#436）" {
  run expect_bash allow "${WORK}" \
    'git grep -n -e "$PATTERN"' \
    'git grep -n -e"$PATTERN"' \
    "git grep -n -e \$'\\t'" \
    'git grep -n -f "$FILE"' \
    'git grep -n x -- "$DIR"' \
    'git grep -n x -- $DIR' \
    'git grep -n x -- src/*.py' \
    'git grep -n x src/"$DIR"' \
    'git grep --max-depth="$N" x' \
    'git grep -C"$N" x' \
    'git grep -m"$N" x' \
    'git -C "$DIR" grep -n x'

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test ".claude/settings.json 的 permissions.deny 有 Read(//**/*token*.md)" {
  run python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
print("Read(//**/*token*.md)" in settings.get("permissions", {}).get("deny", []))' "${REPO_ROOT}/.claude/settings.json"

  [ "${output}" = True ]
}

# ── 第 5 點：主 checkout 不切分支 ─────────────────────────────────────────

@test "主 checkout 裡的 git switch main 被擋，下一步寫改到 worktree 裡做" {
  checkouts
  bash_call "git switch main" "${WORK}/main-checkout"

  [ "$(verdict)" = deny ]
  grep -qF "${STEP_WORKTREE}" "${WORK}/err.txt"
}

@test "cd 或 git -C 指到主 checkout 的切換分支被擋（-C 以 cd 之後的目錄解析）" {
  checkouts
  run expect_bash deny "${WORK}/linked" \
    "cd ../main-checkout && git checkout feat/x" \
    "git -C ../main-checkout switch feat/x" \
    "cd .. && git -C main-checkout switch feat/x" \
    "git -C .. -C main-checkout checkout -b feat/y"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "判斷不了目錄的 cd \"\$X\" && git switch feat/x 被擋，下一步寫改到 worktree 裡做，或寫明目錄" {
  checkouts
  bash_call 'cd "$X" && git switch feat/x' "${WORK}/linked"

  [ "$(verdict)" = deny ]
  grep -qF "${STEP_DIR}" "${WORK}/err.txt"
}

@test "子 shell 裡的 cd、cd -、git -C 的目錄來自變數時，切換分支被擋" {
  checkouts
  run expect_bash deny "${WORK}/linked" \
    "(cd ../linked && git switch feat/x)" \
    "cd - && git switch feat/x" \
    "git -C \"\$X\" switch feat/x" \
    "GIT_DIR=../main-checkout/.git git switch feat/x"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test ".git 檔指向的管理目錄沒有 commondir（submodule）的目錄裡，git switch feat/x 被擋" {
  checkouts
  bash_call "git switch feat/x" "${WORK}/main-checkout/sub"

  [ "$(verdict)" = deny ]
}

@test "分離 git 目錄的主 checkout（.git 是檔，管理目錄沒有 commondir）裡切換分支被擋" {
  checkouts
  bash_call "git switch feat/x" "${WORK}/separate"

  [ "$(verdict)" = deny ]
}

@test "一般 clone、bare repo、分離 git 目錄建出來的 linked worktree 裡 git switch feat/x 放行" {
  checkouts
  run expect_bash allow "${WORK}/linked" "git switch feat/x"
  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
  run expect_bash allow "${WORK}/bare-wt" "git switch feat/x"
  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
  run expect_bash allow "${WORK}/separate-wt" "git switch feat/x"
  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "主 checkout 裡 git checkout -- a.txt、git worktree add、git status 放行" {
  checkouts
  run expect_bash allow "${WORK}/main-checkout" \
    "git checkout -- a.txt" \
    "git checkout main -- a.txt" \
    "git worktree add -b feat/z ../z origin/main" \
    "git status"

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "從 worktree 用 git -C 指到另一個 worktree 切換分支放行" {
  checkouts
  [ "$(bash_verdict "git -C ../bare-wt switch feat/x" "${WORK}/linked")" = allow ]
}

@test "不呼叫 git：PATH 上的 git 換成記錄呼叫的假程式，判定相同、假 git 被呼叫 0 次" {
  checkouts
  mkdir -p "${WORK}/fake"
  printf '#!/bin/sh\necho "$*" >>"%s"\nexit 1\n' "${WORK}/git-calls.log" >"${WORK}/fake/git"
  chmod +x "${WORK}/fake/git"
  PATH="${WORK}/fake:${PATH}" run expect_bash deny "${WORK}/main-checkout" "git switch main"
  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
  PATH="${WORK}/fake:${PATH}" run expect_bash allow "${WORK}/linked" "git switch feat/x"
  [ "${status}" -eq 0 ] || { echo "${output}"; false; }

  [ ! -e "${WORK}/git-calls.log" ]
}

# ── 第 6 點：指令說明要中文 ───────────────────────────────────────────────

@test "description 是英文時被擋，下一步寫用繁體中文寫指令說明" {
  bash_call "ls" "${WORK}" "List files"

  [ "$(verdict)" = deny ]
  grep -qF "${STEP_DESCRIPTION}" "${WORK}/err.txt"
}

@test "description 是中文時放行" {
  bash_call "ls" "${WORK}" "列出檔案"

  [ "$(verdict)" = allow ]
}

@test "沒有 description 時被擋" {
  call Bash '{"command": "ls"}'

  [ "$(verdict)" = deny ]
}

# ── 讀不到輸入、讀不懂指令 ────────────────────────────────────────────────

@test "讀不到 hook 輸入（空的、不是 JSON）、讀不懂指令的結構時擋下並寫出下一步" {
  code=0
  "${HOOK}" </dev/null >"${WORK}/out.txt" 2>"${WORK}/err.txt" || code=$?
  [ "$(verdict)" = deny ]
  printf 'not json' | "${HOOK}" >"${WORK}/out.txt" 2>"${WORK}/err.txt" || code=$?
  [ "$(verdict)" = deny ]

  bash_call "docker ps 'unterminated"
  [ "$(verdict)" = deny ]
  grep -q "下一步：" "${WORK}/err.txt"
}

@test "其他工具的呼叫放行" {
  call WebFetch '{"url": "https://example.invalid/token.md", "prompt": "x"}'

  [ "$(verdict)" = allow ]
}

# ── 接線與設定 ────────────────────────────────────────────────────────────

@test ".claude/settings.json 以 PreToolUse 的 Bash matcher 與 Read|Edit|Write|Grep|Glob matcher 呼叫 env-rules.sh" {
  run python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
found = []
for entry in settings.get("hooks", {}).get("PreToolUse", []):
    for hook in entry.get("hooks", []):
        if hook.get("type") == "command" and "script/claude-hooks/env-rules.sh" in hook.get("command", ""):
            found.append(entry.get("matcher"))
print(" ".join(sorted(found)))' "${REPO_ROOT}/.claude/settings.json"

  [ "${output}" = "Bash Read|Edit|Write|Grep|Glob" ]
}

@test "照 .claude/settings.json 實際註冊的那一行命令執行，docker ps 回傳 ask、Read 指名 token 檔被擋" {
  local line
  line="$(python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in settings["hooks"]["PreToolUse"]:
    for hook in entry["hooks"]:
        if "env-rules.sh" in hook["command"]:
            print(hook["command"])
            raise SystemExit' "${REPO_ROOT}/.claude/settings.json")"
  printf '#!/bin/sh\nCLAUDE_PROJECT_DIR="%s" exec sh -c '"'"'%s'"'"'\n' "${REPO_ROOT}" "${line}" >"${WORK}/registered.sh"
  chmod +x "${WORK}/registered.sh"
  HOOK="${WORK}/registered.sh"

  bash_call "docker ps"
  [ "$(verdict)" = ask ]
  call Read '{"file_path": "../api token.md"}'
  [ "$(verdict)" = deny ]
}

@test "設定和 hook 裡沒有本機絕對路徑或使用者名稱" {
  run grep -nE '/Users/|/home/|/private/(var|tmp)/|/var/folders/|[A-Za-z]:\\\\Users|~[A-Za-z0-9_]+/' \
    "${REPO_ROOT}/.claude/settings.json" "${REPO_ROOT}"/script/claude-hooks/*

  [ "${status}" -eq 1 ]
}
