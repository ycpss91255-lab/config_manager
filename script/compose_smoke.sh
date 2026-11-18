#!/usr/bin/env bash
#
# compose 的服務實測（T25 的第二個觀察位置，#51）。
#
# test/bats/integration/compose.bats 驗的是「compose 會照這樣起服務」；這支驗的是「這樣起的服務
# 真的是那樣」：host 與 bridge 各**實際起一次**，從外面連、整個容器移除再建、叫它停。兩種結果
# 分開報——那一檔綠了不代表這一支過了，這一支沒跑到的那一次，這一半是待驗，不是通過。
#
# **只在 Linux 上有意義**，所以由 CI 的 runner 執行：`host` 網路在 macOS 的 Docker Desktop 上
# 不是主機的網路，在那裡量到的「非本機位址連不到」什麼都不證明。
#
# 它會占用 8080／8081 與固定的容器名稱（compose 檔寫死的），所以一開始先確認兩者都沒人在用，
# 有的話直接停下——**不碰任何既有的容器或 volume**。自己用的是隔離的 compose 專案名、自己的
# 具名 volume、暫存的目標根目錄，結束時（含失敗時）全部清掉。
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_ROOT
readonly API="http://127.0.0.1:8080"
readonly WEB="http://127.0.0.1:8081"
# 容器名與映像在設了 CM_CI_KEY 時帶上擁有者的鍵（#356，見 script/ci_owner.sh），所以不是 readonly。
BACKEND="config_manager_backend"
FRONTEND="config_manager_frontend"
CONTROL="cm_smoke_control"
IMAGE="config_manager:runtime"
readonly CONTROL_PORT=18099
readonly STOP_GRACE=10

MODE="準備"
WORK=""
CONTROL_PID=""

# 這幾個由 ci_owner.sh 設定；shellcheck 不跟進被 source 的檔案，所以先在這裡宣告。
declare OWNER_KEY OWNER_SUFFIX OWNER_IMAGE
declare -a OWNER_LABELS
# shellcheck source=ci_owner.sh
source "${REPO_ROOT}/script/ci_owner.sh"

fail() {
  printf 'compose_smoke: 失敗 [%s] %s。下一步：%s\n' "${MODE}" "$1" "$2" >&2
  exit 1
}

ok() {
  printf 'compose_smoke: 通過 [%s] %s\n' "${MODE}" "$1"
}

usage() {
  cat <<'USAGE'
用法：script/compose_smoke.sh

把 compose 的服務實際起起來驗一次：host 網路（compose.yaml）與 bridge 網路
（加 compose.bridge.yaml）各一次。只在 Linux 上有意義，由 CI 執行。

每一種網路模式驗：
  經 script/run.sh 起服務（與 just docker run 同一條路）；本機連得到後端與前端；後端是部署模式
  主機名稱候選是 runner 的 hostname；重跑啟動工具不重啟服務、候選不變；docker restart 之後
  尚未確認、上一次的候選檔被清掉，再跑啟動工具就取得；執行期目錄不在掛載清單裡（#385）
  主機的非 loopback 位址連不到兩個服務（先以一個故意綁 0.0.0.0 的對照服務證明那個位址連得到）
  容器的 PID 1 是服務本身；重啟策略是 unless-stopped
  容器整個移除再建之後：清單、已進版的值、歷史、白名單都在，草稿與身分不在
  docker compose stop 在寬限時間內結束，不是被強制終止
另外驗一次：建好的 runtime 映像裡 import 不到測試工具。

占用 8080／8081 與 compose 檔裡固定的容器名稱；已經有人在用就直接停下，不碰既有的東西。

  CM_CI_KEY=<鍵>  CI 用（#356）：compose 專案、映像、容器都以這個鍵命名並帶 cm.ci.owner 標籤，
                  清理只照這個鍵挑。見 script/ci_owner.sh
USAGE
}

