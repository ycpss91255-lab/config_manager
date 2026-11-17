"""io/host_candidate — 主機名稱候選：服務的啟動識別碼與候選紀錄（#385）。

外部互動層：這裡真的碰檔案系統。

**誰寫、誰讀。** 服務每次啟動產生一個隨機的啟動識別碼，留在記憶體裡，並發布一份到執行期目錄
（`publish_start_id`）。啟動工具的 post-run hook 在**主機**上讀 `hostname`，以
`docker compose exec` 執行這支模組的 `record`，把「啟動識別碼＋名稱」（或「本次無法取得」與原因）
寫進候選檔。服務只讀候選檔（`read_candidate`），以自己記憶體裡的識別碼判定它屬不屬於這次啟動——
不看檔案時間：複製、還原會改變時間，主機與容器的時鐘也可能不同（維護者 11/17）。

**執行期目錄**是容器可寫層裡的 `/run/config_manager/`：不在設定庫、不在任何資料卷，容器每次啟動時
由 entrypoint 清空。候選只對一次啟動有效，保存下來沒有用處；現有的 `git bundle` 備份、資料卷打包、
設定庫複製都不包含它。

**同一次啟動已有有效候選時不更新**（維護者 11/17）：重跑啟動工具不必重啟服務，畫面稱它為「本次
啟動取得的候選」，不保證是即時的主機名稱。服務真正重啟時識別碼改變，舊候選自然失效。

**寫入工作綁定開始時取得的識別碼**（維護者 11/17）：`record` 一開始就讀取並綁定識別碼，之後的判斷
與寫出都用這一個，不重讀——寫入期間服務重啟，寫出的紀錄仍屬於舊的那一次，不會被套上新識別碼。
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
import time
from dataclasses import dataclass
from typing import TextIO

from config_manager.core.attributes import is_safe_hostname
from config_manager.io.atomic import replace_atomically
from config_manager.io.errors import TargetNotWritable, TemporaryLeftBehind

DEFAULT_RUNTIME_DIR = "/run/config_manager"
START_ID_FILE = "start-id"
CANDIDATE_FILE = "host-candidate.json"
DEFAULT_WAIT_SECONDS = 30.0
_POLL_SECONDS = 0.1
_ONLY_OWNER_RW = 0o600

# `record` 的結束碼：hook 依它決定怎麼說（T19）。
RECORDED = 0  # 記下了這次的名稱，或這次啟動本來就有候選
UNAVAILABLE = 2  # 記下了「本次無法取得」與原因
FAILED = 1  # 什麼都沒記下

NOT_RECEIVED = (
    "服務沒有收到本次啟動的主機名稱候選；若是經啟動工具（just docker run）啟動，"
    "詳細原因在啟動工具的輸出。下一步：重跑啟動工具（容器沿用時不會重啟服務），或由開發者直接輸入"
)


@dataclass(frozen=True)
class Candidate:
    """本次啟動取得的候選。不保證是即時的主機名稱。"""

    hostname: str


@dataclass(frozen=True)
class Unconfirmed:
    """沒有有效候選：「目前主機名稱尚未確認」，`reason` 只寫服務實際知道的那一種。"""

    reason: str


def new_start_id() -> str:
    """一個隨機的啟動識別碼。不由時間產生——要比對的是「哪一次啟動」，不是「何時」。"""
    return secrets.token_hex(16)


def publish_start_id(runtime_dir: str, start_id: str) -> None:
    """把這次啟動的識別碼寫到執行期目錄，讓寫檔程式讀得到。失敗時丟 OSError 家族，由呼叫端決定。"""
    replace_atomically(
        os.path.join(runtime_dir, START_ID_FILE),
        (start_id + "\n").encode("utf-8"),
        finalize=_owner_only,
    )


def read_candidate(runtime_dir: str, start_id: str) -> Candidate | Unconfirmed:
    """執行期目錄裡屬於 `start_id` 這次啟動的候選；沒有就說明為什麼（只說服務看得到的事）。"""
    path = os.path.join(runtime_dir, CANDIDATE_FILE)
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except FileNotFoundError:
        return Unconfirmed(NOT_RECEIVED)
    except OSError as error:
        return Unconfirmed(
            f"候選檔 {path} 讀不出來（{error.strerror}）。"
            "下一步：重跑啟動工具，或由開發者直接輸入"
        )
    return _judge(_parse(raw), start_id)


def _judge(content: dict[str, str] | str, start_id: str) -> Candidate | Unconfirmed:
    """候選檔的內容屬不屬於 `start_id` 這次啟動、是不是一個可用的名稱。"""
    if isinstance(content, str):
        return Unconfirmed(f"候選內容不合法：{content}。下一步：重跑啟動工具，或由開發者直接輸入")
    if content.get("start_id") != start_id:
        return Unconfirmed(NOT_RECEIVED)
    if "unavailable" in content:
        return Unconfirmed(
            f"啟動工具這次在主機上沒有取得名稱：{content['unavailable']}。"
            "下一步：處理那個原因後重跑啟動工具，或由開發者直接輸入"
        )
    hostname = content.get("hostname", "")
    if not is_safe_hostname(hostname):
        return Unconfirmed(
            f"候選內容不合法：名稱「{hostname}」不是安全的 hostname。"
            "下一步：重跑啟動工具，或由開發者直接輸入"
        )
    return Candidate(hostname)


def record(
    runtime_dir: str,
    *,
    unavailable: str | None,
    wait_seconds: float,
    streams: tuple[TextIO, TextIO, TextIO],
) -> int:
    """寫檔程式本體：綁定這次啟動的識別碼，記下名稱或「本次無法取得」。回結束碼。

    `streams` 是 (標準輸入, 標準輸出, 標準錯誤)。標準輸入只在**綁定識別碼之後**才讀——
    綁定的是開始時那一個，之後換掉識別碼檔也不影響這一筆（T27 的競態規格靠這個順序）。
    """
    stdin, stdout, stderr = streams
    candidate_path = os.path.join(runtime_dir, CANDIDATE_FILE)
    start_id = _bind_start_id(runtime_dir, wait_seconds)
    if start_id is None:
        stderr.write(
            f"等不到服務的啟動識別碼（{os.path.join(runtime_dir, START_ID_FILE)}，"
            f"等了 {wait_seconds:g} 秒）：服務可能還沒起來或沒有起來，主機名稱候選沒有記下。"
            "下一步：確認服務在執行（docker compose ps），再重跑啟動工具\n"
        )
        return FAILED
    stderr.write(f"已綁定本次服務啟動識別碼：{start_id}\n")
    stderr.flush()

    # 帶 --unavailable 時不讀標準輸入：hook 那時沒有名稱可給，讀了會卡在繼承來的終端機上。
    entry = _entry(start_id, unavailable, "" if unavailable is not None else stdin.read())
    existing = read_candidate(runtime_dir, start_id)
    if isinstance(existing, Candidate):
        stdout.write(f"本次服務啟動已有候選：{existing.hostname}，不重新取得\n")
        return RECORDED
    try:
        replace_atomically(
            candidate_path,
            json.dumps(entry, ensure_ascii=False).encode("utf-8"),
            finalize=_owner_only,
        )
    except (OSError, TargetNotWritable, TemporaryLeftBehind) as error:
        stderr.write(
            f"主機名稱候選沒有寫進 {candidate_path}：{error}。既有的候選檔沒有動。"
            "下一步：確認執行期目錄的空間與權限，再重跑啟動工具\n"
        )
        return FAILED
    if "hostname" in entry:
        stdout.write(f"已記錄本次啟動的主機名稱候選：{entry['hostname']}\n")
        return RECORDED
    stdout.write(f"已記錄：本次沒有取得主機名稱（{entry['unavailable']}）\n")
    return UNAVAILABLE


def main(
    argv: list[str],
    *,
    stdin: TextIO | None = None,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
) -> int:
    """`python -m config_manager.io.host_candidate record …` 的進入點（T27）。"""
    parser = argparse.ArgumentParser(prog="python -m config_manager.io.host_candidate")
    commands = parser.add_subparsers(dest="command", required=True)
    recorder = commands.add_parser(
        "record", help="記下本次服務啟動的主機名稱候選（名稱由標準輸入給）"
    )
    recorder.add_argument("--runtime-dir", default=DEFAULT_RUNTIME_DIR)
    recorder.add_argument("--wait", type=float, default=DEFAULT_WAIT_SECONDS)
    recorder.add_argument("--unavailable", default=None, help="這次在主機上取不到名稱的原因")
    arguments = parser.parse_args(argv)
    return record(
        arguments.runtime_dir,
        unavailable=arguments.unavailable,
        wait_seconds=arguments.wait,
        streams=(stdin or sys.stdin, stdout or sys.stdout, stderr or sys.stderr),
    )


def _entry(start_id: str, unavailable: str | None, read: str) -> dict[str, str]:
    """這一次要記下的內容：名稱安全就記名稱，否則記「本次無法取得」與原因。"""
    if unavailable is not None:
        return {"start_id": start_id, "unavailable": unavailable}
    hostname = read.strip()
    if not hostname:
        return {"start_id": start_id, "unavailable": "在主機上讀到的主機名稱是空的"}
    if not is_safe_hostname(hostname):
        return {
            "start_id": start_id,
            "unavailable": (
                f"在主機上讀到的名稱「{hostname}」不是安全的 hostname"
                "（只能用英數字、.、_、-，且不能是 . 或 ..）"
            ),
        }
    return {"start_id": start_id, "hostname": hostname}


def _bind_start_id(runtime_dir: str, wait_seconds: float) -> str | None:
    """讀這次啟動的識別碼，還沒出現就等，到上限仍沒有回 None。只讀這一次（綁定）。"""
    path = os.path.join(runtime_dir, START_ID_FILE)
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            with open(path, encoding="utf-8") as handle:
                start_id = handle.read().strip()
        except FileNotFoundError:
            start_id = ""
        if start_id:
            return start_id
        if time.monotonic() >= deadline:
            return None
        time.sleep(_POLL_SECONDS)


def _parse(raw: bytes) -> dict[str, str] | str:
    """候選檔的內容；不合法時回說明哪裡不合法的字串。"""
    try:
        loaded = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        return f"不是可解析的 JSON（{error}）"
    if not isinstance(loaded, dict) or not all(
        isinstance(key, str) and isinstance(value, str) for key, value in loaded.items()
    ):
        return "應是一個只含字串的物件"
    return loaded


def _owner_only(path: str) -> None:
    os.chmod(path, _ONLY_OWNER_RW)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
