#!/usr/bin/env bash
#
# Claude Code 的 PreToolUse hook（matcher Bash 與 mcp__ccd_pr__set_auto_merge）：擋下 agent 自己合併 PR、沒綁 issue 的 PR
# 描述與不是草稿的 PR（#408 調整需求第 1～3 點）。合併由 CI 的 merge job 執行（#407），這支只在本機提早擋、給清楚的下一步。
#
# 由 .claude/settings.json 掛上，在主機上跑。**只讀工具呼叫的輸入**（#408 的 Q1）：標準輸入那份 JSON 裡的工具名稱、指令文字與
# cwd，以及指令帶入的檔；本 repo 的身分讀 cwd 那個簽出的 git 設定（remote 的網址）。不跑專案程式，不執行指令本身，也不連網。
#
#   第 1 點  agent 不合併：gh pr merge（任何參數）、gh api 寫入 pulls/<n>/merge、gh api graphql 的有效查詢含
#            mergePullRequest／enablePullRequestAutoMerge／enqueuePullRequest、mcp__ccd_pr__set_auto_merge（不看輸入）。
#            有效查詢照 gh 解析後的結果取：-f／--raw-field query= 的值、-F／--field query= 的值或 query=@<檔> 的內容、
#            --input <檔> 的 JSON 裡 query 欄位的字串。
#   第 2 點  gh pr create 與帶 --body／--body-file 的 gh pr edit：描述裡的關閉參照照 script/closing-references.txt（只有那一份）
#            解析出完整身分（repo＋編號），正好一張、而且是本 repo 的才放行。#N 算本 repo；本 repo 是 -R 寫的 repo，沒寫就是
#            cwd 那個簽出的 remote（gh repo set-default 選的那個，沒有就是 origin）。是不是 GitHub closingIssuesReferences 的
#            同一張由 CI 的綁定判定（script/pr_binding.sh）查。旗標只認和署名 hook 同一份清單（shell-parse.sh 的 GH_*）。
#   第 3 點  gh pr create 的草稿旗標有效值不是 true 就擋（--draft、-d 算；沒寫、--draft=false 都擋）。
#
# **看不到該看的內容就擋下並寫出下一步，不默默放行**（Q8）：值來自 shell 變數或指令替換、從標準輸入讀、要開編輯器或互動、
# 清單以外的旗標、讀不到帶入的檔、讀不懂這條指令、判斷不了本 repo 卻寫了 owner/repo 的參照。
#
# 結束碼：0 放行；2 擋下（Claude Code 把 fd 2 的訊息交給工作階段）。其他結束碼 Claude Code 會放行，所以 python 中途失敗也一律
# 轉成 2，.claude/settings.json 那一行也以 `|| exit 2` 接住這支不在的情況。
#
# 這支刻意只用 bash 3.2 也有的寫法：hook 由使用者的環境啟動，PATH 上的 bash 不一定是 brew 的那一個（macOS 內建的是 3.2）。
# 判定都在 python 裡；讀指令的那一段在 shell-parse.sh，和署名 hook 共用。
set -u

here="${BASH_SOURCE[0]%/*}"
[ "${here}" = "${BASH_SOURCE[0]}" ] && here=.
closing="${here}/../closing-references.txt"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'pr-rules: python3 不在 PATH 上，這次的工具呼叫會不會合併 PR、開出沒綁 issue 的描述判斷不了，先擋下（#408）。\n' >&2
  printf 'pr-rules: 下一步：在這台機器裝 python3，或讓 Claude Code 的 PATH 找得到它，再重送\n' >&2
  exit 2
fi

if [ ! -r "${here}/shell-parse.sh" ]; then
  printf 'pr-rules: 讀不到共用的指令解析 %s，這次的工具呼叫判斷不了，先擋下（#408）。\n' "${here}/shell-parse.sh" >&2
  printf 'pr-rules: 下一步：確認 script/claude-hooks/shell-parse.sh 在這個簽出裡，再重送\n' >&2
  exit 2
fi
# shellcheck source=script/claude-hooks/shell-parse.sh
. "${here}/shell-parse.sh"

IFS= read -r -d '' program <<'PY' || true
TAG = "pr-rules"
CLOSING_PATH = sys.argv[1]
MERGE_TOOL = "mcp__ccd_pr__set_auto_merge"

