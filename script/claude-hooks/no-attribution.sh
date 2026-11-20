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

IFS= read -r -d '' program <<'PY' || true
import json
import os
import re
import sys

TAG = "no-attribution"
PATTERNS_PATH = sys.argv[1]
sys.stderr.reconfigure(encoding="utf-8", errors="replace")
PATTERNS = []

# 指令文字裡沒有 git 或 gh 這兩個字，就不必解析（也不會因為讀不懂而擋下無關的指令）。
MENTIONS = re.compile(r"(?<![A-Za-z0-9_-])(?:git|gh)(?![A-Za-z0-9_-])")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
LINES = re.compile(r"\r\n|\n|\r")
NAME_START = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_"
NAME_CHARS = NAME_START + "0123456789"

STEP_LITERAL = "值寫成字面的文字（-m \"…\"、--body \"…\"），或先把文字寫進檔、再以 -F／--body-file 帶入"
STEP_SPLIT = "把指令拆成單純的 git commit -F <檔>／gh … --body-file <檔> 再送"

HITS = []    # (位置, 行號, 樣式)
BLOCKS = []  # (位置, 原因, 下一步)


class Unparsable(Exception):
    """這條指令的引號、括號或指令替換沒有結束，讀不出它的結構。"""


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


# ── 讀 shell 指令：字、運算子、重新導向、指令替換 ─────────────────────────

class Word:
    """一個 shell 字。text 是去掉引號之後的字面文字（展開的部分不在裡面）。"""

    def __init__(self, text=""):
        self.text = text
        self.prefix = text      # 第一個展開之前的字面文字
        self.dynamic = None     # 有 shell 展開時，記下是哪一種
        self.quoted = False
        self.nested = []        # 指令替換、反引號、程序替換裡的指令（token 串）

    @property
    def static(self):
        return self.dynamic is None

    def add(self, chars):
        self.text += chars
        if self.dynamic is None:
            self.prefix += chars

    def expand(self, kind):
        if self.dynamic is None:
            self.dynamic = kind


def sub_word(word, start):
    out = Word()
    out.text = word.text[start:]
    out.prefix = word.prefix[start:]
    out.dynamic = word.dynamic
    out.nested = word.nested
    return out


SPACE = " \t"
META = set(" \t\n;&|()<>")
OPERATORS = ("&&", "||", ";;&", ";;", ";&", "|&", ";", "&", "|", "(", ")")
REDIRECTIONS = ("<<<", "<<-", "<<", "&>>", "&>", ">>", ">|", ">&", "<&", "<>", ">", "<")


