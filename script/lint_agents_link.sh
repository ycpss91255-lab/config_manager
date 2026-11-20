#!/usr/bin/env bash
#
# 規範正本 AGENTS.md 與指向它的 CLAUDE.md，在 git 樹與工作樹裡是不是該有的形狀（#404）。
#
# 規範正本是一般檔 AGENTS.md；CLAUDE.md 是指向它的相對 symlink（git 記成 mode 120000、內容剛好是
# AGENTS.md）。Claude Code 讀 CLAUDE.md，經由連結讀到 AGENTS.md 的內容。連結被換成一般檔之後，規範就
# 分成兩份，改了其中一份另一份不會跟著變——而 `.agents/skills/setup-matt-pocock-skills/SKILL.md` 的指示
# 正是「改 CLAUDE.md」，用先寫新檔再換名的工具（例如 GNU sed 的 -i）去改，連結就會被換掉。
#
# 兩項檢查分開判定、分開回報，因為它們抓得到的時機不同：
#
#   git 樹   這一輪受驗的 commit（`git ls-tree HEAD`）。commit 之後一定抓得到；CI 簽出的就是受驗的
#            commit，所以 CI 上兩項看的是同一份內容。
#   工作樹   實際簽出的檔案。換掉了還沒 commit 時，只有這一項抓得到——要在本機跑 `./script/test.sh --lint`。
#
# **擋不住的**：AGENTS.md 的內容對不對。這裡只看連結的形狀。
set -euo pipefail

usage() {
  cat <<'USAGE'
用法：script/lint_agents_link.sh

  在目前所在的 git repo 的根目錄檢查兩項，分開回報：

  git 樹   HEAD 裡的 CLAUDE.md 是 mode 120000、內容剛好是 AGENTS.md；
           AGENTS.md 是 mode 100644 的一般檔（不是 symlink，也不是目錄）
  工作樹   CLAUDE.md 是指向 AGENTS.md 的 symlink；AGENTS.md 是一般檔；經 CLAUDE.md 讀得到內容

  exit 0   兩項都通過
  exit 1   至少一項失敗
  exit 2   不在 git repo 裡，或用法不對
USAGE
}

# git 樹裡一個項目的 mode，說成人讀得懂的種類。
tree_kind() {
  case "$1" in
    100644) printf '一般檔' ;;
    100755) printf '可執行的一般檔' ;;
    120000) printf 'symlink' ;;
    040000) printf '目錄' ;;
    160000) printf 'submodule' ;;
    *) printf '不認得的種類' ;;
  esac
}

# 工作樹裡一個存在、但不是 symlink 的路徑，說成人讀得懂的種類。
work_kind() {
  if [[ -d "$1" ]]; then
    printf '目錄'
  elif [[ -f "$1" ]]; then
    printf '一般檔'
  else
    printf '特殊檔'
  fi
}

# symlink 的目標，原樣（不吃掉結尾的換行：目標是「AGENTS.md」加一個換行時，那是另一個檔名）。
link_target() {
  local target
  target="$(readlink "$1"; printf x)"
  printf '%s' "${target%$'\n'x}"
}

# git 樹：這一輪受驗的 commit。
check_tree() {
  local head
  if ! head="$(git rev-parse --verify --quiet 'HEAD^{commit}')"; then
    printf 'lint_agents_link: git 樹：失敗——讀不到 HEAD（還沒有任何 commit？），CLAUDE.md 與 AGENTS.md 在 git 裡的形狀無從檢查\n' >&2
    printf 'lint_agents_link: 下一步：先 commit，或在有 commit 的簽出裡執行\n' >&2
    return 1
  fi

  local failed=0 mode sha target
  read -r mode _ sha _ <<<"$(git ls-tree "${head}" -- CLAUDE.md)"
  if [[ -z "${mode}" ]]; then
    printf 'lint_agents_link: git 樹：失敗——HEAD 裡沒有 CLAUDE.md\n' >&2
    printf 'lint_agents_link: 下一步：ln -s AGENTS.md CLAUDE.md，git add CLAUDE.md 後 commit\n' >&2
    failed=1
  elif [[ "${mode}" != 120000 ]]; then
    printf 'lint_agents_link: git 樹：失敗——CLAUDE.md 在 HEAD 裡是%s（mode %s），不是指向 AGENTS.md 的 symlink（mode 120000）\n' \
      "$(tree_kind "${mode}")" "${mode}" >&2
    printf 'lint_agents_link: 下一步：先把 CLAUDE.md 裡的改動搬進 AGENTS.md，再 rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md，git add CLAUDE.md 後 commit\n' >&2
    failed=1
  else
    target="$(git cat-file blob "${sha}"; printf x)"
    target="${target%x}"
    if [[ "${target}" != AGENTS.md ]]; then
      printf 'lint_agents_link: git 樹：失敗——CLAUDE.md 在 HEAD 裡是 symlink，但指向 %s，不是 AGENTS.md\n' "${target}" >&2
      printf 'lint_agents_link: 下一步：rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md（相對路徑，目標剛好是 AGENTS.md），git add CLAUDE.md 後 commit\n' >&2
      failed=1
    fi
  fi

  mode=""
  read -r mode _ sha _ <<<"$(git ls-tree "${head}" -- AGENTS.md)"
  if [[ -z "${mode}" ]]; then
    printf 'lint_agents_link: git 樹：失敗——HEAD 裡沒有 AGENTS.md（規範正本），CLAUDE.md 指向的目標不在\n' >&2
    printf 'lint_agents_link: 下一步：把規範內容放回一般檔 AGENTS.md 後 commit；被刪掉的話用 git log -- AGENTS.md 找回\n' >&2
    failed=1
  elif [[ "${mode}" != 100644 ]]; then
    printf 'lint_agents_link: git 樹：失敗——AGENTS.md 在 HEAD 裡是 %s（mode %s），規範正本要是 mode 100644 的一般檔\n' \
      "$(tree_kind "${mode}")" "${mode}" >&2
    printf 'lint_agents_link: 下一步：把 AGENTS.md 換成內容相同的一般檔（不是 symlink、不是目錄、沒有執行權限），git add AGENTS.md 後 commit\n' >&2
    failed=1
  fi

  if ((failed == 0)); then
    printf 'lint_agents_link: git 樹：通過（HEAD %s：CLAUDE.md 是 mode 120000、指向 AGENTS.md；AGENTS.md 是 mode 100644 的一般檔）\n' \
      "$(git rev-parse --short=12 "${head}")"
  fi
  return "${failed}"
}

