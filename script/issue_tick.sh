#!/usr/bin/env bash
#
# 勾 issue 的帳本：只把一條未勾的驗收條件勾起來，行尾加「 — <commit 主旨>」（#413 調整需求第 6 點）。勾帳本不算本文修改、不送審
# （協調工作階段 2026-11-25 定的例行做法），所以 Claude Code 的 hook（script/claude-hooks/issue-rules.sh）擋直接改本文的寫法、
# 不擋這支；這支自己核對只改了那一行。
#
#   script/issue_tick.sh <編號> <條件片段> <commit 主旨>
#
#   - 讀本文（gh issue view）；有 CRLF 就先換成 LF（#420 修好之前的繞法）
#   - 未勾的行用和 script/lint_checkpoints.sh 相同的判斷（^[[:space:]]*[-*+] \[ \]）；含 <條件片段> 的要正好一行
#   - 主旨要是一行，而且和 git log --format=%s HEAD 或 git log --format=%s origin/main 的某一筆逐字相同（在目前目錄的 git repo 裡查）
#   - 改後的本文和原本（換成 LF 之後）只差那一行；用 script/attribution-patterns.txt 檢查
#   - 送出前再讀一次本文，和第一次讀到的不同就停（中間有人改過）
#   - gh issue edit <編號> --repo github.com/ycpss91255-lab/config_manager --body-file <改後的本文>，不帶其他旗標
#
# 會呼叫的外部程式：python3、gh、git。規格用假的 gh。
#
# 這支刻意只用 bash 3.2 也有的寫法：它由工作階段在主機上執行，PATH 上的 bash 不一定是 brew 的那一個（macOS 內建的是 3.2）。
set -u

here="${BASH_SOURCE[0]%/*}"
[ "${here}" = "${BASH_SOURCE[0]}" ] && here=.
top="$(cd "${here}/.." && pwd -P)"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'issue_tick: python3 不在 PATH 上，%s 核對不了要勾的那一行（#413）。\n' "${top}/script/issue_tick.sh" >&2
  printf 'issue_tick: 下一步：在這台機器裝 python3，或讓 PATH 找得到它，再重新執行\n' >&2
  exit 2
fi

IFS= read -r -d '' program <<'PY' || true
import json
import os
import re
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TAG = "issue_tick"
TOP = sys.argv[1]
ARGS = sys.argv[2:]
PATTERNS = os.path.join(TOP, "script", "attribution-patterns.txt")
REPO = "github.com/ycpss91255-lab/config_manager"
UNCHECKED = re.compile(r"^[ \t\n\v\f\r]*[-*+] \[ \]")
USAGE = "用法：script/issue_tick.sh <編號> <條件片段> <commit 主旨>"


class Stop(Exception):
    def __init__(self, why, step):
        super().__init__(why)
        self.why = why
        self.step = step


def gh_env():
    env = dict(os.environ)
    for key in ("GH_REPO", "GH_HOST"):
        env.pop(key, None)
    return env


def gh(args, what):
    try:
        result = subprocess.run(["gh", *args], capture_output=True, env=gh_env(), check=False)
    except OSError as error:
        raise Stop(f"執行不了 gh（{error.strerror}），{what}做不了", "安裝 gh 並登入（gh auth login）")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip().splitlines()
        raise Stop(f"gh {args[0]} {args[1]} 以 {result.returncode} 結束，{what}沒有完成（{detail[-1] if detail else '沒有訊息'}）",
                   "照 gh 的訊息處理後重新執行")
    return result.stdout.decode("utf-8", errors="replace")


def read_body(number):
    out = gh(["issue", "view", number, "--repo", REPO, "--json", "body"], f"讀 #{number} 的本文")
    try:
        body = json.loads(out)["body"]
    except (ValueError, KeyError, TypeError):
        raise Stop(f"gh issue view {number} 的輸出讀不出本文", "確認 gh 的版本支援 --json body")
    if not isinstance(body, str):
        raise Stop(f"gh issue view {number} 的本文不是字串", "確認 gh 的版本支援 --json body")
    return body


