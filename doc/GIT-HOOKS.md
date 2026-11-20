# 本機 git hook

`commit` 與 `push` 之前，先在本機擋下 CI 也會擋的東西（#391）。檢查本身由各自的 issue 登記：

| 進入點 | 檢查 | CI 上的同一支 |
|---|---|---|
| `commit-msg` | `10-single-task.sh`：commit 主旨的標題任務編號限制——最多一個 F 項、一個 `#` 編號、一個 scope（#351） | `single-task` job |
| `commit-msg` | `20-no-attribution.sh`：commit 訊息的每一行有沒有 Claude 署名或完整的 session 網址，樣式在 `script/attribution-patterns.txt`（#405） | `attribution` job |
| `pre-push` | `10-run-name.sh`：要推的 commit 裡，workflow 的 `run-name` 分得出對應的 commit（#350） | `run-name` job |
| `pre-push` | `20-single-task.sh`：要推的新 commit 的主旨，同上的標題任務編號限制（#351） | `single-task` job |

本機只做不必讀 issue 的部分；PR 標題、關閉關鍵字綁定的 issue 數、F 項與 issue 的對應、關聯 issue 的標題，在 CI 的
`single-task` job 檢查。標題任務編號限制數的是編號，**不證明**一個 commit 或 PR 只有一個任務。

## 打開與關掉

```bash
just setup hooks       # 打開
just setup hooks-off   # 關掉
```

- 只設這個 repo 本地設定裡的 `core.hooksPath`（值是 `.githooks`），不改全域（`~/.gitconfig`）與系統設定，不安裝任何工具。
- **這份本地設定由這個 repo 的所有 worktree 共用**：在任何一個 worktree 打開，全部 worktree 都生效。
- 每個 worktree 用的是自己簽出的 `.githooks/`；**簽出的 commit 裡沒有 `.githooks/` 的 worktree 不會執行 hook**（例如還停在這個功能之前的分支）。
- 不覆蓋別人的設定：本地已經有別的 `core.hooksPath`、有單一 worktree 範圍（`git config --worktree`）的值，或從全域、系統繼承了值時，`just setup hooks` 停下並說明，不設。
- `just setup hooks-off` 只在本地的值是 `.githooks` 時拿掉它；是別的值、或值來自全域／系統時都不動，只說明。

## 檢查在哪裡跑

在檢查映像裡，不在這台主機上（與 `just test` 同一份映像，第一次會先建映像）。`.githooks/<進入點>` 把 git 給的參數與標準輸入原樣交給 `script/githook.sh`，再轉給 `script/test.sh --hook`；轉進容器時帶 `-i`，`pre-push` 每一行 ref 才進得了容器。

- docker 不能用、映像建不起來或 `docker run` 失敗時，commit 與 push 會被擋下，不放行。
- 環境裡的 `CM_TEST_LOCAL=1` 不會讓 hook 改在主機跑。

## 登記一支檢查

放一個可執行檔到 `script/githook-checks/<commit-msg|pre-push>/`，依檔名順序執行：

- `commit-msg`：第一個參數是 commit 訊息檔的路徑。
- `pre-push`：兩個參數是 remote 名稱與 URL；標準輸入每一行是「本地 ref 本地 SHA 遠端 ref 遠端 SHA」。

失敗時以非零結束並在 fd 2 說明原因與下一步；任何一支失敗，git 就不繼續。

## 擋不到的

- `git commit --no-verify`、`git push --no-verify` 會跳過本機 hook；沒有打開 hook 的 clone 也沒有。**CI 的檢查是最後一道。**