# 指令文字裡沒有 gh 這個字，就不必解析（也不會因為讀不懂而擋下無關的指令）。
MENTIONS = re.compile(r"(?<![A-Za-z0-9_-])gh(?![A-Za-z0-9_-])")
MERGE_PATH = re.compile(r"(?:^|/)pulls/[^/]+/merge/?$")
MERGE_MUTATIONS = ("mergePullRequest", "enablePullRequestAutoMerge", "enqueuePullRequest")
PR_WRITES = {"create": "create", "new": "create", "edit": "edit"}  # new 是 gh pr create 的別名

STEP_MERGE = "合併由 CI 的 merge job 執行，檢查全過會自己合併；卡住就查 merge job 的紀錄並回報，不要自己合併"
STEP_QUERY = "把查詢寫在 -f query= 或檔案裡"
STEP_BIND = "先開審過的 issue，再在描述寫 Closes #N"
STEP_BODY_FILE = "改用 --body-file <檔> 帶入描述"
STEP_DRAFT = "加 --draft 開草稿；帳本勾完、TDD red 與驗證結果寫進 PR 之後再 gh pr ready <n>"
STEP_LITERAL = "值寫成字面的文字，或先把描述寫進檔、再以 --body-file 帶入"
STEP_SPLIT = "把指令拆開，gh 單獨一條送出，值寫成字面"
STEP_INPUT = ("這支由 Claude Code 的 PreToolUse hook 呼叫；手動執行時，把 hook 會收到的 JSON（tool_name、tool_input.command）"
              "餵進標準輸入")

# shell-parse.sh 的分析程序用的三個說法
COMMANDS = "gh"
UNPARSABLE = "判斷不了它會不會合併 PR、開出或改出 PR 描述"

BLOCKS = []  # (位置, 原因, 下一步)
PATTERN = None


def block(where, why, step):
    item = (where, why, step)
    if item not in BLOCKS:
        BLOCKS.append(item)


def finish():
    if not BLOCKS:
        sys.exit(0)
    err = sys.stderr
    print(f"{TAG}: 擋下這次的工具呼叫（#408）：agent 不合併 PR、每個 PR 描述綁一張本 repo 的 issue、PR 一律先開成草稿，"
          "或是有 hook 判斷不了的地方。", file=err)
    steps = []
    for where, why, step in BLOCKS:
        print(f"{TAG}:   - {where}：{why}", file=err)
        if step not in steps:
            steps.append(step)
    print(f"{TAG}: 下一步：", file=err)
    for step in steps:
        print(f"{TAG}:   - {step}", file=err)
    sys.exit(2)


def stop(where, why, step):
    block(where, why, step)
    finish()


# ── 關閉參照與本 repo ─────────────────────────────────────────────────────

def load_pattern(path):
    """script/closing-references.txt 那一行樣式（#407 交付的唯一一份），不分大小寫。"""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = [line.rstrip("\n") for line in handle if line.strip() and not line.lstrip().startswith("#")]
    except OSError as error:
        stop(f"關閉參照的擷取規格 {path}", f"讀不到（{error.strerror}）", "確認 script/closing-references.txt 在這個簽出裡")
    if len(lines) != 1:
        stop(f"關閉參照的擷取規格 {path}", f"應該正好有一行樣式，讀到 {len(lines)} 行", "把樣式合成一行，說明寫在 # 開頭的行")
    try:
        return re.compile(lines[0], re.IGNORECASE)
    except re.error as error:
        stop(f"關閉參照的擷取規格 {path}", f"不是可用的正規式（{error}）", "修正那一行")


def repo_identity(text):
    """OWNER/REPO、HOST/OWNER/REPO、https://HOST/OWNER/REPO(.git)、git@HOST:OWNER/REPO(.git) → owner/repo（小寫）。"""
    value = text.strip()
    match = re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://(?:[^@/]*@)?[^/]+/(.*)$", value)
    if match:
        path = match.group(1)
    else:
        match = re.match(r"^(?:[^@/:]+@)?[^/:]+:(.*)$", value)
        path = match.group(1) if match else value
    path = path.split("?", 1)[0].rstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    parts = [part for part in path.split("/") if part]
    if len(parts) < 2:
        return None
    return f"{parts[-2]}/{parts[-1]}".lower()


