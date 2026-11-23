#!/usr/bin/env bash
#
# Claude Code 的 PreToolUse hook（matcher Bash）：擋下在主機直接跑專案的檢查工具、推到 main、目的地不明確的推送與不帶
# lease 的 force push（#409 調整需求第 1、2 點）。真正擋的是 CI（檢查在容器裡跑）與 main 的 ruleset，這支只在本機提早擋、
# 給清楚的下一步。
#
# 由 .claude/settings.json 掛上，在主機上跑。**只讀工具呼叫的輸入裡的指令文字**（#409 的 Q1）：不讀 git 設定、不呼叫 git、
# 不讀指令帶入的檔，也不連網；所以在主 checkout、worktree、設了 push.followTags 的 repo 裡判斷結果都一樣。
#
#   第 1 點  主機檢查：指令依 &&、||、;、| 分段（略過開頭的變數設定與 env、command、nohup 這類包裝），任一段以
#            pytest、ruff、mypy、pylint、bats、shellcheck、hadolint、actionlint，或 python／python3 -m pytest|ruff|mypy|pylint
#            開頭就擋。./script/test.sh（含 CM_TEST_LOCAL=1 ./script/test.sh）不是這幾個工具，不擋；CM_TEST_LOCAL=1 放在
#            pytest 這類工具前面不算例外（那是 ./script/test.sh 的主機模式，工具自己不讀它），下一步指向
#            CM_TEST_LOCAL=1 ./script/test.sh。
#   第 2 點  推送：驗的是指令明列的 ref，每一個都要確定。
#            - 目的地只認寫死的完整 ref：refs/heads/<名稱> 或 refs/tags/<名稱>；remote、refspec 與旗標的值都要是字面。
#            - 沒寫 refspec、refspec 沒寫 :<目的地>、matching 的 : 與 +:、含 * 的 refspec 都擋。
#            - 旗標只認 PUSH_BOOLS、PUSH_VALUES 這份清單；--recurse-submodules 只認 check、no。
#            - 目的地是 refs/heads/main（含 :refs/heads/main、刪除模式的 refs/heads/main）就擋。
#            - 刪除模式（-d／--delete）：remote 之後的每個參數都直接當成要刪的目的地 ref 核對。
#            - --force、-f、+ 開頭的 refspec、--no-force-with-lease 擋；只放行 --force-with-lease（不帶參數，保護全部
#              要更新的 ref）與 --force-with-lease=<ref>[:<expect>]。後者沒點名的目的地沒有 lease，也沒有被強制：沒點名的
#              既有分支仍受一般的 fast-forward 限制；刪除照刪除模式的規則，tag 照 git 對 tag 的推送規則（遠端已有同名
#              tag 時，沒有強制就拒絕）。
#            - git -C <目錄> push 照同樣的規則；git -c、--config-env 與 GIT_CONFIG 開頭的變數設定會在這次推送改 git 設定，
#              hook 不讀設定、判斷不了實際推什麼，所以擋。
#
# **看不到、判斷不了的時候擋下並寫出下一步，不默默放寬保護**（Q8）。擋不住的（間接呼叫、別名、分支歸屬、git 設定造成的
# 額外推送）寫在 doc/TEST-PLAN.md T19。
#
# 結束碼：0 放行；2 擋下（Claude Code 把 fd 2 的訊息交給工作階段）。其他結束碼 Claude Code 會放行，所以 python 中途失敗也一律
# 轉成 2，.claude/settings.json 那一行也以 `|| exit 2` 接住這支不在的情況。
#
# 這支刻意只用 bash 3.2 也有的寫法：hook 由使用者的環境啟動，PATH 上的 bash 不一定是 brew 的那一個（macOS 內建的是 3.2）。
# 判定都在 python 裡；讀指令的那一段（含 git 的全域選項）在 shell-parse.sh，和署名 hook、PR 規則 hook 共用。
set -u

here="${BASH_SOURCE[0]%/*}"
[ "${here}" = "${BASH_SOURCE[0]}" ] && here=.

