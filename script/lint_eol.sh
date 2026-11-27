#!/usr/bin/env bash
#
# 換行規則 lint。文字檔在 repo 裡一律 LF：規則不在，或索引裡有含 CRLF 的文字檔，就失敗（#439）。
#
# 這個 repo 的 shell 腳本、Dockerfile、bats 規格、justfile 都在 Linux 容器裡執行。它們以 CRLF 進到容器會壞
# （`\r: command not found`、shebang 失效），而簽出時是 LF 還是 CRLF，在沒有規則時取決於每台機器的
# `core.autocrlf`。規則寫在根目錄的 `.gitattributes`：最上方是組織共用的換行規則區塊，夾在兩行標記之間
# （ycpss91255-lab/base#2246），本 repo 自己的例外寫在結尾標記之下。
#
# 兩項檢查分開判定、分開回報，因為它們壞掉的方式不同：
#
#   規則  工作樹裡的 `.gitattributes` 有那個區塊：開頭標記、結尾標記，兩者之間有 `* text=auto eol=lf`。
#         區塊被刪掉、標記被改字、那條規則被搬到標記之外，都算沒有。
#   索引  追蹤的檔在索引裡含 CRLF（`git ls-files --eol` 的 `i/crlf`、`i/mixed`）而且沒有 `-text` 屬性。
#         規則在的時候 `git add` 會把文字檔轉成 LF 才進索引，所以這一項抓的是規則加上之前就 commit 進來、
#         之後沒有 `git add --renormalize` 的檔，以及規則被拿掉之後進來的檔。
#
# 刻意要保留 CRLF 的檔（例如含 CR 的測試資料），在 `.gitattributes` 的結尾標記之下標成 `-text`；
# `binary` 屬性包含 `-text`。
#
# **擋不住的**：區塊的內容是不是和組織的那一份逐位元組相同——這裡只看兩行標記與 `* text=auto eol=lf`。
# 區塊的全文由 base 那一邊的升級機制維護，抄一份在這裡比對，只會多一份會過期的副本（不變式 9）。
# 工作樹裡還沒 `git add` 的檔也不看：它們還不在索引裡。區塊是不是在檔案的最上方不檢查（只找第一對標記）；
# 結尾標記之下的規則會蓋過區塊（最後符合的那一行生效），所以在那裡寫一條範圍很大的 `-text`（例如 `* -text`）
# 等於把規則關掉，而這支不會出聲——那裡加了什麼要靠 review。
set -euo pipefail

readonly RULES_FILE='.gitattributes'
readonly BEGIN_MARK='# managed by template: line endings begin (do not remove)'
readonly END_MARK='# managed by template: line endings end (do not remove)'
readonly LF_RULE='* text=auto eol=lf'

usage() {
  cat <<'USAGE'
用法：script/lint_eol.sh

  在目前所在的 git repo 的根目錄檢查兩項，分開回報：

  規則   .gitattributes 有組織共用的換行規則區塊：開頭與結尾兩行標記，
         兩者之間有 `* text=auto eol=lf`
  索引   追蹤的檔在索引裡沒有含 CRLF 的（git ls-files --eol 的 i/crlf、i/mixed）；
         帶 -text 屬性的檔不算

  exit 0   兩項都通過
  exit 1   至少一項失敗
  exit 2   不在 git repo 裡，或用法不對
USAGE
}

