#!/usr/bin/env bats
#
# .githooks/ 與 script/githook.sh —— git 給 hook 的東西有沒有完整交到每一支登記的檢查，以及主機缺工具時
# 有沒有擋下（T19、#391、#406）。
#
# git 在主機上觸發 hook，登記的檢查（script/githook-checks/<進入點>/ 底下的可執行檔）也在這台主機上直接跑，
# 不經 docker（#406）。規格以**真的 git** 觸發：真的 `git commit`、對一個本機 bare repo 的真的 `git push`，
# 一般簽出與 worktree 各一次。登記測試用的檢查，把它收到的參數、標準輸入與訊息檔內容寫下來，與 git 給的比對。
#
# 主機缺什麼以**重建 PATH** 造出來（path_without）：command -v 是 shell 內建，覆寫不掉。bash 低於 4 以 PATH
# 最前面一支只回報主版本 3 的假 bash 造出來（old_bash）：登記的檢查以 `#!/usr/bin/env bash` 啟動，用的是
# PATH 上先找到的那一支。
#
# 擋不住的：主機工具與檢查映像不同造成的差異（規格跑在映像裡，CI 是最後一道）；githook.sh 自己在真的
# bash 3.2 底下跑到印出說明那一步（映像裡沒有 bash 3.2）。見 doc/TEST-PLAN.md T19。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  RECORD="${WORK}/record"
  REAL_BASH="$(command -v bash)"
  mkdir -p "${RECORD}" "${WORK}/home"
  export HOME="${WORK}/home"
  export GIT_AUTHOR_NAME=spec GIT_AUTHOR_EMAIL=spec@example.com
  export GIT_COMMITTER_NAME=spec GIT_COMMITTER_EMAIL=spec@example.com

  # 一份真的簽出：被測的兩個進入點與 githook.sh 照 repo 裡的樣子放進去。
  MAIN="${WORK}/main"
  mkdir -p "${MAIN}/script" "${MAIN}/.githooks"
  cp "${REPO_ROOT}/script/githook.sh" "${MAIN}/script/"
  cp "${REPO_ROOT}/.githooks/commit-msg" "${REPO_ROOT}/.githooks/pre-push" "${MAIN}/.githooks/"
  git init -q -b main "${MAIN}"
  git -C "${MAIN}" add -A
  git -C "${MAIN}" commit -q -m "chore: fixture"
  git -C "${MAIN}" config core.hooksPath .githooks
}

teardown() {
  rm -rf "${WORK}"
}

# register <進入點> <檔名> <腳本主體>：登記一支檢查並提交，worktree 簽出時也有它。
register() {
  local entry="$1" name="$2" body="$3"
  mkdir -p "${MAIN}/script/githook-checks/${entry}"
  printf '#!/usr/bin/env bash\n%s\n' "${body}" >"${MAIN}/script/githook-checks/${entry}/${name}"
  chmod +x "${MAIN}/script/githook-checks/${entry}/${name}"
  git -C "${MAIN}" add -A
  git -C "${MAIN}" commit -q --no-verify -m "chore: register ${name}"
}

# recorder <名稱>：一支檢查的主體，把收到的參數、標準輸入與（commit-msg 的）訊息檔內容寫進 RECORD/<名稱>/。
recorder() {
  local out="${RECORD}/$1"
  mkdir -p "${out}"
  printf 'printf "%%s\\n" "$@" >"%s/args"\ncat >"%s/stdin"\n[[ -f "${1:-}" ]] && cp "$1" "%s/message"\nexit 0' \
    "${out}" "${out}" "${out}"
}

# 照 repo 實際登記的 commit-msg 檢查，連同它們轉交的兩支判定與樣式清單，放進簽出並提交。
real_commit_msg_checks() {
  mkdir -p "${MAIN}/script/githook-checks/commit-msg"
  cp "${REPO_ROOT}/script/githook-checks/commit-msg/"* "${MAIN}/script/githook-checks/commit-msg/"
  cp "${REPO_ROOT}/script/lint_single_task.sh" "${REPO_ROOT}/script/lint_attribution.sh" \
    "${REPO_ROOT}/script/attribution-patterns.txt" "${MAIN}/script/"
  git -C "${MAIN}" add -A
  git -C "${MAIN}" commit -q --no-verify -m "chore: 照 repo 登記的 commit-msg 檢查"
}

