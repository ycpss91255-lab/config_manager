#!/usr/bin/env bash
#
# workflow 的 run-name 分得出每一次執行對應的 commit（#350）。
#
# 沒有 run-name 時，pull_request 觸發的每一次執行都顯示 PR 標題，同一個 PR 推好幾次，Actions 頁面上
# 的名稱完全相同，分不出是哪一個 commit。判定標準是維護者 11/14 定案的，照每一種觸發要求 run-name
# 的 `${{ … }}` 裡引用能辨識 commit 的欄位：
#
#   pull_request（與 pull_request_target）   github.event.pull_request.head.sha
#                                             （github.sha 是 GitHub 為 PR 合出來的那一個 commit，不算）
#   推 tag（push.tags）                       github.ref_name 與 github.sha
#   其餘（push、workflow_dispatch、merge_group…） github.sha
#
# PR 編號與標題是附加資訊，不能取代 SHA。沒有 run-name、純靜態字串，都擋。GitHub 的運算式沒有截短
# 字串的函式，所以引用了那個欄位，印出來的就是完整的 SHA。
#
# **獨立的一支**（維護者 11/12、11/14）：CI 的 run-name job 與本機的 pre-push hook
# （script/githook-checks/pre-push/10-run-name.sh）呼叫同一支，不併進 `script/test.sh --lint`。
#
# 不靠 YAML 套件（runner 的 python3 不保證有，與 ci_rollup.sh 同一個理由）：workflow 是這個 repo 自己
# 寫的區塊式 YAML，這裡只讀頂層的 run-name 與 on。純文字值照 YAML 的規則去掉註解——空格後面的 `#`
# 開始註解，所以沒加引號的 `run-name: PR #${{ … }}` 其實只剩「PR」。
#
# **擋不住的**：運算式在每一種觸發下真的印出那個欄位。這裡看的是有沒有引用；藏在永遠不成立的條件裡
# 也會通過。實際的名稱由 GitHub 上的執行紀錄核對。
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_ROOT

usage() {
  cat <<'USAGE'
用法：script/lint_run_name.sh [<workflow 檔>…]
      script/lint_run_name.sh --pre-push

  不給檔案      檢查 .github/workflows/ 底下的 *.yaml 與 *.yml（CI 的 run-name job）
  --pre-push    讀 git pre-push 的標準輸入，檢查要推上去的每一個 commit 裡的 workflow 檔
                （本機的 pre-push hook）；刪除分支的那一行略過

  exit 0   全部通過
  exit 1   有 workflow 的 run-name 分不出對應的 commit
  exit 2   讀不到檔案、git 讀不出 commit，或用法不對
USAGE
}

