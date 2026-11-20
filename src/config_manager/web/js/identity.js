// W1 身分輸入：角色、記住此裝置、身分輸入頁與清單頁的切換。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, apiFetch, failureText } from "./api.js";
import { markDeveloperOnly } from "./dom.js";
import { load } from "./tree.js";
import { whileBusy } from "./dialogs.js";
import { acquireSession, identityLabel, setReadonly } from "./session.js";
import { leftNotice } from "./exit.js";
import { startIdleWatch, timeoutNotice } from "./idle.js";
import { browseView } from "./browse.js";
import { detailText, whitelistButton, whitelistView } from "./whitelist.js";
import { settingsView } from "./settings.js";
import { confirmView } from "./onboard.js";

// ── W1 身分輸入 ──────────────────────────────────────────────────────────────
// 不是登入：沒有密碼、不驗證、角色是自我宣告（ADR-00000020）。唯一的用途是成為
// 變更紀錄的作者。文案一律用「身分輸入」，因為說「登入」會讓人以為有存取控制
// （CONTEXT.md「避免使用的說法」）。
export const ROLE_TEXT = { user: "一般使用者", developer: "開發者" };

export const identityForm = document.querySelector("[data-testid='identity-form']");
export const identityError = document.querySelector("[data-testid='identity-error']");
export const roleToggle = document.querySelector("[data-testid='role-toggle']");
export const currentRole = document.querySelector("[data-testid='current-role']");
export const header = document.querySelector("header");
export const listView = document.querySelector("main");

export function selectedRole() {
  const pressed = roleToggle.querySelector("[aria-pressed='true']");
  return pressed ? pressed.dataset.role : "user";
}

// 六個整頁 view 靠 hidden 布林互斥切換。集中在這裡把全部設 hidden，各 show* 先呼叫它再打開
// 自己那個——否則每個 show* 都得逐一記得隱藏其餘五個，漏掉一個（whitelistView 先前就被 showList／
// showBrowse／showConfirm 全數漏掉，#252）就會兩個 view 疊著顯示，且殘留 view 裡的控制（如白名單的
// 「確認移除」）還活著、可從不該出現它的畫面觸發不可逆刪除。browseView／confirmView／whitelistView
// 在此函式之後才宣告，但本函式只在事件與啟動時被呼叫（那時整段 script 已初始化完畢），故安全。
// 開頁時「正在向後端詢問模式與身分…」（F35）：換到任何一頁就收起。
export const startupPendingEl = document.querySelector("[data-testid='startup-pending']");

export function hideAllPageViews() {
  startupPendingEl.hidden = true;
  identityForm.hidden = true;
  header.hidden = true;
  listView.hidden = true;
  browseView.hidden = true;
  confirmView.hidden = true;
  whitelistView.hidden = true;
  settingsView.hidden = true;
}

// 記住此裝置（#288）：姓名與 Email 存在這個瀏覽器自己的 localStorage，後端不存。角色刻意不存——
// 每次開啟都要重新選，開發者身分不該因為上次勾過就自動帶著。
export const REMEMBERED_KEY = "cm.identity.remembered";
export const rememberLabel = document.querySelector("[data-testid='remember-device']");

export function rememberedIdentity() {
  try {
    const raw = localStorage.getItem(REMEMBERED_KEY);
    const parsed = raw ? JSON.parse(raw) : null;
    return parsed && typeof parsed.name === "string" && typeof parsed.email === "string" ? parsed : null;
  } catch (_error) {
    return null;
  }
}

export function rememberIdentity(identity) {
  try {
    if (identity) localStorage.setItem(REMEMBERED_KEY, JSON.stringify({ name: identity.name, email: identity.email }));
    else localStorage.removeItem(REMEMBERED_KEY);
  } catch (_error) {
    // 存不進去（私密視窗等）：只是下次要再打一次姓名與 Email。
  }
}

