#!/usr/bin/env bats
#
# script/scrub_attribution.sh —— 清掉既有 PR 與 issue 說明裡的 Claude 署名與 session 連結（T19、#410，#269 第 3 步）。
#
# 測的是公開行為：命令列與 PATH 上的假 gh 進去，看結束碼、訊息、備份目錄裡的檔，以及假 gh 收到的寫入。
# 假 gh 是一份小小的 GitHub：${FIX}/state.json 存 PR 與 issue（PR 的說明只存在 pulls 那邊），列舉時一頁固定
# 2 筆（不管 per_page），沒帶 state=all 時照 GitHub 的預設只回開著的。issues 的列舉照 GitHub 的樣子把 PR 也
# 放進去（帶 pull_request 欄位）。每一次呼叫逐行記在 ${FIX}/calls.log，寫入另記在 ${FIX}/writes.log。
# 失敗注入：${FIX}/fail-<pulls|issues>-page-<N>（那一頁讀取失敗）、${FIX}/garbage-<pulls|issues>-page-<N>
# （那一頁回的不是 JSON）、${FIX}/fail-patch-<pulls|issues>-<N>（那一份寫入失敗）。
# 署名的字樣在執行時才組出來，這份檔案裡沒有從行首開始的署名行，也沒有完整的 session 網址。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  SCRUB="${REPO_ROOT}/script/scrub_attribution.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  FIX="${WORK}/fix"
  STUB="${WORK}/bin"
  BACKUP="${WORK}/backup"
  mkdir -p "${FIX}" "${STUB}"
  printf '{"pulls": [], "issues": []}\n' >"${FIX}/state.json"
  : >"${FIX}/calls.log"
  : >"${FIX}/writes.log"
  fake_gh
  export FIX
  NL=$'\n'
  CR=$'\r'
  COAUTHOR="Co-Authored-By"": Claude Opus 5 <noreply@anthropic.com>"
  SESSION_LINE="Claude-Session"": https://claude.ai/code/session_""01SpecFakeIdAa"
  GENERATED="🤖 Generated with [Claude Code]""(https://claude.com/claude-code)"
  SESSION_URL="https://claude.ai/code/session_""01SpecFakeId23"
  REMOVED="（session 連結已移除）"
}

teardown() {
  cd / || true
  rm -rf "${WORK}"
}

fake_gh() {
  cat >"${STUB}/gh" <<'STUB'
#!/usr/bin/env python3
import json, os, sys, urllib.parse

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")
FIX = os.environ["FIX"]
STATE = os.path.join(FIX, "state.json")
PAGE_SIZE = 2
args = sys.argv[1:]
with open(os.path.join(FIX, "calls.log"), "a", encoding="utf-8") as log:
    log.write("\t".join(args) + "\n")


def refuse(text, code=64):
    print(text, file=sys.stderr)
    sys.exit(code)


if not args or args[0] != "api":
    refuse("假 gh 不認得這個呼叫：" + " ".join(args))
method, source, endpoint = "GET", None, None
rest = args[1:]
while rest:
    word = rest.pop(0)
    if word in ("-X", "--method"):
        method = rest.pop(0)
    elif word == "--input":
        source = rest.pop(0)
    elif word.startswith("-"):
        refuse("假 gh 不認得這個旗標：" + word)
    elif endpoint is None:
        endpoint = word
    else:
        refuse("假 gh 多了一個參數：" + word)
with open(STATE, encoding="utf-8") as handle:
    state = json.load(handle)
url = urllib.parse.urlsplit(endpoint or "")
query = dict(urllib.parse.parse_qsl(url.query))
parts = url.path.split("/")
if len(parts) < 4 or parts[0] != "repos" or parts[3] not in ("pulls", "issues"):
    refuse("假 gh 不認得這個路徑：" + str(endpoint))
kind = parts[3]


def as_issue(pull):
    return {"number": pull["number"], "state": pull["state"], "body": pull["body"],
            "pull_request": {"url": "https://api.github.invalid/pulls/%d" % pull["number"]}}


if len(parts) == 4 and method == "GET":
    page = int(query.get("page", "1"))
    tag = "%s-page-%d" % (kind, page)
    if os.path.exists(os.path.join(FIX, "fail-" + tag)):
        refuse("HTTP 502: Bad Gateway (https://api.github.invalid/%s)" % endpoint, 1)
    if os.path.exists(os.path.join(FIX, "garbage-" + tag)):
        print("<html>Bad Gateway</html>")
        sys.exit(0)
    items = state["pulls"] if kind == "pulls" else state["issues"] + [as_issue(p) for p in state["pulls"]]
    wanted = query.get("state", "open")
    items = sorted((i for i in items if wanted == "all" or i["state"] == wanted), key=lambda i: i["number"])
    print(json.dumps(items[(page - 1) * PAGE_SIZE:page * PAGE_SIZE], ensure_ascii=False))
    sys.exit(0)
if len(parts) != 5:
    refuse("假 gh 不認得這個路徑：" + str(endpoint))
number = int(parts[4])
pool = state["pulls"] if kind == "pulls" else state["issues"] + [as_issue(p) for p in state["pulls"]]
found = [i for i in pool if i["number"] == number]
if not found:
    refuse("HTTP 404: Not Found (https://api.github.invalid/%s)" % endpoint, 1)
if method == "GET":
    print(json.dumps(found[0], ensure_ascii=False))
    sys.exit(0)
if method != "PATCH" or source is None:
    refuse("假 gh 只接受 GET 與帶 --input 的 PATCH：%s %s" % (method, endpoint))
with open(os.path.join(FIX, "writes.log"), "a", encoding="utf-8") as log:
    log.write("%s\t%s\n" % (method, endpoint))
if os.path.exists(os.path.join(FIX, "fail-patch-%s-%d" % (kind, number))):
    refuse("HTTP 422: Validation Failed (https://api.github.invalid/%s)" % endpoint, 1)
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)
target = [i for i in (state["pulls"] if kind == "pulls" else state["issues"]) if i["number"] == number][0]
target["body"] = payload["body"]
with open(STATE, "w", encoding="utf-8") as handle:
    json.dump(state, handle, ensure_ascii=False)