class Lexer:
    def __init__(self, source, start=0, closing=False):
        self.s = source
        self.i = start
        self.closing = closing    # True：讀到對應的 ) 就停（指令替換、程序替換裡）
        self.tokens = []
        self.word = None
        self.heredocs = []        # 這一行結束後要讀內文的 (分隔字, 去掉開頭 tab, token)
        self.depth = 0

    def peek(self, offset=0):
        index = self.i + offset
        return self.s[index] if index < len(self.s) else ""

    def current(self):
        if self.word is None:
            self.word = Word()
        return self.word

    def flush(self):
        if self.word is not None:
            self.tokens.append(["word", self.word])
            self.word = None

    def run(self):
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c in SPACE:
                self.flush()
                self.i += 1
            elif c == "\\" and self.peek(1) == "\n":
                self.i += 2
            elif c == "\n":
                self.flush()
                self.tokens.append(["op", "\n"])
                self.i += 1
                self.read_heredocs()
            elif c == "#" and self.word is None:
                end = s.find("\n", self.i)
                self.i = len(s) if end < 0 else end
            elif c == ")" and self.closing and self.depth == 0:
                self.flush()
                return self.tokens, self.i + 1
            elif c in "<>" and self.peek(1) == "(":
                word = self.current()
                inner, end = Lexer(s, self.i + 2, closing=True).run()
                word.nested.append(inner)
                word.expand("程序替換")
                self.i = end
            elif c in "<>" or (c == "&" and self.peek(1) == ">"):
                self.redirection()
            elif c in ";&|()":
                self.flush()
                op = next(op for op in OPERATORS if s.startswith(op, self.i))
                self.i += len(op)
                if op == "(":
                    self.depth += 1
                elif op == ")":
                    self.depth = max(0, self.depth - 1)
                self.tokens.append(["op", op])
            else:
                self.word_char()
        self.flush()
        if self.closing:
            raise Unparsable("指令替換 $( … ) 沒有結束")
        self.read_heredocs()
        return self.tokens, self.i

    def redirection(self):
        word = self.word
        if word is not None and word.static and not word.quoted and word.text.isdigit():
            self.word = None  # 2>、1>& 前面的 fd 編號
        else:
            self.flush()
        op = next(op for op in REDIRECTIONS if self.s.startswith(op, self.i))
        self.i += len(op)
        token = ["redir", op, None, None]  # 目標字（heredoc 是分隔字）、heredoc 的內文
        self.tokens.append(token)
        if op in ("<<", "<<-"):
            while self.peek() in SPACE and self.peek():
                self.i += 1
            while self.i < len(self.s) and self.s[self.i] not in META:
                self.word_char()
            delimiter = self.word
            self.word = None
            if delimiter is None:
                raise Unparsable("<< 後面沒有分隔字")
            token[2] = delimiter
            self.heredocs.append((delimiter.text, op == "<<-", token))

    def read_heredocs(self):
        s = self.s
        for delimiter, strip_tabs, token in self.heredocs:
            body = []
            while self.i < len(s):
                end = s.find("\n", self.i)
                line = s[self.i:] if end < 0 else s[self.i:end]
                self.i = len(s) if end < 0 else end + 1
                if strip_tabs:
                    line = line.lstrip("\t")
                if line == delimiter:
                    break
                body.append(line)
            token[3] = "\n".join(body)
        self.heredocs = []

    def word_char(self):
        s = self.s
        c = s[self.i]
        word = self.current()
        if c == "'":
            end = s.find("'", self.i + 1)
            if end < 0:
                raise Unparsable("單引號沒有結束")
            word.add(s[self.i + 1:end])
            word.quoted = True
            self.i = end + 1
        elif c == '"':
            word.quoted = True
            self.i = self.double_quoted(self.i + 1, word)
        elif c == "$":
            self.i = self.dollar(self.i, word, False)
        elif c == "`":
            self.i = self.backtick(self.i, word)
        elif c == "\\":
            if self.i + 1 < len(s):
                word.add(s[self.i + 1])
                word.quoted = True
            self.i += 2
        elif c in "*?[":
            word.add(c)
            word.expand("萬用字元")
            self.i += 1
        elif c == "~" and word.text == "" and word.static and not word.quoted:
            following = self.peek(1)
            if following in ("", "/") or following in META:
                word.add(os.path.expanduser("~"))
            else:
                word.add(c)
                word.expand("~使用者")
            self.i += 1
        else:
            word.add(c)
            self.i += 1

    def double_quoted(self, i, word):
        s = self.s
        while i < len(s):
            c = s[i]
            if c == '"':
                return i + 1
            if c == "\\" and i + 1 < len(s):
                following = s[i + 1]
                if following in '$`"\\':
                    word.add(following)
                    i += 2
                elif following == "\n":
                    i += 2
                else:
                    word.add(c)
                    i += 1
            elif c == "$":
                i = self.dollar(i, word, True)
            elif c == "`":
                i = self.backtick(i, word)
            else:
                word.add(c)
                i += 1
        raise Unparsable("雙引號沒有結束")

    def dollar(self, i, word, in_double_quotes):
        s = self.s
        following = s[i + 1] if i + 1 < len(s) else ""
        if following == "(":
            if i + 2 < len(s) and s[i + 2] == "(":
                word.expand("算術展開")
                return self.skip_arithmetic(i + 3)
            inner, end = Lexer(s, i + 2, closing=True).run()
            word.nested.append(inner)
            word.expand("指令替換")
            return end
        if following == "{":
            word.expand("變數")
            return self.skip_braces(i + 2, word)
        if following == "'" and not in_double_quotes:
            word.expand("$'…' 引號")
            return self.skip_ansi(i + 2)
        if following == '"' and not in_double_quotes:
            word.quoted = True
            return self.double_quoted(i + 2, word)
        if following and following in NAME_START:
            end = i + 1
            while end < len(s) and s[end] in NAME_CHARS:
                end += 1
            word.expand("變數")
            return end
        if following and following in "0123456789@*#?$!-":
            word.expand("變數")
            return i + 2
        word.add("$")
        return i + 1

    def skip_arithmetic(self, i):
        s = self.s
        depth = 0
        while i < len(s):
            if s[i] == "(":
                depth += 1
            elif s[i] == ")":
                if depth == 0:
                    if i + 1 < len(s) and s[i + 1] == ")":
                        return i + 2
                    raise Unparsable("算術展開 $(( … )) 沒有結束")
                depth -= 1
            i += 1
        raise Unparsable("算術展開 $(( … )) 沒有結束")

    def skip_braces(self, i, word):
        s = self.s
        depth = 1
        while i < len(s):
            c = s[i]
            if c == "\\":
                i += 2
            elif c == "'":
                end = s.find("'", i + 1)
                if end < 0:
                    raise Unparsable("單引號沒有結束")
                i = end + 1
            elif c == '"':
                i = self.double_quoted(i + 1, Word())
            elif c == "$" and i + 1 < len(s) and s[i + 1] in "({":
                i = self.dollar(i, word, True)
            elif c == "{":
                depth += 1
                i += 1
            elif c == "}":
                depth -= 1
                i += 1
                if depth == 0:
                    return i
            else:
                i += 1
        raise Unparsable("${ … } 沒有結束")

    def skip_ansi(self, i):
        s = self.s
        while i < len(s):
            if s[i] == "\\":
                i += 2
            elif s[i] == "'":
                return i + 1
            else:
                i += 1
        raise Unparsable("$'…' 沒有結束")

    def backtick(self, i, word):
        s = self.s
        j = i + 1
        content = []
        while j < len(s):
            c = s[j]
            if c == "\\" and j + 1 < len(s) and s[j + 1] in "`$\\":
                content.append(s[j + 1])
                j += 2
            elif c == "`":
                inner, _ = Lexer("".join(content)).run()
                word.nested.append(inner)
                word.expand("指令替換")
                return j + 1
            else:
                content.append(c)
                j += 1
        raise Unparsable("反引號沒有結束")


