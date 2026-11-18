#!/usr/bin/env bats
#
# .githooks/、script/githook.sh 與 script/test.sh --hook —— git 給 hook 的東西有沒有完整到達
# 容器裡的檢查（T19、#391）。
#
# git 在主機上觸發 hook，登記的檢查（script/githook-checks/<進入點>/ 底下的可執行檔）在檢查
# 映像裡跑。規格以**真的 git** 觸發：真的 `git commit`、對一個本機 bare repo 的真的 `git push`，
# 一般簽出與 worktree 各一次。
#
# PATH 上的 docker 是一個**轉接**：記下參數；建映像直接成功；`docker run` 則把映像後面那段指令
# 在 --volume 掛到 /repo 的那份簽出裡、以 CM_IN_TEST_IMAGE=1 執行，而且**只有參數帶 -i 時才把
# 標準輸入接過去**——少了 -i，真的 docker run 也收不到標準輸入。登記一支測試用的檢查，把它收到的
# 參數、標準輸入與訊息檔內容寫下來，與 git 給的比對。
#
# 擋不住的：真的容器裡 worktree 的訊息檔經掛載讀得到（轉接跑在同一個檔案系統上）。掛載由
# test.bats 的那兩條（#103）觀察，真的容器那一次由 #391 的 PR 在 CI 上實跑留證據。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  BIN="${WORK}/bin"
  RECORD="${WORK}/record"
  DOCKER_ARGV="${WORK}/docker-argv"
  mkdir -p "${BIN}" "${RECORD}" "${WORK}/home"
  export HOME="${WORK}/home"
  export GIT_AUTHOR_NAME=spec GIT_AUTHOR_EMAIL=spec@example.com
  export GIT_COMMITTER_NAME=spec GIT_COMMITTER_EMAIL=spec@example.com
  unset CM_TEST_LOCAL

  # 一份真的簽出：被測的三支（兩個進入點、githook.sh、test.sh）照 repo 裡的樣子放進去。
  MAIN="${WORK}/main"
  mkdir -p "${MAIN}/script" "${MAIN}/.githooks"
  cp "${REPO_ROOT}/script/test.sh" "${REPO_ROOT}/script/githook.sh" "${MAIN}/script/"
  cp "${REPO_ROOT}/.githooks/commit-msg" "${REPO_ROOT}/.githooks/pre-push" "${MAIN}/.githooks/"
  git init -q -b main "${MAIN}"
  git -C "${MAIN}" add -A
  git -C "${MAIN}" commit -q -m "chore: fixture"
  git -C "${MAIN}" config core.hooksPath .githooks
}

teardown() {
  rm -rf "${WORK}"
}

# 轉接的 docker。$1 是 `docker run` 要回的結束碼（不給就照跑那段指令）。
passthrough_docker() {
  local run_status="${1:-}"
  cat >"${BIN}/docker" <<DOCKER
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"${DOCKER_ARGV}"
[[ "\$1" == run ]] || exit 0
shift
if [[ -n "${run_status}" ]]; then
  printf 'docker: Error response from daemon: 假的失敗\n' >&2
  exit ${run_status}
fi
interactive=0 repo="" envs=()
while ((\$# > 0)); do
  case "\$1" in
    -i | --interactive) interactive=1; shift ;;
    --rm) shift ;;
    --env) envs+=("\$2"); shift 2 ;;
    --volume) [[ "\$2" == *:/repo ]] && repo="\${2%:/repo}"; shift 2 ;;
    --workdir) shift 2; break ;;
    *) shift 2 ;;
  esac
done
shift
cd "\${repo}" || exit 1
if ((interactive)); then
  exec env CM_IN_TEST_IMAGE=1 "\${envs[@]}" "\$@"
fi
exec env CM_IN_TEST_IMAGE=1 "\${envs[@]}" "\$@" </dev/null
DOCKER
  chmod +x "${BIN}/docker"
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

# 把收到的參數、標準輸入與（commit-msg 的）訊息檔內容寫進 RECORD。
recorder_body() {
  printf 'printf "%%s\\n" "$@" >"%s/args"\ncat >"%s/stdin"\n[[ -f "${1:-}" ]] && cp "$1" "%s/message"\nexit 0' \
    "${RECORD}" "${RECORD}" "${RECORD}"
}

# 以受控的 PATH（轉接的 docker 在最前面）跑一道 git 指令。
in_repo() {
  run env PATH="${BIN}:${PATH}" "$@"
}

@test "沒有登記任何檢查時 commit-msg 以 0 結束並說明，docker 沒有被呼叫" {
  passthrough_docker

  in_repo git -C "${MAIN}" commit --allow-empty -m "chore: 沒有檢查"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"沒有登記"* ]]
  [ ! -e "${DOCKER_ARGV}" ]
}

