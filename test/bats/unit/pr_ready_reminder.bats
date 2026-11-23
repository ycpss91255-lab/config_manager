#!/usr/bin/env bats
#
# script/claude-hooks/pr-ready-reminder.sh —— Claude Code 的 PostToolUse／PostToolUseFailure hook：PR 轉成可合併時，用
# hook 輸出的 additionalContext 提醒 Claude「檢查全過就會被 CI 的 merge job 合併」（T19、#408 第 4 點）。
#
# 依 hooks 文件：結束碼 0 時寫到 stderr 的內容 Claude 看不到，所以提醒寫成 stdout 上的一份 JSON
# （hookSpecificOutput.additionalContext）。呼叫成功時 Claude Code 送的是 PostToolUse，tool_response 是物件；
# 失敗時送 PostToolUseFailure（Bash 非零結束，error 第一行是 Exit code N），或 tool_response 是錯誤文字的字串。
#
# 測的是公開行為：照 Claude Code 給 hook 的形狀把 JSON 餵進標準輸入，看結束碼與 additionalContext 的內容。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  HOOK="${REPO_ROOT}/script/claude-hooks/pr-ready-reminder.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
}

teardown() {
  rm -rf "${WORK}"
}

# remind <事件> <指令文字> [<tool_response 的 JSON>]：照 Claude Code 給 hook 的形狀把 JSON 餵進標準輸入。
# 結束碼記在 code；additionalContext 寫到 ${WORK}/context.txt（沒有輸出 JSON 時是空檔）。
remind() {
  local response='{"stdout": "", "stderr": "", "interrupted": false, "isImage": false}'
  if [ $# -ge 3 ]; then
    response="$3"
  fi
  python3 -c '
import json, sys
event, command, response = sys.argv[1], sys.argv[2], sys.argv[3]
data = {
    "session_id": "spec",
    "hook_event_name": event,
    "tool_name": "Bash",
    "tool_input": {"command": command, "description": "spec"},
    "cwd": sys.argv[4],
}
if event == "PostToolUseFailure":
    data["error"] = "Exit code 1\ngh: something went wrong"
else:
    data["tool_response"] = json.loads(response)
print(json.dumps(data))' "$1" "$2" "${response}" "${WORK}" >"${WORK}/input.json"
  code=0
  "${HOOK}" <"${WORK}/input.json" >"${WORK}/out.json" 2>"${WORK}/err.txt" || code=$?
  python3 -c '
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    sys.exit(0)
data = json.loads(raw)
print(data["hookSpecificOutput"]["additionalContext"])' "${WORK}/out.json" >"${WORK}/context.txt"
}

# event：輸出 JSON 的 hookSpecificOutput.hookEventName。
event() {
  python3 -c '
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["hookEventName"])' "${WORK}/out.json"
}

@test "成功的 gh pr ready 12 有提醒：檢查全過就會被 CI 的 merge job 以 merge commit 合併，Closes 的 issue 會被關掉" {
  remind PostToolUse "gh pr ready 12"

  [ "${code}" -eq 0 ]
  run cat "${WORK}/context.txt"
  [[ "${output}" == *"PR #12"*"檢查全過就會被 CI 的 merge job 以 merge commit 合併"*"Closes 的 issue 會被關掉"* ]]
}

@test "成功的 gh pr ready 12 的提醒寫出合併條件、之後每次推送都可能觸發合併" {
  remind PostToolUse "gh pr ready 12"

  run cat "${WORK}/context.txt"
  [[ "${output}" == *"同 repo 的分支、base 是 main、合併前重判通過"*"之後每一次推送都可能觸發合併"* ]]
}

@test "成功的 gh pr ready 12 的提醒寫出 ready_for_review 會觸發 CI，排隊與結果由 GitHub 決定" {
  remind PostToolUse "gh pr ready 12"

  run cat "${WORK}/context.txt"
  [[ "${output}" == *"ready_for_review 會觸發 CI"*"排隊與結果由 GitHub 決定"* ]]
}

@test "成功的 gh pr ready 12 的提醒寫出還沒驗完就用 gh pr ready 12 --undo 轉回草稿、不一定趕得上" {
  remind PostToolUse "gh pr ready 12"

  run cat "${WORK}/context.txt"
  [[ "${output}" == *"gh pr ready 12 --undo"*"不一定趕得上"* ]]
}

@test "TDD red 是固定提醒：寫明確認描述有 ## TDD red，hook 沒有讀描述" {
  remind PostToolUse "gh pr ready 12"

  run cat "${WORK}/context.txt"
  [[ "${output}" == *"確認描述有 ## TDD red（或純文件的不適用理由）"*"固定提醒"*"沒有讀描述"* ]]
}

@test "提醒以 PostToolUse 的 hookSpecificOutput 輸出" {
  remind PostToolUse "gh pr ready 12"

  run event
  [ "${output}" = "PostToolUse" ]
}

