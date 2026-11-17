"""T27 — 主機名稱候選的寫入。測試介面：`python -m config_manager.io.host_candidate record`（#385）。

被觀察的是 post-run hook 在容器裡呼叫的那一支程式本身：在沙箱目錄實際執行它（不經 docker），看它
留下的檔案、結束碼與訊息。大部分規格以 `main(argv)` 在測試程序內執行——與 `python -m` 是同一個
進入點；要對程序本身動手的（限制可寫入的檔案大小、在它讀標準輸入之前停住它）以子程序執行。
失敗注入用作業系統層的真實失敗，不替換程式碼。

服務採不採用這筆候選（識別碼比對、殘留的暫存檔不算候選）在 T9 觀察，不在這裡。
"""

import io
import json
import os
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest

from config_manager.io.host_candidate import main

_THIS_START = "a" * 32
_OTHER_START = "b" * 32
_ONLY_OWNER_RW = 0o600
_RECORDED = 0
_UNAVAILABLE = 2
_SRC = str(Path(__file__).resolve().parents[3] / "src")


def _runtime(tmp_path: Path, start_id: str | None = _THIS_START) -> Path:
    """一個沙箱執行期目錄；`start_id` 是 None 時，服務還沒發布識別碼。"""
    runtime = tmp_path / "run"
    runtime.mkdir(mode=0o700)
    if start_id is not None:
        (runtime / "start-id").write_text(start_id + "\n", encoding="utf-8")
    return runtime


def _candidate_path(runtime: Path) -> Path:
    return runtime / "host-candidate.json"


def _write_candidate(runtime: Path, record: dict[str, str]) -> bytes:
    content = json.dumps(record).encode("utf-8")
    _candidate_path(runtime).write_bytes(content)
    return content


def _candidate(runtime: Path) -> dict[str, str]:
    loaded: dict[str, str] = json.loads(_candidate_path(runtime).read_text(encoding="utf-8"))
    return loaded


def _record(runtime: Path, *args: str, stdin: str = "amr01\n") -> tuple[int, str]:
    """在測試程序內執行寫檔程式；回結束碼與它印出的全部訊息。"""
    out, err = io.StringIO(), io.StringIO()
    code = main(
        ["record", "--runtime-dir", str(runtime), "--wait", "0.3", *args],
        stdin=io.StringIO(stdin),
        stdout=out,
        stderr=err,
    )
    return code, out.getvalue() + err.getvalue()


def _program(runtime: Path, *args: str) -> list[str]:
    return [
        sys.executable, "-m", "config_manager.io.host_candidate",
        "record", "--runtime-dir", str(runtime), *args,
    ]


def _environment() -> dict[str, str]:
    return {**os.environ, "PYTHONPATH": _SRC}


def test_with_no_candidate_the_writer_records_this_starts_id_and_the_name(tmp_path):
    runtime = _runtime(tmp_path)

    code, message = _record(runtime)

    assert (code, _candidate(runtime), "amr01" in message) == (
        _RECORDED,
        {"start_id": _THIS_START, "hostname": "amr01"},
        True,
    )


def test_the_recorded_candidate_is_readable_and_writable_only_by_its_owner(tmp_path):
    runtime = _runtime(tmp_path)

    _record(runtime)

    assert stat.S_IMODE(_candidate_path(runtime).stat().st_mode) == _ONLY_OWNER_RW


def test_recording_leaves_no_temporary_file_behind(tmp_path):
    runtime = _runtime(tmp_path)

    _record(runtime)

    assert sorted(os.listdir(runtime)) == ["host-candidate.json", "start-id"]


def test_a_candidate_from_another_start_is_replaced_with_this_starts(tmp_path):
    runtime = _runtime(tmp_path)
    _write_candidate(runtime, {"start_id": _OTHER_START, "hostname": "old-host"})

    _record(runtime)

    assert _candidate(runtime) == {"start_id": _THIS_START, "hostname": "amr01"}


def test_a_valid_candidate_from_this_start_is_kept_byte_for_byte(tmp_path):
    # 維護者 11/17：同一次服務啟動已有有效候選時，重跑啟動工具不重新取得。
    runtime = _runtime(tmp_path)
    before = _write_candidate(runtime, {"start_id": _THIS_START, "hostname": "amr01"})

    code, message = _record(runtime, stdin="amr99\n")

    assert (code, _candidate_path(runtime).read_bytes(), "本次服務啟動已有候選" in message) == (
        _RECORDED,
        before,
        True,
    )


def test_an_unavailable_record_from_this_start_is_replaced(tmp_path):
    # 「本次無法取得」不是候選：沒有候選才嘗試取得，所以重跑時再取一次。
    runtime = _runtime(tmp_path)
    _write_candidate(runtime, {"start_id": _THIS_START, "unavailable": "hostname 失敗"})

    _record(runtime)

    assert _candidate(runtime) == {"start_id": _THIS_START, "hostname": "amr01"}


