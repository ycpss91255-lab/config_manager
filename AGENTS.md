# AGENTS.md（CLAUDE.md 是指向本檔的 symlink；要改規範，改本檔）

`config_manager` 的 agent 指引。**先讀 `CONTEXT.md`** 取得領域用語——用那裡的詞，不要另造同義詞。

## 這是什麼

集中式 config 管理系統：config repo 是唯一真實來源，寫出至目標位置，變更前先驗證，偏離會被呈現而非自動處置。Python 3.11 + FastAPI backend；目前只有核心層落地。

閱讀順序：`CONTEXT.md` → `doc/PRD.md`（9 條不變式，不得違反）→ `doc/adr/`（為什麼長成這樣）→ `doc/TEST-PLAN.md`（已確認的測試介面）。

## 分層

`api → core → io` 單向（ADR-00000011）。以頂層模組名匯入（`from config_manager.core.config_list import load`、`python -m config_manager.api.cli`）。

- `src/config_manager/core/` — 純邏輯，**不做 I/O**：需要檔案內容？當參數傳進來。核心層的每個測試都在無檔案系統、無 git、無網路的情況下執行。
- `src/config_manager/io/` — 檔案系統與 git 的 adapter。所有東西都在單一頂層套件底下，因為頂層的 `io/` 會遮蔽 stdlib 的同名模組，甚至讓直譯器無法啟動（ADR-00000026）。
- `src/config_manager/api/` — HTTP 端點與 CLI（CLI 是 HTTP client，ADR-00000009）。
- `src/config_manager/web/` — 單一 HTML 入口（`index.html`）；`help.html` 是靜態說明頁，介面上的字改了要一起改（#54）。

## 工作流程

- **依 milestone 與 issue 推進。** 照 GitHub milestone 的順序做（`gh issue list --milestone v0.1.0`），不要跳版。
- **分支 → 草稿 PR → CI 的 merge job 合併。** 新工作開 feature branch，開**草稿** PR；檢查全過由 CI 的 merge job 以
  merge commit 合併（見下面「合併規則」）。**agent 不自己合併。** **不得直推 `main`。** 推之前先 `git fetch` 加 `git rebase origin/main`——這個 org 是多人共推。
- **force push 的範圍只到「別人手上有的分支」。** 自己的 feature branch 在 rebase 之後
  以 `--force-with-lease` 推回去是**正常且必要**的：分支保護要求 head 與 base 同步才准
  合併，而 rebase 一定改寫 SHA。`--force-with-lease` 而非 `--force`，因為前者會在遠端
  有你沒看過的東西時停下來。
  **絕不對 `main` 或任何別人也在推的分支 force push。**
  Claude Code 的 PreToolUse hook `script/claude-hooks/host-push-rules.sh` 在本機擋推送的寫法（#409）：每個目的地都寫死成
  完整的 ref（`git push -u origin feat/x:refs/heads/feat/x`），推到 main、不帶 lease 的 force push、清單外的旗標都擋；
  「只推自己的分支」hook 判斷不了，由執行的人確認。
  （這條先前寫成「不得 force push」，兩個獨立的工作流各自把它讀成「連自己的分支都不能
  rebase 後推」，於是把該 rebase 的 PR 留在落後狀態。規則的範圍沒寫清楚，等於規則沒寫。）
- **自己無法決定的事**（owner 層級／架構）→ 開 GitHub issue 並等待，但不要空轉：同時去做另一個沒被擋住的 issue。
- **已交付行為的 bug** → `fix` 加 patch 版號；一個 milestone 的功能是 minor。
- **一張 issue 對應一個 PR。** PR 先開成草稿（`gh pr create --draft`）；issue 的驗收條件**全部勾完**、TDD red 與驗證結果
  寫進 PR 之後才 `gh pr ready`——做不完就把 issue 拆小，一張需要三個 PR 才做得完的 issue，本來就是三件事。一張 issue 只對應
  一個已合併的 PR：被完成過（已關閉，或已有「由 PR #<n> 合併完成」的紀錄）的 issue 不能再綁，新的工作另開 issue。
- **標題任務編號限制**（#351）：一則 commit 主旨、一個 PR 標題、一張 issue 的標題，最多列一個 F 項與一個 `#` 編號
  （同一個出現兩次算一個；`F33～F35`、`F37、F38` 這類範圍與列舉算多個），scope 只能有一個；一個 PR 以關閉關鍵字
  只綁一張 issue；寫 `F36（#345）` 時，#345 的標題或內文要有 `F36`。有 sub-issue 的 issue 沒有豁免。由
  `script/lint_single_task.sh` 擋：本機 hook（`just setup hooks` 之後）與 CI 的 `single-task` job。**它數的是編號，
  不證明內容只有一個任務**——拆不拆仍照「一張 issue 對應一個 PR」判斷。
- **issue 是帳本，PR 是描述。** 每完成一條驗收條件就 commit 一次，並把該 commit 的
  **主旨**記在那條勾選行後面：`- [x] 條件文字 — <commit 主旨>`。PR 描述寫的是
  「做了什麼、為什麼、被否決的選項、突變檢查、驗證數字」，不是進度。
  驗證數字（驗證結果）要寫明受測的 head、CI run、逐項判定，以及結果的限定（例如只在哪個環境驗過、哪些沒驗）（#411；個人規則）。
  什麼時候全部勾完、附 TDD red 與驗證結果，照下面「合併規則」的「合併程序」第 3 步，這裡不另定時點。
  由 `script/lint_checkpoints.sh` 在 CI 檢查（未勾、沒記 commit、主旨在 git 歷史裡
  找不到，三者皆擋）。
  **記主旨不記 SHA**：rebase 會改寫 SHA，而這個 repo 規定推送前 rebase、分支要和 main 同步才合併
  ——綁在 SHA 上等於每次合併前手動重填一輪帳本（#129 實測過兩次）。
- **每個 PR 都要綁一張 issue；新功能一定先有 issue。** PR 描述用關閉關鍵字（`Closes #N`）綁一張本 repo 還沒完成的 issue，
  由共用的綁定判定（`script/pr_binding.sh`）在 CI 擋（#407 定案 8）。原本可以不開 issue 的兩種例外（人工驗收的
  F 項修正、維護者直接要求的純文件或流程修改）**取消**：每一個 F 項修正與純文件或流程修改，都要先擬 issue、經審稿工作階段
  判「可以開」（下面「開 issue 與發留言的條件」）、開 issue，再開 PR。

  新功能依實際內容判斷，不只看 commit 的 `feat` 標籤——多了使用者看得到的新行為、新端點、新設定或新的資料格式就是新功能，
  即使是在驗收期間、由驗收發現引出來的也一樣。
  （這條是 2026-11-09 定的。之前驗收期間有兩個新功能只開了 PR、沒有 issue：#336 草稿記主人、
  #339 可選的請求紀錄。維護者決定不補開 issue，這個流程差異留在這裡。）