print(json.dumps(target, ensure_ascii=False))
STUB
  chmod +x "${STUB}/gh"
}

# add_pr <編號> <open|closed> <draft：true|false> <merged：true|false> <說明>
add_pr() {
  python3 - "${FIX}/state.json" "$@" <<'PY'
import json, sys
path, number, state, draft, merged, body = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["pulls"].append({"number": int(number), "state": state, "draft": draft == "true",
                      "merged_at": "2026-11-01T00:00:00Z" if merged == "true" else None, "body": body})
json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False)
PY
}

# add_issue <編號> <open|closed> <說明>
add_issue() {
  python3 - "${FIX}/state.json" "$@" <<'PY'
import json, sys
path, number, state, body = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["issues"].append({"number": int(number), "state": state, "body": body})
json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False)
PY
}

# set_body <pulls|issues> <編號> <說明>：模擬有人在網頁上改了說明。
set_body() {
  python3 - "${FIX}/state.json" "$@" <<'PY'
import json, sys
path, kind, number, body = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
[item for item in data[kind] if item["number"] == int(number)][0]["body"] = body
json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False)
PY
}

# body_of <pulls|issues> <編號>：假 GitHub 上現在的說明，逐位元組寫到標準輸出。
body_of() {
  python3 - "${FIX}/state.json" "$@" <<'PY'
import json, sys
path, kind, number = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
sys.stdout.buffer.write([i for i in data[kind] if i["number"] == int(number)][0]["body"].encode("utf-8"))
PY
}

scrub() {
  run env PATH="${STUB}:${PATH}" "${SCRUB}" --repo spec-owner/spec-repo --backup-dir "${BACKUP}" --interval 0 "$@"
}

writes() {
  grep -c . "${FIX}/writes.log" || true
}

# 最近一次試跑的目錄（備份與比對基準）。
latest_run() {
  find "${BACKUP}" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
}

# 一份分在三頁以上的資料：PR 5 份（含已合併、已關閉、開著的草稿與開著的非草稿），issue 3 份（含已關閉的）。
mixed_state() {
  add_pr 1 closed false true "## 摘要${NL}${NL}${GENERATED}"
  add_pr 2 closed false false "乾淨的描述"
  add_pr 3 closed false false "見 ${SESSION_URL} 的紀錄"
  add_pr 6 open true false "草稿${NL}${NL}${GENERATED}"
  add_pr 8 open false false "開著${NL}${NL}${COAUTHOR}"
  add_issue 4 closed "已關閉的 issue${NL}${NL}${GENERATED}"
  add_issue 5 open "乾淨的 issue"
  add_issue 7 open "開著的 issue 引用 ${SESSION_URL}"
}

