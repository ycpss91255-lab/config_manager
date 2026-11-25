#!/usr/bin/env bash
#
# Claude Code 的 PreToolUse hook（matcher Bash，以及 Write|Edit|NotebookEdit）：開 issue 與改 issue 的標題或本文，只走審稿過的
# 那一份（#413 調整需求第 7 點）。審稿紀錄與送出由 script/issue_draft.sh 處理；這支擋掉繞過它的一般寫法，給清楚的下一步。
#
# 由 .claude/settings.json 掛上，在主機上跑。**只讀工具呼叫的輸入**（Q1）：指令文字、Write／Edit／NotebookEdit 的路徑、指令明白
# 帶入的 API 檔案（-F <欄位>=@<檔>、--input <檔>）。不讀草稿、紀錄與環境變數，不跑專案程式，也不連網。
#
#   開 issue      gh issue create／gh issue new（不論參數）；gh api 的 REST 開 issue（…/issues、有效方法是 POST）；
#                 gh api graphql 的有效查詢含 createIssue
#   改標題或內文  gh issue edit 帶 -t／--title、-b／--body、-F／--body-file、--attach，或沒有任何旗標；gh api 的 REST 改 issue
#                 （…/issues/<編號>、會寫入、欄位或 --input 的 JSON 有 title 或 body）；gh api graphql 的有效查詢含 updateIssue
#   身分變數      指令文字裡的 CLAUDE_CODE_SESSION_ID、CLAUDE_CODE_HOST_SESSION_ID 不是單純讀取（$名稱、${名稱}、printenv 名稱）
#   快照與紀錄    寫入、搬移、刪除 .issue-drafts/<名稱>/snapshots/ 底下的東西（Write、Edit、NotebookEdit，以及 Bash 的重新導向與
#                 寫入、搬移、刪除類的程式）。只有用 rm -r 或 git clean 刪掉整個快照資料夾或更上層不擋：紀錄會跟著一起刪掉
#
# script/issue_draft.sh、script/issue_tick.sh 的指令文字裡沒有上面要擋的東西，所以照常執行；hook 不核對它們是不是本簽出的那一支。
#
# **看不到、判斷不了的時候擋下並寫出下一步，不默默放行**（Q8）。擋不住的寫在 #413 的「擋不住」與 doc/TEST-PLAN.md T19。
#
# 結束碼：0 放行；2 擋下（Claude Code 把 fd 2 的訊息交給工作階段）。其他結束碼 Claude Code 會放行，所以 python 中途失敗也一律
# 轉成 2，.claude/settings.json 那一行也以 `|| exit 2` 接住這支不在的情況。
#
# 這支刻意只用 bash 3.2 也有的寫法：hook 由使用者的環境啟動，PATH 上的 bash 不一定是 brew 的那一個（macOS 內建的是 3.2）。
# 判定都在 python 裡；讀指令的那一段在 shell-parse.sh，和其他 hook 共用。
set -u

here="${BASH_SOURCE[0]%/*}"
[ "${here}" = "${BASH_SOURCE[0]}" ] && here=.

if ! command -v python3 >/dev/null 2>&1; then
  printf 'issue-rules: python3 不在 PATH 上，這次的工具呼叫會不會繞過審稿開 issue、改本文或寫審稿紀錄判斷不了，先擋下（#413）。\n' >&2
  printf 'issue-rules: 下一步：在這台機器裝 python3，或讓 Claude Code 的 PATH 找得到它，再重送\n' >&2
  exit 2
fi

if [ ! -r "${here}/shell-parse.sh" ]; then
  printf 'issue-rules: 讀不到共用的指令解析 %s，這次的工具呼叫判斷不了，先擋下（#413）。\n' "${here}/shell-parse.sh" >&2
  printf 'issue-rules: 下一步：確認 script/claude-hooks/shell-parse.sh 在這個簽出裡，再重送\n' >&2
  exit 2