if ! command -v python3 >/dev/null 2>&1; then
  printf 'host-push-rules: python3 不在 PATH 上，這條指令會不會在主機跑檢查工具、推到哪裡判斷不了，先擋下（#409）。\n' >&2
  printf 'host-push-rules: 下一步：在這台機器裝 python3，或讓 Claude Code 的 PATH 找得到它，再重送\n' >&2
  exit 2
fi

if [ ! -r "${here}/shell-parse.sh" ]; then
  printf 'host-push-rules: 讀不到共用的指令解析 %s，這條指令判斷不了，先擋下（#409）。\n' "${here}/shell-parse.sh" >&2
  printf 'host-push-rules: 下一步：確認 script/claude-hooks/shell-parse.sh 在這個簽出裡，再重送\n' >&2
  exit 2
fi
# shellcheck source=script/claude-hooks/shell-parse.sh
. "${here}/shell-parse.sh"

IFS= read -r -d '' program <<'PY' || true
TAG = "host-push-rules"

TOOLS = ("pytest", "ruff", "mypy", "pylint", "bats", "shellcheck", "hadolint", "actionlint")
PY_MODULES = ("pytest", "ruff", "mypy", "pylint")
PYTHON = re.compile(r"^python(?:3(?:\.[0-9]+)?)?$")

# 指令文字裡沒有這些字，就不必解析（也不會因為讀不懂而擋下無關的指令）。
MENTIONS = re.compile(r"(?<![A-Za-z0-9_-])(?:git|python[0-9.]*|" + "|".join(TOOLS) + r")(?![A-Za-z0-9_-])")

STEP_HOST = "改用 ./script/test.sh（在檢查映像裡跑，執行前照 docker 先問），或看 GitHub CI"
STEP_LOCAL = "要在主機跑就寫 CM_TEST_LOCAL=1 ./script/test.sh：它先盤點主機缺的工具；有跳過的執行不算通過"
STEP_REFSPEC = "每個 refspec 都寫成 <來源>:refs/heads/<名稱>，例如 git push -u origin feat/x:refs/heads/feat/x"
STEP_FLAGS = ("只用這些旗標：-u／--set-upstream、--force-with-lease（含 =<ref>[:<expect>]）、--force-if-includes、-n／--dry-run、"
              "-v／--verbose、-q／--quiet、--porcelain、--progress、--no-progress、--atomic、-o／--push-option、-d／--delete、"
              "--recurse-submodules=check、--recurse-submodules=no、--no-recurse-submodules")
STEP_MAIN = "不能推到 main：推到自己的分支、開草稿 PR，由 CI 的 merge job 合併"
STEP_LEASE = "改用 --force-with-lease（不帶參數，或 --force-with-lease=<ref>[:<expect>]），而且只推自己的分支"
STEP_DELETE = "刪除模式的每個參數都寫成完整的 ref，例如 git push --delete origin refs/heads/feat/x"
STEP_LITERAL = "remote、refspec 與旗標的值都寫成字面"
STEP_CONFIG = "拿掉 git 後面的 -c／--config-env 與 GIT_CONFIG 開頭的變數設定；推送的範圍只用指令上的旗標與 refspec 寫明"
STEP_SPLIT = "把指令拆開，git push 與檢查工具各自單獨一條送出，參數寫成字面"
STEP_INPUT = "這支由 Claude Code 的 PreToolUse hook 呼叫；手動執行時，把 hook 會收到的 JSON（tool_input.command）餵進標準輸入"

# shell-parse.sh 的分析程序用的三個說法
COMMANDS = "git push／檢查工具"
UNPARSABLE = "判斷不了它會不會在主機跑檢查工具、推到哪裡"

BLOCKS = []  # (位置, 原因, 下一步)


def block(where, why, step):
    item = (where, why, step)
    if item not in BLOCKS:
        BLOCKS.append(item)


def finish():
    if not BLOCKS:
        sys.exit(0)
    err = sys.stderr
    print(f"{TAG}: 擋下這次的工具呼叫（#409）：檢查工具一律在容器裡跑、不推到 main、git push 寫明完整的目的地 ref、"
          "force push 只用 --force-with-lease，或是有 hook 判斷不了的地方。", file=err)
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


