#!/usr/bin/env bats
#
# script/issue_draft.sh —— 開 issue 與改 issue 本文的審稿流程：審稿工作階段判定通過的那一份，就是開出去或改上去的那一份
# （T19、#413 調整需求第 1～5 點）。
#
# 測的是公開行為：命令列、環境變數與 PATH 上的假 gh 進去，看結束碼、訊息、.issue-drafts 底下的檔，以及假 gh 收到的參數與內文。
# 腳本以自己所在簽出的頂層放 .issue-drafts，所以每個規格把它和樣式清單複製到 ${TREE}/script/ 底下執行，不碰這個 repo。
#
# 假 gh（${STUB}/gh）：
#   gh issue view <N> …      → 印出 ${FIX}/issue-<N>.json；旁邊有 <檔>.next 時，回完之後換成它（觀察「送審之後被改過」）
#   gh issue create|edit …   → 參數逐行記在 ${FIX}/calls.log（tab 隔開），--body-file 的內容複製到 ${FIX}/sent-body；
#                              create 印出一個網址。${FIX}/before-send 存在時，讀 --body-file 之前先執行它（觀察「核對之後改了草稿」）；
#                              ${FIX}/gate 存在時，先建 ${FIX}/started，等 ${FIX}/release 出現才繼續（觀察鎖）
# 工作階段 id 以環境變數給：寫的人是 writer，審稿是 reviewer。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  TREE="${WORK}/tree"
  FIX="${WORK}/fix"
  STUB="${WORK}/bin"
  mkdir -p "${TREE}/script" "${FIX}" "${STUB}"
  cp "${REPO_ROOT}/script/issue_draft.sh" "${REPO_ROOT}/script/attribution-patterns.txt" "${TREE}/script/"
  DRAFT="${TREE}/script/issue_draft.sh"
  DIR="${TREE}/.issue-drafts/x"
  mkdir -p "${DIR}"
  printf 'chore(x): 一個標題\n' >"${DIR}/title.txt"
  printf '內文第一行\n- [ ] 一條驗收\n' >"${DIR}/body.md"
  : >"${FIX}/calls.log"
  fake_gh
  ID="CLAUDE_CODE_""SESSION_ID"
  HOST_ID="CLAUDE_CODE_""HOST_SESSION_ID"
  unset "${HOST_ID}"
  export FIX
  PATH="${STUB}:${PATH}"
  COAUTHOR="Co-Authored-By"": Claude Opus 5 <noreply@anthropic.com>"
}

teardown() {
  [ -e "${FIX}/release" ] || touch "${FIX}/release"
  rm -rf "${WORK}"
}

fake_gh() {
  cat >"${STUB}/gh" <<'STUB'
#!/usr/bin/env python3
import os, shutil, subprocess, sys, time
FIX = os.environ["FIX"]
args = sys.argv[1:]
with open(os.path.join(FIX, "calls.log"), "a", encoding="utf-8") as log:
    log.write("\t".join(args) + "\n")
if args[:2] == ["issue", "view"]:
    path = os.path.join(FIX, f"issue-{args[2]}.json")
    if not os.path.exists(path):
        print("GraphQL: Could not resolve to an issue", file=sys.stderr)
        sys.exit(1)
    sys.stdout.write(open(path, encoding="utf-8").read())
    if os.path.exists(path + ".next"):
        os.replace(path + ".next", path)
    sys.exit(0)
if args[:2] in (["issue", "create"], ["issue", "edit"]):
    if os.path.exists(os.path.join(FIX, "gate")):
        open(os.path.join(FIX, "started"), "w").close()
        for _ in range(600):
            if os.path.exists(os.path.join(FIX, "release")):
                break
            time.sleep(0.05)
    hook = os.path.join(FIX, "before-send")
    if os.path.exists(hook):
        subprocess.run(["bash", hook], check=True)
    shutil.copy(args[args.index("--body-file") + 1], os.path.join(FIX, "sent-body"))
    if args[1] == "create":
        print("https://github.com/ycpss91255-lab/config_manager/issues/999")
    sys.exit(0)
print("假 gh 不認得這個呼叫：" + " ".join(args), file=sys.stderr)
sys.exit(64)
STUB
  chmod +x "${STUB}/gh"
}