- **開 issue 與發留言的條件**：細節見 `doc/agents/reporting.md`「開 issue 前的審稿」；由 `script/issue_draft.sh` 與 Claude Code 的
  hook `script/claude-hooks/issue-rules.sh` 擋（#413，「每條規則由哪一層擋」第 30 列）。
  - **issue 草稿與 issue 本文的修改，交給協調工作階段另開的審稿工作階段審**：不經 Codex，寫的人也不自己審（協調工作階段自己寫的
    也一樣）。逐點處理意見（採納就改、不採納附證據），改完再審，直到判定通過：開 issue 判「可以開」、改本文判「可以發」；開了或改了
    之後，在 issue 留言附最後一輪的判定與適合公開的意見摘要；協調工作階段向維護者簡單說明審了哪些項目。
    出處：2026-11-24 維護者原話「不用 Codex。你再開一個窗口審核」。「另開窗口」是另開審稿工作階段、寫的人不自己審、改本文也要審，
    是協調工作階段的理解。子工作階段用 SendMessage 請協調工作階段開審稿工作階段、不自己開；沒有協調工作階段時，寫草稿的工作階段
    請維護者另開：這兩點是執行細節（協調工作階段定的，不是原話）。
  - **怎麼送（#413）**：寫的人把標題與內文寫進 `.issue-drafts/<名稱>/title.txt`、`body.md`，執行
    `script/issue_draft.sh submit <名稱> --new`（改本文時 `--edit <編號>`），把它印出的那段話用 SendMessage 送給協調工作階段；審稿工作
    階段照那段話審，把意見寫成檔、最後一個非空行寫判定，執行 `script/issue_draft.sh verdict <名稱> <雜湊> <意見檔>`；判定通過後，寫的人
    或協調工作階段執行 `script/issue_draft.sh create <名稱>`（改本文是 `edit <名稱>`）。送出的是判定通過而且雜湊相同的那一份；執行
    `submit` 與 `verdict` 的工作階段 id（`CLAUDE_CODE_SESSION_ID`）相同就不放行。直接 `gh issue create`、`gh issue edit` 改標題或本文、
    `gh api` 開或改 issue，由 hook 擋。
  - **勾帳本不算本文修改，不送審**：只把未勾的 `[ ]` 改成 `[x]`、行尾加 ` — <commit 主旨>`（`-`、`*`、`+` 開頭的勾選框都算），用
    `script/issue_tick.sh <編號> <條件片段> <commit 主旨>`，hook 不擋它。（協調工作階段 2026-11-25 定的例行做法）
  - **判「可以開」就開，不必問維護者；不亂開、不開了又關。** 需要 owner 層級或架構決定的事，仍照上面「自己無法決定的事」等維護者
    決定，審稿不取代那個決定。（11/20 Q6 前半「開 issue 不用問我」；個人規則，見下面「工作階段的規則」）
  - **要發的留言**（回寫到其他 issue 的內容、對外的更正，例如 #407 回寫 #373 那則）由協調工作階段 `config_manager` 自己審一遍
    （2026-11-21 #407 定案 15，現行），向維護者簡單說明審了哪些項目，然後就發；不送審稿工作階段。11/24 的問句只問開 issue，所以
    這一半不變，是協調工作階段的理解。
  - **工作階段在自己的 PR、issue 上寫進度和結果**，不必先給協調工作階段審；照 `doc/agents/reporting.md`「精確措辭」寫，不加署名
    （「Commit 訊息」），不放本機路徑。（協調工作階段的指示，11/24）
  - **issue 提案的底線**：不預設縮小驗收範圍、事實與推論分開、草稿審過才發、核可發留言不等於核可實作等 5 條，逐條見
    `doc/agents/reporting.md`「issue 提案底線」。（個人規則）
  - 舊規則紀錄：2026-11-20 定草稿要 Codex 審過（Q6 後半「codex 要看過」），由寫草稿的工作階段自己呼叫 Codex（原話「應該是工作階段自己呼叫 不是你呼叫」）；
    2026-11-21 #407 定案 15 取消 Codex，改由協調工作階段自審 issue 草稿與要發的留言；2026-11-24 issue 草稿與本文修改改由審稿工作階段審。
- **討論記在哪裡**：對 issue 的討論記在 issue；TDD red 證明與對 PR 的討論寫在 PR。
- **決策要寫回它被提出的地方。** 討論定案後，把決策、佐證、以及被否決的選項與理由寫回該 issue 或 PR，不要只留在對話裡。關閉帶驗收條件的 issue 時，**證據附在 issue 上，勾選框實際勾起來**。

## 工作階段的規則（#411）

下面這些原本只在 Claude Code 的本機記憶或協調工作階段的指示裡，別台機器、其他 agent 工具、cloud 工作階段都看不到；照維護者定案寫進 repo
（Q3 原話「放進 repo 不要放 global」；總則原話「這些能做成hook 就做成 hook 不要用記憶來處理，要有明確規範」）。每條一句，細節在
`doc/agents/reporting.md`（Q9）；每條由哪一層擋，見「合併規則」的「每條規則由哪一層擋」。括號裡是出處：「個人規則」指原本只在
本機記憶裡的維護者個人規則。

**回報與提問**

- **回覆一律用繁體中文**，包括進度句和指令說明。Bash 工具的指令說明沒有中文字由 hook 擋
  （`script/claude-hooks/env-rules.sh`，#412）；回覆本身沒有工具擋。（個人規則；Q3）
- **白話、一步一步教；第一行是結果或下一步；清單最多 5 項。** 見 `doc/agents/reporting.md`「回報給維護者的寫法」。（個人規則；協調工作階段的指示；Q3）
- **措辭要精確**：事實與推論分開、歸因有佐證、用精確名稱、不默默放寬保護等 6 條，逐條見 `doc/agents/reporting.md`「精確措辭」。（個人規則）
- **設計選擇分三類**：例行實作選擇自己決定並寫依據、測試介面看是不是新的觀察位置、驗收規則變更要有依據或維護者確認，逐條見
  `doc/agents/reporting.md`「設計選擇分三類」。（個人規則）
- **回報或提問前先讀相關 issue 的最新內文與留言；提案、定案、實驗結果分開寫；已定案的不重問；提問前逐題對照全部定案，例行選擇
  自己決定並寫依據。** 子工作階段要人決定的問題，先用 SendMessage 送協調工作階段，不直接問維護者，也不把一輪結束在「等使用者回答」；
  協調工作階段能決定的自己決定，真的需要維護者決定的才由它去問；沒有協調工作階段時，直接回報維護者，一樣先對照定案。順序與細節見
  `doc/agents/reporting.md`「回報與提問之前」。（個人規則；11/20 維護者意見；11/21 維護者原話「請問你沒有收到其他工作階段的問題嗎
  為什麼是由工作階段直接問我」，經轉達）

**工作階段與環境**

- **每個 PR、issue 開一個獨立的工作階段處理與驗證。**（個人規則；Q3）
- **不切換主 checkout 的分支**：新工作從最新的 `origin/main` 另開 worktree，在 worktree 裡做。主 checkout 裡的 `git switch`、
  `git checkout <分支>` 由 hook 擋（`env-rules.sh`，#412）。（協調工作階段的指示；Q3）