fi
# shellcheck source=script/claude-hooks/shell-parse.sh
. "${here}/shell-parse.sh"

IFS= read -r -d '' program <<'PY' || true
TAG = "issue-rules"
WRITE_TOOLS = {"Write": "file_path", "Edit": "file_path", "NotebookEdit": "notebook_path"}

# 指令文字裡沒有這些字（目錄也不在 .issue-drafts 底下），就不必解析。
MENTIONS = re.compile(r"(?<![A-Za-z0-9_-])gh(?![A-Za-z0-9_-])|\.issue-drafts")
IDENTITY = re.compile(r"(?<![A-Za-z0-9_])CLAUDE_CODE_(?:HOST_)?SESSION_ID(?![A-Za-z0-9_])")
GLOB = re.compile(r"[*?\[]")
CREATE_PATH = re.compile(r"^repos/[^/]+/[^/]+/issues/?$")
EDIT_PATH = re.compile(r"^repos/[^/]+/[^/]+/issues/[^/]+/?$")
MUTATIONS = ("createIssue", "updateIssue")

STEP_CREATE = ("先寫 .issue-drafts/<名稱>/（title.txt、body.md），執行 script/issue_draft.sh submit <名稱> --new 送審；"
               "判定通過後執行 script/issue_draft.sh create <名稱>")
STEP_EDIT = ("改本文走 script/issue_draft.sh submit <名稱> --edit <編號>，審過後 script/issue_draft.sh edit <名稱>；"
             "只勾帳本用 script/issue_tick.sh <編號> <條件片段> <commit 主旨>")
STEP_API = STEP_CREATE + "；改標題或本文：" + STEP_EDIT
STEP_QUERY = "把查詢寫在 -f query= 或檔案裡；開 issue 或改本文照 script/issue_draft.sh 的流程"
STEP_IDENTITY = ("不要在指令裡設定、清掉或改寫工作階段 id（CLAUDE_CODE_SESSION_ID、CLAUDE_CODE_HOST_SESSION_ID）；要看值就用 "
                 "printenv <名稱> 或 \"$<名稱>\"，審稿紀錄由審稿工作階段自己執行 script/issue_draft.sh verdict 產生")
STEP_SNAPSHOT = ("快照與紀錄只由 script/issue_draft.sh 寫；要重審就改草稿再 submit，要放棄就 rm -r 整個 "
                 ".issue-drafts/<名稱>/snapshots/<雜湊> 或更上層")
STEP_LITERAL = "路徑寫成字面，不經變數或萬用字元"
STEP_SPLIT = "把指令拆開，gh 與寫檔的指令各自單獨一條送出，值寫成字面"
STEP_INPUT = ("這支由 Claude Code 的 PreToolUse hook 呼叫；手動執行時，把 hook 會收到的 JSON（tool_name、tool_input、cwd）"
              "餵進標準輸入")

# shell-parse.sh 的分析程序用的三個說法
COMMANDS = "gh 與寫檔的指令"
UNPARSABLE = "判斷不了它會不會繞過審稿開 issue、改本文或寫審稿紀錄"

BLOCKS = []  # (位置, 原因, 下一步)


def block(where, why, step):
    item = (where, why, step)
    if item not in BLOCKS:
        BLOCKS.append(item)


def finish():
    if not BLOCKS:
        sys.exit(0)
    err = sys.stderr
    print(f"{TAG}: 擋下這次的工具呼叫（#413）：開 issue 與改 issue 的標題或本文只走審稿過的那一份，審稿紀錄只由 "
          "script/issue_draft.sh 寫，或是有 hook 判斷不了的地方。", file=err)
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


# ── 身分變數 ──────────────────────────────────────────────────────────────

