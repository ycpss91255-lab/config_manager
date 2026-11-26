# 讀 PR 描述與 issue 內文的檢查遇到 CRLF 換行 — 2026-11-26 調查紀錄

> 對應：#420 驗收條件第 3 項（其他讀內文的檢查遇到 CRLF 的行為要查過、記在 #420；有問題的另開 issue）。
> 對象：CI 上讀 PR 描述、issue 內文或留言的檢查，加上 merge job 的快照。`lint_checkpoints.sh` 本身由 #420 的修正處理，不在這份紀錄。
> 依據分兩種，逐列標明：**實測**是在 GitHub CI 上跑過的規格；**推論**是只讀程式碼的判斷，沒有跑。

## 怎麼量的

- 暫時分支 `tmp/crlf-probe-420`（head `8f45c1d`），建在 #420 的修正 commit `18a57d1` 上。在下表五支檢查各自的規格檔尾端，加上名稱以「實測 #420」開頭的
  暫時規格：用那支規格現成的假資料，只把 PR 描述、issue 內文或留言的換行改成 CRLF，看結束碼與它指名了什麼。
- 手動觸發的那一輪：https://github.com/ycpss91255-lab/config_manager/actions/runs/45759557535 。`bats` job 的 `specs` 步驟 success，1..1098 沒有任何
  `not ok`，9 條「實測 #420」都是 `ok`。量完已刪分支，這些暫時規格沒有合併。
- 假資料經規格的假 `gh` 回成 JSON：CR 在 JSON 字串裡跳脫成 `\r`，各檢查用 `json` 解開之後，讀到的內文帶著 CR。
  **真的 `gh` 回的 JSON 有沒有保留 CR，沒有量。** 推論會保留：JSON 字串照樣跳脫控制字元，而 #418 的原始內文在 GitHub 的編輯紀錄裡是 `\r\n`
  （#420 的問題說明）。

## 結果

| 檢查 | 讀的內容 | 內文是 CRLF 時 | 依據 |
|---|---|---|---|
| `pr_binding.sh`（共用綁定判定；checkpoints、single-task、merge-gate、merge job 都呼叫它） | PR 描述的關閉關鍵字；綁定那張 issue 的留言（「由 PR #N 合併完成」） | 照樣綁定那一張；網頁合併的完成留言是 CRLF 時照樣算已完成、擋下 | 實測：「實測 #420：描述是 CRLF 換行時照樣綁定那一張」「實測 #420：網頁合併的完成留言是 CRLF 換行時照樣算已完成」。程式碼：關閉參照的樣式（`script/closing-references.txt`）以 `\s*` 接 `#[0-9]+`，留言從行首比對，行尾的 CR 碰不到 |
| `lint_merge_gate.sh` | PR 描述的 `## TDD red` 段落 | 段落、執行連結、純文件的「不適用：<理由>」照樣認得 | 實測：「實測 #420：描述是 CRLF 換行時，TDD red 段落與執行連結照樣認得」「實測 #420：描述是 CRLF 換行時，純文件 PR 的「不適用：<理由>」照樣認得」。程式碼：段落用 Python 的 `splitlines()` 切行，CR LF 算一個換行 |
| `lint_single_task.sh`（pr 模式） | PR 描述的 `Refs #N`／`Relates to #N`；關聯 issue 的內文（F 項對應） | Refs 引用的 issue 照樣檢查標題；只寫在內文的 F 項照樣對得上 | 實測：「實測 #420：描述是 CRLF 換行時，Refs 引用的 issue 照樣檢查標題」「實測 #420：issue 內文是 CRLF 換行時，F 項只寫在內文也照樣對得上」。程式碼：兩個樣式都沒有錨定行尾 |
| `lint_attribution.sh`（pr 模式） | PR 描述，逐行比對署名樣式 | 命中的行照樣抓到，行號照 CRLF 分行；沒有署名的照樣通過 | 實測：「實測 #420：描述是 CRLF 換行時，命中的那一行照樣抓到，行號照 CRLF 分行」「實測 #420：CRLF 換行、沒有署名的描述照樣通過」。程式碼：分行用 `\r\n\|\n\|\r` |
| `ci_merge.sh`（merge job） | 自己只拿 PR 描述算 sha256 當識別；帳本由重判裡的 `lint_checkpoints.sh` 判 | 在 `18a57d1` 上，issue 內文與 PR 描述都是 CRLF 時，重判通過、照樣合併 | 實測：「實測 #420：issue 內文與 PR 描述都是 CRLF 換行時，重判通過、照樣合併」。**修正之前 merge job 會被擋是推論**：重判跑的是同一支 `lint_checkpoints.sh`，它在 #420 的 TDD red 那一輪對 CRLF 內文以非 0 結束；修正之前的 merge job 本身沒有量 |
| `gh_snapshot.sh`（merge job 的快照） | 原樣記下 `gh` 的 JSON 輸出 | 不改內文 | 推論：依程式碼，記的是 JSON 文字，CR 在字串裡是跳脫的 `\r`，`text=True` 的換行轉換碰不到它。上一列的實測經過快照、結果是合併，和這個推論一致，但「不改內文」本身沒有單獨量 |
| `lint_test_interfaces.sh agreed`（merge job 重判的一道） | 只讀 issue 的 `createdAt` | 不讀內文，不受影響 | 推論（依程式碼） |

**結論：除了 `lint_checkpoints.sh`（#420 修正），沒有找到 CRLF 造成的問題，不另開 issue。**

## 現在有沒有受影響的 PR

- 2026-11-26 以 GitHub API 讀本 repo 全部的 issue 與 PR（issue 204 份、PR 230 份，含已關閉、已合併）：**內文含 CR 的 0 份**。
  #418 的 CRLF 是已經被改寫成 LF 的舊版本（#420 的問題說明）。所以 #420 修好之前，現在也沒有 PR 因此被擋著。
- 新寫的內文會不會是 CRLF，看用什麼寫：這份紀錄沒有量網頁、`gh` 各自送出的換行。

## 限定

- 實測用的是各規格的假 `gh`，每支只量了上表那一兩種寫法；只看結束碼與它指名的內容。
- 只有 CR、沒有 LF 的換行（舊式 Mac 的換行）沒有量。#420 的修正也只把 CRLF 換成 LF，這種換行照舊不處理。

## 另外看到的

- `script/issue_tick.sh`（勾帳本的工具，不是檢查）讀本文時本來就把 CRLF 換成 LF，送出的是 LF（`test/bats/unit/issue_tick.bats` 的「CRLF 的本文送出時是 LF」，
  上面那一輪也是 `ok`）。它檔頭把這件事寫成「#420 修好之前的繞法」：#420 修好之後，這個換法仍然無害，只是那句說明不再精確。#420 只改
  `lint_checkpoints.sh`，沒有動它。
- `script/issue_draft.sh` 拿 GitHub 上的標題與本文算雜湊（改本文前核對有沒有被別人改過），不逐行判讀；草稿本身不准有 CR（推論，依程式碼）。
