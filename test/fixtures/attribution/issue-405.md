#### 問題說明
- `CLAUDE.md:73-75`（#269）：commit、PR、issue、留言不加 Claude Code 署名，也不放 claude.ai 的 session 連結。現在只有文字，沒有東西擋。
- #269 第 1 步是在 `~/.claude/settings.json` 加 `attribution`。
  - 維護者的 Mac 上 11/20 查：這個欄位不存在，repo 的 `.claude/settings.json` 也沒有。
  - 工作階段收到的系統提醒仍要求 commit 加 `Co-Authored-By`、PR 加「Generated with」。
- #269 第 2 步是「用 hook 擋寫入（第二道）」。
- #269 留言 7001049098（ycpss91255，11/19）的盤點：main 帶署名的 commit 181 個，其中含「Generated with」或 session 連結的 17 個。同一則留言寫「本 issue 只記錄盤點結果；改寫歷史、force-push 與設定變更需 owner 另行決定後再執行。」
- 真實署名的實際格式（11/20 用 `git log origin/main -n 400 --format=%B` 數 main 最近 400 個 commit 的訊息，以及 PR #246 的描述）：
  - 共同作者行與 session 行都從行首開始：`Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`（也有 `Co-authored-by` 的寫法）、`Claude-Session: https://claude.ai/code/session_<ID>`；
  - PR 描述的署名行也從行首開始：`🤖 Generated with [Claude Code](https://claude.com/claude-code)`。
- 說明署名的文字（例如 #269 內文、本 issue）會在行中引用這些字樣。樣式要分得出真實署名和行中引用，否則連這類 issue 都開不了。
- 改成 merge commit 之後（〔合併規則〕），PR 分支上的每個 commit 都原樣進 main。
- 先例：`ycpss91255-research/vendor_kit` 的 `.claude/hooks/attribution_guard.py`。

#### 維護者定案
- Q2（11/20，原話「2+git hook 也允許在本機跑」，經 config_manager 工作階段轉達）：做 #269 第 2 步加第 3 步（第 3 步是〔B2〕），不改寫 git 歷史、不 force push。
- Q3（原話「放進 repo 不要放 global」）：第 1 步的 `attribution` 改放 repo 的 `.claude/settings.json`。
- Q1：Claude Code hook 在主機跑，只讀工具呼叫的輸入（指令文字、帶入的檔），不跑專案程式與測試。
- Q8（config_manager 依既有規則代為決定）：hook 看不到該看的內容時擋下並寫出下一步，不默默放寬保護。
- Q4：不設 milestone。
- #269 的第 4 步（改寫歷史）、第 5 步（側欄）不做，照上面 7001049098 那句等 owner 另行決定。

#### 調整需求
1. **repo 設定**：`.claude/settings.json` 加 `"attribution": { "commit": "", "pr": "", "sessionUrl": false }`（照 #269 第 1 步原文）。
2. **一份樣式清單** `script/attribution-patterns.txt`：一行一個延伸正規式，不分大小寫，逐行比對。本 issue 有三個呼叫端（第 3～5 點）；〔B2〕是第四個，由〔B2〕自己驗收。四條樣式和各自的適用範圍：
   - `^Co-Authored-By:.*(claude|anthropic)`：只認行首。
   - `^Claude-Session:`：只認行首。
   - `^(🤖 )?Generated with \[Claude Code\]`：只認行首。
   - `https://claude\.ai/code/session_[A-Za-z0-9_-]+`：完整的 session 網址（帶 ID），**任何位置都算**，包括行中、反引號裡。規則本身就是不公開 session 連結（`CLAUDE.md:73-75`），引用也一樣。要舉例就寫 `session_<ID>` 這類不完整的寫法。
   - 不單獨比對 `noreply@anthropic\.com`：真實署名都帶 `Co-Authored-By:` 前綴，單獨比對 email 會擋到說明文字。
