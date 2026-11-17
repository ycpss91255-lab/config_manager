"""api/host_name — 新納管預設主機名稱的端點（#385）。

`GET /api/host-name` 查看、`PUT /api/host-name` 確認或修改，body `{hostname}`。是本 repo 對設計
§3.5.3 端點表的追加（比照 `GET /api/mode`）。

**查看不需要編輯權**，兩種角色都可以；**確認與修改限開發者、需要編輯權**，後端檢查（不只靠畫面），
經 `editing.write`（F23）與 `require_permission`（維護者 11/17）。開發者角色是自我宣告，不是帳號
認證——那是 T17 寫明的界線，這裡不假裝有更多。

查看回的是：保存的納管預設名稱（`saved`，可能沒有）、本次啟動取得的候選（`candidate`，不保證是
即時的主機名稱）或「目前主機名稱尚未確認」的原因（`unconfirmed`，只寫服務實際知道的那一種）、
每個名稱來源（`sources`：本次啟動的候選、既有條目全部相同時的那個名稱），以及只有一個名稱時的
預填值（`prefill`）。**來源不一致時不默默選一個**：兩個都列、不預填，由開發者確認（維護者 11/17）。
候選與預填都只是預填，**不自動保存**，也不修改既有 config 的 hostname。

獨立成一個模組的理由同 `api/attributes`：`routes.py` 已貼近單檔行數上限（C0302）。
"""

from __future__ import annotations

from subprocess import CalledProcessError

from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel

from config_manager.api.lock import Editing, require_permission
from config_manager.api.session import Identity
from config_manager.core.errors import UnsafeDefaultHostname
from config_manager.core.roles import MAINTAIN_HOST_NAME
from config_manager.io.default_hostname import save_default_hostname
from config_manager.io.errors import ChangeError, DefaultHostnameLeftBehind, WriterError
from config_manager.io.host_candidate import Candidate, read_candidate
from config_manager.io.repo import load_list


class HostNameInput(BaseModel):
    """要保存的新納管預設主機名稱。"""

    hostname: str


def register_host_name(app: FastAPI, repo: str, editing: Editing, start: tuple[str, str]) -> None:
    """把查看與確認／修改的端點掛上 app。`start` 是 (執行期目錄, 本次啟動識別碼)。"""
    runtime_dir, start_id = start

    @app.get("/api/host-name")
    def view_host_name() -> dict[str, object]:
        """查看新納管預設主機名稱與本次啟動取得的候選。唯讀、不需要編輯權。"""
        return host_name_view(repo, runtime_dir, start_id)

    @app.put("/api/host-name")
    def save_host_name(payload: HostNameInput, request: Request) -> dict[str, object]:
        """確認或修改新納管預設主機名稱：寫進清單檔的 `[defaults]`，記一筆 commit。"""
        with editing.write(request, "設定新納管預設主機名稱") as identity:
            _save(repo, identity, payload.hostname)
        return host_name_view(repo, runtime_dir, start_id)


def host_name_view(repo: str, runtime_dir: str, start_id: str) -> dict[str, object]:
    """查看用的內容（見模組說明）。"""
    _, current = load_list(repo)
    found = read_candidate(runtime_dir, start_id)
    sources: list[dict[str, str]] = []
    if isinstance(found, Candidate):
        sources.append({"kind": "candidate", "hostname": found.hostname})
    held = {entry.hostname for entry in current.files}
    if len(held) == 1:
        sources.append({"kind": "entries", "hostname": next(iter(held))})
    distinct = {source["hostname"] for source in sources}
    return {
        "saved": current.defaults.hostname,
        "candidate": found.hostname if isinstance(found, Candidate) else None,
        "unconfirmed": None if isinstance(found, Candidate) else found.reason,
        "sources": sources,
        "prefill": next(iter(distinct)) if len(distinct) == 1 else None,
    }


def _save(repo: str, identity: Identity | None, hostname: str) -> None:
    """開發者門檻（沒身分 409、角色不足 403）之後保存。值不安全 422；寫入／commit 失敗 500。"""
    identity = require_permission(identity, MAINTAIN_HOST_NAME)
    try:
        save_default_hostname(repo, hostname, identity.git_author)
    except UnsafeDefaultHostname as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    except (
        DefaultHostnameLeftBehind, WriterError, ChangeError, CalledProcessError, OSError
    ) as error:
        raise HTTPException(status_code=500, detail=str(error)) from error
