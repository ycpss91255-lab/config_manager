#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code hook 共用的指令解析（#408）。由 script/claude-hooks/ 底下的 hook 以 `.` 載入，不直接執行。
#
# 署名 hook（#405）原本自己帶著這一段；#408 的 PR 規則 hook 要讀同樣的指令、認同一份 gh 旗標清單（#408 第 2 點：「旗標
# 只認和〔B〕相同的清單」「下一步兩支 hook 寫法一致」），所以搬到這裡，只留一份。
#
# shell_parse_program 印出一段 python，載入它的 hook 把自己的 python 接在後面，再以 `python3 -c` 執行（標準輸入留給
# hook 的 JSON）。這段 python 提供：
#
#   Lexer、build          把指令文字讀成依序的簡單指令（字、引號、指令替換、heredoc、&&／;、子 shell）
#   run_script、analyze   依序分析每一條簡單指令：指令替換裡的、cd 之後的目錄、bash -c、eval、tee 與重新導向寫出的檔
#   command_words         拿掉變數設定、if／!／time 這類前綴與 env、command、nohup 這類包裝，留下真正執行的字
#   parse_options         依旗標清單把參數分成旗標、值與位置參數，清單外的旗標另外列出
#   read_file             讀指令帶入的檔，讀不到就記下原因與下一步
#   gh_parts              gh 的群組、子指令與其餘參數
#   GH_*、API_*           gh pr|issue|release 與 gh api 認得的旗標，與清單外旗標的原因和下一步
#   load_input            讀 hook 的 JSON
#
# 載入它的 hook 要在自己的 python 裡定義：
#
#   block(where, why, step)    記下一個擋下（或判斷不了）的原因
#   stop(where, why, step)     記下之後立刻結束
#   MENTIONS                   指令文字裡要找的程式名稱（bash -c、eval 的內容沒有它就不展開）
#   COMMANDS                   下一步裡怎麼稱呼這支 hook 管的指令（例如「git commit／gh」）
#   UNPARSABLE                 讀不懂指令結構時，原因的後半句（例如「找不出要寫出去的文字」）
#   STEP_SPLIT                 讀不懂指令結構時的下一步
#   dispatch(program, args, state, assignments, words)   程式名稱是字面的簡單指令（cd、shell、eval、tee 以外）
#   indirect(words)            程式名稱來自 shell 展開的簡單指令（例如 xargs 之後才決定）
#
# 這支刻意只用 bash 3.2 也有的寫法：hook 由使用者的環境啟動，PATH 上的 bash 不一定是 brew 的那一個（macOS 內建的是 3.2）。
shell_parse_program() {
  cat <<'PY'
import json
import os
import re
import sys

sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
NAME_START = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_"
NAME_CHARS = NAME_START + "0123456789"


class Unparsable(Exception):
    """這條指令的引號、括號或指令替換沒有結束，讀不出它的結構。"""


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


def lex(text):
    """指令文字 → 依序的簡單指令；讀不懂就記下原因、回 None。"""
    try:
        tokens, _ = Lexer(text).run()
    except Unparsable as error:
        block("這條指令", f"讀不懂它的結構（{error}），{UNPARSABLE}", STEP_SPLIT)
        return None
    return build(tokens)


def run_script(text, state):
    items = lex(text)
    if items is not None:
        run_items(items, state)


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




def command_words(command):
    """(變數設定的名稱, 真正執行的字)：拿掉開頭的 NAME=值、if／!／time 這類前綴與 env、command 這類包裝。"""
    words = list(command.words)
    assignments = []
    while words and ASSIGN.match(words[0].prefix):
        assignments.append(words.pop(0).prefix.split("=", 1)[0].rstrip("+"))
    while words and words[0].static and words[0].text in PREFIX_WORDS:
        words.pop(0)
        if words and words[0].static and words[0].text == "-p":
            words.pop(0)
    return assignments, strip_wrappers(words)


def analyze(command, state):
    for word in command.words + [r[1] for r in command.redirections if r[1] is not None]:
        for inner in word.nested:
            run_items(build(inner), State(state.cwd, state.written))
    for op, target, _ in command.redirections:
        if op in (">", ">>", ">|", "&>", "&>>") and target is not None and target.static:
            path = resolve(state.cwd, target.text)
            if path is not None:
                state.written.add(path)

    assignments, words = command_words(command)
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
        dispatch(program, args, state, assignments, words)


def change_directory(args, state):
    targets = [a for a in args if not (a.static and a.text.startswith("-") and a.text != "-")]
    if not targets:
        state.cwd = os.path.expanduser("~")
    elif not targets[0].static or targets[0].text == "-":
        state.cwd = None
    else:
        state.cwd = resolve(state.cwd, targets[0].text)


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
                      f"直接執行 {COMMANDS}，不經 bash -c")
            return
        i += 1


