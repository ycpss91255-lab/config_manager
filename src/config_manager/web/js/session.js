// 編輯階段（#33、§7.2.2、ADR-00000014）：取得、續約、失去與唯讀。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, apiFetch, failureText } from "./api.js";
import { element } from "./dom.js";
import { ownerLabel } from "./drafts.js";
import { workspaceEpoch } from "./workspace.js";
import { formatTime } from "./history.js";
import { promoteDoneEl } from "./promote.js";
import { leaveForExit } from "./exit.js";
import { ROLE_TEXT, currentIdentity, currentRole } from "./identity.js";
import { applyIdle, idleRequest, idleTimer, leaveForGone, leaveForIdle } from "./idle.js";
import { detailText } from "./whitelist.js";

// ── 編輯階段（#33、§7.2.2、ADR-00000014）──────────────────────────────────────
// 一次只有一個編輯階段。進清單時向 backend 取得；成功就拿到識別碼（只存在這個分頁的 sessionStorage，
// 重新整理不丟）並定期續期；關閉頁面時主動釋放；異常中斷靠續期逾時自動釋放。已被占用→唯讀：
// 橫幅指名持有者與開始時間，會寫入的控制項不出現（不是停用）。不提供強制接管。
export const readonlyBanner = document.querySelector("[data-testid='readonly-banner']");
export const SESSION_TOKEN_KEY = "cm.session.token";
export const RENEW_EVERY_MS = 30_000;
export let sessionToken = null;

// 別的模組要改這個狀態時走這裡：匯入的名稱是唯讀的（#359）。
export function setSessionToken(value) {
  sessionToken = value;
}

export let renewTimer = null;

// 別的模組要改這個狀態時走這裡：匯入的名稱是唯讀的（#359）。
export function setRenewTimer(value) {
  renewTimer = value;
}


export function storedToken() {
  try { return sessionStorage.getItem(SESSION_TOKEN_KEY); } catch (_error) { return null; }
}

export function rememberToken(token) {
  sessionToken = token;
  try {
    if (token) sessionStorage.setItem(SESSION_TOKEN_KEY, token);
    else sessionStorage.removeItem(SESSION_TOKEN_KEY);
  } catch (_error) {
    // 私密視窗等存不進去：識別碼還在記憶體裡，只是重新整理後要重新取得。
  }
}

export function setReadonly(holder, startedAt, reason) {
  document.body.dataset.readonly = "true";
  currentRole.textContent = "唯讀";
  const who = holder
    ? `目前由 ${holder.name}（${holder.email}）自 ${formatTime(startedAt)} 起編輯中。`
    : "";
  const standard = `${who}一次只允許一個編輯階段；等對方離開或逾時釋放後重新整理即可取得。不提供強制接管。`;
  readonlyBanner.replaceChildren(
    element("strong", { text: "唯讀模式。" }),
    element("p", { text: reason ? (who ? `${reason}${who}` : reason) : standard }),
  );
  readonlyBanner.hidden = false;
  if (renewTimer) { clearInterval(renewTimer); renewTimer = null; }
}

// 這個分頁在不知情時失去了編輯權（被釋放後別人接手、逾時被收回…，F23）：轉唯讀，唯讀橫幅原樣
// 寫出後端的原因（含下一步：重新整理）。可能是這個瀏覽器退出了、或閒置逾時被退出了：馬上問後端。
export function loseEditing(reason) {
  endEditing(reason, true);
}

// 編輯階段在這個分頁不知情時沒了（續期被拒、寫入被擋，F28）：**先**立刻轉唯讀——橫幅寫 `reason`（寫入
// 被擋是後端的原因原樣；續期被拒是中性的一句，不猜逾時、釋放或重啟）——**再**去問原因；問到才換字。
export const EDITING_ENDED_TEXT = "編輯階段已失效，這個分頁現在是唯讀。重新整理頁面以重新取得。";

export function endEditing(reason, refusedWrite = false) {
  rememberToken(null);
  setReadonly(null, null, reason);
  askWhyEditingEnded(refusedWrite, reason);
}

