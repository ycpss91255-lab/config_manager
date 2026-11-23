#!/usr/bin/env bats
#
# script/claude-hooks/host-push-rules.sh —— Claude Code 的 PreToolUse hook：檢查工具不在主機直接跑、git push 寫明完整的
# 目的地 ref、不推到 main、force push 只用 --force-with-lease（T19、#409）。
#
# hook 在主機上跑，只讀工具呼叫的輸入裡的指令文字（#409 的 Q1）：不讀 git 設定、不呼叫 git、不讀指令帶入的檔。
# 看不到、判斷不了的時候擋下並寫出下一步（Q8）。
#
# 測的是公開行為：照 Claude Code 給 hook 的形狀把 JSON 餵進標準輸入，看結束碼（2 是擋下）與訊息。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  HOOK="${REPO_ROOT}/script/claude-hooks/host-push-rules.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  STEP_HOST="改用 ./script/test.sh（在檢查映像裡跑，執行前照 docker 先問），或看 GitHub CI"
  STEP_REFSPEC="每個 refspec 都寫成 <來源>:refs/heads/<名稱>，例如 git push -u origin feat/x:refs/heads/feat/x"
  STEP_FLAGS="只用這些旗標"
  STEP_MAIN="不能推到 main"
  STEP_LEASE="改用 --force-with-lease"
  STEP_DELETE="刪除模式的每個參數都寫成完整的 ref，例如 git push --delete origin refs/heads/feat/x"
  # 判斷結果該不該隨環境變的那幾條規格共用的指令：放行與擋下的都有。
  SAMPLES=(
    "git push -u origin feat/x:refs/heads/feat/x"
    "git push origin"
    "git push origin feat/x"
    "git push origin feat/x:refs/heads/main"
    "git push --force-with-lease origin feat/x:refs/heads/feat/x"
    "git push -f origin feat/x:refs/heads/feat/x"
    "git -C ../wt push origin feat/y:refs/heads/feat/y"
    "pytest test/pytest"
  )
}

teardown() {
  rm -rf "${WORK}"
}

# input_at <cwd> <指令文字>：照 Claude Code 給 PreToolUse hook 的形狀寫出 JSON（Bash 工具）。
input_at() {
  python3 -c '
import json, sys
print(json.dumps({
    "session_id": "spec",
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[1], "description": "spec"},
    "cwd": sys.argv[2],
}))' "$2" "$1" >"${WORK}/input.json"
}

# hook <指令文字>：把 Bash 工具的輸入餵給 host-push-rules.sh，cwd 是 ${WORK}。
hook() {
  input_at "${WORK}" "$1"
  run "${HOOK}" <"${WORK}/input.json"
}

# decide <cwd> <指令文字> [<執行 hook 的前綴>…]：印出那條指令的結束碼與訊息（多條指令的結果拿來整段比對）。
decide() {
  local cwd="$1" command="$2" code=0
  shift 2
  input_at "${cwd}" "${command}"
  "$@" "${HOOK}" <"${WORK}/input.json" >"${WORK}/out.txt" 2>&1 || code=$?
  printf '%s => %s\n' "${command}" "${code}"
  cat "${WORK}/out.txt"
}

# transcript <cwd> [<執行 hook 的前綴>…]：SAMPLES 每一條的結束碼與訊息。
transcript() {
  local cwd="$1" command
  shift
  for command in "${SAMPLES[@]}"; do
    decide "${cwd}" "${command}" "$@"
  done
}

# repo <目錄>：建一個有一個 commit 的 git repo（只有規格自己呼叫 git；hook 不呼叫）。
repo() {
  git init -q "$1"
  git -C "$1" -c user.name=spec -c user.email=spec@example.invalid commit -q --allow-empty -m init
  git -C "$1" remote add origin https://github.com/o/r.git
}

# ── 主機檢查：檢查工具一律在容器裡跑 ──────────────────────────────────────

@test "pytest test/pytest 以 2 擋下，下一步寫改用 ./script/test.sh 或看 GitHub CI" {
  hook "pytest test/pytest"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_HOST}"* ]]
}

@test "cd 之後的 ruff check src 也以 2 擋下並寫出下一步" {
  hook "cd x && ruff check src"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_HOST}"* ]]
}

