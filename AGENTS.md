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
- **分支 → PR → squash。** 新工作開 feature branch，開 PR，由維護者 squash merge。
  **不得直推 `main`。** 推之前先 `git fetch` 加 `git rebase origin/main`——這個 org 是多人共推。
- **force push 的範圍只到「別人手上有的分支」。** 自己的 feature branch 在 rebase 之後
  以 `--force-with-lease` 推回去是**正常且必要**的：分支保護要求 head 與 base 同步才准
  合併，而 rebase 一定改寫 SHA。`--force-with-lease` 而非 `--force`，因為前者會在遠端
  有你沒看過的東西時停下來。
  **絕不對 `main` 或任何別人也在推的分支 force push。**
  （這條先前寫成「不得 force push」，兩個獨立的工作流各自把它讀成「連自己的分支都不能
  rebase 後推」，於是把該 rebase 的 PR 留在落後狀態。規則的範圍沒寫清楚，等於規則沒寫。）
- **自己無法決定的事**（owner 層級／架構）→ 開 GitHub issue 並等待，但不要空轉：同時去做另一個沒被擋住的 issue。
- **已交付行為的 bug** → `fix` 加 patch 版號；一個 milestone 的功能是 minor。
- **一張 issue 對應一個 PR。** issue 的驗收條件**全部勾完**才開 PR——做不完就把 issue 拆小，
  一張需要三個 PR 才做得完的 issue，本來就是三件事。（不開 issue、只開 PR 的例外有兩種，見下面
  「只開 PR 的兩種例外」。）
- **標題任務編號限制**（#351）：一則 commit 主旨、一個 PR 標題、一張 issue 的標題，最多列一個 F 項與一個 `#` 編號
  （同一個出現兩次算一個；`F33～F35`、`F37、F38` 這類範圍與列舉算多個），scope 只能有一個；一個 PR 以關閉關鍵字
  只綁一張 issue；寫 `F36（#345）` 時，#345 的標題或內文要有 `F36`。有 sub-issue 的 issue 沒有豁免。由
  `script/lint_single_task.sh` 擋：本機 hook（`just setup hooks` 之後）與 CI 的 `single-task` job。**它數的是編號，
  不證明內容只有一個任務**——拆不拆仍照「一張 issue 對應一個 PR」判斷。
- **issue 是帳本，PR 是描述。** 每完成一條驗收條件就 commit 一次，並把該 commit 的
  **主旨**記在那條勾選行後面：`- [x] 條件文字 — <commit 主旨>`。PR 描述寫的是
  「做了什麼、為什麼、被否決的選項、突變檢查、驗證數字」，不是進度。
  由 `script/lint_checkpoints.sh` 在 CI 檢查（未勾、沒記 commit、主旨在 git 歷史裡
  找不到，三者皆擋）。
  **記主旨不記 SHA**：rebase 會改寫 SHA、squash 會讓它消失，而這個 repo 三者都規定了
  ——綁在 SHA 上等於每次合併前手動重填一輪帳本（#129 實測過兩次）。
- **只開 PR 的兩種例外；新功能一定先有 issue。** 下面兩種**只開 PR、不開 issue**。它們都不引用
  issue，所以 `lint_checkpoints.sh` 沒有帳本可對——帳本在別處，不是沒有帳本：
  1. **人工驗收的 F 項修正**（驗收發現清單上要修的問題）：發現、維護者的決定、修正規格與重驗證據
     記在驗收紀錄裡（人工驗收的證據與發現清單，不在這個 repo），PR 描述引用它們、寫明是哪幾個 F 項。
  2. **維護者直接要求、且不涉及產品新功能的純文件或流程規範修改**（例如這一條本身）：PR 描述寫明
     是維護者直接要求、為什麼不開 issue。改到程式、測試或工具的行為就不算「純」文件。

  **新功能不在這兩種例外裡**，要先有 issue：依實際內容判斷，不只看 commit 的 `feat` 標籤——
  多了使用者看得到的新行為、新端點、新設定或新的資料格式就是新功能，即使是在驗收期間、由驗收
  發現引出來的也一樣。做法是先擬 issue 給維護者確認，確認後才開 issue，再開 PR。
  （這條是 2026-11-09 定的。之前驗收期間有兩個新功能只開了 PR、沒有 issue：#336 草稿記主人、
  #339 可選的請求紀錄。維護者決定不補開 issue，這個流程差異留在這裡。）
- **決策要寫回它被提出的地方。** 討論定案後，把決策、佐證、以及被否決的選項與理由寫回該 issue 或 PR，不要只留在對話裡。關閉帶驗收條件的 issue 時，**證據附在 issue 上，勾選框實際勾起來**。

## 合併規則（#407）

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
  印一行「核對不了」，回應裡有這個欄位就把內容也印出來；由維護者在設定頁核對。本 repo 的 `GITHUB_TOKEN` 實際回什麼沒有實測。
