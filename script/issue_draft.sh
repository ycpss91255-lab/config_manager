#!/usr/bin/env bash
#
# 開 issue 與改 issue 本文的審稿流程（#413）：審稿工作階段判定通過的那一份，就是開出去或改上去的那一份。
#
#   script/issue_draft.sh submit <名稱> (--new | --edit <編號>)   寫的人：做出快照、算雜湊、印出要送給協調工作階段的一段話
#   script/issue_draft.sh verdict <名稱> <雜湊> <意見檔>          審稿工作階段：對那份快照寫出審稿紀錄
#   script/issue_draft.sh create <名稱>                           判「可以開」之後開 issue
#   script/issue_draft.sh edit <名稱>                             判「可以發」之後改 issue 的標題與本文
#
# 草稿是 .issue-drafts/<名稱>/title.txt（一行標題）與 body.md（內文），.issue-drafts/ 在這支腳本所在簽出的頂層（.gitignore 有它）。
# 雜湊＝「標題、換行、內文」整串的 sha256，標題去掉結尾的換行。送審、下判定、送出共用這裡同一份讀檔、正規化與雜湊的實作。
#
#   快照  .issue-drafts/<名稱>/snapshots/<雜湊>/：title.txt、body.md、meta（雜湊、用途、執行 submit 的工作階段 id；改本文時另有
#         base/title.txt、base/body.md 與它們的雜湊）、review.md（審稿紀錄）、published（開出的網址）
#   身分  工作階段 Bash 環境裡的 CLAUDE_CODE_SESSION_ID：執行 submit 的和執行 verdict 的不能是同一個。CLAUDE_CODE_HOST_SESSION_ID
#         另外比對（#428）：兩邊都有而且相同（例如從寫的人的 Bash 啟動的 claude），或只有一邊有，就停；兩邊都沒有時只比
#         CLAUDE_CODE_SESSION_ID。verdict 比環境變數，create、edit 比紀錄第一行的 reviewer_host 和 meta 的 writer_host
#   鎖    四個動作共用 mkdir .issue-drafts/<名稱>/.lock；create、edit 一直拿到 gh 結束
#   目標  寫死成 github.com 上的本 repo，不受 GH_REPO、GH_HOST 影響；gh 只帶 --repo、--title、--body-file
#
# 這支不載入、也不執行 repo 裡的其他程式檔（審稿工作階段下判定前，比對的是這支加上下面這份清單）。
# 讀取的 repo 檔：script/attribution-patterns.txt
#
# 會呼叫的外部程式：python3、gh。開 issue、改本文要 gh 已經登入；規格用假的 gh。
#
# 這支刻意只用 bash 3.2 也有的寫法：它由工作階段在主機上執行，PATH 上的 bash 不一定是 brew 的那一個（macOS 內建的是 3.2）。
# 判定都在 python 裡；python 程式以 -c 傳入。
set -u

here="${BASH_SOURCE[0]%/*}"
[ "${here}" = "${BASH_SOURCE[0]}" ] && here=.
self="$(cd "${here}" && pwd -P)/${BASH_SOURCE[0]##*/}"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'issue_draft: python3 不在 PATH 上，%s 做不了快照、雜湊與核對（#413）。\n' "${self}" >&2
  printf 'issue_draft: 下一步：在這台機器裝 python3，或讓 PATH 找得到它，再重新執行\n' >&2
  exit 2
fi

IFS= read -r -d '' program <<'PY' || true
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TAG = "issue_draft"
SELF = sys.argv[1]
ARGS = sys.argv[2:]
TOP = os.path.dirname(os.path.dirname(SELF))
DRAFTS = os.path.join(TOP, ".issue-drafts")
PATTERNS = os.path.join(TOP, "script", "attribution-patterns.txt")
REPO = "github.com/ycpss91255-lab/config_manager"
REPO_API = "ycpss91255-lab/config_manager"
NAME = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*$")
SHA = re.compile(r"^[0-9a-f]{64}$")
VERDICTS = {"new": ("可以開", "要修改"), "edit": ("可以發", "要修改")}
PASS = {"new": "可以開", "edit": "可以發"}
RECORD = re.compile(r"^issue-review: (可以開|可以發|要修改) sha256=([0-9a-f]{64}) reviewer=(\S+)(?: reviewer_host=(\S+))?$")
USAGE = ("用法：script/issue_draft.sh submit <名稱> (--new | --edit <編號>) | verdict <名稱> <雜湊> <意見檔> | create <名稱> | "
         "edit <名稱>")