SECTION = re.compile(r'^\s*\[\s*([A-Za-z0-9.-]+)(?:\s+"((?:[^"\\]|\\.)*)")?\s*\]')
ENTRY = re.compile(r"^\s*([A-Za-z][A-Za-z0-9-]*)\s*(?:=\s*(.*?))?\s*$")


def git_config(cwd):
    """cwd 所在簽出的 git 設定檔（worktree 讀共用的那一份）；找不到就是 None。"""
    directory = cwd
    gitdir = None
    while directory:
        dot = os.path.join(directory, ".git")
        if os.path.isdir(dot):
            gitdir = dot
            break
        if os.path.isfile(dot):
            try:
                with open(dot, encoding="utf-8") as handle:
                    content = handle.read().strip()
            except OSError:
                return None
            if not content.startswith("gitdir:"):
                return None
            gitdir = os.path.normpath(os.path.join(directory, content[len("gitdir:"):].strip()))
            break
        parent = os.path.dirname(directory)
        if parent == directory:
            return None
        directory = parent
    if gitdir is None:
        return None
    common = gitdir  # 一般的簽出沒有 commondir，設定檔就在 gitdir 底下
    commondir = os.path.join(gitdir, "commondir")
    if os.path.isfile(commondir):
        try:
            with open(commondir, encoding="utf-8") as handle:
                common = os.path.normpath(os.path.join(gitdir, handle.read().strip()))
        except OSError:
            return None
    return os.path.join(common, "config")


def remote_identity(cwd):
    """(owner/repo, None) 或 (None, 判斷不了的原因)。gh repo set-default 選的 remote 優先，再來是 origin、唯一的 remote。"""
    if cwd is None:
        return None, "判斷不了這條指令執行時的目錄"
    path = git_config(cwd)
    if path is None:
        return None, f"{cwd} 不在 git 簽出裡"
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        return None, f"讀不到 git 設定 {path}（{error.strerror}）"
    remotes = {}
    section = None
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped[0] in "#;":
            continue
        header = SECTION.match(line)
        if header:
            section = (header.group(1).lower(), header.group(2))
            continue
        entry = ENTRY.match(line)
        if entry and section and section[0] == "remote" and section[1] is not None:
            value = (entry.group(2) or "").strip().strip('"')
            remotes.setdefault(section[1], {})[entry.group(1).lower()] = value
    chosen = [name for name, keys in remotes.items() if keys.get("gh-resolved") == "base"]
    if not chosen and "origin" in remotes:
        chosen = ["origin"]
    if not chosen and len(remotes) == 1:
        chosen = list(remotes)
    if len(chosen) != 1 or not remotes[chosen[0]].get("url"):
        return None, "git 設定裡找不到 gh 會用的 remote（gh repo set-default 選的那個或 origin）"
    identity = repo_identity(remotes[chosen[0]]["url"])
    if identity is None:
        return None, f"remote {chosen[0]} 的網址讀不出 owner/repo"
    return identity, None


class Identity:
    """本 repo：-R 寫的 repo，沒寫就是 remote 的。只有描述裡出現 owner/repo 的參照時才讀。"""

    def __init__(self, repo_flag, cwd):
        self.repo_flag = repo_flag
        self.cwd = cwd
        self.value = None
        self.why = None
        self.read = False

    def get(self):
        if not self.read:
            self.read = True
            if self.repo_flag is not None:
                if not self.repo_flag.static:
                    self.why = f"-R 的值來自 shell 的{self.repo_flag.dynamic}"
                else:
                    self.value = repo_identity(self.repo_flag.text)
                    if self.value is None:
                        self.why = f"-R {self.repo_flag.text} 讀不出 owner/repo"
            else:
                self.value, self.why = remote_identity(self.cwd)
        return self.value, self.why