# 這一輪起的東西全部收掉。失敗時也要跑，所以掛在 EXIT 上；每一步都容錯，收拾本身不該再製造
# 一個蓋掉原本錯誤的錯誤。
cleanup() {
  local status=$?
  [[ -n "${CONTROL_PID}" ]] && kill "${CONTROL_PID}" 2>/dev/null || true
  docker container rm --force "${CONTROL}" >/dev/null 2>&1 || true
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    COMPOSE_FILE="compose.yaml:compose.bridge.yaml" \
      docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  owner_sweep
  if [[ -n "${WORK}" ]]; then
    # 目標根目錄裡的檔案是容器的使用者寫的，runner 的使用者不一定刪得掉；交給一個容器去刪。
    docker run --rm "${OWNER_LABELS[@]}" --user root --entrypoint rm -v "${WORK}:${WORK}" \
      "${IMAGE}" -rf "${WORK}/targets" >/dev/null 2>&1 || true
    rm -rf "${WORK}" 2>/dev/null || true
  fi
  return "${status}"
}

# json <Python 運算式> —— 對 stdin 的 JSON 問一個問題；`d` 是解出來的值。
json() {
  python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"
}

# call <方法> <路徑> [JSON 內容] —— 帶著同一罐 cookie 打後端，回應印到 stdout。取得了編輯權
# （EDITING 有值）就帶上識別碼：寫入只接受持有編輯權的那個瀏覽器（F23）。
EDITING=""
call() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(--silent --show-error --fail-with-body --max-time 20
    --cookie "${WORK}/cookies" --cookie-jar "${WORK}/cookies" --request "${method}")
  [[ -n "${body}" ]] && args+=(--header 'content-type: application/json' --data "${body}")
  [[ -n "${EDITING}" ]] && args+=(--header "x-cm-editing-token: ${EDITING}")
  curl "${args[@]}" "${API}${path}"
}

wait_for() {
  local url="$1" tries=0
  until curl --silent --fail --max-time 2 --output /dev/null "${url}"; do
    tries=$((tries + 1))
    if (( tries >= 60 )); then
      docker compose logs --tail 40 >&2 || true
      fail "${url} 等了 60 秒仍然沒有回應" "看上面印出的容器日誌，啟動檢查失敗的原因會在最後幾行"
    fi
    sleep 1
  done
}

preconditions() {
  [[ "$(uname -s)" == "Linux" ]] \
    || fail "這台機器不是 Linux（$(uname -s)），host 網路在這裡不是主機的網路" "改在 Linux 上跑；CI 的 compose-smoke job 就是做這件事"
  local name
  for name in "${BACKEND}" "${FRONTEND}" "${CONTROL}"; do
    [[ -z "$(docker ps --all --quiet --filter "name=^${name}\$")" ]] \
      || fail "已經有一個叫 ${name} 的容器，這支不碰既有的容器" "在一台沒有部署這套服務的機器上跑，或先由負責的人把它移走"
  done
  # 連線被拒（curl 結束碼 7）才算空著。其餘任何結果——連得上、連上了但回的不是 HTTP——都代表
  # 那個埠號有人在用。
  local port code
  for port in 8080 8081 "${CONTROL_PORT}"; do
    code=0
    curl --silent --max-time 2 --output /dev/null "http://127.0.0.1:${port}/" || code=$?
    [[ "${code}" -eq 7 ]] \
      || fail "127.0.0.1:${port} 已經有東西在聽，這支不占用別人的埠號" "在一台這個埠號空著的機器上跑"
  done
}

# 主機上一個不是 loopback 的 IPv4 位址——「別台機器會用來連這台」的那一個。
lan_address() {
  local address
  address="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | head -n 1 || true)"
  [[ -n "${address}" ]] \
    || fail "這台機器找不到任何非 loopback 的 IPv4 位址，沒辦法驗「非本機連不到」" "在有對外網卡的機器上跑"
  printf '%s\n' "${address}"
}

