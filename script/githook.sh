#!/usr/bin/env bash
#
# 本機 git hook 的共用入口（#391、#406）。`.githooks/<進入點>` 把 git 給的參數原樣交給這支，標準輸入
# 也原樣繼承：commit-msg 的參數是訊息檔的路徑；pre-push 的參數是 remote 名稱與 URL，標準輸入
# 每一行是「本地 ref 本地 SHA 遠端 ref 遠端 SHA」。
#
# **登記的檢查在這台主機上直接跑，不經 docker**（維護者 11/20 定案，#406；ADR-00000027 的 Amendment）。
# 這是 commit、push 之前提早攔的一層，不是證據：主機的工具和檢查映像不同，CI 在映像裡跑同一支檢查，
# 是最後一道。
#
# 判斷的先後：
#   1. 先數登記的檢查（`script/githook-checks/<進入點>/` 底下的可執行檔）。一支都沒有就放行並說明，
#      不看主機工具——沒有要執行的東西，也就不需要工具。
#   2. 有登記的檢查，先確認主機有：PATH 上先找到的 bash 是 4 以上（登記的檢查以 `#!/usr/bin/env bash`
#      啟動，用的就是那一支，不一定是執行這支的那一支）、python3、git。缺任何一項就非零結束並寫出
#      下一步，不放行（#406 的 Q8：不默默放寬保護）。
#   3. 依檔名順序執行每一支。commit-msg：每支都收到 git 給的訊息檔路徑；git 不給標準輸入，這裡也不讀，
#      每支收到空的標準輸入（直接在終端機執行時才不會停下來等輸入）。pre-push：每支都收到兩個參數，
#      標準輸入先存成暫存檔，每支都收到完整的一份。
#   4. 任何一支失敗就非零結束，逐支指名失敗的那幾支；原因由各支自己印。
#
# 圖形介面的 git 用戶端可能帶著不同的 PATH，先找到 macOS 內建的 bash 3.2：第 2 步擋下並說明。所以這支
# 在走到第 2 步的說明之前，只用 bash 3.2 也有的寫法（沒有 mapfile、關聯陣列，不展開空陣列）。
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_ROOT

STDIN_COPY=""
cleanup() {
  if [[ -n "${STDIN_COPY}" ]]; then
    rm -f "${STDIN_COPY}"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
用法：script/githook.sh <commit-msg|pre-push> [git 給 hook 的參數…]

由 .githooks/ 的進入點呼叫（just setup hooks 之後，git 會在 commit 與 push 時觸發）。
登記的檢查放在 script/githook-checks/<進入點>/，在這台主機上依檔名順序直接執行，不經 docker。
有登記的檢查時，主機要有 bash 4 以上（PATH 上先找到的那一支）、python3 與 git。
USAGE
}

# 有登記的檢查時才問：主機缺什麼。每缺一項印一行（都帶下一步），缺任何一項就回 1。
host_missing() {
  local entry="$1" missing=0 bash_path major=""
  if bash_path="$(command -v bash)"; then
    major="$(bash -c 'printf "%s" "${BASH_VERSINFO[0]}"' 2>/dev/null)" || major=""
    if ! [[ "${major}" =~ ^[0-9]+$ ]] || ((major < 4)); then
      printf 'githook: %s 有登記的檢查，但 PATH 上先找到的 bash（%s）主版本是 %s，登記的檢查要 bash 4 以上，git 不會繼續。下一步：macOS 用 brew install bash，並讓 Homebrew 的 bin（例如 /opt/homebrew/bin）在 PATH 上排在 /bin 前面\n' \
        "${entry}" "${bash_path}" "${major:-（讀不出來）}" >&2
      missing=1
    fi
  else
    printf 'githook: %s 有登記的檢查，但 PATH 上找不到 bash，登記的檢查要 bash 4 以上，git 不會繼續。下一步：macOS 用 brew install bash，並讓 Homebrew 的 bin 在 PATH 上找得到\n' \
      "${entry}" >&2
    missing=1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'githook: %s 有登記的檢查，但 PATH 上找不到 python3，登記的檢查要用它，git 不會繼續。下一步：裝 Python 3（macOS 用 brew install python），讓 python3 在 PATH 上找得到\n' \
      "${entry}" >&2
    missing=1
  fi
  if ! command -v git >/dev/null 2>&1; then
    printf 'githook: %s 有登記的檢查，但 PATH 上找不到 git，登記的檢查要用它，git 不會繼續。下一步：macOS 用 xcode-select --install 或 brew install git，讓 git 在 PATH 上找得到\n' \
      "${entry}" >&2
    missing=1
  fi
  return "${missing}"
}

main() {
  local entry="${1:-}"
  case "${entry}" in
    commit-msg | pre-push) shift ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  local -a checks=()
  local check
  for check in "${REPO_ROOT}/script/githook-checks/${entry}"/*; do
    if [[ -f "${check}" && -x "${check}" ]]; then
      checks+=("${check}")
    fi
  done
  if ((${#checks[@]} == 0)); then
    printf 'githook: %s 目前沒有登記任何檢查，放行（登記的位置：script/githook-checks/%s/）\n' "${entry}" "${entry}"
    return 0
  fi

  host_missing "${entry}" || return 1

  local input=/dev/null
  if [[ "${entry}" == pre-push ]]; then
    STDIN_COPY="$(mktemp "${TMPDIR:-/tmp}/githook-pre-push.XXXXXX")"
    cat >"${STDIN_COPY}"
    input="${STDIN_COPY}"
  fi

  local code name failed=""
  for check in "${checks[@]}"; do
    name="${check#"${REPO_ROOT}"/}"
    code=0
    "${check}" "$@" <"${input}" || code=$?
    if ((code != 0)); then
      printf 'githook: %s 的檢查 %s 沒有通過（結束碼 %d），原因是它在上面印的那幾行。下一步：照那幾行修正，再重新 commit 或 push\n' \
        "${entry}" "${name}" "${code}" >&2
      failed="${failed:+${failed}、}${name}"
    fi
  done
  if [[ -n "${failed}" ]]; then
    printf 'githook: %s 沒有通過的檢查：%s；git 不會繼續。下一步：逐支照上面的原因修正，再重新 commit 或 push\n' \
      "${entry}" "${failed}" >&2
    return 1
  fi
}

main "$@"
