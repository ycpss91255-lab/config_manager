#!/usr/bin/env bash
#
# Claude Code 的 PreToolUse hook（matcher Bash）：工作階段與環境的規則（#412）。規則本文在
# AGENTS.md「工作階段的規則」；原本只靠文字，這支在本機擋下或先問，給清楚的下一步。
#
# 由 .claude/settings.json 掛上，在主機上跑。**只讀工具呼叫的輸入**（#412 的 Q1）：不呼叫 git、不跑專案程式與測試、不掃
# 檔案系統。讀的檔只有這支旁邊的入口清單 docker-entrypoints.txt。
#
#   第 1 點  docker 先問：指令依 &&、||、;、| 分段（略過開頭的變數設定與 env、command、nohup 這類包裝），任一段是
#            docker-entrypoints.txt 上的入口（docker、just docker、just test、會開 docker 的 repo 腳本，寫成 ./script/x.sh、
#            script/x.sh、bash script/x.sh 都算）就回傳 ask。
#   第 3 點  cm_verify：命中第 1 點的指令，文字裡同時出現 cm_verify（參數、-p 專案名、前面的變數設定都算）就擋（deny），
#            deny 優先於 ask。
#
# **看不到、判斷不了的時候擋下並寫出下一步，不默默放寬保護**（Q8）。擋不住的寫在 doc/TEST-PLAN.md T19。
#
# 結束碼：0 放行（要先問時把 ask 寫成 JSON 印到標準輸出）；2 擋下（Claude Code 把 fd 2 的訊息交給工作階段）。其他結束碼
# Claude Code 會放行，所以 python 中途失敗也一律轉成 2，.claude/settings.json 那一行也以 `|| exit 2` 接住這支不在的情況。
#
# 這支刻意只用 bash 3.2 也有的寫法：hook 由使用者的環境啟動，PATH 上的 bash 不一定是 brew 的那一個（macOS 內建的是 3.2）。
# 判定都在 python 裡；讀指令的那一段（含 cd 之後的目錄）在 shell-parse.sh，和其他 hook 共用。
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

STEP_DOCKER = "照 AGENTS.md「工作階段的規則」，docker 指令先問維護者；驗收證據以 GitHub CI 為準"
STEP_VERIFY = ("不碰 cm_verify_* 驗證環境（維護者人工驗收用的容器與 volume，doc/USER-VERIFICATION.md 的準備表）："
               "不啟動、不停止、不重建、不改；要操作請維護者自己執行")
STEP_SPLIT = "把指令拆開，每段的程式、參數與路徑寫成字面"
STEP_INPUT = ("這支由 Claude Code 的 PreToolUse hook 呼叫；手動執行時，把 hook 會收到的 JSON（tool_name、tool_input）"
              "餵進標準輸入")
STEP_ENTRIES = "確認 script/claude-hooks/docker-entrypoints.txt 在這個簽出裡、讀得到，再重送"

# shell-parse.sh 的分析程序用的兩個說法
COMMANDS = "docker 這類指令"
UNPARSABLE = "判斷不了它會不會開 docker"

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
        print(f"{TAG}: 擋下這次的工具呼叫（#412）：docker 先問、不碰 cm_verify_* 驗證環境，或是有 hook 判斷不了的地方。", file=err)
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
    """把後面的字當成指令執行的程式（xargs、sudo、find -exec…）：裡面有清單上的入口就先問。"""
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


# ── 進入點 ────────────────────────────────────────────────────────────────

def bash_rules(data):
    command, cwd = input_command(data, STEP_INPUT)
    if not MENTIONS.search(command):
        return
    load_entries()
    items = lex(command)
    if items is None:
        return
    run_items(items, State(cwd))
    if ASK and CM_VERIFY.search(command):
        block(f"{'、'.join(ASK)}（指令裡有 cm_verify）", "會碰到 cm_verify_* 驗證環境", STEP_VERIFY)


def main():
    data = load_input(STEP_INPUT)
    tool = data.get("tool_name")
    if tool == "Bash":
        bash_rules(data)
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