# 「連不到」只有在「本來連得到」的前提下才有意義。所以每一種模式都先起一個**故意綁 0.0.0.0**
# 的對照服務、從同一個非本機位址連它：連得到，才接著量被測的服務。host 模式的對照是主機上的
# 一個程序；bridge 模式的對照是一個埠號對應到 0.0.0.0 的容器——與被測的服務走同一條路。
start_control() {
  local address="$1"
  if [[ "${MODE}" == "host" ]]; then
    python3 -m http.server "${CONTROL_PORT}" --bind 0.0.0.0 --directory "${WORK}/control" >/dev/null 2>&1 &
    CONTROL_PID=$!
  else
    docker run --detach "${OWNER_LABELS[@]}" --name "${CONTROL}" --publish "0.0.0.0:${CONTROL_PORT}:8081" \
      --env CM_ROLE=frontend --stop-signal SIGINT "${IMAGE}" \
      python -m http.server 8081 --bind 0.0.0.0 --directory /opt/config_manager/src/config_manager/web >/dev/null
    if [[ -n "${OWNER_KEY}" ]]; then
      [[ "$(docker container inspect --format '{{index .Config.Labels "cm.ci.owner"}}' "${CONTROL}")" == "${OWNER_KEY}" ]] \
        || fail "對照容器 ${CONTROL} 沒有帶 cm.ci.owner=${OWNER_KEY}" "檢查 start_control 的 docker run 有沒有帶 OWNER_LABELS"
    fi
  fi
  wait_for "http://${address}:${CONTROL_PORT}/"
  ok "對照：${address}:${CONTROL_PORT} 上一個綁 0.0.0.0 的服務連得到（測試端到得了這個位址）"
}

stop_control() {
  [[ -n "${CONTROL_PID}" ]] && kill "${CONTROL_PID}" 2>/dev/null || true
  CONTROL_PID=""
  docker container rm --force "${CONTROL}" >/dev/null 2>&1 || true
}

# 被測的埠號從非本機位址要是**被拒絕**（curl 結束碼 7），不是逾時：逾時可能是封包被丟掉，
# 那說不出有沒有東西在聽。
refused_from() {
  local address="$1" port="$2" code=0
  curl --silent --max-time 5 --output /dev/null "http://${address}:${port}/" || code=$?
  [[ "${code}" -eq 7 ]] \
    || fail "從 ${address}:${port} 連線的結果是 curl 結束碼 ${code}，預期是 7（連線被拒）" "0 代表連得到——檢查 compose 檔裡這個服務的監聽位址與埠號對應；28 是逾時，說不出有沒有在聽，換一台網路單純的機器再量"
  ok "${address}:${port} 連線被拒（只有本機連得到）"
}

only_local() {
  local address
  address="$(lan_address)"
  start_control "${address}"
  refused_from "${address}" 8080
  refused_from "${address}" 8081
  stop_control
}

answers_locally() {
  wait_for "${API}/api/mode"
  wait_for "${WEB}/"
  [[ "$(curl --silent "${API}/api/mode" | json 'd["mode"]')" == "deployment" ]] \
    || fail "後端回報的模式不是 deployment" "檢查 compose.yaml 的 CM_MODE 預設值"
  local page
  page="$(curl --silent "${WEB}/")"
  [[ "${page}" == *"config_manager"* ]] \
    || fail "前端供出來的不是這套系統的頁面" "檢查 compose.yaml 裡 frontend 的 --directory"
  ok "本機連得到後端（部署模式）與前端"
}

runs_as_pid_one() {
  local name expected command
  for name in "${BACKEND}:config_manager.api.cli" "${FRONTEND}:http.server"; do
    expected="${name#*:}"
    command="$(docker exec "${name%%:*}" cat /proc/1/cmdline | tr '\0' ' ')"
    [[ "${command}" == *"${expected}"* ]] \
      || fail "${name%%:*} 的 PID 1 是「${command}」，不是服務本身" "檢查 script/entrypoint.sh 最後一行是不是 exec \"\$@\""
    [[ "$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "${name%%:*}")" == "unless-stopped" ]] \
      || fail "${name%%:*} 的重啟策略不是 unless-stopped" "檢查 compose.yaml 的 restart"
  done
  ok "兩個容器的 PID 1 都是服務本身，重啟策略都是 unless-stopped"
}