- **docker 指令先問**，包括會開 docker 的 repo 腳本與 recipe（`./script/test.sh`、`just test`、`just docker …`）；本機跑
  `./script/test.sh` 也先問（含 `CM_TEST_LOCAL=1`）；驗收證據以 GitHub CI 為準，本機的結果不算（「品質閘門」）。由 `.claude/settings.json`
  的 `permissions.ask` 與 hook 先問，入口清單是 `script/claude-hooks/docker-entrypoints.txt`；編輯後自動跑的 `script/check_file.sh`
  只提醒、不開 docker（#412）。（個人規則；Q3）
- **不碰 `cm_verify_*` 驗證環境**：那是維護者人工驗收用的容器與 volume（`doc/USER-VERIFICATION.md` 的準備表），不啟動、不停止、
  不重建、不改。會開 docker 的入口加上指令裡的 `cm_verify` 由 hook 擋（#412）。（個人規則；Q3）
- **不讀 token 檔**：存放存取 token 的檔（例如維護者機器上檔名含 token 的筆記）不讀、不搜尋到、不複製。由 hook 與
  `Read(//**/*token*.md)` 的 deny 規則擋；Grep 工具與 Bash 的遞迴搜尋（`grep -r`、`rg`…）一律擋，要讀單一檔案用 Read（#412）。
  （協調工作階段的指示；Q3）
- **動工前先查證現況**：issue 內容常過期（已被後來的 PR 做掉卻沒關、引用的行號已經移動），先查 main、`git log`、`doc/TEST-PLAN.md`
  再動手。（個人規則）

## 合併規則（#407）

維護者 2026-11-20 定案：檢查全過，由 CI 的 `merge` job 以 merge commit 合併（照 `ycpss91255-lab/sim_asset`，不用
merge queue、不用 auto-merge）。流程是：開 issue → 新分支 → 本機測試 → 推到分支跑 CI → 開草稿 PR → `gh pr ready` 時
跑完整的 CI 驗證（含 acceptance），全過由 merge job 合併。**agent 不自己合併**（定案 16）。

原則：**真正擋的是伺服器端**（GitHub ruleset、CI）；hook 只是提早擋、給清楚的訊息（git hook 要先 `just setup hooks`，
Claude Code hook 只對 Claude Code 有效）；兩種都擋不了的部分寫在這裡。CI 的判定由 PR 自己那一版的 workflow 決定：
一個 PR 可以改掉自己的守門程式讓自己通過，本 repo 信任所有有 push 權限的人（#407 查證 A），不另設關卡。

### 每條規則由哪一層擋

這是唯一一張「規則和擋它的工具」對照表（第 20 列起由 #411 補上）。**改了任何一層，這張表要一起改。**「hook」欄標了 issue
編號、還沒實作的，現在只有 CI 與 ruleset 在擋；「真正擋的那一層」寫「只靠文字」的，現在沒有任何工具在擋。

