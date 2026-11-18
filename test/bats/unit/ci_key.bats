#!/usr/bin/env bats
#
# script/ci_key.sh — CI 建立的資源屬於哪一個擁有者（#356）。
#
# CI 的每個 job 建映像、compose 專案、容器與資料卷之前，先由它算出這個 job 的鍵；名稱與
# 標籤都帶這個鍵，清理也只照它挑。鍵分不開的兩個 job——同一輪裡平行的 job、matrix 的
# 分片、重跑——它們的資源就分不開。
#
# 測的是公開行為：一組受控的環境變數進去，看印出的鍵、寫進 GITHUB_ENV 的內容與結束碼。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  KEY="${REPO_ROOT}/script/ci_key.sh"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

# 以 GitHub 會給的那三個變數呼叫。要改哪一個就在後面再給一次（env 以最後一個為準）；
# 要拿掉哪一個，就在被測的腳本前面接一個 `env -u <變數>`。
key() {
  run env -i PATH="${PATH}" GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=compose-smoke "$@"
}

@test "三個變數都有值時印出 cm-<run_id>-<run_attempt>-<job>" {
  key "${KEY}"

  [ "${output}" = "cm-4242-1-compose-smoke" ]
}

@test "有 CM_CI_SHARD 時鍵後面加上底線與分片" {
  key GITHUB_JOB=web-e2e CM_CI_SHARD=3 "${KEY}"

  [ "${output}" = "cm-4242-1-web-e2e_3" ]
}

@test "matrix 的第 1 份與一個叫 web-e2e-1 的 job 拿到的鍵不同" {
  key GITHUB_JOB=web-e2e CM_CI_SHARD=1 "${KEY}"
  local shard="${output}"
  key GITHUB_JOB=web-e2e-1 "${KEY}"

  [ "${shard}" != "${output}" ]
}

@test "同一個 run 重跑（run_attempt 不同）時鍵不同" {
  key "${KEY}"
  local first="${output}"
  key GITHUB_RUN_ATTEMPT=2 "${KEY}"

  [ "${first}" != "${output}" ]
}

@test "少了 GITHUB_RUN_ID 時以 2 結束並指名它，不印鍵" {
  key env -u GITHUB_RUN_ID "${KEY}"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"GITHUB_RUN_ID"* ]]
  [[ "${output}" != *"cm-"* ]]
}

@test "少了 GITHUB_RUN_ATTEMPT 時以 2 結束並指名它，不印鍵" {
  key env -u GITHUB_RUN_ATTEMPT "${KEY}"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"GITHUB_RUN_ATTEMPT"* ]]
  [[ "${output}" != *"cm-"* ]]
}

@test "少了 GITHUB_JOB 時以 2 結束並指名它，不印鍵" {
  key env -u GITHUB_JOB "${KEY}"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"GITHUB_JOB"* ]]
  [[ "${output}" != *"cm-"* ]]
}

@test "job id 有大寫或底線時以 2 結束並指名它，不轉換成別的鍵" {
  key GITHUB_JOB=Web_E2E "${KEY}"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"Web_E2E"* ]]
  [[ "${output}" != *"cm-"* ]]
}

@test "分片不是數字時以 2 結束並指名它" {
  key GITHUB_JOB=web-e2e CM_CI_SHARD=a1 "${KEY}"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"CM_CI_SHARD"* ]]
}

@test "run_attempt 不是數字時以 2 結束並指名它" {
  key GITHUB_RUN_ATTEMPT=1x "${KEY}"

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"GITHUB_RUN_ATTEMPT"* ]]
}

@test "--github-env 把 CM_CI_KEY=<鍵> 附加到 GITHUB_ENV 指的檔案，原有內容不變" {
  printf 'EARLIER=kept\n' >"${WORK}/github-env"

  key GITHUB_ENV="${WORK}/github-env" "${KEY}" --github-env

  [ "$(cat "${WORK}/github-env")" = "$(printf 'EARLIER=kept\nCM_CI_KEY=cm-4242-1-compose-smoke')" ]
}

@test "--github-env 也在 stdout 印出這個鍵，CI 的紀錄看得到每個 job 用的是哪一個" {
  key GITHUB_ENV="${WORK}/github-env" "${KEY}" --github-env

  [[ "${output}" == *"cm-4242-1-compose-smoke"* ]]
}

@test "--github-env 但 GITHUB_ENV 沒設時以 2 結束並指名它" {
  key "${KEY}" --github-env

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"GITHUB_ENV"* ]]
}