class Stop(Exception):
    """停下：印出原因與下一步，以非零結束。"""

    def __init__(self, why, step):
        super().__init__(why)
        self.why = why
        self.step = step


# ── 共用：讀草稿、正規化、雜湊 ────────────────────────────────────────────

def digest(title, body):
    """「標題、換行、內文」整串的 sha256；title、body 都是 bytes，title 已去掉結尾的換行。"""
    return hashlib.sha256(title + b"\n" + body).hexdigest()


def read_pair(folder, what):
    """讀 folder 底下的 title.txt 與 body.md：回 (標題 bytes, 內文 bytes, 雜湊)。"""
    try:
        with open(os.path.join(folder, "title.txt"), "rb") as handle:
            raw_title = handle.read()
        with open(os.path.join(folder, "body.md"), "rb") as handle:
            body = handle.read()
    except OSError as error:
        raise Stop(f"讀不到{what}的 {error.filename}（{error.strerror}）",
                   f"確認 {folder} 底下有 title.txt（一行標題）與 body.md（內文）")
    if b"\r" in raw_title or b"\r" in body:
        raise Stop(f"{what}（{folder}）的標題或內文有 CR（\\r）", "改成 LF 換行再執行")
    title = raw_title[:-1] if raw_title.endswith(b"\n") else raw_title
    if b"\n" in title:
        raise Stop(f"{what}的標題（{folder}/title.txt）多於一行", "title.txt 只寫一行標題")
    try:
        if not title.decode("utf-8").strip():
            raise Stop(f"{what}的標題（{folder}/title.txt）是空的", "在 title.txt 寫一行標題")
        body.decode("utf-8")
    except UnicodeDecodeError:
        raise Stop(f"{what}（{folder}）不是 UTF-8", "存成 UTF-8 再執行")
    return title, body, digest(title, body)


def load_patterns():
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
    return patterns


def check_attribution(title, body, what):
    """逐行比對 #405 的署名樣式；命中就停（不重抄命中的內容）。"""
    patterns = load_patterns()
    for part, text in (("標題", title), ("內文", body)):
        for number, line in enumerate(text.decode("utf-8").split("\n"), 1):
            for pattern in patterns:
                if pattern.search(line):
                    raise Stop(f"{what}的{part}第 {number} 行命中署名樣式 {pattern.pattern}",
                               "拿掉 Claude 署名與 session 連結（AGENTS.md「Commit 訊息」）再執行")


def present(value):
    """「有 id」：不是空字串、也不含空白字元；沒有就回空字串。"""
    return value if value and re.fullmatch(r"\S+", value) else ""


def session(name):
    return present(os.environ.get(name, ""))


def check_hosts(writer_host, reviewer_host, who, step):
    """比對兩邊的 CLAUDE_CODE_HOST_SESSION_ID（#428）：兩邊都有而且相同，或只有一邊有，就停；兩邊都沒有時不比。"""
    if writer_host and reviewer_host:
        if writer_host == reviewer_host:
            raise Stop(f"{who}和執行 submit 的工作階段在同一個桌面 app 工作階段裡（例如從它的 Bash 啟動的 claude）："
                       "寫的人不自己審（#428）", step)
    elif writer_host or reviewer_host:
        raise Stop(f"{who}和執行 submit 的工作階段，兩邊的環境不同（一邊在桌面 app 裡、一邊不在），"
                   "判斷不了是不是同一個工作階段（#428）", f"{step}；審稿工作階段要和寫的人一樣開在桌面 app 裡")


# ── 草稿資料夾、鎖、快照 ──────────────────────────────────────────────────