def test_a_malformed_candidate_from_this_start_is_replaced(tmp_path):
    runtime = _runtime(tmp_path)
    _candidate_path(runtime).write_bytes(b"{not json")

    _record(runtime)

    assert _candidate(runtime) == {"start_id": _THIS_START, "hostname": "amr01"}


def test_an_unavailable_reason_is_recorded_for_this_start_and_exits_2(tmp_path):
    runtime = _runtime(tmp_path)

    code, _ = _record(runtime, "--unavailable", "hostname: command not found", stdin="")

    assert (code, _candidate(runtime)) == (
        _UNAVAILABLE,
        {"start_id": _THIS_START, "unavailable": "hostname: command not found"},
    )


@pytest.mark.parametrize("read", ["amr/01\n", "..\n", "amr 01\n", "\n", ""])
def test_an_unsafe_or_empty_name_is_recorded_as_unavailable(tmp_path, read):
    # 不安全的名稱會流進 files/<hostname>/ 的路徑；它不是候選，記成「本次無法取得」並說明原因，
    # 讓畫面顯示的是服務實際知道的原因（維護者 11/17）。
    runtime = _runtime(tmp_path)

    code, _ = _record(runtime, stdin=read)

    recorded = _candidate(runtime)
    assert (
        code,
        recorded["start_id"],
        "hostname" in recorded,
        bool(recorded.get("unavailable")),
    ) == (_UNAVAILABLE, _THIS_START, False, True)


def test_a_write_failure_keeps_the_existing_candidate_and_leaves_no_temporary_file(tmp_path):
    # 真實的寫入失敗：子程序可寫入的檔案大小限制為 0，write(2) 回 EFBIG。
    runtime = _runtime(tmp_path)
    before = _write_candidate(runtime, {"start_id": _OTHER_START, "hostname": "old-host"})

    result = subprocess.run(
        ["bash", "-c", 'ulimit -f 0 && exec "$@"', "bash", *_program(runtime, "--wait", "1")],
        input="amr01\n",
        capture_output=True,
        text=True,
        env=_environment(),
        timeout=30,
        check=False,
    )

    assert (
        result.returncode not in (_RECORDED, _UNAVAILABLE),
        _candidate_path(runtime).read_bytes(),
        sorted(os.listdir(runtime)),
        "下一步" in result.stderr,
    ) == (True, before, ["host-candidate.json", "start-id"], True)


def test_a_rename_failure_leaves_the_occupied_place_and_no_temporary_file(tmp_path):
    # 真實的改名失敗：候選檔的位置被一個目錄占住，rename(2) 回 EISDIR。
    runtime = _runtime(tmp_path)
    _candidate_path(runtime).mkdir()

    code, message = _record(runtime)

    assert (
        code not in (_RECORDED, _UNAVAILABLE),
        _candidate_path(runtime).is_dir(),
        sorted(os.listdir(runtime)),
        "下一步" in message,
    ) == (True, True, ["host-candidate.json", "start-id"], True)


def test_without_a_start_id_the_writer_gives_up_at_the_limit_without_recording(tmp_path):
    runtime = _runtime(tmp_path, start_id=None)

    code, message = _record(runtime)

    assert (
        code not in (_RECORDED, _UNAVAILABLE),
        _candidate_path(runtime).exists(),
        "啟動識別碼" in message,
    ) == (True, False, True)


def test_the_writer_waits_for_the_start_id_to_appear(tmp_path):
    # 服務剛起來時可能還沒寫出識別碼：寫檔程式等它出現才寫。
    runtime = _runtime(tmp_path, start_id=None)
    writer = subprocess.Popen(
        _program(runtime, "--wait", "20"),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=_environment(),
    )
    time.sleep(0.5)
    (runtime / "start-id").write_text(_THIS_START + "\n", encoding="utf-8")

    writer.communicate("amr01\n", timeout=30)

    assert _candidate(runtime) == {"start_id": _THIS_START, "hostname": "amr01"}


def test_a_start_id_replaced_after_binding_does_not_relabel_the_record(tmp_path):
    # 競態（維護者 11/17）：寫入工作綁定開始時取得的識別碼，中途不換成新的。寫檔程式一開始就讀取
    # 並綁定識別碼、印出一行，之後才讀標準輸入——在那之間把識別碼檔換成新的一個。
    runtime = _runtime(tmp_path)
    writer = subprocess.Popen(
        _program(runtime, "--wait", "20"),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=_environment(),
    )
    for line in writer.stderr or ():
        if "已綁定" in line:
            break
    replacement = runtime / "start-id.new"
    replacement.write_text(_OTHER_START + "\n", encoding="utf-8")
    replacement.replace(runtime / "start-id")

    writer.communicate("amr01\n", timeout=30)

    assert _candidate(runtime)["start_id"] == _THIS_START
