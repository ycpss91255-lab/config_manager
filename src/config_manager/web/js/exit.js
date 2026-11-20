// 退出（F3）。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, apiFetch, failureText } from "./api.js";
import { participantsText } from "./drafts.js";
import { workspace } from "./workspace.js";
import { confirmAction, isBusy, whileBusy } from "./dialogs.js";
import { askWhyEditingEnded, sessionToken } from "./session.js";
import { currentIdentity, identityForm, showIdentityForm } from "./identity.js";
import { leaveForIdle, leaveMainPage } from "./idle.js";
import { detailText } from "./whitelist.js";

// ── 退出（F3）────────────────────────────────────────────────────────────────
// 換人、換角色：清掉這個瀏覽器的身分，回到身分輸入頁。只影響這個瀏覽器（別的瀏覽器的身分與編輯權
// 不動），所以唯讀的分頁也能按。這個瀏覽器持有編輯權時當場釋放，並清掉目前全部共用草稿（暫行規則：
// 可能包含從前一位接手的草稿，F22 未解）。有東西會丟——未進版的草稿、區塊裡沒存的改動、持有的是這個
// 瀏覽器的另一個分頁——後端回 confirm_required，照它說的逐項寫進確認框，確認了才再送一次。
export const exitButton = document.querySelector("[data-testid='exit']");
export const exitErrorEl = document.querySelector("[data-testid='exit-error']");
export const leftNotice = document.querySelector("[data-testid='session-left']");
export const EXITED_TEXT = "這個瀏覽器已退出（在這個或另一個分頁按了「退出」），它持有的編輯權已一併釋放。"
  + "下一步：重新輸入身分以繼續（可以換人、換角色）。";
export const EXITED_REFUSED_TEXT = "這個瀏覽器已退出（在另一個分頁按了「退出」），它持有的編輯權已一併釋放；"
  + "剛才在這個分頁送出的改動沒有寫進去。下一步：重新輸入身分以繼續（可以換人、換角色）。";
export const GONE_TEXT = "身分已失效：後端沒有這個瀏覽器的紀錄（例如服務重新啟動過），不是閒置逾時；編輯權也已失效，"
  + "未進版的草稿也已不在。下一步：重新輸入身分以繼續。";

export async function sendExit(confirmed) {
  const response = await apiFetch(`${API_BASE}/api/session`, {
    method: "DELETE",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      confirmed,
      unsaved: workspace.querySelector("[data-dirty='true']") !== null,
      token: sessionToken,
    }),
  });
  return { response, payload: await response.json().catch(() => null) };
}

export function exitLosses(detail) {
  const losses = [];
  if (detail.drafts) {
    // 逐人列（ADR-00000032）：清掉的是目前全部共用草稿（含別人存的），說清楚誰參與了幾份。
    const who = (detail.by_owner || []).length
      ? `：${participantsText(detail.by_owner, detail.distinct ?? detail.drafts)}`
      : "";
    losses.push(`${detail.drafts} 份未進版的草稿將遺失（清掉的是目前全部共用草稿，含別人存的）${who}`);
  }
  if (detail.unsaved) losses.push("目前區塊裡還沒儲存的改動將遺失");
  if (detail.other_tab) losses.push("這個瀏覽器另一個分頁正在編輯，退出會釋放它的編輯權，那邊沒存的改動也會丟失");
  return losses;
}

