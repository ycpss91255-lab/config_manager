"""io/default_hostname — 保存新納管預設主機名稱（清單檔的 `[defaults] hostname`，#385）。

外部互動層：這裡真的碰檔案系統與 git。

**只在納管新 config 時預填。** 既有條目一律讀自己的 hostname；修改這個預設值不替它們改名
（不變式 8、維護者 11/17）。寫回走 `core.config_list.dump`：只動 `[defaults]` 那一鍵，其餘逐位元組
不變，寫出前先自我驗證（不安全的名稱丟 `UnsafeDefaultHostname`，什麼都沒寫）。

**每次確認與修改記下修改前後的值與操作者**：一筆一般 commit（不是 T7 的變更紀錄——這個值不
屬於任何一筆條目，沒有 uid），作者是改的人。commit 沒成就把清單檔還原，與白名單的寫回同一個
做法（`io/allowed_roots._write_roots_and_commit`）：清單檔一被寫入，下一次納管就用它。
"""

from __future__ import annotations

import os
from subprocess import CalledProcessError

from config_manager.core.config_list import dump
from config_manager.io.atomic import replace_atomically
from config_manager.io.errors import DefaultHostnameLeftBehind, WriterError
from config_manager.io.git import commit, stage, unstage
from config_manager.io.preflight import CONFIG_LIST_NAME
from config_manager.io.repo import load_list, write_config_list


def save_default_hostname(repo: str, wanted: str, author: str) -> bool:
    """把 `[defaults] hostname` 存成 `wanted` 並記一筆 commit。與現在相同時什麼都不做、回 False。"""
    original, current = load_list(repo)
    before = current.defaults.hostname
    if before == wanted:
        return False
    updated = current.model_copy(
        update={"defaults": current.defaults.model_copy(update={"hostname": wanted})}
    )
    text = dump(updated, original)
    subject = f"新納管預設主機名稱：{before or '（未設定）'} → {wanted}"

    write_config_list(repo, text)
    try:
        stage(repo, CONFIG_LIST_NAME)
        commit(repo, subject, author)
    except BaseException as failure:
        path = os.path.join(repo, CONFIG_LIST_NAME)
        try:
            replace_atomically(path, original.encode("utf-8"))
            unstage(repo, CONFIG_LIST_NAME)
        except (OSError, WriterError, CalledProcessError) as cleanup:
            raise DefaultHostnameLeftBehind(
                f"「{subject}」沒有記成 commit，還原 {path} 也失敗了（{cleanup}）；"
                f"新的值可能已生效卻沒有紀錄。下一步：手動檢視並還原 {path}"
            ) from failure
        raise
    return True
