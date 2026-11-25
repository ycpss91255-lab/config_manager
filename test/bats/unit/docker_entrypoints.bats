#!/usr/bin/env bats
#
# script/claude-hooks/docker-entrypoints.txt —— 會執行 docker 的入口清單（T19、#412 調整需求第 1 點）。env-rules.sh 照它回傳 ask，
# .claude/settings.json 的 permissions.ask 照它寫 Bash 規則。
#
# 這支規格遞迴掃 script/ 底下的可執行檔，找實際執行 docker 的行，與呼叫清單上另一個入口的行：
#   - 讀 shell 指令用 script/claude-hooks/shell-parse.sh 的 Lexer（和 hook 同一份），所以註解、訊息字串、heredoc 的內文裡提到的
#     docker 不算；先設環境變數再執行（script/hooks/post/build.sh:13）、指令替換裡的、exec、if ! 後面的都算。
#   - 「呼叫另一個入口」：指令的程式名稱（或 bash、source 的第一個參數）指到另一支要登記的可執行檔，或變數設定的值寫了它的路徑
#     （之後以變數執行，例如 release.sh 的 ACCEPTANCE）。要登記的集合一直擴大到不再變。
#   - 只供 source 載入的檔（沒有執行權限）不掃；不是 shell 的可執行檔（shebang 不是 sh／bash）也不掃——它們自己開 docker 是
#     #412 寫明擋不住的那一類。
#
# 被觀察的是「清單和 script/ 底下的檔對不對得起來」：新增一支執行 docker 的可執行檔卻沒登記、清單上留著已經不存在或不再開 docker
# 的檔，都會讓這支規格失敗。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  LIST="${REPO_ROOT}/script/claude-hooks/docker-entrypoints.txt"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  IFS= read -r -d '' SCANNER <<'PY' || true
root = sys.argv[1]


class RawLexer(Lexer):
    """記下每個字在原始碼裡的位置與原文（行號、變數設定的值裡寫的路徑）。"""

    def current(self):
        if self.word is None:
            self.word = Word()
            self.word.start = self.i
        return self.word

    def flush(self):
        if self.word is not None:
            self.word.raw = self.s[self.word.start:self.i]
        super().flush()


Lexer = RawLexer  # 指令替換裡的 Lexer 也用它

DOCKER = {"docker", "docker-compose"}
RECIPES = {"docker", "test"}
DECLARE = {"readonly", "local", "export", "declare", "typeset"}


def executables():
    found = []
    for dirpath, dirs, files in os.walk(os.path.join(root, "script")):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(dirpath, name)
            if not os.path.isfile(path) or not os.access(path, os.X_OK):
                continue
            with open(path, encoding="utf-8", errors="replace") as handle:
                source = handle.read()
            first = source.split("\n", 1)[0]
            if first.startswith("#!") and not re.search(r"\b(ba)?sh\b", first):
                continue
            found.append((os.path.relpath(path, root), source))
    return found


def line_of(source, word):
    return source.count("\n", 0, getattr(word, "start", 0)) + 1


def callee(word, scripts):
    text = os.path.normpath(word.text) if word.text else ""
    for script in scripts:
        if text == script or text.endswith("/" + script):
            return script
    return None


def walk(tokens, source, scripts, hits):
    for command in build(tokens):
        if command in (PUSH, POP):
            continue
        for word in command.words + [r[1] for r in command.redirections if r[1] is not None]:
            for inner in word.nested:
                walk(inner, source, scripts, hits)
        _, words = command_words(command)
        values = command.words[:len(command.words) - len(words)]
        if words and words[0].static and words[0].text in DECLARE:
            values += [w for w in words[1:] if ASSIGN.match(w.prefix)]
        for word in values:
            for script in scripts:
                if re.search(r"(^|[/=\"'{:-])" + re.escape(script) + r"($|[\"'}\s])", getattr(word, "raw", "")):
                    hits.append((line_of(source, word), script))
        if not words:
            continue
        head = words[0]
        name = os.path.basename(head.text) if head.static else ""
        if name in DOCKER:
            hits.append((line_of(source, head), name))
        elif name == "just":
            recipes = [a.text for a in words[1:] if a.static and not a.text.startswith("-")]
            if recipes and recipes[0].split("::", 1)[0] in RECIPES:
                hits.append((line_of(source, head), "just " + recipes[0].split("::", 1)[0]))
        else:
            target = head
            if name in SHELLS or name in (".", "source"):
                rest = [a for a in words[1:] if not (a.static and a.text.startswith("-"))]
                target = rest[0] if rest else None
            script = callee(target, scripts) if target is not None else None
            if script is not None:
                hits.append((line_of(source, target), script))


def main():
    files = executables()
    names = [rel for rel, _ in files]
    parsed = {}
    for rel, source in files:
        try:
            parsed[rel] = (RawLexer(source).run()[0], source)
        except Unparsable as error:
            print(f"{rel}:0:讀不懂（{error}）")
    required = set()
    while True:
        report = []
        for rel in names:
            if rel not in parsed:
                continue
            hits = []
            tokens, source = parsed[rel]
            walk(tokens, source, [n for n in names if n != rel], hits)
            for line, target in sorted(set(hits)):
                if target in DOCKER or target.startswith("just ") or target in required:
                    report.append(f"{rel}:{line}:{target}")
        now = {entry.split(":", 1)[0] for entry in report}
        if now == required:
            break
        required = now
    for entry in report:
        print(entry)


main()
PY
}

teardown() {
  rm -rf "${WORK}"
}

