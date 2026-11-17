"""io/source — T22 匯入時刻對外界的讀取.

外部互動層：這裡真的碰檔案系統。核心層不碰（ADR-00000011）。

`read_source` 是**系統唯一一次向外界取值的時刻**，取到之後就凍結進紀錄、永不再讀
（不變式 8、ADR-00000012、T22）。本機 hostname 原本也在這裡讀（`local_hostname`），#385 起
納管用的名稱改為清單檔的 `[defaults] hostname`，由開發者確認後保存，這裡不再讀它。

**判定不在這裡重寫。** 「這條路徑落在白名單內嗎」由 `core/whitelist.decide` 回答
——那是純字面比對，已經在 #11 落地並驗過。這一層只做核心做不到的那半：`realpath`
解析（I/O）。少了這樣的分工就會有兩份白名單邏輯，而兩份邏輯遲早會給出兩個答案。

**名字只解析一次，之後全部在同一個 fd 上做。** 這是這支的核心設計，理由是實測出來的：
先前的版本按路徑做了三趟（`os.stat` 判型別、`open` 讀內容、再一次 `os.stat` 取權限），
而在白名單目錄裡持續翻動「普通檔案 ↔ 指向外面的符號連結」時，**56586 次呼叫命中
481 次**，回傳了白名單外檔案的完整內容，`resolved_path` 卻仍報白名單內的路徑——出處
紀錄會說謊。改成 `os.open(O_NOFOLLOW)` 一次拿到 fd，型別、權限、內容全部來自 `fstat`
與同一個 fd，那三趟之間的窗口就不存在了，content 與 permissions 也保證來自同一個 inode。

**殘餘的窗口仍然存在**：`O_NOFOLLOW` 只保護**最後一段**，路徑中間的目錄仍可能在解析
與開檔之間被換掉。要完全關掉需要 `openat2` 的 `RESOLVE_NO_SYMLINKS`，那不在本介面的
承諾範圍內（T22 已寫下這一條）。失敗方向是**拒絕**：寧可這次匯入不成立，也不讀一份
來歷不明的內容。

**來源路徑要解析得出唯一的真正位置**（F18，安全）：Python 3.11 的 realpath（非 strict）遇到連結
迴圈就不再解析後面那幾段、再依字面收掉 `..`，於是 `<白名單>/loop/../link_out/x`（`link_out` 指向
白名單外）會被「解析」成白名單內的字串，開檔時核心卻順著 `link_out` 走出去——讀到外面的內容，
出處紀錄還寫成白名單內的假路徑。來源路徑改用 `io/paths.stable_realpath`：解析結果不是不動點就以
`SourcePathUnstable` 拒絕，不拿它去判定、也不開檔（瀏覽那一側同樣的修正在 #322）。
"""

from __future__ import annotations

import errno
import grp
import os
import pwd
import stat
from collections.abc import Iterable
from dataclasses import dataclass

from config_manager.core.models import Permissions
from config_manager.core.whitelist import decide
from config_manager.io.errors import (
    ContentUnreadable,
    SourceAbsent,
    SourceNotRegularFile,
    SourceOutsideRoots,
    SourcePathUnstable,
    SourceTooLarge,
    SourceUnreachable,
)
from config_manager.io.paths import blocking_parent, read_capped, stable_realpath


_CHUNK = 65536

# 來源檔大小上限（#200）。config 檔案本就小；10 MiB 已遠比任何真實 config 寬鬆，但擋得住
# 用超大檔把記憶體吃光的 DoS。呼叫端可用 `max_bytes` 覆寫（例如測試給一個小值）；持久化的
# 環境變數接線（CM_MAX_SOURCE_BYTES）之後要的話再加。
MAX_SOURCE_BYTES = 10 * 1024 * 1024


