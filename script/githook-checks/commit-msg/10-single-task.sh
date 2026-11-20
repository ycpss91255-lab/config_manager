#!/usr/bin/env bash
#
# commit-msg：commit 主旨的標題任務編號限制（#351）——最多一個 F 項、一個 #編號、一個 scope。
# 判定在 script/lint_single_task.sh，CI 的 single-task job 呼叫同一支；這裡只把 git 給的訊息檔交給它。
# 由 script/githook.sh 在這台主機上直接執行（#391、#406）。
set -euo pipefail

exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/lint_single_task.sh" commit-msg "$1"