3. **Claude Code PreToolUse hook** `script/claude-hooks/no-attribution.sh`（matcher `Bash`）：
   - 檢查的指令：`git commit`、`gh pr|issue create|edit|comment`、`gh release create|edit`、會寫入的 `gh api`；
   - **先取出要寫出去的文字，再逐行比對**，不拿整條指令去比（整條指令裡，第一行訊息排在 `-m`、`--body` 或引號後面，行首樣式會看不到）：
     - `git commit`：`-m`／`--message` 的值、`-F`／`--file` 帶入的檔、`--trailer` 的值（每個 trailer 照 `<鍵>: <值>` 當成一行比對）。
       - 只認這些旗標：上面三個，加上 `-a`／`--all`、`--amend`、`--no-edit`、`--allow-empty`、`-q`／`--quiet`、`-s`／`--signoff`。出現其他旗標就照 Q8 擋下，例如會帶入訊息的 `-C`、`-c`、`--reuse-message`、`--reedit-message`、`--fixup`、`--squash`、`-t`／`--template`、`-e`／`--edit`；
       - `--no-verify` 也擋：它會跳過第 4 點的 commit-msg 檢查；
       - `--amend --no-edit` 也擋（Q8）：它沿用 HEAD 的訊息，hook 只看工具輸入（Q1）確認不了那段訊息、也確認不了 commit-msg 檢查有沒有打開。下一步寫「明帶訊息：`--amend -m …` 或 `--amend -F <檔>`」；
     - `gh pr|issue|release`：`-t`／`--title`、`-b`／`--body`、`-n`／`--notes` 的值，以及 `-F`／`--body-file`、`--notes-file` 帶入的檔。
       - 只認不會改寫文字的旗標：上面這幾個，加上 `-R`／`--repo`、`-d`／`--draft`、`-B`／`--base`、`-H`／`--head`，以及 label、assignee、reviewer、milestone、project 這幾類的旗標、`--edit-last`。
       - 出現其他旗標就照 Q8 擋下，因為本機核對不了實際送出的文字。例如 `--attach` 會改寫描述、可能重寫附件連結；還有 `-e`／`--editor`、`-w`／`--web`、`--fill` 系列、`-T`／`--template`、`--recover`、`--generate-notes`；
     - `gh api`：沒寫 `-X`／`--method` 時，帶了欄位（`-f`、`-F`）或 `--input` 都會預設用 POST（`gh api --help` 與 gh 2.100.0 的原始碼），所以有任何一個就當成寫入；寫了 `-X` 就照它判斷：
       - `-f`／`--raw-field` 與 `-F`／`--field` 是 `key=value`，比對解出的 value；
       - `-F key=@<檔>` 由 gh 讀檔，比對那個檔的內容；
       - `--input <檔>` 是 JSON：先解析，再比對每個字串欄位解碼後的內容（跳脫的換行要還原，才看得到行首）；
     - 取不出來就當成看不到，照 Q8 擋下：值來自 shell 變數或指令替換；從標準輸入讀（`@-`、`--input -`、`--body-file -`、`git commit -F -`）；`--input` 不是合法的 JSON；
     - 判定為寫入、卻沒有可檢查的文字的，也照 Q8 擋下：互動或編輯器模式（`gh … -e`／`--editor`、`--web`、少了標題或內文參數而會跳提示的 `gh issue|pr create`），以及上面列的那幾個 `git commit` 旗標；
   - 命中時以結束碼 2 擋下，寫出命中的樣式和行號，以及下一步（刪掉那一行；session 網址改成不完整的寫法）。不重抄命中的內容，免得完整的 session 網址又進到工作階段紀錄；
   - 讀不到輸入、讀不到帶入的檔、沒有 python3 時擋下並寫出下一步（Q8）。
4. **git commit-msg 檢查** `script/githook-checks/commit-msg/20-no-attribution.sh`。在哪裡跑照當時的 `script/githook.sh`：〔F〕合併前在映像裡，合併後在本機。
5. **CI**：`attribution` job＋`script/lint_attribution.sh`，只在 pull_request 跑：
   - 檢查 PR 範圍內每個 commit 的訊息、PR 標題、PR 描述；失敗時只印位置（哪個 commit、標題或描述、第幾行）與命中的樣式，不印命中的內容，免得完整的 session 網址進到公開的 CI 紀錄；
   - 列進 `ci-rollup` 的 needs 和 `--pull-request` 組，merge_group、push 時允許跳過（〔合併規則〕的 merge job 經 `ci-rollup` 等到它）。
   - 已知缺口：595a2ee 的 `ci.yaml` 的 `pull_request:` 沒寫 types，只在 opened、synchronize、reopened 跑。本 issue 合併到〔合併規則〕上線之間，在網頁上改 PR 標題或描述不會重跑 `attribution`，原本的綠燈會留在同一個 head 上。這個缺口等〔合併規則〕把 `edited` 加進觸發條件才補齊；本 issue 不改觸發條件，避免和〔合併規則〕改同一處。