@dataclass(frozen=True)
class Source:
    """匯入時刻從外界讀到的一切。

    `content` 是**位元組**而不是 `str`：納管要保證來源檔與原始檔案逐位元組相同，
    而任何一次解碼再編碼都可能在邊角上改寫位元組。`resolved_path` 是實際被讀的那
    一個路徑——呼叫端請求的可能是一條符號連結。
    """

    content: bytes
    permissions: Permissions
    resolved_path: str


def read_source(
    path: str, allowed_roots: Iterable[str], max_bytes: int = MAX_SOURCE_BYTES
) -> Source:
    """讀一份要被納管的來源檔。

    `max_bytes` 是大小上限（#200）：`fstat` 的 `st_size` 超過就在**讀取之前**丟
    `SourceTooLarge`，一個位元組都不讀進來——白名單內放一個超大檔不該能把記憶體吃光。

    失敗一律是具名例外，呼叫端據以分辨：

    - `SourceOutsideRoots` —— 解析後落在白名單之外，**一個位元組都沒讀**
    - `SourceNotRegularFile` —— 目錄、裝置、socket、斷掉的連結
    - `SourcePathUnstable` —— 解析或開檔期間路徑被改動（競速），或路上有連結迴圈、解析不出唯一的
      真正位置（F18），這次匯入不成立
    - `SourceAbsent` —— 來源不存在（與「讀不到」分開）
    - `SourceUnreachable` —— 上層某層目錄沒有 traverse（`+x`）權限，去不到
    - `SourceTooLarge` —— 比 `max_bytes` 大，不整個讀進記憶體（#200）
    - `ContentUnreadable` —— 是一般檔案、也到得了，但內容讀不出來（權限）

    「不存在／讀不到／上層目錄無 traverse」這三種的細分已於 #182／#184 落地（見
    `_classify_open_failure`）。
    """
    # 先固定下來：allowed_roots 可能是一次性的可迭代物，而判定與訊息都要用到它。
    roots = tuple(allowed_roots)
    resolved = _resolve_source(path)

    # 白名單的「根」自己也要解析。`io/writer._within_roots` 對它的 roots 就是這樣做的
    # ——同一個問題的兩道檢查不該給出不同答案。core 不能做 I/O，所以解析在這一層，
    # 判定仍然由 core（純字面比對，#11 已驗過）。
    if not decide(tuple(_resolve(root) for root in roots), resolved).allowed:
        covered = "、".join(roots) if roots else "（目前是空的）"
        raise SourceOutsideRoots(
            f"來源解析後落在白名單之外：{path} → {resolved}；目前涵蓋：{covered}。"
            f"下一步：確認這條路徑或其中一段不是指向白名單外的符號連結，"
            f"或把該位置納入白名單"
        )

    descriptor = _open_source(path, resolved)
    try:
        info = os.fstat(descriptor)
        kind = _not_a_regular_file(info.st_mode)
        if kind is not None:
            raise SourceNotRegularFile(
                f"來源不是一般檔案（{kind}）：{path} → {resolved}。"
                f"下一步：納管的對象是一份 config 檔案本身，改指向那個檔案"
            )
        # 讀之前先擋大小：st_size 來自剛才的 fstat，超過就一個位元組都不讀（#200）。
        if info.st_size > max_bytes:
            raise SourceTooLarge(
                f"來源檔太大（{info.st_size} 位元組，上限 {max_bytes}）：{path} → {resolved}。"
                f"下一步：確認指到的是一份 config 檔案而不是資料檔／日誌；config 本就不該這麼大"
            )
        content = _read_all(descriptor, path, resolved, max_bytes)
    finally:
        os.close(descriptor)

    return Source(
        content=content,
        permissions=_permissions_of(info),
        resolved_path=resolved,
    )