// 進行中分兩段（F24）：先問後端要不要確認那一發寫「確認退出條件中…」；確認框開著、人還沒選時
// 退出鈕還原成「退出」（不是進行中——那看起來像已經在退出）；按「退出並丟掉」真正送出才「退出中…」。
export async function exitBrowser() {
  if (isBusy(exitButton)) return;
  exitErrorEl.hidden = true;
  try {
    let { response, payload } = await whileBusy(exitButton, "確認退出條件中…", () => sendExit(false));
    const detail = payload && payload.detail;
    if (response.status === 409 && detail && detail.kind === "confirm_required") {
      const ok = await confirmAction(
        "退出這個瀏覽器？",
        `${exitLosses(detail).join("；")}。無法復原；這個瀏覽器的其他分頁也會跟著退出。`,
        "退出並丟掉",
      );
      if (!ok || !identityForm.hidden) return;  // 取消了，或確認框開著時已經回到身分輸入頁
      ({ response, payload } = await whileBusy(exitButton, "退出中…", () => sendExit(true)));
    }
    if (!response.ok) {
      const why = payload && payload.detail ? detailText(payload.detail) : `${response.status} ${response.statusText}`;
      showExitError(`退出失敗，仍在主畫面：${why}`);
      return;
    }
    announceExit();
    // 按下去時其實已閒置逾時（例如筆電睡過頭、頁面還沒問到）：照閒置逾時說，不說成「沒有編輯權」。
    if (payload && payload.timed_out) leaveForIdle(null);
    else leaveForExit(payload);
  } catch (error) {
    showExitError(failureText("退出", error));
  }
}

export function showExitError(text) {
  exitErrorEl.textContent = text;
  exitErrorEl.hidden = false;
}

// 退出了（這個分頁按的；`result` 是 null＝後端說這個瀏覽器已退出，是另一個分頁按的）：回身分輸入頁並
// 說明。開發模式姓名與 Email 留在表單上、只要重選角色（換角色不必重打身分）；部署模式一律清空——
// 共用機器，下一個坐下來的可能是別人。模式未知也清空。
export function leaveForExit(result, refusedWrite = false) {
  const leaving = currentIdentity;
  leaveMainPage(document.body.dataset.mode !== "development");
  refillIdentity(leaving);
  const elsewhere = refusedWrite ? EXITED_REFUSED_TEXT : EXITED_TEXT;
  showIdentityForm(false, result ? exitedText(result) : elsewhere);
}

// 開發模式：姓名與 Email 照剛才的身分填回表單。這一頁載入時身分就是現成的（重新整理過、第二個分頁）
// 的話，表單上本來沒有字。部署模式與模式未知不填。
export function refillIdentity(identity) {
  if (!identity || document.body.dataset.mode !== "development") return;
  identityForm.elements.name.value = identity.name;
  identityForm.elements.email.value = identity.email;
}

export function exitedText(result) {
  const released = result.released ? "編輯權已釋放" : "這個瀏覽器原本沒有編輯權，別人的編輯不受影響";
  const who = (result.by_owner || []).length
    ? `（${participantsText(result.by_owner, result.distinct ?? result.cleared_drafts)}）`
    : "";
  const cleared = result.cleared_drafts ? `，清除了 ${result.cleared_drafts} 份未進版的草稿${who}` : "";
  return `已退出：${released}${cleared}。下一步：重新輸入身分以繼續（可以換人、換角色）。`;
}

// 退出後通知這個瀏覽器的其他分頁，讓它們立刻一起回身分輸入頁（使用者 10/21 選定）——唯讀分頁沒有續期、
// 開發模式沒有閒置輪詢，不通知的話它們要到重新整理才知道。同一個來源的分頁共用 localStorage：寫一筆，
// 其他分頁就收到 `storage` 事件（寫的那一頁自己收不到）。收到的分頁問後端這個瀏覽器是不是真的已退出，
// 是才離開。存不進去（私密視窗等）就退回原本那條路：下一次跟後端溝通時才知道。
export const EXITED_KEY = "cm.session.exited";

export function announceExit() {
  try {
    localStorage.setItem(EXITED_KEY, String(Date.now()));
  } catch (_error) {
    // 見上：其他分頁改在下一次跟後端溝通時得知。
  }
}

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireExit() {
  exitButton.addEventListener("click", exitBrowser);

  window.addEventListener("storage", (event) => {
    if (event.key === EXITED_KEY && identityForm.hidden) askWhyEditingEnded(false);
  });
}