# path_without <名稱…>：印出一個 PATH 目錄，裡面是現在 PATH 上每一個指令的連結（同名的以 PATH 上先找到的
# 為準），只拿掉指定的名稱。PATH 只設這一個目錄，拿掉的那幾個就找不到。
path_without() {
  local dir="${WORK}/path-without"
  local -a dirs=()
  local i name
  rm -rf "${dir}"
  mkdir -p "${dir}"
  IFS=: read -r -a dirs <<<"${PATH}"
  for ((i = ${#dirs[@]} - 1; i >= 0; i--)); do
    [[ -d "${dirs[i]}" ]] || continue
    ln -sf "${dirs[i]}"/* "${dir}/" 2>/dev/null || true
  done
  for name in "$@"; do
    rm -f "${dir:?}/${name}"
  done
  [[ -x "${dir}/env" ]] || return 1
  printf '%s' "${dir}"
}

# old_bash：印出一個目錄，裡面一支假的 bash，模擬 PATH 上先找到的是 macOS 內建的 bash 3.2：被問版本
# （--version，或 bash -c 讀 BASH_VERSINFO／BASH_VERSION）時回答 3.2；拿它執行任何別的東西都失敗——有登記的
# 檢查被它啟動，就看得出來。
old_bash() {
  local dir="${WORK}/old-bash"
  mkdir -p "${dir}"
  {
    printf '#!%s\n' "${REAL_BASH}"
    printf 'case "${1:-} ${2:-}" in\n'
    printf '  "--version "*) printf "GNU bash, version 3.2.57(1)-release (arm64-apple-darwin23)\\n"; exit 0 ;;\n'
    printf '  "-c "*BASH_VERSINFO*) printf 3; exit 0 ;;\n'
    printf '  "-c "*BASH_VERSION*) printf "3.2.57(1)-release"; exit 0 ;;\n'
    printf 'esac\n'
    printf 'printf "假的 bash 3.2 不執行：%%s\\n" "$*" >&2\n'
    printf 'exit 126\n'
  } >"${dir}/bash"
  chmod +x "${dir}/bash"
  printf '%s' "${dir}"
}

# given_is_commit_editmsg <簽出> <記下的參數>：git 給的路徑（相對的以簽出的根目錄為準）是不是那份簽出的
# git 目錄裡的 COMMIT_EDITMSG。
given_is_commit_editmsg() {
  local checkout="$1" given="$2"
  [[ "${given}" == /* ]] || given="${checkout}/${given}"
  [ "${given}" -ef "$(git -C "${checkout}" rev-parse --absolute-git-dir)/COMMIT_EDITMSG" ]
}

@test "沒有登記任何檢查時 commit-msg 以 0 結束並說明" {
  run git -C "${MAIN}" commit --allow-empty -m "chore: 沒有檢查"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"沒有登記"* ]]
}

@test "沒有登記任何檢查時，主機找不到 python3 也以 0 結束" {
  local path
  path="$(path_without python3)"
  [ ! -e "${path}/python3" ]

  run env PATH="${path}" git -C "${MAIN}" commit --allow-empty -m "chore: 沒有 python3 也沒有檢查"

  [ "${status}" -eq 0 ]
}

@test "PATH 上沒有 docker 時，直接執行 githook.sh commit-msg <檔> 仍會執行登記的檢查" {
  register commit-msg 10-record "$(recorder record)"
  printf 'chore: 直接執行\n' >"${WORK}/msg"
  local path
  path="$(path_without docker)"
  [ ! -e "${path}/docker" ]

  run env PATH="${path}" "${MAIN}/script/githook.sh" commit-msg "${WORK}/msg"

  [ "${status}" -eq 0 ]
  [ "$(cat "${RECORD}/record/message")" = "chore: 直接執行" ]
}

@test "一般簽出裡 git commit 時，登記的檢查收到 git 給的訊息檔路徑，讀得到這次的 commit 訊息" {
  register commit-msg 10-record "$(recorder record)"

  run git -C "${MAIN}" commit --allow-empty -m "chore: 一般簽出的訊息"

  [ "${status}" -eq 0 ]
  given_is_commit_editmsg "${MAIN}" "$(head -n 1 "${RECORD}/record/args")"
  [ "$(head -n 1 "${RECORD}/record/message")" = "chore: 一般簽出的訊息" ]
}

@test "worktree 裡 git commit 時，登記的檢查收到 git 給的訊息檔路徑，讀得到這次的 commit 訊息" {
  register commit-msg 10-record "$(recorder record)"
  git -C "${MAIN}" worktree add -q "${WORK}/wt"

  run git -C "${WORK}/wt" commit --allow-empty -m "chore: worktree 的訊息"

  [ "${status}" -eq 0 ]
  given_is_commit_editmsg "${WORK}/wt" "$(head -n 1 "${RECORD}/record/args")"
  [ "$(head -n 1 "${RECORD}/record/message")" = "chore: worktree 的訊息" ]
}

@test "一般簽出裡一次 git push 兩個 ref 時，兩支檢查都收到相同的兩個參數與完整的標準輸入" {
  register pre-push 10-first "$(recorder first)"
  register pre-push 20-second "$(recorder second)"
  git -C "${MAIN}" branch other
  git init -q --bare "${WORK}/remote.git"
  git -C "${MAIN}" remote add origin "${WORK}/remote.git"
  local sha zero args stdin
  sha="$(git -C "${MAIN}" rev-parse refs/heads/main)"
  zero="$(printf '%0*d' "${#sha}" 0)"
  args="$(printf 'origin\n%s' "${WORK}/remote.git")"
  stdin="$(printf 'refs/heads/main %s refs/heads/main %s\nrefs/heads/other %s refs/heads/other %s' \
    "${sha}" "${zero}" "${sha}" "${zero}")"

  run git -C "${MAIN}" push -q origin main:main other:other

  [ "${status}" -eq 0 ]
  [ "$(cat "${RECORD}/first/args")" = "${args}" ]
  [ "$(cat "${RECORD}/second/args")" = "${args}" ]
  [ "$(cat "${RECORD}/first/stdin")" = "${stdin}" ]
  [ "$(cat "${RECORD}/second/stdin")" = "${stdin}" ]
}

@test "worktree 裡一次 git push 兩個 ref 時，兩支檢查都收到相同的兩個參數與完整的標準輸入" {
  register pre-push 10-first "$(recorder first)"
  register pre-push 20-second "$(recorder second)"
  git init -q --bare "${WORK}/remote.git"
  git -C "${MAIN}" remote add origin "${WORK}/remote.git"
  git -C "${MAIN}" worktree add -q -b wt-branch "${WORK}/wt"
  git -C "${WORK}/wt" branch wt-other
  local sha zero args stdin
  sha="$(git -C "${WORK}/wt" rev-parse HEAD)"
  zero="$(printf '%0*d' "${#sha}" 0)"
  args="$(printf 'origin\n%s' "${WORK}/remote.git")"
  stdin="$(printf 'refs/heads/wt-branch %s refs/heads/wt-branch %s\nrefs/heads/wt-other %s refs/heads/wt-other %s' \
    "${sha}" "${zero}" "${sha}" "${zero}")"

  run git -C "${WORK}/wt" push -q origin wt-branch:wt-branch wt-other:wt-other

  [ "${status}" -eq 0 ]
  [ "$(cat "${RECORD}/first/args")" = "${args}" ]
  [ "$(cat "${RECORD}/second/args")" = "${args}" ]
  [ "$(cat "${RECORD}/first/stdin")" = "${stdin}" ]
  [ "$(cat "${RECORD}/second/stdin")" = "${stdin}" ]
}

@test "登記了兩支檢查時依檔名順序都執行" {
  register commit-msg 20-second "printf '20-second\n' >>\"${RECORD}/order\""
  register commit-msg 10-first "printf '10-first\n' >>\"${RECORD}/order\""

  run git -C "${MAIN}" commit --allow-empty -m "chore: 兩支檢查"

  [ "${status}" -eq 0 ]
  [ "$(cat "${RECORD}/order")" = "$(printf '10-first\n20-second')" ]
}

@test "兩支檢查都失敗時 hook 非零結束，逐支列出兩支與它們的原因、不提 docker，git commit 沒有產生新的 commit" {
  register commit-msg 10-refuse-a "printf '原因甲：主旨裡有兩個 F 項\n' >&2; exit 1"
  register commit-msg 20-refuse-b "printf '原因乙：訊息裡有署名\n' >&2; exit 3"
  local before
  before="$(git -C "${MAIN}" rev-parse HEAD)"

  run git -C "${MAIN}" commit --allow-empty -m "chore: 會被擋下"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"原因甲：主旨裡有兩個 F 項"* && "${output}" == *"原因乙：訊息裡有署名"* ]]
  [[ "${output}" == *"10-refuse-a"* && "${output}" == *"20-refuse-b"* ]]
  [[ "${output}" != *"docker"* ]]
  [ "$(git -C "${MAIN}" rev-parse HEAD)" = "${before}" ]
}

@test "有登記的檢查、PATH 上先找到的 bash 低於 4 時非零結束並寫出下一步，不執行檢查" {
  register commit-msg 10-record "$(recorder record)"
  printf 'chore: 舊的 bash\n' >"${WORK}/msg"

  run env PATH="$(old_bash):${PATH}" "${REAL_BASH}" "${MAIN}/script/githook.sh" commit-msg "${WORK}/msg"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"bash 4"* && "${output}" == *"下一步"*"brew install bash"* ]]
  [[ "${output}" != *"docker"* ]]
  [ ! -e "${RECORD}/record/args" ]
}

@test "有登記的檢查、PATH 上找不到 python3 時非零結束並寫出下一步，不執行檢查，git commit 沒有產生新的 commit" {
  register commit-msg 10-record "$(recorder record)"
  local path before
  path="$(path_without python3)"
  before="$(git -C "${MAIN}" rev-parse HEAD)"

  run env PATH="${path}" git -C "${MAIN}" commit --allow-empty -m "chore: 沒有 python3"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"找不到 python3"*"下一步"* ]]
  [ ! -e "${RECORD}/record/args" ]
  [ "$(git -C "${MAIN}" rev-parse HEAD)" = "${before}" ]
}

@test "有登記的檢查、PATH 上找不到 git 時非零結束並寫出下一步，不執行檢查" {
  register commit-msg 10-record "$(recorder record)"
  printf 'chore: 沒有 git\n' >"${WORK}/msg"
  local path
  path="$(path_without git)"
  [ ! -e "${path}/git" ]

  run env PATH="${path}" "${MAIN}/script/githook.sh" commit-msg "${WORK}/msg"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"找不到 git"*"下一步"* ]]
  [ ! -e "${RECORD}/record/args" ]
}

@test "照 repo 登記的 commit-msg 檢查，乾淨的訊息照樣產生新的 commit" {
  real_commit_msg_checks
  local before
  before="$(git -C "${MAIN}" rev-parse HEAD)"

  run git -C "${MAIN}" commit --allow-empty -m "chore(githook): 乾淨的訊息（#406）"

  [ "${status}" -eq 0 ]
  [ "$(git -C "${MAIN}" rev-parse HEAD)" != "${before}" ]
}

@test "照 repo 登記的 commit-msg 檢查，訊息含署名時 20-no-attribution.sh 擋下並印出原因，沒有產生新的 commit" {
  real_commit_msg_checks
  local coauthor before
  coauthor="Co-Authored-By"": Claude <noreply@anthropic.com>"
  printf 'chore(githook): 帶署名的訊息（#406）\n\n%s\n' "${coauthor}" >"${WORK}/msg"
  before="$(git -C "${MAIN}" rev-parse HEAD)"

  run git -C "${MAIN}" commit --allow-empty -F "${WORK}/msg"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"20-no-attribution.sh"* && "${output}" == *"^Co-Authored-By:"* ]]
  [ "$(git -C "${MAIN}" rev-parse HEAD)" = "${before}" ]
}

@test "repo 裡沒有任何一處寫著 git hook 的檢查要經 script/test.sh 的 hook 入口執行" {
  run git -C "${REPO_ROOT}" grep -n -e 'test\.sh --hook' -- .

  [ "${status}" -eq 1 ]
}