def draft_dir(name):
    if not NAME.match(name):
        raise Stop(f"草稿名稱 {name!r} 不合規則", "名稱只能用英數、.、_、-，不能以 . 開頭")
    folder = os.path.join(DRAFTS, name)
    if not os.path.isdir(folder):
        raise Stop(f"找不到草稿資料夾 {folder}", f"先寫 {folder}/title.txt 與 body.md")
    return folder


class Lock:
    def __init__(self, folder):
        self.path = os.path.join(folder, ".lock")

    def __enter__(self):
        try:
            os.mkdir(self.path)
        except FileExistsError:
            raise Stop(f"鎖 {self.path} 已經存在：另一個動作還在跑", f"等它結束；確定沒有在跑，就 rmdir {self.path}")
        except OSError as error:
            raise Stop(f"建不了鎖 {self.path}（{error.strerror}）", "確認草稿資料夾可以寫入")
        return self

    def __exit__(self, *exc):
        try:
            os.rmdir(self.path)
        except OSError:
            print(f"{TAG}: 放不掉鎖 {self.path}；下一步：確定沒有在跑，就 rmdir {self.path}", file=sys.stderr)
        return False


def read_meta(snap):
    path = os.path.join(snap, "meta")
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        raise Stop(f"讀不到快照的 meta {path}（{error.strerror}）", "重新執行 submit 送審")
    meta = {}
    for line in lines:
        if "=" in line:
            key, value = line.split("=", 1)
            meta[key] = value
    if not SHA.match(meta.get("sha256", "")) or meta.get("kind") not in VERDICTS or not meta.get("writer"):
        raise Stop(f"快照的 meta {path} 缺雜湊、用途或執行 submit 的工作階段", "重新執行 submit 送審")
    if meta["kind"] == "edit" and not (meta.get("issue", "").isdigit() and SHA.match(meta.get("base_sha256", ""))):
        raise Stop(f"快照的 meta {path} 缺要改的編號或送審當時的雜湊", "重新執行 submit 送審")
    return meta


def write_atomic(path, data):
    folder = os.path.dirname(path)
    handle, temporary = tempfile.mkstemp(dir=folder, prefix=".tmp-")
    try:
        with os.fdopen(handle, "wb") as out:
            out.write(data)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.remove(temporary)
        raise


def published_url(snap):
    path = os.path.join(snap, "published")
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip() or "（網址沒有記下）"
    except OSError:
        return "（讀不到網址）"


# ── gh ────────────────────────────────────────────────────────────────────

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


def github_issue(number):
    """GitHub 上 #number 現在的 (標題 bytes, 本文 bytes)。"""
    out = gh(["issue", "view", number, "--repo", REPO, "--json", "title,body"], f"讀 #{number}")
    try:
        data = json.loads(out)
        title, body = data["title"], data["body"]
    except (ValueError, KeyError, TypeError):
        raise Stop(f"gh issue view {number} 的輸出讀不出標題與本文", "確認 gh 的版本支援 --json title,body")
    if not isinstance(title, str) or not isinstance(body, str):
        raise Stop(f"gh issue view {number} 的標題或本文不是字串", "確認 gh 的版本支援 --json title,body")
    return title.encode("utf-8"), body.encode("utf-8")


# ── submit ────────────────────────────────────────────────────────────────

