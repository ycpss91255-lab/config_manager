#!/usr/bin/env bash
#
# Claude Code 的 PreToolUse hook（matcher Bash）：寫進 commit、PR、issue 之前，擋下 Claude 署名與
# session 連結（#405，#269 第 2 步）。
#
# 由 .claude/settings.json 掛上，在主機上跑。**只讀工具呼叫的輸入**（維護者 Q1）：標準輸入那份 JSON
# 裡的指令文字與 cwd，以及指令帶入的檔；不跑專案程式，也不執行指令本身。
#
# 檢查的指令：git commit、gh pr|issue create|edit|comment、gh release create|edit、會寫入的 gh api。
# **先取出要寫出去的文字，再逐行比對** script/attribution-patterns.txt，不拿整條指令去比：整條指令裡，
# 訊息的第一行排在 -m、--body 或引號後面，行首的樣式會看不到。取的是：
#
#   git commit   -m／--message 的值、-F／--file 帶入的檔、--trailer 的值（照「<鍵>: <值>」當成一行）
#   gh pr|issue  -t／--title、-b／--body 的值，-F／--body-file 帶入的檔
#   gh release   -t／--title、-n／--notes 的值，-F／--notes-file 帶入的檔
#   gh api       -f 與 -F 的值、-F key=@<檔> 的檔、--input <檔> 解析後每個字串欄位（跳脫的換行已還原）
#
# **看不到該看的文字就擋下並寫出下一步，不默默放行**（Q8）：值來自 shell 變數或指令替換、從標準輸入讀、
# 要開編輯器或互動、清單以外的旗標、讀不到帶入的檔、讀不懂這條指令。命中時寫出位置、行號與樣式，
# **不重抄命中的內容**，免得完整的 session 網址又進到工作階段紀錄。
#
# 結束碼：0 放行；2 擋下（Claude Code 把 fd 2 的訊息交給工作階段）。其他結束碼 Claude Code 會放行，
# 所以 python 中途失敗也一律轉成 2，.claude/settings.json 那一行也以 `|| exit 2` 接住這支不在的情況。
#
#
# 讀 shell 指令的那一段（字、引號、指令替換、&&／;、bash -c、eval、cd）與 gh 的旗標清單在 script/claude-hooks/shell-parse.sh，
# 和 PR 規則 hook（pr-rules.sh，#408）共用同一份。
# 這支刻意只用 bash 3.2 也有的寫法：hook 由使用者的環境啟動，PATH 上的 bash 不一定是 brew 的那一個
# （macOS 內建的是 3.2）。判定都在 python 裡；python 程式以 -c 傳入，標準輸入留給 hook 的 JSON。
set -u

here="${BASH_SOURCE[0]%/*}"
[ "${here}" = "${BASH_SOURCE[0]}" ] && here=.
patterns="${here}/../attribution-patterns.txt"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'no-attribution: python3 不在 PATH 上，這條指令要寫出的文字核對不了，先擋下（#405）。\n' >&2
  printf 'no-attribution: 下一步：在這台機器裝 python3，或讓 Claude Code 的 PATH 找得到它，再重送這條指令\n' >&2
  exit 2
fi

if [ ! -r "${here}/shell-parse.sh" ]; then
  printf 'no-attribution: 讀不到共用的指令解析 %s，這條指令核對不了，先擋下（#405）。\n' "${here}/shell-parse.sh" >&2
  printf 'no-attribution: 下一步：確認 script/claude-hooks/shell-parse.sh 在這個簽出裡，再重送這條指令\n' >&2
  exit 2
fi
# shellcheck source=script/claude-hooks/shell-parse.sh
. "${here}/shell-parse.sh"

IFS= read -r -d '' program <<'PY' || true
TAG = "no-attribution"
PATTERNS_PATH = sys.argv[1]
PATTERNS = []

