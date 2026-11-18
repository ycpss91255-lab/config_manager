# 本機 git hook

`commit` 與 `push` 之前，先在本機擋下 CI 也會擋的東西（#391）。檢查本身由各自的 issue 登記（#350、#351）；
**目前還沒有登記任何檢查**，打開之後 commit 與 push 只會印一行「目前沒有登記任何檢查，放行」。

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
