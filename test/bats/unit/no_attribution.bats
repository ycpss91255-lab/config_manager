#!/usr/bin/env bats
#
# script/claude-hooks/no-attribution.sh —— Claude Code 的 PreToolUse hook：寫進 commit、PR、issue 之前，
# 擋下 Claude 署名與 session 連結（T19、#405）。
#
# hook 在主機上跑，只讀工具呼叫的輸入：標準輸入那份 JSON 裡的指令文字與 cwd，以及指令帶入的檔。
# 先取出要寫出去的文字再逐行比對 script/attribution-patterns.txt；看不到該看的文字就擋下並寫出下一步。
#
# 測的是公開行為：照 Claude Code 給 hook 的形狀把 JSON 餵進標準輸入，看結束碼（2 是擋下）與訊息。
# 署名的字樣在執行時才組出來，這份檔案裡沒有從行首開始的署名行，也沒有完整的 session 網址。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  HOOK="${REPO_ROOT}/script/claude-hooks/no-attribution.sh"
  FIXTURES="${REPO_ROOT}/test/fixtures/attribution"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  NL=$'\n'
  COAUTHOR="Co-Authored-By"": Claude Opus 5 <noreply@anthropic.com>"
  GENERATED="🤖 Generated with [Claude Code]""(https://claude.com/claude-code)"
  SESSION_URL="https://claude.ai/code/session_""01SpecFakeId23"
}

teardown() {
  rm -rf "${WORK}"
}

# hook <指令文字>：照 Claude Code 給 PreToolUse hook 的形狀把 JSON 餵進標準輸入，cwd 是 ${WORK}。
hook() {
  python3 -c '
import json, sys
print(json.dumps({
    "session_id": "spec",
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[1], "description": "spec"},
    "cwd": sys.argv[2],
}))' "$1" "${WORK}" >"${WORK}/input.json"
  run "${HOOK}" <"${WORK}/input.json"
}

# body <檔名> <內容>：在 ${WORK} 底下寫一個要帶入的檔。
body() {
  printf '%s\n' "$2" >"${WORK}/$1"
}

# ── 命中樣式：以 2 擋下並指名那一行 ─────────────────────────────────────

@test "git commit -m 的訊息有一行共同作者行時以 2 擋下，指名第幾個 -m 與第幾行" {
  hook "git commit -m \"fix(web): 修好${NL}${NL}${COAUTHOR}\""

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"第 1 個 -m"*"第 3 行"* ]]
}

@test "共同作者行就是 -m 訊息的第一行時以 2 擋下，指名第 1 行" {
  hook "git commit -m \"${COAUTHOR}\""

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"第 1 個 -m"*"第 1 行"* ]]
}

@test "訊息乾淨、共同作者行放在 --trailer 時以 2 擋下，指名那個 --trailer" {
  hook "git commit -m \"clean\" --trailer \"Co-Authored-By: Claude <noreply@anthropic.com>\""

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--trailer"* ]]
}

@test "gh pr create 的 --body-file 有 Generated with 那一行時以 2 擋下，指名 --body-file 與行號" {
  body f.md "## 摘要${NL}內容${NL}${GENERATED}"

  hook "gh pr create --title t --body-file f.md"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--body-file"*"第 3 行"* ]]
}

@test "gh issue comment 的內文在行中引用完整的 session 網址時以 2 擋下" {
  hook "gh issue comment 5 --body \"說明：舊的留言放了 ${SESSION_URL} 這個連結\""

  [ "${status}" -eq 2 ]
}

@test "命中完整的 session 網址時，擋下的訊息裡沒有那個網址" {
  hook "gh issue comment 5 --body \"說明：舊的留言放了 ${SESSION_URL} 這個連結\""

  [ "${status}" -eq 2 ]
  [[ "${output}" != *"${SESSION_URL}"* ]]
}

@test "gh api -f body= 的值第一行是共同作者行時以 2 擋下，指名 -f" {
  hook "gh api repos/o/r/issues/1/comments -f body='${COAUTHOR}${NL}其餘內文'"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"-f body"* ]]
}