# ── 依指令分派（shell-parse.sh 的 analyze 呼叫） ─────────────────────────

def dispatch(program, args, state, assignments, words):
    if program == "git":
        analyze_git(args, assignments)
    elif program in TOOLS:
        host_check(program, assignments)
    elif PYTHON.match(program):
        analyze_python(program, args, assignments)
    else:
        indirect(words)


def indirect(words):
    """git push 被交給別的程式執行（xargs、find -exec…）：參數在執行時才決定。檢查工具只看每一段開頭（第 1 點），不看參數。"""
    for i, word in enumerate(words):
        if not word.static or os.path.basename(word.text) != "git":
            continue
        if git_parts(words[i + 1:])[1] == "push":
            runner = os.path.basename(words[0].text) if words[0].static else "這條指令"
            block(f"{runner} 執行的 git push",
                  "git push 交給別的程式執行（例如 xargs、find -exec），refspec 在執行時才決定，hook 判斷不了推到哪裡",
                  "直接執行 git push，refspec 寫成字面")
            return


# ── 第 1 點：主機檢查 ─────────────────────────────────────────────────────

def host_check(name, assignments):
    why = "專案的檢查一律在容器裡跑，主機的結果不是證據（AGENTS.md「品質閘門」）"
    block(name, why, STEP_HOST)
    if "CM_TEST_LOCAL" in assignments:
        block(f"{name} 前面的 CM_TEST_LOCAL=", "CM_TEST_LOCAL 是 ./script/test.sh 的主機模式，檢查工具自己不讀它", STEP_LOCAL)


def python_module(args):
    """python 以 -m 執行的模組名稱；執行腳本、-c、從標準輸入讀、--version 這類是 ""；-m 之前的參數來自 shell 展開時是 None。"""
    i = 0
    while i < len(args):
        word = args[i]
        if not word.static:
            return None
        text = word.text
        if text == "--check-hash-based-pycs":
            i += 2
            continue
        if text.startswith("--") or not text.startswith("-") or text == "-":
            return ""
        j = 1
        while j < len(text):
            option = text[j]
            if option == "m":
                if j + 1 < len(text):
                    return text[j + 1:]
                if i + 1 < len(args):
                    return args[i + 1].text if args[i + 1].static else None
                return ""
            if option == "c":
                return ""
            if option in "WX":  # 要值：連寫在後面，或是下一個字
                if j + 1 == len(text):
                    i += 1
                break
            j += 1
        i += 1
    return ""


def analyze_python(program, args, assignments):
    module = python_module(args)
    if module in PY_MODULES:
        host_check(f"{program} -m {module}", assignments)
    elif module is None and any(a.static and (a.text in PY_MODULES or a.text[2:] in PY_MODULES) for a in args):
        block(program, "-m 之前的參數來自 shell 展開，判斷不了是不是以 -m 執行檢查工具", STEP_HOST)


# ── 第 2 點：git push ────────────────────────────────────────────────────

PUSH_BOOLS = {"-u", "--set-upstream", "--force-with-lease", "--force-if-includes", "-n", "--dry-run", "-v", "--verbose",
              "-q", "--quiet", "--porcelain", "--progress", "--no-progress", "--atomic", "-d", "--delete",
              "--no-recurse-submodules"}
PUSH_VALUES = {"-o", "--push-option", "--recurse-submodules"}
RECURSE_OK = ("check", "no")
FORCE_FLAGS = {
    "-f": "強制推送，不管遠端有沒有你沒看過的東西",
    "--force": "強制推送，不管遠端有沒有你沒看過的東西（也會關掉同一條指令裡 --force-with-lease 的檢查）",
    "--no-force-with-lease": "會取消前面所有的 --force-with-lease",
}
OTHER_REFS = "指令上沒列出的 ref 也會推，hook 判斷不了推到哪裡（可能推到 main）"
PUSH_UNKNOWN = {
    "--all": f"會推送所有本機分支：{OTHER_REFS}",
    "--branches": f"會推送所有本機分支（--all 的別名）：{OTHER_REFS}",
    "--mirror": f"會讓遠端的 ref 和本機一模一樣，包括刪掉遠端的分支：{OTHER_REFS}",
    "--tags": f"會推送所有本機 tag：{OTHER_REFS}",
    "--follow-tags": f"會另外推送指向這次推送內容的 annotated tag：{OTHER_REFS}",
    "--prune": "會刪掉遠端上本機沒有對應的分支：指令上沒列出的 ref 也會動到",
    "--no-verify": "會跳過本機的 pre-push 檢查（git hook，#406）",
}


