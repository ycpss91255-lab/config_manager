#!/usr/bin/env bash
#
# 單檔檢查。剛編輯過的那一個檔案，跑得動它的那幾項檢查。
#
# **這不是 CI 的替代品。CI 是權威，這支只是把回饋提前。** 它刻意只跑「一個檔案就能
# 判定」的檢查——ruff、lint_messages、shellcheck。mypy 要看整包型別、pylint 要看整包
# 匯入、pytest 要跑整組測試、覆蓋率下限只有在全部跑完之後才有意義：那些留在
# `./script/test.sh` 與 CI。這支說「乾淨」只代表那三項乾淨，不代表這次修改可以合併。
#
# `script/**/*.sh` 除了 shellcheck 之外也走 lint_messages：shell 的執行期輸出從 #133
# 起在三要素的管轄內，而單檔就判定得了它（與 `src/**/*.py` 同一個理由）。
#
# 為什麼要有它：閾值與規則本來就都擋得住（設計 §0.4），但擋下的時機是「推上去之後」。
# 同一個違規，在寫下它的當下看見，跟在十個 commit 之後從 CI 的紅燈回推，成本差很遠。
#
# 兩個呼叫者，兩種模式（#412）：
#
#   命令列  `script/check_file.sh <path>`：跑那幾項檢查。跟 test.sh 一樣轉進檢查映像，因為
#           主機不是這個專案的證據（ADR-00000027）。差別是**不建映像**：Dockerfile 一改，
#           建置就是好幾分鐘。映像不在就說出來並讓路——這支不是閘門，擋不擋得住由 CI 決定。
#   hook    Claude Code 的 PostToolUse hook 不給參數，把 JSON 送進 stdin。這時**不跑檢查、
#           不開 docker**，只把「這個檔適用哪幾項單檔檢查、要跑就執行命令列模式」寫成 JSON 的
#           additionalContext 印到 stdout，交給 Claude。依據是維護者定案：Claude Code hook
#           只讀工具呼叫的輸入、不跑專案的檢查（Q1），docker 指令先問（Q3）。先前這條路徑在
#           映像已經建好時會直接 `docker run`，不經 Bash、權限規則與 Bash hook 都攔不到；
#           「把回饋提前」改成由 agent 先問、再跑命令列模式。
#
# hook 模式一律以 0 結束。依 Claude Code 的 hooks 文件，結束碼 0 時 stdout 的 JSON 會被讀、
# stderr 不會交給 Claude；所以讀不到輸入這類情況也寫進 additionalContext。這支自己中途失敗
# （非 0）時，.claude/settings.json 那一行的 `|| exit 2` 把它轉成 2：PostToolUse 的 2 會把
# stderr 交給 Claude。那一行不能把 stdout 轉向，否則 JSON 到不了 Claude。
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_ROOT
readonly TEST_IMAGE="config_manager-test-tools:local"

usage() {
  cat <<'USAGE'
用法：script/check_file.sh [<path>]

  <path>  要檢查的那一個檔案。絕對路徑，或相對於 repo 根目錄。
          不帶參數時是 Claude Code 的 PostToolUse hook：從 stdin 讀它的酬載，
          取其中的 tool_input.file_path，**不跑檢查、不開 docker**，只把適用的檢查與
          下一步寫成 JSON 的 additionalContext 印到 stdout（#412）。

  src/**/*.py      ruff check，外加 script/lint_messages.sh
  script/**/*.sh   shellcheck --severity=warning，外加 script/lint_messages.sh
  其餘             沒有可以單檔判定的檢查，結束碼 0

帶 <path> 時在 docker/Dockerfile.test-tools 裡執行，而且**不建置它**（會開 docker，
agent 要先問）。這支不是 ./script/test.sh 或 CI 的替代品——它只是把同一組回饋提前，
而且只提前那些單一檔案就判定得了的檢查。
USAGE
}

# hook 的酬載是 JSON，而 shell 沒有 JSON parser。這裡用主機的 python3 只是為了讀一個
# 欄位、寫一份 JSON——不是拿它當檢查的證據，檢查仍然只在映像裡發生。
# 印出 tool_input.file_path（沒有就是空字串）；讀不到 JSON 時以 3 結束。
hook_path() {
  python3 -c 'import json, sys
try:
    payload = json.load(sys.stdin)
except (ValueError, OSError):
    raise SystemExit(3)
tool_input = payload.get("tool_input") if isinstance(payload, dict) else None
path = tool_input.get("file_path") if isinstance(tool_input, dict) else None
print(path if isinstance(path, str) else "")
'
}

