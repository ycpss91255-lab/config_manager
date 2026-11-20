#!/usr/bin/env bash
#
# commit-msg：commit 訊息裡的 Claude 署名與 session 連結（#405）。
# 判定在 script/lint_attribution.sh，樣式在 script/attribution-patterns.txt（CI 的 attribution job 與 Claude Code 的
# hook 讀同一份）；這裡只把 git 給的訊息檔交給它。在哪裡跑照 script/githook.sh（#391）。
set -euo pipefail

exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/lint_attribution.sh" commit-msg "$1"
