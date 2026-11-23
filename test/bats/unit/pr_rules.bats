#!/usr/bin/env bats
#
# script/claude-hooks/pr-rules.sh —— Claude Code 的 PreToolUse hook：agent 不合併、PR 描述要綁一張本 repo 的 issue、
# 一律先開草稿 PR（T19、#408）。
#
# hook 在主機上跑，只讀工具呼叫的輸入：標準輸入那份 JSON 裡的工具名稱、指令文字與 cwd，以及指令帶入的檔；本 repo 的
# 身分讀 cwd 那個簽出的 git 設定（remote）。看不到該看的內容就擋下並寫出下一步（Q8）。
#
# 測的是公開行為：照 Claude Code 給 hook 的形狀把 JSON 餵進標準輸入，看結束碼（2 是擋下）與訊息。
# 本 repo 的身分用替身：${WORK} 是一個 origin 指到 https://github.com/o/r.git 的 git repo，所以 o/r 就是本 repo。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  HOOK="${REPO_ROOT}/script/claude-hooks/pr-rules.sh"
  ATTRIBUTION="${REPO_ROOT}/script/claude-hooks/no-attribution.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  NL=$'\n'
  git -C "${WORK}" init -q
  git -C "${WORK}" remote add origin https://github.com/o/r.git
  STEP_MERGE="合併由 CI 的 merge job 執行，檢查全過會自己合併；卡住就查 merge job 的紀錄並回報，不要自己合併"
  STEP_BIND="先開審過的 issue，再在描述寫 Closes #N"
  STEP_ATTACH="附件在網頁上加，或把附件的網址直接寫進 --body-file 的內文；描述一律用 --body-file 送出"
}

teardown() {
  rm -rf "${WORK}"
}

# input <指令文字>：照 Claude Code 給 PreToolUse hook 的形狀寫出 JSON（Bash 工具），cwd 是 ${WORK}。
input() {
  python3 -c '
import json, sys
print(json.dumps({
    "session_id": "spec",
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[1], "description": "spec"},
    "cwd": sys.argv[2],
}))' "$1" "${WORK}" >"${WORK}/input.json"
}

# hook <指令文字>：把 Bash 工具的輸入餵給 pr-rules.sh。
hook() {
  input "$1"
  run "${HOOK}" <"${WORK}/input.json"
}

# tool <工具名稱> <tool_input 的 JSON>：把別的工具（例如 MCP 工具）的輸入餵給 pr-rules.sh。
tool() {
  python3 -c '
import json, sys
print(json.dumps({
    "session_id": "spec",
    "hook_event_name": "PreToolUse",
    "tool_name": sys.argv[1],
    "tool_input": json.loads(sys.argv[2]),
    "cwd": sys.argv[3],
}))' "$1" "$2" "${WORK}" >"${WORK}/input.json"
  run "${HOOK}" <"${WORK}/input.json"
}

# body <檔名> <內容>：在 ${WORK} 底下寫一個要帶入的檔。
body() {
  printf '%s\n' "$2" >"${WORK}/$1"
}

# ── 第 1 點：agent 不合併 ─────────────────────────────────────────────────

@test "gh pr merge 12 以 2 擋下，下一步寫合併由 CI 的 merge job 執行" {
  hook "gh pr merge 12"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_MERGE}"* ]]
}

@test "gh pr merge 12 --merge 以 2 擋下並寫出下一步" {
  hook "gh pr merge 12 --merge"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_MERGE}"* ]]
}

@test "gh pr merge 12 --auto 以 2 擋下並寫出下一步" {
  hook "gh pr merge 12 --auto"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_MERGE}"* ]]
}

@test "gh pr merge 12 --admin --squash 以 2 擋下並寫出下一步" {
  hook "gh pr merge 12 --admin --squash"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_MERGE}"* ]]
}

@test "gh pr merge --disable-auto 也以 2 擋下：不看參數" {
  hook "gh pr merge 12 --disable-auto"

  [ "${status}" -eq 2 ]
}