def analyze_eval(args, state):
    if all(a.static for a in args):
        text = " ".join(a.text for a in args)
        if MENTIONS.search(text):
            run_script(text, State(state.cwd, state.written))
    elif any(MENTIONS.search(a.text) for a in args):
        block("eval", "eval 的內容有 shell 展開，執行時才決定，hook 核對不了", f"直接執行 {COMMANDS}，不經 eval")


# ── 旗標 ──────────────────────────────────────────────────────────────────

class Parsed:
    def __init__(self):
        self.options = []      # (旗標名稱, 值的 Word 或 None)；不帶值的旗標寫成 --x=值 時，值也記下來
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
                parsed.options.append((name, value))
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



def read_file(where, word, cwd, state, step=None):
    """讀帶入的檔；讀不到就記下原因、回 None。step 給了就用它當每一種原因的下一步。"""
    if word is None:
        return None
    if not word.static:
        block(where, f"路徑來自 shell 的{word.dynamic}，hook 不知道要讀哪個檔", step or "路徑寫成字面")
        return None
    if word.text == "-":
        block(where, "從標準輸入讀，hook 看不到要送出的文字", step or "先把文字寫進檔，再以檔名帶入（不用 -）")
        return None
    path = resolve(cwd, word.text)
    if path is None:
        block(where, "這條指令先切換到 hook 判斷不了的目錄，相對路徑對不到檔",
              step or "改用絕對路徑，或拿掉前面的 cd -、cd \"$變數\"")
        return None
    if path in state.written:
        block(where, "這個檔在同一條指令裡先被寫出，hook 讀得到的只有執行前的內容",
              step or f"分成兩次：先把檔寫好，再另外執行 {COMMANDS}")
        return None
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except FileNotFoundError:
        block(where, "找不到這個檔", step or "確認路徑（相對路徑以這條指令執行時的目錄為準），先把檔寫好再送")
        return None
    except IsADirectoryError:
        block(where, "這是目錄，不是檔", step or "改成要帶入的那個檔")
        return None
    except OSError as error:
        block(where, f"讀不到這個檔（{error.strerror}）", step or "確認檔案權限後再送")
        return None
    return data.decode("utf-8", errors="replace")


def shown(word):
    return word.text if word is not None and word.static else ""


# ── gh ────────────────────────────────────────────────────────────────────

def gh_parts(args):
    """gh 的 (群組, 子指令, 其餘參數)。群組來自 shell 展開時群組是 None；子指令來自 shell 展開時子指令是 None；
    沒有子指令時子指令是空字串。gh api 沒有子指令，其餘參數就是 api 後面的全部。"""
    texts = [a.text if a.static else None for a in args]
    if not texts:
        return "", "", []
    group = texts[0]
    if group is None:
        return None, None, args[1:]
    if group == "api":
        return group, "", args[1:]
    i = 1
    while i < len(texts):
        text = texts[i]
        if text is None:
            return group, None, args[1:]
        if text in ("-R", "--repo"):
            i += 2
        elif text.startswith("-"):
            i += 1
        else:
            break
    if i >= len(texts):
        return group, "", args[1:]
    return group, texts[i], args[1:i] + args[i + 1:]


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
    # 下一步照 #408 第 2 點，兩支 hook 寫法一致（署名 hook 與 PR 規則 hook 都讀這一張）
    "--attach": ("會改寫實際送出的描述（可能重寫附件連結），送出的文字在本機核對不了",
                 "附件在網頁上加，或把附件的網址直接寫進 --body-file 的內文；描述一律用 --body-file 送出"),
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




# ── hook 的輸入 ───────────────────────────────────────────────────────────

def load_input(step):
    """讀標準輸入那份 hook 的 JSON；讀不到就以 step 當下一步結束。"""
    raw = sys.stdin.buffer.read()
    if not raw.strip():
        stop("hook 的輸入", "標準輸入是空的，看不到這次的工具呼叫", step)
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        stop("hook 的輸入", "標準輸入不是 JSON，看不到這次的工具呼叫", step)
    if not isinstance(data, dict):
        stop("hook 的輸入", "JSON 的最上層不是物件，看不到這次的工具呼叫", step)
    return data


def input_command(data, step):
    """(指令文字, cwd)：Bash 工具呼叫的 tool_input.command 與 cwd（不是絕對路徑就是 None）。"""
    tool_input = data.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str):
        stop("hook 的輸入", "JSON 裡沒有 tool_input.command，看不到要執行的指令", step)
    cwd = data.get("cwd")
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        cwd = None
    return command, cwd
PY
}