def submit(args):
    if len(args) == 2 and args[1] == "--new":
        kind, number = "new", None
    elif len(args) == 3 and args[1] == "--edit" and args[2].isdigit() and int(args[2]) > 0:
        kind, number = "edit", args[2]
    else:
        raise Stop("submit 的參數不對", "寫成 submit <名稱> --new，或 submit <名稱> --edit <編號>")
    writer = session("CLAUDE_CODE_SESSION_ID")
    if not writer:
        raise Stop("環境變數 CLAUDE_CODE_SESSION_ID 是空的，判斷不了是哪個工作階段送審（Q8）",
                   "在 Claude Code 的工作階段裡執行（它的 Bash 環境有這個變數）")
    name = args[0]
    folder = draft_dir(name)
    with Lock(folder):
        title, body, sha = read_pair(folder, "草稿")
        check_attribution(title, body, "草稿")
        snapshots = os.path.join(folder, "snapshots")
        snap = os.path.join(snapshots, sha)
        url = published_url(snap)
        if url is not None:
            raise Stop(f"這份內容（{sha}）已經開過：{url}", "不要再開一次；要改它的本文，改草稿後執行 submit <名稱> --edit <編號>")
        meta = [f"sha256={sha}", f"kind={kind}"]
        base = None
        if kind == "edit":
            base = github_issue(number)
            meta += [f"issue={number}", f"base_sha256={digest(*base)}"]
        meta.append(f"writer={writer}")
        host = session("CLAUDE_CODE_HOST_SESSION_ID")
        if host:
            meta.append(f"writer_host={host}")
        os.makedirs(snapshots, exist_ok=True)
        temporary = tempfile.mkdtemp(dir=snapshots, prefix=".tmp-")
        try:
            with open(os.path.join(temporary, "title.txt"), "wb") as out:
                out.write(title + b"\n")
            with open(os.path.join(temporary, "body.md"), "wb") as out:
                out.write(body)
            if base is not None:
                os.mkdir(os.path.join(temporary, "base"))
                with open(os.path.join(temporary, "base", "title.txt"), "wb") as out:
                    out.write(base[0] + b"\n")
                with open(os.path.join(temporary, "base", "body.md"), "wb") as out:
                    out.write(base[1])
            with open(os.path.join(temporary, "meta"), "w", encoding="utf-8") as out:
                out.write("\n".join(meta) + "\n")
            if os.path.exists(snap):
                shutil.rmtree(snap)  # 同一份內容先前的快照與紀錄：重送就重審
            os.rename(temporary, snap)
        except BaseException:
            shutil.rmtree(temporary, ignore_errors=True)
            raise
    purpose = "開新 issue" if kind == "new" else f"改 #{number} 的標題與本文"
    passing = PASS[kind]
    lines = [
        f"{TAG}: 送審的快照做好了（#413）。",
        f"  快照：{snap}",
        f"  雜湊：{sha}",
        f"  用途：{purpose}",
        "下一步：用 SendMessage 把下面這段送給協調工作階段，請它開審稿工作階段（寫的人不自己審）。",
        "----",
        f"請審這份 issue 草稿的快照（{purpose}）。只讀：不改草稿、程式與 GitHub；可以寫自己的意見檔（放在 repo 外）與 verdict 的紀錄。",
        f"- 標題：{snap}/title.txt",
        f"- 內文：{snap}/body.md",
    ]
    if kind == "edit":
        lines.append(f"- 送審當時 GitHub 上的標題與本文：{snap}/base/title.txt、{snap}/base/body.md")
    lines += [
        f"- 雜湊：{sha}",
        "下判定前，照 doc/agents/reporting.md 先確認要執行的腳本沒被改過（每一支的兩個值要相同）：",
    ]
    for rel in ("script/issue_draft.sh", "script/attribution-patterns.txt"):
        lines.append(f"  git -C '{TOP}' hash-object --no-filters {rel}")
        lines.append(f"  gh api 'repos/{REPO_API}/contents/{rel}?ref=main' --jq .sha")
    lines += [
        f"意見寫成檔，最後一個非空行寫「判定：{passing}」或「判定：要修改」，然後執行：",
        f"  '{SELF}' verdict {name} {sha} <意見檔>",
        "----",
    ]
    print("\n".join(lines))


# ── verdict ───────────────────────────────────────────────────────────────