@test "放在 && 後面的 gh pr merge 也以 2 擋下" {
  hook "git fetch && gh pr merge 12 --merge"

  [ "${status}" -eq 2 ]
}

@test "放在 bash -c 裡的 gh pr merge 也以 2 擋下" {
  hook "bash -c 'gh pr merge 12'"

  [ "${status}" -eq 2 ]
}

@test "交給 xargs 執行的 gh pr merge 也以 2 擋下" {
  hook "echo 12 | xargs gh pr merge"

  [ "${status}" -eq 2 ]
}

@test "gh -R 寫在子指令前面的 gh pr merge 也以 2 擋下" {
  hook "gh pr -R o/r merge 12"

  [ "${status}" -eq 2 ]
}

@test "commit 訊息裡提到 gh pr merge 不是合併，放行" {
  hook "git commit -m \"chore(hooks): 擋下 gh pr merge\""

  [ "${status}" -eq 0 ]
}

@test "gh api -X PUT 寫入 pulls/12/merge 以 2 擋下並寫出下一步" {
  hook "gh api -X PUT repos/o/r/pulls/12/merge"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_MERGE}"* ]]
}

@test "沒寫 -X、帶了欄位的 gh api 是隱含的 POST：寫入 pulls/12/merge 以 2 擋下" {
  hook "gh api repos/o/r/pulls/12/merge -f merge_method=merge"

  [ "${status}" -eq 2 ]
}

@test "完整網址的 pulls/12/merge 以 --method PUT 寫入也以 2 擋下" {
  hook "gh api --method PUT https://api.github.com/repos/o/r/pulls/12/merge"

  [ "${status}" -eq 2 ]
}

@test "讀取 pulls/12/merge（GET，查有沒有合併）放行" {
  hook "gh api repos/o/r/pulls/12/merge"

  [ "${status}" -eq 0 ]
}

@test "gh api graphql 的 -f query= 含 mergePullRequest 以 2 擋下並寫出下一步" {
  hook "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_MERGE}"* ]]
}

@test "gh api graphql 的 --field query= 含 mergePullRequest 以 2 擋下" {
  hook "gh api graphql --field query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'"

  [ "${status}" -eq 2 ]
}

@test "gh api graphql -F query=@q.graphql，檔裡含 enablePullRequestAutoMerge 以 2 擋下" {
  body q.graphql "mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }"

  hook "gh api graphql -F query=@q.graphql"

  [ "${status}" -eq 2 ]
}

@test "gh api graphql --input j.json，query 欄位含 enqueuePullRequest 以 2 擋下" {
  python3 -c 'import json; print(json.dumps({"query": "mutation { enqueuePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"}))' >"${WORK}/j.json"

  hook "gh api graphql --input j.json"

  [ "${status}" -eq 2 ]
}

@test "gh api graphql --input - 從標準輸入讀查詢，以 2 擋下，下一步寫把查詢寫在 -f query= 或檔案裡" {
  hook "gh api graphql --input -"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"把查詢寫在 -f query= 或檔案裡"* ]]
}

@test "gh api graphql -F query=@- 從標準輸入讀查詢，以 2 擋下" {
  hook "gh api graphql -F query=@-"

  [ "${status}" -eq 2 ]
}

@test "gh api graphql --input bad.json 的 JSON 無法解析，以 2 擋下並寫出下一步" {
  printf '{"query": \n' >"${WORK}/bad.json"

  hook "gh api graphql --input bad.json"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"把查詢寫在 -f query= 或檔案裡"* ]]
}

@test "gh api graphql --input 的 JSON 裡沒有字串的 query，以 2 擋下" {
  printf '{"variables": {}}\n' >"${WORK}/j.json"

  hook "gh api graphql --input j.json"

  [ "${status}" -eq 2 ]
}

@test "gh api graphql -F query=@<檔>，讀不到那個檔時以 2 擋下" {
  hook "gh api graphql -F query=@missing.graphql"

  [ "${status}" -eq 2 ]
}