# 指令文字裡沒有 git 或 gh 這兩個字，就不必解析（也不會因為讀不懂而擋下無關的指令）。
MENTIONS = re.compile(r"(?<![A-Za-z0-9_-])(?:git|gh)(?![A-Za-z0-9_-])")
LINES = re.compile(r"\r\n|\n|\r")

STEP_LITERAL = "值寫成字面的文字（-m \"…\"、--body \"…\"），或先把文字寫進檔、再以 -F／--body-file 帶入"
STEP_SPLIT = "把指令拆成單純的 git commit -F <檔>／gh … --body-file <檔> 再送"
# shell-parse.sh 的分析程序用的三個說法
COMMANDS = "git commit／gh"
UNPARSABLE = "找不出要寫出去的文字"

HITS = []    # (位置, 行號, 樣式)
BLOCKS = []  # (位置, 原因, 下一步)


def block(where, why, step):
    item = (where, why, step)
    if item not in BLOCKS:
        BLOCKS.append(item)


def finish():
    if not HITS and not BLOCKS:
        sys.exit(0)
    err = sys.stderr
    print(f"{TAG}: 擋下這條指令（#405）：要寫進 commit、PR 或 issue 的文字有 Claude 署名或 session 連結，"
          "或是有 hook 核對不了的地方。", file=err)
    steps = []
    if HITS:
        print(f"{TAG}: 命中 script/attribution-patterns.txt 的樣式（不重抄命中的內容）：", file=err)
        for where, lineno, pattern in HITS:
            print(f"{TAG}:   - {where}，第 {lineno} 行：{pattern}", file=err)
        steps.append("刪掉命中的那一行再送；要舉例 session 網址時寫成 session_<ID> 這類不完整的寫法")
    if BLOCKS:
        print(f"{TAG}: 核對不了（看不到就擋）：", file=err)
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


# ── 樣式與比對 ────────────────────────────────────────────────────────────

def load_patterns(path):
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        stop(f"樣式清單 {path}", f"讀不到（{error.strerror}）", "確認 script/attribution-patterns.txt 在這個簽出裡")
    patterns = []
    for number, line in enumerate(lines, 1):
        if not line.strip() or line.startswith("#"):
            continue
        try:
            patterns.append((line, re.compile(line, re.IGNORECASE)))
        except re.error as error:
            stop(f"樣式清單 {path} 第 {number} 行", f"不是可用的正規式（{error}）", "修正那一行")
    if not patterns:
        stop(f"樣式清單 {path}", "裡面沒有任何樣式", "照檔頭的說明補回樣式")
    return patterns


def check_text(where, text):
    for lineno, line in enumerate(LINES.split(text), 1):
        for source, pattern in PATTERNS:
            if pattern.search(line):
                hit = (where, lineno, source)
                if hit not in HITS:
                    HITS.append(hit)


# ── 依指令分派（shell-parse.sh 的 analyze 呼叫） ─────────────────────────

def dispatch(program, args, state, assignments, words):
    if program == "git":
        analyze_git(args, state, assignments)
    elif program == "gh":
        analyze_gh(args, state)
    else:
        indirect(words)


def git_subcommand(texts):
    i = 0
    while i < len(texts):
        text = texts[i]
        if text is None:
            return None
        if text in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"):
            i += 2
        elif text.startswith("-"):
            i += 1
        else:
            return text
    return None


GH_VERBS = {"pr": {"create", "edit", "comment"}, "issue": {"create", "edit", "comment"}, "release": {"create", "edit"}}


def gh_writes(texts):
    if not texts or texts[0] is None:
        return False
    if texts[0] == "api":
        return True
    verbs = GH_VERBS.get(texts[0])
    return bool(verbs) and any(t in verbs for t in texts[1:] if t is not None)