# as <工作階段 id> <參數…>：以那個工作階段 id 執行 issue_draft.sh（id 是空字串時清掉變數）。
as() {
  local who="$1"
  shift
  if [ -z "${who}" ]; then
    run env -u "${ID}" "${DRAFT}" "$@"
  else
    run env "${ID}=${who}" "${DRAFT}" "$@"
  fi
}

# submit_new：寫的人送審，SHA 設成印出的雜湊、SNAPDIR 設成快照資料夾。
submit_new() {
  as writer submit x --new
  [ "${status}" -eq 0 ]
  SHA="$(printf '%s\n' "${output}" | sed -n 's/^  雜湊：//p')"
  SNAPDIR="${DIR}/snapshots/${SHA}"
}

# issue_json <編號> <標題> <本文>：假 gh 回答的 GitHub 上那張 issue。
issue_json() {
  python3 -c 'import json, sys; print(json.dumps({"title": sys.argv[1], "body": sys.argv[2]}, ensure_ascii=False))' \
    "$2" "$3" >"${FIX}/issue-$1.json"
}

# submit_edit：寫的人送審改 #7 的本文。
submit_edit() {
  issue_json 7 "舊的標題" "舊的本文"
  as writer submit x --edit 7
  [ "${status}" -eq 0 ]
  SHA="$(printf '%s\n' "${output}" | sed -n 's/^  雜湊：//p')"
  SNAPDIR="${DIR}/snapshots/${SHA}"
}

# opinion <判定>：寫一份意見檔，最後一個非空行是「判定：<判定>」。
opinion() {
  printf '第一點意見\n\n判定：%s\n\n' "$1" >"${WORK}/opinion.md"
}

# reviewed <判定>：審稿工作階段下判定。
reviewed() {
  opinion "$1"
  as reviewer verdict x "${SHA}" "${WORK}/opinion.md"
}

writes() {
  grep -cE "^issue"$'\t'"(create|edit)" "${FIX}/calls.log" || true
}

expected_sha() {
  python3 -c 'import hashlib, sys
title = open(sys.argv[1], "rb").read()
title = title[:-1] if title.endswith(b"\n") else title
print(hashlib.sha256(title + b"\n" + open(sys.argv[2], "rb").read()).hexdigest())' "${DIR}/title.txt" "${DIR}/body.md"
}

# ── submit ────────────────────────────────────────────────────────────────

@test "submit 以「標題、換行、內文」的 sha256 做出快照，印出雜湊" {
  submit_new
  [ "${SHA}" = "$(expected_sha)" ]
}

@test "submit 的快照有 title.txt、body.md 與記著用途和寫的人的 meta" {
  submit_new
  cmp "${SNAPDIR}/body.md" "${DIR}/body.md"
  cmp "${SNAPDIR}/title.txt" "${DIR}/title.txt"
  grep -qx 'kind=new' "${SNAPDIR}/meta"
  grep -qx 'writer=writer' "${SNAPDIR}/meta"
}

@test "submit 印出要送給協調工作階段的那段話，含審稿工作階段要執行的 verdict 指令" {
  submit_new
  [[ "${output}" == *"SendMessage"*"verdict x ${SHA} <意見檔>"* ]]
}

@test "submit --edit 另存 GitHub 上送審當時的標題與本文" {
  submit_edit
  [ "$(cat "${SNAPDIR}/base/body.md")" = "舊的本文" ]
  [ "$(cat "${SNAPDIR}/base/title.txt")" = "舊的標題" ]
  grep -qx 'issue=7' "${SNAPDIR}/meta"
}

@test "同一份內容重新 submit，原有的審稿紀錄被刪掉" {
  submit_new
  reviewed 可以開
  [ -f "${SNAPDIR}/review.md" ]
  as writer submit x --new

  [ "${status}" -eq 0 ]
  [ ! -e "${SNAPDIR}/review.md" ]
}