def check_binding(where, text, identity):
    """描述裡的關閉參照照共用規則解析出完整身分再計數：正好一張、而且是本 repo 的才放行。"""
    found = []    # ("" 是本 repo，或別的 owner/repo, 編號)
    shown_as = {}
    refs = list(PATTERN.finditer(text))
    if not refs:
        block(where, "描述沒有關閉關鍵字，沒有綁任何 issue（每個 PR 都要綁一張，#407）", STEP_BIND)
        return
    for match in refs:
        raw = match.group(0)
        if match.group("url"):
            block(where, f"「{raw}」接的是網址，不是本 repo 的 issue 編號", "改寫成 Closes #<issue 編號>")
            continue
        number = int(match.group("number"))
        repo = match.group("repo")
        if repo is None:
            key = ("", number)
        else:
            this, why = identity.get()
            if this is None:
                block(where, f"「{raw}」寫了 {repo}，可是{why}，判斷不了它是不是本 repo", "改寫成 Closes #<issue 編號>")
                continue
            key = ("" if repo.lower() == this else repo.lower(), number)
        if key not in found:
            found.append(key)
            shown_as[key] = raw
    if len(found) > 1:
        listed = "、".join(f"「{shown_as[key]}」" for key in found)
        block(where, f"描述綁了不只一張 issue（{listed}；#N 和 owner/repo#N 指不同 repo 時是兩張）",
              "一個 PR 只綁一張本 repo 的 issue，其餘的另開 PR")
    elif len(found) == 1 and found[0][0]:
        block(where, f"描述綁的「{shown_as[found[0]]}」不是本 repo 的 issue", "只綁本 repo 的 issue：寫 Closes #<issue 編號>")


# ── 依指令分派（shell-parse.sh 的 analyze 呼叫） ─────────────────────────

def dispatch(program, args, state, assignments, words):
    if program == "gh":
        analyze_gh(args, state)
    else:
        indirect(words)


def indirect(words):
    """gh 被交給別的程式執行（xargs、find -exec…）：參數在執行時才決定。"""
    texts = [w.text if w.static else None for w in words]
    for i, text in enumerate(texts):
        if text is None or os.path.basename(text) != "gh":
            continue
        group, verb, _ = gh_parts(words[i + 1:])
        runner = os.path.basename(texts[0]) if texts[0] else "這條指令"
        if group == "pr" and verb == "merge":
            block(f"{runner} 執行的 gh pr merge", "agent 不合併 PR：合併由 CI 的 merge job 執行（#407 定案 16）", STEP_MERGE)
            return
        if group is None or group == "api" or (group == "pr" and (verb is None or verb in PR_WRITES)):
            block(f"{runner} 執行的 gh",
                  "gh 交給別的程式執行（例如 xargs、find -exec），參數在執行時才決定，hook 判斷不了它會不會合併 PR 或開出、改出 PR 描述",
                  "直接執行 gh，參數寫成字面")
            return


def analyze_gh(args, state):
    group, verb, rest = gh_parts(args)
    if group is None:
        if any(a.static and a.text in ("merge", "api", "create", "new", "edit") for a in args):
            block("gh", "群組或子指令來自 shell 展開，hook 判斷不了它會不會合併 PR 或開出、改出 PR 描述", "子指令寫成字面")
        return
    if group == "api":
        analyze_api(rest, state)
        return
    if group != "pr":
        return
    if verb is None:
        block("gh pr", "子指令來自 shell 展開，hook 判斷不了它會不會合併 PR 或開出、改出 PR 描述", "子指令寫成字面")
        return
    if verb == "merge":
        block("gh pr merge", "agent 不合併 PR：合併由 CI 的 merge job 執行（#407 定案 16），任何參數都擋", STEP_MERGE)
        return
    if verb in PR_WRITES:
        analyze_pr_write(PR_WRITES[verb], verb, rest, state)


# ── gh pr create／edit ───────────────────────────────────────────────────

TRUE_VALUES = {"1", "t", "T", "TRUE", "true", "True"}     # 同 Go 的 strconv.ParseBool（gh 的旗標照它解析）
FALSE_VALUES = {"0", "f", "F", "FALSE", "false", "False"}


def draft_value(parsed, label):
    """草稿旗標的有效值：最後一個 -d／--draft 為準；沒寫是 False。"""
    value = False
    for name, word in parsed.options:
        if name not in ("-d", "--draft"):
            continue
        if word is None:
            value = True
        elif not word.static:
            block(f"{label} 的 {name}=", f"值來自 shell 的{word.dynamic}，判斷不了是不是草稿", STEP_DRAFT)
            value = None
        elif word.text in TRUE_VALUES:
            value = True
        elif word.text in FALSE_VALUES:
            value = False
        else:
            value = False  # gh 會拒收這個值；當成不是草稿
    return value


