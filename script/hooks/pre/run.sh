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

refuse_missing_target_root() {
  local target_root="${CM_TARGET_ROOT:-/opt/robot/config}"
  if [[ ! -d "${target_root}" ]]; then
    printf 'pre-run: 目標位置的根目錄 %s 在主機上不存在。\n' "${target_root}" >&2
    printf 'pre-run: 否則 Docker 會用 root 建出那個目錄，之後的寫出會失敗。\n' >&2
    printf 'pre-run: 下一步：先建起來（sudo mkdir -p %s），或設 CM_TARGET_ROOT 指到別處\n' "${target_root}" >&2
    exit 1
  fi
}

refuse_leftover_variable
refuse_missing_target_root