# 規則：工作樹裡的 .gitattributes（git 套用的就是這一份）。
check_rules() {
  if [[ ! -f "${RULES_FILE}" ]]; then
    printf 'lint_eol: 規則：失敗——根目錄沒有 %s，簽出的換行取決於每台機器的 core.autocrlf\n' "${RULES_FILE}" >&2
    printf 'lint_eol: 下一步：把組織共用的換行規則區塊（含兩行標記）放進 %s 的最上方後 commit（#439 有全文）\n' "${RULES_FILE}" >&2
    return 1
  fi

  # 0 還沒遇到開頭標記；1 在區塊裡；2 已經過了結尾標記。
  local state=0 has_rule=0 line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${state}" in
      0) [[ "${line}" == "${BEGIN_MARK}" ]] && state=1 ;;
      1)
        if [[ "${line}" == "${END_MARK}" ]]; then
          state=2
        elif [[ "${line}" == "${LF_RULE}" ]]; then
          has_rule=1
        fi
        ;;
      *) break ;;
    esac
  done <"${RULES_FILE}"

  if ((state == 0)); then
    printf 'lint_eol: 規則：失敗——%s 沒有共用區塊的開頭標記「%s」\n' "${RULES_FILE}" "${BEGIN_MARK}" >&2
    printf 'lint_eol: 下一步：把組織共用的換行規則區塊（含兩行標記，不改字）放回 %s 的最上方（#439 有全文）\n' "${RULES_FILE}" >&2
    return 1
  fi
  if ((state == 1)); then
    printf 'lint_eol: 規則：失敗——%s 有開頭標記，但後面沒有結尾標記「%s」\n' "${RULES_FILE}" "${END_MARK}" >&2
    printf 'lint_eol: 下一步：在 %s 的共用區塊最後補回結尾標記那一行（不改字）；本 repo 自己的規則寫在它之下\n' "${RULES_FILE}" >&2
    return 1
  fi
  if ((has_rule == 0)); then
    printf 'lint_eol: 規則：失敗——%s 的共用區塊裡（兩行標記之間）沒有「%s」\n' "${RULES_FILE}" "${LF_RULE}" >&2
    printf 'lint_eol: 下一步：把 %s 的共用區塊還原成組織的那一份（#439 有全文），「%s」要在兩行標記之間\n' "${RULES_FILE}" "${LF_RULE}" >&2
    return 1
  fi

  printf 'lint_eol: 規則：通過（%s 有共用區塊，區塊裡有「%s」）\n' "${RULES_FILE}" "${LF_RULE}"
}

# 索引：追蹤的檔在索引裡的換行。git ls-files --eol 一行一個檔：
#   i/<索引裡的換行> w/<工作樹裡的換行> attr/<屬性><TAB><路徑>
check_index() {
  local listing
  if ! listing="$(git ls-files --eol)"; then
    printf 'lint_eol: 索引：失敗——在 %s 執行 git ls-files --eol 沒有成功，索引裡的換行沒有被檢查\n' "$(pwd)" >&2
    printf 'lint_eol: 下一步：在 %s 執行 git ls-files --eol 看它回報的原因\n' "$(pwd)" >&2
    return 1
  fi

  # 違規的檔先收起來，最後和下一步一起印：逐檔各印一次下一步，檔一多就讀不到重點。
  local report="" total=0 info path attributes
  while IFS=$'\t' read -r info path; do
    [[ -n "${info}" ]] || continue
    total=$((total + 1))
    case "${info}" in
      i/crlf* | i/mixed*) ;;
      *) continue ;;
    esac
    attributes="${info#*attr/}"
    # -text（binary 也會展開成它）：這個檔的換行是刻意的，git 不轉換。
    case " ${attributes} " in
      *' -text '*) continue ;;
    esac
    report+="lint_eol: 索引：失敗——${path} 在索引裡含 CRLF（${info%% *}），而且沒有 -text 屬性"$'\n'
  done <<<"${listing}"

  if [[ -n "${report}" ]]; then
    printf '%slint_eol: 下一步：執行 git add --renormalize . 後 commit（只改換行的另成一筆）；要保留 CRLF 的檔，在 %s 的結尾標記之下標成 -text\n' \
      "${report}" "${RULES_FILE}" >&2
    return 1
  fi
  printf 'lint_eol: 索引：通過（追蹤的 %d 個項目裡，沒有含 CRLF 而不帶 -text 屬性的）\n' "${total}"
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
    printf 'lint_eol: 無從檢查——這裡不是 git repo（%s），%s 與索引裡的換行都沒有被檢查\n' "$(pwd)" "${RULES_FILE}" >&2
    printf 'lint_eol: 下一步：在 repo 的簽出裡執行，或確認容器掛載到了正確的位置\n' >&2
    return 2
  fi
  cd "${top}"

  local failed=0
  check_rules || failed=1
  check_index || failed=1
  return "${failed}"
}

main "$@"