@test "python3 -m mypy src 以 2 擋下並寫出下一步" {
  hook "python3 -m mypy src"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_HOST}"* ]]
}

@test "python -m pytest 以 2 擋下" {
  hook "python -m pytest test/pytest"

  [ "${status}" -eq 2 ]
}

@test "-m 前面有別的直譯器旗標的 python3 -B -m pylint src 以 2 擋下" {
  hook "python3 -B -m pylint src"

  [ "${status}" -eq 2 ]
}

@test "-m 與模組名連寫的 python3 -mruff check src 以 2 擋下" {
  hook "python3 -mruff check src"

  [ "${status}" -eq 2 ]
}

@test "mypy --strict src/config_manager 以 2 擋下" {
  hook "mypy --strict src/config_manager"

  [ "${status}" -eq 2 ]
}

@test "pylint src 以 2 擋下" {
  hook "pylint src"

  [ "${status}" -eq 2 ]
}

@test "bats test/bats/unit 以 2 擋下" {
  hook "bats test/bats/unit"

  [ "${status}" -eq 2 ]
}

@test "shellcheck script/test.sh 以 2 擋下" {
  hook "shellcheck script/test.sh"

  [ "${status}" -eq 2 ]
}

@test "hadolint docker/Dockerfile 以 2 擋下" {
  hook "hadolint docker/Dockerfile"

  [ "${status}" -eq 2 ]
}

@test "actionlint 以 2 擋下" {
  hook "actionlint"

  [ "${status}" -eq 2 ]
}

@test "用路徑呼叫的 .venv/bin/pytest 以 2 擋下" {
  hook ".venv/bin/pytest test/pytest"

  [ "${status}" -eq 2 ]
}

@test "開頭有環境變數設定的 PYTHONPATH=src pytest 以 2 擋下：略過開頭的變數設定" {
  hook "PYTHONPATH=src pytest test/pytest"

  [ "${status}" -eq 2 ]
}

@test "放在 || 後面的 pytest 以 2 擋下" {
  hook "ls || pytest test/pytest"

  [ "${status}" -eq 2 ]
}

@test "放在 ; 後面的 mypy 以 2 擋下" {
  hook "echo ok; mypy src"

  [ "${status}" -eq 2 ]
}

@test "放在管線 | 後面的 ruff 以 2 擋下" {
  hook "cat src/a.py | ruff check -"

  [ "${status}" -eq 2 ]
}

@test "CM_TEST_LOCAL=1 放在 pytest 前面也以 2 擋下，下一步指向 CM_TEST_LOCAL=1 ./script/test.sh" {
  hook "CM_TEST_LOCAL=1 pytest test/pytest"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"CM_TEST_LOCAL=1 ./script/test.sh"* ]]
}

@test "./script/test.sh --lint 放行" {
  hook "./script/test.sh --lint"

  [ "${status}" -eq 0 ]
}

@test "CM_TEST_LOCAL=1 ./script/test.sh 放行" {
  hook "CM_TEST_LOCAL=1 ./script/test.sh"

  [ "${status}" -eq 0 ]
}

@test "python3 -m pip install 這類不是檢查工具的模組放行" {
  hook "python3 -m pip install --user build"

  [ "${status}" -eq 0 ]
}

@test "python3 執行腳本放行" {
  hook "python3 script/x.py --check"

  [ "${status}" -eq 0 ]
}

@test "只在參數裡提到 pytest 的 grep 放行" {
  hook "grep -n pytest pyproject.toml"

  [ "${status}" -eq 0 ]
}

# ── 推送：批次推送與清單外的旗標（refspec 都寫完整，擋下的原因是那個旗標） ─────

@test "git push --branches 以 2 擋下，指名 --branches，下一步寫只用這些旗標" {
  hook "git push --branches origin a:refs/heads/a"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--branches"*"下一步"*"${STEP_FLAGS}"* ]]
}

@test "git push --all 以 2 擋下，指名 --all，下一步寫只用這些旗標" {
  hook "git push --all origin a:refs/heads/a"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--all"*"下一步"*"${STEP_FLAGS}"* ]]
}