6. `AGENTS.md` 的署名那段補一句：由哪幾層擋、擋不到哪些。`doc/TEST-PLAN.md` T19、`doc/GIT-HOOKS.md` 加列。

#### 驗收條件
- [ ] `.claude/settings.json` 有 `attribution`，三個欄位照 #269 第 1 步。
- [ ] `no-attribution.sh` 以結束碼 2 擋下並指名命中的那一行：
  - `git commit -m` 的訊息有一行 `Co-Authored-By: Claude …`；
  - `gh pr create --body-file` 的檔有 `🤖 Generated with [Claude Code](…)` 那一行；
  - `gh issue comment` 的內文在一段說明的行中引用了完整的 session 網址；
  - 署名就是訊息的第一行：`git commit -m "Co-Authored-By: Claude …"`；
  - 訊息乾淨、署名放在 trailer：`git commit -m "clean" --trailer "Co-Authored-By: Claude <noreply@anthropic.com>"`；
  - `gh api` 的三種帶法各一例：`-f body='…'` 的值第一行是共同作者行、`-F body=@f`（f 裡有 `Generated with [Claude Code]` 那一行）、`gh api repos/<owner>/<repo>/issues/1/comments --input j.json`（沒有 `-X`、`-f`、`-F`；`body` 欄位裡跳脫的換行後面接著共同作者行）。
- [ ] `no-attribution.sh` 放行：
  - 只在行中引用 `Co-Authored-By`、`Generated with` 字樣、session 網址寫成 `session_<ID>` 的內文，包括直接寫在指令參數裡的（例如 `--body "說明 Co-Authored-By 那一行要刪"`）；
  - 用 #269 目前的完整內文、本 issue 的內文當輸入的 `gh issue create --title t --body-file f`（標題和內文都明帶）；
  - `git log --grep Co-Authored-By`、`gh pr view` 這類唯讀指令。
- [ ] 用了清單以外的旗標，照 Q8 以結束碼 2 擋下（沒有命中的行可以指名）：`gh pr edit 12 --attach a.png`、`gh pr edit 12 --body-file f --attach a.png`（f 沒有署名）都擋，訊息指出是 `--attach` 讓實際送出的描述核對不了，並寫出下一步（附件在網頁上加，或把附件網址直接寫進 `--body-file` 的內文）。
- [ ] 讀不到 hook 輸入、`--body-file` 指的檔不存在、從標準輸入讀（`gh api -F body=@-`、`gh api --input -`、`gh issue create --title t --body-file -`、`git commit -F -`）、`gh issue create -e`、只帶 `--body-file` 沒帶標題的 `gh issue create`（會跳提示）、`git commit -C HEAD~1`、`git commit --no-verify -m x` 時擋下並寫出下一步。
- [ ] `git commit --amend --no-edit`、`git commit --amend --no-edit --trailer "x: y"` 都擋下，下一步寫明帶訊息；`git commit --amend -m "clean"` 放行。
- [ ] CI 失敗時的輸出只有位置與樣式，沒有命中的內容。
- [ ] 命中完整 session 網址時，擋下的訊息裡沒有那個網址。
- [ ] commit 訊息含任一樣式時，commit-msg 進入點以非零結束。
- [ ] `lint_attribution.sh`：PR 範圍內有 commit 命中、PR 標題命中、或 PR 描述命中時失敗並指名；都沒有時通過。
- [ ] `ci-rollup` 把 `attribution` 列在 pull_request 時必須 success 的那一組；merge_group、push 時允許跳過。
- [ ] 第 3～5 點的三個呼叫端都讀同一份 `script/attribution-patterns.txt`。
- [ ] T19 與 `doc/GIT-HOOKS.md` 有對應的列。

