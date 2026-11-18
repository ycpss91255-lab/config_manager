#!/usr/bin/env bats
#
# script/lint_run_name.sh —— 每一次 workflow 執行的名稱分不分得出對應的 commit（T19、#350）。
#
# 沒有 run-name 時，pull_request 觸發的每一次執行都顯示 PR 標題，同一個 PR 推好幾次名稱都一樣。
# 判定標準是維護者 11/14 定案的：PR 觸發帶 head 的完整 SHA；push、手動、merge_group 帶
# github.sha；推 tag 的帶 tag 名稱與 github.sha。
#
# 測的是公開行為：餵 workflow 檔（或一份真的 repo 與 pre-push 的標準輸入）進去，看結束碼與訊息。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  LINT="${REPO_ROOT}/script/lint_run_name.sh"
  WORK="$(cd -- "$(mktemp -d)" && pwd -P)"
  export GIT_AUTHOR_NAME=spec GIT_AUTHOR_EMAIL=spec@example.com
  export GIT_COMMITTER_NAME=spec GIT_COMMITTER_EMAIL=spec@example.com
}

teardown() {
  rm -rf "${WORK}"
}

# workflow <檔名> <on 的那幾行> [run-name 那一行]：寫一份最小的 workflow。
workflow() {
  local name="$1" on="$2" run_name="${3:-}"
  {
    printf 'name: spec\n'
    [[ -n "${run_name}" ]] && printf '%s\n' "${run_name}"
    printf '%s\n' "${on}"
    printf 'jobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
  } >"${WORK}/${name}"
}

readonly PR_ON=$'on:\n  pull_request:'
readonly PUSH_ON=$'on:\n  push:\n    branches: [main]'

@test "repo 自己的 ci.yaml 與 release.yaml 通過" {
  run "${LINT}" "${REPO_ROOT}/.github/workflows/ci.yaml" "${REPO_ROOT}/.github/workflows/release.yaml"

  [ "${status}" -eq 0 ]
}

@test "沒有 run-name 的 workflow 被擋下，指名那個檔" {
  workflow none.yaml "${PUSH_ON}"

  run "${LINT}" "${WORK}/none.yaml"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"none.yaml"*"run-name"* ]]
}

@test "run-name 是純靜態字串時擋下" {
  workflow static.yaml "${PUSH_ON}" 'run-name: CI'

  run "${LINT}" "${WORK}/static.yaml"

  [ "${status}" -ne 0 ]
  # 指名原因是靜態字串——只看結束碼的話，「push 觸發沒有 github.sha」那條也會擋下它。
  [[ "${output}" == *"static.yaml"*"靜態"* ]]
}

@test "沒加引號時空格加 # 之後是 YAML 的註解，只剩靜態文字的 run-name 被擋下" {
  # YAML 的純文字值裡，空格後面的 # 開始註解：這一行的值其實只有「PR」。
  workflow comment.yaml "${PR_ON}" 'run-name: PR #${{ github.event.pull_request.head.sha }}'

  run "${LINT}" "${WORK}/comment.yaml"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comment.yaml"*"靜態"* ]]
}

@test "pull_request 觸發只帶 PR 編號與標題、沒有 head 的 SHA 時擋下，指名觸發與缺的欄位" {
  workflow pr.yaml "${PR_ON}" \
    'run-name: "PR #${{ github.event.pull_request.number }} ${{ github.event.pull_request.title }}"'

  run "${LINT}" "${WORK}/pr.yaml"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"pull_request"*"github.event.pull_request.head.sha"* ]]
}

@test "pull_request 觸發帶的是 github.sha 而不是 head 的 SHA 時擋下" {
  workflow pr.yaml "${PR_ON}" 'run-name: PR ${{ github.event.pull_request.number }} @ ${{ github.sha }}'

  run "${LINT}" "${WORK}/pr.yaml"

  [ "${status}" -ne 0 ]
}

@test "pull_request 觸發帶 head 的 SHA 時通過" {
  workflow pr.yaml "${PR_ON}" \
    'run-name: "PR #${{ github.event.pull_request.number }} @ ${{ github.event.pull_request.head.sha }}"'

  run "${LINT}" "${WORK}/pr.yaml"

  [ "${status}" -eq 0 ]
}

