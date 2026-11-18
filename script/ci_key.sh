#!/usr/bin/env bash
#
# CI 建立的資源屬於哪一個擁有者（#356）。
#
# CI 的每個 job 建映像、compose 專案、容器與資料卷之前，先由這支算出這個 job 的鍵：
#
#   cm-<run_id>-<run_attempt>-<job>        一般的 job
#   cm-<run_id>-<run_attempt>-<job>_<分片>  matrix 的 job（CM_CI_SHARD）
#
# 名稱與標籤（cm.ci.owner）都帶這個鍵，清理也只照它挑。一個共同後綴分不開的東西，它都要
# 分得開：同一輪裡平行的 job（run_id 相同）、matrix 的分片（job id 也相同）、重跑
# （run_attempt 不同）。
#
# **不轉換字元。** job id 有大寫、底線或其他字元時直接停下，而不是把它們換成 `-`：換字元
# 會讓兩個不同的 job 拿到同一個鍵，那正是這支要防的事。分片前面用 `_`，因為 job id 裡
# 不准有 `_`——`web-e2e` 的第 1 份與一個叫 `web-e2e-1` 的 job 因此不會撞。
#
# 只在 GitHub Actions 裡有意義：三個變數是 runner 給每個 step 的預設環境變數。本機不呼叫
# 這支，所以本機的名稱一個都不變。
set -euo pipefail

usage() {
  cat <<'USAGE'
用法：script/ci_key.sh [--github-env]

印出這個 CI job 的擁有者鍵。讀 runner 給的 GITHUB_RUN_ID、GITHUB_RUN_ATTEMPT、GITHUB_JOB，
matrix 的 job 另外讀 CM_CI_SHARD（strategy.job-index）。

  --github-env   另外把 CM_CI_KEY=<鍵> 附加到 GITHUB_ENV 指的檔案，之後的 step 都讀得到

缺變數、或變數不是預期的字元時以 2 結束，不印鍵。
USAGE
}

refuse() {
  printf 'ci_key: %s，沒有算出鍵。下一步：%s\n' "$1" "$2" >&2
  exit 2
}

# need <變數名> <要符合的樣式> <樣式的說明>
need() {
  local name="$1" pattern="$2" what="$3" value="${!1:-}"
  [[ -n "${value}" ]] \
    || refuse "${name} 沒有值" "在 GitHub Actions 的 step 裡執行；runner 會給每個 step 這個變數"
  [[ "${value}" =~ ${pattern} ]] \
    || refuse "${name}=${value} 不是${what}" "改用符合的值；不轉換字元，免得兩個不同的 job 拿到同一個鍵"
}

main() {
  local export_env=0
  case "${1:-}" in
    "") ;;
    --github-env) export_env=1 ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  need GITHUB_RUN_ID '^[0-9]+$' '數字'
  need GITHUB_RUN_ATTEMPT '^[0-9]+$' '數字'
  need GITHUB_JOB '^[a-z][a-z0-9-]*$' '小寫字母開頭、只含小寫英數字與 - 的 job id'
  local key="cm-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${GITHUB_JOB}"
  if [[ -v CM_CI_SHARD ]]; then
    need CM_CI_SHARD '^[0-9]+$' '數字'
    key+="_${CM_CI_SHARD}"
  fi

  if ((export_env)); then
    [[ -n "${GITHUB_ENV:-}" ]] \
      || refuse "GITHUB_ENV 沒有值，不知道要寫到哪裡" "在 GitHub Actions 的 step 裡執行"
    printf 'CM_CI_KEY=%s\n' "${key}" >>"${GITHUB_ENV}"
    printf 'ci_key: 這個 job 的擁有者鍵是 %s（已寫進 GITHUB_ENV 的 CM_CI_KEY）\n' "${key}"
    return 0
  fi
  printf '%s\n' "${key}"
}

main "$@"
