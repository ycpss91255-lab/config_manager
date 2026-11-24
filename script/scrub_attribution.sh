#!/usr/bin/env bash
#
# 清掉既有 PR 與 issue 說明裡的 Claude 署名與 session 連結（#410，#269 第 3 步）。不動 git 歷史、不 force push。
#
# 樣式讀 script/attribution-patterns.txt（#405 的那一份；這支是它的第四個呼叫端，不另抄一份）。一份說明的改法：
#
#   - 以 ^ 開頭的樣式（共同作者行、Claude-Session: 行、Generated with [Claude Code] 行）：命中的那一整行刪掉；
#   - 其他樣式（完整的 session 網址）：只把命中的那一段換成「（session 連結已移除）」，那一行其他文字不動；
#   - 結尾有刪行時，刪完之後說明結尾的空行（只有空白或 tab 的行）一起刪掉；說明中間的空行不動；
#   - 其餘內容逐位元組不變：每一行保留它原本的換行字元（\r\n、\n、\r），沒命中的行一個字元都不改。
#
# 試跑（預設）：列舉全部 PR 與 issue（state=all，含已關閉的 issue、已合併與已關閉的 PR），一頁一頁讀到空的那一頁。
# issues 的列舉會把 PR 也一起回傳（帶 pull_request 欄位），那些一律排除：PR 只走 pulls 那條路徑，同一份說明不會被改兩次。
# 列出要改的編號、每一份刪哪幾行、換掉幾個網址，標出開著、不是草稿的 PR（改它們的描述會觸發 edited，重跑一輪 CI；
# 檢查全過就會被 merge job 合併）。不寫入 GitHub。要改的每一份把原文逐位元組存進備份目錄底下這一次試跑的子目錄，
# 當成 --apply 的比對基準；舊的試跑目錄不覆蓋。
#
# --apply：照最近一次試跑的清單，寫入前一刻再讀一次說明，和備份的原文比；相同才用 gh api -X PATCH 寫回清過的版本，
# 不同就略過那一份。結束時列出已改、略過、失敗三份清單。重跑：對略過與失敗的那幾份重新試跑（新的試跑用當下的內容
# 建立新的備份與比對基準），再 --apply。結案：最後一次試跑列出 0 個，而且兩份清單都成功翻完所有分頁。
#
# 輸出只有編號、行號與樣式，不印命中的內容（同 lint_attribution.sh）：不把完整的 session 網址再抄一次。
#
# 它擋不住的（另見 doc/TEST-PLAN.md T19）：
#   - 說明的編輯紀錄：GitHub 保留舊版本，仍看得到；
#   - 留言裡的署名（#269 第 3 步只寫說明）、commit 訊息（第 4 步，不做）；
#   - --apply 比對與寫入之間的空檔裡別人的修改：沒有條件式寫入，那段時間裡的修改會被蓋掉；
#   - 列舉途中有 issue 被刪掉時，後面的項目往前移一格，可能漏看一份：結案那次試跑會再翻一次。
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_ROOT

usage() {
  cat <<'USAGE'
用法：script/scrub_attribution.sh --repo <owner/name> [--backup-dir <目錄>]
      script/scrub_attribution.sh --repo <owner/name> --apply [--backup-dir <目錄>] [--interval <秒>]

  （預設）       試跑：列舉全部 PR 與 issue 的所有分頁，列出要改的編號、每一份刪哪幾行、換掉幾個網址，
                 標出開著、不是草稿的 PR。不寫入 GitHub；要改的每一份把原文存進備份目錄。
  --apply        照最近一次試跑：寫入前再讀一次說明、和備份的原文比，相同才以 gh api -X PATCH 寫回，
                 不同就略過。結束時列出已改、略過、失敗。
  --repo         要清的 repo（owner/name）。
  --backup-dir   備份與比對基準的根目錄（預設 <repo 根目錄>/.attribution-scrub/，在 .gitignore 裡）。
  --interval     --apply 每兩次寫入之間等幾秒（預設 1；GitHub 建議連續的寫入要隔開）。

  樣式在 script/attribution-patterns.txt。輸出只有編號、行號與樣式，不印命中的內容。

  exit 0   試跑：兩份清單都翻完、沒有要改的；--apply：要改的每一份都寫回了
  exit 1   讀不到某一頁、樣式清單或備份（不報 0）；--apply 有略過或失敗的
  exit 2   用法不對
  exit 3   試跑：兩份清單都翻完、有要改的（列在上面）
USAGE
}