// 編輯權在這個分頁不知情時沒了（或收到另一個分頁的退出通知）：依序問既有端點，依答案顯示（F28）：
// 1. `idle` 說已退出（同一個瀏覽器的另一個分頁按了「退出」，F3）→ 回身分輸入頁、說是退出（`refusedWrite`
//    ＝是寫入被擋才發現的，另說剛才的改動沒有寫進去）；說閒置逾時 → 照閒置逾時說（部署模式，#48）。
// 2. `GET /api/session` 回 null（後端沒有這個瀏覽器的紀錄，例如服務重新啟動過）→ 回身分輸入頁說身分已失效
//    ——不分模式。
// 3. `GET /api/session/lock` 說別人持有 → 唯讀橫幅指名持有者與開始時間。
// 4. 都不是、或問不到 → 維持原本的字與唯讀。
// 查詢帶世代號：這段期間人重新進入了（離開主畫面會加 workspaceEpoch），晚到的答案不覆蓋新狀態。
export let whyGeneration = 0;

export async function askWhyEditingEnded(refusedWrite = false, reason = null) {
  const generation = ++whyGeneration;
  const epoch = workspaceEpoch;
  const stale = () => generation !== whyGeneration || epoch !== workspaceEpoch
    || document.body.dataset.readonly !== "true";
  const view = await idleRequest(false);
  if (stale()) return;
  if (view && view.left) { leaveForExit(null, refusedWrite); return; }
  if (view && view.timed_out) { leaveForIdle(view.timeout_seconds); return; }
  const identity = await askJson(`${API_BASE}/api/session`);
  if (stale()) return;
  if (identity === null) { leaveForGone(); return; }
  if (identity === undefined) return;  // 問不到：原因不明，維持原本的字
  const lock = await askJson(`${API_BASE}/api/session/lock`);
  if (stale()) return;
  if (lock && lock.held && lock.holder) setReadonly(lock.holder, lock.started_at, reason);
  else if (idleTimer && view) applyIdle(view);  // 部署模式：閒置倒數照後端說的（身分還在時）
  await noteDraftsAfterLosingEditing(stale);
}

// 失去編輯權之後，草稿還在不在（ADR-00000032，F7）：照後端此刻的回答寫，不保證接得回——續期逾時
// 回收階段時草稿保留，但之後可能被接手的人清掉、或服務重新啟動過。問不到就不寫這句。
export async function noteDraftsAfterLosingEditing(stale) {
  const drafts = await askJson(`${API_BASE}/api/drafts`);
  if (stale() || drafts === undefined || drafts === null) return;
  const mine = (drafts.drafts || []).filter((draft) => (draft.touched_by || []).some((who) => who.mine));
  const text = mine.length
    ? `未進版的草稿（${mine.length} 份）還在，重新取得編輯權後會接回。`
    : "未進版的草稿已不在（可能已被清除或服務重新啟動）。";
  const old = readonlyBanner.querySelector("[data-testid='readonly-drafts']");
  if (old) old.remove();
  readonlyBanner.appendChild(element("p", { "data-testid": "readonly-drafts", text }));
}

// 問一個只讀端點：回 JSON；後端有回但不是 200、或連不上 → undefined（和「回 null」分開）。
export async function askJson(url) {
  try {
    const response = await apiFetch(url);
    return response.ok ? await response.json() : undefined;
  } catch (_error) {
    return undefined;
  }
}

export function setEditing() {
  document.body.dataset.readonly = "false";
  readonlyBanner.hidden = true;
  // 標頭的身分要跟著回來：轉唯讀時它被改成「唯讀」，取回編輯階段後不改回去的話，畫面說唯讀、
  // 實際上卻可以編輯（人工驗證 U38）。
  if (currentIdentity) currentRole.textContent = identityLabel(currentIdentity);
}

export function identityLabel(identity) {
  return `${identity.name}・${ROLE_TEXT[identity.role] || identity.role}`;
}

// 正在進行的那一次取得：取得還沒回來時又回到清單，不再送第二次——兩發一起接續，晚到的那一發
// 會把先到的那一發剛換到的識別碼清掉，把自己鎖成唯讀（F23 審查）。
export let acquiring = null;

export function acquireSession() {
  // 已經持有（回到清單時也會走到這裡）：不再接續——接續會換識別碼，還帶著舊識別碼、正在路上的
  // 寫入就會被後端擋下（F23）。
  if (sessionToken) return Promise.resolve();
  if (!acquiring) acquiring = takeSession().finally(() => { acquiring = null; });
  return acquiring;
}

