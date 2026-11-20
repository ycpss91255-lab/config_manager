// 閒置逾時（#48）。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, apiFetch } from "./api.js";
import { draftUids } from "./drafts.js";
import {
  refreshWorkspaceEmpty, setWorkspaceEpoch, workspaceEmpty, workspaceEpoch,
} from "./workspace.js";
import { cancelOpenConfirm } from "./dialogs.js";
import {
  clearPromoteBanners, leftBehindUnreadableEl, leftBehindWarningEl, statusNotUpdatedEl,
} from "./promote.js";
import { rememberToken, renewTimer, setRenewTimer } from "./session.js";
import { GONE_TEXT, exitErrorEl, leaveForExit, refillIdentity } from "./exit.js";
import {
  currentIdentity, identityForm, roleToggle, setCurrentIdentity, showIdentityForm,
} from "./identity.js";

// ── 閒置逾時（#48）──────────────────────────────────────────────────────────────
// 部署模式：這個瀏覽器的人 10 分鐘沒操作就自動退出並釋放編輯階段；逾時前 1 分鐘提示，可延長。
// **判定在後端**（它記最後一次操作的時間）：這裡只做三件事——把「有人在操作」回報上去、照後端說的
// 剩餘時間顯示提示、後端說已逾時就回身分輸入頁。開發模式後端回「不逾時」，這裡就不啟動。
export const IDLE_TICK_MS = window.CM_IDLE_TICK_MS || 15_000;
export const idleWarning = document.querySelector("[data-testid='idle-warning']");
export const idleWarningText = document.querySelector("[data-testid='idle-warning-text']");
export const timeoutNotice = document.querySelector("[data-testid='session-timeout']");
export let idleTimer = null;

// 別的模組要改這個狀態時走這裡：匯入的名稱是唯讀的（#359）。
export function setIdleTimer(value) {
  idleTimer = value;
}

export let idleCountdown = null;
export let interacted = false;
export let lastActivityAt = 0;

// 別的模組要改這個狀態時走這裡：匯入的名稱是唯讀的（#359）。
export function setLastActivityAt(value) {
  lastActivityAt = value;
}

// 後端最近一次說的：{ seconds, at }——還剩幾秒、是在本機的哪個時刻說的（倒數顯示用）。
export let idleLeft = null;

export async function idleRequest(active) {
  try {
    const response = await apiFetch(
      `${API_BASE}/api/session/${active ? "activity" : "idle"}`, { method: active ? "POST" : "GET" },
    );
    return response.ok ? await response.json() : null;
  } catch (_error) {
    return null;  // 問不到：下一輪再問。前端不自己判定逾時。
  }
}

export async function startIdleWatch() {
  stopIdleWatch();
  const view = await idleRequest(false);
  if (!view || view.timeout_seconds === null) return;  // 開發模式（或問不到）：不逾時、不監看
  idleTimer = setInterval(idleTick, IDLE_TICK_MS);
  applyIdle(view);
}

export function stopIdleWatch() {
  if (idleTimer) { clearInterval(idleTimer); idleTimer = null; }
  if (idleCountdown) { clearInterval(idleCountdown); idleCountdown = null; }
  idleWarning.hidden = true;
  idleLeft = null;
  interacted = false;
}

export async function idleTick(active = interacted) {
  interacted = false;
  if (active) lastActivityAt = Date.now();
  applyIdle(await idleRequest(active));
}

export function applyIdle(view) {
  if (!view || !idleTimer) return;
  // 三種「沒身分了」各說各的（F3）：按了退出、閒置逾時、後端沒有這張票的紀錄（例如服務重啟過）。
  if (view.left) { leaveForExit(null); return; }
  if (view.timed_out) { leaveForIdle(view.timeout_seconds); return; }
  if (view.remaining_seconds === null) { leaveForGone(); return; }
  idleLeft = { seconds: view.remaining_seconds, at: Date.now() };
  const warning = view.remaining_seconds <= view.warn_seconds;
  idleWarning.hidden = !warning;
  if (warning && !idleCountdown) idleCountdown = setInterval(showIdleCountdown, 1000);
  if (!warning && idleCountdown) { clearInterval(idleCountdown); idleCountdown = null; }
  showIdleCountdown();
}

// 提示上的秒數是顯示用的倒數（從後端最近一次的答案往下數）；數到 0 就立刻再問後端——退出與否
// 由它說了算。
export function showIdleCountdown() {
  if (!idleLeft || idleWarning.hidden) return;
  const seconds = Math.max(0, Math.ceil(idleLeft.seconds - (Date.now() - idleLeft.at) / 1000));
  const drafts = draftUids.size
    ? `、${draftUids.size} 份未進版的草稿會被清除`
    : "";
  idleWarningText.textContent =
    `已有一段時間沒有操作，約 ${seconds} 秒後將自動退出並釋放編輯階段${drafts}。要繼續請按「繼續使用」。`;
  if (seconds === 0) idleTick(false);
}

// 逾時：後端已清掉這個瀏覽器的身分、釋放了它的編輯階段。回身分輸入頁並說明發生了什麼。表單清空：
// 下一個坐下來的可能是別人，不留上一個人的姓名與 Email 給他按。
export function leaveForIdle(timeoutSeconds) {
  leaveMainPage(true);
  showIdentityForm(timeoutSeconds || true);
}

// 後端已沒有這個瀏覽器的紀錄（例如服務重新啟動過）：身分與編輯權都已失效，但不是閒置逾時（F3）。
export function leaveForGone() {
  const leaving = currentIdentity;
  leaveMainPage(document.body.dataset.mode !== "development");
  refillIdentity(leaving);
  showIdentityForm(false, GONE_TEXT);
}

// 離開主畫面、回身分輸入頁（閒置逾時、退出、身分已失效）：開著的確認框取消、停掉閒置監看與續期、
// 丟掉識別碼與身分。工作區清空——上一個身分打開的區塊（含沒存的改動、開發者才有的入口）不留給下一個
// 進來的人，還在路上的區塊內容回來時也不放回去（F3）。
// `blank`：表單也清空；角色一律回到預設（每次重選，預設落向安全）。
export function leaveMainPage(blank) {
  if (cancelOpenConfirm) cancelOpenConfirm();
  setWorkspaceEpoch(workspaceEpoch + 1);
  stopIdleWatch();
  if (renewTimer) { clearInterval(renewTimer); setRenewTimer(null); }
  rememberToken(null);
  setCurrentIdentity(null);
  for (const node of [...workspace.children]) if (node !== workspaceEmpty) node.remove();
  refreshWorkspaceEmpty();
  clearPromoteBanners();
  for (const node of [leftBehindWarningEl, leftBehindUnreadableEl, statusNotUpdatedEl]) node.hidden = true;
  exitErrorEl.hidden = true;
  if (blank) identityForm.reset();
  for (const button of roleToggle.querySelectorAll("button[data-role]")) {
    button.setAttribute("aria-pressed", String(button.dataset.role === "user"));
  }
}

export function noteInteraction() {
  if (!idleTimer) return;
  interacted = true;
  // 安靜了一陣子之後的第一個動作立刻回報：等下一輪才報的話，人剛回來卻在那幾秒內被判逾時。
  if (Date.now() - lastActivityAt >= IDLE_TICK_MS) idleTick(true);
}

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireIdle() {
  for (const kind of ["pointerdown", "pointermove", "keydown", "wheel", "touchstart"]) {
    window.addEventListener(kind, noteInteraction, { passive: true });
  }
  document.querySelector("[data-testid='idle-extend']").addEventListener("click", () => idleTick(true));
}