// `timedOut`：因閒置被退出後回到這一頁（值是逾時的秒數，不知道就給 true）；`left`：退出、或身分已
// 失效時要說的話（F3）——說明發生了什麼，不留一張沒頭沒尾的表單。
export function showIdentityForm(timedOut = false, left = "") {
  hideAllPageViews();
  timeoutNotice.hidden = !timedOut;
  leftNotice.hidden = !left;
  leftNotice.textContent = left;
  if (timedOut) {
    const minutes = typeof timedOut === "number" ? `超過 ${Math.round(timedOut / 60) || 1} 分鐘` : "過久";
    timeoutNotice.textContent =
      `閒置${minutes}沒有操作，已自動退出；編輯階段已釋放，未進版的草稿（若有）已清除。`
      + "下一步：重新輸入身分以繼續。";
  }
  // 只在開發模式提供；模式未知時也不提供（不假設是開發模式，#47）。
  rememberLabel.hidden = document.body.dataset.mode !== "development";
  const remembered = rememberLabel.hidden ? null : rememberedIdentity();
  if (remembered) {
    identityForm.elements.name.value = remembered.name;
    identityForm.elements.email.value = remembered.email;
    identityForm.elements.remember.checked = true;
  }
  identityForm.hidden = false;
}

// 目前身分。browse 的拒絕 UX 依角色分流（開發者才有加入白名單入口），返回也靠它。
export let currentIdentity = null;

// 別的模組要改這個狀態時走這裡：匯入的名稱是唯讀的（#359）。
export function setCurrentIdentity(value) {
  currentIdentity = value;
}


export function showList(identity) {
  currentIdentity = identity;
  hideAllPageViews();
  header.hidden = false;
  listView.hidden = false;
  currentRole.textContent = identityLabel(identity);
  // 白名單維護面板開發者專屬：按鈕對一般使用者不出現於 DOM（UI-ELEMENTS.md 角色表、
  // ADR-00000020），不是停用。一般使用者的檢視走 browse 的根清單與允許範圍。
  whitelistButton.hidden = identity.role !== "developer";
  markDeveloperOnly(whitelistButton, identity.role === "developer");
  load();
  acquireSession();
  startIdleWatch();
}

// 別人正持有編輯階段（#33）：沒有自己的身分也能看清單，但一切會寫入的控制項不出現。
export function showReadonlyList(detail) {
  currentIdentity = null;
  hideAllPageViews();
  header.hidden = false;
  listView.hidden = false;
  currentRole.textContent = "唯讀";
  whitelistButton.hidden = true;
  markDeveloperOnly(whitelistButton, false);
  setReadonly(detail.holder, detail.started_at, null);
  load();
}

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireIdentity() {
  roleToggle.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-role]");
    if (!button) return;
    for (const option of roleToggle.querySelectorAll("button[data-role]")) {
      option.setAttribute("aria-pressed", String(option === button));
    }
  });

  identityForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    identityError.hidden = true;

    const body = {
      name: identityForm.elements.name.value,
      email: identityForm.elements.email.value,
      role: selectedRole(),
    };

    await whileBusy(identityForm.querySelector("button.enter"), "進入中…", async () => {
      try {
        const response = await apiFetch(`${API_BASE}/api/session`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
        });
        const payload = await response.json();
        if (response.status === 409 && payload.detail && payload.detail.kind === "held") {
          // 別人正在編輯：不換身分（否則對方的紀錄會掛到你頭上），改以唯讀進清單（§7.2.2）。
          showReadonlyList(payload.detail);
          return;
        }
        if (!response.ok) {
          // 端點的訊息已經寫成可行動的樣子（欄位＋原因＋下一步），原樣顯示，
          // 不在這裡改寫成一句籠統的「輸入無效」（不變式 2）。
          identityError.textContent = detailText(payload.detail) || `${response.status} ${response.statusText}`;
          identityError.hidden = false;
          return;
        }
        rememberIdentity(!rememberLabel.hidden && identityForm.elements.remember.checked ? payload : null);
        showList(payload);
      } catch (error) {
        identityError.textContent = failureText("送出身分", error);
        identityError.hidden = false;
      }
    });
  });
}