@test "gh api -F body=@f 的檔有 Generated with 那一行時以 2 擋下，指名那個檔" {
  body f.md "內文${NL}${GENERATED}"

  hook "gh api repos/o/r/issues/1/comments -F body=@f.md"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"f.md"*"第 2 行"* ]]
}

@test "沒有 -X、-f、-F 的 gh api --input 也算寫入：body 欄位解碼後的共同作者行以 2 擋下" {
  python3 -c 'import json, sys; print(json.dumps({"body": "說明\n" + sys.argv[1]}))' "${COAUTHOR}" >"${WORK}/j.json"

  hook "gh api repos/o/r/issues/1/comments --input j.json"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--input"*"第 2 行"* ]]
}

# ── 放行 ──────────────────────────────────────────────────────────────────

@test "只在行中引用署名字樣、session 網址寫成 session_<ID> 的 --body 放行" {
  hook "gh issue comment 5 --body \"說明 Co-Authored-By 那一行要刪；Generated with [Claude Code] 那一行也刪；網址寫成 session_<ID>\""

  [ "${status}" -eq 0 ]
}

@test "只在行中引用署名字樣的 --body-file 放行" {
  body f.md "- 刪掉 \`${COAUTHOR}\` 這種行${NL}- 也刪掉「${GENERATED}」${NL}- 連結寫成 https://claude.ai/code/session_<ID>"

  hook "gh issue comment 5 --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "以 #269 的完整內文開 issue（標題與內文都明帶）放行" {
  cp "${FIXTURES}/issue-269.md" "${WORK}/f.md"

  hook "gh issue create --title t --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "以 #405 的完整內文開 issue（標題與內文都明帶）放行" {
  cp "${FIXTURES}/issue-405.md" "${WORK}/f.md"

  hook "gh issue create --title t --body-file f.md"

  [ "${status}" -eq 0 ]
}

@test "git log --grep Co-Authored-By 這類唯讀的 git 指令放行" {
  hook "git log --grep Co-Authored-By"

  [ "${status}" -eq 0 ]
}

@test "gh pr view 這類唯讀的 gh 指令放行" {
  hook "gh pr view 12 --json body"

  [ "${status}" -eq 0 ]
}

@test "沒有欄位、沒有 --input 也沒有 -X 的 gh api 是讀取，放行" {
  hook "gh api repos/o/r/issues/1/comments"

  [ "${status}" -eq 0 ]
}

@test "git commit --amend -m 明帶乾淨的訊息時放行" {
  hook "git commit --amend -m \"clean\""

  [ "${status}" -eq 0 ]
}

# ── 清單外的旗標：實際送出的文字核對不了 ─────────────────────────────────

@test "gh pr edit --attach 以 2 擋下，指名 --attach 並寫出下一步" {
  hook "gh pr edit 12 --attach a.png"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--attach"*"下一步"*"網頁"*"--body-file"* ]]
}

@test "內文乾淨也帶了 --attach 的 gh pr edit 以 2 擋下，指名 --attach" {
  body f.md "乾淨的描述"

  hook "gh pr edit 12 --body-file f.md --attach a.png"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--attach"* ]]
}

# ── 看不到該看的文字：照 Q8 擋下並寫出下一步 ─────────────────────────────

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

@test "hook 的輸入裡沒有指令文字時以 2 擋下並寫出下一步" {
  printf '{"tool_name": "Bash", "tool_input": {}}\n' >"${WORK}/input.json"

  run "${HOOK}" <"${WORK}/input.json"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"* ]]
}

@test "--body-file 指的檔不存在時以 2 擋下，指名那個檔並寫出下一步" {
  hook "gh issue create --title t --body-file missing.md"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"missing.md"*"下一步"* ]]
}

@test "gh api -F body=@- 從標準輸入讀時以 2 擋下" {
  hook "gh api repos/o/r/issues/1/comments -F body=@-"

  [ "${status}" -eq 2 ]
}

@test "gh api --input - 從標準輸入讀時以 2 擋下" {
  hook "gh api repos/o/r/issues/1/comments --input -"

  [ "${status}" -eq 2 ]
}