# 重啟保留範圍（驗證清單 U40）。「重啟」做得比 restart 更重：容器整個移除再建，只有 volume 留著
# ——留得下來的東西因此確定是住在 volume 裡，不是住在容器的可寫層。
survives_recreation() {
  local target="${CM_TARGET_ROOT}/smoke-${MODE}.yaml" extra="${CM_TARGET_ROOT}/extra-${MODE}"
  # 檔案由容器裡的服務使用者建：納管會記下它的擁有者，進版要能照那個擁有者寫回去。
  docker exec "${BACKEND}" sh -c 'printf "max_vel: 0.8\n" > "$1" && mkdir -p "$2"' _ "${target}" "${extra}"

  call POST /api/session '{"name":"實測","email":"smoke@example.com","role":"developer"}' >/dev/null
  # 取得編輯權（F23）：之後的寫入都帶它。容器重建後是新的程序、只做讀取，不必釋放。
  EDITING="$(call POST /api/session/lock | json 'd["token"]')"
  call POST /api/allowed-roots "{\"prefix\":\"${extra}\"}" >/dev/null
  # 新納管預設主機名稱（#385）：開發者確認本次啟動取得的候選，之後的納管才有名稱可用。
  call PUT /api/host-name "{\"hostname\":\"$(hostname)\"}" >/dev/null
  local entry uid
  entry="$(call POST /api/configs "{\"source_path\":\"${target}\",\"format\":\"yaml\",\"ambiguity_note\":\"\"}")"
  uid="$(json 'd["uid"]' <<<"${entry}")"
  [[ "$(json 'd["hostname"]' <<<"${entry}")" == "$(hostname)" ]] \
    || fail "納管紀錄的 hostname 不是開發者確認的主機名稱 $(hostname)" "檢查 PUT /api/host-name 有沒有寫進清單檔的 [defaults]"
  if [[ "${MODE}" == "bridge" ]]; then
    [[ "$(json 'd["hostname"]' <<<"${entry}")" != "$(docker exec "${BACKEND}" hostname)" ]] \
      || fail "bridge 下納管紀錄的 hostname 是容器自己的名稱" "候選應由 post-run hook 在主機上讀，不是容器裡"
  fi
  ok "納管紀錄的 hostname 是確認過的主機名稱，不是容器 ID"
  call POST /api/drafts "{\"uid\":\"${uid}\",\"edits\":{\"max_vel\":1.2}}" >/dev/null
  call POST /api/promote '{}' >/dev/null
  call POST /api/drafts "{\"uid\":\"${uid}\",\"edits\":{\"max_vel\":1.5}}" >/dev/null
  [[ "$(call GET /api/drafts | json 'd["count"]')" == "1" ]] \
    || fail "移除容器之前應該有一份未進版草稿" "檢查 POST /api/drafts 的回應"

  docker compose down --remove-orphans >/dev/null 2>&1
  docker compose up --detach >/dev/null 2>&1
  wait_for "${API}/api/mode"

  local seen
  seen="$(call GET /api/configs | json "[(r['state']) for r in d if r['uid'] == '${uid}']")"
  [[ "${seen}" == "['in_sync']" ]] \
    || fail "容器重建後清單裡這份設定是 ${seen}，預期是一份、狀態一致" "檢查 config_repo volume 有沒有掛在 CM_CONFIG_REPO 指的路徑"
  [[ "$(call GET "/api/configs/${uid}" | json 'd["values"]["max_vel"]')" == "1.2" ]] \
    || fail "容器重建後已進版的值不是 1.2" "檢查來源複本是不是寫在 volume 裡"
  [[ "$(call GET "/api/configs/${uid}/history" | json '[c["kind"] for c in d]')" == "['cfg']" ]] \
    || fail "容器重建後這份設定的歷史不是一筆進版紀錄" "檢查 config-repo 的 .git 是不是在 volume 裡"
  [[ "$(call GET /api/allowed-roots | json "'${extra}' in d['prefixes']")" == "True" ]] \
    || fail "容器重建後從介面加的白名單根目錄不見了" "檢查 allowed-roots.toml 是不是寫在 volume 裡"
  [[ "$(call GET /api/drafts | json 'd["count"]')" == "0" ]] \
    || fail "容器重建後還看得到未進版草稿" "草稿不該跨重啟保留（U40）；檢查是不是有東西把它寫進了 volume"
  [[ "$(call GET /api/session)" == "null" ]] \
    || fail "容器重建後服務還認得原本的身分" "身分不該跨重啟保留（U40）"
  ok "容器整個移除再建之後：清單、已進版的值、歷史、白名單都在；未進版草稿與身分不在"
}

# 經啟動工具起服務（#385）：pre-run hook、docker compose up -d、post-run hook 全部走一次，與
# `just docker run` 同一條路。輸出寫到紀錄檔，失敗時才印出來。
launch() {
  ./script/run.sh >"${WORK}/run.log" 2>&1 || {
    cat "${WORK}/run.log" >&2
    fail "script/run.sh 失敗" "看上面印出的 pre-run／post-run 訊息"
  }
}

