#!/usr/bin/env bash
#
# Claude Code 的 PostToolUse 與 PostToolUseFailure hook（matcher Bash）：PR 轉成可合併時，提醒 Claude「符合合併條件時，檢查全過
# 就會被 CI 的 merge job 合併」（#408 調整需求第 4 點）。只提醒、不擋：擋的是 CI（merge-gate、merge job 的重判）。
#
# 由 .claude/settings.json 掛上，在主機上跑。**只讀工具呼叫的輸入**（#408 的 Q1）：標準輸入那份 JSON 裡的事件、指令文字與
# tool_response；不跑專案程式，也不連網，所以不知道 PR 的描述、也不知道這個 PR 會不會真的被合併。
#
# 依 hooks 文件，結束碼 0 時寫到 stderr 的內容 Claude 看不到，所以提醒寫成 stdout 上的一份 JSON：
# {"hookSpecificOutput": {"hookEventName": <收到的事件>, "additionalContext": <提醒>}}。
#
#   觸發     指令只有一段，是沒帶 --undo 的 gh pr ready，而且這次呼叫成功（PostToolUse，tool_response 是物件、沒有被中斷）
#   條件式   用 &&、; 串起來的多段指令裡有 gh pr ready：分不出是哪一段成功，給「如果剛才的指令把 PR 轉成可合併了，……」，
#            呼叫失敗（PostToolUseFailure）也一樣
#   不提醒   gh pr ready --undo、gh pr create --draft、只有一段而且失敗的呼叫（PostToolUseFailure，或 tool_response 是錯誤
#            文字的字串，或被中斷）
#
# 讀不懂 hook 的輸入、PATH 上沒有 python3 時以 2 結束：PostToolUse 的 2 不擋任何東西（工具已經跑完），只讓 Claude 看得到 stderr
# 寫的「判斷不了」與下一步。
#
# 這支刻意只用 bash 3.2 也有的寫法：hook 由使用者的環境啟動，PATH 上的 bash 不一定是 brew 的那一個（macOS 內建的是 3.2）。
# 判定都在 python 裡；讀指令的那一段在 shell-parse.sh，和署名 hook、PR 規則 hook 共用。
set -u

here="${BASH_SOURCE[0]%/*}"
[ "${here}" = "${BASH_SOURCE[0]}" ] && here=.

if ! command -v python3 >/dev/null 2>&1; then
  # 沒有 python3 就讀不了 JSON：只用 bash 的內建指令粗看輸入裡有沒有 gh 與 ready，有才出聲
  IFS= read -r -d '' raw || true
  case "${raw}" in
    *gh*ready*)
      printf 'pr-ready-reminder: python3 不在 PATH 上，判斷不了剛才的指令有沒有把 PR 轉成可合併（#408）。\n' >&2
      printf 'pr-ready-reminder: 下一步：在這台機器裝 python3；如果剛才轉成可合併了，記得檢查全過就會被 CI 的 merge job 合併，還沒驗完就 gh pr ready <n> --undo\n' >&2
      exit 2
      ;;
  esac
  exit 0
fi

if [ ! -r "${here}/shell-parse.sh" ]; then
  printf 'pr-ready-reminder: 讀不到共用的指令解析 %s，判斷不了剛才的指令有沒有把 PR 轉成可合併（#408）。\n' "${here}/shell-parse.sh" >&2
  printf 'pr-ready-reminder: 下一步：確認 script/claude-hooks/shell-parse.sh 在這個簽出裡；如果剛才轉成可合併了，記得檢查全過就會被 CI 合併\n' >&2
  exit 2
fi
# shellcheck source=script/claude-hooks/shell-parse.sh
. "${here}/shell-parse.sh"

IFS= read -r -d '' program <<'PY' || true
TAG = "pr-ready-reminder"
EVENTS = ("PostToolUse", "PostToolUseFailure")

# 指令文字裡沒有 gh 與 ready 這兩個字，就不必解析。
MENTIONS = re.compile(r"(?<![A-Za-z0-9_-])gh(?![A-Za-z0-9_-])")
READY = re.compile(r"(?<![A-Za-z0-9_-])ready(?![A-Za-z0-9_-])")

STEP_INPUT = ("這支由 Claude Code 的 PostToolUse／PostToolUseFailure hook 呼叫；手動執行時，把 hook 會收到的 JSON"
              "（hook_event_name、tool_input.command、tool_response）餵進標準輸入；如果剛才轉成可合併了，記得檢查全過就會被 CI 合併")

# shell-parse.sh 的分析程序用的三個說法
COMMANDS = "gh pr ready"
UNPARSABLE = "分不出裡面有沒有 gh pr ready"
STEP_SPLIT = "gh pr ready 單獨一條執行"

FOUND = []   # 找到的 gh pr ready（沒帶 --undo）：PR 的寫法，沒寫就是 None
UNSURE = []  # 看不清楚、可能是 gh pr ready 的地方


def block(where, why, step):
    UNSURE.append((where, why))


def stop(where, why, step):
    print(f"{TAG}: {where}：{why}，判斷不了剛才的指令有沒有把 PR 轉成可合併（#408）。", file=sys.stderr)
    print(f"{TAG}: 下一步：{step}", file=sys.stderr)
    sys.exit(2)


# ── 依指令分派（shell-parse.sh 的 analyze 呼叫） ─────────────────────────

