#!/usr/bin/env bats
#
# script/claude-hooks/issue-rules.sh —— Claude Code 的 PreToolUse hook：開 issue 與改 issue 的標題或本文只走審稿過的那一份，
# 審稿紀錄只由 script/issue_draft.sh 寫（T19、#413 調整需求第 7 點）。
#
# hook 在主機上跑，只讀工具呼叫的輸入：指令文字、Write／Edit／NotebookEdit 的路徑、指令明白帶入的 API 檔案。看不到該看的內容
# 就擋下並寫出下一步（Q8）。
#
# 測的是公開行為：照 Claude Code 給 hook 的形狀把 JSON 餵進標準輸入，看結束碼（2 是擋下）與訊息。cwd 是一個暫存目錄 ${WORK}，
# 相對路徑照它解析。工作階段 id 的變數名稱在執行時才組出來，這份檔案的指令字串不必逐一寫死。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  HOOK="${REPO_ROOT}/script/claude-hooks/issue-rules.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  ID="CLAUDE_CODE_""SESSION_ID"
  HOST_ID="CLAUDE_CODE_""HOST_SESSION_ID"
  SNAP=".issue-drafts/x/snapshots/h"
  STEP_CREATE="先寫 .issue-drafts/<名稱>/（title.txt、body.md），執行 script/issue_draft.sh submit <名稱> --new 送審"
  STEP_EDIT="改本文走 script/issue_draft.sh submit <名稱> --edit <編號>，審過後 script/issue_draft.sh edit <名稱>"
  STEP_IDENTITY="不要在指令裡設定、清掉或改寫工作階段 id"
  STEP_SNAPSHOT="快照與紀錄只由 script/issue_draft.sh 寫"
}

teardown() {
  rm -rf "${WORK}"
}

# hook <指令文字>：把 Bash 工具的輸入餵給 issue-rules.sh。
hook() {
  python3 -c '
import json, sys
print(json.dumps({
    "session_id": "spec",
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[1], "description": "規格"},
    "cwd": sys.argv[2],
}))' "$1" "${WORK}" >"${WORK}/input.json"
  run "${HOOK}" <"${WORK}/input.json"
}

# tool <工具名稱> <路徑>：把 Write／Edit／NotebookEdit 的輸入餵給 issue-rules.sh。
tool() {
  python3 -c '
import json, sys
key = "notebook_path" if sys.argv[1] == "NotebookEdit" else "file_path"
print(json.dumps({
    "session_id": "spec",
    "hook_event_name": "PreToolUse",
    "tool_name": sys.argv[1],
    "tool_input": {key: sys.argv[2], "content": "x"},
    "cwd": sys.argv[3],
}))' "$1" "$2" "${WORK}" >"${WORK}/input.json"
  run "${HOOK}" <"${WORK}/input.json"
}

# blocked_with <下一步的片段>：以 2 擋下，訊息有「下一步」與那個片段。
blocked_with() {
  [ "${status}" -eq 2 ] && [[ "${output}" == *"下一步"*"$1"* ]]
}

# ── 開 issue ──────────────────────────────────────────────────────────────

@test "gh issue create 帶著正確的標題與內文，也以 2 擋下並寫出送審的下一步" {
  hook "gh issue create --title 'chore(x): 標題' --body-file body.md"
  blocked_with "${STEP_CREATE}"
}

@test "gh issue create 帶 --attach 以 2 擋下並寫出送審的下一步" {
  hook "gh issue create --title t --body-file body.md --attach a.png"
  blocked_with "${STEP_CREATE}"
}

@test "gh issue new（gh issue create 的別名）以 2 擋下並寫出送審的下一步" {
  hook "gh issue new"
  blocked_with "${STEP_CREATE}"
}

@test "gh issue create 放在 bash -c 裡也以 2 擋下" {
  hook "bash -c 'gh issue create -t x -b y'"
  [ "${status}" -eq 2 ]
}

@test "gh issue create 交給 xargs 執行也以 2 擋下" {
  hook "xargs gh issue create"
  [ "${status}" -eq 2 ]
}

@test "script/issue_draft.sh create x 不擋" {
  hook "script/issue_draft.sh create x"
  [ "${status}" -eq 0 ]
}

# ── 用 gh api 開或改 issue ────────────────────────────────────────────────

