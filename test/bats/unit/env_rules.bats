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
  STEP_SEARCH="改用 Grep 工具"
  STEP_GREP="加上副檔名寫死、不是 .md 的 glob"
  STEP_WORKTREE="改到 worktree 裡做"
  STEP_DIR="改到 worktree 裡做，或寫明目錄"
  STEP_VERIFY="不碰 cm_verify_* 驗證環境"
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
  grep -q "${STEP_VERIFY}" "${WORK}/err.txt"
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

@test "Grep：沒有 glob、glob 是 md 或不是寫死的副檔名、只給 type、path 不是 repo 裡的相對路徑的都被擋" {
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

@test "Grep 被擋時下一步寫加上副檔名寫死、不是 .md 的 glob" {
  call Grep '{"pattern": "ghp_", "path": "src/a.py"}'

  grep -q "${STEP_GREP}" "${WORK}/err.txt"
}

@test "Grep：path 是目錄或檔案、glob 寫死不是 md 的副檔名時放行（條件相同、結果相同）" {
  run expect allow Grep \
    '{"pattern": "ghp_", "path": "src", "glob": "**/*.py"}' \
    '{"pattern": "ghp_", "path": "src/a.py", "glob": "**/*.py"}' \
    '{"pattern": "ghp_", "glob": "*.sh"}'

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "Glob：**/*、**/*.md、**/*.sh 放行（只回傳路徑）" {
  run expect allow Glob '{"pattern": "**/*"}' '{"pattern": "**/*.md"}' '{"pattern": "**/*.sh", "path": "script"}'

  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "Bash 的遞迴搜尋：grep -r、--include 的 grep -r、rg、rg -t、find -exec grep 都被擋，下一步寫改用 Grep 工具" {
  run expect_bash deny "${WORK}" \
    "grep -r ghp_ ." \
    "grep -r --include='*.py' x src" \
    "rg ghp_" \
    "rg -t py x" \
    "find . -name '*' -exec grep ghp_ {} +"
  [ "${status}" -eq 0 ] || { echo "${output}"; false; }

  bash_call "grep -r ghp_ ."
  grep -q "${STEP_SEARCH}" "${WORK}/err.txt"
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
  grep -q "${STEP_WORKTREE}" "${WORK}/err.txt"
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
  grep -q "${STEP_DIR}" "${WORK}/err.txt"
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