started_at() {
  docker inspect --format '{{.State.StartedAt}}' "${BACKEND}"
}

candidate() {
  call GET /api/host-name | json 'd["candidate"]'
}

# 主機名稱候選（#385）：post-run hook 在**主機**（runner）上讀 hostname、交給容器記下；同一次服務
# 啟動已有候選時重跑不更新、也不重啟服務；服務自己重啟之後尚未確認，再跑啟動工具才取得。
host_name_candidate() {
  local expected before start_id view
  expected="$(hostname)"
  [[ "$(candidate)" == "${expected}" ]] \
    || fail "設定 API 回報的本次啟動候選是「$(candidate)」，不是 runner 的 hostname ${expected}" "看 ${WORK}/run.log 裡 post-run 那幾行"
  ok "經啟動工具起服務後，本次啟動取得的候選是 runner 的主機名稱（${expected}）"

  before="$(started_at)"
  start_id="$(docker exec "${BACKEND}" cat /run/config_manager/start-id)"
  launch
  [[ "$(started_at)" == "${before}" && "$(docker exec "${BACKEND}" cat /run/config_manager/start-id)" == "${start_id}" ]] \
    || fail "重跑 script/run.sh 之後服務重啟了" "檢查 script/run.sh 有沒有加上會重建容器的參數"
  [[ "$(candidate)" == "${expected}" ]] \
    || fail "重跑 script/run.sh 之後候選變成「$(candidate)」" "同一次啟動已有候選時不該更新；檢查 io/host_candidate.record"
  ok "重跑啟動工具：容器沿用、服務不重啟（啟動識別碼不變），候選不變"

  docker restart "${BACKEND}" >/dev/null
  wait_for "${API}/api/mode"
  view="$(call GET /api/host-name)"
  [[ "$(json 'd["candidate"] is None and "沒有收到本次啟動" in d["unconfirmed"]' <<<"${view}")" == "True" ]] \
    || fail "docker restart 之後設定 API 仍回報「${view}」" "服務應以新的啟動識別碼判定；檢查 io/host_candidate.read_candidate"
  docker exec "${BACKEND}" test ! -e /run/config_manager/host-candidate.json \
    || fail "docker restart 之後上一次的候選檔還在" "檢查 script/entrypoint.sh 的 clear_runtime_dir"
  ok "docker restart 之後回報目前主機名稱尚未確認，上一次的候選檔已被 entrypoint 清掉"

  before="$(started_at)"
  launch
  [[ "$(candidate)" == "${expected}" && "$(started_at)" == "${before}" ]] \
    || fail "重啟之後再跑 script/run.sh，候選是「$(candidate)」或服務又重啟了" "看 ${WORK}/run.log"
  ok "再跑啟動工具就取得候選，服務不重啟"

  [[ "$(docker inspect --format '{{range .Mounts}}{{.Destination}} {{end}}' "${BACKEND}")" != *"/run/config_manager"* ]] \
    || fail "執行期目錄 /run/config_manager 出現在容器的掛載清單裡" "它要在容器自己的可寫層，檢查 compose 檔的 volumes／tmpfs"
  ok "執行期目錄不在容器實際的掛載清單裡"

  local modes
  # 權限與擁有者在容器裡讀（容器裡的 Python），不用 stat 的旗標——GNU 與 BSD 的寫法不同。
  modes="$(docker exec "${BACKEND}" python -c '
import os, pwd, sys
print("|".join(
    f"{os.stat(p).st_mode & 0o777:o} {pwd.getpwuid(os.stat(p).st_uid).pw_name}" for p in sys.argv[1:]
))' /run/config_manager /run/config_manager/start-id /run/config_manager/host-candidate.json)"
  [[ "${modes}" == "700 user|600 user|600 user" ]] \
    || fail "執行期目錄與裡面的檔是「${modes}」，預期 700／600 且由服務使用者 user 擁有" "檢查 Dockerfile 預建 /run/config_manager 的那一步與寫檔時的權限"
  ok "執行期目錄由服務使用者擁有、0700，識別碼檔與候選檔 0600"
}

