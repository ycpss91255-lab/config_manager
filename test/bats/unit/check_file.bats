#!/usr/bin/env bats
#
# script/check_file.sh — 編輯之後立刻跑得動的那幾項單檔檢查。
#
# 這支不是閘門（CI 才是），但它的失敗形狀跟閘門一樣危險：一個接錯線的 hook 什麼都
# 不檢查，而它每次都回 0，看起來跟「檢查過了、乾淨」一模一樣。這個 repo 已經在
# hadolint 上付過一次那個代價（ADR-00000027 第二列）。所以派工規則要有規格。
#
# 被觀察的是命令列（T19）：一個路徑進去，或一份 hook 酬載進 stdin，看結束碼與訊息。
# 規格跑在檢查映像裡，CM_IN_TEST_IMAGE=1 已由映像設定，所以命令列模式是就地執行、不轉容器。
#
# hook 模式（不帶參數、stdin 是 hook 的 JSON）不跑檢查、不開 docker，只把適用的檢查與下一步寫成 JSON 的
# additionalContext（#412）。這幾條照 .claude/settings.json 實際註冊的那一行命令執行，PATH 上放一支記錄呼叫的假
# docker，並拿掉 CM_IN_TEST_IMAGE：先前的 hook 模式在這個條件下會轉進容器、呼叫 docker run。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/script/check_file.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
}

teardown() {
  rm -rf "${WORK}"
}

# project：在 ${WORK}/project 放一份只有 check_file.sh 的 repo（src/a.py、script/a.sh 都在），PATH 上的假 docker 把每次
# 呼叫記到 ${WORK}/docker.log；image inspect 成功，所以先前的寫法會一路走到 docker run。
project() {
  mkdir -p "${WORK}/project/script" "${WORK}/project/src" "${WORK}/fake"
  cp "${SCRIPT}" "${WORK}/project/script/check_file.sh"
  printf 'x = 1\n' >"${WORK}/project/src/a.py"
  printf '#!/usr/bin/env bash\necho a\n' >"${WORK}/project/script/a.sh"
  printf '#!/bin/sh\necho "$*" >>"%s"\nexit 0\n' "${WORK}/docker.log" >"${WORK}/fake/docker"
  chmod +x "${WORK}/fake/docker"
}

# registered：.claude/settings.json 裡 PostToolUse 的 Edit|Write 那一行命令。
registered() {
  python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in settings["hooks"]["PostToolUse"]:
    if entry.get("matcher") == "Edit|Write":
        for hook in entry["hooks"]:
            if "check_file.sh" in hook["command"]:
                print(hook["command"])' "${REPO_ROOT}/.claude/settings.json"
}

# hook_run <工具> <file_path>：照註冊的那一行命令、以 Claude Code 的方式（sh -c，CLAUDE_PROJECT_DIR 是 repo 根目錄）
# 執行，stdin 是那次 Edit／Write 的 JSON。結束碼放 code，stdout、stderr 各自放在 out.txt、err.txt。
hook_run() {
  python3 -c 'import json, sys
print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": sys.argv[1],
                  "tool_input": {"file_path": sys.argv[2]}, "tool_response": {"success": True}}))' "$1" "$2" \
    >"${WORK}/input.json"
  code=0
  env -u CM_IN_TEST_IMAGE -u CM_TEST_LOCAL PATH="${WORK}/fake:${PATH}" CLAUDE_PROJECT_DIR="${WORK}/project" \
    sh -c "$(registered)" <"${WORK}/input.json" >"${WORK}/out.txt" 2>"${WORK}/err.txt" || code=$?
}

# context：out.txt 是 PostToolUse 的 hookSpecificOutput 時，印出它的 additionalContext；不是就以非零結束。
context() {
  python3 -c 'import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]
assert data["hookEventName"] == "PostToolUse"
print(data["additionalContext"])' "${WORK}/out.txt"
}

@test "src 底下的 Python 檔違反 ruff 規則時被擋下" {
  cat >"${REPO_ROOT}/src/config_manager/core/_spec_tmp.py" <<'PY'
def f() -> int:
    try:
        return int("x")
    except:
        return 0
PY
  run "${SCRIPT}" src/config_manager/core/_spec_tmp.py
  rm -f "${REPO_ROOT}/src/config_manager/core/_spec_tmp.py"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"E722"* ]]
}