@test "一般簽出裡 git commit 時，登記的檢查讀得到這次的 commit 訊息" {
  passthrough_docker
  register commit-msg 10-record "$(recorder_body)"

  in_repo git -C "${MAIN}" commit --allow-empty -m "chore: 一般簽出的訊息"

  [ "${status}" -eq 0 ]
  [ "$(head -n 1 "${RECORD}/message")" = "chore: 一般簽出的訊息" ]
}

@test "worktree 裡 git commit 時，登記的檢查讀得到這次的 commit 訊息" {
  passthrough_docker
  register commit-msg 10-record "$(recorder_body)"
  git -C "${MAIN}" worktree add -q "${WORK}/wt"

  in_repo git -C "${WORK}/wt" commit --allow-empty -m "chore: worktree 的訊息"

  [ "${status}" -eq 0 ]
  [ "$(head -n 1 "${RECORD}/message")" = "chore: worktree 的訊息" ]
}

@test "git push 時，登記的檢查收到的兩個參數與標準輸入，與 git 給 hook 的完全相同" {
  passthrough_docker
  register pre-push 10-record "$(recorder_body)"
  git init -q --bare "${WORK}/remote.git"
  git -C "${MAIN}" remote add origin "${WORK}/remote.git"
  local sha
  sha="$(git -C "${MAIN}" rev-parse refs/heads/main)"

  in_repo git -C "${MAIN}" push -q origin main:main

  [ "${status}" -eq 0 ]
  [ "$(cat "${RECORD}/args")" = "$(printf 'origin\n%s' "${WORK}/remote.git")" ]
  [ "$(cat "${RECORD}/stdin")" = "refs/heads/main ${sha} refs/heads/main 0000000000000000000000000000000000000000" ]
}

@test "git push 時 docker run 帶 -i，標準輸入才進得了容器" {
  passthrough_docker
  register pre-push 10-record "$(recorder_body)"
  git init -q --bare "${WORK}/remote.git"
  git -C "${MAIN}" remote add origin "${WORK}/remote.git"

  in_repo git -C "${MAIN}" push -q origin main:main

  grep -qxF -- '-i' "${DOCKER_ARGV}"
}

@test "登記了兩支檢查時依檔名順序都執行" {
  passthrough_docker
  register commit-msg 20-second "printf '20-second\n' >>\"${RECORD}/order\""
  register commit-msg 10-first "printf '10-first\n' >>\"${RECORD}/order\""

  in_repo git -C "${MAIN}" commit --allow-empty -m "chore: 兩支檢查"

  [ "$(cat "${RECORD}/order")" = "$(printf '10-first\n20-second')" ]
}

@test "一支檢查失敗時 hook 非零結束並轉述原因，git commit 沒有產生新的 commit" {
  passthrough_docker
  register commit-msg 10-refuse "printf '主旨裡有兩個 F 項：F1、F2\n' >&2; exit 1"
  local before
  before="$(git -C "${MAIN}" rev-parse HEAD)"

  in_repo git -C "${MAIN}" commit --allow-empty -m "chore: 會被擋下"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"主旨裡有兩個 F 項：F1、F2"* ]]
  [ "$(git -C "${MAIN}" rev-parse HEAD)" = "${before}" ]
}

@test "docker 不在時 hook 非零結束並說明原因，不放行" {
  register commit-msg 10-record "$(recorder_body)"
  local before
  before="$(git -C "${MAIN}" rev-parse HEAD)"

  in_repo git -C "${MAIN}" commit --allow-empty -m "chore: 沒有 docker"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"docker"* ]]
  [ "$(git -C "${MAIN}" rev-parse HEAD)" = "${before}" ]
}

@test "docker run 失敗時 hook 非零結束並說明，不放行" {
  passthrough_docker 125
  register commit-msg 10-record "$(recorder_body)"
  local before
  before="$(git -C "${MAIN}" rev-parse HEAD)"

  in_repo git -C "${MAIN}" commit --allow-empty -m "chore: docker run 失敗"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"githook"* ]]
  [ "$(git -C "${MAIN}" rev-parse HEAD)" = "${before}" ]
}

@test "環境裡有 CM_TEST_LOCAL=1 時照樣轉進容器，不改在主機跑" {
  passthrough_docker
  register commit-msg 10-record "$(recorder_body)"

  in_repo env CM_TEST_LOCAL=1 git -C "${MAIN}" commit --allow-empty -m "chore: CM_TEST_LOCAL"

  grep -qxF -- 'run' "${DOCKER_ARGV}"
}