# 這個檔適用哪幾項單檔檢查（空字串：沒有）。命令列模式的 run_checks 照同一張表跑。
checks_for() {
  case "$1" in
    src/*.py) printf 'ruff check、script/lint_messages.sh' ;;
    script/*.sh) printf 'shellcheck --severity=warning、script/lint_messages.sh' ;;
    *) printf '' ;;
  esac
}

# 把一段提醒寫成 PostToolUse 的 JSON（hooks 文件的 hookSpecificOutput.additionalContext）。
emit_context() {
  python3 -c 'import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": sys.argv[1]}}))' "$1"
}

# hook 模式：不跑檢查、不開 docker，只提醒（#412）。
hook_reminder() {
  [[ -t 0 ]] && return 0
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "check_file: python3 不在 PATH 上，讀不到 hook 的輸入，不知道剛才改了哪個檔，什麼都沒檢查。下一步：要檢查就執行 script/check_file.sh <路徑>（會開 docker，照 docker 先問）"}}'
    return 0
  fi
  local given status=0 file checks
  given="$(hook_path)" || status=$?
  if ((status != 0)); then
    emit_context "check_file: 讀不到 hook 的輸入（不是 JSON），不知道剛才改了哪個檔，什麼都沒檢查。下一步：要檢查就執行 script/check_file.sh <路徑>（會開 docker，照 docker 先問）"
    return 0
  fi
  [[ -n "${given}" ]] || return 0
  file="$(relative_path "${given}")"
  [[ -n "${file}" ]] || return 0
  checks="$(checks_for "${file}")"
  [[ -n "${checks}" ]] || return 0
  emit_context "check_file: ${file} 適用的單檔檢查是 ${checks}；hook 不跑檢查、不開 docker（#412），這次什麼都沒檢查。下一步：要跑就執行 script/check_file.sh ${file}（會開 docker，照 docker 先問），或推上去看 GitHub CI"
}

# repo 根目錄底下的相對路徑，或空字串（檔案不在這個 repo 裡）。掛載進容器的是
# repo 根目錄，所以主機的絕對路徑到了那邊沒有意義，必須先相對化再送進去。
relative_path() {
  local path="$1"
  [[ "${path}" == /* ]] || path="${REPO_ROOT}/${path}"
  case "${path}" in
    "${REPO_ROOT}"/*) printf '%s' "${path#"${REPO_ROOT}"/}" ;;
    *) printf '' ;;
  esac
}

# 每一項都跑完再回報，不是第一項紅了就停。停在第一項會讓「修好再跑、又冒出一條」
# 重複好幾輪，而這支存在的理由正是縮短那個迴圈。
run_checks() {
  local file="$1" failed=0
  cd "${REPO_ROOT}"

  case "${file}" in
    src/*.py)
      ruff check "${file}" || failed=1
      ./script/lint_messages.sh "${file}" || failed=1
      ;;
    script/*.sh)
      shellcheck --severity=warning "${file}" || failed=1
      ./script/lint_messages.sh "${file}" || failed=1
      ;;
    *)
      printf 'check_file: %s has no single-file check; nothing was run.\n' "${file}"
      ;;
  esac
  return "${failed}"
}

dispatch_to_container() {
  if ! command -v docker >/dev/null 2>&1; then
    printf 'check_file: docker 沒有安裝，所以 %s **沒有**被檢查。\n' "$1" >&2
    printf 'check_file: 這條只是提前回饋的路徑，擋不擋得住仍由 ./script/test.sh 與 CI 決定。\n' >&2
    printf 'check_file: 下一步：安裝 docker，或直接跑 ./script/test.sh\n' >&2
    return 0
  fi
  if ! docker image inspect "${TEST_IMAGE}" >/dev/null 2>&1; then
    printf 'check_file: %s 還不存在，所以 %s **沒有**被檢查。\n' "${TEST_IMAGE}" "$1" >&2
    printf 'check_file: 下一步：先跑一次 ./script/test.sh 把它建起來。這裡不建，是因為 hook 要快\n' >&2
    return 0
  fi

  # --user：映像的使用者是 root，而 root 程序寫進 bind mount 會在主機留下 root 所有
  # 的檔案。這裡只讀不寫，但掛載是雙向的，理由與 test.sh 相同，做法也保持相同。
  exec docker run --rm \
    --user "$(id -u):$(id -g)" \
    --env HOME=/tmp \
    --env CM_IN_TEST_IMAGE=1 \
    --volume "${REPO_ROOT}:/repo" \
    --workdir /repo \
    "${TEST_IMAGE}" \
    ./script/check_file.sh "$1"
}

main() {
  case "${1:-}" in -h | --help)
    usage
    return 0
    ;;
  esac

  if [[ -z "${1:-}" ]]; then
    hook_reminder
    return 0
  fi

  local file
  file="$(relative_path "$1")"
  [[ -n "${file}" ]] || return 0
  [[ -f "${REPO_ROOT}/${file}" ]] || return 0

  # 只有會被檢查的路徑才值得付一次容器啟動的代價。這個判斷要在轉進去之前做，
  # 否則每一次編輯任何檔案都會多等一秒。
  [[ -n "$(checks_for "${file}")" ]] || return 0

  if [[ "${CM_IN_TEST_IMAGE:-}" != "1" && "${CM_TEST_LOCAL:-}" != "1" ]]; then
    dispatch_to_container "${file}"
    return 0
  fi

  run_checks "${file}"
}

main "$@"