| # | 規則 | 真正擋的那一層 | hook | 擋不了的部分 |
|---|---|---|---|---|
| 1 | 不直推 main、不 force push、不刪 main | ruleset | #409：`script/claude-hooks/host-push-rules.sh` 擋目的地是 `refs/heads/main` 的 `git push`（含刪除 main）與不帶 lease 的 force push | git 設定造成的額外推送（`push.followTags`、`push.recurseSubmodules`、`remote.<name>.mirror`）：hook 不讀設定，由 ruleset 擋 |
| 2 | 由 CI 的 merge job 以 merge commit 合併；agent 不合併，網頁合併只由維護者操作 | 只擋「合併方式」：ruleset 只允許 merge commit，加上第 3、4 列的條件。伺服器端沒有限制「誰可以送出合併」 | #408 第 1 點：`script/claude-hooks/pr-rules.sh` 擋 agent 的 `gh pr merge`、寫入 `pulls/<n>/merge` 的 `gh api`、合併類 mutation 的 `gh api graphql`、`mcp__ccd_pr__set_auto_merge` | 「agent 不合併」「網頁合併只由維護者、照下面的程序」是規範 |
| 3 | `ci-rollup` 通過，而且分支和最新的 main 同步，才合併 | ruleset（必要檢查＋strict） | 同上 | 落後時 rebase 再推送 |
| 4 | PR 的 review 討論串解決才合併 | ruleset | 不需要 | 解決後要手動重跑 merge job（沒有觸發事件） |
| 5 | `v*` tag 不能刪、不能 force push，tag 的 commit 要有 `ci-rollup` 通過（#164） | tag ruleset | 不需要 | 發版前先在 main 手動觸發 CI（推論、未實測）；發壞時改打下一個 rc 或下一個 patch 版 |
| 6 | 每個 PR 都開到 main，用關閉關鍵字綁一張本 repo 還沒完成的 issue，描述和 GitHub 的關閉參照指同一張，標題與 commit 訊息不另外關別的 | CI：共用的綁定判定 `script/pr_binding.sh`（checkpoints、single-task、merge-gate、merge job 都用它；擷取規格只有 `script/closing-references.txt`） | #408 第 2 點：`pr-rules.sh` 擋 `gh pr create`、`gh pr edit` 的描述沒有關閉關鍵字、解析出兩張以上或不是本 repo 的 | 網頁上開的 PR（hook 看不到，CI 擋） |
| 7 | 附 TDD red：這個 PR 的一輪 pull_request 執行（任一次 attempt）失敗在可認定 red 的 job 的 `specs` 步驟、紀錄有規格層級的失敗（純文件可寫「不適用：<理由>」） | CI：merge-gate | #408 第 4 點：`script/claude-hooks/pr-ready-reminder.sh` 在 `gh pr ready` 之後提醒檢查全過會被合併、附 TDD red（固定提醒，hook 沒讀描述） | 失敗的是不是這個 PR 新增的規格、原因是不是預期的，要靠 review |
| 8 | 前面的 milestone 沒關，後面 milestone 的 PR 不合併 | CI：merge-gate | 不需要 | milestone 關閉後要手動重跑（沒有觸發事件） |
| 9 | PR 一律先開成草稿；驗完才轉成可合併 | merge job 略過草稿；GitHub 也不能合併草稿 | #408 第 3 點：`pr-rules.sh` 擋草稿旗標的有效值不是 true 的 `gh pr create` | 什麼時候轉成可合併 |
| 10 | 改了 PR 描述後重新檢查 | CI：`pull_request` 有 `edited`，使用者或 agent 帳號改描述就重跑（GITHUB_TOKEN 的編輯不會）；合併前另有 merge job 的重判 | 不需要 | — |
| 11 | 合併後核對 merge job 成功、issue 已關 | 沒有 | 做不到：合併發生在 GitHub 上 | 整條 |
| 12 | 對 issue 的討論記在 issue；TDD red 與對 PR 的討論寫在 PR | CI 只核對 PR 描述裡有 `## TDD red` 段落 | 不需要 | 其餘 |
| 13 | 合併前跑完 acceptance、署名檢查等全部檢查 | CI：都列進 `ci-rollup`，merge job 只等 `ci-rollup` | 不需要 | — |
| 14 | repo 的保護設定和下面「repo 保護設定」表一致（第 1～5 列的設定沒被改掉） | CI：`repo-rules`（列進 `ci-rollup`） | 不需要 | bypass 名單讀不到；只在 CI 跑的時候才發現 |
| 15 | 不是 PR 的觸發不能替 PR 開綠燈：手動觸發的 `ci-rollup` 只在 main 上會綠 | CI：`ci_rollup.sh` 遇到 workflow_dispatch 而 ref 不是 main 就失敗 | 不需要 | 在功能分支上手動觸發仍看得到各 job 結果，但不能當合併或 TDD red 的依據 |
| 16 | `git push` 寫完整的目的地 ref | 沒有（推到 main 由 ruleset 擋） | #409：`host-push-rules.sh` 只認寫死的 `refs/heads/<名稱>`／`refs/tags/<名稱>`；沒寫 refspec、沒寫 `:<dst>`、matching、萬用字元、清單外的旗標都擋 | git 設定造成的額外推送（同第 1 列） |
| 17 | force push 只用 `--force-with-lease`，只推自己的分支 | ruleset 擋 main；其他分支沒有 | #409：`host-push-rules.sh` 擋 `--force`、`-f`、`+` 開頭的 refspec、`--no-force-with-lease` | 「只推自己的分支」：hook 不知道分支是誰的，由執行的人照上面「工作流程」確認 |
| 18 | commit、PR、issue 與留言不帶 Claude 署名與 session 連結（#405） | CI：`attribution`（PR 的 commit 訊息、標題與描述，列進 `ci-rollup`） | repo 的 `attribution` 設定、Claude Code 的 PreToolUse hook、本機 commit-msg 檢查（已實作，#405） | 網頁上直接寫的內容、留言（見上面「Commit 訊息」） |
| 19 | 檢查工具一律在容器裡跑，不在主機直接跑（`CM_TEST_LOCAL=1 ./script/test.sh` 是明文的例外；下面「品質閘門」） | CI 在容器裡跑，主機的結果不算證據 | #409：`host-push-rules.sh` 擋 Claude Code 經 Bash 在主機直接跑 `pytest`、`ruff`、`mypy`、`pylint`、`bats`、`shellcheck`、`hadolint`、`actionlint` 與 `python -m pytest\|ruff\|mypy\|pylint` | 間接呼叫（`python -c`、`uv run`、自寫腳本、別名）；cloud 工作階段（Edit／Write 之後的 `check_file.sh` 自 #412 起只提醒、不跑檢查） |
| 20 | 本機 git hook 登記的檢查在主機上直接跑、不經 docker；那是提早攔的一層，不是證據（#406；「品質閘門」） | CI：在容器裡跑同一組檢查，是最後一道 | 本機 git hook：`.githooks/` → `script/githook.sh`（`just setup hooks` 之後）；有登記的檢查而主機缺 bash 4 以上、python3 或 git 時擋下 | `--no-verify`、沒打開 hook 的 clone；主機工具和映像不同造成的差異 |
| 21 | 既有的 PR 與 issue 說明裡的署名與 session 連結要清掉，不改 git 歷史（#410） | 沒有：一次性的清理（新寫的署名由第 18 列擋） | 不需要；清理用 `script/scrub_attribution.sh`（試跑列出、`--apply` 寫回），執行紀錄在 `doc/review/2026-11-24-attribution-scrub.md` | 說明的編輯紀錄、留言、commit 訊息；`--apply` 比對和寫入之間的空檔裡別人的修改 |
| 22 | 回覆一律用繁體中文，包括進度句和指令說明（「工作階段的規則」） | 指令說明：沒有伺服器端的一層；本機 Claude Code 由 hook 擋（hook 欄）；回覆本身只靠文字 | #412：`script/claude-hooks/env-rules.sh` 擋 Bash 的 `description` 沒有中日韓文字 | 回覆本身；分不出繁簡；cloud 工作階段、`disableAllHooks` |
| 23 | 白話、一步一步；第一行是結果或下一步；清單最多 5 項 | 只靠文字 | 沒有 | 整條 |
| 24 | 每個 PR、issue 開獨立的工作階段處理與驗證 | 只靠文字 | 沒有 | 整條 |
| 25 | docker 指令先問；本機跑 `./script/test.sh` 先問 | 沒有伺服器端的一層；本機 Claude Code 由 hook 擋（hook 欄），另有 `.claude/settings.json` 的 `permissions.ask` | #412：`env-rules.sh` 對 `script/claude-hooks/docker-entrypoints.txt` 上的入口回傳 ask（規格遞迴掃 `script/` 核對清單）；`check_file.sh` 的 hook 模式只提醒、不開 docker | Python 腳本自己開 docker、不在清單上的間接呼叫；cloud 工作階段、`disableAllHooks` |
| 26 | 驗收證據以 GitHub CI 為準 | 合併只認 CI：ruleset 要 `ci-rollup`（第 3 列） | 不需要 | 回報與驗收紀錄裡把本機結果當證據 |
| 27 | 不碰 `cm_verify_*` 驗證環境 | 沒有伺服器端的一層；本機 Claude Code 由 hook 擋（hook 欄） | #412：`env-rules.sh` 在清單上的入口加上指令裡的 `cm_verify` 時擋下（deny 優先於 ask） | 依連接埠連進驗證環境；不經清單上入口的寫法 |
| 28 | 不讀 token 檔 | 沒有伺服器端的一層；本機 Claude Code 由 hook 擋（hook 欄），另有 `permissions.deny` 的 `Read(//**/*token*.md)` | #412：`env-rules.sh` 擋 Read、Edit、Write、Grep、Glob 與 Bash 指名檔名含 token 的 `.md`；Grep 工具與 Bash 的遞迴搜尋一律擋（Grep 讀不讀得到範圍裡指向 token 檔的 symlink 判斷不了、實測做不到，照 Q8 擋，2026-11-25 改），下一步是用 Read 讀單一檔案 | 自寫的程式自己開檔；檔名不含 token 的 token 檔；Bash 經名字不含 token、指向 token 檔的 symlink 讀檔（hook 只看指令文字） |
| 29 | 不切換主 checkout 的分支，在 worktree 裡做 | 沒有伺服器端的一層；本機 Claude Code 由 hook 擋（hook 欄） | #412：`env-rules.sh` 擋主 checkout 裡的 `git switch`、`git checkout <分支>`／`-b`，只放行確認是 linked worktree 的目錄；判斷不了目錄也擋 | 腳本裡、git 的別名、先 `export GIT_DIR` 這類別的寫法 |
| 30 | 開 issue 前與改 issue 本文前，草稿交給協調工作階段另開的審稿工作階段審，不經 Codex、寫的人不自己審；開了或改了之後留言附最後一輪的判定；勾帳本不送審（「工作流程」的「開 issue 與發留言的條件」） | 沒有伺服器端的一層；本機由腳本與 Claude Code 的 hook 擋（hook 欄） | #413：`script/issue_draft.sh` 只送審稿判定通過、而且雜湊和目前草稿相同的那一份，執行 `submit` 與 `verdict` 的工作階段 id 相同就停；`script/claude-hooks/issue-rules.sh` 擋直接 `gh issue create`、`gh issue edit` 改標題或本文、`gh api` 開或改 issue、指令裡改寫工作階段 id、寫入或刪除 `.issue-drafts/<名稱>/snapshots/`；`issue-reminder.sh` 開了或改了之後提醒留言；勾帳本用 `script/issue_tick.sh` | 換一個工作階段送審或下判定（只比對 id，分不出內容是誰寫的）；改腳本、別處的同名腳本、整段是變數的路徑、自寫程式寫紀錄、`gh alias`；網頁上開或改、cloud 工作階段、`disableAllHooks`；審得好不好；開了之後的留言（只提醒） |
| 31 | 判「可以開」就開，不必問維護者；不亂開、不開了又關；owner 層級或架構的決定仍等維護者 | 只靠文字 | 沒有 | 整條 |
| 32 | 動工前先查證現況（main、`git log`、`doc/TEST-PLAN.md`） | 只靠文字 | 沒有 | 整條 |
| 33 | 回報或提問前先讀 issue 最新內容；提案、定案、實驗結果分開；已定案不重問；提問前逐題對照全部定案 | 只靠文字 | 沒有 | 整條 |
| 34 | 子工作階段要人決定的問題先送協調工作階段；沒有協調工作階段時直接回報維護者 | 只靠文字 | 沒有 | 整條 |
| 35 | 紅燈判讀：預期紅卻綠先核對測試走到重現路徑；不為了紅燈改斷言（「TDD」） | 只靠文字（merge-gate 只核對有 red，第 7 列） | 沒有 | 整條 |
| 36 | PR 描述的驗證結果寫明受測 head、CI run、逐項判定與限定（「工作流程」的帳本那條） | 只靠文字 | 沒有 | 整條 |
| 37 | 精確措辭 6 條（`doc/agents/reporting.md`） | 只靠文字 | 沒有 | 整條 |
| 38 | 設計選擇分三類（`doc/agents/reporting.md`） | 只靠文字；第 2 類走到「新增一個測試介面」時，其中兩步由 `lint_test_interfaces.sh` 擋（「TDD」） | 沒有 | 分類本身 |
| 39 | issue 提案底線 5 條（`doc/agents/reporting.md`） | 只靠文字 | 沒有 | 整條 |
| 40 | 人工驗收：批次交付；完整絕對路徑只用在交給操作者的指令；退路指令另外給；判定照錄原話（`doc/CLAUDE-VERIFICATION.md`） | 只靠文字 | 沒有 | 整條 |
| 41 | 要發的留言（回寫到其他 issue、對外的更正）由協調工作階段自審（#407 定案 15，11/21）；自己 PR、issue 上的進度與結果不必先審 | 只靠文字 | 沒有 | 整條 |

