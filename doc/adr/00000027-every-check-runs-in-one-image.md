# 每一項檢查都在同一份映像內執行，本機與 CI 一致

> 服務：不變式 2（絕不靜默失效）

- **Date:** 2026-09-04
- **Status:** Accepted
- **Relates to:** ADR-00000026（單一頂層套件）、ADR-00000025（commit 慣例取樣自 base）

## Context

本 repo 的檢查曾以三種方式跑：CI 的 YAML 逐項列出工具、本機的 `just test lint`
呼叫另一份清單、以及開發者手邊碰巧裝了什麼。三者的差異已造成四次實際誤判：

| 事件 | 本機說 | 實際 |
|---|---|---|
| `pyproject.toml` 的 `pythonpath` | 測試收集失敗，像是專案壞了 | 本機 pytest 6.2.5 不認得該選項，**靜默忽略** |
| hadolint 的 `DL3006` | 乾淨 | CI **連續六次全紅**——本機沒有 hadolint，lint 靜默跳過 |
| `#56` 的 `io` 撞名 | 直譯器完全啟動不了 | 容器（3.11）是 `ModuleNotFoundError`。同一個 bug 兩種面貌，本機那個更誤導 |
| workflow 表達式 | 無人可驗 | actionlint 只存在於 CI，而它抓的是 YAML parser 看不到的那一層 |

第二項當時的修法是「工具缺席改為中止而非通過」。那把**靜默跳過**換成**明確跳過**，
是改善，但**跳過的檢查仍然沒跑**——綠燈的意義仍然取決於執行者裝了什麼。

## Decision

`docker/Dockerfile.test-tools` 是唯一的檢查環境，含 Python 3.11、
`requirements-dev.txt`、shellcheck、hadolint、actionlint、bats、git。

`script/test.sh` 在偵測到自己不在該映像內時（`CM_IN_TEST_IMAGE`），
自行建置並轉進容器重跑；CI 只呼叫 `./script/test.sh`，不安裝任何工具。
**一份映像，兩個呼叫者。**

逃生口是 `CM_TEST_LOCAL=1`，且沿用既有行為：缺什麼就指名什麼，明確跳過。

工具版本一律釘住。會自己變動的 linter 會讓無關的 commit 變紅，
而遇到無法解釋的紅燈，人的第一個反應是不再信任這個閘門。

## Alternatives

- **在 CI 的 YAML 裡逐項 `apt-get install`。** 先前的做法。它與本機清單是兩份，
  而兩份清單一定漂移——這正是六次紅燈的成因。
- **把工具做成應用映像的一個 `-test` stage。** 兩者目標相反：應用映像要盡可能小，
  這個要帶齊每一支 linter。把工具鏈拖進應用的 build graph 會讓每次應用建置變慢，
  且 `runtime` 有可能意外繼承到工具。
- **要求開發者自己裝齊七支工具。** 無法檢查，也無法保證版本一致。
  「請先安裝下列工具」這句話的成功率，等於它出現在 README 第幾行。

## Consequences

- 跑檢查需要 docker。這是本專案的既有前提（產出物就是容器），不是新增依賴。
- 首次執行要建置映像（約一分鐘），之後走 layer cache。
- 映像預設使用台灣的 Debian 鏡像：`deb.debian.org` 是 Fastly anycast，
  從本專案開發所在的網路連不上，而**只能在 GitHub runner 上建起來的映像，
  不可能是大家都用來跑檢查的那一個**。以 `CM_APT_MIRROR` 覆寫。
  選用的鏡像同時提供 `/debian` 與 `/debian-security`——較近的兩個只有前者，
  而只改主檔案庫會讓 security 那行仍指向連不上的主機，`apt update` 照樣失敗。
- 新增檢查工具時只改 Dockerfile 與 `test.sh` 的 `run_lint`，CI 不需同步。

---

**Amendment (#406, 2026-11-21):** 決策未變，「唯一的檢查環境」的適用範圍改了：**它不再涵蓋本機 git hook。**
維護者 11/20 定案（#406 的 Q2、Q5）：git hook 登記的檢查（`script/githook-checks/<進入點>/`）由 `script/githook.sh`
在主機上直接跑，不經 docker。這是給 git hook 的例外，不是給檢查的例外：

- `script/test.sh`（`just test`）與 CI 仍在 `docker/Dockerfile.test-tools` 這同一份映像裡跑。「一份映像，兩個呼叫者」不變，
  git hook 不是第三個呼叫者。
- git hook 是 commit、push 之前提早攔的一層，不是證據。主機工具和映像不同造成的差異——本 ADR 的 Context 那四次——在那裡
  仍然可能發生，所以**CI 是最後一道**：hook 登記的每一支檢查，CI 都在映像裡跑同一支。
- 主機缺 bash 4 以上（`PATH` 上先找到的那一支）、python3 或 git 時，hook 擋下並寫出下一步，不放行。這延續上面
  「工具缺席改為中止而非通過」的同一條線：缺工具不得靜默通過。

#391 原本把 hook 的檢查也轉進這份映像。那個做法讓打開 hook 的 checkout 每次 commit、push 都要用 docker，與「docker 先問」
衝突，所以 #406 拿掉了那個入口。
