#!/usr/bin/env bash
# compose_smoke.sh 與 backup_drill.sh 共用的擁有者處理（#356）。由它們 source，不單獨執行。
#
# 設了 CM_CI_KEY（script/ci_key.sh 算出來的鍵）時：
#
#   compose 專案名   <鍵>（由呼叫端以 ${OWNER_KEY:-…} 設定）
#   映像             config_manager:runtime-<鍵>（CM_TAG）
#   容器名           compose 檔的名稱加上 -<鍵>（CM_NAME_SUFFIX）；腳本自己起的容器也加
#   標籤             這一輪建立的映像、容器與資料卷都帶 cm.ci.owner=<鍵>
#   清理             compose down 只收這個專案；之後再照 cm.ci.owner=<完整的鍵> 收一次。
#                    **不照名稱前綴或子字串挑**——以本次的鍵開頭的另一個鍵，是另一個擁有者
#                    （script/ci_bystanders.sh 在 CI 上驗這一點）
#
# 沒設時一個都不變：映像 config_manager:runtime、容器名是 compose 檔的預設、不帶標籤、
# 不寫疊加檔，專案名照呼叫端原本的寫法。
#
# 呼叫端要先定義 fail <原因> <下一步>。

OWNER_KEY=""
OWNER_SUFFIX=""
OWNER_IMAGE="config_manager:runtime"
OWNER_FILE=""
OWNER_LABELS=()

# owner_init —— 讀 CM_CI_KEY，定下這一輪的名稱。要在檢查名稱有沒有人用、建立任何資源之前呼叫。
owner_init() {
  [[ -v CM_CI_KEY ]] || return 0
  [[ "${CM_CI_KEY}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    || fail "CM_CI_KEY=${CM_CI_KEY} 不是 script/ci_key.sh 給的那種鍵（小寫英數字、-、_）" \
      "不設它，或用 script/ci_key.sh 算出來的值"
  OWNER_KEY="${CM_CI_KEY}"
  OWNER_SUFFIX="-${OWNER_KEY}"
  # shellcheck disable=SC2034 # 由 source 這支的 compose_smoke.sh 與 backup_drill.sh 帶進 docker run
  OWNER_LABELS=(--label "cm.ci.owner=${OWNER_KEY}")
  export CM_TAG="runtime-${OWNER_KEY}"
  export CM_NAME_SUFFIX="${OWNER_SUFFIX}"
  OWNER_IMAGE="config_manager:${CM_TAG}"
}

# owner_compose_file <目錄> —— 有鍵時在那個目錄寫一份只加擁有者標籤的疊加檔。
owner_compose_file() {
  [[ -n "${OWNER_KEY}" ]] || return 0
  OWNER_FILE="$1/owner.compose.yaml"
  local service
  {
    printf '# script/ci_owner.sh 寫的（#356）：只加擁有者標籤，不改任何其他設定。\n'
    printf 'services:\n'
    for service in backend frontend; do
      printf '  %s:\n' "${service}"
      printf '    build:\n      labels:\n        cm.ci.owner: "%s"\n' "${OWNER_KEY}"
      printf '    labels:\n      cm.ci.owner: "%s"\n' "${OWNER_KEY}"
    done
    printf 'volumes:\n  config_repo:\n    labels:\n      cm.ci.owner: "%s"\n' "${OWNER_KEY}"
  } >"${OWNER_FILE}"
}

# owner_files <COMPOSE_FILE 的值> —— 有疊加檔時接在最後面，印出完整的 COMPOSE_FILE。
owner_files() {
  printf '%s%s\n' "$1" "${OWNER_FILE:+:${OWNER_FILE}}"
}

# owner_sweep —— 清理的最後一步：照 cm.ci.owner=<完整的鍵> 收掉還留著的容器與資料卷
# （例如中途失敗、compose down 沒收到的）。label 的過濾是整個值相等，不是前綴。每一步都容錯：
# 收拾本身不該再製造一個蓋掉原本錯誤的錯誤。
owner_sweep() {
  [[ -n "${OWNER_KEY}" ]] || return 0
  local -a ids=()
  mapfile -t ids < <(docker container ls --all --quiet --filter "label=cm.ci.owner=${OWNER_KEY}" 2>/dev/null)
  ((${#ids[@]} == 0)) || docker container rm --force "${ids[@]}" >/dev/null 2>&1 || true
  mapfile -t ids < <(docker volume ls --quiet --filter "label=cm.ci.owner=${OWNER_KEY}" 2>/dev/null)
  ((${#ids[@]} == 0)) || docker volume rm --force "${ids[@]}" >/dev/null 2>&1 || true
}

# owner_verify <compose 的容器>… —— 這一輪建立的容器屬於 <鍵> 這個專案、帶 cm.ci.owner=<鍵>；
# 映像與設定庫的資料卷也帶同一個標籤。以 docker inspect 讀實際的資源，不從名稱推定。
owner_verify() {
  [[ -n "${OWNER_KEY}" ]] || return 0
  local name got
  for name in "$@"; do
    got="$(docker container inspect --format \
      '{{index .Config.Labels "cm.ci.owner"}} {{index .Config.Labels "com.docker.compose.project"}}' "${name}")"
    [[ "${got}" == "${OWNER_KEY} ${OWNER_KEY}" ]] \
      || fail "容器 ${name} 的擁有者標籤與 compose 專案是「${got}」，不是 ${OWNER_KEY}" \
        "檢查 script/ci_owner.sh 寫的疊加檔有沒有接進 COMPOSE_FILE"
  done
  # 核對的是第一個容器**實際用的**映像（開發模式用的是 devel，不是 OWNER_IMAGE，#392）。
  local image
  image="$(docker container inspect --format '{{.Config.Image}}' "$1")"
  got="$(docker image inspect --format '{{index .Config.Labels "cm.ci.owner"}}' "${image}")"
  [[ "${got}" == "${OWNER_KEY}" ]] \
    || fail "映像 ${image} 的擁有者標籤是「${got}」，不是 ${OWNER_KEY}" "檢查疊加檔的 build.labels"
  got="$(docker volume inspect --format '{{index .Labels "cm.ci.owner"}}' "${COMPOSE_PROJECT_NAME}_config_repo")"
  [[ "${got}" == "${OWNER_KEY}" ]] \
    || fail "資料卷 ${COMPOSE_PROJECT_NAME}_config_repo 的擁有者標籤是「${got}」，不是 ${OWNER_KEY}" "檢查疊加檔的 volumes"
}