def ready_target(args):
    """沒帶 --undo 的 gh pr ready 指的 PR（寫法原樣，沒寫是 ""）；--undo、--help 是 None；看不清楚是 False。"""
    parsed = parse_options(args, {"-R", "--repo"}, {"--undo", "-h", "--help"})
    names = parsed.names()
    if "--undo" in names or "-h" in names or "--help" in names:
        return None
    if parsed.opaque or parsed.unknown:
        return False
    if not parsed.positionals:
        return ""
    word = parsed.positionals[0]
    return word.text if word.static else False


def note_ready(args):
    target = ready_target(args)
    if target is False:
        UNSURE.append(("gh pr ready", "參數來自 shell 展開或不在認得的旗標清單裡，分不出有沒有 --undo"))
        FOUND.append(None)
    elif target is not None:
        FOUND.append(target or None)


def dispatch(program, args, state, assignments, words):
    if program != "gh":
        indirect(words)
        return
    group, verb, rest = gh_parts(args)
    if group is None or (group == "pr" and verb is None):
        UNSURE.append(("gh", "群組或子指令來自 shell 展開"))
    elif group == "pr" and verb == "ready":
        note_ready(rest)


def indirect(words):
    texts = [w.text if w.static else None for w in words]
    for i, text in enumerate(texts):
        if text is not None and os.path.basename(text) == "gh":
            group, verb, _ = gh_parts(words[i + 1:])
            if group == "pr" and verb in ("ready", None):
                UNSURE.append(("gh", "gh pr ready 交給別的程式執行，參數在執行時才決定"))
                FOUND.append(None)
            return


# ── 提醒 ──────────────────────────────────────────────────────────────────

def reminder(target, conditional):
    if target and target.isdigit():
        pr, undo = f"PR #{target}", f"gh pr ready {target} --undo"
    elif target:
        pr, undo = f"PR {target}", f"gh pr ready {target} --undo"
    elif conditional:
        pr, undo = "那個 PR", "gh pr ready <n> --undo"
    else:
        pr, undo = "這個分支的 PR", "gh pr ready --undo"
    if conditional:
        first = f"{TAG}（#408）：如果剛才的指令把 PR 轉成可合併了（這條指令有好幾段，hook 分不出是哪一段成功或失敗），請注意："
    else:
        first = f"{TAG}（#408）：剛才的 gh pr ready 把 {pr} 轉成可合併了。"
    return "\n".join([
        first,
        f"- 符合合併規則的合併條件（同 repo 的分支、base 是 main、合併前重判通過）時，{pr} 檢查全過就會被 CI 的 merge job 以 "
        "merge commit 合併，Closes 的 issue 會被關掉；之後每一次推送都可能觸發合併。",
        "- ready_for_review 會觸發 CI（#407 把它加進觸發條件）；排隊與結果由 GitHub 決定。",
        f"- 還沒驗完，就用 {undo} 轉回草稿；這時 merge job 可能已經觸發，轉回草稿不一定趕得上。",
        "- 確認描述有 ## TDD red（或純文件的不適用理由）。這是固定提醒：hook 只看指令、沒有讀描述，不代表已經判斷過；"
        "擋的是 CI 的 merge-gate。",
        "- agent 不自己合併；merge job 失敗或卡住就查它的紀錄並回報（AGENTS.md「合併規則」）。",
    ])


def emit(event, text):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}, ensure_ascii=False))
    sys.exit(0)


# ── 進入點 ────────────────────────────────────────────────────────────────

def main():
    data = load_input(STEP_INPUT)
    command, cwd = input_command(data, STEP_INPUT)
    if not (MENTIONS.search(command) and READY.search(command)):
        sys.exit(0)
    event = data.get("hook_event_name")
    if event not in EVENTS:
        event = "PostToolUse"
    response = data.get("tool_response")
    succeeded = event == "PostToolUse" and isinstance(response, dict) and not response.get("interrupted")

    items = lex(command)
    if items is None:
        emit(event, reminder(None, True))
    run_items(items, State(cwd))
    if not FOUND and not UNSURE:
        sys.exit(0)
    direct = False
    if len(items) == 1 and not isinstance(items[0], str) and not UNSURE and len(FOUND) == 1:
        command_item = items[0]
        _, words = command_words(command_item)
        nested = any(w.nested for w in command_item.words)
        direct = bool(words) and words[0].static and os.path.basename(words[0].text) == "gh" and not nested
    if direct:
        if succeeded:
            emit(event, reminder(FOUND[0], False))
        sys.exit(0)
    targets = sorted({t for t in FOUND if t})
    emit(event, reminder(targets[0] if len(targets) == 1 else None, True))


try:
    main()
except SystemExit:
    raise
except Exception as error:  # 沒預料到的錯誤：讓 Claude 看得到判斷不了
    print(f"{TAG}: 判斷時發生沒預料到的錯誤（{type(error).__name__}），判斷不了剛才的指令有沒有把 PR 轉成可合併（#408）。",
          file=sys.stderr)
    print(f"{TAG}: 下一步：如果剛才轉成可合併了，記得檢查全過就會被 CI 的 merge job 合併；這個錯誤請回報到 #408", file=sys.stderr)
    sys.exit(2)
PY

python3 -c "$(shell_parse_program)
${program}"
code=$?
if [ "${code}" -eq 0 ] || [ "${code}" -eq 2 ]; then
  exit "${code}"
fi
printf 'pr-ready-reminder: 判斷中途失敗（python3 結束碼 %s），判斷不了剛才的指令有沒有把 PR 轉成可合併（#408）。\n' "${code}" >&2
printf 'pr-ready-reminder: 下一步：照上面 python3 印的原因修正；如果剛才轉成可合併了，記得檢查全過就會被 CI 的 merge job 合併\n' >&2
exit 2