def analyze_pr_write(kind, verb, args, state):
    label = f"gh pr {verb}"
    text_flags = GH_TEXT["pr"]
    parsed = parse_options(args, set(text_flags) | GH_VALUES["pr"], GH_BOOLS["pr"])
    names = parsed.names()
    if "-h" in names or "--help" in names:
        return
    for name in parsed.unknown:
        why, step = GH_UNKNOWN.get(name, GH_UNKNOWN_DEFAULT)
        block(f"{label} 的 {name}", why, step)
    if parsed.opaque:
        block(f"{label} 的參數", "有參數整個來自 shell 展開，分不出是不是旗標", STEP_LITERAL)
    for name in parsed.missing:
        block(f"{label} 的 {name}", "少了值", "補上值")
    bodies = [(n, v) for n, v in parsed.options if text_flags.get(n) in ("body", "file")]
    if kind == "create":
        if draft_value(parsed, label) is False:
            block(label, "沒有開成草稿：不是草稿的 PR 一開就會觸發 merge job，之後轉回草稿可能趕不上（#408 第 3 點）", STEP_DRAFT)
        if not bodies:
            block(label, "沒有 --body 或 --body-file：gh 會跳出提示或由 commit 產生描述，hook 看不到描述", STEP_BODY_FILE)
    elif not parsed.options and not parsed.unknown and not parsed.opaque:
        block(label, "沒有任何旗標，gh 會進入互動模式，hook 看不到要改成的描述", STEP_BODY_FILE)
    repos = [v for n, v in parsed.options if n in ("-R", "--repo") and v is not None]
    identity = Identity(repos[-1] if repos else None, state.cwd)
    for name, value in bodies:
        if value is None:
            continue
        if text_flags[name] == "body":
            where = f"{label} 的 {name}"
            if not value.static:
                block(where, f"值來自 shell 的{value.dynamic}，hook 看不到描述", STEP_LITERAL)
                continue
            text = value.text
        else:
            where = f"{label} 的 {name} {shown(value)}".rstrip()
            text = read_file(where, value, state.cwd, state)
        if text is not None:
            check_binding(where, text, identity)


# ── gh api ────────────────────────────────────────────────────────────────

def endpoint_path(text):
    """完整網址拿掉主機、去掉查詢字串與開頭的 /。"""
    match = re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://[^/]+(/.*)?$", text)
    path = (match.group(1) or "") if match else text
    return path.split("?", 1)[0].lstrip("/")


def analyze_api(args, state):
    parsed = parse_options(args, API_VALUES, API_BOOLS)
    names = parsed.names()
    if "-h" in names or "--help" in names:
        return
    methods = [v for n, v in parsed.options if n in ("-X", "--method")]
    fields = [(n, v) for n, v in parsed.options if n in ("-f", "--raw-field", "-F", "--field")]
    inputs = [v for n, v in parsed.options if n == "--input"]
    if methods:
        method = methods[-1]
        writes = method is None or not method.static or method.text.upper() not in ("GET", "HEAD")
    else:
        # 沒寫 -X 時，帶了欄位或 --input 都預設用 POST（gh api --help）
        writes = bool(fields or inputs)
    endpoint = parsed.positionals[0] if parsed.positionals else None
    if endpoint is None or not endpoint.static:
        if writes or parsed.opaque:
            kind = endpoint.dynamic if endpoint is not None else "展開"
            block("gh api 的端點", f"端點或參數來自 shell 的{kind}，hook 判斷不了它是不是合併 PR", "端點與 -X 寫成字面")
        return
    path = endpoint_path(endpoint.text)
    if path == "graphql" or path.endswith("/graphql"):
        analyze_graphql(parsed, fields, inputs, state)
    elif MERGE_PATH.search(path):
        if writes:
            block(f"gh api 寫入 {endpoint.text}", "這個端點會合併 PR；agent 不合併（#407 定案 16）", STEP_MERGE)
        elif parsed.opaque or parsed.unknown:
            block(f"gh api {endpoint.text}", "有參數來自 shell 展開或不在認得的旗標清單裡，判斷不了是讀取還是合併", "-X 與欄位寫成字面")


