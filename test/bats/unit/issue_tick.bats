#!/usr/bin/env bats
#
# script/issue_tick.sh —— 勾 issue 的帳本：只把一條未勾的驗收條件勾起來，行尾加「 — <commit 主旨>」（T19、#413 調整需求第 6 點）。
#
# 測的是公開行為：命令列與 PATH 上的假 gh 進去，看結束碼、訊息，以及假 gh 收到的參數與內文。commit 主旨的核對在目前目錄的
# git repo 裡查，所以每個規格在 ${WORK}/repo 建一個臨時的 git repo、做幾個 commit，並從那裡執行。
#
# 假 gh：gh issue view <N> 印出 ${FIX}/issue-<N>.json，旁邊有 <檔>.next 時回完之後換成它（觀察「兩次讀到的本文不同」）；
# gh issue edit 把參數逐行記在 ${FIX}/calls.log，--body-file 的內容複製到 ${FIX}/sent-body。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  TICK="${REPO_ROOT}/script/issue_tick.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  FIX="${WORK}/fix"
  STUB="${WORK}/bin"
  REPO="${WORK}/repo"
  mkdir -p "${FIX}" "${STUB}" "${REPO}"
  : >"${FIX}/calls.log"
  cat >"${STUB}/gh" <<'STUB'
#!/usr/bin/env python3
import os, shutil, sys
FIX = os.environ["FIX"]
args = sys.argv[1:]
with open(os.path.join(FIX, "calls.log"), "a", encoding="utf-8") as log:
    log.write("\t".join(args) + "\n")
if args[:2] == ["issue", "view"]:
    path = os.path.join(FIX, f"issue-{args[2]}.json")
    sys.stdout.write(open(path, encoding="utf-8").read())
    if os.path.exists(path + ".next"):
        os.replace(path + ".next", path)
    sys.exit(0)
if args[:2] == ["issue", "edit"]:
    shutil.copy(args[args.index("--body-file") + 1], os.path.join(FIX, "sent-body"))
    sys.exit(0)
print("假 gh 不認得這個呼叫：" + " ".join(args), file=sys.stderr)
sys.exit(64)
STUB
  chmod +x "${STUB}/gh"
  export FIX
  PATH="${STUB}:${PATH}"
  git -C "${REPO}" init -q
  git -C "${REPO}" -c user.name=spec -c user.email=spec@example.com commit -q --allow-empty -m "chore(x): 做好了第一條"
  SUBJECT="chore(x): 做好了第一條"
  COAUTHOR="Co-Authored-By"": Claude Opus 5 <noreply@anthropic.com>"
  NL=$'\n'
  CRLF=$'\r\n'
}

teardown() {
  rm -rf "${WORK}"
}

# body <編號> <本文>：假 gh 回答的本文。
body() {
  python3 -c 'import json, sys; print(json.dumps({"body": sys.argv[1]}, ensure_ascii=False))' "$2" >"${FIX}/issue-$1.json"
}

tick() {
  cd "${REPO}"
  run "${TICK}" "$@"
}

edits() {
  grep -cE "^issue"$'\t'"edit" "${FIX}/calls.log" || true
}

LEDGER="#### 驗收條件
- [ ] 第一條 hook 擋開 issue
- [ ] 第二條 submit 做出快照
結尾"

@test "只改對到的那一行：[ ] 改成 [x]、行尾加「 — 主旨」，其他位元組不變" {
  body 5 "${LEDGER}"
  tick 5 "第一條" "${SUBJECT}"

  [ "${status}" -eq 0 ]
  [ "$(cat "${FIX}/sent-body")" = "#### 驗收條件
- [x] 第一條 hook 擋開 issue — ${SUBJECT}
- [ ] 第二條 submit 做出快照
結尾" ]
}

@test "* [ ] 與 + [ ] 開頭的未勾行也認得" {
  local marker
  for marker in '*' '+'; do
    body 5 "${marker} [ ] 第一條${NL}${marker} [ ] 第二條"
    tick 5 "第二條" "${SUBJECT}"
    [ "$(cat "${FIX}/sent-body")" = "${marker} [ ] 第一條${NL}${marker} [x] 第二條 — ${SUBJECT}" ] ||
      { echo "沒認得：${marker}"; return 1; }
  done
}

@test "CRLF 的本文送出時是 LF" {
  body 5 "- [ ] 第一條${CRLF}- [ ] 第二條${CRLF}"
  tick 5 "第一條" "${SUBJECT}"

  [ "${status}" -eq 0 ]
  [ "$(cat "${FIX}/sent-body"; printf .)" = "- [x] 第一條 — ${SUBJECT}${NL}- [ ] 第二條${NL}." ]
}

@test "假 gh 收到的是 issue edit <編號>，旗標只有 --repo 與 --body-file，目標寫死成本 repo" {
  body 5 "${LEDGER}"
  GH_REPO=other/repo tick 5 "第一條" "${SUBJECT}"

  [ "${status}" -eq 0 ]
  python3 -c '
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
edit = [l.split("\t") for l in lines if l.startswith("issue\tedit")]
assert len(edit) == 1, lines
args = edit[0]
assert args[:3] == ["issue", "edit", "5"], args
assert [a for a in args if a.startswith("-")] == ["--repo", "--body-file"], args
assert args[args.index("--repo") + 1] == "github.com/ycpss91255-lab/config_manager", args' "${FIX}/calls.log"
}

@test "下列情況以非零結束、不呼叫 gh issue edit，並寫出下一步" {
  local case
  for case in none two emptysubject newline unknown changed attribution; do
    : >"${FIX}/calls.log"
    rm -f "${FIX}/issue-5.json.next"
    body 5 "${LEDGER}"
    case "${case}" in
      none) tick 5 "第三條" "${SUBJECT}" ;;
      two) tick 5 "條" "${SUBJECT}" ;;
      emptysubject) tick 5 "第一條" "" ;;
      newline) tick 5 "第一條" "${SUBJECT}${NL}夾帶的一行" ;;
      unknown) tick 5 "第一條" "chore(x): 歷史裡沒有的主旨" ;;
      changed)
        python3 -c 'import json, sys; print(json.dumps({"body": sys.argv[1]}, ensure_ascii=False))' "${LEDGER}${NL}有人改了" \
          >"${FIX}/issue-5.json.next"
        tick 5 "第一條" "${SUBJECT}"
        ;;
      attribution) body 5 "${LEDGER}${NL}${COAUTHOR}"; tick 5 "第一條" "${SUBJECT}" ;;
    esac
    [ "${status}" -ne 0 ] || { echo "沒停：${case}"; return 1; }
    [[ "${output}" == *"下一步"* ]] || { echo "沒寫下一步：${case}"; return 1; }
    [ "$(edits)" -eq 0 ] || { echo "呼叫了 gh issue edit：${case}"; return 1; }
  done
}

@test "主旨不在 HEAD 與 origin/main 的 git 歷史裡時，原因寫出那個主旨" {
  body 5 "${LEDGER}"
  tick 5 "第一條" "chore(x): 歷史裡沒有的主旨"
  [[ "${output}" == *"chore(x): 歷史裡沒有的主旨"*"git 歷史"* ]]
}