def check_identity(command):
    """變數名稱只准出現在 $名稱、${名稱}、printenv 名稱 這三種單純讀取裡。"""
    for match in IDENTITY.finditer(command):
        start, end = match.start(), match.end()
        before, after = command[:start], command[end:]
        if before.endswith("${") and after.startswith("}"):
            continue
        if before.endswith("$"):
            continue
        if re.search(r"(?:^|[\s;&|(])printenv[ \t]+$", before):
            continue
        block(f"指令文字裡的 {match.group(0)}", "不是單純讀取（$名稱、${名稱}、printenv 名稱），可能在設定、清掉或改寫工作階段 id",
              STEP_IDENTITY)


# ── 快照與紀錄 ────────────────────────────────────────────────────────────

def drafts_parts(path):
    """絕對路徑裡 .issue-drafts 之後的各段；不在 .issue-drafts 底下是 None。"""
    parts = [part for part in path.split("/") if part]
    if ".issue-drafts" not in parts:
        return None
    return parts[len(parts) - 1 - parts[::-1].index(".issue-drafts") + 1:]


def classify(path):
    """outside：不在快照裡（含草稿本身與 .lock）；level：整個快照資料夾或更上層；inside：快照裡面的東西。"""
    rest = drafts_parts(path)
    if rest is None:
        return "outside"
    if len(rest) <= 1:
        return "level"
    if rest[1] != "snapshots":
        return "outside"
    if len(rest) <= 3:
        return "level"
    return "inside"


def target_of(word, state):
    """(絕對路徑, None) 或 (None, 判斷不了的原因)；字面的部分沒有 .issue-drafts、也不在它底下時是 (None, None)。"""
    literal = word.text
    if not word.static:
        if ".issue-drafts" in literal or (state.cwd and "/.issue-drafts" in state.cwd):
            return None, f"路徑有一部分來自 shell 的{word.dynamic}，判斷不了會不會落在快照裡"
        return None, None
    path = resolve(state.cwd, literal)
    if path is None:
        if ".issue-drafts" in literal:
            return None, "這條指令先切換到 hook 判斷不了的目錄，相對路徑對不到位置"
        return None, None
    rest = drafts_parts(path)
    if rest is not None and any(GLOB.search(part) for part in rest):
        return None, "路徑含萬用字元，判斷不了會不會落在快照裡"
    return path, None


def snapshot_scope(where, word, state, allow_level):
    """寫入、搬移（allow_level=False）或刪除（allow_level=True）的目標在快照裡就擋。"""
    path, why = target_of(word, state)
    if why:
        block(where, why, STEP_LITERAL)
        return
    if path is None:
        return
    kind = classify(path)
    if kind == "inside" or (kind == "level" and not allow_level and (drafts_parts(path) or [""])[1:2] == ["snapshots"]):
        block(where, f"{path} 在 .issue-drafts 的快照裡，審稿紀錄與快照只由 script/issue_draft.sh 寫", STEP_SNAPSHOT)


def level_scope(where, word, state):
    """寫入、搬移類程式的目標：快照資料夾本身或更上層也擋（例如把一整份快照複製到別的草稿）。"""
    path, why = target_of(word, state)
    if why:
        block(where, why, STEP_LITERAL)
        return
    if path is not None and classify(path) in ("inside", "level"):
        block(where, f"{path} 是 .issue-drafts 的草稿資料夾或快照，寫入或搬移它會改到審稿紀錄", STEP_SNAPSHOT)


WRITE_REDIRECTIONS = (">", ">>", ">|", "&>", "&>>", "<>")
WRITERS = {"tee", "cp", "mv", "ln", "install", "rsync", "touch", "truncate"}
DELETERS = {"rm", "unlink", "rmdir"}


def operands(args):
    """參數裡的路徑：不是旗標的字，與 --x=<值> 的值。"""
    for word in args:
        head = word.text if word.static else word.prefix
        if head.startswith("-"):
            if "=" in head:
                yield sub_word(word, head.index("=") + 1)
            continue
        yield word


