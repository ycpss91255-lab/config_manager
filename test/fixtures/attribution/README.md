# 署名防護的放行樣本（#405）

`no_attribution.bats` 拿這兩份當 `gh issue create --title t --body-file <檔>` 的內文，確認說明署名規則的
issue 本身不會被擋下：它們只在行中引用共同作者行、`Generated with` 那一行與 session 網址的寫法。

- `issue-269.md`：#269 的內文
- `issue-405.md`：#405 的內文（勾選框都還沒勾）

兩份都是 2026-11-21 以 `gh issue view <編號> --json body --jq .body` 取得的快照，之後 issue 再改也不更新。