stops_in_time() {
  local started elapsed name code
  started="$(date +%s)"
  docker compose stop --timeout "${STOP_GRACE}" >/dev/null 2>&1
  elapsed=$(( $(date +%s) - started ))
  for name in "${BACKEND}" "${FRONTEND}"; do
    code="$(docker inspect --format '{{.State.ExitCode}}' "${name}")"
    [[ "${code}" -ne 137 ]] \
      || fail "${name} 是被強制終止的（結束碼 137），停止訊號沒有被服務接住" "檢查 entrypoint 的 exec 交棒，以及 compose.yaml 裡這個服務的 stop_signal"
  done
  (( elapsed < STOP_GRACE )) \
    || fail "docker compose stop 花了 ${elapsed} 秒，等滿了 ${STOP_GRACE} 秒的寬限" "同上：有一個服務沒有接住停止訊號"
  ok "docker compose stop 在 ${elapsed} 秒內結束，兩個容器都不是被強制終止"
}

exercise() {
  MODE="$1"
  COMPOSE_FILE="$(owner_files "$2")"
  export COMPOSE_FILE
  printf 'compose_smoke: ── %s 網路（%s）──\n' "${MODE}" "${COMPOSE_FILE}"
  launch
  owned_by_this_run
  answers_locally
  host_name_candidate
  only_local
  runs_as_pid_one
  survives_recreation
  stops_in_time
  docker compose down --volumes --remove-orphans >/dev/null 2>&1
  rm -f "${WORK}/cookies"
}

# 擁有者（#356）：設了 CM_CI_KEY 時，這一輪的容器、映像與資料卷都以 docker inspect 讀回來核對。
owned_by_this_run() {
  [[ -n "${OWNER_KEY}" ]] || return 0
  owner_verify "${BACKEND}" "${FRONTEND}"
  ok "擁有者：專案 ${COMPOSE_PROJECT_NAME}、映像 ${IMAGE}、容器 ${BACKEND}／${FRONTEND}、設定庫的資料卷都帶 cm.ci.owner=${OWNER_KEY}"
}

image_has_no_test_tooling() {
  MODE="映像"
  local module
  for module in pytest coverage ruff mypy pylint playwright; do
    if docker run --rm "${OWNER_LABELS[@]}" --entrypoint python "${IMAGE}" -c "import ${module}" >/dev/null 2>&1; then
      fail "runtime 映像裡 import 得到 ${module}" "把它從 config/pip/requirements.txt 移到 requirements-dev.txt"
    fi
  done
  ok "runtime 映像裡 import 不到任何測試工具"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    return 0
  fi
  cd "${REPO_ROOT}"
  owner_init
  BACKEND+="${OWNER_SUFFIX}"
  FRONTEND+="${OWNER_SUFFIX}"
  CONTROL+="${OWNER_SUFFIX}"
  IMAGE="${OWNER_IMAGE}"
  preconditions

  WORK="$(mktemp -d)"
  trap cleanup EXIT
  export COMPOSE_PROJECT_NAME="${OWNER_KEY:-cm_smoke_$$}"
  export CM_TARGET_ROOT="${WORK}/targets"
  # 主機名稱不再由環境變數決定（#385）：留著舊的 CM_HOSTNAME，pre-run hook 會停下來。
  unset CM_HOSTNAME
  # 目標根目錄要讓容器裡的服務使用者寫得進去；它的 uid 與 runner 的不同，所以整個放開。
  # 這是暫存目錄，結束時就刪。
  mkdir -p "${CM_TARGET_ROOT}" "${WORK}/control"
  chmod 0777 "${CM_TARGET_ROOT}"
  printf 'control\n' >"${WORK}/control/index.html"
  owner_compose_file "${WORK}"

  MODE="建置"
  COMPOSE_FILE="$(owner_files compose.yaml)" docker compose build >/dev/null 2>&1 \
    || fail "runtime 映像建不起來" "直接跑 docker compose build 看它印出的原因"
  ok "runtime 映像建好了"

  image_has_no_test_tooling
  exercise host "compose.yaml"
  exercise bridge "compose.yaml:compose.bridge.yaml"

  MODE="總結"
  ok "host 與 bridge 兩種網路的服務實測都過了"
}

main "$@"
