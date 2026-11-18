#!/usr/bin/env bats
#
# script/setup_hooks.sh — 打開與關掉本機 git hook 時，動了哪一份 git 設定（T19、#391）。
#
# 它只設這個 repo 的 core.hooksPath。這份本地設定由同一個 repo 的所有 worktree 共用，所以
# 不宣稱只影響目前的工作目錄。全域與系統設定以受控的 HOME、XDG_CONFIG_HOME、
# GIT_CONFIG_SYSTEM 指到暫存檔，看它們有沒有被改；repo 是暫存目錄裡一份真的 git repo。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/script/setup_hooks.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  export HOME="${WORK}/home" XDG_CONFIG_HOME="${WORK}/xdg" GIT_CONFIG_SYSTEM="${WORK}/system-gitconfig"
  unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
  mkdir -p "${HOME}" "${XDG_CONFIG_HOME}"
  REPO="${WORK}/repo"
  git init -q "${REPO}"
  git -C "${REPO}" -c user.email=spec@example.com -c user.name=spec commit -q --allow-empty -m "chore: fixture"
  cd "${REPO}" || return 1
}

teardown() {
  rm -rf "${WORK}"
}

# 全域與系統兩份設定檔現在的樣子；不存在就寫「不存在」。
outside_configs() {
  local file
  for file in "${HOME}/.gitconfig" "${XDG_CONFIG_HOME}/git/config" "${GIT_CONFIG_SYSTEM}"; do
    if [[ -e "${file}" ]]; then
      printf '%s:\n%s\n' "${file}" "$(cat "${file}")"
    else
      printf '%s: 不存在\n' "${file}"
    fi
  done
}

@test "本地沒有設時設成 .githooks，訊息寫明這份設定由所有 worktree 共用" {
  run "${SCRIPT}" on

  [ "${status}" -eq 0 ]
  [ "$(git config --local --get core.hooksPath)" = ".githooks" ]
  [[ "${output}" == *"所有 worktree"* ]]
}

@test "打開時訊息也寫明簽出裡沒有 .githooks/ 就不會執行 hook" {
  run "${SCRIPT}" on

  [[ "${output}" == *".githooks/"*"不會執行"* ]]
}

@test "打開與關掉都不改全域與系統設定檔" {
  local before
  before="$(outside_configs)"

  run "${SCRIPT}" on
  [ "${status}" -eq 0 ]
  run "${SCRIPT}" off
  [ "${status}" -eq 0 ]

  [ "$(outside_configs)" = "${before}" ]
}

@test "再跑一次時設定不變，以 0 結束並說明已經啟用" {
  "${SCRIPT}" on >/dev/null
  local before
  before="$(cat .git/config)"

  run "${SCRIPT}" on

  [ "${status}" -eq 0 ]
  [ "$(cat .git/config)" = "${before}" ]
  [[ "${output}" == *"已經啟用"* ]]
}

@test "在 worktree 裡執行時設在共用的本地設定，主簽出也讀得到" {
  git worktree add -q "${WORK}/wt"
  cd "${WORK}/wt" || return 1

  run "${SCRIPT}" on

  [ "${status}" -eq 0 ]
  [ "$(git -C "${REPO}" config --local --get core.hooksPath)" = ".githooks" ]
}

@test "本地已經是別的值時不覆蓋，非零結束並指名那個值" {
  git config --local core.hooksPath custom-hooks

  run "${SCRIPT}" on

  [ "${status}" -ne 0 ]
  [ "$(git config --local --get core.hooksPath)" = "custom-hooks" ]
  [[ "${output}" == *"custom-hooks"* ]]
}

@test "本地沒有設、全域有值時不覆蓋也不在本地設值，說明繼承來的 hook 會不再執行" {
  git config --global core.hooksPath "${HOME}/global-hooks"
  local before
  before="$(outside_configs)"

  run "${SCRIPT}" on

  [ "${status}" -ne 0 ]
  ! git config --local --get core.hooksPath
  [ "$(outside_configs)" = "${before}" ]
  [[ "${output}" == *"${HOME}/global-hooks"*"不再執行"* ]]
}

@test "有單一 worktree 範圍的值時不覆蓋，非零結束並說明" {
  git config extensions.worktreeConfig true
  git config --worktree core.hooksPath wt-hooks

  run "${SCRIPT}" on

  [ "${status}" -ne 0 ]
  ! git config --local --get core.hooksPath
  [[ "${output}" == *"wt-hooks"*"worktree"* ]]
}

@test "關掉時拿掉本地的 .githooks" {
  "${SCRIPT}" on >/dev/null

  run "${SCRIPT}" off

  [ "${status}" -eq 0 ]
  ! git config --local --get core.hooksPath
}

@test "關掉時本地是別的值就不動，說明那不是這支設的" {
  git config --local core.hooksPath custom-hooks

  run "${SCRIPT}" off

  [ "$(git config --local --get core.hooksPath)" = "custom-hooks" ]
  [[ "${output}" == *"custom-hooks"* ]]
}

@test "關掉時本地沒有設、全域是 .githooks 就不動全域，說明要在全域那裡處理" {
  git config --global core.hooksPath .githooks
  local before
  before="$(outside_configs)"

  run "${SCRIPT}" off

  [ "$(outside_configs)" = "${before}" ]
  [[ "${output}" == *"全域"* ]]
}