@test "沒寫編號的 gh pr ready 也有提醒，指的是這個分支的 PR" {
  remind PostToolUse "gh pr ready"

  run cat "${WORK}/context.txt"
  [[ "${output}" == *"這個分支的 PR"*"檢查全過就會被 CI 的 merge job 以 merge commit 合併"* ]]
}

@test "gh pr ready 12 --undo（轉回草稿）沒有提醒" {
  remind PostToolUse "gh pr ready 12 --undo"

  [ "${code}" -eq 0 ]
  [ ! -s "${WORK}/context.txt" ]
}

@test "gh pr create --draft 沒有提醒" {
  remind PostToolUse "gh pr create --draft --title t --body-file f.md"

  [ "${code}" -eq 0 ]
  [ ! -s "${WORK}/context.txt" ]
}

@test "失敗的 gh pr ready 12（PostToolUseFailure）沒有提醒" {
  remind PostToolUseFailure "gh pr ready 12"

  [ "${code}" -eq 0 ]
  [ ! -s "${WORK}/context.txt" ]
}

@test "tool_response 是錯誤文字的字串（失敗的呼叫）時沒有提醒" {
  remind PostToolUse "gh pr ready 12" '"Exit code 1\ngh: not found"'

  [ "${code}" -eq 0 ]
  [ ! -s "${WORK}/context.txt" ]
}

@test "被中斷的 gh pr ready 12 沒有提醒" {
  remind PostToolUse "gh pr ready 12" '{"stdout": "", "stderr": "", "interrupted": true, "isImage": false}'

  [ "${code}" -eq 0 ]
  [ ! -s "${WORK}/context.txt" ]
}

@test "和 gh pr ready 無關的指令沒有提醒" {
  remind PostToolUse "git status && echo ready"

  [ "${code}" -eq 0 ]
  [ ! -s "${WORK}/context.txt" ]
}

@test "用 && 串起來的多段指令給條件式的提醒：如果剛才的指令把 PR 轉成可合併了" {
  remind PostToolUse "git push && gh pr ready 12"

  run cat "${WORK}/context.txt"
  [[ "${output}" == *"如果剛才的指令把 PR 轉成可合併了"*"檢查全過就會被 CI 的 merge job 以 merge commit 合併"* ]]
}

@test "用 ; 串起來的多段指令給條件式的提醒" {
  remind PostToolUse "gh pr ready 12; gh pr view 12"

  run cat "${WORK}/context.txt"
  [[ "${output}" == *"如果剛才的指令把 PR 轉成可合併了"* ]]
}

@test "多段指令的呼叫失敗（PostToolUseFailure）時也給條件式的提醒：分不出是哪一段失敗" {
  remind PostToolUseFailure "gh pr ready 12 && false"

  run cat "${WORK}/context.txt"
  [[ "${output}" == *"如果剛才的指令把 PR 轉成可合併了"* ]]
}

@test "多段指令的條件式提醒在 PostToolUseFailure 時以 PostToolUseFailure 的 hookSpecificOutput 輸出" {
  remind PostToolUseFailure "gh pr ready 12 && false"

  run event
  [ "${output}" = "PostToolUseFailure" ]
}

@test "條件式的提醒不說成已經轉了" {
  remind PostToolUse "git push && gh pr ready 12"

  run cat "${WORK}/context.txt"
  [[ "${output}" != *"剛才的 gh pr ready 把"* ]]
}

@test "hook 的輸入讀不懂時以 2 結束（Claude 看得到 stderr），寫出判斷不了與下一步" {
  printf 'not json\n' >"${WORK}/input.json"

  run "${HOOK}" <"${WORK}/input.json"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"判斷不了"*"下一步"* ]]
}

@test "PATH 上沒有 python3、指令提到 gh pr ready 時以 2 結束，寫出 python3 與下一步" {
  mkdir "${WORK}/nopy"
  remind PostToolUse "gh pr ready 12"

  run env -i PATH="${WORK}/nopy" "$(command -v bash)" "${HOOK}" <"${WORK}/input.json"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"python3"*"下一步"* ]]
}

@test "PATH 上沒有 python3、指令和 gh pr ready 無關時以 0 結束" {
  mkdir "${WORK}/nopy"
  remind PostToolUse "git status"

  run env -i PATH="${WORK}/nopy" "$(command -v bash)" "${HOOK}" <"${WORK}/input.json"

  [ "${status}" -eq 0 ]
}

@test ".claude/settings.json 以 PostToolUse 與 PostToolUseFailure 的 Bash matcher 呼叫 pr-ready-reminder.sh" {
  run python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
found = []
for event in ("PostToolUse", "PostToolUseFailure"):
    for entry in settings.get("hooks", {}).get(event, []):
        if entry.get("matcher") != "Bash":
            continue
        for hook in entry.get("hooks", []):
            if hook.get("type") == "command" and "script/claude-hooks/pr-ready-reminder.sh" in hook.get("command", ""):
                found.append(event)
print(" ".join(found))' "${REPO_ROOT}/.claude/settings.json"

  [ "${status}" -eq 0 ]
  [ "${output}" = "PostToolUse PostToolUseFailure" ]
}