@test "gh issue create --body-file - 從標準輸入讀時以 2 擋下" {
  hook "gh issue create --title t --body-file -"

  [ "${status}" -eq 2 ]
}

@test "git commit -F - 從標準輸入讀時以 2 擋下" {
  hook "git commit -F -"

  [ "${status}" -eq 2 ]
}

@test "-m 的值來自 shell 變數時以 2 擋下" {
  hook "git commit -m \"\$MSG\""

  [ "${status}" -eq 2 ]
}

@test "-m 的值來自指令替換時以 2 擋下" {
  hook "git commit -m \"\$(cat <<'EOF'${NL}fix(web): 修好${NL}EOF${NL})\""

  [ "${status}" -eq 2 ]
}

@test "gh issue create -e 要開編輯器時以 2 擋下" {
  hook "gh issue create -e"

  [ "${status}" -eq 2 ]
}

@test "只帶 --body-file 沒帶標題的 gh issue create 會跳提示，以 2 擋下" {
  body f.md "乾淨的內文"

  hook "gh issue create --body-file f.md"

  [ "${status}" -eq 2 ]
}

@test "git commit -C HEAD~1 帶入既有的訊息，以 2 擋下並指名 -C" {
  hook "git commit -C HEAD~1"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"-C"* ]]
}

@test "git commit --no-verify 會跳過 commit-msg 檢查，以 2 擋下並指名 --no-verify" {
  hook "git commit --no-verify -m x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--no-verify"* ]]
}

@test "git commit --amend --no-edit 沿用 HEAD 的訊息，以 2 擋下，下一步寫明帶訊息" {
  hook "git commit --amend --no-edit"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"--amend -m"* ]]
}

@test "git commit --amend --no-edit --trailer 也以 2 擋下，下一步寫明帶訊息" {
  hook "git commit --amend --no-edit --trailer \"x: y\""

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"--amend -m"* ]]
}

# ── 指令的結構 ────────────────────────────────────────────────────────────

@test "同一條指令先 cd 到子目錄時，相對路徑讀的是子目錄裡的那個檔" {
  mkdir "${WORK}/sub"
  body f.md "乾淨的描述"
  body sub/f.md "內文${NL}${GENERATED}"

  hook "cd sub && gh pr create --title t --body-file f.md"

  [ "${status}" -eq 2 ]
}

@test "放在指令替換裡的 gh pr create 照樣檢查" {
  body f.md "內文${NL}${GENERATED}"

  hook "url=\$(gh pr create --title t --body-file f.md) && echo \"\${url}\""

  [ "${status}" -eq 2 ]
}

@test "帶入的檔在同一條指令裡先被重新導向寫出時以 2 擋下" {
  body f.md "乾淨的描述"

  hook "printf 'x\\n' > f.md && gh pr create --title t --body-file f.md"

  [ "${status}" -eq 2 ]
}

@test "PATH 上沒有 python3 時以 2 擋下並寫出下一步" {
  mkdir "${WORK}/nopy"
  hook "gh pr view 12"

  run env -i PATH="${WORK}/nopy" "$(command -v bash)" "${HOOK}" <"${WORK}/input.json"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"python3"*"下一步"* ]]
}

# ── repo 設定 ─────────────────────────────────────────────────────────────

@test ".claude/settings.json 的 attribution 照 #269 第 1 步：commit 與 pr 是空字串、sessionUrl 是 false" {
  run python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps(settings.get("attribution"), sort_keys=True))' "${REPO_ROOT}/.claude/settings.json"

  [ "${status}" -eq 0 ]
  [ "${output}" = '{"commit": "", "pr": "", "sessionUrl": false}' ]
}

@test ".claude/settings.json 以 PreToolUse 的 Bash matcher 呼叫 no-attribution.sh" {
  run python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in settings.get("hooks", {}).get("PreToolUse", []):
    if entry.get("matcher") != "Bash":
        continue
    for hook in entry.get("hooks", []):
        if hook.get("type") == "command" and "script/claude-hooks/no-attribution.sh" in hook.get("command", ""):
            print("wired")' "${REPO_ROOT}/.claude/settings.json"

  [ "${status}" -eq 0 ]
  [ "${output}" = "wired" ]
}