def service_identity() -> tuple[str, frozenset[str], bool]:
    """服務的**有效**執行身分：(使用者名稱, 可設定的群組名稱集合, 是不是 root)。

    納管判定 `requires_privilege` 時拿它跟來源檔的 owner／group 比（#175）：非 root 的
    服務 apply 時無法把檔案 chown 給別的擁有者（POSIX：改 owner 要 root），也只能把
    group 設成自己設得上的群組。

    用**有效** uid／gid 而非真實的：新建檔取用建立者的 euid，chown／chgrp 的權限由有效
    （fs）身分決定，不是真實 uid（#175 的資安審查）。群組能設的是 egid ＋ 附屬群組——
    真實 gid 若既非 egid 也不在附屬群組裡其實設不上，所以不放進來（否則會少標一筆該
    提權的，那是危險的方向）。名稱查不到時回數字形式（同 `owner_name`／`group_name`，
    容器裡常沒有 passwd 項目）。
    """
    euid = os.geteuid()
    gids = {os.getegid(), *os.getgroups()}
    return owner_name(euid), frozenset(group_name(gid) for gid in gids), euid == 0


def _resolve_source(path: str) -> str:
    """來源路徑的 realpath，而且要解析得出唯一的真正位置（F18）——白名單判定與開檔看的必須是同一個
    位置。根的解析照舊用 `_resolve`：根由白名單設定檔決定，不是請求帶進來的。"""
    try:
        stable = stable_realpath(path)
    except OSError as error:
        raise SourcePathUnstable(
            f"解析路徑時它正在被改動：{path}（{error.strerror}）。"
            f"下一步：確認沒有其他程序正在改寫這條路徑上的符號連結，然後重試"
        ) from error
    if stable is None:
        # 不帶解析結果：那個字串不可信，也不該透露路上那幾段連結指向哪裡。
        raise SourcePathUnstable(
            f"來源路徑解析不出唯一的真正位置（路上有連結迴圈）：{path}。"
            f"下一步：改用不經過連結的完整路徑"
        )
    return stable


def _resolve(path: str) -> str:
    try:
        return os.path.realpath(path)
    except OSError as error:
        raise SourcePathUnstable(
            f"解析路徑時它正在被改動：{path}（{error.strerror}）。"
            f"下一步：確認沒有其他程序正在改寫這條路徑上的符號連結，然後重試"
        ) from error