# ── 試跑 ───────────────────────────────────────────────────────────────────

@test "試跑：列出所有命中的編號，含第二頁以後的、已合併與已關閉的，以 3 結束" {
  mixed_state

  scrub

  [ "${status}" -eq 3 ]
  [[ "${output}" == *"PR #1"*"PR #3"*"PR #6"*"PR #8"*"issue #4"*"issue #7"* ]]
}

@test "試跑：沒命中的不列出" {
  mixed_state

  scrub

  [[ "${output}" != *"PR #2"* && "${output}" != *"issue #5"* ]]
}

@test "試跑：要改的份數照兩份清單分開列出" {
  mixed_state

  scrub

  [[ "${output}" == *"要改 6 份（PR 4、issue 2）"* ]]
}

@test "試跑：假 gh 收到的寫入請求是 0 個" {
  mixed_state

  scrub

  [ "$(writes)" -eq 0 ]
  [ "$(grep -c PATCH "${FIX}/calls.log" || true)" -eq 0 ]
}

@test "試跑：列舉帶 state=all 並翻到空的那一頁為止" {
  mixed_state

  scrub

  grep -q $'^api\trepos/spec-owner/spec-repo/pulls?.*state=all.*page=4' "${FIX}/calls.log"
  grep -q $'^api\trepos/spec-owner/spec-repo/issues?.*state=all.*page=5' "${FIX}/calls.log"
}

@test "試跑：本機備份的內容和假 gh 給的原文逐位元組相同" {
  original="  前面有空白、後面也有  ${CR}${NL}	tab 開頭${CR}${NL}${CR}${NL}${GENERATED}${CR}${NL}中文 ünïcödé 結尾沒有換行"
  add_pr 9 closed false true "${original}"
  printf '%s' "${original}" >"${WORK}/expected"

  scrub

  cmp "${WORK}/expected" "$(latest_run)/pr-9.txt"
}

@test "試跑：issues API 回傳裡的 PR 被排除，每一份 PR 說明只出現在 pulls 那條路徑" {
  mixed_state

  scrub

  [ "$(grep -c 'PR #8（' <<<"${output}")" -eq 1 ]
  [[ "${output}" != *"issue #8"* && "${output}" != *"issue #1"* ]]
  [ ! -e "$(latest_run)/issue-8.txt" ]
}

@test "試跑：每一份列出會刪哪幾行、換掉幾個網址" {
  add_pr 9 closed false true "第一行${NL}${COAUTHOR}${NL}見 ${SESSION_URL} 與 ${SESSION_URL}${NL}${NL}${GENERATED}"

  scrub

  [[ "${output}" == *"PR #9"*"刪第 2、5 行"*"換掉 2 個網址"* ]]
}

@test "試跑：標出開著、不是草稿的 PR；開著的草稿不標" {
  mixed_state

  scrub

  [[ "${output}" == *"開著、不是草稿的 PR：#8（"* ]]
}

@test "試跑：輸出只有編號、行號與樣式，沒有命中的共同作者行與 session 網址" {
  mixed_state

  scrub

  [[ "${output}" != *"noreply@anthropic.com"* && "${output}" != *"${SESSION_URL}"* ]]
}

# ── 改法（看 --apply 寫回假 GitHub 的內容）──────────────────────────────────────

apply_one() {
  add_pr 9 closed false true "$1"
  scrub
  scrub --apply
  body_of pulls 9 >"${WORK}/actual"
  printf '%s' "$2" >"${WORK}/expected"
}

@test "改法：命中行首樣式的整行被刪（共同作者行、Claude-Session: 行、Generated with 行）" {
  apply_one "A${NL}${COAUTHOR}${NL}B${NL}${SESSION_LINE}${NL}C${NL}${GENERATED}${NL}D${NL}" "A${NL}B${NL}C${NL}D${NL}"

  cmp "${WORK}/expected" "${WORK}/actual"
}

@test "改法：行中的完整 session 網址只換掉網址，同一行其他文字保留" {
  apply_one "前文 ${SESSION_URL}，後文${NL}第二行" "前文 ${REMOVED}，後文${NL}第二行"

  cmp "${WORK}/expected" "${WORK}/actual"
}