PUSH, POP = "(", ")"


class Command:
    def __init__(self):
        self.words = []
        self.redirections = []  # [運算子, 目標字, heredoc 內文]


def build(tokens):
    """token 串 → 依序的簡單指令，子 shell 的 ( ) 留成 PUSH／POP 記號。"""
    items = []
    state = {"command": Command(), "pending": None}

    def end():
        if state["pending"] is not None:
            state["command"].redirections.append(state["pending"][1:])
            state["pending"] = None
        command = state["command"]
        if command.words or command.redirections:
            items.append(command)
        state["command"] = Command()

    for token in tokens:
        kind = token[0]
        if kind == "word":
            if state["pending"] is not None:
                state["pending"][2] = token[1]
                state["command"].redirections.append(state["pending"][1:])
                state["pending"] = None
            else:
                state["command"].words.append(token[1])
        elif kind == "redir":
            if token[1] in ("<<", "<<-"):
                state["command"].redirections.append(token[1:])
            else:
                state["pending"] = token
        else:
            end()
            if token[1] in (PUSH, POP):
                items.append(token[1])
    end()
    return items


# ── 依序分析每一條簡單指令 ────────────────────────────────────────────────

class State:
    def __init__(self, cwd, written=None):
        self.cwd = cwd                                      # None：判斷不了目前的目錄
        self.written = written if written is not None else set()  # 這條指令裡先前被寫出的檔