def analyze_graphql(parsed, fields, inputs, state):
    queries = []  # (位置, 查詢)
    seen = False
    if parsed.opaque:
        block("gh api graphql 的參數", "有參數整個來自 shell 展開，分不出是不是查詢", STEP_QUERY)
    for name in parsed.unknown:
        block(f"gh api graphql 的 {name}", "不在 hook 認得的旗標清單裡，取不到有效的查詢", STEP_QUERY)
    for name in parsed.missing:
        block(f"gh api graphql 的 {name}", "少了值", "補上值")
    for name, value in fields:
        flag = "-f" if name in ("-f", "--raw-field") else "-F"
        if value is None:
            continue
        if "=" not in value.prefix:
            if not value.static:
                block(f"gh api graphql 的 {flag}", f"欄位名稱來自 shell 的{value.dynamic}，分不出是不是 query", STEP_QUERY)
            continue
        if value.prefix.split("=", 1)[0] != "query":
            continue
        seen = True
        where = f"gh api graphql 的 {flag} query"
        if not value.static:
            block(where, f"值來自 shell 的{value.dynamic}，hook 看不到查詢", STEP_QUERY)
            continue
        content = value.text.split("=", 1)[1]
        if flag == "-F" and content.startswith("@"):
            where = f"gh api graphql 的 -F query=@{content[1:]}"
            text = read_file(where, literal(content[1:]), state.cwd, state, STEP_QUERY)
            if text is not None:
                queries.append((where, text))
        else:
            queries.append((where, content))
    for value in inputs:
        seen = True
        where = f"gh api graphql 的 --input {shown(value)}".rstrip()
        text = read_file(where, value, state.cwd, state, STEP_QUERY)
        if text is None:
            continue
        try:
            document = json.loads(text)
        except json.JSONDecodeError as error:
            block(where, f"不是合法的 JSON（第 {error.lineno} 行第 {error.colno} 欄），取不到查詢", STEP_QUERY)
            continue
        query = document.get("query") if isinstance(document, dict) else None
        if not isinstance(query, str):
            block(where, "JSON 裡沒有字串的 query 欄位，取不到查詢", STEP_QUERY)
            continue
        queries.append((f"{where}（query 欄位）", query))
    if not seen:
        block("gh api graphql", "沒有 -f query=、-F query= 或 --input，取不到有效的查詢", STEP_QUERY)
    for where, query in queries:
        for mutation in MERGE_MUTATIONS:
            if mutation.lower() in query.lower():
                block(where, f"查詢含 {mutation}：會合併 PR、開啟自動合併或排進合併佇列；agent 不合併（#407 定案 16）", STEP_MERGE)


# ── 進入點 ────────────────────────────────────────────────────────────────

def main():
    global PATTERN
    data = load_input(STEP_INPUT)
    if data.get("tool_name") == MERGE_TOOL:
        stop(f"工具 {MERGE_TOOL}", "它會開啟或關掉 PR 的自動合併；agent 不碰合併，不看輸入一律擋（#408 第 1 點）", STEP_MERGE)
    command, cwd = input_command(data, STEP_INPUT)
    if not MENTIONS.search(command):
        sys.exit(0)
    PATTERN = load_pattern(CLOSING_PATH)
    run_script(command, State(cwd))
    finish()


try:
    main()
except SystemExit:
    raise
except Unparsable as error:
    stop("這條指令", f"讀不懂它的結構（{error}），{UNPARSABLE}", STEP_SPLIT)
except Exception as error:  # 任何沒預料到的錯誤都擋下，不讓 Claude Code 當成放行
    print(f"{TAG}: 判斷時發生沒預料到的錯誤（{type(error).__name__}），這次的工具呼叫先擋下（#408）。", file=sys.stderr)
    print(f"{TAG}: 下一步：{STEP_SPLIT}；這個錯誤請回報到 #408", file=sys.stderr)
    sys.exit(2)
PY

python3 -c "$(shell_parse_program)
${program}" "${closing}"
code=$?
if [ "${code}" -eq 0 ] || [ "${code}" -eq 2 ]; then
  exit "${code}"
fi
printf 'pr-rules: 判斷中途失敗（python3 結束碼 %s），這次的工具呼叫先擋下（#408）。\n' "${code}" >&2
printf 'pr-rules: 下一步：照上面 python3 印的原因修正；修不了就把指令拆開，gh 單獨一條送出、值寫成字面\n' >&2
exit 2