@test "改法：因刪行多出的結尾空行被刪，說明中間的空行不動" {
  apply_one "A${NL}${NL}B${NL}${NL}${NL}C${NL}${NL}${GENERATED}" "A${NL}${NL}B${NL}${NL}${NL}C${NL}"

  cmp "${WORK}/expected" "${WORK}/actual"
}

@test "改法：署名行後面原本就有的結尾空行一起刪" {
  apply_one "A${NL}${NL}${GENERATED}${NL}${NL}" "A${NL}"

  cmp "${WORK}/expected" "${WORK}/actual"
}

@test "改法：中間刪了一行、結尾沒有刪時，結尾的空行不動" {
  apply_one "A${NL}${COAUTHOR}${NL}B${NL}${NL}" "A${NL}B${NL}${NL}"

  cmp "${WORK}/expected" "${WORK}/actual"
}

@test "改法：其餘內容逐位元組不變（CRLF、行尾空白、tab、非 ASCII、只在行中引用的字樣）" {
  rest="  縮排 ${CR}${NL}	tab${CR}${NL}說明 Co-Authored-By 那一行、Generated with [Claude Code] 那一行要刪，網址寫成 session_<ID>${CR}${NL}ünïcödé 😀 "
  apply_one "${rest}${CR}${NL}${GENERATED}" "${rest}${CR}${NL}"

  cmp "${WORK}/expected" "${WORK}/actual"
}

@test "改法：只在行中引用署名字樣、網址寫成 session_<ID> 的說明不列出" {
  add_issue 9 closed "說明 Co-Authored-By 那一行要刪；Generated with [Claude Code] 也是；網址寫成 https://claude.ai/code/session_<ID>"

  scrub

  [ "${status}" -eq 0 ]
  [[ "${output}" != *"issue #9"* ]]
}

# ── --apply ─────────────────────────────────────────────────────────────────

@test "--apply：用 gh api -X PATCH 寫回 pulls/<N> 與 issues/<N>，全部寫回時以 0 結束" {
  mixed_state
  scrub

  scrub --apply

  [ "${status}" -eq 0 ]
  [ "$(sort "${FIX}/writes.log")" = "$(printf 'PATCH\trepos/spec-owner/spec-repo/%s\n' issues/4 issues/7 pulls/1 pulls/3 pulls/6 pulls/8 | sort)" ]
}

@test "--apply：寫入前說明已被改過的那一份被略過並列出，其他照寫" {
  mixed_state
  scrub
  set_body pulls 3 "有人在網頁上改過 ${SESSION_URL}"

  scrub --apply

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"略過 1 份"*"PR #3"* ]]
  [ "$(grep -c 'pulls/3$' "${FIX}/writes.log" || true)" -eq 0 ]
  [ "$(writes)" -eq 5 ]
}

@test "--apply：部分失敗時列出已改、略過、失敗三份清單" {
  mixed_state
  scrub
  set_body issues 7 "有人改過"
  touch "${FIX}/fail-patch-pulls-6"

  scrub --apply

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"已改 4 份：PR #1、#3、#8；issue #4"*"略過 1 份：issue #7"*"失敗 1 份：PR #6"* ]]
}

@test "--apply：標出已改的裡面開著、不是草稿的 PR" {
  mixed_state
  scrub

  scrub --apply

  [[ "${output}" == *"已改的裡面開著、不是草稿的 PR：#8"* ]]
}

@test "--apply：沒有試跑過就失敗，寫出下一步" {
  mixed_state

  scrub --apply

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"下一步："* ]]
  [ "$(writes)" -eq 0 ]
}

@test "--apply：最近一次試跑沒有翻完所有分頁時不寫入" {
  mixed_state
  scrub
  touch "${FIX}/fail-issues-page-2"
  scrub

  scrub --apply

  [ "${status}" -eq 1 ]
  [ "$(writes)" -eq 0 ]
}

# ── 重跑與結案 ──────────────────────────────────────────────────────────────

@test "重跑：對略過的那一份重新試跑時，備份與比對基準換成當下的內容" {
  mixed_state
  scrub
  current="有人在網頁上改過${NL}${NL}${GENERATED}"
  set_body pulls 3 "${current}"
  scrub --apply
  printf '%s' "${current}" >"${WORK}/expected"

  scrub

  [[ "${output}" == *"要改 1 份（PR 1、issue 0）"* ]]
  cmp "${WORK}/expected" "$(latest_run)/pr-3.txt"
}