def _open_source(path: str, resolved: str) -> int:
    """以 `O_NOFOLLOW` 開檔；失敗時把原因分類成具名例外。

    `O_NONBLOCK` 讓具名管道不會把整個匯入卡住——開得成之後 `fstat` 會認出它不是
    一般檔案並拒絕。
    """
    try:
        return os.open(resolved, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise _classify_open_failure(path, resolved, error) from error


def _classify_open_failure(path: str, resolved: str, error: OSError) -> Exception:
    """把 `os.open` 的失敗分成四種——它們的成因與處置各不相同（#182）。

    把「不存在」「讀不到」「上層目錄擋住去路」混成同一種，等於把訊號消掉：使用者
    收到「不是一般檔案」時會去改錯的東西（不變式 2，`io/digest` 的 docstring 寫過
    同一件事）。
    """
    if error.errno == errno.ELOOP:
        # 解析之後最後一段又變成了符號連結——那就是競速本身。
        return SourcePathUnstable(
            f"開檔時來源變成了符號連結：{path} → {resolved}。"
            f"下一步：確認沒有其他程序正在改寫這條路徑，然後重試"
        )

    if error.errno == errno.ENOENT:
        if os.path.islink(path):
            # realpath 把連結收斂成了不存在的目標——那是一條斷掉的符號連結。
            return SourceNotRegularFile(
                f"來源是一條斷掉的符號連結（指向不存在的目標）：{path} → {resolved}。"
                f"下一步：納管的對象是一份 config 檔案本身，改指向那個檔案"
            )
        return SourceAbsent(
            f"來源不存在：{path} → {resolved}。"
            f"下一步：確認路徑拼對了，且那份檔案真的在那個位置"
        )

    if error.errno in (errno.EACCES, errno.EPERM):
        blocker = blocking_parent(resolved)
        if blocker is not None:
            return SourceUnreachable(
                f"上層目錄擋住去路（「{blocker}」沒有 traverse 權限）：{path}。"
                f"下一步：給那個目錄加上執行（+x）權限，或改由讀得到它的身分執行"
            )
        return ContentUnreadable(
            f"內容讀不出來：{path} → {resolved}（{error.strerror}）。"
            f"下一步：確認執行身分對它有讀取權限"
        )

    return SourceNotRegularFile(
        f"來源開不起來（{error.strerror}）：{path} → {resolved}。"
        f"下一步：確認它是一份一般檔案（不是裝置或 socket）"
    )


def _read_all(descriptor: int, path: str, resolved: str, max_bytes: int) -> bytes:
    """把整個 fd 讀完，但不超過 `max_bytes`。

    只讀這一次：解析要文字、複製要位元組、算雜湊也要位元組，對同一個活著的檔案
    分三趟讀，三趟之間內容可以變，那樣「兩邊 sha256 相同」證明的就不是同一份東西
    （T22）。這裡讀進來的這一份就是後續全部步驟共用的那一份。

    `max_bytes` 的邊界在 `st_size` 檢查之外再守一道（#200）：檔案若在 fstat 與讀取之間被
    撐大，讀到超過上限就丟 `SourceTooLarge`，而不是無上限地一路讀進記憶體。
    """
    def _too_large(total: int) -> Exception:
        return SourceTooLarge(
            f"來源檔在讀取途中超過上限（已讀 {total} 位元組，上限 {max_bytes}）："
            f"{path} → {resolved}。下一步：確認沒有其他程序正在把它撐大，且指到的是"
            f"一份 config 檔案"
        )

    try:
        return b"".join(read_capped(descriptor, _CHUNK, max_bytes, _too_large))
    except OSError as error:
        raise ContentUnreadable(
            f"內容讀不出來：{path} → {resolved}（{error.strerror}）。"
            f"下一步：確認執行身分對它有讀取權限"
        ) from error


# 型別名稱以中文回報，因為它會直接出現在使用者看得到的訊息裡。一個 inode 只會是其中
# 一種，所以順序無關緊要。資料，不是邏輯：多認一種就加一列。
_KINDS: tuple[tuple[str, str], ...] = (
    ("S_ISDIR", "目錄"),
    ("S_ISFIFO", "具名管道"),
    ("S_ISSOCK", "socket"),
    ("S_ISBLK", "區塊裝置"),
    ("S_ISCHR", "字元裝置"),
)


def _not_a_regular_file(mode: int) -> str | None:
    """不是一般檔案時回傳它是什麼；是一般檔案則回 None。

    吃的是 `fstat` 的 mode 而不是路徑——型別必須與內容來自同一個 inode，否則判定的
    與讀到的可以是兩個不同的東西。
    """
    for predicate, name in _KINDS:
        if getattr(stat, predicate)(mode):
            return name
    if not stat.S_ISREG(mode):
        return "非一般檔案"
    return None


def _permissions_of(info: os.stat_result) -> Permissions:
    """權限來自已開啟的那個 fd 的 `fstat`，不是對路徑的第二次查詢。

    按路徑再查一次可能查到另一個 inode——那樣回報的權限描述的就不是被讀進來的
    那一份內容。
    """
    return Permissions(
        owner=owner_name(info.st_uid),
        group=group_name(info.st_gid),
        mode=f"{stat.S_IMODE(info.st_mode):04o}",
    )


def owner_name(uid: int) -> str:
    # 容器裡的使用者常常沒有 passwd 項目（`io/writer` 記過實測 uid 501 查不到名字）。
    # 查不到就回數字形式——那不是取巧，是部署環境的現實，而且它仍然是正確的擁有者。
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def group_name(gid: int) -> str:
    try:
        return grp.getgrgid(gid).gr_name
    except KeyError:
        return str(gid)
