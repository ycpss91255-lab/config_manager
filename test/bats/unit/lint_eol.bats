#!/usr/bin/env bats
#
# script/lint_eol.sh —— 換行規則在不在，以及索引裡有沒有含 CRLF 的文字檔（T19、#439）。
#
# 兩項檢查分開判定、分開回報：
#   規則  根目錄的 .gitattributes 有組織共用的換行規則區塊：開頭與結尾兩行標記，兩者之間有 `* text=auto eol=lf`。
#   索引  追蹤的檔在索引裡含 CRLF（git ls-files --eol 的 i/crlf、i/mixed）而且沒有 -text 屬性時，逐檔指名。
#
# 測的是公開行為：在暫存目錄建一份真的 git repo，造出各種形狀再執行，看結束碼與訊息指名的是哪一項、哪個檔。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  LINT="${REPO_ROOT}/script/lint_eol.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  cd "${WORK}" || return 1
  git init -q .
  git config user.name spec
  git config user.email spec@example.invalid
  # 規格自己決定索引裡是什麼換行，不讓執行環境的設定代為轉換。
  git config core.autocrlf false
}

teardown() {
  cd / || true
  rm -rf "${WORK}"
}

# 共用區塊裡這支檢查會看的三行，加上一條別的規則。
rules_block() {
  printf '%s\n' \
    '# managed by template: line endings begin (do not remove)' \
    '* text=auto eol=lf' \
    '*.pdf binary' \
    '# managed by template: line endings end (do not remove)'
}

commit_all() {
  git add -A
  git commit -q -m spec
}

# 輸出裡有一行依序帶著這幾段字。逐行比對：整段輸出一起比的話，「規則：失敗」與只出現在索引那一行的檔名也會
# 湊成一對，指名的是哪一項就看不出來了。
has_line() {
  local pattern="" part
  for part in "$@"; do
    pattern+="${part}.*"
  done
  grep -qE -- "${pattern}" <<<"${output}"
}

@test ".gitattributes 有共用區塊、索引裡沒有含 CRLF 的檔時，規則與索引兩項都通過" {
  rules_block >.gitattributes
  printf 'echo ok\n' >run.sh
  commit_all

  run "${LINT}"

  [ "${status}" -eq 0 ]
  has_line "規則：通過"
  has_line "索引：通過"
}

@test "這個 repo 自己的簽出通過" {
  cd "${REPO_ROOT}" || return 1

  run "${LINT}"

  [ "${status}" -eq 0 ]
}

@test "沒有 .gitattributes 時，規則那一項失敗" {
  printf 'echo ok\n' >run.sh
  commit_all

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "規則：失敗" ".gitattributes"
  has_line "索引：通過"
}

@test ".gitattributes 沒有開頭標記時，規則那一項失敗" {
  printf '* text=auto eol=lf\n' >.gitattributes
  commit_all

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "規則：失敗" "開頭標記"
}

@test ".gitattributes 有開頭標記、沒有結尾標記時，規則那一項失敗" {
  rules_block | sed '$d' >.gitattributes
  commit_all

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "規則：失敗" "結尾標記"
}

@test "區塊裡沒有 * text=auto eol=lf 時，規則那一項失敗" {
  rules_block | sed '2d' >.gitattributes
  commit_all

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "規則：失敗" "text=auto eol=lf"
}

@test "* text=auto eol=lf 寫在結尾標記之後時，規則那一項失敗" {
  rules_block | sed '2d' >.gitattributes
  printf '* text=auto eol=lf\n' >>.gitattributes
  commit_all

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "規則：失敗" "text=auto eol=lf"
}

@test "索引裡有含 CRLF 的文字檔時，索引那一項失敗並指名那個檔" {
  # 先在沒有規則時把 CRLF 的檔 commit 進去，再補規則而不 renormalize：索引裡留著 CRLF。
  printf 'echo ok\r\n' >run.sh
  printf 'fine\n' >ok.md
  commit_all
  rules_block >.gitattributes
  git add .gitattributes
  git commit -q -m rules

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "規則：通過"
  has_line "索引：失敗" "run.sh"
  ! has_line "索引：失敗" "ok.md"
}

@test "索引裡有 CRLF 與 LF 混用的文字檔時，索引那一項失敗並指名那個檔" {
  printf 'one\r\ntwo\n' >mixed.txt
  commit_all
  rules_block >.gitattributes
  git add .gitattributes
  git commit -q -m rules

  run "${LINT}"

  [ "${status}" -ne 0 ]
  has_line "索引：失敗" "mixed.txt"
}

@test "含 CRLF 的檔帶 -text 屬性時，索引那一項通過" {
  rules_block >.gitattributes
  printf '\nfixture.txt -text\n' >>.gitattributes
  printf 'one\r\ntwo\r\n' >fixture.txt
  commit_all

  run "${LINT}"

  [ "${status}" -eq 0 ]
  has_line "索引：通過"
}

@test "不在 git repo 裡時以 2 結束，說明無從檢查" {
  rm -rf .git
  rules_block >.gitattributes

  run "${LINT}"

  [ "${status}" -eq 2 ]
  has_line "無從檢查" "git repo"
}

@test "帶了不認得的參數時以 2 結束並印用法" {
  run "${LINT}" --nope

  [ "${status}" -eq 2 ]
  has_line "用法"
}