- **Actions 的「Workflow permissions」**：我們讀是 403。
- **只在 CI 跑的時候才會發現**：設定被改掉、又沒有人開 PR 或手動觸發 CI，就不會發現。
- **`GITHUB_TOKEN` 讀不讀得到 rulesets**：這幾個端點文件都標為只要 Metadata 讀取權；只有讀取權的使用者帳號實測讀得到
  （2026-11-20，base、cli/cli），`GITHUB_TOKEN` 沒實測，由 #407 的 PR 第一輪實測。讀不到就是必驗項目讀不到，`repo-rules` 失敗。

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
`sessionUrl` 在本機驗證不了；`--no-verify` 跳過的 git commit-msg 檢查；在網頁上改 PR 標題或描述之後 CI 不會重跑（#407 補）；
PR 標題含完整網址時仍會出現在 workflow 的執行名稱裡；沒從行首開始的署名行這類樣式以外的寫法；經腳本檔、別名執行的寫入，
以及 `gh pr review --body`、`gh issue close --comment` 這類沒列進 hook 的 gh 寫入（留言沒有第二道）；既有的舊內容。逐項見
`doc/TEST-PLAN.md` T19 的「署名防護」。

## 品質閘門（本機與 CI 同一組）

**所有檢查一律在容器內執行，絕不對這台主機跑。** 唯一的例外是本機 git hook 登記的檢查：它們在主機上直接跑、不經 docker
（維護者 11/20 定案，#406；ADR-00000027 的 Amendment）。那是提早攔的一層，不是證據——`just test` 與 CI 仍在容器裡跑，CI 是最後一道。

`./script/test.sh`（或 `just test`）會建置 `docker/Dockerfile.test-tools` 並把自己轉進容器重跑；CI 呼叫同一支腳本，不安裝任何工具。一份映像，兩個呼叫者（ADR-00000027）。綠了才推。

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

**新增一個測試介面**（不是在既有介面上加一條行為）走四步，詳見 `doc/TEST-PLAN.md`
的「新增一個測試介面」：

1. 先開 issue 寫下介面位置、為什麼既有介面觀察不到、要觀察哪些行為，並取得確認
2. **`doc/TEST-PLAN.md` 的那一段單獨一個 commit，不與任何 `test/` 底下的檔案同一個 commit**
3. 新增的 `### T<N>` 段落寫下來由 issue 編號
4. PR 描述引用該 issue

第 2 步是關鍵：介面與它的第一批測試落在同一個 commit 裡，與「先寫測試再回頭把介面
文件湊上去」在 git 歷史上無法分辨，於是 ADR-00000018 的「事先議定」退化成自我確認
（`T19`／`T20`／`T21` 實際發生過，#123）。**這四步目前沒有工具擋著，追蹤於 #144**
——依 §0.4，只寫在這裡的規範等同不存在，所以看到這段時不要當作它已經被驗過。

## Agent skills

### Issue tracker

GitHub Issues（`ycpss91255-research/config_manager`），以 `gh` CLI 操作。決策與驗收證據
一律寫回 issue。見 `doc/agents/issue-tracker.md`。

### Triage 標籤

狀態標籤用 `backlog` ／ `ready-to-agent` ／ `wontfix`；`needs-info` 與 `ready-for-human`
刻意無對應（沒有外部回報者）。見 `doc/agents/triage-labels.md`。

### 領域文件

單一 context：`CONTEXT.md` ＋ **`doc/adr/`**（不是 `docs/adr/`——skill 的預設路徑在這裡
是錯的）。見 `doc/agents/domain.md`。

## 改這份規範

要改規範就直接改 `AGENTS.md`，不要對 `CLAUDE.md` 寫入：`CLAUDE.md` 是指向本檔的 symlink（#404）。照
`.agents/skills/setup-matt-pocock-skills/SKILL.md`「改 `CLAUDE.md`」時，改的也是 `AGENTS.md`。

- **Edit、Write 工具**：對 `CLAUDE.md` 寫入會被拒絕（依 Claude Code 文件），直接改 `AGENTS.md` 省一步。
- **shell**：`sed -i` 這類先寫新檔再換名的工具，可能把 symlink 換成一般檔——GNU sed（Linux）依它的手冊，
  沒加 `--follow-symlinks` 時會換掉連結；macOS 內建的 BSD sed 實測是拒絕改 symlink。一般的 `>`、`>>`
  重新導向照連結寫進 `AGENTS.md`，不會換掉連結，但為了一致也直接寫 `AGENTS.md`。

改完以後由 `script/lint_agents_link.sh` 確認連結還在：CI 的 `lint` job 會跑到；本機是
`./script/test.sh --lint agents-link`（會開 docker）。
