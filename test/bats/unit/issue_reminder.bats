#!/usr/bin/env bats
#
# script/claude-hooks/issue-reminder.sh —— Claude Code 的 PostToolUse／PostToolUseFailure hook：用 script/issue_draft.sh 開了 issue
# 或改了本文之後，提醒在 issue 留言附最後一輪的判定與意見摘要（T19、#413 調整需求第 8 點）。只提醒、不擋。
#
# 測的是公開行為：照 Claude Code 給 hook 的形狀把 JSON 餵進標準輸入，看結束碼與標準輸出的 additionalContext。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  HOOK="${REPO_ROOT}/script/claude-hooks/issue-reminder.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  REMINDER="在那張 issue 留言附最後一輪的判定，與適合公開的意見摘要"
}

teardown() {
  rm -rf "${WORK}"
}

# post <事件> <指令文字> <tool_response 的 JSON>：餵給 issue-reminder.sh，additionalContext 印在 CONTEXT。
post() {
  python3 -c '
import json, sys
print(json.dumps({
    "session_id": "spec",
    "hook_event_name": sys.argv[1],
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[2], "description": "規格"},
    "tool_response": json.loads(sys.argv[3]),
    "cwd": sys.argv[4],
}))' "$1" "$2" "$3" "${WORK}" >"${WORK}/input.json"
  run "${HOOK}" <"${WORK}/input.json"
  CONTEXT="$(printf '%s' "${output}" | python3 -c '
import json, sys
text = sys.stdin.read()
print(json.loads(text)["hookSpecificOutput"]["additionalContext"] if text.strip() else "")')"
}

@test "script/issue_draft.sh create 成功之後，additionalContext 有留言提醒" {
  post PostToolUse "script/issue_draft.sh create x" '{"stdout": "", "stderr": "", "interrupted": false}'

  [ "${status}" -eq 0 ]
  [[ "${CONTEXT}" == *"${REMINDER}"* ]]
}

@test "script/issue_draft.sh edit 成功之後，additionalContext 有留言提醒" {
  post PostToolUse "script/issue_draft.sh edit x" '{"stdout": "", "stderr": "", "interrupted": false}'
  [[ "${CONTEXT}" == *"${REMINDER}"* ]]
}

@test "只有一段而且失敗的 create 不提醒" {
  post PostToolUseFailure "script/issue_draft.sh create x" '"Exit code 1"'

  [ "${status}" -eq 0 ]
  [ -z "${CONTEXT}" ]
}

@test "submit、verdict 不提醒" {
  local command
  for command in "script/issue_draft.sh submit x --new" "script/issue_draft.sh verdict x h o.md"; do
    post PostToolUse "${command}" '{"stdout": "", "interrupted": false}'
    [ -z "${CONTEXT}" ] || { echo "提醒了：${command}"; return 1; }
  done
}

@test "多段指令裡有 create 時給條件式提醒，失敗也給" {
  local event
  for event in PostToolUse PostToolUseFailure; do
    post "${event}" "cd ${WORK} && script/issue_draft.sh create x" '"Exit code 1"'
    [[ "${CONTEXT}" == *"如果剛才的指令"*"${REMINDER}"* ]] || { echo "沒有條件式提醒：${event}"; return 1; }
  done
}

@test ".claude/settings.json 以 PostToolUse 與 PostToolUseFailure 的 Bash matcher 呼叫 issue-reminder.sh" {
  run python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
found = []
for event in ("PostToolUse", "PostToolUseFailure"):
    for entry in settings.get("hooks", {}).get(event, []):
        if entry.get("matcher") != "Bash":
            continue
        for hook in entry.get("hooks", []):
            if hook.get("type") == "command" and "script/claude-hooks/issue-reminder.sh" in hook.get("command", ""):
                found.append(event)
print(" ".join(found))' "${REPO_ROOT}/.claude/settings.json"

  [ "${status}" -eq 0 ]
  [ "${output}" = "PostToolUse PostToolUseFailure" ]
}