@test "push 觸發沒有 github.sha 時擋下，指名觸發" {
  workflow push.yaml "${PUSH_ON}" 'run-name: ${{ github.ref_name }}'

  run "${LINT}" "${WORK}/push.yaml"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"push"*"github.sha"* ]]
}

@test "workflow_dispatch 觸發沒有 github.sha 時擋下" {
  workflow dispatch.yaml $'on:\n  workflow_dispatch:' 'run-name: ${{ github.ref_name }}'

  run "${LINT}" "${WORK}/dispatch.yaml"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"workflow_dispatch"* ]]
}

@test "merge_group 觸發沒有 github.sha 時擋下" {
  workflow mq.yaml $'on:\n  merge_group:' 'run-name: ${{ github.ref_name }}'

  run "${LINT}" "${WORK}/mq.yaml"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"merge_group"* ]]
}

@test "推 tag 的觸發少了 tag 名稱時擋下" {
  workflow tag.yaml $'on:\n  push:\n    tags: [\'v*\']' 'run-name: Release ${{ github.sha }}'

  run "${LINT}" "${WORK}/tag.yaml"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"github.ref_name"* ]]
}

@test "推 tag 的觸發帶 tag 名稱與 github.sha 時通過" {
  workflow tag.yaml $'on:\n  push:\n    tags: [\'v*\']' 'run-name: Release ${{ github.ref_name }} @ ${{ github.sha }}'

  run "${LINT}" "${WORK}/tag.yaml"

  [ "${status}" -eq 0 ]
}

@test "on 寫成一行清單時照同樣的觸發判定" {
  workflow inline.yaml 'on: [push, pull_request]' 'run-name: ${{ github.sha }}'

  run "${LINT}" "${WORK}/inline.yaml"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"pull_request"* ]]
}

@test "on 寫成一個觸發時照同樣的判定" {
  workflow single.yaml 'on: push' 'run-name: ${{ github.ref_name }}'

  run "${LINT}" "${WORK}/single.yaml"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"push"* ]]
}

# ── pre-push：要推上去的 commit 裡的 workflow ─────────────────────────────

# 一份真的 repo，第一個 commit 的 workflow 沒有 run-name；工作目錄裡再把它改好、不提交。
repo_with_bad_commit() {
  REPO="${WORK}/repo"
  mkdir -p "${REPO}/.github/workflows"
  git init -q -b main "${REPO}"
  workflow bad.yaml "${PUSH_ON}"
  mv "${WORK}/bad.yaml" "${REPO}/.github/workflows/ci.yaml"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "chore: 沒有 run-name"
  BAD="$(git -C "${REPO}" rev-parse HEAD)"
  workflow good.yaml "${PUSH_ON}" 'run-name: ${{ github.sha }}'
  mv "${WORK}/good.yaml" "${REPO}/.github/workflows/ci.yaml"
}

@test "--pre-push 檢查的是要推上去的 commit 裡的 workflow，不是工作目錄裡的" {
  repo_with_bad_commit

  cd "${REPO}" || return 1
  run "${LINT}" --pre-push <<<"refs/heads/main ${BAD} refs/heads/main 0000000000000000000000000000000000000000"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ci.yaml"* ]]
}

@test "--pre-push 遇到刪除分支的那一行（本地 SHA 全是 0）時略過" {
  repo_with_bad_commit

  cd "${REPO}" || return 1
  run "${LINT}" --pre-push <<<"(delete) 0000000000000000000000000000000000000000 refs/heads/gone ${BAD}"

  [ "${status}" -eq 0 ]
}

@test "登記的 pre-push 檢查把標準輸入交給 lint_run_name.sh --pre-push" {
  repo_with_bad_commit
  mkdir -p "${REPO}/script/githook-checks/pre-push"
  cp "${LINT}" "${REPO}/script/lint_run_name.sh"
  cp "${REPO_ROOT}/script/githook-checks/pre-push/10-run-name.sh" "${REPO}/script/githook-checks/pre-push/"

  cd "${REPO}" || return 1
  run "${REPO}/script/githook-checks/pre-push/10-run-name.sh" origin "${WORK}/remote.git" \
    <<<"refs/heads/main ${BAD} refs/heads/main 0000000000000000000000000000000000000000"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ci.yaml"*"run-name"* ]]
}
