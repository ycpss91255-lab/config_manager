#!/usr/bin/env bash
#
# pre-push：要推上去的新 commit 的主旨，都符合標題任務編號限制（#351）。commit-msg 那一道擋不到
# rebase、cherry-pick 這類沒有經過它的 commit，所以推之前再看一次。判定在 script/lint_single_task.sh；
# 這裡只把 git 給的標準輸入交給它（remote 名稱與 URL 兩個參數用不到）。由 script/githook.sh 在這台
# 主機上直接執行（#391、#406）。
set -euo pipefail

exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/lint_single_task.sh" pre-push