@test "重跑：再 --apply 時寫回的是由當下內容清過的版本" {
  mixed_state
  scrub
  set_body pulls 3 "有人在網頁上改過${NL}${NL}${GENERATED}"
  scrub --apply
  scrub

  scrub --apply

  [ "${status}" -eq 0 ]
  [ "$(body_of pulls 3)" = "有人在網頁上改過" ]
}

@test "重跑：先前的備份不被覆蓋" {
  mixed_state
  scrub
  first="$(latest_run)"
  set_body pulls 3 "有人改過 ${SESSION_URL}"
  scrub
  printf '%s' "見 ${SESSION_URL} 的紀錄" >"${WORK}/expected"

  cmp "${WORK}/expected" "${first}/pr-3.txt"
}

@test "結案：--apply 之後再試跑，兩份清單都翻完、列出 0 個，以 0 結束" {
  mixed_state
  scrub
  scrub --apply

  scrub

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"要改 0 份（PR 0、issue 0）"* ]]
}

# ── 讀取失敗 ────────────────────────────────────────────────────────────────

@test "讀取失敗：PR 清單第 2 頁讀不到時以 1 結束並指名那一份清單與頁數，不報 0" {
  mixed_state
  touch "${FIX}/fail-pulls-page-2"

  scrub

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"PR 清單第 2 頁"* ]]
  [[ "${output}" != *"要改 0 份"* ]]
}

@test "讀取失敗：issue 清單第 1 頁讀不到時以 1 結束並指名那一份清單與頁數" {
  mixed_state
  touch "${FIX}/fail-issues-page-1"

  scrub

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"issue 清單第 1 頁"* ]]
}

@test "讀取失敗：某一頁回的不是 JSON 時以 1 結束並指名那一頁" {
  mixed_state
  touch "${FIX}/garbage-issues-page-2"

  scrub

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"issue 清單第 2 頁"* ]]
}

@test "讀取失敗：試跑沒翻完時沒有命中的清單也不報 0 份" {
  touch "${FIX}/fail-pulls-page-1"

  scrub

  [ "${status}" -eq 1 ]
  [[ "${output}" != *"要改 0 份"* ]]
}

# ── 樣式清單、#269、備份位置、用法 ─────────────────────────────────────────

@test "讀 script/attribution-patterns.txt：換上的樣式命中的整行被刪，原本的樣式不再算" {
  COPY="${WORK}/copy"
  mkdir -p "${COPY}/script"
  cp "${SCRUB}" "${COPY}/script/"
  printf '^Spec-Marker:\n' >"${COPY}/script/attribution-patterns.txt"
  add_pr 9 closed false true "A${NL}Spec-Marker: 1${NL}${GENERATED}"
  SCRUB="${COPY}/script/scrub_attribution.sh"
  scrub
  scrub --apply

  [ "$(body_of pulls 9)" = "A${NL}${GENERATED}" ]
}

@test "#269 的完整內文：試跑列出 0 個，--apply 不寫入" {
  add_issue 269 open "$(cat "${REPO_ROOT}/test/fixtures/attribution/issue-269.md")"
  scrub
  [ "${status}" -eq 0 ]

  scrub --apply

  [ "$(writes)" -eq 0 ]
}

@test "預設的備份目錄在 .gitignore 裡：在 repo 根目錄試跑後 git status 沒有新檔" {
  COPY="${WORK}/copy"
  mkdir -p "${COPY}/script"
  cp "${SCRUB}" "${REPO_ROOT}/script/attribution-patterns.txt" "${COPY}/script/"
  cp "${REPO_ROOT}/.gitignore" "${COPY}/"
  git init -q "${COPY}"
  git -C "${COPY}" add -A
  git -C "${COPY}" -c user.name=spec -c user.email=spec@example.com commit -q -m "chore(spec): 起點"
  mixed_state
  cd "${COPY}" || return 1

  run env PATH="${STUB}:${PATH}" "${COPY}/script/scrub_attribution.sh" --repo spec-owner/spec-repo --interval 0

  [ "${status}" -eq 3 ]
  [ -z "$(git -C "${COPY}" status --porcelain --untracked-files=all)" ]
}

@test "用法：沒有 --repo 時以 2 結束" {
  run env PATH="${STUB}:${PATH}" "${SCRUB}" --backup-dir "${BACKUP}"

  [ "${status}" -eq 2 ]
}
