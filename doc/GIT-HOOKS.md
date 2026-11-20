# 本機 git hook

`commit` 與 `push` 之前，先在本機擋下 CI 也會擋的東西（#391、#406）。檢查本身由各自的 issue 登記：

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

在這台主機上直接跑，不經 docker（維護者 11/20 定案，#406；改掉 #391 原本轉進檢查映像的設計）。`.githooks/<進入點>`
把 git 給的參數與標準輸入原樣交給 `script/githook.sh`，由它依檔名順序執行登記的檢查：

1. 先數登記的檢查。一支都沒有就放行並說明，不看主機工具。
2. 有登記的檢查，先確認主機有這三樣，缺任何一樣就擋下並寫出下一步，不放行：
   - **bash 4 以上**：看的是 `PATH` 上先找到的那一支，因為登記的檢查以 `#!/usr/bin/env bash` 啟動，用的就是它。
     macOS 內建的是 3.2：`brew install bash`，並讓 Homebrew 的 bin（例如 `/opt/homebrew/bin`）在 `PATH` 上排在 `/bin` 前面。
   - **python3**、**git**。
3. `commit-msg`：每支都收到 git 給的訊息檔路徑。`pre-push`：每支都收到 remote 名稱與 URL，以及完整的一份標準輸入
   （先存成暫存檔，再逐支餵）。
4. 任何一支失敗，hook 非零結束並逐支指名失敗的檢查；原因由各支自己印。

**這是提早攔的一層，不是證據。** 主機上的 bash、python3、git 版本和檢查映像不同，同一支檢查的結果可能不一樣
（ADR-00000027 的 Amendment）。CI 在映像裡跑同一支檢查，**CI 是最後一道**。`just test` 與 CI 仍然只在檢查映像裡跑。

## 登記一支檢查

放一個可執行檔到 `script/githook-checks/<commit-msg|pre-push>/`，依檔名順序執行：

- `commit-msg`：第一個參數是 commit 訊息檔的路徑。
- `pre-push`：兩個參數是 remote 名稱與 URL；標準輸入每一行是「本地 ref 本地 SHA 遠端 ref 遠端 SHA」。

失敗時以非零結束並在 fd 2 說明原因與下一步；任何一支失敗，git 就不繼續。

檢查在主機上跑，所以只用 `githook.sh` 先確認過的東西：bash 4 以上、git、python3 的標準函式庫。要用別的工具，
先把它加進 `script/githook.sh` 的主機確認（缺了要擋下並寫出下一步），再登記。

## 擋不到的

- `git commit --no-verify`、`git push --no-verify` 會跳過本機 hook；沒有打開 hook 的 clone 也沒有。**CI 的檢查是最後一道。**
- 主機工具和檢查映像不同造成的差異：本機通過、CI 沒過時，以 CI 為準。
- 圖形介面的 git 用戶端可能帶著不同的 `PATH`，先找到 macOS 內建的 bash 3.2：hook 照上面第 2 步擋下並說明，不會默默通過；
  要在那個用戶端裡 commit，讓它的 `PATH` 也先找到 bash 4 以上。