# scan <根目錄>：印出 <路徑>:<行>:<執行的入口>，每個偵測到的執行一行。
scan() {
  # shellcheck source=script/claude-hooks/shell-parse.sh
  . "${REPO_ROOT}/script/claude-hooks/shell-parse.sh"
  python3 -c "$(shell_parse_program)
${SCANNER}" "$1"
}

# required <根目錄>：要登記的可執行檔，一行一個。
required() {
  scan "$1" | cut -d: -f1 | sort -u
}

# listed <清單>：清單上的 script/ 腳本，一行一個。
listed() {
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$1" | grep '^script/' | sort -u
}

# unregistered <根目錄> <清單>：要登記卻沒登記的可執行檔。
unregistered() {
  comm -23 <(required "$1") <(listed "$2")
}

# fixture：把 repo 的 script/ 原樣複製到 ${WORK}（保留執行權限）。
fixture() {
  cp -Rp "${REPO_ROOT}/script" "${WORK}/script"
}

@test "script/ 底下實際執行 docker 的可執行檔，每一支都登記在 docker-entrypoints.txt" {
  run unregistered "${REPO_ROOT}" "${LIST}"

  [ "${status}" -eq 0 ]
  [ -z "${output}" ] || { echo "沒登記：${output}"; false; }
}

@test "清單上的每一支腳本都存在、可執行，而且掃得到它執行 docker 或呼叫另一個入口" {
  required "${REPO_ROOT}" >"${WORK}/required.txt"
  listed "${LIST}" >"${WORK}/listed.txt"

  run comm -13 "${WORK}/required.txt" "${WORK}/listed.txt"

  [ "${status}" -eq 0 ]
  [ -z "${output}" ] || { echo "清單上多出來：${output}"; false; }
}

@test "讀得懂 script/ 底下每一支 shell 可執行檔" {
  run scan "${REPO_ROOT}"

  [ "${status}" -eq 0 ]
  [[ "${output}" != *":0:讀不懂"* ]]
}

@test "先設環境變數再執行 docker 的行算數：script/hooks/post/build.sh:13" {
  run scan "${REPO_ROOT}"

  [[ "${output}" == *"script/hooks/post/build.sh:13:docker"* ]]
}

@test "新增一支執行 docker 的可執行檔卻沒登記時，規格失敗（它被列成沒登記）" {
  fixture
  printf '#!/usr/bin/env bash\nset -eu\nCM_STAGE=x docker compose ps\n' >"${WORK}/script/new_docker.sh"
  chmod +x "${WORK}/script/new_docker.sh"

  run unregistered "${WORK}" "${LIST}"

  [ "${output}" = "script/new_docker.sh" ]
}

@test "一支假的可執行檔裡呼叫 script/test.sh（清單上的入口）卻沒登記時，規格也失敗" {
  fixture
  printf '#!/usr/bin/env bash\n"${REPO_ROOT}/script/test.sh" --lint\n' >"${WORK}/script/calls_test.sh"
  chmod +x "${WORK}/script/calls_test.sh"

  run unregistered "${WORK}" "${LIST}"

  [ "${output}" = "script/calls_test.sh" ]
}

@test "呼叫沒登記的入口的可執行檔也要登記（一直擴大到不再變）" {
  fixture
  printf '#!/usr/bin/env bash\ndocker ps\n' >"${WORK}/script/a.sh"
  printf '#!/usr/bin/env bash\nbash script/a.sh\n' >"${WORK}/script/b.sh"
  chmod +x "${WORK}/script/a.sh" "${WORK}/script/b.sh"

  run unregistered "${WORK}" "${LIST}"

  [ "${output}" = "$(printf 'script/a.sh\nscript/b.sh')" ]
}

@test "現有的間接入口 script/release.sh 在清單裡" {
  run grep -qx 'script/release.sh' "${LIST}"

  [ "${status}" -eq 0 ]
}

@test "只供 source 載入的檔（沒有執行權限）不要求登記" {
  fixture
  printf 'docker ps\n' >"${WORK}/script/only_sourced.sh"
  chmod 644 "${WORK}/script/only_sourced.sh"

  run unregistered "${WORK}" "${LIST}"

  [ -z "${output}" ]
}

@test "註解、訊息字串與 heredoc 的內文裡提到的 docker 不算執行" {
  fixture
  cat >"${WORK}/script/mentions.sh" <<'SH'
#!/usr/bin/env bash
# docker compose up 在註解裡
printf 'mentions: 下一步：跑 docker compose logs\n' >&2
cat <<'USAGE'
docker run 在 heredoc 裡
USAGE
SH
  chmod +x "${WORK}/script/mentions.sh"

  run unregistered "${WORK}" "${LIST}"

  [ -z "${output}" ]
}

@test ".claude/settings.json 的 permissions.ask 和清單一一對應（script/ 寫成三種寫法，其他寫成 <入口> *）" {
  run python3 -c '
import json, sys
entries = []
for line in open(sys.argv[1], encoding="utf-8"):
    text = line.split("#", 1)[0].strip()
    if text:
        entries.append(text)
expected = []
for entry in entries:
    if entry.startswith("script/"):
        expected += [f"Bash(./{entry} *)", f"Bash({entry} *)", f"Bash(bash {entry} *)"]
    else:
        expected.append(f"Bash({entry} *)")
settings = json.load(open(sys.argv[2], encoding="utf-8"))
actual = settings.get("permissions", {}).get("ask", [])
print("missing:", sorted(set(expected) - set(actual)))
print("extra:", sorted(set(actual) - set(expected)))' "${LIST}" "${REPO_ROOT}/.claude/settings.json"

  [ "${output}" = "$(printf 'missing: []\nextra: []')" ]
}