def known_subjects():
    subjects = set()
    found = False
    for ref in ("HEAD", "origin/main"):
        try:
            result = subprocess.run(["git", "log", "--format=%s", ref], capture_output=True, check=False)
        except OSError as error:
            raise Stop(f"執行不了 git（{error.strerror}），核對不了 commit 主旨", "安裝 git 再執行")
        if result.returncode == 0:
            found = True
            subjects.update(result.stdout.decode("utf-8", errors="replace").splitlines())
    if not found:
        raise Stop(f"{os.getcwd()} 不在 git repo 裡（git log HEAD 失敗），核對不了 commit 主旨",
                   "在有那個 commit 的簽出裡執行（例如 PR 的 worktree）")
    return subjects


def check_attribution(text):
    try:
        with open(PATTERNS, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        raise Stop(f"讀不到署名樣式清單 {PATTERNS}（{error.strerror}）", "確認 script/attribution-patterns.txt 在這個簽出裡")
    patterns = []
    for number, line in enumerate(lines, 1):
        if not line.strip() or line.startswith("#"):
            continue
        try:
            patterns.append(re.compile(line, re.IGNORECASE))
        except re.error as error:
            raise Stop(f"署名樣式清單 {PATTERNS} 第 {number} 行不是可用的正規式（{error}）", "修正那一行")
    if not patterns:
        raise Stop(f"署名樣式清單 {PATTERNS} 裡面沒有任何樣式", "照檔頭的說明補回樣式")
    for number, line in enumerate(text.split("\n"), 1):
        for pattern in patterns:
            if pattern.search(line):
                raise Stop(f"改後的本文第 {number} 行命中署名樣式 {pattern.pattern}",
                           "先把本文裡的署名清掉（script/scrub_attribution.sh，#410），再勾帳本")


def tick(number, fragment, subject):
    if not number.isdigit() or int(number) <= 0:
        raise Stop(f"編號 {number!r} 不是正整數", USAGE)
    if not fragment:
        raise Stop("條件片段是空的", "寫出那一條驗收條件裡的一段文字，只對到一行")
    if not subject.strip() or "\n" in subject or "\r" in subject:
        raise Stop("commit 主旨是空的或有換行", "寫一行 commit 主旨（和 git log 的某一筆逐字相同）")
    if subject not in known_subjects():
        raise Stop(f"commit 主旨「{subject}」不在 HEAD 或 origin/main 的 git 歷史裡",
                   "在有那個 commit 的簽出裡執行，或先 git fetch；主旨要和 git log 的某一筆逐字相同")
    original = read_body(number)
    lines = original.replace("\r\n", "\n").split("\n")
    hits = [i for i, line in enumerate(lines) if UNCHECKED.match(line) and fragment in line]
    if len(hits) != 1:
        raise Stop(f"#{number} 未勾的行裡含「{fragment}」的有 {len(hits)} 行，應該正好一行", "換一段只對到那一行的條件片段")
    index = hits[0]
    line = lines[index]
    box = line.index("[ ]")
    changed = list(lines)
    changed[index] = line[:box] + "[x]" + line[box + 3:] + " — " + subject
    differing = [i for i, (old, new) in enumerate(zip(lines, changed)) if old != new]
    if len(changed) != len(lines) or differing != [index]:
        raise Stop("改後的本文不只差那一行", "回報到 #413")
    updated = "\n".join(changed)
    check_attribution(updated)
    if read_body(number) != original:
        raise Stop(f"讀取之後 #{number} 的本文被改過", "重新執行，讓這支讀到最新的本文")
    handle, path = tempfile.mkstemp(prefix="issue-tick-", suffix=".md")
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="") as out:
            out.write(updated)
        gh(["issue", "edit", number, "--repo", REPO, "--body-file", path], f"勾 #{number} 的帳本")
    finally:
        os.remove(path)
    print(f"{TAG}: 勾好了（#413）：#{number} 第 {index + 1} 行")
    if "\r\n" in original:
        print(f"{TAG}: #{number} 的本文原本是 CRLF，這次一起換成了 LF（#420）")


def main():
    if len(ARGS) == 1 and ARGS[0] in ("-h", "--help"):
        print(USAGE)
        sys.exit(0)
    try:
        if len(ARGS) != 3:
            raise Stop("參數不對", USAGE)
        tick(*ARGS)
    except Stop as stopped:
        print(f"{TAG}: {stopped.why}（#413）。", file=sys.stderr)
        print(f"{TAG}: 下一步：{stopped.step}", file=sys.stderr)
        sys.exit(1)


main()
PY

python3 -c "${program}" "${top}" "$@"