main() {
  local mode="files"
  local -a files=()
  case "${1:-}" in
    -h | --help)
      usage
      return 0
      ;;
    --pre-push)
      mode="pre-push"
      shift
      ;;
    -*)
      usage >&2
      return 2
      ;;
  esac
  # pre-push 的標準輸入先存下來：下面的 python 程式本身是經標準輸入（heredoc）餵進去的，
  # 它的 sys.stdin 讀不到 git 給的那幾行。
  local input=""
  if [[ "${mode}" == pre-push ]]; then
    input="$(mktemp)"
    cat >"${input}"
    files=("${input}")
  elif [[ "${mode}" == files ]]; then
    if (($# > 0)); then
      files=("$@")
    else
      local candidate
      for candidate in "${REPO_ROOT}"/.github/workflows/*.yaml "${REPO_ROOT}"/.github/workflows/*.yml; do
        [[ -f "${candidate}" ]] && files+=("${candidate}")
      done
    fi
  fi

  local code=0
  python3 - "${mode}" "${files[@]}" <<'PY' || code=$?
import re
import subprocess
import sys

mode, paths = sys.argv[1], sys.argv[2:]
PR_EVENTS = {"pull_request", "pull_request_target"}
HEAD_SHA = "github.event.pull_request.head.sha"
SHA = "github.sha"
TAG = "github.ref_name"


def fail_io(message, next_step):
    print(f"lint_run_name: {message}", file=sys.stderr)
    print(f"lint_run_name: 下一步：{next_step}", file=sys.stderr)
    sys.exit(2)


def strip_comment(text):
    """YAML 純文字值的註解：空格（或行首）後面的 # 開始註解。"""
    match = re.search(r"(^|\s)#", text)
    return text[: match.start()] if match else text


def top_level(lines, key):
    """頂層 key 的值：(有沒有這個 key, 同一行的值, 底下縮排的那幾行)。"""
    pattern = re.compile(r"""^(["']?)([A-Za-z_-]+)\1\s*:(.*)$""")
    for index, raw in enumerate(lines):
        if not raw or raw[0].isspace() or raw.startswith("#"):
            continue
        match = pattern.match(raw)
        if not match or match[2] != key:
            continue
        block = []
        for following in lines[index + 1 :]:
            if following and not following[0].isspace() and not following.startswith("#"):
                break
            block.append(following)
        return True, match[3], block
    return False, "", []


def run_name_text(inline, block):
    """run-name 實際的字串內容（只為了找 ${{ … }}，不求逐字還原 YAML 的折行）。"""
    value = inline.strip()
    if value[:1] in ("|", ">"):  # 區塊值：內容全在底下，# 是字面
        return "\n".join(block)
    if value[:1] in ('"', "'"):
        quote = value[0]
        rest = value[1:]
        end = rest.find(quote)
        return rest if end < 0 else rest[:end]
    text = strip_comment(value)
    continued = [strip_comment(line).strip() for line in block if line.strip() and not line.strip().startswith("#")]
    return " ".join([text, *continued]).strip()


def triggers(inline, block):
    """[(觸發, 是不是推 tag)]。"""
    value = strip_comment(inline).strip()
    if value.startswith("["):
        names = [name.strip().strip("'\"") for name in value.strip("[]").split(",") if name.strip()]
        return [(name, False) for name in names]
    if value:
        return [(value.strip("'\""), False)]
    found = []
    indent = None
    current = None
    push_keys = set()
    for line in block:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        width = len(line) - len(line.lstrip(" "))
        if indent is None:
            indent = width
        stripped = line.strip()
        if width == indent:
            item = re.match(r"-\s*(\S+)", stripped)
            key = re.match(r"""(["']?)([A-Za-z_-]+)\1\s*:""", stripped)
            current = (item[1] if item else key[2] if key else None)
            if current:
                found.append(current)
        elif current == "push":
            key = re.match(r"([A-Za-z_-]+)\s*:", stripped)
            if key and width > indent:
                push_keys.add(key[1])
    result = []
    for name in found:
        if name == "push" and "tags" in push_keys:
            if push_keys & {"branches", "branches-ignore"}:
                result.append(("push", False))
            result.append(("push", True))
        else:
            result.append((name.strip("'\""), False))
    return result


def check(display, content):
    lines = content.splitlines()
    problems = []
    has_run_name, inline, block = top_level(lines, "run-name")
    if not has_run_name:
        return [f"{display}：沒有 run-name，每一次執行的名稱分不出對應的 commit"]
    text = run_name_text(inline, block)
    expressions = " ".join(re.findall(r"\$\{\{(.*?)\}\}", text, re.S))
    if not expressions.strip():
        return [f"{display}：run-name 是純靜態字串（{text!r}），每一次執行的名稱都一樣"]
    has_on, on_inline, on_block = top_level(lines, "on")
    if not has_on:
        return [f"{display}：讀不到頂層的 on:，不知道要照哪一種觸發檢查 run-name"]

    def has(field):
        return re.search(re.escape(field) + r"(?![A-Za-z0-9_.])", expressions) is not None

    for name, is_tag in triggers(on_inline, on_block):
        if name in PR_EVENTS:
            wanted = [HEAD_SHA]
        elif is_tag:
            wanted = [TAG, SHA]
        else:
            wanted = [SHA]
        for field in wanted:
            if not has(field):
                kind = f"{name}（推 tag）" if is_tag else name
                problems.append(f"{display}：{kind} 觸發的 run-name 沒有引用 {field}")
    return problems


def read_file(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as error:
        fail_io(f"讀不到 workflow 檔 {path}：{error}", "確認路徑，或不帶參數讓它讀 .github/workflows/")


def git(*args):
    completed = subprocess.run(["git", *args], capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        fail_io(f"git {' '.join(args)} 失敗：{completed.stderr.strip()}", "在要推的那份 repo 裡執行，確認那個 commit 在本機")
    return completed.stdout


targets = []
if mode == "pre-push":
    shas = []
    with open(paths[0], encoding="utf-8") as handle:
        pushed = handle.read()
    for line in pushed.splitlines():
        fields = line.split()
        if len(fields) < 4 or set(fields[1]) == {"0"} or fields[1] in shas:
            continue
        shas.append(fields[1])
    if not shas:
        print("lint_run_name: 沒有要推上去的 commit，沒有 workflow 要檢查")
        sys.exit(0)
    for sha in shas:
        for path in git("ls-tree", "--name-only", sha, "--", ".github/workflows/").splitlines():
            if path.endswith((".yaml", ".yml")):
                targets.append((f"{path}（{sha[:12]}）", git("show", f"{sha}:{path}")))
else:
    if not paths:
        fail_io(".github/workflows/ 底下沒有任何 workflow 檔，沒有東西可以檢查——這不是通過", "在 repo 根目錄執行，或指名要檢查的檔")
    targets = [(path, read_file(path)) for path in paths]

problems = [problem for display, content in targets for problem in check(display, content)]
if problems:
    for problem in problems:
        print(f"lint_run_name: {problem}", file=sys.stderr)
    print(
        "lint_run_name: 下一步：照 #350 的標準改 run-name——pull_request 帶 github.event.pull_request.head.sha，"
        "推 tag 帶 github.ref_name 與 github.sha，其餘觸發帶 github.sha；值裡有 # 要加引號或用 >- 區塊",
        file=sys.stderr,
    )
    sys.exit(1)
print(f"lint_run_name: {len(targets)} 個 workflow 檔的 run-name 都分得出對應的 commit")
PY
  [[ -z "${input}" ]] || rm -f "${input}"
  return "${code}"
}

main "$@"