def indirect(words):
    """git commit 或 gh 的寫入被交給別的程式執行（xargs、find -exec…）：參數在執行時才決定。"""
    texts = [w.text if w.static else None for w in words]
    for i, text in enumerate(texts):
        if text is None:
            continue
        name = os.path.basename(text)
        if (name == "git" and git_subcommand(texts[i + 1:]) == "commit") or (name == "gh" and gh_writes(texts[i + 1:])):
            runner = os.path.basename(texts[0]) if texts[0] else "這條指令"
            block(f"{runner} 執行的 {name}",
                  "git commit 或 gh 的寫入交給別的程式執行（例如 xargs、find -exec），參數在執行時才決定，hook 核對不了",
                  "直接執行 git commit／gh，要寫出的文字明帶或寫進檔再以 -F、--body-file 帶入")
            return


def check_word(where, word):
    if word is None:
        return
    if not word.static:
        block(where, f"值來自 shell 的{word.dynamic}，hook 看不到實際的文字", STEP_LITERAL)
        return
    check_text(where, word.text)


def check_file(where, word, cwd, state):
    text = read_file(where, word, cwd, state)
    if text is not None:
        check_text(where, text)


# ── git commit ────────────────────────────────────────────────────────────

COMMIT_VALUES = {"-m", "--message", "-F", "--file", "--trailer"}
COMMIT_BOOLS = {"-a", "--all", "--amend", "--no-edit", "--allow-empty", "-q", "--quiet", "-s", "--signoff",
                "-n", "--no-verify"}
COMMIT_UNKNOWN = {
    "-C": "會帶入既有 commit 的訊息", "--reuse-message": "會帶入既有 commit 的訊息",
    "-c": "會帶入既有 commit 的訊息並開編輯器", "--reedit-message": "會帶入既有 commit 的訊息並開編輯器",
    "--fixup": "會由 git 產生或帶入訊息", "--squash": "會由 git 產生或帶入訊息",
    "-t": "會帶入範本檔的訊息", "--template": "會帶入範本檔的訊息",
    "-e": "會開編輯器", "--edit": "會開編輯器",
}
STEP_COMMIT_FLAGS = "只用 -m、-F、--trailer 明帶訊息（另外認得 -a、--amend、--no-edit、--allow-empty、-q、-s）"


def analyze_git(args, state, assignments):
    cwd = state.cwd
    config = []
    i = 0
    subcommand = None
    while i < len(args):
        word = args[i]
        if not word.static:
            if any(a.static and a.text == "commit" for a in args[i:]):
                block("git", "git 的選項或子指令來自 shell 展開，hook 核對不了", STEP_LITERAL)
            return
        text = word.text
        if text == "-C":
            if i + 1 < len(args):
                target = args[i + 1]
                cwd = resolve(cwd, target.text) if target.static else None
            i += 2
        elif text in ("-c", "--config-env"):
            config.append(text)
            i += 2
        elif text.startswith("--config-env="):
            config.append("--config-env")
            i += 1
        elif text in ("--git-dir", "--work-tree", "--namespace", "--super-prefix"):
            i += 2
        elif text.startswith("-"):
            i += 1
        else:
            subcommand = text
            break
    if subcommand != "commit":
        return
    analyze_commit(args[i + 1:], state, cwd, config, assignments)


def trailer_line(text):
    match = re.match(r"([^=:]*)[=:](.*)", text, re.S)
    if not match:
        return f"{text.strip()}: "
    return f"{match.group(1).strip()}: {match.group(2).strip()}"


