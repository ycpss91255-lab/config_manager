#!/usr/bin/env bash
#
# `just setup hooks`／`just setup hooks-off` 的本體（#391、#406）：打開或關掉這個 repo 的本機 git hook。
#
# 只動這個 repo 的本地設定裡的 `core.hooksPath`（`git config --local`），不改全域（~/.gitconfig）、
# 系統設定，不安裝任何工具。**這份本地設定由同一個 repo 的所有 worktree 共用**（git-worktree 文件），
# 所以它不宣稱只影響目前的工作目錄。值是相對路徑 `.githooks`：git 在各個 worktree 的根目錄解析它，
# 每個 worktree 用的是自己簽出的 `.githooks/`；簽出的 commit 裡沒有 `.githooks/` 的，不會執行 hook。
#
# 分開看三種來源，不覆蓋、不誤刪別人的設定：
#   本地（local）          這支唯一會寫、會拿掉的那一份；而且只拿掉值剛好是 .githooks 的
#   單一 worktree（worktree）extensions.worktreeConfig 打開時的 config.worktree，它蓋過本地
#   繼承來的（global、system、command）
#                          本地設值會讓它們在這個 repo 不再生效，所以有它們時不設
# 本地的值是 .githooks 時，分不出是這支設的還是手動設的，一律當成這支的設定。
set -euo pipefail

readonly WANT=".githooks"

usage() {
  cat <<'USAGE'
用法：script/setup_hooks.sh on|off

  on    把這個 repo 的本地 core.hooksPath 設成 .githooks（just setup hooks）
  off   拿掉這個 repo 本地的 core.hooksPath，只在它是 .githooks 時（just setup hooks-off）

只動這個 repo 的本地設定，它由所有 worktree 共用；不改全域與系統設定。
USAGE
}

refuse() {
  printf 'setup_hooks: %s\n' "$1" >&2
  printf 'setup_hooks: 下一步：%s\n' "$2" >&2
  exit 1
}

LOCAL_VALUES=()
WORKTREE_VALUES=()
INHERITED=()

# 讀出每一個 core.hooksPath 與它的範圍。沒有任何值時 git 以 1 結束，那不是錯誤。
read_values() {
  git rev-parse --git-dir >/dev/null 2>&1 \
    || refuse "目前目錄（${PWD}）不在 git repo 裡，沒有 core.hooksPath 可以設" "在 config_manager 的簽出裡執行"
  local listing scope value code=0
  listing="$(git config --show-scope --get-all core.hooksPath)" || code=$?
  ((code == 0 || code == 1)) \
    || refuse "git config 讀不出 core.hooksPath（結束碼 ${code}）" "確認 git 是 2.26 以上（要有 --show-scope），再跑一次"
  while IFS=$'\t' read -r scope value; do
    [[ -n "${scope}" ]] || continue
    case "${scope}" in
      local) LOCAL_VALUES+=("${value}") ;;
      worktree) WORKTREE_VALUES+=("${value}") ;;
      global) INHERITED+=("全域設定：${value}") ;;
      system) INHERITED+=("系統設定：${value}") ;;
      *) INHERITED+=("${scope}：${value}") ;;
    esac
  done <<<"${listing}"
}

turn_on() {
  read_values
  if ((${#WORKTREE_VALUES[@]} > 0)); then
    refuse "這個 worktree 有單一 worktree 範圍的 core.hooksPath（${WORKTREE_VALUES[*]}），它蓋過 repo 的本地設定，所以沒有設" \
      "要用 .githooks/，先確認那個值不再需要，自己拿掉（git config --worktree --unset core.hooksPath），再跑 just setup hooks"
  fi
  if ((${#LOCAL_VALUES[@]} > 0)); then
    if ((${#LOCAL_VALUES[@]} == 1)) && [[ "${LOCAL_VALUES[0]}" == "${WANT}" ]]; then
      printf 'setup_hooks: 已經啟用：這個 repo 的本地 core.hooksPath 是 %s，沒有改任何設定\n' "${WANT}"
      return 0
    fi
    refuse "這個 repo 的本地 core.hooksPath 已經是 ${LOCAL_VALUES[*]}，沒有覆蓋它" \
      "要改用 .githooks/，先確認那個值不再需要，自己拿掉（git config --local --unset-all core.hooksPath），再跑 just setup hooks"
  fi
  if ((${#INHERITED[@]} > 0)); then
    refuse "core.hooksPath 從別處繼承來（${INHERITED[*]}）；在這個 repo 設本地值，那裡的 hook 在這個 repo 就不再執行，所以沒有設" \
      "要兩邊都跑，讓那個 hook 目錄也呼叫 .githooks/ 的進入點；確定這個 repo 只要 .githooks/，就自己設 git config --local core.hooksPath .githooks"
  fi
  git config --local core.hooksPath "${WANT}"
  printf 'setup_hooks: 已啟用：這個 repo 的本地 core.hooksPath 設成 %s\n' "${WANT}"
  printf 'setup_hooks: 這份設定由這個 repo 的所有 worktree 共用；簽出裡沒有 .githooks/ 的 worktree 不會執行 hook\n'
  printf 'setup_hooks: 登記的檢查在這台主機上直接跑，不經 docker（要 bash 4 以上、python3、git，缺了 commit 與 push 會被擋下並說明）；解除：just setup hooks-off\n'
}

turn_off() {
  read_values
  if ((${#LOCAL_VALUES[@]} == 1)) && [[ "${LOCAL_VALUES[0]}" == "${WANT}" ]]; then
    git config --local --unset core.hooksPath
    printf 'setup_hooks: 已解除：拿掉這個 repo 本地的 core.hooksPath（%s），它的所有 worktree 都不再執行 .githooks/\n' "${WANT}"
    ((${#INHERITED[@]} == 0)) \
      || printf 'setup_hooks: 繼承來的 core.hooksPath 仍然有效：%s\n' "${INHERITED[*]}"
    return 0
  fi
  if ((${#LOCAL_VALUES[@]} > 0)); then
    printf 'setup_hooks: 這個 repo 本地的 core.hooksPath 是 %s，不是 just setup hooks 設的 %s，沒有動它\n' "${LOCAL_VALUES[*]}" "${WANT}"
    return 0
  fi
  if ((${#INHERITED[@]} > 0)); then
    printf 'setup_hooks: 這個 repo 本地沒有設 core.hooksPath；現在的值來自全域或系統設定（%s），這支不動全域與系統設定，要在那裡處理\n' "${INHERITED[*]}"
    return 0
  fi
  printf 'setup_hooks: 這個 repo 沒有設 core.hooksPath，沒有要解除的\n'
}

main() {
  case "${1:-}" in
    on) turn_on ;;
    off) turn_off ;;
    -h | --help) usage ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
