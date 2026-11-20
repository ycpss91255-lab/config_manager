// 頁面的全域名稱（#359）。
//
// 拆成模組之前，這些是行內腳本的頂層宣告，本來就在全域；T11 的規格（test_web.py）透過它們觀察與操作
// 頁面的狀態，例如讀 `sessionToken`、呼叫 `idleTick(false)`。模組的頂層不在全域，所以這裡把規格用到的
// 那一組明確掛回 window，名稱與意思都不變。會被改寫的狀態用 getter／setter 掛，讀到的永遠是模組裡
// 現在的值，寫入也寫回模組。規格沒用到的名稱不掛。

import { API_BASE, apiFetch, editFetch } from "./api.js";
import { setDrafts } from "./drafts.js";
import { load, render } from "./tree.js";
import { confirmAction } from "./dialogs.js";
import { discardDrafts, promoteAll } from "./promote.js";
import {
  EDITING_ENDED_TEXT, acquireSession, askWhyEditingEnded, rememberToken, renewSession, renewTimer,
  sessionToken, setEditing, setReadonly, setRenewTimer, setSessionToken,
} from "./session.js";
import {
  idleTick, idleTimer, lastActivityAt, setIdleTimer, setLastActivityAt, stopIdleWatch,
} from "./idle.js";
import { loadMode } from "./startup.js";

export function exposePageGlobals() {
  Object.assign(window, {
    API_BASE,
    EDITING_ENDED_TEXT,
    acquireSession,
    apiFetch,
    askWhyEditingEnded,
    confirmAction,
    discardDrafts,
    editFetch,
    idleTick,
    load,
    loadMode,
    promoteAll,
    rememberToken,
    render,
    renewSession,
    setDrafts,
    setEditing,
    setReadonly,
    stopIdleWatch,
  });
  Object.defineProperty(window, "sessionToken", {
    get: () => sessionToken,
    set: (value) => { setSessionToken(value); },
    configurable: true,
    enumerable: true,
  });
  Object.defineProperty(window, "renewTimer", {
    get: () => renewTimer,
    set: (value) => { setRenewTimer(value); },
    configurable: true,
    enumerable: true,
  });
  Object.defineProperty(window, "idleTimer", {
    get: () => idleTimer,
    set: (value) => { setIdleTimer(value); },
    configurable: true,
    enumerable: true,
  });
  Object.defineProperty(window, "lastActivityAt", {
    get: () => lastActivityAt,
    set: (value) => { setLastActivityAt(value); },
    configurable: true,
    enumerable: true,
  });
}