@test "已經開過（有 published）的同一份內容再 submit：以非零結束、印出網址，published 與紀錄都不變" {
  submit_new
  reviewed 可以開
  as anyone create x
  cp "${SNAPDIR}/review.md" "${WORK}/review.before"
  as writer submit x --new

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"issues/999"* ]]
  [ -f "${SNAPDIR}/published" ]
  cmp "${SNAPDIR}/review.md" "${WORK}/review.before"
}

@test "submit 在下列情況以非零結束、不做快照，並寫出下一步" {
  local case
  for case in noid twolines empty cr attribution locked; do
    rm -rf "${DIR}/snapshots" "${DIR}/.lock"
    printf 'chore(x): 一個標題\n' >"${DIR}/title.txt"
    printf '內文\n' >"${DIR}/body.md"
    case "${case}" in
      noid) as "" submit x --new ;;
      twolines) printf 'a\nb\n' >"${DIR}/title.txt"; as writer submit x --new ;;
      empty) printf '\n' >"${DIR}/title.txt"; as writer submit x --new ;;
      cr) printf '內文\r\n' >"${DIR}/body.md"; as writer submit x --new ;;
      attribution) printf '內文\n%s\n' "${COAUTHOR}" >"${DIR}/body.md"; as writer submit x --new ;;
      locked) mkdir "${DIR}/.lock"; as writer submit x --new ;;
    esac
    [ "${status}" -ne 0 ] || { echo "沒停：${case}"; return 1; }
    [[ "${output}" == *"下一步"* ]] || { echo "沒寫下一步：${case}"; return 1; }
    [ ! -d "${DIR}/snapshots" ] || [ -z "$(ls -A "${DIR}/snapshots")" ] || { echo "做了快照：${case}"; return 1; }
  done
}

# ── verdict ───────────────────────────────────────────────────────────────

@test "verdict 寫出的紀錄第一行是判定、草稿的雜湊與審稿的工作階段 id" {
  local result
  for result in 可以開 要修改; do
    submit_new
    reviewed "${result}"
    [ "${status}" -eq 0 ] || { echo "失敗：${result}"; return 1; }
    [ "$(head -n 1 "${SNAPDIR}/review.md")" = "issue-review: ${result} sha256=${SHA} reviewer=reviewer" ] ||
      { echo "第一行不對：${result}"; return 1; }
  done
}

@test "改本文的快照判「可以發」時，紀錄第一行是可以發" {
  submit_edit
  reviewed 可以發

  [ "${status}" -eq 0 ]
  [ "$(head -n 1 "${SNAPDIR}/review.md")" = "issue-review: 可以發 sha256=${SHA} reviewer=reviewer" ]
}

@test "verdict 的紀錄在第一行之後是意見檔全文" {
  submit_new
  reviewed 可以開
  tail -n +2 "${SNAPDIR}/review.md" >"${WORK}/rest"
  cmp "${WORK}/rest" "${WORK}/opinion.md"
}

@test "verdict 在下列情況不留下紀錄（原本判定通過的也刪掉），以非零結束並指名原因" {
  local case record zeros
  zeros="$(printf '0%.0s' $(seq 64))"
  for case in self noid nosnap tampered noopinion emptyopinion noverdict mismatch; do
    submit_new
    reviewed 可以開
    [ -f "${SNAPDIR}/review.md" ] || { echo "前置失敗：${case}"; return 1; }
    opinion 可以開
    record="${SNAPDIR}/review.md"
    case "${case}" in
      self) as writer verdict x "${SHA}" "${WORK}/opinion.md" ;;
      noid) as "" verdict x "${SHA}" "${WORK}/opinion.md" ;;
      nosnap) record="${DIR}/snapshots/${zeros}/review.md"; as reviewer verdict x "${zeros}" "${WORK}/opinion.md" ;;
      tampered) printf '偷改\n' >>"${SNAPDIR}/body.md"; as reviewer verdict x "${SHA}" "${WORK}/opinion.md" ;;
      noopinion) as reviewer verdict x "${SHA}" "${WORK}/missing.md" ;;
      emptyopinion) printf '\n\n' >"${WORK}/opinion.md"; as reviewer verdict x "${SHA}" "${WORK}/opinion.md" ;;
      noverdict) printf '意見\n判定可以開\n' >"${WORK}/opinion.md"; as reviewer verdict x "${SHA}" "${WORK}/opinion.md" ;;
      mismatch) opinion 可以發; as reviewer verdict x "${SHA}" "${WORK}/opinion.md" ;;
    esac
    [ "${status}" -ne 0 ] || { echo "沒停：${case}"; return 1; }
    [[ "${output}" == *"下一步"* ]] || { echo "沒寫下一步：${case}"; return 1; }
    [ ! -e "${record}" ] || { echo "留下紀錄：${case}"; return 1; }
  done
}

