#!/usr/bin/env bash
#
# Claude Code 的 PreToolUse hook（matcher Bash，以及 Read|Edit|Write|Grep|Glob）：工作階段與環境的規則（#412）。規則本文在
# AGENTS.md「工作階段的規則」；原本只靠文字，這支在本機擋下或先問，給清楚的下一步。
#
# 由 .claude/settings.json 掛上，在主機上跑。**只讀工具呼叫的輸入**（#412 的 Q1）：不呼叫 git、不跑專案程式與測試、不掃
# 檔案系統。讀的檔只有這支旁邊的入口清單 docker-entrypoints.txt，與第 5 點往上找到的 .git（檔案或資料夾）和它指到的管理目錄。
#
#   第 1 點  docker 先問：指令依 &&、||、;、| 分段（略過開頭的變數設定與 env、command、nohup 這類包裝），任一段是
#            docker-entrypoints.txt 上的入口（docker、just docker、just test、會開 docker 的 repo 腳本，寫成 ./script/x.sh、
#            script/x.sh、bash script/x.sh 都算）就回傳 ask。
#   第 3 點  cm_verify：命中第 1 點的指令，文字裡同時出現 cm_verify（參數、-p 專案名、前面的變數設定都算）就擋（deny），
#            deny 優先於 ask。
#   第 4 點  token 檔：Read／Edit／Write 的 file_path、Grep 的 path 與 glob、Glob 的 path 與 pattern、Bash 指令裡的每個字，
#            檔名含 token 的 .md（不分大小寫）就擋。Grep 工具一律擋（#412 本文 2026-11-25 改：搜尋範圍裡指向 token 檔的
#            symlink 讀不讀得到，hook 只看輸入分不出來、實測也做不到，照 Q8 擋）；Bash 的遞迴搜尋（grep -r／-R、rg、
#            find … -exec grep、xargs grep）也一律擋。git grep 會讀沒追蹤檔或 repo 外檔的寫法也擋（#426）：帶 --no-index、
#            --untracked（含至少到 --n／--u 的縮寫；-e、-f 的值與 -- 之後的字不算），前面有 git -c、--config-env 或
#            GIT_CONFIG… 的變數設定（含 env 後面的），經 xargs、parallel 執行；經 git -C、find -exec 與 sudo 這類包裝程式執行的
#            照同樣的規則。看不出內容的 git 寫法與 -O 也擋（#436）：git grep 的參數（-- 之前）會拆成好幾個字（shell-parse.sh 的
#            Word.splits），或是展開前的字面部分看不出是不是選項的展開字（-e、-f 的值、字面部分不以 - 開頭、--名稱="$值"、-C"$N"
#            這類連寫的值放行）；git 的全域選項或子指令來自展開（不管後面有沒有 grep），或這一段有會拆成好幾個字的字（-C "$DIR"、
#            --git-dir="$D" 這類不會拆的值不算子指令）；經 xargs 執行而子指令沒寫、來自展開或是 -I、-J、-i 的替換字串，或 -J 的
#            字在子指令前面；經 watch、parallel 執行的 git 一律擋；程式名稱來自展開、後面有字面的 grep 時把它當成可能是 git，照
#            git grep 的規則看；git grep 的 -O、--open-files-in-pager 與它至少到 --o 的前綴。包裝程式後面再經包裝程式執行的 git
#            照 git 前面最近的那一個判斷。這幾種的下一步都是「要讀單一檔案就用 Read」與「跨檔搜尋內容用 git grep」：不帶這些寫法
#            的 git grep 只搜 repo 追蹤的檔；#436 的每一種另加一句怎麼改寫。
#   第 5 點  主 checkout 不切分支：git switch、git checkout <分支>／-b 的目錄從 hook 輸入的 cwd 開始，依序疊上 cd 與
#            git -C；從那裡往上找 .git，只有確認是 linked worktree（gitdir 指到的管理目錄有 commondir，共用目錄底下的
#            worktrees/<名稱> 就是它）才放行。git checkout -- <檔> 不擋。
#   第 6 點  指令說明要中文：Bash 的 description 沒有任何中日韓文字就擋（分不出繁簡）。
#
# **看不到、判斷不了的時候擋下並寫出下一步，不默默放寬保護**（Q8）。擋不住的寫在 doc/TEST-PLAN.md T19。
#
# 結束碼：0 放行（要先問時把 ask 寫成 JSON 印到標準輸出）；2 擋下（Claude Code 把 fd 2 的訊息交給工作階段）。其他結束碼
# Claude Code 會放行，所以 python 中途失敗也一律轉成 2，.claude/settings.json 那一行也以 `|| exit 2` 接住這支不在的情況。
#
# 這支刻意只用 bash 3.2 也有的寫法：hook 由使用者的環境啟動，PATH 上的 bash 不一定是 brew 的那一個（macOS 內建的是 3.2）。
# 判定都在 python 裡；讀指令的那一段（含 cd 之後的目錄、git 的全域選項）在 shell-parse.sh，和其他 hook 共用。
set -u

here="${BASH_SOURCE[0]%/*}"
[ "${here}" = "${BASH_SOURCE[0]}" ] && here=.

if ! command -v python3 >/dev/null 2>&1; then
  printf 'env-rules: python3 不在 PATH 上，這次的工具呼叫會不會開 docker、讀 token 檔、在主 checkout 切分支判斷不了，先擋下（#412）。\n' >&2
  printf 'env-rules: 下一步：在這台機器裝 python3，或讓 Claude Code 的 PATH 找得到它，再重送\n' >&2
  exit 2
fi

if [ ! -r "${here}/shell-parse.sh" ]; then
  printf 'env-rules: 讀不到共用的指令解析 %s，這次的工具呼叫判斷不了，先擋下（#412）。\n' "${here}/shell-parse.sh" >&2
  printf 'env-rules: 下一步：確認 script/claude-hooks/shell-parse.sh 在這個簽出裡，再重送\n' >&2
  exit 2