@test "git push --recurse-submodules=on-demand 以 2 擋下，指名那個旗標，下一步寫只用這些旗標" {
  hook "git push --recurse-submodules=on-demand origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--recurse-submodules=on-demand"*"下一步"*"${STEP_FLAGS}"* ]]
}

@test "git push --no-verify 以 2 擋下，指名 --no-verify，下一步寫只用這些旗標" {
  hook "git push --no-verify origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--no-verify"*"下一步"*"${STEP_FLAGS}"* ]]
}

@test "refspec 都寫完整時，擋下 --all 的訊息裡沒有 refspec 的下一步" {
  hook "git push --all origin a:refs/heads/a"

  [[ "${output}" != *"${STEP_REFSPEC}"* ]]
}

@test "縮寫的長旗標 --dry 不在清單裡，以 2 擋下" {
  hook "git push --dry origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--dry"*"${STEP_FLAGS}"* ]]
}

# ── 推送：目的地不明確 ────────────────────────────────────────────────────

@test "沒寫 remote 與 refspec 的 git push 以 2 擋下，下一步寫每個 refspec 寫成完整的目的地" {
  hook "git push"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_REFSPEC}"* ]]
}

@test "只寫 remote 的 git push origin 以 2 擋下並寫出 refspec 的下一步" {
  hook "git push origin"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_REFSPEC}"* ]]
}

@test "refspec 沒寫 :<目的地> 的 git push -u origin feat/x 以 2 擋下並寫出 refspec 的下一步" {
  hook "git push -u origin feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_REFSPEC}"* ]]
}

@test "matching 的 git push origin : 以 2 擋下並寫出 refspec 的下一步" {
  hook "git push origin :"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_REFSPEC}"* ]]
}

@test "含萬用字元的 refspec 以 2 擋下並寫出 refspec 的下一步" {
  hook "git push origin 'refs/heads/*:refs/heads/*'"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_REFSPEC}"* ]]
}

@test "沒寫 refspec 的 git push --all origin 以 2 擋下，兩個下一步都寫出" {
  hook "git push --all origin"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_REFSPEC}"* && "${output}" == *"${STEP_FLAGS}"* ]]
}

@test "沒寫 refspec 的 git push --tags origin 以 2 擋下，兩個下一步都寫出" {
  hook "git push --tags origin"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_REFSPEC}"* && "${output}" == *"${STEP_FLAGS}"* ]]
}

@test "git push --prune 以 2 擋下，指名 --prune，下一步寫只用這些旗標" {
  hook "git push --prune origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--prune"*"${STEP_FLAGS}"* ]]
}

@test "第一個位置參數就是 refspec 時，它被當成 remote，沒有 refspec，以 2 擋下" {
  hook "git push feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_REFSPEC}"* ]]
}

# ── 推送：目的地不是寫死的完整 ref ────────────────────────────────────────

@test "目的地是短名的 git push origin feat/x:feat/x 以 2 擋下並寫出 refspec 的下一步" {
  hook "git push origin feat/x:feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_REFSPEC}"* ]]
}

@test "目的地是 HEAD 的 git push origin feat/x:HEAD 以 2 擋下並寫出 refspec 的下一步" {
  hook "git push origin feat/x:HEAD"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_REFSPEC}"* ]]
}

@test "目的地含 shell 變數的 refspec 以 2 擋下並寫出 refspec 的下一步" {
  hook "git push origin \"feat/x:refs/heads/\$BR\""

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_REFSPEC}"* ]]
}

@test "目的地 refs/heads/ 後面沒有名稱時以 2 擋下" {
  hook "git push origin feat/x:refs/heads/"

  [ "${status}" -eq 2 ]
}

@test "目的地在 refs/heads/、refs/tags/ 以外（refs/notes/x）時以 2 擋下" {
  hook "git push origin feat/x:refs/notes/x"

  [ "${status}" -eq 2 ]
}

@test "remote 來自 shell 變數時以 2 擋下" {
  hook "git push \"\$REMOTE\" feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
}

# ── 推送：推到 main ───────────────────────────────────────────────────────

@test "git push origin feat/x:refs/heads/main 以 2 擋下，下一步寫不能推到 main" {
  hook "git push origin feat/x:refs/heads/main"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_MAIN}"* ]]
}