@test "verdict 由執行 submit 的同一個工作階段執行時，原因寫寫的人不自己審" {
  submit_new
  opinion 可以開
  as writer verdict x "${SHA}" "${WORK}/opinion.md"
  [[ "${output}" == *"寫的人不自己審"* ]]
}

@test "鎖在別人手上時，verdict 以非零結束、紀錄不動" {
  submit_new
  reviewed 可以開
  cp "${SNAPDIR}/review.md" "${WORK}/review.before"
  mkdir "${DIR}/.lock"
  reviewed 要修改

  [ "${status}" -ne 0 ]
  cmp "${SNAPDIR}/review.md" "${WORK}/review.before"
}

# ── create／edit 停下的情況 ───────────────────────────────────────────────

@test "create／edit 在下列情況以非零結束、不呼叫寫入的 gh，並寫出下一步" {
  local case action
  for case in changed rejected norecord nosnap nometa notitle samereviewer kind attribution published basechanged \
    titlechanged; do
    rm -rf "${DIR}/snapshots" "${DIR}/.lock"
    printf 'chore(x): 一個標題\n' >"${DIR}/title.txt"
    printf '內文\n' >"${DIR}/body.md"
    action=create
    case "${case}" in
      basechanged | titlechanged) action=edit; submit_edit; reviewed 可以發 ;;
      *) submit_new; reviewed 可以開 ;;
    esac
    case "${case}" in
      changed) printf '審完又改\n' >>"${DIR}/body.md" ;;
      rejected) reviewed 要修改 ;;
      norecord) rm "${SNAPDIR}/review.md" ;;
      nosnap) rm -rf "${SNAPDIR}" ;;
      nometa) rm "${SNAPDIR}/meta" ;;
      notitle) rm "${DIR}/title.txt" ;;
      samereviewer) sed -i.bak 's/reviewer=reviewer/reviewer=writer/' "${SNAPDIR}/review.md" ;;
      kind) action=edit ;;
      attribution)
        printf '%s\n' "${COAUTHOR}" >>"${DIR}/body.md"
        cp "${DIR}/body.md" "${SNAPDIR}/body.md"
        sha="$(expected_sha)"
        mv "${SNAPDIR}" "${DIR}/snapshots/${sha}"
        sed -i.bak "s/${SHA}/${sha}/" "${DIR}/snapshots/${sha}/meta" "${DIR}/snapshots/${sha}/review.md"
        ;;
      published) as anyone create x; : >"${FIX}/calls.log" ;;
      basechanged) issue_json 7 "舊的標題" "有人勾了帳本" ;;
      titlechanged) issue_json 7 "有人改了標題" "舊的本文" ;;
    esac
    : >"${FIX}/calls.log"
    as anyone "${action}" x
    [ "${status}" -ne 0 ] || { echo "沒停：${case}"; return 1; }
    [[ "${output}" == *"下一步"* ]] || { echo "沒寫下一步：${case}"; return 1; }
    [ "$(writes)" -eq 0 ] || { echo "呼叫了寫入的 gh：${case}"; return 1; }
  done
}

# ── create／edit 送出 ─────────────────────────────────────────────────────