main() {
  local repo="" apply=0 backup="${REPO_ROOT}/.attribution-scrub" interval=1
  while (($# > 0)); do
    case "$1" in
      --repo | --backup-dir | --interval)
        if (($# < 2)); then
          usage >&2
          return 2
        fi
        case "$1" in
          --repo) repo="$2" ;;
          --backup-dir) backup="$2" ;;
          --interval) interval="$2" ;;
        esac
        shift 2
        ;;
      --apply)
        apply=1
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        usage >&2
        return 2
        ;;
    esac
  done
  if [[ ! "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || [[ ! "${interval}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    usage >&2
    return 2
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf 'scrub_attribution: python3 不在 PATH 上，一份說明都沒有讀。\n' >&2
    printf 'scrub_attribution: 下一步：在跑這支腳本的機器上裝 python3\n' >&2
    return 1
  fi

  python3 - "${REPO_ROOT}/script/attribution-patterns.txt" "${repo}" "${apply}" "${backup}" "${interval}" <<'PY'
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TAG = "scrub_attribution"
PLACEHOLDER = "（session 連結已移除）"
patterns_path, REPO, apply_mode, BACKUP, INTERVAL = sys.argv[1:]
APPLY = apply_mode == "1"
INTERVAL = float(INTERVAL)
BREAK = re.compile(r"\r\n|\n|\r")
BLANK = re.compile(r"[ \t]*")
KINDS = {"pr": ("pulls", "PR"), "issue": ("issues", "issue")}


def say(line=""):
    print(f"{TAG}: {line}", flush=True)


def fail(lines):
    for line in lines:
        print(f"{TAG}: {line}", file=sys.stderr)
    sys.exit(1)


def load_patterns(path):
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        fail([f"讀不到樣式清單 {path}（{error.strerror}），一份說明都沒有讀。",
              "下一步：確認 script/attribution-patterns.txt 在這個簽出裡"])
    whole, inline = [], []
    for number, line in enumerate(lines, 1):
        if not line.strip() or line.startswith("#"):
            continue
        try:
            compiled = re.compile(line, re.IGNORECASE)
        except re.error as error:
            fail([f"樣式清單 {path} 第 {number} 行不是可用的正規式（{error}）。", "下一步：修正那一行"])
        (whole if line.startswith("^") else inline).append((line, compiled))
    if not whole and not inline:
        fail([f"樣式清單 {path} 裡沒有任何樣式，一份說明都沒有讀。", "下一步：照檔頭的說明補回樣式"])
    return whole, inline


WHOLE, INLINE = load_patterns(patterns_path)


def split_lines(text):
    """[(這一行的內容, 它的換行字元)]；最後一行沒有換行時換行字元是空字串。"""
    lines, start = [], 0
    for match in BREAK.finditer(text):
        lines.append((text[start:match.start()], match.group()))
        start = match.end()
    if start < len(text):
        lines.append((text[start:], ""))
    return lines


def scrub(text):
    """回傳 (清過的說明, 刪掉的 [(行號, 樣式)], 換掉的網址數, 另刪的結尾空行數)。"""
    kept, deleted, urls = [], [], 0
    for lineno, (content, newline) in enumerate(split_lines(text), 1):
        hit = next((source for source, pattern in WHOLE if pattern.search(content)), None)
        if hit is not None:
            deleted.append((lineno, hit))
            continue
        for _source, pattern in INLINE:
            content, count = pattern.subn(PLACEHOLDER, content)
            urls += count
        kept.append((lineno, content, newline))
    trailing = 0
    last = max((lineno for lineno, content, _ in kept if not BLANK.fullmatch(content)), default=0)
    if any(lineno > last for lineno, _ in deleted):
        while kept and kept[-1][0] > last:
            kept.pop()
            trailing += 1
    return "".join(content + newline for _, content, newline in kept), deleted, urls, trailing


def gh(*arguments):
    try:
        completed = subprocess.run(["gh", *arguments], capture_output=True, text=True, encoding="utf-8")
    except FileNotFoundError:
        return None, "PATH 上沒有 gh"
    except UnicodeDecodeError as error:
        return None, f"gh 的輸出不是 UTF-8（{error}）"
    if completed.returncode != 0:
        return None, (completed.stderr.strip().splitlines() or [f"gh 以 {completed.returncode} 結束，沒有給出原因"])[-1]
    return completed.stdout, None


def status_of(kind, item):
    if kind == "issue":
        return "開著" if item.get("state") == "open" else "已關閉"
    if item.get("merged_at"):
        return "已合併"
    if item.get("state") != "open":
        return "已關閉"
    return "開著的草稿" if item.get("draft") else "開著、不是草稿"


def enumerate_all(kind):
    """一頁一頁讀到空的那一頁。回傳 ({編號: 那一筆}, 讀了幾頁, 排除的 PR 數)。任何一頁讀不到就失敗。"""
    path, label = KINDS[kind]
    items, excluded, page = {}, 0, 1
    while True:
        endpoint = f"repos/{REPO}/{path}?state=all&sort=created&direction=asc&per_page=100&page={page}"
        raw, error = gh("api", endpoint)
        where = f"{label} 清單第 {page} 頁"
        if raw is None:
            fail([f"{where}讀取失敗（{error}），{label} 清單沒有翻完所有分頁；這次試跑不算數，不報 0。",
                  "下一步：確認 gh 已登入、對這個 repo 有讀取權限、網路正常，再重新試跑"])
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as error:
            fail([f"{where}回的不是 JSON（{error}），{label} 清單沒有翻完所有分頁；這次試跑不算數，不報 0。",
                  f"下一步：手動執行 gh api '{endpoint}' 看它回了什麼，再重新試跑"])
        if not isinstance(data, list) or not all(isinstance(item, dict) and isinstance(item.get("number"), int)
                                                 for item in data):
            fail([f"{where}回的不是一串帶編號的 {label}，{label} 清單沒有翻完所有分頁；這次試跑不算數，不報 0。",
                  f"下一步：手動執行 gh api '{endpoint}' 看它回了什麼，再重新試跑"])
        if not data:
            return items, page, excluded
        for item in data:
            if kind == "issue" and "pull_request" in item:
                excluded += 1
                continue
            items.setdefault(item["number"], item)
        page += 1


def new_run_dir():
    try:
        os.makedirs(BACKUP, exist_ok=True)
        existing = [int(name[:4]) for name in os.listdir(BACKUP) if re.fullmatch(r"\d{4}-.*", name)]
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        run = os.path.join(BACKUP, f"{max(existing, default=0) + 1:04d}-{stamp}")
        os.makedirs(run)
    except OSError as error:
        fail([f"建立不了備份目錄 {BACKUP}（{error.strerror}），沒有讀任何說明。",
              "下一步：用 --backup-dir 指一個寫得進去的目錄"])
    return run


def write_json(path, data):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=1)
        handle.write("\n")


def numbers(entries):
    """[(kind, number)] → 「PR #1、#3；issue #4」。"""
    parts = []
    for kind in ("pr", "issue"):
        picked = sorted(number for k, number in entries if k == kind)
        if picked:
            parts.append(f"{KINDS[kind][1]} " + "、".join(f"#{number}" for number in picked))
    return "；".join(parts)


def summary_line(name, entries):
    listed = numbers(entries)
    return f"{name} {len(entries)} 份" + (f"：{listed}" if listed else "")


def dry_run():
    run = new_run_dir()
    write_json(os.path.join(run, "plan.json"), {"repo": REPO, "complete": False, "items": []})
    say(f"試跑（不寫入 GitHub）：{REPO}；樣式讀 script/attribution-patterns.txt")
    pulls, pull_pages, _ = enumerate_all("pr")
    issues, issue_pages, excluded = enumerate_all("issue")
    say(f"PR 清單翻完 {pull_pages} 頁（讀到空的那一頁為止），共 {len(pulls)} 份；"
        f"issue 清單翻完 {issue_pages} 頁，共 {len(issues)} 份（另排除 issues API 回傳裡的 PR {excluded} 筆）")
    plan, listing = [], []
    for kind, items in (("pr", pulls), ("issue", issues)):
        for number in sorted(items):
            item = items[number]
            body = item.get("body") or ""
            cleaned, deleted, urls, trailing = scrub(body)
            if cleaned == body:
                continue
            status = status_of(kind, item)
            name = f"{kind}-{number}.txt"
            with open(os.path.join(run, name), "wb") as handle:
                handle.write(body.encode("utf-8"))
            plan.append({"kind": kind, "number": number, "status": status, "file": name,
                         "original_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
                         "deleted_lines": [lineno for lineno, _ in deleted], "trailing_blank_lines": trailing,
                         "urls": urls})
            lines = "、".join(str(lineno) for lineno, _ in deleted)
            removed = f"刪第 {lines} 行" if deleted else "刪 0 行"
            if trailing:
                removed += f"，另刪結尾空行 {trailing} 行"
            sources = sorted({source for _, source in deleted})
            hit = f"（樣式 {'、'.join(sources)}）" if sources else ""
            listing.append(f"  - {KINDS[kind][1]} #{number}（{status}）：{removed}{hit}；換掉 {urls} 個網址")
    write_json(os.path.join(run, "plan.json"), {"repo": REPO, "complete": True, "items": plan})
    pr_count = sum(1 for entry in plan if entry["kind"] == "pr")
    say(f"要改 {len(plan)} 份（PR {pr_count}、issue {len(plan) - pr_count}）")
    for line in listing:
        say(line)
    ready = [entry["number"] for entry in plan if entry["status"] == "開著、不是草稿"]
    if ready:
        say("開著、不是草稿的 PR：" + "、".join(f"#{number}" for number in ready)
            + "（改描述會觸發 edited，重跑一輪 CI；檢查全過就會被 merge job 合併）")
    if not plan:
        say("兩份清單都翻完所有分頁，沒有要改的說明。")
        return 0
    say(f"備份與比對基準：{run}（每一份的原文；下一次 --apply 以這份為準）")
    say("下一步：核對上面的清單，再加 --apply 寫回")
    return 3


def latest_plan():
    try:
        runs = sorted(name for name in os.listdir(BACKUP) if re.fullmatch(r"\d{4}-.*", name))
    except OSError:
        runs = []
    if not runs:
        fail([f"備份目錄 {BACKUP} 裡沒有任何一次試跑，--apply 沒有比對基準，沒有寫入。",
              "下一步：先不加 --apply 試跑一次，核對清單後再 --apply"])
    run = os.path.join(BACKUP, runs[-1])
    try:
        with open(os.path.join(run, "plan.json"), encoding="utf-8") as handle:
            plan = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        fail([f"讀不到最近一次試跑的清單 {run}/plan.json（{error}），沒有寫入。", "下一步：重新試跑，再 --apply"])
    if not plan.get("complete"):
        fail([f"最近一次試跑 {run} 沒有翻完所有分頁，清單不完整，沒有寫入。", "下一步：重新試跑到成功，再 --apply"])
    if plan.get("repo") != REPO:
        fail([f"最近一次試跑 {run} 是 {plan.get('repo')} 的，不是 {REPO}，沒有寫入。",
              f"下一步：對 {REPO} 重新試跑，再 --apply"])
    return run, plan["items"]


def apply():
    run, items = latest_plan()
    say(f"--apply：照試跑 {os.path.basename(run)}，要改 {len(items)} 份")
    done, skipped, failed, ready, details = [], [], [], [], []
    wrote = False
    for entry in items:
        kind, number = entry["kind"], entry["number"]
        path, label = KINDS[kind]
        key = (kind, number)
        try:
            with open(os.path.join(run, entry["file"]), "rb") as handle:
                original = handle.read().decode("utf-8")
        except (OSError, UnicodeDecodeError) as error:
            failed.append(key)
            details.append(f"  - {label} #{number} 失敗：讀不到備份 {entry['file']}（{error}）")
            continue
        endpoint = f"repos/{REPO}/{path}/{number}"
        raw, error = gh("api", endpoint)
        current = None
        if raw is not None:
            try:
                current_item = json.loads(raw)
                current = current_item.get("body") or ""
            except (json.JSONDecodeError, AttributeError) as decode_error:
                error = f"回的不是 JSON 物件（{decode_error}）"
        if current is None:
            failed.append(key)
            details.append(f"  - {label} #{number} 失敗：寫入前讀不到說明（{error}）")
            continue
        if current != original:
            skipped.append(key)
            details.append(f"  - {label} #{number} 略過：寫入前的說明和試跑時的原文不同")
            continue
        payload = os.path.join(run, f"{kind}-{number}.patch.json")
        write_json(payload, {"body": scrub(original)[0]})
        if wrote and INTERVAL > 0:
            time.sleep(INTERVAL)
        wrote = True
        _, error = gh("api", "-X", "PATCH", endpoint, "--input", payload)
        if error is not None:
            failed.append(key)
            details.append(f"  - {label} #{number} 失敗：寫入時 gh 回報錯誤（{error}）")
            continue
        done.append(key)
        if kind == "pr" and current_item.get("state") == "open" and not current_item.get("draft"):
            ready.append(number)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    write_json(os.path.join(run, f"apply-{stamp}.json"),
               {"done": [list(key) for key in done], "skipped": [list(key) for key in skipped],
                "failed": [list(key) for key in failed]})
    say(summary_line("已改", done))
    say(summary_line("略過", skipped))
    say(summary_line("失敗", failed))
    for line in details:
        say(line)
    if ready:
        say("已改的裡面開著、不是草稿的 PR：" + "、".join(f"#{number}" for number in sorted(ready))
            + "（改描述會觸發 edited 那一輪 CI）")
    if skipped or failed:
        say("下一步：重新試跑（用當下的內容建立新的備份與比對基準），核對後再 --apply")
        return 1
    say("下一步：再試跑一次，確認兩份清單都翻完、列出 0 個")
    return 0


sys.exit(apply() if APPLY else dry_run())
PY
}

main "$@"