def in_place(program, args):
    for word in args:
        if not word.static:
            continue
        text = word.text
        if program == "sed" and (text.startswith("-i") or text.startswith("--in-place")):
            return True
        if program == "sed" and text.startswith("-") and not text.startswith("--") and "i" in text[1:]:
            return True
        if program == "perl" and text.startswith("-") and not text.startswith("--") and "i" in text[1:]:
            return True
    return False


def check_writes(command, state):
    for op, target, _ in command.redirections:
        if op in WRITE_REDIRECTIONS and target is not None:
            snapshot_scope(f"重新導向 {op} {shown(target)}".rstrip(), target, state, False)
    _, words = command_words(command)
    if not words or not words[0].static:
        return
    program = os.path.basename(words[0].text)
    args = words[1:]
    where = f"{program} 的參數"
    if program in WRITERS or (program in ("sed", "perl") and in_place(program, args)):
        for word in operands(args):
            level_scope(where, word, state)
    elif program == "dd":
        for word in args:
            if (word.text if word.static else word.prefix).startswith("of="):
                level_scope("dd 的 of=", sub_word(word, 3), state)
    elif program in DELETERS:
        recursive = any(w.static and (w.text in ("-r", "-R", "--recursive") or
                                      (w.text.startswith("-") and not w.text.startswith("--") and
                                       ("r" in w.text[1:] or "R" in w.text[1:]))) for w in args)
        for word in operands(args):
            snapshot_scope(where, word, state, recursive or program == "rmdir")
    elif program == "find":
        acting = any(w.static and w.text in ("-delete", "-exec", "-execdir", "-ok", "-okdir") for w in args)
        if acting:
            for word in args:
                if word.static and word.text.startswith("-"):
                    break
                level_scope("find 的起點", word, state)
    elif program == "git":
        options, sub, rest = git_parts(args)
        if sub == "clean":
            cwd = state.cwd
            for name, value in options:
                if name == "-C":
                    cwd = resolve(cwd, value.text) if value is not None and value.static else None
            inner = State(cwd, state.written)
            for word in operands(rest):
                snapshot_scope("git clean 的路徑", word, inner, True)


# ── gh ────────────────────────────────────────────────────────────────────

ISSUE_EDIT_VALUES = {"-R", "--repo", "-t", "--title", "-b", "--body", "-F", "--body-file", "-m", "--milestone",
                     "--add-assignee", "--remove-assignee", "--add-label", "--remove-label", "--add-project",
                     "--remove-project", "--add-blocked-by", "--remove-blocked-by", "--add-blocking", "--remove-blocking",
                     "--add-sub-issue", "--remove-sub-issue", "--parent", "--type", "--attach"}
ISSUE_EDIT_BOOLS = {"--remove-milestone", "--remove-parent", "--remove-type", "-h", "--help"}
ISSUE_EDIT_TEXT = {"-t", "--title", "-b", "--body", "-F", "--body-file", "--attach"}


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
        if group is None or group == "api" or (group == "issue" and verb in (None, "create", "new", "edit")):
            runner = os.path.basename(texts[0]) if texts[0] else "這條指令"
            block(f"{runner} 執行的 gh",
                  "gh 交給別的程式執行（例如 xargs、find -exec），參數在執行時才決定，hook 判斷不了它會不會開 issue 或改本文",
                  "直接執行 gh，參數寫成字面")
        return


def analyze_gh(args, state):
    group, verb, rest = gh_parts(args)
    if group is None:
        if any(a.static and a.text in ("issue", "api", "create", "new", "edit") for a in args):
            block("gh", "群組或子指令來自 shell 展開，hook 判斷不了它會不會開 issue 或改本文", "子指令寫成字面")
        return
    if group == "api":
        analyze_api(rest, state)
        return
    if group != "issue":
        return
    if verb is None:
        block("gh issue", "子指令來自 shell 展開，hook 判斷不了它會不會開 issue 或改本文", "子指令寫成字面")
    elif verb in ("create", "new"):
        block(f"gh issue {verb}", "直接開 issue 會繞過審稿：開出的標題與內文要和審稿判「可以開」的那一份相同（#413），任何參數都擋",
              STEP_CREATE)
    elif verb == "edit":
        analyze_issue_edit(rest)