def analyze_commit(args, state, cwd, config, assignments):
    parsed = parse_options(args, COMMIT_VALUES, COMMIT_BOOLS)
    names = parsed.names()
    for flag in config:
        block(f"git {flag}", "可能改掉 commit 訊息（trailer、template）或跳過 commit-msg 檢查（core.hooksPath），hook 核對不了",
              "拿掉 git 後面的 -c／--config-env；要的設定寫進 repo 的 git config")
    for name in assignments:
        if name.startswith("GIT_CONFIG"):
            block(f"git commit 前面的 {name}=", "這個環境變數會改 git 的設定（同 git -c），hook 核對不了",
                  "拿掉那個環境變數設定再 commit")
    if "-n" in names or "--no-verify" in names:
        block("git commit 的 --no-verify", "它會跳過本機的 commit-msg 檢查（第二道）",
              "拿掉 --no-verify；commit-msg 檢查擋下時照它的訊息修正")
    for name in parsed.unknown:
        block(f"git commit 的 {name}", COMMIT_UNKNOWN.get(name, "不在 hook 認得的旗標清單裡，可能帶入既有的訊息、開編輯器或改寫訊息"),
              STEP_COMMIT_FLAGS)
    if parsed.opaque:
        block("git commit 的參數", "有參數整個來自 shell 展開，分不出是不是旗標", STEP_LITERAL)
    for name in parsed.missing:
        block(f"git commit 的 {name}", "少了值", "補上值")
    messages = [v for n, v in parsed.options if n in ("-m", "--message")]
    files = [v for n, v in parsed.options if n in ("-F", "--file")]
    trailers = [v for n, v in parsed.options if n == "--trailer"]
    if not messages and not files:
        if "--amend" in names and "--no-edit" in names:
            block("git commit --amend --no-edit",
                  "沿用 HEAD 的訊息：hook 只看工具的輸入，確認不了那段訊息，也確認不了 commit-msg 檢查有沒有打開",
                  "明帶訊息：git commit --amend -m … 或 git commit --amend -F <檔>")
        else:
            block("git commit", "沒有 -m 或 -F：git 會開編輯器或沿用既有的訊息，hook 看不到要寫進去的文字",
                  "明帶訊息：git commit -m … 或 git commit -F <檔>")
    for number, value in enumerate(messages, 1):
        check_word(f"git commit 的第 {number} 個 -m", value)
    for value in files:
        check_file(f"git commit 的 -F {shown(value)}".rstrip(), value, cwd, state)
    for number, value in enumerate(trailers, 1):
        where = f"git commit 的第 {number} 個 --trailer"
        if value is None:
            continue
        if not value.static:
            check_word(where, value)
        else:
            check_text(where, trailer_line(value.text))


# ── gh pr／issue／release ────────────────────────────────────────────────

def analyze_gh(args, state):
    group, verb, rest = gh_parts(args)
    if group is None:
        if any(a.static and a.text in ("api", "create", "edit", "comment") for a in args):
            block("gh", "子指令來自 shell 展開，hook 核對不了", STEP_LITERAL)
        return
    if group == "api":
        analyze_api(rest, state)
        return
    if group not in GH_VERBS or verb not in GH_VERBS[group]:
        return
    analyze_gh_write(group, verb, rest, state)


def analyze_gh_write(group, verb, args, state):
    label = f"gh {group} {verb}"
    text_flags = GH_TEXT[group]
    parsed = parse_options(args, set(text_flags) | GH_VALUES[group], GH_BOOLS[group])
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
    kinds = {text_flags[n] for n in names if n in text_flags}
    if verb == "create" and group in ("pr", "issue") and not ("title" in kinds and kinds & {"body", "file"}):
        block(label, "少了標題或內文，gh 會跳出提示讓人輸入，hook 看不到那段文字", STEP_GH_TEXT)
    if verb == "create" and group == "release" and not kinds & {"body", "file"}:
        block(label, "少了說明，gh 會跳出提示或開編輯器，hook 看不到那段文字", "說明明帶：--notes … 或 --notes-file <檔>")
    if verb == "comment" and not kinds & {"body", "file"}:
        block(label, "少了內文，gh 會開編輯器或跳出提示，hook 看不到那段文字", "內文明帶：--body … 或 --body-file <檔>")
    if verb == "edit" and not parsed.options and not parsed.unknown and not parsed.opaque:
        block(label, "沒有任何旗標，gh 會進入互動模式，hook 看不到要改成的文字", STEP_GH_TEXT)
    for name, value in parsed.options:
        kind = text_flags.get(name)
        if kind in ("title", "body"):
            check_word(f"{label} 的 {name}", value)
        elif kind == "file":
            check_file(f"{label} 的 {name} {shown(value)}".rstrip(), value, state.cwd, state)