fi
# shellcheck source=script/claude-hooks/shell-parse.sh
. "${here}/shell-parse.sh"

IFS= read -r -d '' program <<'PY' || true
TAG = "env-rules"
ENTRY_FILE = sys.argv[1] if len(sys.argv) > 1 else ""

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# 指令文字裡沒有這些字，就不必解析（也不會因為讀不懂而擋下無關的指令）。
MENTIONS = re.compile(r"(?i)docker|just|git|grep|rg|find|xargs|script|\.sh\b|token|cm_verify|source|sudo|doas|watch|parallel"
                      r"|caffeinate|stdbuf|unbuffer|(?<![A-Za-z0-9_-])(?:sh|bash|zsh|dash|ksh|eval)(?![A-Za-z0-9_-])")
CM_VERIFY = re.compile(r"(?i)cm_verify")
CJK = re.compile("[\u3040-\u30ff\u3100-\u312f\u31a0-\u31bf\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uac00-\ud7af"
                 "\U00020000-\U0003134f]")  # 假名、注音、CJK 統一表意文字（含擴充 A、相容與擴充 B 以後）、韓文音節

STEP_DOCKER = "照 AGENTS.md「工作階段的規則」，docker 指令先問維護者；驗收證據以 GitHub CI 為準"
STEP_VERIFY = ("不碰 cm_verify_* 驗證環境（維護者人工驗收用的容器與 volume，doc/USER-VERIFICATION.md 的準備表）："
               "不啟動、不停止、不重建、不改；要操作請維護者自己執行")
STEP_TOKEN = "token 檔不讀、不搜尋、不複製（AGENTS.md「工作階段的規則」）；需要 token 的步驟請維護者自己執行"
STEP_READ = ("要讀單一檔案就用 Read（Read 有 Read(//**/*token*.md) 的 deny 規則，照 symlink 解析到的檔比對）；"
             "Grep 工具、Bash 的 grep -r、rg 這類遞迴搜尋，與 git grep 會讀沒追蹤檔或 repo 外檔的寫法一律擋（#412、#426）")
STEP_GIT_GREP = ("跨檔搜尋內容用 git grep：不加 --no-index、--untracked、-O，前面不加 git -c、--config-env 或 GIT_CONFIG… 的設定，"
                 "只搜 repo 追蹤的檔")
STEP_SEARCH = (STEP_READ, STEP_GIT_GREP)  # 遞迴搜尋、Grep 工具與 git grep 被擋時的下一步（#426 調整需求第 2 點）
STEP_RUNNER = "不經 xargs、parallel，直接下 git grep"
STEP_LITERAL = "git 的選項與子指令寫成字面"
STEP_GREP_ARGS = "git grep 的選項寫成字面；要搜的字串來自變數時寫成 -e \"$X\"，路徑放在 -- 後面"
STEP_XARGS = "xargs 後面的 git 寫明字面的子指令（不用替換字串）"
STEP_SHELL_RUNNER = "不經 watch、parallel，直接下 git"
STEP_PROGRAM = "程式名稱寫成字面（例如 git、sudo），不放在變數裡"
STEP_PAGER = "要看符合的檔，用 git grep -l 列出檔名，再用 Read 讀；不加 -O、--open-files-in-pager"
STEP_WORKTREE = ("改到 worktree 裡做：從最新的 origin/main 另開 worktree（git worktree add -b <分支> <目錄> origin/main），"
                 "在那裡切分支；要還原檔案就寫 git checkout -- <檔>")
STEP_DIR = "改到 worktree 裡做，或寫明目錄（git -C <worktree 的目錄> switch …，目錄寫成字面、不放在子 shell 裡 cd）"
STEP_DESCRIPTION = "用繁體中文寫指令說明（Bash 工具的 description），再重送"
STEP_SPLIT = "把指令拆開，每段的程式、參數與路徑寫成字面"
STEP_INPUT = ("這支由 Claude Code 的 PreToolUse hook 呼叫；手動執行時，把 hook 會收到的 JSON（tool_name、tool_input、cwd）"
              "餵進標準輸入")
STEP_ENTRIES = "確認 script/claude-hooks/docker-entrypoints.txt 在這個簽出裡、讀得到，再重送"

# shell-parse.sh 的分析程序用的兩個說法
COMMANDS = "docker／git／grep 這類指令"
UNPARSABLE = "判斷不了它會不會開 docker、讀 token 檔或在主 checkout 切分支"

DENY = []  # (位置, 原因, 下一步)；下一步是一句，或依序的幾句（tuple）
ASK = []   # 位置


def block(where, why, step):
    item = (where, why, step)
    if item not in DENY:
        DENY.append(item)


def ask(where):
    if where not in ASK:
        ASK.append(where)


def finish():
    if DENY:
        err = sys.stderr
        print(f"{TAG}: 擋下這次的工具呼叫（#412）：docker 先問、不碰 cm_verify_* 驗證環境、不讀 token 檔、不在主 checkout "
              "切換分支、指令說明用中文，或是有 hook 判斷不了的地方。", file=err)
        steps = []
        for where, why, step in DENY:
            print(f"{TAG}:   - {where}：{why}", file=err)
            for line in step if isinstance(step, tuple) else (step,):
                if line not in steps:
                    steps.append(line)
        print(f"{TAG}: 下一步：", file=err)
        for step in steps:
            print(f"{TAG}:   - {step}", file=err)
        sys.exit(2)
    if ASK:
        reason = (f"{TAG}: docker 先問（#412）：這條指令會執行 docker 或會開 docker 的入口（{'、'.join(ASK)}）。"
                  f"{STEP_DOCKER}。")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                                                 "permissionDecisionReason": reason}}, ensure_ascii=False))
    sys.exit(0)


def stop(where, why, step):
    block(where, why, step)
    finish()


# ── 入口清單 ──────────────────────────────────────────────────────────────

PROGRAMS = set()   # docker、docker-compose
RECIPES = set()    # just 的 docker、test
SCRIPTS = []       # script/x.sh