### 合併程序

1. 推到功能分支，手動觸發 CI 看各 job 結果（`gh workflow run ci.yaml --ref <分支>`；過渡做法，等 #373 定分支推送的 CI）。
   這一輪的 `ci-rollup` 一定紅（非 main 的手動觸發只供參考），也不算 TDD red。
2. 開**草稿** PR：`gh pr create --draft --title '<合規的標題>' --body-file <檔>`，描述要有 `Closes #<issue>`。草稿每次推送都跑 PR 上
   的完整 CI（含 PR 專屬的檢查），TDD red 在這裡取得；merge job 略過草稿，不會合併。
3. issue 的驗收條件**全部勾完**、`## TDD red` 與驗證結果寫進 PR 之後，執行 `gh pr ready <n>`。那一輪跑全部檢查，全過就由
   merge job 以 merge commit 合併，並關掉綁定的 issue、留言「由 PR #<n> 合併完成。」。
4. **合併後核對**：merge job 成功、issue 已關並有那則留言。bot（GITHUB_TOKEN）合併之後 main 不會再跑一輪 CI：分支和 main
   同步（strict）時，合併進去的內容就是 PR 的 CI 測過的內容（#407 查證 B）。維護者在網頁上合併時是使用者帳號的推送，`push` 到
   main 的觸發照樣會跑 main 那一輪。

**TDD red 的寫法**：PR 描述的 `## TDD red` 段落放這個 PR 自己的 pull_request 執行連結，另寫失敗的是哪一條新規格、預期的
失敗原因、對應哪個 commit 主旨（CI 核對不了這三項，由 review 核對）。功能分支上手動觸發的舊 red 不算。PR 在草稿時要補 red：在
最新的 main 上重建一個只有失敗規格的 head，用 `--force-with-lease` 推到自己的分支，等那一輪 pull_request 執行留下合格的 red，
再把完整的修正 rebase 到最新 main 推回去。純文件（改的每個檔都在 `doc/` 底下或是 `.md`，含 `.agents/skills/`）可以寫
「不適用：<理由>」。

**merge job 紅了，看它的紀錄**：

- 落後 main：rebase 到最新的 main 再推送。
- 討論串沒解決：解決後 `gh run rerun <run> --failed`。
- 前面的 milestone 剛關閉：`gh run rerun <run> --failed`。
- 不是最新的一輪、或 head 已經不是這一輪的：看最新那一輪。
- merge job 自己失敗或卡住：查紀錄回報原因，修好後重跑，或由維護者在網頁上合併（下面）。**agent 一律不合併。**
- 只因為討論串沒解決而重跑失敗的 merge job（`--failed`）時，先前成功的 checkpoints 與 merge-gate 沿用舊結果就可以：merge job
  自己會用現況重判。

**merge job 被跳過或取消時**，照實際原因處理：

- fork 的 PR：merge job 本來就不跑，照下面的網頁合併。
- base 不是 main：綁定判定也會失敗；把 PR 的 base 改成 main。
- `ci-rollup` 的結果不是 `success`：先處理失敗的檢查。
- 那一輪是草稿時的事件：重跑沿用原本的事件內容，還是會跳過；要產生新的非草稿事件——`gh pr ready`、推一個 commit，或由使用者或
  agent 帳號改一次描述。
- 被取消（例如 `concurrency` 換成新的一輪）：PR 還沒合併時，看最新那一輪（被取消的那一輪仍是最新、不是草稿、head 仍是目前的
  head 時才可以重跑它）。PR 已經合併、還沒關 issue 時，重跑**原本那一輪**的 merge job 補作業：`gh run rerun <run> --job <merge job 的 id>`。
  它只在合併者是 bot、合併 commit 的第二個 parent 是那一輪的 head、合併紀錄的 run id 是那一輪時才補，issue 照合併紀錄。

**網頁合併**（只有維護者；適用所有 PR；只在兩種情況：這個 PR 最新那一輪非草稿 pull_request 執行的 `ci-rollup` 已經 `success`、
只有 merge job 的合併操作本身失敗；或 fork 的 PR）：

