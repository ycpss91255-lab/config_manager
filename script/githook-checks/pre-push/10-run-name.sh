#!/usr/bin/env bash
#
# pre-push：要推上去的每一個 commit 裡，workflow 的 run-name 都分得出對應的 commit（#350）。
# 判定在 script/lint_run_name.sh，CI 的 run-name job 呼叫同一支；這裡只把 git 給的標準輸入交給它
# （remote 名稱與 URL 兩個參數用不到）。由 script/githook.sh 在這台主機上直接執行（#391、#406）。
set -euo pipefail

exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/lint_run_name.sh" --pre-push
