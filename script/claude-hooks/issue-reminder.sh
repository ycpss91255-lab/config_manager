#!/usr/bin/env bash
#
# Claude Code 的 PostToolUse 與 PostToolUseFailure hook（matcher Bash）：用 script/issue_draft.sh 開了 issue 或改了本文之後，提醒
# 「在 issue 留言附最後一輪的判定與適合公開的意見摘要」（#413 調整需求第 8 點）。只提醒、不擋。
#
# 由 .claude/settings.json 掛上，在主機上跑。**只讀工具呼叫的輸入**（Q1）：標準輸入那份 JSON 裡的事件、指令文字與 tool_response；
# 不跑專案程式，也不連網，所以不知道開出的是哪一張 issue、也不讀審稿紀錄。
#
# 依 hooks 文件，結束碼 0 時寫到 stderr 的內容 Claude 看不到，所以提醒寫成 stdout 上的一份 JSON：
# {"hookSpecificOutput": {"hookEventName": <收到的事件>, "additionalContext": <提醒>}}。
#
# 觸發照 script/claude-hooks/pr-ready-reminder.sh 的規則：
#   提醒     指令只有一段，是 script/issue_draft.sh create|edit，而且這次呼叫成功（PostToolUse，tool_response 是物件、沒有被中斷）
#   條件式   用 &&、; 串起來的多段指令裡有它：分不出是哪一段成功，給「如果剛才開成或改成了，……」，呼叫失敗也一樣
#   不提醒   submit、verdict；只有一段而且失敗的呼叫（PostToolUseFailure，或 tool_response 是錯誤文字的字串，或被中斷）
#
# 讀不懂 hook 的輸入、PATH 上沒有 python3 時以 2 結束：PostToolUse 的 2 不擋任何東西（工具已經跑完），只讓 Claude 看得到 stderr
# 寫的「判斷不了」與下一步。
#
# 這支刻意只用 bash 3.2 也有的寫法：hook 由使用者的環境啟動，PATH 上的 bash 不一定是 brew 的那一個（macOS 內建的是 3.2）。
# 判定都在 python 裡；讀指令的那一段在 shell-parse.sh，和其他 hook 共用。
set -u

here="${BASH_SOURCE[0]%/*}"
[ "${here}" = "${BASH_SOURCE[0]}" ] && here=.

if ! command -v python3 >/dev/null 2>&1; then
  IFS= read -r -d '' raw || true
  case "${raw}" in
    *issue_draft.sh*)
      printf 'issue-reminder: python3 不在 PATH 上，判斷不了剛才的指令有沒有開 issue 或改本文（#413）。\n' >&2
      printf 'issue-reminder: 下一步：在這台機器裝 python3；如果剛才開成或改成了，記得在 issue 留言附最後一輪的判定與意見摘要\n' >&2
      exit 2
      ;;
  esac
  exit 0
fi

if [ ! -r "${here}/shell-parse.sh" ]; then
  printf 'issue-reminder: 讀不到共用的指令解析 %s，判斷不了剛才的指令有沒有開 issue 或改本文（#413）。\n' "${here}/shell-parse.sh" >&2
  printf 'issue-reminder: 下一步：確認 script/claude-hooks/shell-parse.sh 在這個簽出裡；如果剛才開成或改成了，記得留言附判定\n' >&2
  exit 2
fi
# shellcheck source=script/claude-hooks/shell-parse.sh
. "${here}/shell-parse.sh"

IFS= read -r -d '' program <<'PY' || true
TAG = "issue-reminder"
EVENTS = ("PostToolUse", "PostToolUseFailure")
SCRIPT = "issue_draft.sh"
ACTIONS = ("create", "edit")

# 指令文字裡沒有 issue_draft.sh，就不必解析。
MENTIONS = re.compile(r"issue_draft\.sh")

STEP_INPUT = ("這支由 Claude Code 的 PostToolUse／PostToolUseFailure hook 呼叫；手動執行時，把 hook 會收到的 JSON"
              "（hook_event_name、tool_input.command、tool_response）餵進標準輸入；如果剛才開成或改成了，記得留言附判定")