def verdict(args):
    if len(args) != 3:
        raise Stop("verdict 的參數不對", "寫成 verdict <名稱> <雜湊> <意見檔>")
    name, sha, opinion = args
    if not SHA.match(sha):
        raise Stop(f"雜湊 {sha!r} 不是 64 位的小寫十六進位", "照 submit 印出的雜湊寫")
    folder = draft_dir(name)
    with Lock(folder):
        snap = os.path.join(folder, "snapshots", sha)
        record = os.path.join(snap, "review.md")
        if os.path.exists(record):
            os.remove(record)  # 第一步：舊紀錄先失效，之後任何一步失敗都不會留下可以放行的紀錄
        reviewer = session("CLAUDE_CODE_SESSION_ID")
        if not reviewer:
            raise Stop("環境變數 CLAUDE_CODE_SESSION_ID 是空的，判斷不了是哪個工作階段下判定（Q8）",
                       "在 Claude Code 的審稿工作階段裡執行（它的 Bash 環境有這個變數）")
        if not os.path.isdir(snap):
            raise Stop(f"找不到快照 {snap}", "照 submit 印出的名稱與雜湊寫；草稿改過就請寫的人重新 submit")
        meta = read_meta(snap)
        if meta["writer"] == reviewer:
            raise Stop("執行 verdict 的工作階段就是執行 submit 的那一個：寫的人不自己審（#413）",
                       "用 SendMessage 請協調工作階段另開審稿工作階段，由它執行 verdict")
        reviewer_host = session("CLAUDE_CODE_HOST_SESSION_ID")
        check_hosts(present(meta.get("writer_host")), reviewer_host, "這個工作階段",
                    "用 SendMessage 請協調工作階段另開審稿工作階段，由它執行 verdict")
        _, _, actual = read_pair(snap, "快照")
        if actual != sha or meta["sha256"] != sha:
            raise Stop(f"快照 {snap} 重算的雜湊是 {actual}，和參數或 meta 對不上", "請寫的人重新 submit 送審")
        try:
            with open(opinion, "rb") as handle:
                text = handle.read().decode("utf-8")
        except OSError as error:
            raise Stop(f"讀不到意見檔 {opinion}（{error.strerror}）", "把意見寫成檔再執行")
        except UnicodeDecodeError:
            raise Stop(f"意見檔 {opinion} 不是 UTF-8", "存成 UTF-8 再執行")
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if not lines:
            raise Stop(f"意見檔 {opinion} 是空的", "寫下意見，最後一行寫判定")
        allowed = VERDICTS[meta["kind"]]
        match = re.fullmatch(r"判定：(可以開|可以發|要修改)", lines[-1])
        if not match:
            raise Stop(f"意見檔 {opinion} 的最後一個非空行沒有判定",
                       f"最後一行寫「判定：{allowed[0]}」或「判定：{allowed[1]}」")
        result = match.group(1)
        if result not in allowed:
            purpose = "開新 issue" if meta["kind"] == "new" else "改本文"
            raise Stop(f"判定「{result}」和用途對不上：這份快照是{purpose}", f"最後一行寫「判定：{allowed[0]}」或「判定：{allowed[1]}」")
        header = f"issue-review: {result} sha256={sha} reviewer={reviewer}"
        if reviewer_host:
            header += f" reviewer_host={reviewer_host}"
        write_atomic(record, (header + "\n" + text).encode("utf-8"))
    print(f"{TAG}: 審稿紀錄寫好了（#413）：{record}")
    print(f"  判定：{result}")
    if result == PASS[meta["kind"]]:
        command = "create" if meta["kind"] == "new" else "edit"
        print(f"下一步：通知寫的人或協調工作階段，由它執行 script/issue_draft.sh {command} {name}")
    else:
        print("下一步：把意見交給寫的人；改完由它重新 submit 送審")


# ── create／edit ──────────────────────────────────────────────────────────