@test "gh api graphql 的查詢來自 shell 變數時以 2 擋下" {
  hook "gh api graphql -f query=\"\$Q\""

  [ "${status}" -eq 2 ]
}

@test "gh api graphql 的查詢來自指令替換時以 2 擋下" {
  hook "gh api graphql -f query=\"\$(cat q.graphql)\""

  [ "${status}" -eq 2 ]
}

@test "只讀的 gh api graphql 查詢放行" {
  hook "gh api graphql -f query='query { viewer { login } }'"

  [ "${status}" -eq 0 ]
}

@test "gh pr view 12 放行" {
  hook "gh pr view 12"

  [ "${status}" -eq 0 ]
}

@test "gh pr checks 12 放行" {
  hook "gh pr checks 12"

  [ "${status}" -eq 0 ]
}

@test "gh run rerun <run> --failed 放行" {
  hook "gh run rerun 45122748820 --failed"

  [ "${status}" -eq 0 ]
}

@test "以 mcp__ccd_pr__set_auto_merge 這個工具名稱餵輸入時以 2 擋下，下一步寫合併由 CI 的 merge job 執行" {
  tool mcp__ccd_pr__set_auto_merge '{"enabled": true}'

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_MERGE}"* ]]
}

@test "mcp__ccd_pr__set_auto_merge 不看輸入：關掉自動合併的輸入、空的輸入都以 2 擋下" {
  tool mcp__ccd_pr__set_auto_merge '{"enabled": false}'
  first="${status}"
  tool mcp__ccd_pr__set_auto_merge '{}'

  [ "${first}" -eq 2 ]
  [ "${status}" -eq 2 ]
}

# ── 第 2 點：PR 描述要綁一張本 repo 的 issue ──────────────────────────────

@test "gh pr create --draft --body-file f，f 沒有關閉關鍵字時以 2 擋下，下一步寫先開 issue 再寫 Closes #N" {
  body f.md "## 摘要${NL}內容"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_BIND}"* ]]
}

@test "gh pr create --draft --body-file f，f 有 Closes #12 時放行" {
  body f.md "Closes #12${NL}${NL}## 摘要"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "gh pr edit 12 --body-file f，f 沒有關閉關鍵字時以 2 擋下" {
  body f.md "## 摘要${NL}內容"

  hook "gh pr edit 12 --body-file f.md"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_BIND}"* ]]
}

@test "gh pr edit 12 --body-file f，f 有 Closes #12 時放行" {
  body f.md "Closes #12"

  hook "gh pr edit 12 --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "gh pr edit 12 --body 直接寫描述、沒有關閉關鍵字時以 2 擋下" {
  hook "gh pr edit 12 --body '只有摘要'"

  [ "${status}" -eq 2 ]
}

@test "沒有改描述的 gh pr edit（只改標籤）放行" {
  hook "gh pr edit 12 --add-label backlog"

  [ "${status}" -eq 0 ]
}

@test "gh pr create --draft --fill 看不到描述，以 2 擋下，下一步寫改用 --body-file" {
  hook "gh pr create --draft --fill"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"改用 --body-file"* ]]
}

@test "沒帶描述的 gh pr create --draft 會跳提示，以 2 擋下，下一步寫改用 --body-file" {
  hook "gh pr create --draft --title t"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"改用 --body-file"* ]]
}

@test "沒有任何旗標的 gh pr edit 會進互動模式，以 2 擋下，下一步寫改用 --body-file" {
  hook "gh pr edit 12"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"改用 --body-file"* ]]
}

@test "gh pr edit 12 --attach a.png 以 2 擋下，下一步寫附件在網頁上加、描述一律用 --body-file 送出" {
  hook "gh pr edit 12 --attach a.png"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_ATTACH}"* ]]
}

@test "gh pr edit 12 --body-file f --attach a.png，f 有 Closes #12 也以 2 擋下並寫出同一個下一步" {
  body f.md "Closes #12"

  hook "gh pr edit 12 --body-file f.md --attach a.png"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_ATTACH}"* ]]
}