@test "刪除 main 的 git push origin :refs/heads/main 以 2 擋下，下一步寫不能推到 main" {
  hook "git push origin :refs/heads/main"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_MAIN}"* ]]
}

@test "多個目的地裡有一個是 main 時以 2 擋下，下一步寫不能推到 main" {
  hook "git push origin a:refs/heads/a b:refs/heads/main"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_MAIN}"* ]]
}

@test "來源是 main、目的地是自己的分支時放行：只看目的地" {
  hook "git push origin main:refs/heads/feat/x"

  [ "${status}" -eq 0 ]
}

# ── 推送：強制推送 ────────────────────────────────────────────────────────

@test "git push -f 以 2 擋下，下一步寫改用 --force-with-lease" {
  hook "git push -f origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"*"${STEP_LEASE}"* ]]
}

@test "--force 與 --force-with-lease 一起寫時以 2 擋下，下一步寫改用 --force-with-lease" {
  hook "git push --force --force-with-lease origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_LEASE}"* ]]
}

@test "+ 開頭的 refspec 以 2 擋下，下一步寫改用 --force-with-lease" {
  hook "git push origin +feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_LEASE}"* ]]
}

@test "--no-force-with-lease 取消 lease 時以 2 擋下，下一步寫改用 --force-with-lease" {
  hook "git push --force-with-lease --no-force-with-lease origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_LEASE}"* ]]
}

@test "和別的短旗標連寫的 -uf 以 2 擋下，下一步寫改用 --force-with-lease" {
  hook "git push -uf origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_LEASE}"* ]]
}

# ── 推送：刪除模式 ────────────────────────────────────────────────────────

@test "git push --delete origin refs/heads/feat/x 放行" {
  hook "git push --delete origin refs/heads/feat/x"

  [ "${status}" -eq 0 ]
}

@test "git push --delete origin refs/heads/main 以 2 擋下，下一步寫不能推到 main" {
  hook "git push --delete origin refs/heads/main"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_MAIN}"* ]]
}

@test "刪除模式寫短名的 git push --delete origin feat/x 以 2 擋下，下一步寫完整的 ref" {
  hook "git push --delete origin feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"${STEP_DELETE}"* ]]
}

@test "刪除模式的 -d 一樣照刪除模式判斷：git push -d origin feat/x 以 2 擋下" {
  hook "git push -d origin feat/x"

  [ "${status}" -eq 2 ]
}

# ── 推送：放行 ────────────────────────────────────────────────────────────

@test "git push -u origin feat/x:refs/heads/feat/x 放行" {
  hook "git push -u origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 0 ]
}

@test "多個目的地都寫完整的 git push origin a:refs/heads/a b:refs/heads/b 放行" {
  hook "git push origin a:refs/heads/a b:refs/heads/b"

  [ "${status}" -eq 0 ]
}

@test "git push --force-with-lease origin feat/x:refs/heads/feat/x 放行" {
  hook "git push --force-with-lease origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 0 ]
}

@test "只點名一個 ref 的 --force-with-lease=refs/heads/a 推兩個目的地時放行（b 沒有 lease，照 git 只能 fast-forward）" {
  hook "git push --force-with-lease=refs/heads/a origin a:refs/heads/a b:refs/heads/b"

  [ "${status}" -eq 0 ]
}

@test "git -C ../wt push origin feat/y:refs/heads/feat/y 放行" {
  hook "git -C ../wt push origin feat/y:refs/heads/feat/y"

  [ "${status}" -eq 0 ]
}

@test "推 tag 的 git push origin v1.0.0:refs/tags/v1.0.0 放行" {
  hook "git push origin v1.0.0:refs/tags/v1.0.0"

  [ "${status}" -eq 0 ]
}

@test "清單裡的旗標都用上時放行" {
  hook "git push -n -v -q --porcelain --progress --atomic --force-if-includes --force-with-lease -o ci.skip --recurse-submodules=check origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 0 ]
}

@test "--no-recurse-submodules 與 --recurse-submodules=no 放行" {
  hook "git push --no-recurse-submodules --recurse-submodules=no origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 0 ]
}

