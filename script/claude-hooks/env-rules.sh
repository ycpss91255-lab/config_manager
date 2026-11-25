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
#            find … -exec grep、xargs grep）也一律擋。兩者的下一步都是「要讀單一檔案就用 Read」。
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
             "Grep 工具與 Bash 的遞迴搜尋一律擋（#412 調整需求第 4 點）")
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

DENY = []  # (位置, 原因, 下一步)
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
            if step not in steps:
                steps.append(step)
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
    elif program in GREPS:
        analyze_grep(program, args)
    elif program == "rg":
        block("rg", "rg 會讀搜尋範圍裡每個檔的內容；它的設定檔、跟不跟隨 symlink 都會改變實際的搜尋範圍，只看指令判斷不了"
              "會不會讀到 token 檔", STEP_READ)
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
    analyze_runner(None, words[1:], None)


def analyze_runner(runner, args, state):
    """把後面的字當成指令執行的程式（xargs、sudo、find -exec…）：裡面有清單上的入口就先問，有 grep、rg 就擋。"""
    for i, word in enumerate(args):
        if not word.static:
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
                      "hook 判斷不了會不會讀到 token 檔", STEP_READ)
            else:
                analyze_grep(name, args[i + 1:])
        elif name == "git" and runner in ("sudo", "doas"):
            analyze_git(args[i + 1:], state if state is not None else State(None), [])


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
                  "symlink 也會改變實際的搜尋範圍，只看指令判斷不了會不會讀到 token 檔", STEP_READ)
            return
        i += 1


def analyze_find(args, state):
    for i, word in enumerate(args):
        if word.static and word.text in ("-exec", "-execdir", "-ok", "-okdir"):
            analyze_runner("find", args[i + 1:], state)
            return


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
          "文件沒寫、deny 規則對 Grep 只是 best-effort", STEP_READ)


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
