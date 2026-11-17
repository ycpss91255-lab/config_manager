#!/usr/bin/env bats
#
# script/hooks/post/run.sh — 讀了主機的什麼、對 docker 發出了什麼（T19、#385）。
#
# 它在主機上執行，但只透過 PATH 上的 `hostname` 與 `docker` 接觸主機——兩者換成假的，就能在
# 容器裡觀察，與 release.bats 的假 gh 同一個手法。**限制**：假 docker 只證明 hook 呼叫了什麼，
# 不證明候選檔真的被完整替換——那是 T27（test/pytest/integration/test_host_candidate.py）。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  HOOK="${REPO_ROOT}/script/hooks/post/run.sh"
  WORK="$(mktemp -d)"
  STUB="${WORK}/bin"
  mkdir -p "${STUB}"
  PATH="${STUB}:${PATH}"
  export PATH
  unset COMPOSE_FILE

  # 假 docker：每一次呼叫記下參數（一行一個）、COMPOSE_FILE 與標準輸入，以 ---- 分隔；
  # exec 與 ps 的輸出與結束碼由規格指定。
  DOCKER_CALLS="${WORK}/docker-calls"
  export DOCKER_CALLS
  cat >"${STUB}/docker" <<'STUB'
#!/usr/bin/env bash
{
  printf '%s\n' "$@"
  printf 'COMPOSE_FILE=%s\n' "${COMPOSE_FILE-<unset>}"
  if [[ "${2-}" == exec ]]; then printf 'STDIN:'; cat; printf '\n'; fi
  printf '%s\n' ----
} >>"${DOCKER_CALLS}"
case "${2-}" in
  exec) printf '%s\n' "${FAKE_EXEC_OUTPUT-}"; exit "${FAKE_EXEC_STATUS:-0}" ;;
  ps) printf '%s' "${FAKE_PS_OUTPUT-}"; exit "${FAKE_PS_STATUS:-0}" ;;
esac
STUB
  chmod +x "${STUB}/docker"

  # 假 hostname：印 FAKE_HOSTNAME；給了 FAKE_HOSTNAME_ERROR 就把它印到標準錯誤、以 1 結束。
  cat >"${STUB}/hostname" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${FAKE_HOSTNAME_ERROR-}" ]]; then
  printf '%s\n' "${FAKE_HOSTNAME_ERROR}" >&2
  exit 1
fi
printf '%s\n' "${FAKE_HOSTNAME-amr01}"
STUB
  chmod +x "${STUB}/hostname"
  export FAKE_EXEC_OUTPUT="已記錄本次啟動的主機名稱候選：amr01"
}

teardown() {
  rm -rf "${WORK}"
}

@test "讀到名稱時以標準輸入交給容器裡的寫檔程式，參數不經環境變數（#385）" {
  run "${HOOK}"
  [ "${status}" -eq 0 ]
  grep -qxF 'exec' "${DOCKER_CALLS}"
  [ "$(sed -n '1,8p' "${DOCKER_CALLS}" | paste -sd' ' -)" = \
    "compose exec -T backend python -m config_manager.io.host_candidate record" ]
  grep -qxF 'STDIN:amr01' "${DOCKER_CALLS}"
  [ -z "$(grep -xE -- '-e|--env|--env-file' "${DOCKER_CALLS}")" ]
}

@test "COMPOSE_FILE 照疊加檔原樣傳給 docker compose（bridge／dev 也走同一支，#385）" {
  COMPOSE_FILE=compose.yaml:compose.bridge.yaml run "${HOOK}"
  [ "${status}" -eq 0 ]
  grep -qxF 'COMPOSE_FILE=compose.yaml:compose.bridge.yaml' "${DOCKER_CALLS}"
}

@test "記下候選時說 Compose 啟動命令完成並轉述寫檔程式，不說服務正常（#385）" {
  run "${HOOK}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Compose 啟動命令完成"*"已記錄本次啟動的主機名稱候選：amr01"* ]]
  [[ "${output}" != *"服務正常"* ]]
  [[ "${output}" != *"已就緒"* ]]
}

@test "hostname 失敗時以 --unavailable 帶原因呼叫寫檔程式，說候選取得失敗、結束碼 0（#385）" {
  FAKE_HOSTNAME_ERROR="hostname: 讀不到" FAKE_EXEC_STATUS=2 \
    FAKE_EXEC_OUTPUT="已記錄：本次沒有取得主機名稱" run "${HOOK}"
  [ "${status}" -eq 0 ]
  grep -qxF -- '--unavailable' "${DOCKER_CALLS}"
  grep -qF 'hostname: 讀不到' "${DOCKER_CALLS}"
  [[ "${output}" == *"Compose 啟動命令完成，主機名稱候選取得失敗"* ]]
}

@test "hostname 讀到空的也當成取不到，以 --unavailable 呼叫（#385）" {
  FAKE_HOSTNAME="" FAKE_EXEC_STATUS=2 run "${HOOK}"
  [ "${status}" -eq 0 ]
  grep -qxF -- '--unavailable' "${DOCKER_CALLS}"
}

@test "寫檔程式以 2 結束（記下了本次無法取得）時說候選取得失敗並轉述原因、結束碼 0（#385）" {
  FAKE_EXEC_STATUS=2 FAKE_EXEC_OUTPUT="已記錄：本次沒有取得主機名稱（名稱不安全）" run "${HOOK}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"主機名稱候選取得失敗"*"名稱不安全"* ]]
}

@test "寫檔程式失敗而 backend 在執行中：說候選取得失敗、畫面會顯示尚未確認與下一步，結束碼 0（#385）" {
  FAKE_EXEC_STATUS=1 FAKE_EXEC_OUTPUT="主機名稱候選沒有寫進 /run/config_manager" \
    FAKE_PS_OUTPUT=$'abc123\n' run "${HOOK}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Compose 啟動命令完成，主機名稱候選取得失敗"*"沒有寫進"* ]]
  [[ "${output}" == *"尚未確認"*"下一步"* ]]
  [[ "${output}" != *"服務正常"* ]]
}

@test "寫檔程式失敗而 backend 不在執行中：指明是服務啟動失敗、非零結束（#385）" {
  FAKE_EXEC_STATUS=1 FAKE_PS_OUTPUT="" run "${HOOK}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"服務啟動失敗"*"下一步"* ]]
}

@test "寫檔程式失敗又查不到 backend 的狀態：寫明無法確認服務狀態、非零結束（#385）" {
  FAKE_EXEC_STATUS=1 FAKE_PS_STATUS=1 run "${HOOK}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"無法確認服務狀態"* ]]
  [[ "${output}" != *"服務正常"* ]]
}