# 工作樹：實際簽出的檔案。
check_worktree() {
  local failed=0 target
  if [[ -L CLAUDE.md ]]; then
    target="$(link_target CLAUDE.md)"
    if [[ "${target}" != AGENTS.md ]]; then
      printf 'lint_agents_link: 工作樹：失敗——CLAUDE.md 是 symlink，但指向 %s，不是 AGENTS.md\n' "${target}" >&2
      printf 'lint_agents_link: 下一步：rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md（相對路徑，目標剛好是 AGENTS.md）\n' >&2
      failed=1
    fi
  elif [[ -e CLAUDE.md ]]; then
    printf 'lint_agents_link: 工作樹：失敗——CLAUDE.md 是%s，不是指向 AGENTS.md 的 symlink（還沒 commit 的話，可能是被先寫新檔再換名的工具換掉了，例如 GNU sed 的就地編輯）\n' \
      "$(work_kind CLAUDE.md)" >&2
    printf 'lint_agents_link: 下一步：先把 CLAUDE.md 裡的改動搬進 AGENTS.md，再 rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md；沒有要留的改動，就 git checkout -- CLAUDE.md 還原\n' >&2
    failed=1
  else
    printf 'lint_agents_link: 工作樹：失敗——CLAUDE.md 不存在\n' >&2
    printf 'lint_agents_link: 下一步：ln -s AGENTS.md CLAUDE.md\n' >&2
    failed=1
  fi

  if [[ -L AGENTS.md ]]; then
    printf 'lint_agents_link: 工作樹：失敗——AGENTS.md 是 symlink（指向 %s），規範正本要是一般檔\n' "$(link_target AGENTS.md)" >&2
    printf 'lint_agents_link: 下一步：把 AGENTS.md 換成內容相同的一般檔\n' >&2
    failed=1
  elif [[ ! -e AGENTS.md ]]; then
    printf 'lint_agents_link: 工作樹：失敗——AGENTS.md 不存在（規範正本），CLAUDE.md 指向的目標不在\n' >&2
    printf 'lint_agents_link: 下一步：把規範內容放回一般檔 AGENTS.md；被刪掉的話用 git checkout -- AGENTS.md 還原\n' >&2
    failed=1
  elif [[ ! -f AGENTS.md ]]; then
    printf 'lint_agents_link: 工作樹：失敗——AGENTS.md 是%s，規範正本要是一般檔\n' "$(work_kind AGENTS.md)" >&2
    printf 'lint_agents_link: 下一步：把 AGENTS.md 換成一般檔，規範內容寫在裡面\n' >&2
    failed=1
  fi

  # 形狀都對，才問讀不讀得到：連結或目標本身錯了，讀到的也不是規範正本。
  if ((failed == 0)) && ! { [[ -s CLAUDE.md ]] && cat CLAUDE.md >/dev/null 2>&1; }; then
    printf 'lint_agents_link: 工作樹：失敗——經 CLAUDE.md 讀不到內容（AGENTS.md 是空的，或沒有讀取權限）\n' >&2
    printf 'lint_agents_link: 下一步：確認 AGENTS.md 有規範內容、而且讀得到\n' >&2
    failed=1
  fi

  if ((failed == 0)); then
    printf 'lint_agents_link: 工作樹：通過（CLAUDE.md 是指向 AGENTS.md 的 symlink；AGENTS.md 是一般檔；經 CLAUDE.md 讀得到內容）\n'
  fi
  return "${failed}"
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      return 0
      ;;
    "") ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  local top
  if ! top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf 'lint_agents_link: git 樹：無從檢查——這裡不是 git repo（%s），CLAUDE.md 與 AGENTS.md 的形狀都沒有被檢查\n' "$(pwd)" >&2
    printf 'lint_agents_link: 下一步：在 repo 的簽出裡執行，或確認容器掛載到了正確的位置\n' >&2
    return 2
  fi
  cd "${top}"

  local failed=0
  check_tree || failed=1
  check_worktree || failed=1
  return "${failed}"
}

main "$@"
