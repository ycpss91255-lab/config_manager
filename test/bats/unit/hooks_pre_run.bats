#!/usr/bin/env bats
#
# script/hooks/pre/run.sh — 啟動前在主機上擋下的東西（T19、#385）。
#
# 它檢查的是主機上的目錄與設定，但那些都經由受控的環境與目錄進來：目標根目錄由
# CM_TARGET_ROOT 決定、`.env` 在目前目錄（run.sh 先 cd 到 repo 根目錄才呼叫它，Compose 讀的
# 也是那一份）。指到暫存目錄就能在容器裡觀察——「在主機執行」不代表觀察不到。
#
# 目標根目錄由 `docker compose config` 解（#388），所以這裡要一支真的 compose：工具映像裡釘住
# 版本的 docker-compose（T25 用的同一支）。PATH 上的 docker 只把 `docker compose …` 轉給它，
# 不是假的；暫存目錄裡放一份 repo 的 compose.yaml。比對的基準也是 compose：同一份設定下
# `docker-compose config` 解出的 backend 掛載來源。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  HOOK="${REPO_ROOT}/script/hooks/pre/run.sh"
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/target" "${WORK}/bin"
  export CM_TARGET_ROOT="${WORK}/target"
  unset CM_HOSTNAME COMPOSE_FILE COMPOSE_ENV_FILES
  export COMPOSE_PROJECT_NAME=spec
  printf '#!/usr/bin/env bash\n[[ "$1" == compose ]] || exit 127\nshift\nexec docker-compose "$@"\n' >"${WORK}/bin/docker"
  chmod +x "${WORK}/bin/docker"
  export PATH="${WORK}/bin:${PATH}"
  cp "${REPO_ROOT}/compose.yaml" "${WORK}/compose.yaml"
  cd "${WORK}" || return 1
}

# 同一份設定下，compose 實際會掛給 backend 的目標根目錄（bind mount 的來源）。
mount_source() {
  docker-compose config --format json | python3 -c '
import json, sys
d = json.load(sys.stdin)
print([v["source"] for v in d["services"]["backend"]["volumes"] if v["type"] == "bind"][0])'
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
  # 結束碼不在這裡判：compose 解 .env 時可能拒絕第三行那種不是「名=值」的寫法（#388 起由
  # compose 解），那時停下也對。這一條只看內容有沒有被執行。
  run "${HOOK}"
  [ ! -e "${WORK}/executed-1" ]
  [ ! -e "${WORK}/executed-2" ]
  [ ! -e "${WORK}/executed-3" ]
}

@test "目標根目錄不存在時照舊停止，訊息指名那個路徑" {
  CM_TARGET_ROOT="${WORK}/missing" run "${HOOK}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${WORK}/missing"* ]]
}

# ── 目標根目錄與 compose 實際掛載的是同一個（#388）──────────────────────────

@test "只在 .env 設 CM_TARGET_ROOT 時繼續，檢查的目錄與 compose 掛載的相同，來源寫 .env（#388）" {
  unset CM_TARGET_ROOT
  mkdir -p "${WORK}/from-env-file"
  printf 'CM_TARGET_ROOT=%s\n' "${WORK}/from-env-file" >.env
  local expected
  expected="$(mount_source)"

  run "${HOOK}"

  [ "${status}" -eq 0 ]
  [ "${expected}" = "${WORK}/from-env-file" ]
  [[ "${output}" == *"目標根目錄 ${expected}"*".env"* ]]
}

@test ".env 設的目錄不存在時停止，訊息指名那個目錄並說它來自 .env（#388）" {
  unset CM_TARGET_ROOT
  printf 'CM_TARGET_ROOT=%s\n' "${WORK}/no-such-dir" >.env

  run "${HOOK}"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${WORK}/no-such-dir"*".env"* ]]
}

@test "環境變數與 .env 都設、值不同時，檢查的是 compose 採用的環境變數那一個（#388）" {
  mkdir -p "${WORK}/from-env-file"
  printf 'CM_TARGET_ROOT=%s\n' "${WORK}/from-env-file" >.env
  local expected
  expected="$(mount_source)"

  run "${HOOK}"

  [ "${status}" -eq 0 ]
  [ "${expected}" = "${WORK}/target" ]
  [[ "${output}" == *"目標根目錄 ${expected}"*"環境變數"* ]]
}

@test "兩者都沒設時檢查 compose 檔的預設目錄，來源寫 compose 檔的預設值（#388）" {
  unset CM_TARGET_ROOT
  local expected
  expected="$(mount_source)"

  run "${HOOK}"

  [ "${expected}" = "/opt/robot/config" ]
  [[ "${output}" == *"/opt/robot/config"*"預設"* ]]
}

@test ".env 的 CM_TARGET_ROOT 值裡的指令替換不被執行（#388）" {
  unset CM_TARGET_ROOT
  printf 'CM_TARGET_ROOT=$(touch %s/executed-4)\n' "${WORK}" >.env

  run "${HOOK}"

  [ ! -e "${WORK}/executed-4" ]
}

@test "compose 解不出設定時停止並轉述原因，不自己猜一個目錄繼續（#388）" {
  printf 'services: [\n' >compose.yaml

  run "${HOOK}"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"docker compose config"* ]]
}