1. 先讀 PR 的最終狀態（重跑可能已經讓 bot 合併了）。
2. 重跑**這個 PR 最新那一輪**的 merge job（`gh run rerun <run> --job <merge job 的 id>`）。它用現況做和 bot 相同的重判，並在紀錄裡
   印出這份資料的識別。重跑完**再讀一次 PR 狀態**：這次合併成功了就結束。
3. 重判通過、只有合併操作又失敗時，人工核對那一輪 `ci-rollup` 的結論是 `success`，再拿紀錄裡印的識別和現況比對：PR 的
   `updatedAt` 與標題、描述各自的 sha256、每一張 issue 的編號與 `updatedAt`、milestone 順序用到的每一個 milestone 的 ID、標題與
   開關狀態、head sha。**全部相同**才以 merge commit 合併；任何一項不同（例如重跑後有人改了帳本、改綁、換 milestone，或重開了
   較早的 milestone，即使 PR 與綁定的 issue 本身沒變），停止，重跑之後再來。
4. 合併後，在綁定的 issue 留「由 PR #<n> 合併完成（網頁合併）」並關閉它（使用者帳號的合併通常會照關閉關鍵字自動關；沒關就手動
   關）。這句留言是之後判斷「這張已經被完成」的紀錄。

fork 的 PR：merge job 不處理 fork。網頁合併前，看這個 PR 最新的一輪、對應目前 head 的非草稿 pull_request 執行：checkpoints、
single-task、merge-gate 與 `attribution` 在最新的 attempt 重新執行過而且通過、`ci-rollup` 是 `success`；再拿 checkpoints、
single-task、merge-gate、`attribution`、test-interfaces 各自印的識別（含 `attribution` 讀到的標題與描述的 sha256、single-task 與
test-interfaces 讀到的其他 issue）和現況比對（同上），全部相同才合併。例如 `attribution` 讀到的是舊標題、之後標題被改、新的一輪
還查不到時，識別對不上，停止。

失敗原因記在對應的 issue；修正另開 issue（開之前照「工作流程」的「開 issue 與發留言的條件」送審稿工作階段審）。

### 發版程序

- **打 tag 前先在 main 手動觸發 CI**：`gh workflow run ci.yaml --ref main`，等那一輪的 `ci-rollup` 通過，tag 打在那一輪測的
  commit 上（`gh run view <run> --json headSha`）。**這是推論、未實測**：事實是 sim_asset 查到一個 bot 的合併 commit（`5356b74`）
  沒有任何檢查，而 tag ruleset（#164）要求 `ci-rollup`；推論是直接在 bot 的合併 commit 上打 tag 會被拒，手動觸發那一輪會在同一個
  commit 留下 `ci-rollup`。第一次發版時實測，把結果（main 手動觸發那一輪的 `ci-rollup` 結論、推上去的 tag、`release.yaml` 那一輪
  的連結與結論）補在這裡。
- `release.yaml` 跑的是 tag 指的 commit 裡的 `release.sh`：#407 合併後的第一次發版，tag 要打在含 #407 合併的 commit 上。
- **tag 不刪、不移**（定案 14）：rc 打錯或發壞，推 `script/release.sh --next <版號>` 印出的下一個 rc；正式 tag 發壞，改發推導出
  的下一個 patch 版（例如 `v0.9.0` 發壞就發 `v0.9.1`），patch 版用 `vX.Y.0` 的檢查點驗收。正式 tag 前一律先核對：同一個 SHA 上那個
  rc 的 release notes 裡 `--gate overall` 判定通過、覆蓋率 badge 一致，兩者都成立才打正式 tag。
- **兩種閘門**：CI 的 acceptance job 用 `--target --gate automated`（自動檢查全過、沒有未涵蓋就過，人工待驗不擋 PR）；發版的
  `release.sh` 用 `--gate overall`（人工檢查點也要簽完）。
- **簽核與 target 的先後**：讓目標版本整體通過的那一次簽核，要和「把對照表頂層的 `target` 推到下一版」放在同一個 PR。只放簽核
  的話，那個 PR 的 acceptance 會以 2 結束、`ci-rollup` 紅，訊息寫出這個下一步。之後在對照表加入「有自動檢查點、但還沒做完」的
  版本之前，要先解決 target 推進後會讓所有 PR 紅的問題（另開 issue）。

**v0.9.0 收尾的操作順序**：

1. 最後的簽核與 `target` 推進放在同一個 PR，由 bot 合併。
2. 在 main 手動觸發 CI，等那一輪的 `ci-rollup` 綠。
3. 在那一輪測的 SHA 上推 rc（`script/release.sh --next v0.9.0` 印出的號碼），看 release 的報表。
4. 第 4 步之前，先核對第 3 步那個 rc 的 release：notes 裡 `--gate overall` 的判定是通過、覆蓋率 badge 一致（rc 在 badge 不一致時
   仍會建立 release，rc 的 workflow 綠、標題寫通過都不夠）。核對過了，在同一個 SHA 上推正式 tag `v0.9.0`。
5. **正式 release 建好之後**才關閉 v0.9.0 的 milestone。
6. 重跑被 milestone 順序擋下的 PR（例如 PR #403）。

第 4 步發壞時（tag 已存在、release 沒建）：不刪不移，改發 `release.sh` 推導出的下一個 patch 版（第一次發壞而且那個號碼還沒被
用掉時是 `v0.9.1`；被占用就是下一個可用的號碼）。修正走一般的 PR 由 bot 合併 → 在 main 的新 SHA 手動觸發 CI → 以新 SHA 推
`--next <那個 patch 版號>` 印出的 rc → 核對同上 → 推那個 patch 版號。v0.9.0 的 milestone 等那個正式 release 建好才關。

### repo 保護設定

CI 的 `repo-rules` job（`script/lint_repo_rules.sh`）每一輪都讀 GitHub 上的實際設定，和這張表逐項比對，表上寫的與實際讀到的都印出來，
有一項不一致或讀不到就失敗（`repo` 那一列讀不到時例外：不失敗，印出「未自動核對：allow_merge_commit，以設定頁人工核對為準」）。
**改 repo 的保護設定，要在同一個 PR 改這張表。** 表的格式是固定的，腳本照它讀：每一列是對象（`repo`，或 `ruleset <名稱>`）、
項目與設定值（反引號包住的 JSON），規則的種類兩個方向都比，表上沒列的參數欄位不比、只印出來；細節見 `script/lint_repo_rules.sh --help`。