def resolve(cwd, path):
    if os.path.isabs(path):
        return os.path.normpath(path)
    if cwd is None:
        return None
    return os.path.normpath(os.path.join(cwd, path))


def run_items(items, state):
    saved = []
    for item in items:
        if item == PUSH:
            saved.append(state.cwd)
        elif item == POP:
            if saved:
                state.cwd = saved.pop()
        else:
            analyze(item, state)


def run_script(text, state):
    try:
        tokens, _ = Lexer(text).run()
    except Unparsable as error:
        block("這條指令", f"讀不懂它的結構（{error}），找不出要寫出去的文字", STEP_SPLIT)
        return
    run_items(build(tokens), state)


PREFIX_WORDS = {"!", "{", "then", "do", "else", "elif", "if", "while", "until", "time"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}


def strip_wrappers(words):
    """拿掉 env、command、nohup 這類把後面的指令原樣執行的前綴；command -v 只是查詢，回空串。"""
    while words and words[0].static:
        name = os.path.basename(words[0].text)
        rest = words[1:]
        if name == "env":
            i = 0
            while i < len(rest) and rest[i].static:
                text = rest[i].text
                if text in ("-u", "--unset"):
                    i += 2
                elif text.startswith("-") or ASSIGN.match(text):
                    i += 1
                else:
                    break
            words = rest[i:]
        elif name in ("command", "builtin"):
            i = 0
            while i < len(rest) and rest[i].static and rest[i].text.startswith("-"):
                if rest[i].text in ("-v", "-V"):
                    return []
                i += 1
            words = rest[i:]
        elif name == "nohup":
            words = rest
        elif name == "exec":
            i = 0
            while i < len(rest) and rest[i].static and rest[i].text.startswith("-"):
                i += 2 if rest[i].text == "-a" else 1
            words = rest[i:]
        elif name == "nice":
            i = 0
            while i < len(rest) and rest[i].static and rest[i].text.startswith("-"):
                i += 2 if rest[i].text == "-n" else 1
            words = rest[i:]
        elif name == "timeout":
            i = 0
            while i < len(rest) and rest[i].static and rest[i].text.startswith("-"):
                i += 2 if rest[i].text in ("-s", "-k", "--signal", "--kill-after") else 1
            words = rest[i + 1:]
        elif name == "time":
            words = rest[1:] if rest and rest[0].static and rest[0].text == "-p" else rest
        else:
            break
    return words


def analyze(command, state):
    for word in command.words + [r[1] for r in command.redirections if r[1] is not None]:
        for inner in word.nested:
            run_items(build(inner), State(state.cwd, state.written))
    for op, target, _ in command.redirections:
        if op in (">", ">>", ">|", "&>", "&>>") and target is not None and target.static:
            path = resolve(state.cwd, target.text)
            if path is not None:
                state.written.add(path)

    words = list(command.words)
    assignments = []
    while words and ASSIGN.match(words[0].prefix):
        assignments.append(words.pop(0).prefix.split("=", 1)[0].rstrip("+"))
    while words and words[0].static and words[0].text in PREFIX_WORDS:
        words.pop(0)
        if words and words[0].static and words[0].text == "-p":
            words.pop(0)
    words = strip_wrappers(words)
    if not words:
        return
    head = words[0]
    if not head.static:
        indirect(words)
        return
    program = os.path.basename(head.text)
    args = words[1:]
    if program in ("cd", "pushd"):
        change_directory(args, state)
    elif program == "popd":
        state.cwd = None
    elif program == "git":
        analyze_git(args, state, assignments)
    elif program == "gh":
        analyze_gh(args, state)
    elif program in SHELLS:
        analyze_shell(args, state)
    elif program == "eval":
        analyze_eval(args, state)
    elif program == "tee":
        for arg in args:
            if arg.static and not arg.text.startswith("-"):
                path = resolve(state.cwd, arg.text)
                if path is not None:
                    state.written.add(path)
    else:
        indirect(words)


