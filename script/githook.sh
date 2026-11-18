#!/usr/bin/env bash
#
# 本機 git hook 的共用入口（#391）。`.githooks/<進入點>` 把 git 給的參數原樣交給這支，標準輸入
# 也原樣繼承：commit-msg 的參數是訊息檔的路徑；pre-push 的參數是 remote 名稱與 URL，標準輸入
# 每一行是「本地 ref 本地 SHA 遠端 ref 遠端 SHA」。
#
# **檢查在檢查映像裡跑，不在這台主機上**（CLAUDE.md「所有檢查一律在容器內執行」，維護者
# 11/18 定案不另開主機例外）：轉給 `script/test.sh --hook`，由它轉進映像——轉進時帶 -i，
# 標準輸入才進得了容器。環境裡的 CM_TEST_LOCAL／CM_IN_TEST_IMAGE 在這裡拿掉，hook 不會因為
# 它們改在主機跑。容器跑不起來（docker 不在、映像建不起來、docker run 失敗）時以非零結束，
# git 就不會繼續——不放行。
#
# 登記的檢查是 `script/githook-checks/<進入點>/` 底下的可執行檔，依檔名順序執行。一支都沒有
# 時這裡直接放行並說明，不為了零支檢查去建映像。
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_ROOT

usage() {
  cat <<'USAGE'
用法：script/githook.sh <commit-msg|pre-push> [git 給 hook 的參數…]

由 .githooks/ 的進入點呼叫（just setup hooks 之後，git 會在 commit 與 push 時觸發）。
登記的檢查放在 script/githook-checks/<進入點>/，在檢查映像裡依檔名順序執行。
USAGE
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

  local check count=0
  for check in "${REPO_ROOT}/script/githook-checks/${entry}"/*; do
    [[ -f "${check}" && -x "${check}" ]] && count=$((count + 1))
  done
  if ((count == 0)); then
    printf 'githook: %s 目前沒有登記任何檢查，放行（登記的位置：script/githook-checks/%s/）\n' "${entry}" "${entry}"
    return 0
  fi

  local code=0
  env -u CM_TEST_LOCAL -u CM_IN_TEST_IMAGE "${REPO_ROOT}/script/test.sh" --hook "${entry}" "$@" || code=$?
  if ((code != 0)); then
    printf 'githook: %s 的檢查沒有完成或沒有通過（結束碼 %d），git 不會繼續。\n' "${entry}" "${code}" >&2
    printf 'githook: 下一步：照上面的原因修正後再試；檢查在檢查映像裡跑（script/test.sh --hook），這台機器的 docker 要能用\n' >&2
    return "${code}"
  fi
}

main "$@"