@test "create 判定通過時，假 gh 收到的子命令與旗標固定、目標寫死成本 repo" {
  submit_new
  reviewed 可以開
  : >"${FIX}/calls.log"
  GH_REPO=other/repo GH_HOST=ghe.example.com as anyone create x

  [ "${status}" -eq 0 ]
  python3 -c '
import sys
args = open(sys.argv[1], encoding="utf-8").read().rstrip("\n").split("\t")
flags = [a for a in args if a.startswith("-")]
assert args[:2] == ["issue", "create"], args
assert flags == ["--repo", "--title", "--body-file"], flags
assert args[args.index("--repo") + 1] == "github.com/ycpss91255-lab/config_manager", args
assert args[args.index("--title") + 1] == "chore(x): 一個標題", args' "${FIX}/calls.log"
}

@test "create 送出的內文和快照逐位元組相同" {
  submit_new
  reviewed 可以開
  as anyone create x
  cmp "${FIX}/sent-body" "${SNAPDIR}/body.md"
}

@test "核對之後、呼叫 gh 之前改了 body.md，假 gh 收到的仍是快照" {
  submit_new
  reviewed 可以開
  printf 'printf "偷改\\n" >>%q\n' "${DIR}/body.md" >"${FIX}/before-send"
  as anyone create x

  [ "${status}" -eq 0 ]
  cmp "${FIX}/sent-body" "${SNAPDIR}/body.md"
}

@test "create 成功後寫出 published，記著 gh 印出的網址" {
  submit_new
  reviewed 可以開
  as anyone create x
  [ "$(cat "${SNAPDIR}/published")" = "https://github.com/ycpss91255-lab/config_manager/issues/999" ]
}

@test "edit 判定通過時，假 gh 收到 issue edit <編號>，旗標只有 --repo、--title、--body-file" {
  submit_edit
  reviewed 可以發
  : >"${FIX}/calls.log"
  GH_REPO=other/repo as anyone edit x

  [ "${status}" -eq 0 ]
  python3 -c '
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
edit = [l.split("\t") for l in lines if l.startswith("issue\tedit")]
assert len(edit) == 1, lines
args = edit[0]
flags = [a for a in args if a.startswith("-")]
assert args[:3] == ["issue", "edit", "7"], args
assert flags == ["--repo", "--title", "--body-file"], flags
assert args[args.index("--repo") + 1] == "github.com/ycpss91255-lab/config_manager", args' "${FIX}/calls.log"
}

@test "edit 送出的內文和快照逐位元組相同" {
  submit_edit
  reviewed 可以發
  as anyone edit x
  cmp "${FIX}/sent-body" "${SNAPDIR}/body.md"
}

# ── 鎖 ────────────────────────────────────────────────────────────────────

# slow_create：背景跑一個 create，等假 gh 開始（拿著鎖）才回來。
slow_create() {
  touch "${FIX}/gate"
  env "${ID}=anyone" "${DRAFT}" create x >"${WORK}/first.out" 2>&1 3>&- &
  FIRST=$!
  local i
  for i in $(seq 200); do
    [ -e "${FIX}/started" ] && return 0
    sleep 0.05
  done
  echo "背景的 create 沒有走到 gh"
  return 1
}

@test "同一份草稿同時跑兩個 create：第二個以非零結束、不呼叫 gh" {
  submit_new
  reviewed 可以開
  slow_create
  : >"${FIX}/calls.log"
  as anyone create x
  touch "${FIX}/release"
  wait "${FIRST}"

  [ "${status}" -ne 0 ]
  [ "$(writes)" -eq 0 ]
}

@test "create 拿著鎖時，verdict 以非零結束、紀錄不動，送出的仍是原本判定通過的那一份" {
  submit_new
  reviewed 可以開
  cp "${SNAPDIR}/review.md" "${WORK}/review.before"
  slow_create
  reviewed 要修改
  local verdict_status="${status}"
  touch "${FIX}/release"
  wait "${FIRST}"

  [ "${verdict_status}" -ne 0 ]
  cmp "${SNAPDIR}/review.md" "${WORK}/review.before"
  cmp "${FIX}/sent-body" "${SNAPDIR}/body.md"
}

@test "submit 拿著鎖時，create 拒絕發布" {
  submit_new
  reviewed 可以開
  mkdir "${DIR}/.lock"
  : >"${FIX}/calls.log"
  as anyone create x

  [ "${status}" -ne 0 ]
  [ "$(writes)" -eq 0 ]
}
