#!/usr/bin/env bash
# pre-run hook：在 `just docker run`（含 bridge／dev）之前執行。
#
# 兩件事，都在把任何東西拉起來之前擋下：
#
# 1. 舊的 CM_HOSTNAME 還在（#385）。新納管的預設主機名稱改由介面確認後存在清單檔，
#    compose.yaml 也不再把它傳進容器——留著它會讓人以為它還在起作用，所以停下來請人先移除。
#    檢查兩個來源：這支自己的環境變數（shell 設定檔裡的 export 也反映在這裡），與目前目錄的
#    `.env`（run.sh 先 cd 到 repo 根目錄才呼叫這支，Compose 預設讀的也是那一份）。`.env`
#    **當文字逐行讀，不以 source 執行**——裡面的指令替換或指令不能因為檢查而跑起來。
#    `export` 寫法、行首空白、等號後是空的都算；`#` 開頭的註解行不算。**空值也算**：要清掉
#    的是舊接線本身。不檢查 `--env-file`、`COMPOSE_ENV_FILES` 指定的其他檔；直接用
#    `docker compose up`（不經這支）時也檢查不到——那時名稱不受影響，因為服務已不讀它。
#
# 2. config-repo 的掛載點在**主機上**存在。bind-mount 的來源不存在時，Docker 會靜默地建一個
#    root 所有的空目錄，而第一個症狀是寫出過程深處的權限錯誤——在時間與位置上都離成因很遠。
#    在這裡就失敗，能把錯誤放在真正出問題的東西旁邊。
#
#    **要檢查哪一個目錄，問 compose**（#388）：`docker compose config` 解出來的 backend 目標根目錄，
#    就是 `docker compose up` 會掛的那一個——同一份來源（環境變數、`.env`、COMPOSE_FILE 的疊加檔）、
#    同一個優先順序（環境變數優先於 `.env`，都沒有才用 compose 檔的預設）。先前這裡只讀環境變數，
#    只寫在 `.env` 的值就被當成沒設，檢查的與實際掛載的是兩個目錄。不自己解析 `.env`、也不
#    source 它：解析規則留給 compose 一處，`.env` 的內容不因為檢查而被執行。
set -euo pipefail

refuse_leftover_variable() {
  if [[ -n "${CM_HOSTNAME+set}" ]]; then
    printf 'pre-run: 環境變數裡還有舊的 CM_HOSTNAME（值：「%s」）。\n' "${CM_HOSTNAME}" >&2
    printf 'pre-run: 新納管的預設主機名稱改由介面確認後存在清單檔，不再由環境變數決定，所以這次沒有啟動。\n' >&2
    printf 'pre-run: 下一步：依序 1. 移除舊變數（unset CM_HOSTNAME，並從 shell 設定檔移除那一行）2. 重新啟動服務（just docker run）3. 到介面「設定」確認新納管預設主機名稱\n' >&2
    exit 1
  fi

  [[ -f .env ]] || return 0
  local line stripped number=0 found=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    number=$((number + 1))
    stripped="${line#"${line%%[![:space:]]*}"}"
    [[ "${stripped}" == \#* ]] && continue
    if [[ "${stripped}" =~ ^(export[[:space:]]+)?CM_HOSTNAME[[:space:]]*= ]]; then
      found+=("${number}")
    fi
  done <.env
  if ((${#found[@]} > 0)); then
    printf 'pre-run: %s/.env 第 %s 行還有舊的 CM_HOSTNAME。\n' "${PWD}" "${found[*]}" >&2
    printf 'pre-run: 新納管的預設主機名稱改由介面確認後存在清單檔，不再由環境變數決定，所以這次沒有啟動。\n' >&2
    printf 'pre-run: 下一步：依序 1. 移除舊變數（刪掉 .env 的那幾行）2. 重新啟動服務（just docker run）3. 到介面「設定」確認新納管預設主機名稱\n' >&2
    exit 1
  fi
}

# compose_target_root —— compose 解出的 backend 目標根目錄（CM_ALLOWED_ROOTS，
# 與目標根目錄的掛載同源，T25）。解不出來時印出 compose 的原因、以非零結束。
compose_target_root() {
  local config status=0
  config="$(docker compose config --format json 2>&1)" || status=$?
  if ((status != 0)); then
    printf 'pre-run: docker compose config 解不出這份 compose 設定（結束碼 %s），不知道要檢查哪一個目標根目錄：%s\n' \
      "${status}" "$(printf '%s' "${config}" | tail -n 3 | tr '\n' ' ')" >&2
    printf 'pre-run: 下一步：照上面 compose 的原因修正 compose.yaml、疊加檔或 .env，再跑一次\n' >&2
    return 1
  fi
  if [[ ! "${config}" =~ \"CM_ALLOWED_ROOTS\"[[:space:]]*:[[:space:]]*\"([^\"\\]*)\" ]]; then
    printf 'pre-run: docker compose config 的結果裡找不到 backend 的 CM_ALLOWED_ROOTS，不知道要檢查哪一個目標根目錄\n' >&2
    printf 'pre-run: 下一步：確認 compose.yaml 的 backend 仍以 CM_TARGET_ROOT 設 CM_ALLOWED_ROOTS 與目標根目錄的掛載\n' >&2
    return 1
  fi
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# target_root_source <compose 解出的目錄> —— 那個值從哪裡來，照 compose 的優先順序說：環境變數、
# Compose 讀的環境檔（預設是 .env），或 compose 檔的預設值。後兩者的分辨也問 compose：
# 不帶環境變數與環境檔時解出的，就是 compose 檔的預設值。
target_root_source() {
  local resolved="$1" fallback
  if [[ -n "${CM_TARGET_ROOT:-}" ]]; then
    printf '環境變數 CM_TARGET_ROOT\n'
    return 0
  fi
  if fallback="$(env -u CM_TARGET_ROOT -u COMPOSE_ENV_FILES docker compose --env-file /dev/null config --format json 2>/dev/null)" \
    && [[ "${fallback}" =~ \"CM_ALLOWED_ROOTS\"[[:space:]]*:[[:space:]]*\"([^\"\\]*)\" ]]; then
    if [[ "${BASH_REMATCH[1]}" == "${resolved}" ]]; then
      printf 'compose 檔的預設值\n'
    else
      printf '%s（Compose 讀的環境檔）\n' "${COMPOSE_ENV_FILES:-.env}"
    fi
    return 0
  fi
  printf '%s（Compose 讀的環境檔）或 compose 檔的預設值\n' "${COMPOSE_ENV_FILES:-.env}"
}

refuse_missing_target_root() {
  local target_root origin
  target_root="$(compose_target_root)" || exit 1
  origin="$(target_root_source "${target_root}")"
  if [[ ! -d "${target_root}" ]]; then
    printf 'pre-run: 目標位置的根目錄 %s 在主機上不存在（來源：%s）。\n' "${target_root}" "${origin}" >&2
    printf 'pre-run: 否則 Docker 會用 root 建出那個目錄，之後的寫出會失敗。\n' >&2
    printf 'pre-run: 下一步：先建起來（sudo mkdir -p %s），或改 %s 的 CM_TARGET_ROOT 指到別處\n' "${target_root}" "${origin}" >&2
    exit 1
  fi
  printf 'pre-run: 目標根目錄 %s（來源：%s）\n' "${target_root}" "${origin}"
}

refuse_leftover_variable
refuse_missing_target_root