@test "--attach 的下一步，署名 hook 的寫法和這支一致" {
  input "gh pr edit 12 --attach a.png"
  run "${ATTRIBUTION}" <"${WORK}/input.json"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_ATTACH}"* ]]
}

@test "清單外的旗標（-e）以 2 擋下" {
  body f.md "Closes #12"

  hook "gh pr edit 12 --body-file f.md -e"

  [ "${status}" -eq 2 ]
}

@test "描述來自 shell 變數時以 2 擋下" {
  hook "gh pr edit 12 --body \"\$BODY\""

  [ "${status}" -eq 2 ]
}

@test "--body-file 從標準輸入讀時以 2 擋下" {
  hook "gh pr create --draft --title t --body-file -"

  [ "${status}" -eq 2 ]
}

@test "--body-file 指的檔不存在時以 2 擋下，指名那個檔" {
  hook "gh pr create --draft --title t --body-file missing.md"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"missing.md"* ]]
}

@test "描述有 Closes #1 與 Closes #2 兩張時以 2 擋下" {
  body f.md "Closes #1${NL}Closes #2"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 2 ]
}

@test "描述有 Closes #12 與 Closes other/repo#12（同編號、不同 repo 是兩張）時以 2 擋下" {
  body f.md "Closes #12${NL}Closes other/repo#12"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 2 ]
}

@test "描述只有 Closes other/repo#12（不是本 repo）時以 2 擋下" {
  body f.md "Closes other/repo#12"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 2 ]
}

@test "描述有 Closes #12 與 Closes o/r#12（origin 指到 o/r，同一張）時放行" {
  body f.md "Closes #12${NL}Closes o/r#12"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "本 repo 的完整寫法不分大小寫：Closes #12 與 Closes O/R#12 放行" {
  body f.md "Closes #12${NL}Closes O/R#12"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "帶 -R 時以 -R 的 repo 當本 repo：-R x/y 與 Closes x/y#12 放行" {
  body f.md "Closes x/y#12"

  hook "gh pr create -R x/y --draft --title t --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "描述寫 Closes: #12（關鍵字後面接冒號）時放行" {
  body f.md "Closes: #12"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "描述只有 Discloses #12（不是關閉關鍵字）時以 2 擋下，下一步寫先開 issue 再寫 Closes #N" {
  body f.md "Discloses #12"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_BIND}"* ]]
}

@test "關鍵字後面接網址時以 2 擋下" {
  body f.md "Closes https://github.com/o/r/issues/12"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 2 ]
}

@test "判斷不了本 repo（cwd 不在 git repo 裡）時，寫了 owner/repo 的參照以 2 擋下" {
  rm -rf "${WORK}/.git"
  body f.md "Closes o/r#12"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 2 ]
}

@test "判斷不了本 repo 時，只寫 #N 的參照照樣放行" {
  rm -rf "${WORK}/.git"
  body f.md "Closes #12"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "換上一份只認 Refs 的擷取規格（複製一份樹）時，hook 照那一份判定：Refs #12 放行" {
  mkdir -p "${WORK}/tree/script"
  cp -R "${REPO_ROOT}/script/claude-hooks" "${WORK}/tree/script/"
  {
    printf '# 規格用的替身：只認 Refs\n'
    printf '%s\n' '(?<![A-Za-z0-9_])(?P<keyword>refs):?\s*(?:(?P<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#(?P<number>[0-9]+)|(?P<url>https?://(?:www\.)?github\.com/\S+))'
  } >"${WORK}/tree/script/closing-references.txt"
  body f.md "Refs #12"
  input "gh pr create --draft --title t --body-file f.md"

  run "${WORK}/tree/script/claude-hooks/pr-rules.sh" <"${WORK}/input.json"

  [ "${status}" -eq 0 ]
}

@test "hook 裡沒有第二份關閉關鍵字的樣式：script/claude-hooks 底下找不到 close[sd]、resolve[sd] 這類寫法" {
  run grep -rn -E 'close\[sd\]|resolve\[sd\]|resolve\(s\|d\)' "${REPO_ROOT}/script/claude-hooks"

  [ "${status}" -eq 1 ]
}

# ── 第 3 點：一律先開草稿 PR ───────────────────────────────────────────────

@test "沒寫草稿旗標的 gh pr create 以 2 擋下，下一步寫加 --draft 開草稿" {
  body f.md "Closes #12"

  hook "gh pr create --title t --body-file f.md"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"加 --draft 開草稿"*"gh pr ready <n>"* ]]
}