def full_ref(text):
    """寫死的完整 ref：(heads 或 tags, 名稱)；不是就是 None。名稱照 git check-ref-format 的規則粗略核對。"""
    match = re.match(r"^refs/(heads|tags)/(.+)$", text)
    if not match:
        return None
    name = match.group(2)
    parts = name.split("/")
    if any(not part or part.startswith(".") or part.endswith(".lock") for part in parts):
        return None
    if ".." in name or "@{" in name or name.endswith(".") or name == "@":
        return None
    if any(c in " ~^:?*[\\" or ord(c) < 32 or ord(c) == 127 for c in name):
        return None
    return match.group(1), name


def is_main(ref):
    return ref == ("heads", "main")


def analyze_git(args, assignments):
    options, subcommand, rest = git_parts(args)
    if subcommand is None:
        if any(a.static and a.text == "push" for a in rest):
            block("git", "git 的選項或子指令來自 shell 展開，hook 判斷不了是不是推送、推到哪裡", STEP_LITERAL)
        return
    if subcommand != "push":
        return
    for name, _ in options:
        if name in ("-c", "--config-env"):
            block(f"git {name}", "會在這次推送改 git 的設定（例如 push.followTags、remote.<name>.mirror、remote.<name>.push），"
                  "hook 不讀設定，判斷不了實際推什麼", STEP_CONFIG)
    for name in assignments:
        if name.startswith("GIT_CONFIG"):
            block(f"git push 前面的 {name}=", "這個環境變數會改 git 的設定（同 git -c），hook 不讀設定，判斷不了實際推什麼",
                  STEP_CONFIG)
    analyze_push(rest)


def analyze_push(args):
    parsed = parse_options(args, PUSH_VALUES, PUSH_BOOLS)
    names = parsed.names()
    for name in parsed.unknown:
        if name in FORCE_FLAGS:
            block(f"git push 的 {name}", FORCE_FLAGS[name], STEP_LEASE)
        else:
            block(f"git push 的 {name}", PUSH_UNKNOWN.get(name, "不在 hook 認得的旗標清單裡（縮寫的長旗標也不認）"), STEP_FLAGS)
    if parsed.opaque:
        block("git push 的參數", "有參數整個來自 shell 展開（例如 \"$REMOTE\"），分不出是旗標、remote 還是 refspec", STEP_LITERAL)
    for name in parsed.missing:
        block(f"git push 的 {name}", "少了值", "補上值")
    for name, value in parsed.options:
        if value is None:
            continue
        if not value.static:
            block(f"git push 的 {name}", f"值來自 shell 的{value.dynamic}，展開後可能多出旗標或 refspec", STEP_LITERAL)
        elif name == "--recurse-submodules":
            if value.text not in RECURSE_OK:
                block(f"git push 的 --recurse-submodules={value.text}", "會另外推子模組，或不是 git 認得的值", STEP_FLAGS)
        elif name in PUSH_BOOLS and name != "--force-with-lease":
            block(f"git push 的 {name}={value.text}", "這個旗標不帶值", STEP_FLAGS)
    if parsed.opaque:
        return  # 已經擋下；哪個是 remote、哪些是 refspec 分不出來，不再逐個核對
    if not parsed.positionals:
        block("git push", "沒寫 remote 與 refspec：推到哪裡由 git 設定（push.default、upstream、remote.<name>.push）決定，"
              "hook 不讀設定", STEP_REFSPEC)
        return
    remote, refs = parsed.positionals[0], parsed.positionals[1:]
    if not remote.static:
        block("git push 的 remote", f"來自 shell 的{remote.dynamic}，展開後可能多出旗標或 refspec", STEP_LITERAL)
    if "-d" in names or "--delete" in names:
        analyze_delete(refs)
        return
    if not refs:
        shown_remote = f"（第一個位置參數 {remote.text} 是 remote）" if remote.static else ""
        block("git push", f"沒寫 refspec{shown_remote}：推到哪裡由 git 設定（push.default、upstream、remote.<name>.push）決定，"
              "hook 不讀設定", STEP_REFSPEC)
    for word in refs:
        analyze_refspec(word)