export async function takeSession() {
  // 重新整理：舊頁面卸載時已送出釋放，存著的識別碼可能還有效（釋放晚到）也可能已失效（釋放先到）。
  // 先試著接續（後端會換一個新的識別碼，晚到的舊釋放就動不了它）；失效了就往下重新取得。
  const token = storedToken();
  if (token && await renewSession(token, true)) return;
  try {
    const response = await apiFetch(`${API_BASE}/api/session/lock`, { method: "POST" });
    const payload = await response.json();
    if (response.status === 409 && payload.detail && payload.detail.kind === "held") {
      setReadonly(payload.detail.holder, payload.detail.started_at, null);
      return;
    }
    if (!response.ok) {
      setReadonly(null, null, `取不到編輯階段：${detailText(payload.detail)}`);
      return;
    }
    rememberToken(payload.token);
    setEditing();
    if (payload.cleared_drafts) {
      // 上一個階段閒置逾時釋放時的草稿被清掉——說出來，不靜默丟棄（T13）。
      promoteDoneEl.textContent = `上一個編輯階段逾時釋放，清除了 ${payload.cleared_drafts} 份未進版的草稿。`;
      promoteDoneEl.hidden = false;
    }
    if ((payload.kept_drafts || []).length) {
      // 接手到別人存的草稿（ADR-00000032）：說是誰存的、幾份；進版時紀錄作者是自己、內文會註明。
      const counts = new Map();
      for (const kept of payload.kept_drafts) {
        const label = kept.saved_by ? ownerLabel(kept.saved_by) : "存的人不明";
        counts.set(label, (counts.get(label) || 0) + 1);
      }
      const whose = [...counts].map(([label, count]) => `〈${label}〉存的 ${count} 份`).join("、");
      promoteDoneEl.textContent = `接手了${whose}未進版草稿（不重複共 ${payload.kept_drafts.length} 份）；`
        + "進版時紀錄作者是你、內文會註明由誰存。";
      promoteDoneEl.hidden = false;
    }
    if (!renewTimer) renewTimer = setInterval(() => renewSession(sessionToken), RENEW_EVERY_MS);
  } catch (error) {
    setReadonly(null, null, `取不到編輯階段：${failureText("取得編輯階段", error)}`);
  }
}

// `resuming`＝頁面剛載入、拿存著的識別碼回來接續。此時識別碼失效不算「階段被回收」——多半只是
// 自己重新整理時釋放掉的——所以不轉唯讀，交給 acquireSession 重新取得。
export async function renewSession(token, resuming = false) {
  if (!token) return false;
  try {
    const response = await apiFetch(`${API_BASE}/api/session/lock/renew`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token, resume: resuming }),
    });
    if (response.ok) {
      const payload = await response.json();
      rememberToken(payload.token || token);
      setEditing();
      if (!renewTimer) renewTimer = setInterval(() => renewSession(sessionToken), RENEW_EVERY_MS);
      return true;
    }
    if (response.status === 410) {
      // 晚到的舊續期或舊接續（這段時間已經換了識別碼）：它失效不代表現在的這一個失效，不清掉。
      if (resuming ? sessionToken && token !== sessionToken : token !== sessionToken) return false;
      rememberToken(null);
      // 使用中的階段失效：先明確轉唯讀（中性的一句，不猜原因），再問後端是退出、沒有紀錄、還是別人
      // 持有（F28）；不替使用者悄悄重新取得。
      if (!resuming) endEditing(EDITING_ENDED_TEXT, false);
    }
    return false;
  } catch (_error) {
    return false;  // 暫時連不上：下一次續期再試，不因此轉唯讀
  }
}

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireSession() {
  // 關頁（或重新整理）時主動釋放。用 sendBeacon＋text/plain：瀏覽器保證在頁面卸載後仍送出，且不必
  // 跨來源預檢（關頁當下預檢多半來不及）。萬一這發也沒送到，後端的續期逾時會把階段收回（§7.2.2）。
  window.addEventListener("pagehide", () => {
    if (!sessionToken) return;
    const body = new Blob([JSON.stringify({ token: sessionToken })], { type: "text/plain" });
    const sent = navigator.sendBeacon && navigator.sendBeacon(`${API_BASE}/api/session/lock/release`, body);
    if (!sent) {
      apiFetch(`${API_BASE}/api/session/lock`, {
        method: "DELETE",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token: sessionToken }),
        keepalive: true,
      }).catch(() => {});
    }
  });
}