def change_directory(args, state):
    targets = [a for a in args if not (a.static and a.text.startswith("-") and a.text != "-")]
    if not targets:
        state.cwd = os.path.expanduser("~")
    elif not targets[0].static or targets[0].text == "-":
        state.cwd = None
    else:
        state.cwd = resolve(state.cwd, targets[0].text)


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


def analyze_shell(args, state):
    i = 0
    while i < len(args) and args[i].static and args[i].text[:1] in ("-", "+") and args[i].text not in ("-", "--"):
        text = args[i].text
        if text in ("-o", "+o"):
            i += 2
            continue
        if not text.startswith("--") and "c" in text[1:]:
            if i + 1 >= len(args):
                return
            script = args[i + 1]
            if script.static:
                if MENTIONS.search(script.text):
                    run_script(script.text, State(state.cwd, state.written))
            elif MENTIONS.search(script.text):
                block(f"{os.path.basename(text)} -c 的指令", "內容有 shell 展開，執行時才決定，hook 核對不了",
                      "直接執行 git commit／gh，不經 bash -c")
            return
        i += 1


def analyze_eval(args, state):
    if all(a.static for a in args):
        text = " ".join(a.text for a in args)
        if MENTIONS.search(text):
            run_script(text, State(state.cwd, state.written))
    elif any(MENTIONS.search(a.text) for a in args):
        block("eval", "eval 的內容有 shell 展開，執行時才決定，hook 核對不了", "直接執行 git commit／gh，不經 eval")


# ── 旗標 ──────────────────────────────────────────────────────────────────

class Parsed:
    def __init__(self):
        self.options = []      # (旗標名稱, 值的 Word 或 None)
        self.positionals = []
        self.unknown = []      # 清單外的旗標名稱
        self.opaque = False    # 有參數整個來自 shell 展開，分不出是不是旗標
        self.missing = []      # 要值卻沒有值的旗標

    def names(self):
        return [name for name, _ in self.options]


def parse_options(args, value_flags, bool_flags):
    parsed = Parsed()
    i = 0
    while i < len(args):
        word = args[i]
        head = word.text if word.static else word.prefix
        if not head.startswith("-") or (word.static and head == "-"):
            if head or word.static:
                parsed.positionals.append(word)
            else:
                parsed.opaque = True
            i += 1
            continue
        if word.static and head == "--":
            parsed.positionals.extend(args[i + 1:])
            break
        if head.startswith("--"):
            if "=" in head:
                name = head.split("=", 1)[0]
                value = sub_word(word, len(name) + 1)
            elif word.static:
                name, value = head, None
            else:
                parsed.opaque = True
                i += 1
                continue
            if name in value_flags:
                if value is None:
                    if i + 1 < len(args):
                        i += 1
                        value = args[i]
                    else:
                        parsed.missing.append(name)
                parsed.options.append((name, value))
            elif name in bool_flags:
                parsed.options.append((name, None))
            else:
                parsed.unknown.append(name)
            i += 1
            continue
        # 短旗標，可以連寫（-am msg）；要值的旗標吃掉這個字剩下的部分，或下一個字
        j = 1
        finished = False
        while j < len(head):
            name = "-" + head[j]
            if name in value_flags:
                if j + 1 < len(head) or not word.static:
                    value = sub_word(word, j + 1)
                elif i + 1 < len(args):
                    i += 1
                    value = args[i]
                else:
                    parsed.missing.append(name)
                    value = None
                parsed.options.append((name, value))
                finished = True
                break
            if name in bool_flags:
                parsed.options.append((name, None))
                j += 1
                continue
            parsed.unknown.append(name)
            finished = True
            break
        if not finished and not word.static:
            parsed.opaque = True
        i += 1
    return parsed