@test "gh api 開 issue 的寫法都以 2 擋下" {
  printf '{"title": "x"}\n' >"${WORK}/j.json"
  local command
  for command in \
    "gh api repos/o/r/issues -f title=x" \
    "gh api repos/o/r/issues --input j.json" \
    "gh api -X POST repos/o/r/issues" \
    "gh api --method=POST /repos/{owner}/{repo}/issues --raw-field title=x" \
    "gh api https://api.github.com/repos/o/r/issues -f title=x" \
    'gh api "$EP" -f title=x'; do
    hook "${command}"
    [ "${status}" -eq 2 ] || { echo "沒擋：${command}"; return 1; }
  done
}

@test "gh api 改 issue 的標題或本文以 2 擋下並寫出改本文的下一步" {
  printf '{"title": "x"}\n' >"${WORK}/j.json"
  local command
  for command in \
    "gh api -X PATCH repos/o/r/issues/1 -f body=x" \
    "gh api -X PATCH repos/o/r/issues/1 -F title=x" \
    "gh api -X PATCH repos/o/r/issues/1 --input j.json"; do
    hook "${command}"
    blocked_with "${STEP_EDIT}" || { echo "沒擋或下一步不對：${command}"; return 1; }
  done
}

@test "gh api graphql 的有效查詢含 createIssue 或 updateIssue 以 2 擋下" {
  printf '{"query": "mutation { createIssue(input: {}) { issue { id } } }"}\n' >"${WORK}/q.json"
  local command
  for command in \
    "gh api graphql -f query='mutation { createIssue(input: {}) { issue { id } } }'" \
    "gh api graphql -f query='mutation { updateIssue(input: {}) { issue { id } } }'" \
    "gh api graphql --input q.json"; do
    hook "${command}"
    [ "${status}" -eq 2 ] || { echo "沒擋：${command}"; return 1; }
  done
}

@test "gh api graphql 取不到有效查詢（讀不到的檔、標準輸入）照 Q8 以 2 擋下" {
  local command
  for command in "gh api graphql --input missing.json" "gh api graphql --input -"; do
    hook "${command}"
    [ "${status}" -eq 2 ] || { echo "沒擋：${command}"; return 1; }
  done
}

@test "讀 issue、只改 state、寫留言的 gh api 不擋" {
  local command
  for command in \
    "gh api repos/o/r/issues" \
    "gh api -X PATCH repos/o/r/issues/1 -f state=closed" \
    "gh api repos/o/r/issues/1/comments -f body=x" \
    "gh api graphql -f query='query { viewer { login } }'"; do
    hook "${command}"
    [ "${status}" -eq 0 ] || { echo "被擋：${command}"; return 1; }
  done
}

# ── 改標題或內文 ──────────────────────────────────────────────────────────

@test "gh issue edit 改標題或本文的旗標以 2 擋下並寫出改本文的下一步" {
  local command
  for command in \
    "gh issue edit 1 --body-file b.md" \
    "gh issue edit 1 -b x" \
    "gh issue edit 1 -t x" \
    "gh issue edit 1 --attach f"; do
    hook "${command}"
    blocked_with "${STEP_EDIT}" || { echo "沒擋或下一步不對：${command}"; return 1; }
  done
}

@test "沒有任何旗標的 gh issue edit 照 Q8 以 2 擋下" {
  hook "gh issue edit 1"
  blocked_with "${STEP_EDIT}"
}

@test "下一步寫出勾帳本用 script/issue_tick.sh" {
  hook "gh issue edit 1 --body-file b.md"
  [[ "${output}" == *"只勾帳本用 script/issue_tick.sh"* ]]
}

@test "只改 label 的 gh issue edit 不擋" {
  hook "gh issue edit 1 --add-label x"
  [ "${status}" -eq 0 ]
}

@test "script/issue_tick.sh 1 x y 不擋" {
  hook "script/issue_tick.sh 1 x y"
  [ "${status}" -eq 0 ]
}

# ── 身分變數 ──────────────────────────────────────────────────────────────