# ── gh api ────────────────────────────────────────────────────────────────

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
    if not writes:
        return
    for name in parsed.unknown:
        block(f"gh api 的 {name}", "不在 hook 認得的旗標清單裡，實際送出的內容核對不了",
              "拿掉它；要寫的文字用 -f、-F key=@<檔> 或 --input <檔> 帶入")
    if parsed.opaque:
        block("gh api 的參數", "有參數整個來自 shell 展開，分不出是不是旗標", STEP_LITERAL)
    for name in parsed.missing:
        block(f"gh api 的 {name}", "少了值", "補上值")
    for name, value in fields:
        flag = "-f" if name in ("-f", "--raw-field") else "-F"
        if value is None:
            continue
        if not value.static:
            key = value.prefix.split("=", 1)[0] if "=" in value.prefix else ""
            block(f"gh api 的 {flag} {key}".rstrip(), f"值來自 shell 的{value.dynamic}，hook 看不到實際的文字", STEP_LITERAL)
            continue
        key, equals, content = value.text.partition("=")
        if flag == "-F" and content.startswith("@"):
            check_file(f"gh api 的 -F {key}=@{content[1:]}", literal(content[1:]), state.cwd, state)
        else:
            check_text(f"gh api 的 {flag} {key}", content if equals else value.text)
    for value in inputs:
        where = f"gh api 的 --input {shown(value)}".rstrip()
        text = read_file(where, value, state.cwd, state)
        if text is None:
            continue
        try:
            document = json.loads(text)
        except json.JSONDecodeError as error:
            block(where, f"不是合法的 JSON（第 {error.lineno} 行第 {error.colno} 欄），解不出要送出的字串", "修正那個 JSON 檔再送")
            continue
        for path, content in json_strings(document, ""):
            check_text(f"{where}（{path or '最上層'} 欄位）", content)


# ── 進入點 ────────────────────────────────────────────────────────────────

STEP_INPUT = "這支由 Claude Code 的 PreToolUse hook 呼叫；手動執行時，把 hook 會收到的 JSON（tool_input.command）餵進標準輸入"


def main():
    global PATTERNS
    command, cwd = input_command(load_input(STEP_INPUT), STEP_INPUT)
    if not MENTIONS.search(command):
        sys.exit(0)
    PATTERNS = load_patterns(PATTERNS_PATH)
    run_script(command, State(cwd))
    finish()


try:
    main()
except SystemExit:
    raise
except Unparsable as error:
    stop("這條指令", f"讀不懂它的結構（{error}），找不出要寫出去的文字", STEP_SPLIT)
except Exception as error:  # 任何沒預料到的錯誤都擋下，不讓 Claude Code 當成放行
    print(f"{TAG}: 核對時發生沒預料到的錯誤（{type(error).__name__}），這條指令先擋下（#405）。", file=sys.stderr)
    print(f"{TAG}: 下一步：{STEP_SPLIT}；這個錯誤請回報到 #405", file=sys.stderr)
    sys.exit(2)
PY

python3 -c "$(shell_parse_program)
${program}" "${patterns}"
code=$?
if [ "${code}" -eq 0 ] || [ "${code}" -eq 2 ]; then
  exit "${code}"
fi
printf 'no-attribution: 核對中途失敗（python3 結束碼 %s），這條指令先擋下（#405）。\n' "${code}" >&2
printf 'no-attribution: 下一步：照上面 python3 印的原因修正；修不了就把指令拆成單純的 git commit -F <檔>／gh … --body-file <檔>\n' >&2
exit 2
