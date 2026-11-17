#!/usr/bin/env bats
#
# script/hooks/pre/run.sh — 啟動前在主機上擋下的東西（T19、#385）。
#
# 它檢查的是主機上的目錄與設定，但那些都經由受控的環境與目錄進來：目標根目錄由
# CM_TARGET_ROOT 決定、`.env` 在目前目錄（run.sh 先 cd 到 repo 根目錄才呼叫它，Compose 讀的
# 也是那一份）。指到暫存目錄就能在容器裡觀察——「在主機執行」不代表觀察不到。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  HOOK="${REPO_ROOT}/script/hooks/pre/run.sh"
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/target"
  export CM_TARGET_ROOT="${WORK}/target"
  unset CM_HOSTNAME
  cd "${WORK}" || return 1
}

teardown() {
  rm -rf "${WORK}"
}

@test "沒有殘留、目標根目錄存在時繼續" {
  run "${HOOK}"
  [ "${status}" -eq 0 ]
}

@test "環境變數 CM_HOSTNAME 有值時停止，指出如何移除並寫明順序（#385）" {
  CM_HOSTNAME=amr01 run "${HOOK}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"CM_HOSTNAME"* ]]
  [[ "${output}" == *"1. 移除舊變數"*"2. 重新啟動服務"*"3. 到介面"* ]]
}

@test "環境變數 CM_HOSTNAME 是空值也停止（#385）" {
  CM_HOSTNAME= run "${HOOK}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"CM_HOSTNAME"* ]]
}

@test ".env 裡有 CM_HOSTNAME 時停止，指名 .env 與行號（#385）" {
  printf 'CM_TAG=runtime\nCM_HOSTNAME=amr01\n' >.env
  run "${HOOK}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *".env"*"第 2 行"* ]]
}

@test ".env 的 export 寫法、行首空白、等號前後空白、等號後空的都算殘留（#385）" {
  local line
  for line in 'export CM_HOSTNAME=amr01' '   CM_HOSTNAME=amr01' 'CM_HOSTNAME = amr01' 'CM_HOSTNAME='; do
    printf '%s\n' "${line}" >.env
    run "${HOOK}"
    [ "${status}" -ne 0 ]
  done
}

@test ".env 只有註解掉的 CM_HOSTNAME 時不擋（#385）" {
  printf '# CM_HOSTNAME=amr01\n   # export CM_HOSTNAME=amr01\n' >.env
  run "${HOOK}"
  [ "${status}" -eq 0 ]
}

@test ".env 的內容當文字讀、不被執行（#385）" {
  # 不以 source 讀：.env 裡的指令替換、反引號、一般指令都不能跑起來。
  {
    printf 'A=$(touch %s/executed-1)\n' "${WORK}"
    printf 'B=`touch %s/executed-2`\n' "${WORK}"
    printf 'touch %s/executed-3\n' "${WORK}"
  } >.env
  run "${HOOK}"
  [ "${status}" -eq 0 ]
  [ ! -e "${WORK}/executed-1" ]
  [ ! -e "${WORK}/executed-2" ]
  [ ! -e "${WORK}/executed-3" ]
}

@test "目標根目錄不存在時照舊停止，訊息指名那個路徑" {
  CM_TARGET_ROOT="${WORK}/missing" run "${HOOK}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${WORK}/missing"* ]]
}