def load_entries():
    try:
        with open(ENTRY_FILE, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except (OSError, UnicodeDecodeError) as error:
        stop("入口清單 docker-entrypoints.txt", f"讀不到（{getattr(error, 'strerror', None) or type(error).__name__}），"
             "判斷不了哪些指令會開 docker", STEP_ENTRIES)
    for line in lines:
        text = line.split("#", 1)[0].strip()
        if not text:
            continue
        if text.startswith("script/"):
            SCRIPTS.append(text)
        elif text.startswith("just "):
            RECIPES.add(text.split()[1])
        else:
            PROGRAMS.add(text)
    if not PROGRAMS or not SCRIPTS:
        stop("入口清單 docker-entrypoints.txt", "裡面沒有程式或腳本，判斷不了哪些指令會開 docker", STEP_ENTRIES)


def entry_script(word, state):
    """這個字指到清單上的哪一支腳本（./script/x.sh、script/x.sh、"$X"/script/x.sh、cd script 之後的 ./x.sh）；不是就是 None。"""
    text = word.text
    if not text:
        return None
    candidates = [os.path.normpath(text)]
    if word.static and state is not None and state.cwd is not None and not os.path.isabs(text):
        candidates.append(os.path.normpath(os.path.join(state.cwd, text)))
    for candidate in candidates:
        for script in SCRIPTS:
            if candidate == script or candidate.endswith("/" + script):
                return script
    return None


# ── 依指令分派（shell-parse.sh 的 analyze 呼叫） ─────────────────────────

GREPS = {"grep", "egrep", "fgrep"}
RUNNERS = {"sudo", "doas", "xargs", "watch", "parallel", "caffeinate", "stdbuf", "unbuffer"}

# 這一段指令前面與 env 後面的變數設定名稱，給 git grep 的 GIT_CONFIG… 規則用（#426）。shell-parse.sh 的 command_words 只回傳
# 前面的，env 後面的由 strip_wrappers 拿掉；git switch 的規則照舊只看前面的。
VARIABLES = []

_shared_strip_wrappers = strip_wrappers
_shared_command_words = command_words


def assigned(word):
    """NAME=值 設定的變數名稱（值來自 shell 展開也算）；不是變數設定就回 None。"""
    return word.prefix.split("=", 1)[0].rstrip("+") if ASSIGN.match(word.prefix) else None


def strip_wrappers(words):  # 取代 shell-parse.sh 的同名函式：拿掉的包裝裡的變數設定（env NAME=值）另記進 VARIABLES
    rest = _shared_strip_wrappers(words)
    VARIABLES.extend(name for name in map(assigned, words[:len(words) - len(rest)]) if name)
    return rest


def command_words(command):  # 取代 shell-parse.sh 的同名函式：每一段指令重記 VARIABLES，前面的變數設定也記進去
    del VARIABLES[:]
    assignments, words = _shared_command_words(command)
    VARIABLES[:0] = assignments
    return assignments, words


def dispatch(program, args, state, assignments, words):
    script = entry_script(words[0], state)
    if script is not None:
        ask(script)
    if program in PROGRAMS:
        ask(program)
    elif program == "just":
        analyze_just(args)
    elif program in (".", "source"):
        if args:
            sourced = entry_script(args[0], state)
            if sourced is not None:
                ask(f"{program} {sourced}")
    elif program == "git":
        analyze_git(args, state, assignments)
        git_rules(args, VARIABLES, None)
    elif program in GREPS:
        analyze_grep(program, args)
    elif program == "rg":
        block("rg", "rg 會讀搜尋範圍裡每個檔的內容；它的設定檔、跟不跟隨 symlink 都會改變實際的搜尋範圍，只看指令判斷不了"
              "會不會讀到 token 檔", STEP_SEARCH)
    elif program == "find":
        analyze_find(args, state)
    elif program in RUNNERS:
        analyze_runner(program, args, state)


def indirect(words):
    """程式名稱來自 shell 展開（例如 "$REPO"/script/test.sh、$SUDO docker）：看字面的部分與後面的字。"""
    script = entry_script(words[0], None)
    if script is not None:
        ask(script)
    elif os.path.basename(words[0].text) in PROGRAMS:
        ask(os.path.basename(words[0].text))
    indirect_git_grep(words[1:], VARIABLES, None)
    analyze_runner(None, words[1:], None)


def indirect_git_grep(args, variables, runner):
    """程式名稱來自 shell 展開、後面有字面的 grep（#436 調整需求第 1 點）：把那個程式當成可能是 git，照 git grep 的規則看。
    args 是程式名稱後面的字；第一個字面的 grep 當成子指令，前面的字只看 -c、--config-env。後面沒有字面的 grep 的不看（例如
    "$PY" -m pip install --no-index）。下一步先寫「程式名稱寫成字面」，再寫被觸發的那條 git grep 規則的下一步。"""
    for k, word in enumerate(args):
        if word.static and word.text == "grep":
            break
    else:
        return
    options = [((w.text if w.static else w.prefix).split("=", 1)[0], None) for w in args[:k]]
    who = "程式名稱來自 shell 展開" if runner is None else f"{runner} 執行、程式名稱來自 shell 展開"
    git_grep_checks(f"{who}、後面有 grep 的指令（可能是 git grep）", options, args[k + 1:], variables, runner,
                    (STEP_PROGRAM,))


def analyze_runner(runner, args, state):
    """把後面的字當成指令執行的程式（xargs、sudo、find -exec…）：裡面有清單上的入口就先問，有 grep、rg 就擋；git grep 照
    直接下的規則（#426），它的子指令 grep 不當成 grep 程式。"""
    skips = set()  # git grep 的子指令 grep 在 args 裡的位置
    for i, word in enumerate(args):
        if i in skips:
            continue
        if not word.static:  # 程式名稱可能就是這個展開（sudo "$GIT" grep …）：照同樣的規則（#436）
            indirect_git_grep(args[i + 1:], VARIABLES + [name for name in map(assigned, args[:i]) if name], runner)
            continue
        name = os.path.basename(word.text)
        script = entry_script(word, state)
        if script is not None:
            ask(script)
        elif name in PROGRAMS:
            ask(name)
        elif name == "just":
            analyze_just(args[i + 1:])
        elif name in GREPS or name == "rg":
            if runner in ("xargs", "find") or name == "rg":
                block(f"{runner or '這條指令'} 執行的 {name}", f"{name} 交給別的程式執行，搜尋哪些檔在執行時才決定，"
                      "hook 判斷不了會不會讀到 token 檔", STEP_SEARCH)
            else:
                analyze_grep(name, args[i + 1:])
        elif name == "git":
            if runner in ("sudo", "doas"):
                analyze_git(args[i + 1:], state if state is not None else State(None), [])
            _, subcommand, rest = git_parts(args[i + 1:])
            if subcommand == "grep":
                skips.add(len(args) - len(rest) - 1)
            # 包裝程式後面、git 前面的變數設定（sudo NAME=值、sudo env NAME=值）也算
            variables = VARIABLES + [name for name in map(assigned, args[:i]) if name]
            via, between = nearest_runner(runner, args[:i])
            git_rules(args[i + 1:], variables, via or "這條指令", between)


def nearest_runner(runner, before):
    """(執行 git 的包裝程式, 它和 git 之間的字)：git 前面最近的包裝程式（sudo xargs git … 是 xargs，#436）；前面的字裡沒有
    包裝程式，就是 runner 與前面全部的字。"""
    for k in range(len(before) - 1, -1, -1):
        word = before[k]
        if word.static and os.path.basename(word.text) in RUNNERS:
            return os.path.basename(word.text), before[k + 1:]
    return runner, before


# ── 第 1 點：just 的 recipe ──────────────────────────────────────────────

JUST_VALUES = {"-f", "--justfile", "-d", "--working-directory", "--dotenv-filename", "--dotenv-path", "-E", "--shell",
               "--shell-arg", "--chooser", "--color", "--command-color", "--list-heading", "--list-prefix",
               "--timestamp-format", "--alias-style"}


def analyze_just(args):
    i = 0
    while i < len(args):
        word = args[i]
        if not word.static:
            ask("just（recipe 來自 shell 展開，判斷不了會不會開 docker）")
            return
        text = word.text
        if text == "--set":
            i += 3
        elif text in JUST_VALUES:
            i += 2
        elif text.startswith("-"):
            i += 1
        else:
            if text.split("::", 1)[0] in RECIPES:
                ask(f"just {text}")
            return


_shared_analyze_shell = analyze_shell


def analyze_shell(args, state):  # 取代 shell-parse.sh 的同名函式：另外看 bash script/x.sh 執行的腳本
    _shared_analyze_shell(args, state)
    i = 0
    while i < len(args) and args[i].static and args[i].text[:1] in ("-", "+") and args[i].text not in ("-", "--"):
        text = args[i].text
        if text in ("-o", "+o"):
            i += 2
            continue
        if not text.startswith("--") and "c" in text[1:]:
            return
        i += 1
    if i < len(args) and args[i].static and args[i].text == "--":
        i += 1
    if i < len(args):
        script = entry_script(args[i], state)
        if script is not None:
            ask(f"bash {script}")


# ── 第 4 點：token 檔與遞迴搜尋 ───────────────────────────────────────────

def token_named(text):
    """檔名（最後一段）含 token 的 .md，不分大小寫。萬用字元照字面看（**/*token*.md 也算）。"""
    name = text.rstrip("/").rsplit("/", 1)[-1].lower()
    return "token" in name and name.endswith(".md")


def each_word(items):
    for item in items:
        if item in (PUSH, POP):
            continue
        for word in item.words + [r[1] for r in item.redirections if r[1] is not None]:
            yield word
            for inner in word.nested:
                yield from each_word(build(inner))


GREP_VALUE_SHORT = "efmABCdD"
GREP_VALUE_LONG = {"--regexp", "--file", "--max-count", "--after-context", "--before-context", "--context",
                   "--directories", "--devices", "--include", "--exclude", "--exclude-dir", "--exclude-from", "--label",
                   "--binary-files"}


def analyze_grep(program, args):
    """grep -r／-R／--recursive／-d recurse 這類遞迴搜尋就擋；搜尋指名的檔不擋（指名 token 檔另外擋）。"""
    i = 0
    while i < len(args):
        word = args[i]
        text = word.text if word.static else word.prefix
        if word.static and text == "--":
            return
        recursive = None
        if text.startswith("--"):
            name, equals, value = text.partition("=")
            if name in ("--recursive", "--dereference-recursive"):
                recursive = name
            elif name in GREP_VALUE_LONG:
                if not equals:
                    i += 1
                    value = args[i].text if i < len(args) else ""
                if name == "--directories" and value == "recurse":
                    recursive = "--directories=recurse"
        elif text.startswith("-") and len(text) > 1:
            for j, option in enumerate(text[1:]):
                if option in "rR":
                    recursive = f"-{option}"
                    break
                if option in GREP_VALUE_SHORT:
                    value = text[j + 2:]
                    if not value:
                        i += 1
                        value = args[i].text if i < len(args) else ""
                    if option == "d" and value == "recurse":
                        recursive = "-d recurse"
                    break
        if recursive is not None:
            block(f"{program} {recursive}", "遞迴搜尋會讀目錄底下每個檔的內容；Read 的 deny 規則不涵蓋這類指令，grep 跟不跟隨 "
                  "symlink 也會改變實際的搜尋範圍，只看指令判斷不了會不會讀到 token 檔", STEP_SEARCH)
            return
        i += 1


def analyze_find(args, state):
    for i, word in enumerate(args):
        if word.static and word.text in ("-exec", "-execdir", "-ok", "-okdir"):
            analyze_runner("find", args[i + 1:], state)
            return


# git grep（#426）：不帶 --no-index、--untracked 的 git grep 只搜 repo 追蹤的檔（git-grep(1)），是跨檔搜尋內容的替代做法；會讀
# 沒追蹤檔或 repo 外檔的寫法擋下。只看指令文字（Q1），不讀 git 設定。

GIT_GREP_FLAGS = {"--no-index": "會搜目前目錄底下不歸 git 管的檔，在 repo 外執行時就是那個資料夾裡的每個檔",
                  "--untracked": "會連 repo 裡沒追蹤的檔一起搜"}
GIT_GREP_VALUE_SHORT = "ef"       # -e、-f 的值是要搜的字串、讀字串的檔，不算選項
GIT_GREP_ATTACHED_SHORT = "ABCm"   # 連寫時，後面的字是它的值
GIT_GREP_PAGER = "--open-files-in-pager"  # 與 -O：用 pager 開符合的檔；值只收連寫的（#436）


def git_grep_flag(text):
    """--no-index、--untracked，或它們至少到 --n／--u 的前綴（長選項可以縮寫，照 Q8 都算）；--x=值 只看 = 前面。不是就回 None。"""
    name = text.split("=", 1)[0]
    if len(name) < 3:
        return None
    for flag in GIT_GREP_FLAGS:
        if flag.startswith(name):
            return flag
    return None


def git_grep_pager(name):
    """--open-files-in-pager 與它至少到 --o 的前綴（--o 在 git 上有歧義，照 #426 對 --n 的做法也算）；--x=值 只看 = 前面。"""
    return len(name) >= 3 and GIT_GREP_PAGER.startswith(name)


def git_grep_findings(args):
    """git grep 的參數（-- 之前）裡 hook 要擋的字：[(種類, 補充, 那個字)]（#426、#436）。種類是
      "flag"    寫成選項的 --no-index、--untracked（含縮寫），補充是完整的選項名；來自 shell 展開的字看展開前的字面部分；
      "split"   會拆成好幾個字的字（Word.splits），-e、-f 的值也算；
      "pager"   -O（短選項連寫裡的 O，前面沒有吃掉後面字的 e、f、A、B、C、m）、--open-files-in-pager 與它至少到 --o 的
                前綴，有沒有 =值 都算；
      "opaque"  不會拆的展開字，展開前的字面部分看不出它是不是選項（封閉條件，見下面）。
    不會拆的展開字放行的條件（#436 調整需求第 1 點）：-e、-f 的值；字面部分不是空的、不以 - 開頭；字面部分以 -- 開頭而且含
    =（看 = 前面的名稱）；字面部分是 - 開頭的短選項連寫，在字面部分裡就碰到要值的字母（e、f、A、B、C、m），看那個字母前面的
    部分。其他的（字面部分是空的、-n"$X"、--un"$X" 這類還沒寫完的選項）都擋。"""
    found = []
    i = 0
    while i < len(args):
        word = args[i]
        text = word.text if word.static else word.prefix
        if word.splits:
            found.append(("split", None, word))
        if word.static and text == "--":
            break
        if text.startswith("--"):
            name, equals, _ = text.partition("=")
            flag = git_grep_flag(name)
            if flag is not None:
                found.append(("flag", flag, word))
            if git_grep_pager(name):
                found.append(("pager", None, word))
            if not word.static and not equals and not word.splits:
                found.append(("opaque", None, word))
        elif text.startswith("-") and (len(text) > 1 or not word.static):
            value = False  # 在字面部分裡碰到要值的字母
            for j, option in enumerate(text[1:]):
                if option in GIT_GREP_VALUE_SHORT:
                    if word.static and not text[j + 2:] and i + 1 < len(args):
                        i += 1  # 值是下一個字：會拆成好幾個字才擋
                        if args[i].splits:
                            found.append(("split", None, args[i]))
                    value = True
                    break
                if option in GIT_GREP_ATTACHED_SHORT:
                    value = True
                    break
                if option == "O":  # 後面連寫的字是 pager 的程式
                    found.append(("pager", None, word))
                    value = True
                    break
            if not word.static and not value and not word.splits:
                found.append(("opaque", None, word))
        elif not word.static and not text and not word.splits:
            found.append(("opaque", None, word))
        i += 1
    return found


def shown_word(word):
    """訊息裡怎麼寫這個字：字面的照寫；有展開的寫字面部分加「…」與展開的種類（大括號展開記成大括號展開）。"""
    if word.static:
        return f"{word.text}（大括號展開）" if word.splits else word.text
    return f"{word.prefix}…（{word.dynamic}）"


GIT_GREP_CONFIG = ("會改這次搜尋的 git 設定（例如 grep.fallbackToNoIndex 讓 repo 外的 git grep 改用 --no-index）；hook 不讀 git "
                   "設定（Q1），判斷不了實際搜尋的範圍")


def git_words(args):
    """git 後面的字分成 (全域選項, 子指令, 子指令後面的字, 判斷不了的原因)（#436 調整需求第 1 點）。全域選項是依序的
    (名稱, 值的 Word 或 None)。要值的全域選項（-C、-c…）後面那個字，與字面部分以 -- 開頭又含 = 的字（--git-dir="$D"）是全域選項
    的值，來自展開也一樣，不算子指令。這一段裡有會拆成好幾個字的字，或子指令來自展開時，子指令是 None、原因是那一句。沒有子指令時
    子指令是空字串。shell-parse.sh 的 git_parts 照舊（其他 hook 與 git switch 的規則用它），這裡另外分。"""
    options = []
    i = 0
    while i < len(args):
        word = args[i]
        head = word.text if word.static else word.prefix
        if word.splits:
            return options, None, args[i:], f"git 的全域選項或子指令這一段有會拆成好幾個字的 {shown_word(word)}"
        if word.static and head in GIT_GLOBAL_VALUES:
            value = args[i + 1] if i + 1 < len(args) else None
            if value is not None and value.splits:
                return options, None, args[i + 1:], f"git {head} 的值 {shown_word(value)}會拆成好幾個字"
            options.append((head, value))
            i += 2
        elif (word.static and head.startswith("-")) or (head.startswith("--") and "=" in head):
            name = head.split("=", 1)[0]
            options.append((name, sub_word(word, len(name) + 1) if "=" in head else None))
            i += 1
        elif not word.static:
            return options, None, args[i:], f"git 的子指令（或全域選項）{shown_word(word)}來自 shell 展開"
        else:
            return options, head, args[i + 1:], None
    return options, "", [], None


def git_rules(args, variables, runner, between=()):
    """git 後面的字 args 的規則（#426、#436）。variables 是這一段指令前面、env 與包裝程式後面的變數設定名稱；runner 是執行它的
    包裝程式（直接下的是 None）；between 是包裝程式和 git 之間的字（xargs 的選項）。"""
    who = "git" if runner is None else f"{runner} 執行的 git"
    options, subcommand, rest, unclear = git_words(args)
    if runner in ("watch", "parallel"):
        block(who, f"{runner} 會把組好的指令交給 shell 再解讀一次，hook 看到的字不是實際執行的字（Q8）",
              (STEP_SHELL_RUNNER,) + STEP_SEARCH)
    if runner == "xargs":
        xargs_rules(who, args, between, subcommand, rest)
    if unclear is not None:
        block(who, f"{unclear}，判斷不了實際執行的是哪個子指令、帶了哪些選項（Q8）", (STEP_LITERAL,) + STEP_SEARCH)
        return
    if subcommand == "grep":  # 子指令是字面、不是 grep 的，後面的字不看
        git_grep_checks(f"{who} grep", options, rest, variables, runner, ())


XARGS_VALUES = "adEIJLnPRSs"  # 要值的短選項（macOS 與 GNU 的 xargs）：值連寫在後面，或是下一個字
XARGS_OPTIONAL = "eil"        # GNU 的 -e[eof]、-i[replace]、-l[max-lines]：值只能連寫
XARGS_LONG_VALUES = {"--arg-file", "--delimiter", "--max-args", "--max-procs", "--max-chars", "--process-slot-var"}


def xargs_replacements(words):
    """(xargs 的選項指定的替換字串 [(選項, 字串)], 判斷不了)。words 是 xargs 和它執行的程式之間的字。-I、-J 照寫；GNU 的
    -i[replace]、--replace[=replace] 沒寫值時是 {}（GNU xargs(1)）。選項或替換字串來自 shell 展開、替換字串是空的，就判斷不了。"""
    found = []
    i = 0
    while i < len(words):
        word = words[i]
        if not word.static:
            return found, True
        text = word.text
        if text.startswith("--"):
            name, equals, value = text.partition("=")
            if name == "--replace":
                found.append(("--replace", value if equals else "{}"))
            elif name in XARGS_LONG_VALUES and not equals:
                i += 1
        elif text.startswith("-") and len(text) > 1:
            for j, letter in enumerate(text[1:], 2):
                tail = text[j:]
                if letter in "IJ":
                    if not tail:
                        i += 1
                        if i >= len(words) or not words[i].static:
                            return found, True
                        tail = words[i].text
                    found.append((f"-{letter}", tail))
                    break
                if letter == "i":
                    found.append(("-i", tail or "{}"))
                    break
                if letter in XARGS_OPTIONAL:
                    break
                if letter in XARGS_VALUES:
                    if not tail:
                        i += 1
                    break
        i += 1
    return found, any(not text for _, text in found)


def xargs_rules(who, args, between, subcommand, rest):
    """經 xargs 執行的 git（#436）：子指令沒寫、來自展開或會拆成好幾個字，子指令含替換字串，或 -J 的字在子指令前面就擋。xargs
    沒有替換選項時把讀到的字接在最後（xargs(1)），所以子指令寫成字面、又不是替換字串，標準輸入就變不成子指令。"""
    step = (STEP_XARGS,) + STEP_SEARCH
    if not subcommand:
        block(who, "子指令沒寫或來自 shell 展開，xargs 會把標準輸入讀到的字接在 git 後面，子指令可能就是那些字（Q8）", step)
        return
    replacements, unclear = xargs_replacements(between)
    if unclear:
        block(who, "xargs 的選項或替換字串來自 shell 展開（或是空的），判斷不了子指令會不會被換成標準輸入讀到的字（Q8）", step)
        return
    head = args[:len(args) - len(rest)]  # 全域選項與子指令
    for option, text in replacements:
        if text in subcommand:
            block(who, f"子指令 {subcommand} 含 xargs {option} 的替換字串 {text}，子指令會被換成標準輸入讀到的字（Q8）", step)
        elif option == "-J" and any(text in w.text for w in head):
            block(who, f"xargs -J 的替換字串 {text} 在子指令前面：讀到的參數全部放在那裡，子指令可能就是其中一個（Q8）", step)


GIT_GREP_SPLIT = ("展開後會拆成好幾個字（沒加雙引號的變數、指令替換、算術展開，\"$@\"、萬用字元、大括號展開），其中一個可能就是 "
                  "--untracked 這類選項，hook 看不到（Q8）")
GIT_GREP_PAGER_WHY = ("-O、--open-files-in-pager 用 pager 開符合的檔：值（沒寫時是 GIT_PAGER、core.pager、PAGER）經 shell 執行，"
                      "可以是任何指令，hook 不分析它，也讀不到設定與環境變數（Q1、Q8）")
GIT_GREP_OPAQUE = "來自 shell 展開，展開前的字面部分看不出它是不是選項，展開後可能就是 --untracked 這類選項（Q8）"


def git_grep_checks(who, options, rest, variables, runner, lead):
    """git grep 的規則（#426、#436）。who 是訊息裡的位置；options 是 grep 前面的全域選項；rest 是 grep 後面的字；variables
    是這一段指令前面、env 與包裝程式後面的變數設定名稱；runner 是執行它的包裝程式（直接下的是 None）；lead 是每一句下一步前面
    另加的句子。"""
    if runner in ("xargs", "parallel"):
        block(who, f"{runner} 會把讀到的字接在指令後面當參數，參數可能來自標準輸入，hook 看不到會不會加上 --no-index、"
              "--untracked（Q8）", lead + (STEP_RUNNER,) + STEP_SEARCH)
    for name, _ in options:
        if name in ("-c", "--config-env"):
            block(f"{who} 前面的 git {name}", GIT_GREP_CONFIG, lead + STEP_SEARCH)
    for name in variables:
        if name.startswith("GIT_CONFIG"):
            block(f"{who} 前面的 {name}=", GIT_GREP_CONFIG, lead + STEP_SEARCH)
    for kind, flag, word in git_grep_findings(rest):
        if kind == "pager":
            text = word.text if word.static else word.prefix
            block(f"{who} 的 {text}", GIT_GREP_PAGER_WHY, lead + (STEP_PAGER,) + STEP_SEARCH)
        elif kind == "flag":
            text = word.text if word.static else word.prefix
            alias = " " if text.split("=", 1)[0] == flag else f"（{text} 是它的縮寫）"
            block(f"{who} 的 {text}", f"{flag}{alias}{GIT_GREP_FLAGS[flag]}，可能讀到 token 檔", lead + STEP_SEARCH)
        else:
            block(f"{who} 的參數 {shown_word(word)}", GIT_GREP_SPLIT if kind == "split" else GIT_GREP_OPAQUE,
                  lead + (STEP_GREP_ARGS,) + STEP_SEARCH)


def file_rules(tool, tool_input):
    path = tool_input.get("file_path")
    if isinstance(path, str) and token_named(path):
        block(f"{tool} 的 file_path {path}", "這是檔名含 token 的 .md，存放存取 token 的檔不讀、不改", STEP_TOKEN)


def grep_rules(tool_input):
    """Grep 工具一律擋（#412 本文 2026-11-25 改）：搜尋範圍裡指向 token 檔的 symlink，hook 只看輸入分不出來；Grep 遞迴時跟不跟隨
    symlink、deny 規則對 Grep 是 best-effort，實測又做不到，照 Q8 擋。path 指檔案還是目錄 hook 不區分（Q1），所以單一檔案也擋。"""
    for field in ("path", "glob"):
        value = tool_input.get(field)
        if isinstance(value, str) and token_named(value):
            block(f"Grep 的 {field} {value}", "指名了檔名含 token 的 .md", STEP_TOKEN)
    block("Grep", "Grep 會讀搜尋範圍裡每個檔的內容；範圍裡指向 token 檔的 symlink，hook 只看輸入分不出來，Grep 跟不跟隨 symlink "
          "文件沒寫、deny 規則對 Grep 只是 best-effort", STEP_SEARCH)


def glob_rules(tool_input):
    """Glob 只回傳路徑、不讀內容：沒有指名 token 檔就放行。"""
    for field in ("pattern", "path"):
        value = tool_input.get(field)
        if isinstance(value, str) and token_named(value):
            block(f"Glob 的 {field} {value}", "指名了檔名含 token 的 .md", STEP_TOKEN)


# ── 第 5 點：主 checkout 不切分支 ─────────────────────────────────────────

# 子 shell（( … )、$( … )）、bash -c 與 eval 裡的 cd：shell-parse.sh 不把它的目錄帶回外層，這裡把它當成判斷不了（Q8）。
SHELL_DEPTH = [0]
NESTED_CD = [False]


def run_items(items, state):  # 取代 shell-parse.sh 的同名函式：多記子 shell 的層數
    saved = []
    SHELL_DEPTH[0] += 1
    try:
        for item in items:
            if item == PUSH:
                saved.append(state.cwd)
                SHELL_DEPTH[0] += 1
            elif item == POP:
                if saved:
                    state.cwd = saved.pop()
                    SHELL_DEPTH[0] -= 1
            else:
                analyze(item, state)
    finally:
        SHELL_DEPTH[0] -= 1 + len(saved)


_shared_change_directory = change_directory


def change_directory(args, state):  # 取代 shell-parse.sh 的同名函式：子 shell 裡的 cd 另外記下
    _shared_change_directory(args, state)
    if SHELL_DEPTH[0] > 1:
        NESTED_CD[0] = True


SWITCHERS = ("switch", "checkout")
NEW_BRANCH = ("-b", "-B", "--orphan", "--detach")


def checkout_switches(rest):
    """git checkout 的參數會不會切換分支：沒有參數，或有 -- 而且前面沒有 -b、-B、--orphan、--detach、shell 展開，才算只還原檔案。"""
    if not rest:
        return False
    texts = [w.text if w.static else None for w in rest]
    if "--" not in texts:
        return True
    before = texts[:texts.index("--")]
    return any(t is None or t in NEW_BRANCH or t.startswith("--orphan=") for t in before)


def linked_worktree(dotgit):
    """(是不是 linked worktree, 確認不了時的原因)。照 git worktree 文件核對 gitdir、commondir 與 worktrees/<名稱> 三者。"""
    try:
        with open(dotgit, encoding="utf-8") as handle:
            first = handle.readline().strip()
    except (OSError, UnicodeDecodeError):
        return False, f"讀不到 {dotgit}"
    if not first.startswith("gitdir:"):
        return False, f"{dotgit} 不是 gitdir: <路徑> 的格式"
    admin = os.path.realpath(os.path.join(os.path.dirname(dotgit), first[len("gitdir:"):].strip()))
    try:
        with open(os.path.join(admin, "commondir"), encoding="utf-8") as handle:
            common = handle.readline().strip()
    except (OSError, UnicodeDecodeError):
        return False, f"{dotgit} 指到的管理目錄 {admin} 裡沒有 commondir（例如 submodule、分離的 git 目錄建的主 checkout）"
    common = os.path.realpath(os.path.join(admin, common))
    if os.path.realpath(os.path.join(common, "worktrees", os.path.basename(admin))) != admin:
        return False, f"管理目錄 {admin} 不是共用目錄 {common} 底下的 worktrees/<名稱>"
    return True, ""


def checkout_kind(directory):
    """("main" | "linked" | "unknown", 說明)：從 directory 往上找 .git，只讀檔案、不呼叫 git（Q1）。"""
    path = os.path.realpath(directory)
    if not os.path.isdir(path):
        return "unknown", f"目錄 {directory} 不存在"
    while True:
        dotgit = os.path.join(path, ".git")
        if os.path.isdir(dotgit):
            return "main", f"{dotgit} 是資料夾"
        if os.path.isfile(dotgit):
            linked, why = linked_worktree(dotgit)
            return ("linked", "") if linked else ("unknown", why)
        if os.path.lexists(dotgit):
            return "unknown", f"{dotgit} 不是檔案也不是資料夾"
        parent = os.path.dirname(path)
        if parent == path:
            return "unknown", f"從 {directory} 往上找不到 .git"
        path = parent


def analyze_git(args, state, assignments):
    options, subcommand, rest = git_parts(args)
    if subcommand is None:
        if any(a.static and a.text in SWITCHERS for a in rest):
            block("git", "git 的選項或子指令來自 shell 展開，判斷不了是不是在主 checkout 切換分支", STEP_DIR)
        return
    if subcommand not in SWITCHERS or (subcommand == "checkout" and not checkout_switches(rest)):
        return
    where = f"git {subcommand}"
    for name in assignments:
        if name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"):
            block(f"{where} 前面的 {name}=", "這個環境變數會改 git 找 repo 的位置，判斷不了在哪個簽出切換", STEP_DIR)
            return
    directory = state.cwd
    for name, value in options:
        if name in ("--git-dir", "--work-tree"):
            block(f"{where} 的 {name}", "會改 git 找 repo 的位置，判斷不了在哪個簽出切換", STEP_DIR)
            return
        if name == "-C":
            if value is None or not value.static:
                block(f"{where} 的 -C", "目錄來自 shell 展開或沒寫，判斷不了在哪個簽出切換", STEP_DIR)
                return
            if value.text:
                directory = resolve(directory, value.text)
    if directory is None or NESTED_CD[0]:
        block(where, "這條指令先切換到 hook 判斷不了的目錄（cd 的目錄來自 shell 展開、cd -、popd、子 shell 或 bash -c 裡的 cd，"
              "或 hook 的輸入沒有 cwd）", STEP_DIR)
        return
    kind, detail = checkout_kind(directory)
    if kind == "main":
        block(f"{where}（{directory}）", f"這是主 checkout（{detail}）：主 checkout 不切換分支（AGENTS.md「工作階段的規則」）",
              STEP_WORKTREE)
    elif kind == "unknown":
        block(f"{where}（{directory}）", f"確認不了這裡是 linked worktree：{detail}", STEP_WORKTREE)


# ── 第 6 點：指令說明要中文 ───────────────────────────────────────────────

def description_rule(description):
    if not isinstance(description, str) or not description.strip():
        block("Bash 的 description", "沒有指令說明（AGENTS.md「工作階段的規則」：回覆一律用繁體中文，包括指令說明）",
              STEP_DESCRIPTION)
    elif not CJK.search(description):
        block("Bash 的 description", "指令說明沒有任何中文字（AGENTS.md「工作階段的規則」：回覆一律用繁體中文，包括指令說明）",
              STEP_DESCRIPTION)


# ── 進入點 ────────────────────────────────────────────────────────────────

def bash_rules(data):
    command, cwd = input_command(data, STEP_INPUT)
    description_rule(data["tool_input"].get("description"))
    if not MENTIONS.search(command):
        return
    load_entries()
    items = lex(command)
    if items is None:
        return
    for word in each_word(items):
        if word.text and token_named(word.text):
            block(f"Bash 指令裡的 {word.text}", "這是檔名含 token 的 .md，存放存取 token 的檔不讀、不搜尋、不複製", STEP_TOKEN)
    run_items(items, State(cwd))
    if ASK and CM_VERIFY.search(command):
        block(f"{'、'.join(ASK)}（指令裡有 cm_verify）", "會碰到 cm_verify_* 驗證環境", STEP_VERIFY)


def main():
    data = load_input(STEP_INPUT)
    tool = data.get("tool_name")
    if tool == "Bash":
        bash_rules(data)
    elif tool in ("Read", "Edit", "Write", "Grep", "Glob"):
        tool_input = data.get("tool_input")
        if not isinstance(tool_input, dict):
            stop("hook 的輸入", "JSON 裡沒有 tool_input，看不到這次的工具呼叫", STEP_INPUT)
        if tool == "Grep":
            grep_rules(tool_input)
        elif tool == "Glob":
            glob_rules(tool_input)
        else:
            file_rules(tool, tool_input)
    finish()


try:
    main()
except SystemExit:
    raise
except Unparsable as error:
    stop("這條指令", f"讀不懂它的結構（{error}），{UNPARSABLE}", STEP_SPLIT)
except Exception as error:  # 任何沒預料到的錯誤都擋下，不讓 Claude Code 當成放行
    print(f"{TAG}: 判斷時發生沒預料到的錯誤（{type(error).__name__}），這次的工具呼叫先擋下（#412）。", file=sys.stderr)
    print(f"{TAG}: 下一步：{STEP_SPLIT}；這個錯誤請回報到 #412", file=sys.stderr)
    sys.exit(2)
PY

python3 -c "$(shell_parse_program)
${program}" "${here}/docker-entrypoints.txt"
code=$?
if [ "${code}" -eq 0 ] || [ "${code}" -eq 2 ]; then
  exit "${code}"
fi
printf 'env-rules: 判斷中途失敗（python3 結束碼 %s），這次的工具呼叫先擋下（#412）。\n' "${code}" >&2
printf 'env-rules: 下一步：照上面 python3 印的原因修正；修不了就把指令拆開，每段的程式、參數與路徑寫成字面\n' >&2
exit 2