def analyze_refspec(word):
    if not word.static:
        block(f"git push 的 refspec {word.prefix}…", f"含 shell 的{word.dynamic}，展開之後的冒號與空白會改變目的地，"
              "hook 判斷不了推到哪裡", STEP_REFSPEC)
        return
    text = word.text
    where = f"git push 的 refspec {text}"
    if text.startswith("+"):
        block(where, "+ 開頭的 refspec 是強制推送", STEP_LEASE)
        text = text[1:]
    if text == ":":
        block(where, "matching 的 refspec 會推送所有兩邊同名的分支，指令上沒列出目的地", STEP_REFSPEC)
        return
    if "*" in text:
        block(where, "含萬用字元 *，目的地由兩邊有哪些 ref 決定", STEP_REFSPEC)
        return
    if ":" not in text:
        block(where, "沒寫 :<目的地>：目的地由 git 設定（remote.<name>.push）或來源的種類決定，hook 不讀設定", STEP_REFSPEC)
        return
    destination = text.rsplit(":", 1)[1]  # git 以最後一個冒號分開來源與目的地
    ref = full_ref(destination)
    if ref is None:
        block(where, f"目的地 {destination or '（空的）'} 不是寫死的完整 ref（refs/heads/<名稱> 或 refs/tags/<名稱>），"
              "git 會依來源的種類與遠端的狀況推斷它落在哪裡", STEP_REFSPEC)
    elif is_main(ref):
        block(where, "目的地是 refs/heads/main" + ("（刪除 main）" if text.startswith(":") else ""), STEP_MAIN)


def analyze_delete(refs):
    if not refs:
        block("git push --delete", "沒寫要刪的 ref", STEP_DELETE)
    for word in refs:
        if not word.static:
            block(f"git push --delete 的 {word.prefix}…", f"含 shell 的{word.dynamic}，判斷不了要刪哪一個 ref", STEP_DELETE)
            continue
        ref = full_ref(word.text)
        where = f"git push --delete 的 {word.text}"
        if ref is None:
            block(where, "刪除模式要寫死的完整 ref（refs/heads/<名稱> 或 refs/tags/<名稱>），短名、冒號、+ 都不認", STEP_DELETE)
        elif is_main(ref):
            block(where, "要刪的是 refs/heads/main", STEP_MAIN)


# ── 進入點 ────────────────────────────────────────────────────────────────

def main():
    command, cwd = input_command(load_input(STEP_INPUT), STEP_INPUT)
    if not MENTIONS.search(command):
        sys.exit(0)
    run_script(command, State(cwd))
    finish()


try:
    main()
except SystemExit:
    raise
except Unparsable as error:
    stop("這條指令", f"讀不懂它的結構（{error}），{UNPARSABLE}", STEP_SPLIT)
except Exception as error:  # 任何沒預料到的錯誤都擋下，不讓 Claude Code 當成放行
    print(f"{TAG}: 判斷時發生沒預料到的錯誤（{type(error).__name__}），這次的工具呼叫先擋下（#409）。", file=sys.stderr)
    print(f"{TAG}: 下一步：{STEP_SPLIT}；這個錯誤請回報到 #409", file=sys.stderr)
    sys.exit(2)
PY

python3 -c "$(shell_parse_program)
${program}"
code=$?
if [ "${code}" -eq 0 ] || [ "${code}" -eq 2 ]; then
  exit "${code}"
fi
printf 'host-push-rules: 判斷中途失敗（python3 結束碼 %s），這次的工具呼叫先擋下（#409）。\n' "${code}" >&2
printf 'host-push-rules: 下一步：照上面 python3 印的原因修正；修不了就把指令拆開，git push 與檢查工具各自單獨一條送出、參數寫成字面\n' >&2
exit 2