@test "改寫工作階段 id 的寫法都以 2 擋下並寫出下一步" {
  local command
  for command in \
    "${ID}=x script/issue_draft.sh verdict a b c" \
    "env ${ID}=x script/issue_draft.sh verdict a b c" \
    "export ${ID}=x; script/issue_draft.sh verdict a b c" \
    "unset ${ID}" \
    "env -u ${ID} script/issue_draft.sh verdict a b c" \
    ": \"\${${ID}:=x}\"" \
    "${HOST_ID}=x script/issue_draft.sh verdict a b c"; do
    hook "${command}"
    blocked_with "${STEP_IDENTITY}" || { echo "沒擋：${command}"; return 1; }
  done
}

@test "單純讀取工作階段 id（printenv、\$名稱、\${名稱}）不擋" {
  local command
  for command in \
    "printenv ${ID}" \
    "echo \"\$${ID}\"" \
    "printf %s \"\${${ID}}\" | shasum -a 256 | cut -c1-12"; do
    hook "${command}"
    [ "${status}" -eq 0 ] || { echo "被擋：${command}"; return 1; }
  done
}

# ── 快照與紀錄 ────────────────────────────────────────────────────────────

@test "用 Write、Edit、NotebookEdit 寫快照裡的檔以 2 擋下並寫出下一步" {
  local name file
  for name in Write Edit NotebookEdit; do
    for file in review.md meta; do
      tool "${name}" "${WORK}/${SNAP}/${file}"
      blocked_with "${STEP_SNAPSHOT}" || { echo "沒擋：${name} ${file}"; return 1; }
    done
  done
}

@test "用 Write 寫草稿本身（body.md）不擋" {
  tool Write "${WORK}/.issue-drafts/x/body.md"
  [ "${status}" -eq 0 ]
}

@test "Bash 寫入、搬移、刪除快照裡的東西都以 2 擋下" {
  local command
  for command in \
    "cat > ${SNAP}/review.md" \
    "cp y ${SNAP}/meta" \
    "script/issue_draft.sh verdict x h o.md > ${SNAP}/review.md" \
    "script/issue_draft.sh verdict x h o.md && echo x > ${SNAP}/review.md" \
    "rm ${SNAP}/published" \
    "cd ${SNAP} && rm published" \
    "rm ${SNAP}/*" \
    "git clean -fX ${SNAP}/published" \
    "mv ${SNAP} .issue-drafts/y/snapshots/" \
    "find .issue-drafts -name published -delete"; do
    hook "${command}"
    [ "${status}" -eq 2 ] || { echo "沒擋：${command}"; return 1; }
  done
}

@test "審稿紀錄的寫入被擋時，下一步寫快照只由 script/issue_draft.sh 寫" {
  hook "cat > ${SNAP}/review.md"
  blocked_with "${STEP_SNAPSHOT}"
}

@test "查看快照、執行 verdict、刪掉整個快照資料夾都不擋" {
  local command
  for command in \
    "script/issue_draft.sh verdict x h o.md" \
    "cat ${SNAP}/review.md" \
    "ls .issue-drafts/x" \
    "rm -r ${SNAP}" \
    "git clean -fX .issue-drafts/x/snapshots" \
    "rmdir .issue-drafts/x/.lock"; do
    hook "${command}"
    [ "${status}" -eq 0 ] || { echo "被擋：${command}"; return 1; }
  done
}

# ── 讀不懂的輸入與接線 ────────────────────────────────────────────────────

@test "讀不到 hook 輸入（空的、不是 JSON）以 2 擋下並寫出下一步" {
  run "${HOOK}" </dev/null
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"* ]]
}

@test "沒有 gh、也沒提到 .issue-drafts 的指令不擋" {
  hook "git status && ls -la"
  [ "${status}" -eq 0 ]
}

@test ".claude/settings.json 以 PreToolUse 的 Bash 與 Write|Edit|NotebookEdit matcher 呼叫 issue-rules.sh" {
  run python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
found = []
for entry in settings.get("hooks", {}).get("PreToolUse", []):
    for hook in entry.get("hooks", []):
        if hook.get("type") == "command" and "script/claude-hooks/issue-rules.sh" in hook.get("command", ""):
            found.append(entry.get("matcher"))
print(" ".join(sorted(found)))' "${REPO_ROOT}/.claude/settings.json"

  [ "${status}" -eq 0 ]
  [ "${output}" = "Bash Write|Edit|NotebookEdit" ]
}