| 對象 | 項目 | 設定值 |
|---|---|---|
| repo | `allow_merge_commit` | `true` |
| ruleset main | `target` | `"branch"` |
| ruleset main | `enforcement` | `"active"` |
| ruleset main | `conditions.ref_name.include` | `["~DEFAULT_BRANCH"]` |
| ruleset main | `conditions.ref_name.exclude` | `[]` |
| ruleset main | `rules` | `["deletion", "non_fast_forward", "pull_request", "required_status_checks"]` |
| ruleset main | `pull_request.required_approving_review_count` | `0` |
| ruleset main | `pull_request.required_review_thread_resolution` | `true` |
| ruleset main | `pull_request.allowed_merge_methods` | `["merge"]` |
| ruleset main | `required_status_checks.required_status_checks` | `[{"context": "ci-rollup", "integration_id": 15368}]` |
| ruleset main | `required_status_checks.strict_required_status_checks_policy` | `true` |
| ruleset main | `required_status_checks.do_not_enforce_on_create` | `false` |
| ruleset Require CI for release tags | `target` | `"tag"` |
| ruleset Require CI for release tags | `enforcement` | `"active"` |
| ruleset Require CI for release tags | `conditions.ref_name.include` | `["refs/tags/v*"]` |
| ruleset Require CI for release tags | `conditions.ref_name.exclude` | `[]` |
| ruleset Require CI for release tags | `rules` | `["deletion", "non_fast_forward", "required_status_checks"]` |
| ruleset Require CI for release tags | `required_status_checks.required_status_checks` | `[{"context": "ci-rollup", "integration_id": 15368}]` |
| ruleset Require CI for release tags | `required_status_checks.do_not_enforce_on_create` | `false` |

**核對不了**（`repo-rules` 不比，也不因此算通過）：

- **誰可以繞過**（bypass 名單）：文件寫明 `bypass_actors` 只在呼叫者對那個 ruleset 有寫入權時才回傳。`repo-rules` 每一輪對每個 ruleset
  印一行「核對不了」，回應裡有這個欄位就把內容也印出來；由維護者在設定頁核對。實測（2026-11-23，PR #417 的 run 45122748820）：
  本 repo 的 `GITHUB_TOKEN` 讀兩個 ruleset 的詳情，回應裡都沒有 `bypass_actors`。
- **Actions 的「Workflow permissions」**：我們讀是 403。
- **只在 CI 跑的時候才會發現**：設定被改掉、又沒有人開 PR 或手動觸發 CI，就不會發現。
- **`GITHUB_TOKEN` 讀得到什麼**（實測，2026-11-23，PR #417 的 run 45122748820）：`rulesets` 列表、每個 ruleset 的詳情與
  `rules/branches/main` 都讀得到，25 項必驗項目都比得到；`repos/<repo>` 的回應裡**沒有** `allow_merge_commit`，所以那一列每一輪都印
  「未自動核對」，以設定頁為準（切換時，2026-11-22，有 admin 權限的帳號經 API 讀到 `true`，紀錄在 #407 的留言）。之後讀不到必驗項目，就是 `repo-rules` 失敗。

## Commit 訊息

格式沿用 base 的慣例，由 `script/lint_commit.sh` 檢查（ADR-00000025、ADR-00000028）。自查：`./script/test.sh --lint commit`。

- type 限 `feat fix docs refactor test chore ci perf`，其餘一律 fail
- `type(scope): ` 前綴必須存在且格式正確；句尾不加句號
- **主旨以中文書寫**，且是**陳述句**，說明現在什麼成立（`feat(state): 目標不存在時狀態判定為未部署`），不是「新增 X」這種祈使句
- **只有 type 與 scope 維持英文**——那兩個是給工具讀的識別碼（ADR-00000028）
- scope 與 issue 回指建議附上；長度不檢查

**不加 Claude Code 署名**（#269）：commit 內文不加 `Co-Authored-By:` trailer，PR 說明、issue 與留言不加
「Generated with Claude Code」那一行，也不放 claude.ai 的 session 連結。共同作者行會讓 GitHub 把一個
與本專案無關的 `@claude` 帳號列進 repo 的 Contributors；工具預設會加，所以這條要明寫。

由這幾層擋（#405），樣式只有一份 `script/attribution-patterns.txt`：

- repo 的 `.claude/settings.json` 設 `attribution`（commit、pr 空字串，`sessionUrl` false），Claude Code 不產生署名。
- Claude Code 的 PreToolUse hook `script/claude-hooks/no-attribution.sh`：`git commit`、`gh pr|issue create|edit|comment`、
  `gh release create|edit`、會寫入的 `gh api` 執行前，取出要寫的文字逐行比對。它在主機上跑，只讀指令文字與帶入的檔，
  不跑專案程式（#405 的 Q1：維護者允許 Claude Code hook 這樣在主機上跑）。**看不到的寫法一律擋**：值來自變數或
  指令替換（例如 `-m "$(cat <<'EOF' …)"`）、從標準輸入讀、要開編輯器或互動、清單外的旗標、`--no-verify`、
  `--amend --no-edit`。commit 訊息寫成字面的 `-m "…"`，或先寫進檔、下一條指令再 `-F <檔>`／`--body-file <檔>`。
- 本機的 commit-msg 檢查（`just setup hooks` 之後）與 CI 的 `attribution` job（PR 裡每個 commit 的訊息、PR 標題與描述）。

擋不到：網頁上直接寫的內容；cloud 工作階段與 `disableAllHooks`；優先順序較高的設定蓋掉 `attribution`（hook 與 CI 仍會擋）；
`sessionUrl` 在本機驗證不了；`--no-verify` 跳過的 git commit-msg 檢查；用 GITHUB_TOKEN 改 PR 標題或描述之後 CI 不會重跑（使用者或 agent 帳號改的會：#407 加了 `edited`）；
PR 標題含完整網址時仍會出現在 workflow 的執行名稱裡；沒從行首開始的署名行這類樣式以外的寫法；經腳本檔、別名執行的寫入，
以及 `gh pr review --body`、`gh issue close --comment` 這類沒列進 hook 的 gh 寫入（留言沒有第二道）；既有的舊內容。逐項見
`doc/TEST-PLAN.md` T19 的「署名防護」。

## 品質閘門（本機與 CI 同一組）

**所有檢查一律在容器內執行，絕不對這台主機跑。** 唯一的例外是本機 git hook 登記的檢查：它們在主機上直接跑、不經 docker
（維護者 11/20 定案，#406；ADR-00000027 的 Amendment）。那是提早攔的一層，不是證據——`just test` 與 CI 仍在容器裡跑，CI 是最後一道。

`./script/test.sh`（或 `just test`）會建置 `docker/Dockerfile.test-tools` 並把自己轉進容器重跑；CI 呼叫同一支腳本，不安裝任何工具。一份映像，兩個呼叫者（ADR-00000027）。綠了才推。
它會開 docker，本機要跑先問維護者（「工作階段的規則」）；沒在本機跑時，推到自己的分支，以那一輪 GitHub CI 的結果為準（「合併程序」第 1 步）。驗收證據一律以 GitHub CI 為準。（#411）

Claude Code 經 Bash 直接在主機跑 `pytest`、`ruff`、`mypy`、`pylint`、`bats`、`shellcheck`、`hadolint`、`actionlint`（含 `python -m …`），會被 PreToolUse hook `script/claude-hooks/host-push-rules.sh` 擋下（#409）；`./script/test.sh` 與 `CM_TEST_LOCAL=1 ./script/test.sh` 不擋。

