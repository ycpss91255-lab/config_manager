"""core/yaml_constructor — yaml 讀取的建構器：讀不成的值指出位置（#402）。

ruamel 依寫法把一個純量認成整數、浮點或時間戳，建構時才轉換：`0b_`、`._` 認得出是數字、
`2001-02-30` 認得出是日期，轉換卻失敗，拋出的是裸 IndexError／ValueError，沒有位置（#334 的
spike 量到 9 個字樣）。這裡在建構每個節點時接住這兩種，換成 ruamel 自己的 `ConstructorError`，
帶上那個節點在原文的起始位置——`core/parse` 的 `_parse_yaml` 本來就把 `YAMLError` 換成帶行號的
`SyntaxParse`，不另開一條錯誤的路。

獨立成一支模組，是因為 `core/parse.py` 已經貼近 pylint 的 1000 行上限。
"""

from __future__ import annotations

from typing import Any

from ruamel.yaml.constructor import ConstructorError, RoundTripConstructor

# 原因裡的型別用 ruamel 的說法（標籤的最後一段）；認不出的標籤統稱 value。
_KINDS = (
    ("tag:yaml.org,2002:int", "int"),
    ("tag:yaml.org,2002:float", "float"),
    ("tag:yaml.org,2002:timestamp", "timestamp"),
)


class LocatingConstructor(RoundTripConstructor):
    """round-trip 建構器，只多一件事：建構一個節點拋出 IndexError／ValueError 時，
    改丟帶那個節點位置的 `ConstructorError`。

    接在 `construct_object`：鍵、值、清單元素、merge（`<<`）併進來的值都經過它。
    最裡層的純量先接到；換成的 `ConstructorError` 不是 ValueError，外層的節點不會再包
    一次，位置也不會被換成外層的。只接 #402 量到的這兩種，其餘照 ruamel 原樣拋出。
    """

    def construct_object(self, node: Any, deep: bool = False) -> Any:
        try:
            return super().construct_object(node, deep)
        except (IndexError, ValueError) as exc:
            kind = next((name for tag, name in _KINDS if node.tag == tag), "value")
            raise ConstructorError(
                problem=f"failed to construct {kind}: {exc}", problem_mark=node.start_mark
            ) from exc