@test "src 底下的 Python 檔缺三要素的訊息也被擋下" {
  cat >"${REPO_ROOT}/src/config_manager/core/_spec_tmp.py" <<'PY'
class DuplicateUid(Exception):
    """兩筆條目共用同一個 uid。"""


def f(ref: str) -> None:
    raise DuplicateUid(f"uid 重複：{ref}")
PY
  run "${SCRIPT}" src/config_manager/core/_spec_tmp.py
  rm -f "${REPO_ROOT}/src/config_manager/core/_spec_tmp.py"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"下一步"* ]]
}

@test "script 底下的 shell 腳本走 shellcheck" {
  cat >"${REPO_ROOT}/script/_spec_tmp.sh" <<'SH'
#!/usr/bin/env bash
echo $undefined_and_unquoted
SH
  run "${SCRIPT}" script/_spec_tmp.sh
  rm -f "${REPO_ROOT}/script/_spec_tmp.sh"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"SC2"* ]]
}

@test "乾淨的檔案通過" {
  run "${SCRIPT}" src/config_manager/core/config_list.py
  [ "${status}" -eq 0 ]
}

@test "不在派工表上的路徑不跑任何檢查，也不報錯" {
  run "${SCRIPT}" doc/TEST-PLAN.md
  [ "${status}" -eq 0 ]
}

@test "repo 之外的路徑不跑任何檢查，也不報錯" {
  run "${SCRIPT}" /etc/hostname
  [ "${status}" -eq 0 ]
}

@test "不存在的檔案不報錯" {
  run "${SCRIPT}" src/config_manager/core/no_such_file.py
  [ "${status}" -eq 0 ]
}

@test "hook 模式（照註冊的那一行）編輯 src/a.py 之後，假 docker 被呼叫 0 次" {
  project
  hook_run Edit "${WORK}/project/src/a.py"

  [ ! -e "${WORK}/docker.log" ]
}

@test "hook 模式編輯 src/a.py 之後，stdout 是帶 additionalContext 的 JSON：適用的檢查與下一步，結束碼 0" {
  project
  hook_run Edit "${WORK}/project/src/a.py"

  [ "${code}" -eq 0 ]
  run context
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"src/a.py 適用的單檔檢查是 ruff check、script/lint_messages.sh"*"下一步：要跑就執行 script/check_file.sh src/a.py（會開 docker，照 docker 先問）"* ]]
}

@test "hook 模式寫入 script/a.sh 之後，假 docker 被呼叫 0 次、提醒 shellcheck，結束碼 0" {
  project
  hook_run Write "${WORK}/project/script/a.sh"

  [ "${code}" -eq 0 ]
  [ ! -e "${WORK}/docker.log" ]
  run context
  [[ "${output}" == *"script/a.sh 適用的單檔檢查是 shellcheck --severity=warning、script/lint_messages.sh"* ]]
}

@test "hook 模式編輯不在派工表上的檔時沒有輸出、結束碼 0" {
  project
  hook_run Edit "${WORK}/project/README.md"

  [ "${code}" -eq 0 ]
  [ ! -s "${WORK}/out.txt" ]
}

@test "命令列模式照舊：script/check_file.sh src/a.py 在映像外轉進容器（docker run …）" {
  project
  run env -u CM_IN_TEST_IMAGE -u CM_TEST_LOCAL PATH="${WORK}/fake:${PATH}" "${WORK}/project/script/check_file.sh" src/a.py

  [ "${status}" -eq 0 ]
  grep -q "^run --rm .* ./script/check_file.sh src/a.py$" "${WORK}/docker.log"
}

@test "stdin 不是 JSON 時不報錯，也不假裝檢查過：提醒裡寫明什麼都沒檢查" {
  run bash -c "printf 'not json' | '${SCRIPT}'"
  [ "${status}" -eq 0 ]
  printf '%s' "${output}" >"${WORK}/out.txt"
  run context
  [[ "${output}" == *"什麼都沒檢查"* ]]
}