def literal(text):
    return Word(text)


def check_word(where, word):
    if word is None:
        return
    if not word.static:
        block(where, f"值來自 shell 的{word.dynamic}，hook 看不到實際的文字", STEP_LITERAL)
        return
    check_text(where, word.text)


def read_file(where, word, cwd, state):
    """讀帶入的檔；讀不到就記下原因、回 None。"""
    if word is None:
        return None
    if not word.static:
        block(where, f"路徑來自 shell 的{word.dynamic}，hook 不知道要讀哪個檔", "路徑寫成字面")
        return None
    if word.text == "-":
        block(where, "從標準輸入讀，hook 看不到要送出的文字", "先把文字寫進檔，再以檔名帶入（不用 -）")
        return None
    path = resolve(cwd, word.text)
    if path is None:
        block(where, "這條指令先切換到 hook 判斷不了的目錄，相對路徑對不到檔", "改用絕對路徑，或拿掉前面的 cd -、cd \"$變數\"")
        return None
    if path in state.written:
        block(where, "這個檔在同一條指令裡先被寫出，hook 讀得到的只有執行前的內容",
              "分成兩次：先把檔寫好，再另外執行 git commit／gh")
        return None
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except FileNotFoundError:
        block(where, "找不到這個檔", "確認路徑（相對路徑以這條指令執行時的目錄為準），先把檔寫好再送")
        return None
    except IsADirectoryError:
        block(where, "這是目錄，不是檔", "改成要帶入的那個檔")
        return None
    except OSError as error:
        block(where, f"讀不到這個檔（{error.strerror}）", "確認檔案權限後再送")
        return None
    return data.decode("utf-8", errors="replace")


def check_file(where, word, cwd, state):
    text = read_file(where, word, cwd, state)
    if text is not None:
        check_text(where, text)


def shown(word):
    return word.text if word is not None and word.static else ""


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

GH_TEXT = {
    "pr": {"-t": "title", "--title": "title", "-b": "body", "--body": "body", "-F": "file", "--body-file": "file"},
    "release": {"-t": "title", "--title": "title", "-n": "body", "--notes": "body", "-F": "file", "--notes-file": "file"},
}
GH_TEXT["issue"] = GH_TEXT["pr"]
GH_VALUES = {
    "pr": {"-R", "--repo", "-B", "--base", "-H", "--head",
           "-l", "--label", "--add-label", "--remove-label",
           "-a", "--assignee", "--add-assignee", "--remove-assignee",
           "-r", "--reviewer", "--add-reviewer", "--remove-reviewer",
           "-m", "--milestone", "-p", "--project", "--add-project", "--remove-project"},
    "release": {"-R", "--repo"},
}
GH_VALUES["issue"] = GH_VALUES["pr"]
GH_BOOLS = {
    "pr": {"-d", "--draft", "--edit-last", "--remove-milestone", "-h", "--help"},
    "release": {"-d", "--draft", "-h", "--help"},
}
GH_BOOLS["issue"] = GH_BOOLS["pr"]
STEP_GH_TEXT = "標題與內文明帶：--title …，加上 --body … 或 --body-file <檔>"
GH_UNKNOWN = {
    "--attach": ("會改寫實際送出的描述（可能重寫附件連結），送出的文字在本機核對不了",
                 "附件在網頁上加，或把附件網址直接寫進 --body-file 的內文"),
    "-e": ("會開編輯器，hook 看不到要送出的文字", STEP_GH_TEXT),
    "--editor": ("會開編輯器，hook 看不到要送出的文字", STEP_GH_TEXT),
    "-w": ("會改在瀏覽器裡寫，hook 看不到要送出的文字", STEP_GH_TEXT),
    "--web": ("會改在瀏覽器裡寫，hook 看不到要送出的文字", STEP_GH_TEXT),
    "-f": ("會由 commit 產生標題與內文，hook 看不到", STEP_GH_TEXT),
    "--fill": ("會由 commit 產生標題與內文，hook 看不到", STEP_GH_TEXT),
    "--fill-first": ("會由 commit 產生標題與內文，hook 看不到", STEP_GH_TEXT),
    "--fill-verbose": ("會由 commit 產生標題與內文，hook 看不到", STEP_GH_TEXT),
    "-T": ("會帶入範本的內文", STEP_GH_TEXT),
    "--template": ("會帶入範本的內文", STEP_GH_TEXT),
    "--recover": ("會帶入上次沒送出的內容", STEP_GH_TEXT),
    "--generate-notes": ("會由 GitHub 產生說明", "說明明帶：--notes … 或 --notes-file <檔>"),
    "--notes-from-tag": ("會由 tag 的訊息帶入說明", "說明明帶：--notes … 或 --notes-file <檔>"),
}
GH_UNKNOWN_DEFAULT = ("不在 hook 認得的旗標清單裡，實際送出的文字核對不了",
                      "拿掉它；文字用 --title、--body、--body-file 明帶，其他旗標只用 -R、-d、-B、-H 與 label、assignee、"
                      "reviewer、milestone、project 這幾類")