def send(args, action):
    if len(args) != 1:
        raise Stop(f"{action} 的參數不對", f"寫成 {action} <名稱>")
    name = args[0]
    folder = draft_dir(name)
    expected = "new" if action == "create" else "edit"
    with Lock(folder):
        title, body, sha = read_pair(folder, "草稿")
        snap = os.path.join(folder, "snapshots", sha)
        if not os.path.isdir(snap):
            raise Stop(f"目前的草稿（雜湊 {sha}）沒有送審過的快照：沒送審，或審完又改了標題或內文",
                       f"執行 script/issue_draft.sh submit {name} {'--new' if expected == 'new' else '--edit <編號>'} 送審")
        meta = read_meta(snap)
        if meta["kind"] != expected:
            raise Stop(f"這份快照送審的用途是 {meta['kind']}，不能用 {action} 送出",
                       f"用途是 new 就執行 create，是 edit 就執行 edit；要換用途就重新 submit")
        record = os.path.join(snap, "review.md")
        try:
            with open(record, encoding="utf-8") as handle:
                first = handle.readline().rstrip("\n")
        except OSError as error:
            raise Stop(f"讀不到審稿紀錄 {record}（{error.strerror}）：還沒審，或審稿沒有寫出紀錄",
                       "用 SendMessage 請協調工作階段開審稿工作階段，照 submit 印出的那段話審")
        found = RECORD.match(first)
        if not found:
            raise Stop(f"審稿紀錄 {record} 的第一行讀不出判定、雜湊與審稿的工作階段", "請審稿工作階段重新執行 verdict")
        result, recorded, reviewer, reviewer_host = found.groups()
        if recorded != sha:
            raise Stop(f"審稿紀錄的雜湊 {recorded} 和目前的草稿 {sha} 不同", "重新 submit 送審")
        if result != PASS[expected]:
            raise Stop(f"審稿紀錄判「{result}」", "照審稿意見改草稿，重新 submit 送審")
        if not reviewer or not meta["writer"] or reviewer == meta["writer"]:
            raise Stop("審稿紀錄的審稿工作階段和執行 submit 的是同一個：寫的人不自己審（#413）",
                       "用 SendMessage 請協調工作階段另開審稿工作階段，重新執行 verdict")
        check_hosts(present(meta.get("writer_host")), present(reviewer_host), "審稿紀錄的審稿工作階段",
                    "用 SendMessage 請協調工作階段另開審稿工作階段，重新執行 verdict")
        check_attribution(title, body, "送出用的快照")
        outbox = tempfile.mkdtemp(prefix="issue-draft-")
        try:
            body_file = os.path.join(outbox, "body.md")
            with open(body_file, "wb") as out:
                out.write(body)
            text = title.decode("utf-8")
            if action == "create":
                url = published_url(snap)
                if url is not None:
                    raise Stop(f"這份快照已經開過：{url}", "不要再開一次；要改它的本文，改草稿後執行 submit <名稱> --edit <編號>")
                out = gh(["issue", "create", "--repo", REPO, "--title", text, "--body-file", body_file], "開 issue")
                lines = [line.strip() for line in out.splitlines() if line.strip()]
                url = lines[-1] if lines else "（gh 沒有印出網址）"
                write_atomic(os.path.join(snap, "published"), (url + "\n").encode("utf-8"))
                print(f"{TAG}: 開好了（#413）：{url}")
            else:
                number = meta["issue"]
                if digest(*github_issue(number)) != meta["base_sha256"]:
                    raise Stop(f"送審之後 GitHub 上 #{number} 的標題或本文被改過（例如勾了帳本）",
                               f"把那些修改併進草稿，重新執行 script/issue_draft.sh submit {name} --edit {number} 送審")
                gh(["issue", "edit", number, "--repo", REPO, "--title", text, "--body-file", body_file], f"改 #{number}")
                print(f"{TAG}: 改好了（#413）：#{number}")
        finally:
            shutil.rmtree(outbox, ignore_errors=True)
    print("下一步：在 issue 留言附最後一輪的判定與適合公開的意見摘要（不貼本機路徑）；協調工作階段向維護者簡單說明審了哪些項目")


def main():
    if not ARGS or ARGS[0] in ("-h", "--help"):
        print(USAGE)
        sys.exit(0 if ARGS else 2)
    action, rest = ARGS[0], ARGS[1:]
    try:
        if action == "submit" and rest:
            submit(rest)
        elif action == "verdict":
            verdict(rest)
        elif action in ("create", "edit"):
            send(rest, action)
        else:
            raise Stop(f"不認得的動作或參數 {' '.join(ARGS)!r}", USAGE)
    except Stop as stopped:
        suffix = "。" if re.search(r"（#\d+）$", stopped.why) else "（#413）。"  # 原因已經以（#編號）結尾就不再加
        print(f"{TAG}: {stopped.why}{suffix}", file=sys.stderr)
        print(f"{TAG}: 下一步：{stopped.step}", file=sys.stderr)
        sys.exit(1)


main()
PY

python3 -c "${program}" "${self}" "$@"