def analyze_issue_edit(args):
    parsed = parse_options(args, ISSUE_EDIT_VALUES, ISSUE_EDIT_BOOLS)
    names = parsed.names()
    if "-h" in names or "--help" in names:
        return
    for name in names:
        if name in ISSUE_EDIT_TEXT:
            block(f"gh issue edit 的 {name}", "直接改標題或本文會繞過審稿：改上去的要和審稿判「可以發」的那一份相同（#413）",
                  STEP_EDIT)
    for name in parsed.unknown:
        block(f"gh issue edit 的 {name}", "不在 hook 認得的旗標清單裡，判斷不了會不會改標題或本文", STEP_EDIT)
    if parsed.opaque:
        block("gh issue edit 的參數", "有參數整個來自 shell 展開，分不出是不是改標題或本文的旗標", STEP_EDIT)
    for name in parsed.missing:
        block(f"gh issue edit 的 {name}", "少了值", "補上值")
    if not [n for n in names if n not in ("-R", "--repo")] and not parsed.unknown and not parsed.opaque:
        block("gh issue edit", "沒有任何旗標：有終端機時 gh 會進互動模式改標題與內文，hook 看不到要改成什麼", STEP_EDIT)


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
        known = method is not None and method.static
        upper = method.text.upper() if known else None
        writes = not known or upper not in ("GET", "HEAD")
        posts = not known or upper == "POST"
    else:
        # 沒寫 -X 時，帶了欄位或 --input 都預設用 POST（gh api --help）
        writes = posts = bool(fields or inputs)
    endpoint = parsed.positionals[0] if parsed.positionals else None
    if endpoint is None or not endpoint.static:
        if writes or parsed.opaque:
            kind = endpoint.dynamic if endpoint is not None else "展開"
            block("gh api 的端點", f"端點或參數來自 shell 的{kind}，hook 判斷不了它是不是開 issue 或改本文", "端點與 -X 寫成字面")
        return
    path = endpoint_path(endpoint.text)
    if path == "graphql" or path.endswith("/graphql"):
        analyze_graphql(parsed, fields, inputs, state)
    elif CREATE_PATH.match(path):
        if posts:
            block(f"gh api 寫入 {endpoint.text}", "這個端點會開 issue，繞過審稿（#413）", STEP_API)
        elif parsed.opaque or parsed.unknown:
            block(f"gh api {endpoint.text}", "有參數來自 shell 展開或不在認得的旗標清單裡，判斷不了是讀取還是開 issue",
                  "-X 與欄位寫成字面")
    elif EDIT_PATH.match(path):
        if writes:
            edit_fields(endpoint.text, fields, inputs, state)
        if parsed.opaque or parsed.unknown:
            block(f"gh api {endpoint.text}", "有參數來自 shell 展開或不在認得的旗標清單裡，判斷不了會不會改標題或本文",
                  "-X 與欄位寫成字面")