#### 轉成可合併前核對（寫在 PR 描述，不是勾選項）
- 先記下前提：使用者層的 `~/.claude/settings.json` 沒有 `attribution`（11/20 查過）；兩個 worktree 都沒有 `.claude/settings.local.json`；沒有用命令列參數改設定。
- **有無 repo 設定的對照**：同一個用戶端、同一種做法，各做一次，記下差別。
  - 沒有設定：在 main 的 worktree（repo 還沒有 `attribution`）開新工作階段；
  - 有設定：在這個分支的 worktree 開新工作階段。
- 觀察兩個欄位：
  1. `commit`：請它照預設把要用的 commit 訊息寫到暫存檔，不 commit，比較兩邊的訊息：有設定時沒有共同作者行。直接 commit 的話，有設定的那邊也裝了本 issue 的 hook，被 hook 擋下只能記成 hook 攔截，不能當成設定的效果；
  2. `pr`：請它照預設寫一份 PR 描述存到暫存檔，不開 PR。這是草擬路徑的觀察，不是實際建立 PR 時送出的內容。有設定時沒有 `Generated with` 那一行。
- `sessionUrl` 核對不了：依官方設定參考，它管的是 cloud 或 Remote Control 工作階段在 commit 加的 `Claude-Session` trailer，以及在 PR 描述加的 session 網址；本機工作階段本來就不加這個連結，所以本機的對照看不出它的效果。照 #269 第 1 步原文保留這個欄位，寫進「擋不住」。
- 設定的優先順序依官方設定文件。優先順序較高的設定（`.claude/settings.local.json`、命令列參數等）可能蓋過它，這點寫進「擋不住」。

#### TDD red
- 要附。照現行做法：在功能分支用 workflow_dispatch 跑出 `bats` job 失敗（`ci.yaml` 的 `bats` job 沒有事件條件，dispatch 會跑）。
- PR 描述記下那一輪的 run、失敗的規格、預期的失敗原因、那個 commit 的主旨。
- `attribution` job 只在 pull_request 跑，不拿它當 red。
- 〔合併規則〕若比本 issue 先合併，改照它調整需求第 6 點：red 要是這個 PR 自己的一輪 pull_request 執行，失敗在 `bats` job 的 `specs` 步驟，而且那一步的紀錄有規格層級的失敗（`not ok`）；功能分支上手動觸發的不算。

#### 擋得住／擋不住
- 擋得住：本機 Claude Code 寫入的 commit、PR、issue、留言；打開 hook 的 clone 上的 commit；PR 裡的 commit、PR 標題和描述（CI）。
- 擋不住：
  - 網頁上直接寫的內容；
  - 〔合併規則〕上線前，網頁上改 PR 標題或描述之後不會重跑 CI（見第 5 點）；
  - cloud 工作階段、`disableAllHooks`；
  - 優先順序較高的設定蓋掉 `attribution`（hook 和 CI 仍會擋）；
  - `sessionUrl` 在本機驗證不了（只影響 cloud 或 Remote Control 工作階段的 commit trailer 與 PR 描述）；
  - `--no-verify`；
  - 樣式以外的寫法，例如沒從行首開始的共同作者行；
  - 既有的舊內容：說明由〔B2〕處理，git 歷史不改（Q2）。

#### 不在範圍
- #269 第 3 步（〔B2〕）、第 4 步（改寫歷史）、第 5 步（側欄）。
- 關閉 #269：本 PR 用 `Closes #<本 issue>`，描述裡只提 #269。

#### 依賴與 milestone
- #404先合併；排在〔合併規則〕的 PR 之前（〔合併規則〕要確認 `attribution` 是 `ci-rollup` 的必要相依）。不設 milestone（Q4）。

#### 同組 issue
這張屬於「流程規則改成 hook 與 AGENTS.md」那一組。內文用代號指同組的其他 issue；全部開完後，會在每張留言補上代號和編號的對照（不改內文）。
- #404 規範正本改成 AGENTS.md（同組，已開）
- 〔B〕署名防護
- 〔B2〕清既有說明裡的署名
- 〔C〕agent 不合併、PR 要綁 issue 的 hook
- 〔D〕主機檢查與推送的 hook
- 〔E〕規範補錄
- 〔F〕git hook 改在本機跑
- 〔G〕docker 先問等環境規則
- 〔H〕Codex 審稿紀錄
- 〔合併規則〕另一組的合併規則 issue（CI 的 merge job、每個 PR 綁 issue、TDD red 與 milestone 順序）