# shell-parse.sh 的分析程序用的三個說法
COMMANDS = "script/issue_draft.sh"
UNPARSABLE = "分不出裡面有沒有 script/issue_draft.sh create|edit"
STEP_SPLIT = "script/issue_draft.sh 單獨一條執行"

FOUND = []   # 找到的 create／edit
UNSURE = []  # 看不清楚、可能是 create／edit 的地方


def block(where, why, step):
    UNSURE.append((where, why))


def stop(where, why, step):
    print(f"{TAG}: {where}：{why}，判斷不了剛才的指令有沒有開 issue 或改本文（#413）。", file=sys.stderr)
    print(f"{TAG}: 下一步：{step}", file=sys.stderr)
    sys.exit(2)


def is_script(word):
    return word.static and os.path.basename(word.text) == SCRIPT


def note(args):
    if not args:
        return
    if not args[0].static:
        UNSURE.append((SCRIPT, "動作來自 shell 展開"))
        FOUND.append(None)
    elif args[0].text in ACTIONS:
        FOUND.append(args[0].text)


def dispatch(program, args, state, assignments, words):
    if program == SCRIPT:
        note(args)
    else:
        indirect(words)


def indirect(words):
    for i, word in enumerate(words):
        if is_script(word):
            UNSURE.append((SCRIPT, "交給別的程式執行，參數在執行時才決定"))
            FOUND.append(None)
            return


def reminder(conditional):
    if conditional:
        first = (f"{TAG}（#413）：如果剛才的指令用 script/issue_draft.sh 開了 issue 或改了本文（這條指令有好幾段，hook 分不出是哪一段"
                 "成功或失敗），請注意：")
    else:
        first = f"{TAG}（#413）：剛才用 script/issue_draft.sh 開了 issue 或改了本文。"
    return "\n".join([
        first,
        "- 在那張 issue 留言附最後一輪的判定，與適合公開的意見摘要；不貼本機路徑（AGENTS.md「開 issue 與發留言的條件」）。",
        "- 協調工作階段向維護者簡單說明審了哪些項目。",
        "- 這是固定提醒：hook 只看指令、沒有讀審稿紀錄，也不知道開出的是哪一張。",
    ])


def emit(event, text):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}, ensure_ascii=False))
    sys.exit(0)


def main():
    data = load_input(STEP_INPUT)
    command, cwd = input_command(data, STEP_INPUT)
    if not MENTIONS.search(command):
        sys.exit(0)
    event = data.get("hook_event_name")
    if event not in EVENTS:
        event = "PostToolUse"
    response = data.get("tool_response")
    succeeded = event == "PostToolUse" and isinstance(response, dict) and not response.get("interrupted")

    items = lex(command)
    if items is None:
        emit(event, reminder(True))
    run_items(items, State(cwd))
    if not FOUND and not UNSURE:
        sys.exit(0)
    direct = False
    if len(items) == 1 and not isinstance(items[0], str) and not UNSURE and len(FOUND) == 1:
        command_item = items[0]
        _, words = command_words(command_item)
        nested = any(w.nested for w in command_item.words)
        direct = bool(words) and not nested and is_script(words[0])
    if direct:
        if succeeded:
            emit(event, reminder(False))
        sys.exit(0)
    emit(event, reminder(True))


try:
    main()
except SystemExit:
    raise
except Exception as error:  # 沒預料到的錯誤：讓 Claude 看得到判斷不了
    print(f"{TAG}: 判斷時發生沒預料到的錯誤（{type(error).__name__}），判斷不了剛才的指令有沒有開 issue 或改本文（#413）。",
          file=sys.stderr)
    print(f"{TAG}: 下一步：如果剛才開成或改成了，記得在 issue 留言附判定與意見摘要；這個錯誤請回報到 #413", file=sys.stderr)
    sys.exit(2)
PY

python3 -c "$(shell_parse_program)
${program}"
code=$?
if [ "${code}" -eq 0 ] || [ "${code}" -eq 2 ]; then
  exit "${code}"
fi
printf 'issue-reminder: 判斷中途失敗（python3 結束碼 %s），判斷不了剛才的指令有沒有開 issue 或改本文（#413）。\n' "${code}" >&2
printf 'issue-reminder: 下一步：照上面 python3 印的原因修正；如果剛才開成或改成了，記得在 issue 留言附判定與意見摘要\n' >&2
exit 2
