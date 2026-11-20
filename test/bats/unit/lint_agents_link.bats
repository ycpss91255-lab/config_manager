#!/usr/bin/env bats
#
# script/lint_agents_link.sh —— 規範正本 AGENTS.md 與指向它的 CLAUDE.md，在 git 樹與工作樹裡是不是該有的形狀
# （T19、#404）。
#
# 規範正本是一般檔 AGENTS.md；CLAUDE.md 是指向它的相對 symlink（git 記成 mode 120000、內容剛好是 AGENTS.md）。
# 兩項檢查分開判定、分開回報：git 樹看這一輪受驗的 commit（git ls-tree HEAD），工作樹看實際簽出的檔案。
# 有人照 skill 的指示「改 CLAUDE.md」時，用 sed -i 這類先寫新檔再換名的工具，連結會被換成一般檔——還沒 commit
# 時只有工作樹那一項抓得到，commit 之後兩項都抓得到。
#
# 測的是公開行為：在暫存目錄建一份真的 git repo，造出各種形狀再執行，看結束碼與訊息指名的是哪一項。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  LINT="${REPO_ROOT}/script/lint_agents_link.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  cd "${WORK}" || return 1
  git init -q .
  git config user.name spec
  git config user.email spec@example.invalid
}

teardown() {
  cd / || true
  rm -rf "${WORK}"
}

# 該有的形狀：AGENTS.md 是一般檔，CLAUDE.md 是指向它的相對 symlink。
good_shape() {
  printf '# AGENTS.md\n\n規範內容\n' >AGENTS.md
  ln -s AGENTS.md CLAUDE.md
}

commit_all() {
  git add -A
  git commit -q -m spec
}

# 輸出裡有一行依序帶著這幾段字。逐行比對：整段輸出一起比的話，「git 樹：失敗」與只出現在工作樹那一行的
# 檔名也會湊成一對，指名的是哪一項就看不出來了。
has_line() {
  local pattern="" part
  for part in "$@"; do
    pattern+="${part}.*"
  done
  grep -qE -- "${pattern}" <<<"${output}"
}

@test "AGENTS.md 是一般檔、CLAUDE.md 是指向它的 symlink 時，git 樹與工作樹兩項都通過" {
  good_shape
  commit_all

  run "${LINT}"

  [ "${status}" -eq 0 ]
  has_line "git 樹：通過"
  has_line "工作樹：通過"
}

@test "這個 repo 自己的簽出通過" {
  cd "${REPO_ROOT}" || return 1

  run "${LINT}"

  [ "${status}" -eq 0 ]
}

@test "CLAUDE.md 是一般檔並已 commit 時，git 樹與工作樹兩項都失敗" {
  printf '# AGENTS.md\n\n規範內容\n' >AGENTS.md
  cp AGENTS.md CLAUDE.md
  commit_all

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "git 樹：失敗" "CLAUDE.md"
  has_line "工作樹：失敗" "CLAUDE.md"
}

@test "CLAUDE.md 是指向別的檔的 symlink 時，兩項都失敗" {
  printf '# AGENTS.md\n' >AGENTS.md
  printf '# 別的檔\n' >README.md
  ln -s README.md CLAUDE.md
  commit_all

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "git 樹：失敗" "README.md"
  has_line "工作樹：失敗" "README.md"
}

@test "AGENTS.md 不存在時，兩項都失敗" {
  ln -s AGENTS.md CLAUDE.md
  commit_all

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "git 樹：失敗" "AGENTS.md"
  has_line "工作樹：失敗" "AGENTS.md"
}

@test "AGENTS.md 本身是 symlink 時，兩項都失敗" {
  mkdir doc
  printf '# 規範\n' >doc/rules.md
  ln -s doc/rules.md AGENTS.md
  ln -s AGENTS.md CLAUDE.md
  commit_all

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "git 樹：失敗" "AGENTS.md" "symlink"
  has_line "工作樹：失敗" "AGENTS.md" "symlink"
}

@test "AGENTS.md 是目錄時，兩項都失敗" {
  mkdir AGENTS.md
  printf '# 規範\n' >AGENTS.md/rules.md
  ln -s AGENTS.md CLAUDE.md
  commit_all

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "git 樹：失敗" "AGENTS.md" "目錄"
  has_line "工作樹：失敗" "AGENTS.md" "目錄"
}

@test "git 樹正常、工作樹的 CLAUDE.md 被換成一般檔還沒 commit 時，只有工作樹那一項失敗" {
  good_shape
  commit_all
  rm CLAUDE.md
  cp AGENTS.md CLAUDE.md

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "git 樹：通過"
  has_line "工作樹：失敗" "CLAUDE.md"
}

@test "錯的形狀已 commit、工作樹改回 symlink 還沒 commit 時，只有 git 樹那一項失敗" {
  printf '# AGENTS.md\n' >AGENTS.md
  cp AGENTS.md CLAUDE.md
  commit_all
  rm CLAUDE.md
  ln -s AGENTS.md CLAUDE.md

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "git 樹：失敗" "CLAUDE.md"
  has_line "工作樹：通過"
}

@test "不在 git repo 裡時失敗，說明 git 樹無從檢查" {
  rm -rf .git
  good_shape

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "git 樹" "git repo"
}