def edit_fields(endpoint, fields, inputs, state):
    where = f"gh api 寫入 {endpoint}"
    for name, value in fields:
        if value is None:
            continue
        if "=" not in value.prefix:
            if not value.static:
                block(where, f"{name} 的欄位名稱來自 shell 的{value.dynamic}，分不出是不是 title 或 body", STEP_LITERAL)
            continue
        key = value.prefix.split("=", 1)[0]
        if key in ("title", "body"):
            block(where, f"欄位 {key} 會改 issue 的標題或本文，繞過審稿（#413）", STEP_EDIT)
    for value in inputs:
        source = f"{where} 的 --input {shown(value)}".rstrip()
        text = read_file(source, value, state.cwd, state, STEP_EDIT)
        if text is None:
            continue
        try:
            document = json.loads(text)
        except json.JSONDecodeError as error:
            block(source, f"不是合法的 JSON（第 {error.lineno} 行第 {error.colno} 欄），判斷不了會不會改標題或本文", STEP_EDIT)
            continue
        if not isinstance(document, dict):
            block(source, "JSON 的最上層不是物件，判斷不了會不會改標題或本文", STEP_EDIT)
            continue
        for key in ("title", "body"):
            if key in document:
                block(source, f"JSON 有 {key}：會改 issue 的標題或本文，繞過審稿（#413）", STEP_EDIT)


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
        for mutation in MUTATIONS:
            if mutation.lower() in query.lower():
                block(where, f"查詢含 {mutation}：會開 issue 或改標題、本文，繞過審稿（#413）", STEP_API)


# ── 依序分析每一條簡單指令：先看寫檔，再交給 shell-parse.sh 的分析 ────────

_shared_analyze = analyze


def analyze(command, state):  # noqa: F811 —— 換掉 shell-parse.sh 的 analyze，巢狀的指令也會經過這裡
    check_writes(command, state)
    _shared_analyze(command, state)


# ── 進入點 ────────────────────────────────────────────────────────────────

def check_write_tool(name, data):
    tool_input = data.get("tool_input")
    key = WRITE_TOOLS[name]
    path = tool_input.get(key) if isinstance(tool_input, dict) else None
    if not isinstance(path, str) or not path:
        stop(f"工具 {name}", f"JSON 裡沒有 tool_input.{key}，看不到要寫的檔", STEP_INPUT)
    cwd = data.get("cwd")
    resolved = resolve(cwd if isinstance(cwd, str) and os.path.isabs(cwd) else None, path)
    if resolved is None:
        if ".issue-drafts" in path:
            stop(f"工具 {name} 的 {path}", "相對路徑對不到位置，判斷不了是不是快照裡的檔", "改用絕對路徑")
        sys.exit(0)
    if classify(resolved) == "inside":
        stop(f"工具 {name} 的 {resolved}", "在 .issue-drafts 的快照裡，審稿紀錄與快照只由 script/issue_draft.sh 寫", STEP_SNAPSHOT)
    sys.exit(0)


def main():
    data = load_input(STEP_INPUT)
    name = data.get("tool_name")
    if name in WRITE_TOOLS:
        check_write_tool(name, data)
    command, cwd = input_command(data, STEP_INPUT)
    check_identity(command)
    if MENTIONS.search(command) or (cwd and "/.issue-drafts" in cwd):
        run_script(command, State(cwd))
    finish()


try:
    main()
except SystemExit:
    raise
except Unparsable as error:
    stop("這條指令", f"讀不懂它的結構（{error}），{UNPARSABLE}", STEP_SPLIT)
except Exception as error:  # 任何沒預料到的錯誤都擋下，不讓 Claude Code 當成放行
    print(f"{TAG}: 判斷時發生沒預料到的錯誤（{type(error).__name__}），這次的工具呼叫先擋下（#413）。", file=sys.stderr)
    print(f"{TAG}: 下一步：{STEP_SPLIT}；這個錯誤請回報到 #413", file=sys.stderr)
    sys.exit(2)
PY

python3 -c "$(shell_parse_program)
${program}"
code=$?
if [ "${code}" -eq 0 ] || [ "${code}" -eq 2 ]; then
  exit "${code}"
fi
printf 'issue-rules: 判斷中途失敗（python3 結束碼 %s），這次的工具呼叫先擋下（#413）。\n' "${code}" >&2
printf 'issue-rules: 下一步：照上面 python3 印的原因修正；修不了就把指令拆開，gh 與寫檔的指令各自單獨一條送出、值寫成字面\n' >&2
exit 2