不要為了「快速確認一下」就去呼叫主機的直譯器。**主機不是這個專案的證據**，而這句話不是風格偏好——它已經在這裡給過四個錯誤答案：

| 主機說 | 實際 |
|---|---|
| pytest 收集不到測試 | 主機的 pytest 6.2.5 靜默忽略 `pythonpath`，專案需要 8+ |
| lint 乾淨 | 主機沒有 hadolint，CI 因此連續六次全紅 |
| 直譯器無法啟動 | 在 3.11 下同一個 `io` 撞名（#56）是 `ModuleNotFoundError` |
| workflow 沒東西可檢查 | actionlint 只存在於 CI，而它讀的是 YAML parser 看不到的那一層 |

`CM_TEST_LOCAL=1` 仍可在主機跑。它會先盤點主機並列出**全部**缺少的檢查工具，然後停下。再加 `CM_LINT_ALLOW_MISSING=1` 才會跑其餘的，並重述哪些沒跑——**有跳過的執行不算通過**，不要把它報成綠燈。`CM_APT_MIRROR` 可覆寫映像的 Debian 鏡像。

- `ruff check src test`／`mypy --strict src/config_manager`／`pylint src`（10.00/10）／`pytest test/pytest --cov=src/config_manager`（`core`／`io`／`api`／`web` 各自下限 85，分開擋）
- shell 腳本需要 **bash 4+**（macOS 用 `brew install bash`，內建的 3.2 跑不動）
- 本機 git hook：`just setup hooks` 打開、`just setup hooks-off` 關掉；登記的檢查在這台主機上直接跑、不經 docker（上面那條的例外），
  主機要有 bash 4 以上、python3、git，缺了 commit 與 push 會被擋下。本機通過不算證據，CI 是最後一道。見 `doc/GIT-HOOKS.md`（#391、#406）

## TDD

紅 → 綠，一次一片。**測試只寫在 `doc/TEST-PLAN.md` 已確認的介面上**，絕不寫在未確認的介面上。期望值來自獨立來源；每個測試一個邏輯斷言；測試名稱說明程式碼做什麼，用 `CONTEXT.md` 的詞彙。

**紅燈判讀**（#411；個人規則）：預期紅卻是綠，先核對測試真的走到重現的路徑；不為了讓它紅而改斷言，斷言要改先回報；確認紅燈的原因
就是要修的問題，才修產品。

**新增一個測試介面**（不是在既有介面上加一條行為）走四步，詳見 `doc/TEST-PLAN.md`
的「新增一個測試介面」：

1. 先開 issue 寫下介面位置、為什麼既有介面觀察不到、要觀察哪些行為，並取得確認
2. **`doc/TEST-PLAN.md` 的那一段單獨一個 commit，不與任何 `test/` 底下的檔案同一個 commit**
3. 新增的 `### T<N>` 段落寫下來由 issue 編號
4. PR 描述引用該 issue

第 2 步是關鍵：介面與它的第一批測試落在同一個 commit 裡，與「先寫測試再回頭把介面
文件湊上去」在 git 歷史上無法分辨，於是 ADR-00000018 的「事先議定」退化成自我確認
（`T19`／`T20`／`T21` 實際發生過，#123）。

**哪兩步有工具擋、哪兩步沒有**（#144 已關閉，`script/lint_test_interfaces.sh` 由 PR #167 上線；#411 照它現在的程式寫）：

- **只管新增的介面標題**：一個 commit 對 `doc/TEST-PLAN.md` 的 diff 新增了一行符合 `### T<N> — ` 或 `### A<N> — ` 的標題，
  才檢查那個 commit。改寫既有的標題（diff 裡也會出現一行新增的標題）同樣會觸發；在既有段落加內容、在既有的 T19 加一列，都不檢查。
- **第 2 步由規則 A（`order`）擋**：加入新標題的那個 commit，不得同時變更 `test/` 底下的任何檔案，新增、修改、刪除都算
  （`git diff-tree --name-only` 判斷）。由 `./script/test.sh --lint interfaces` 執行，CI 的 lint job 經同一支腳本跑到。
- **第 3 步與「事先」由規則 B（`agreed`）擋**：新段落要有 `#<issue>` 回指，而且那張 issue 的建立時間（`createdAt`）早於加入
  標題的那個 commit 的 author date。由 CI 的 `test-interfaces` job 執行（要讀 issue，需要 token）。取 `#N` 的方式：只看這個
  commit 對 `doc/TEST-PLAN.md` 的新增行，先取新增的標題行本身的第一個 `#N`；標題行沒有，才往後掃新增行、取第一個 `#N`，遇到
  下一個新增的 T/A 標題才重設。所以往後掃時可能取到後面別的段落裡新增的 `#N`，不保證回指在新段落本身。
- **沒有工具的兩步**：第 1 步「取得確認」（工具證明不了維護者真的同意：同一個作者五分鐘前才開的 issue，兩條規則都過）與第 4 步
  「PR 描述引用該 issue」。這兩步只靠文字——依 §0.4，只寫在這裡的規範等同不存在，看到時不要當作它們已經被驗過。

## Agent skills

### Issue tracker

GitHub Issues（`ycpss91255-lab/config_manager`），以 `gh` CLI 操作。決策與驗收證據
一律寫回 issue。見 `doc/agents/issue-tracker.md`。

### Triage 標籤

狀態標籤用 `backlog` ／ `ready-to-agent` ／ `wontfix`；`needs-info` 與 `ready-for-human`
刻意無對應（沒有外部回報者）。見 `doc/agents/triage-labels.md`。

### 領域文件

單一 context：`CONTEXT.md` ＋ **`doc/adr/`**（不是 `docs/adr/`——skill 的預設路徑在這裡
是錯的）。見 `doc/agents/domain.md`。

### 回報、提問與開 issue

「工作階段的規則」與「開 issue 與發留言的條件」的細節（#411）。見 `doc/agents/reporting.md`。

## 改這份規範

要改規範就直接改 `AGENTS.md`，不要對 `CLAUDE.md` 寫入：`CLAUDE.md` 是指向本檔的 symlink（#404）。照
`.agents/skills/setup-matt-pocock-skills/SKILL.md`「改 `CLAUDE.md`」時，改的也是 `AGENTS.md`。

- **Edit、Write 工具**：對 `CLAUDE.md` 寫入會被拒絕（依 Claude Code 文件），直接改 `AGENTS.md` 省一步。
- **shell**：`sed -i` 這類先寫新檔再換名的工具，可能把 symlink 換成一般檔——GNU sed（Linux）依它的手冊，
  沒加 `--follow-symlinks` 時會換掉連結；macOS 內建的 BSD sed 實測是拒絕改 symlink。一般的 `>`、`>>`
  重新導向照連結寫進 `AGENTS.md`，不會換掉連結，但為了一致也直接寫 `AGENTS.md`。

改完以後由 `script/lint_agents_link.sh` 確認連結還在：CI 的 `lint` job 會跑到；本機是
`./script/test.sh --lint agents-link`（會開 docker）。