def analyze_gh(args, state):
    texts = [a.text if a.static else None for a in args]
    if not texts:
        return
    group = texts[0]
    if group is None:
        if any(t in ("api", "create", "edit", "comment") for t in texts if t is not None):
            block("gh", "子指令來自 shell 展開，hook 核對不了", STEP_LITERAL)
        return
    if group == "api":
        analyze_api(args[1:], state)
        return
    if group not in GH_VERBS:
        return
    i = 1
    while i < len(texts):
        text = texts[i]
        if text is None:
            return
        if text in ("-R", "--repo"):
            i += 2
        elif text.startswith("-"):
            i += 1
        else:
            break
    if i >= len(texts) or texts[i] not in GH_VERBS[group]:
        return
    analyze_gh_write(group, texts[i], args[1:i] + args[i + 1:], state)


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

API_VALUES = {"-X", "--method", "-f", "--raw-field", "-F", "--field", "-H", "--header", "--input", "-q", "--jq",
              "-t", "--template", "-p", "--preview", "--hostname", "--cache"}
API_BOOLS = {"-i", "--include", "--paginate", "--slurp", "--silent", "--verbose", "-h", "--help"}


def json_strings(node, path):
    if isinstance(node, str):
        yield path, node
    elif isinstance(node, dict):
        for key, value in node.items():
            yield from json_strings(value, f"{path}.{key}" if path else str(key))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from json_strings(value, f"{path}[{index}]")


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


def read_input():
    raw = sys.stdin.buffer.read()
    if not raw.strip():
        stop("hook 的輸入", "標準輸入是空的，看不到要執行的指令", STEP_INPUT)
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        stop("hook 的輸入", "標準輸入不是 JSON，看不到要執行的指令", STEP_INPUT)
    tool_input = data.get("tool_input") if isinstance(data, dict) else None
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str):
        stop("hook 的輸入", "JSON 裡沒有 tool_input.command，看不到要執行的指令", STEP_INPUT)
    cwd = data.get("cwd")
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        cwd = None
    return command, cwd


def main():
    global PATTERNS
    command, cwd = read_input()
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

python3 -c "${program}" "${patterns}"
code=$?
if [ "${code}" -eq 0 ] || [ "${code}" -eq 2 ]; then
  exit "${code}"
fi
printf 'no-attribution: 核對中途失敗（python3 結束碼 %s），這條指令先擋下（#405）。\n' "${code}" >&2
printf 'no-attribution: 下一步：照上面 python3 印的原因修正；修不了就把指令拆成單純的 git commit -F <檔>／gh … --body-file <檔>\n' >&2
exit 2