# ── 推送：git 的全域選項與 git 設定 ───────────────────────────────────────

@test "git -c 在這次推送改 git 設定時以 2 擋下並寫出下一步" {
  hook "git -c push.followTags=true push origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"-c"*"下一步"* ]]
}

@test "推送前以 GIT_CONFIG_ 開頭的環境變數改 git 設定時以 2 擋下" {
  hook "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.mirror GIT_CONFIG_VALUE_0=true git push origin feat/x:refs/heads/feat/x"

  [ "${status}" -eq 2 ]
}

@test "主 checkout 與它的 worktree 裡，判斷結果相同" {
  repo "${WORK}/main"
  git -C "${WORK}/main" worktree add -q -b feat/y "${WORK}/wt"

  [ "$(transcript "${WORK}/main")" = "$(transcript "${WORK}/wt")" ]
}

@test "設了 push.followTags=true 與 remote.origin.mirror=true 的 repo 裡，判斷結果和沒設的 repo 相同" {
  repo "${WORK}/plain"
  repo "${WORK}/configured"
  git -C "${WORK}/configured" config push.followTags true
  git -C "${WORK}/configured" config remote.origin.mirror true

  [ "$(transcript "${WORK}/plain")" = "$(transcript "${WORK}/configured")" ]
}

@test "PATH 上沒有 git 時判斷結果照樣：hook 不呼叫 git" {
  mkdir "${WORK}/bin"
  ln -s "$(command -v python3)" "${WORK}/bin/python3"
  ln -s "$(command -v cat)" "${WORK}/bin/cat"

  [ "$(transcript "${WORK}")" = "$(transcript "${WORK}" env -i PATH="${WORK}/bin" "$(command -v bash)")" ]
}

# ── 指令的結構 ────────────────────────────────────────────────────────────

@test "放在 bash -c 裡的 git push origin 以 2 擋下" {
  hook "bash -c 'git push origin'"

  [ "${status}" -eq 2 ]
}

@test "交給 xargs 執行的 git push 以 2 擋下" {
  hook "echo feat/x | xargs git push origin"

  [ "${status}" -eq 2 ]
}

@test "子指令來自 shell 變數的 git 以 2 擋下" {
  hook "git \$SUB origin feat/x:refs/heads/feat/x push"

  [ "${status}" -eq 2 ]
}

@test "commit 訊息裡提到 git push origin 放行：那不是 git push" {
  hook "git commit -m 'git push origin 之前先 rebase'"

  [ "${status}" -eq 0 ]
}

@test "讀不懂結構的 git push（引號沒有結束）以 2 擋下" {
  hook "git push \"origin"

  [ "${status}" -eq 2 ]
}

@test "沒有 git、也沒有檢查工具的指令放行" {
  hook "ls -la && echo ok"

  [ "${status}" -eq 0 ]
}

@test "hook 的輸入是空的時以 2 擋下並寫出下一步" {
  run "${HOOK}" </dev/null

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"* ]]
}

@test "hook 的輸入不是 JSON 時以 2 擋下並寫出下一步" {
  printf 'not json\n' >"${WORK}/input.json"

  run "${HOOK}" <"${WORK}/input.json"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"下一步"* ]]
}

@test "PATH 上沒有 python3 時以 2 擋下並寫出下一步" {
  mkdir "${WORK}/nopy"
  input_at "${WORK}" "git push origin"

  run env -i PATH="${WORK}/nopy" "$(command -v bash)" "${HOOK}" <"${WORK}/input.json"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"python3"*"下一步"* ]]
}

# ── repo 設定 ─────────────────────────────────────────────────────────────

@test ".claude/settings.json 以 PreToolUse 的 Bash matcher 呼叫 host-push-rules.sh" {
  run python3 -c '
import json, sys
settings = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in settings.get("hooks", {}).get("PreToolUse", []):
    if entry.get("matcher") != "Bash":
        continue
    for hook in entry.get("hooks", []):
        if hook.get("type") == "command" and "script/claude-hooks/host-push-rules.sh" in hook.get("command", ""):
            print("wired")' "${REPO_ROOT}/.claude/settings.json"

  [ "${status}" -eq 0 ]
  [ "${output}" = "wired" ]
}