@test "寫 --draft=false 的 gh pr create 以 2 擋下並寫出下一步" {
  body f.md "Closes #12"

  hook "gh pr create --draft=false --title t --body-file f.md"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"加 --draft 開草稿"* ]]
}

@test "gh pr create --draft --title t --body-file f（f 有關閉關鍵字）放行" {
  body f.md "Closes #12"

  hook "gh pr create --draft --title t --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "gh pr create -d --title t --body-file f（f 有關閉關鍵字）放行" {
  body f.md "Closes #12"

  hook "gh pr create -d --title t --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "署名 hook 同時啟用時，gh pr create --draft 與 -d（f 有關閉關鍵字）兩支都放行" {
  body f.md "Closes #12${NL}${NL}## 摘要"
  codes=""
  for flag in --draft -d; do
    input "gh pr create ${flag} --title t --body-file f.md"
    run "${HOOK}" <"${WORK}/input.json"
    codes="${codes}${status}"
    run "${ATTRIBUTION}" <"${WORK}/input.json"
    codes="${codes}${status}"
  done

  [ "${codes}" = "0000" ]
}

# ── 看不到該看的內容：照 Q8 擋下並寫出下一步 ─────────────────────────────

@test "hook 的輸入是空的時以 2 擋下並寫出下一步" {
  run "${HOOK}" </dev/null

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"* ]]
}

@test "hook 的輸入不是 JSON 時以 2 擋下並寫出下一步" {
  printf 'not json\n' >"${WORK}/input.json"

  run "${HOOK}" <"${WORK}/input.json"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"* ]]
}

@test "讀不懂結構的 gh 指令（引號沒有結束）以 2 擋下" {
  hook "gh pr merge \"12"

  [ "${status}" -eq 2 ]
}

@test "沒有 gh 的指令放行" {
  hook "ls -la && git status"

  [ "${status}" -eq 0 ]
}

@test "PATH 上沒有 python3 時以 2 擋下並寫出下一步" {
  mkdir "${WORK}/nopy"
  input "gh pr view 12"

  run env -i PATH="${WORK}/nopy" "$(command -v bash)" "${HOOK}" <"${WORK}/input.json"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"python3"*"下一步"* ]]
}

# ── repo 設定 ─────────────────────────────────────────────────────────────

@test ".claude/settings.json 以 PreToolUse 的 Bash matcher 呼叫 pr-rules.sh" {
  run python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in settings.get("hooks", {}).get("PreToolUse", []):
    if entry.get("matcher") != "Bash":
        continue
    for hook in entry.get("hooks", []):
        if hook.get("type") == "command" and "script/claude-hooks/pr-rules.sh" in hook.get("command", ""):
            print("wired")' "${REPO_ROOT}/.claude/settings.json"

  [ "${status}" -eq 0 ]
  [ "${output}" = "wired" ]
}

@test ".claude/settings.json 以 PreToolUse 的 mcp__ccd_pr__set_auto_merge matcher 呼叫 pr-rules.sh" {
  run python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in settings.get("hooks", {}).get("PreToolUse", []):
    if entry.get("matcher") != "mcp__ccd_pr__set_auto_merge":
        continue
    for hook in entry.get("hooks", []):
        if hook.get("type") == "command" and "script/claude-hooks/pr-rules.sh" in hook.get("command", ""):
            print("wired")' "${REPO_ROOT}/.claude/settings.json"

  [ "${status}" -eq 0 ]
  [ "${output}" = "wired" ]
}
