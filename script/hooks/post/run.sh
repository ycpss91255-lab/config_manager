#!/usr/bin/env bash
# post-run hook：在 `just docker run`（含 bridge／dev）的 `docker compose up` 之後執行（#385）。
#
# 在**主機**上讀 hostname，以 `docker compose exec` 交給容器裡的寫檔程式記下「本次啟動取得的
# 主機名稱候選」（python -m config_manager.io.host_candidate record）。名稱經標準輸入傳入，不經
# 環境變數；COMPOSE_FILE（bridge／dev 的疊加檔）照原樣交給 docker compose。候選只供介面預填，
# 開發者確認後才保存，這裡不決定任何名稱。
#
# **結束碼**（維護者 11/17）：候選取得失敗只警告、以 0 結束——服務已經起來，不擋啟動；但不能把
# 服務啟動失敗也吞掉：寫檔程式失敗時再查 backend 的狀態，不在執行中、或查不到狀態，就以非零結束。
# 這支**不檢查服務是否就緒**，所以任何訊息都不說服務正常，只說 Compose 啟動命令完成。
set -euo pipefail

readonly WRITER=(python -m config_manager.io.host_candidate record)
readonly UNCONFIRMED='畫面會顯示目前主機名稱尚未確認'

main() {
  local name errors status=0 output reason
  errors="$(mktemp)"
  if name="$(hostname 2>"${errors}")" && [[ -n "${name//[[:space:]]/}" ]]; then
    output="$(printf '%s\n' "${name}" | docker compose exec -T backend "${WRITER[@]}" 2>&1)" || status=$?
  else
    reason="在主機上執行 hostname 沒有讀到名稱：$(tr '\n' ' ' <"${errors}")"
    output="$(docker compose exec -T backend "${WRITER[@]}" --unavailable "${reason}" </dev/null 2>&1)" \
      || status=$?
  fi
  rm -f "${errors}"
  output="$(printf '%s\n' "${output}" | grep -v '^已綁定本次服務啟動識別碼' || true)"

  case "${status}" in
    0)
      printf 'post-run: Compose 啟動命令完成；%s\n' "${output}"
      ;;
    2)
      printf 'post-run: Compose 啟動命令完成，主機名稱候選取得失敗：%s；%s。\n' "${output}" "${UNCONFIRMED}" >&2
      printf 'post-run: 下一步：處理上面的原因後重跑 just docker run（容器沿用時不會重啟服務），或到介面「設定」由開發者直接輸入\n' >&2
      ;;
    *)
      refuse_unless_backend_running "${output}"
      printf 'post-run: Compose 啟動命令完成，主機名稱候選取得失敗：%s；%s。\n' "${output}" "${UNCONFIRMED}" >&2
      printf 'post-run: 下一步：處理上面的原因後重跑 just docker run（容器沿用時不會重啟服務），或到介面「設定」由開發者直接輸入\n' >&2
      ;;
  esac
}

# 寫檔程式失敗時，分清楚是候選的問題還是服務根本沒在執行——後者是服務啟動失敗，不能吞掉。
refuse_unless_backend_running() {
  local failure="$1" running
  if ! running="$(docker compose ps --status running --quiet backend 2>&1)"; then
    printf 'post-run: 主機名稱候選取得失敗（%s），而且查不到 backend 的狀態（%s），無法確認服務狀態。\n' \
      "${failure}" "${running}" >&2
    printf 'post-run: 下一步：用 docker compose ps 與 docker compose logs backend 確認服務是否在執行\n' >&2
    exit 1
  fi
  if [[ -z "${running//[[:space:]]/}" ]]; then
    printf 'post-run: backend 沒有在執行——這是服務啟動失敗，不是主機名稱候選的問題（%s）。\n' "${failure}" >&2
    printf 'post-run: 下一步：看 docker compose logs backend 找出它為什麼沒有起來，修正後再跑 just docker run\n' >&2
    exit 1
  fi
}

main "$@"
