// W9 白名單維護（#15）。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, Refused, apiFetch, editFetch, failureText } from "./api.js";
import { element } from "./dom.js";
import { loadErrorText } from "./tree.js";
import { confirmAction, isBusy, whileBusy } from "./dialogs.js";
import { currentIdentity, hideAllPageViews, showList } from "./identity.js";
import { browsePathInput, browseTo, browseView, confirmAddRoot } from "./browse.js";

// ── W9 白名單維護（#15）──────────────────────────────────────────────────────
// 開發者專屬面板：檢視誰/何時、新增含候選數預覽（GET /api/candidate-count，#206）、
// 移除含受影響確認（DELETE 未帶 confirmed 先回受影響清單＋409）。按鈕由 showList 依角色
// 顯示/隱藏。逃逸（../、symlink）由後端擋成 422，這裡原樣呈現。
export const whitelistView = document.querySelector("[data-testid='whitelist']");
export const whitelistButton = document.querySelector("[data-testid='open-whitelist']");
export const whitelistRootsEl = document.querySelector("[data-testid='whitelist-roots']");
export const whitelistAddInput = document.querySelector("[data-testid='whitelist-add-input']");
export const whitelistPreviewEl = document.querySelector("[data-testid='whitelist-preview']");
export const whitelistErrorEl = document.querySelector("[data-testid='whitelist-error']");
// 每次預覽遞增；晚到的舊預覽若世代已變就丟棄——否則「此路徑下有 N 個可納管檔」會顯示上一次
// 輸入的數字，與目前輸入框不符；加入成功時也遞增它，作廢加入前送出、仍在途的預覽（#252）。
export let previewGeneration = 0;

// 端點的 detail 有兩形：純字串（add／remove 的值錯誤）或物件（candidate-count 與 DELETE
// 確認的 {kind, message, …}）。兩者都取得出可行動訊息，不自造籠統字句（不變式 2）。
export function detailText(detail) {
  if (typeof detail === "string") return detail;
  if (detail && detail.message) return detail.message;
  return JSON.stringify(detail);
}

export function showWhitelist() {
  hideAllPageViews();
  whitelistView.hidden = false;
  whitelistAddInput.value = "";
  whitelistPreviewEl.hidden = true;
  whitelistErrorEl.hidden = true;
  loadWhitelist();
}

export async function loadWhitelist() {
  try {
    const response = await apiFetch(`${API_BASE}/api/allowed-roots`);
    if (!response.ok) throw new Refused(await loadErrorText(response));
    const roots = (await response.json()).roots;
    if (!roots.length) {
      whitelistRootsEl.replaceChildren(
        element("li", {
          class: "whitelist-empty", "data-testid": "whitelist-empty",
          text: "白名單目前是空的，所以沒有任何目錄可以瀏覽或納管。下一步：在上方輸入一個目錄的絕對路徑，按「加入白名單」。",
        })
      );
      return;
    }
    whitelistRootsEl.replaceChildren(...roots.map(whitelistRootRow));
  } catch (error) {
    whitelistRootsEl.replaceChildren(
      element("li", { class: "whitelist-empty", text: failureText("讀取白名單", error) })
    );
  }
}

export function whitelistRootRow(root) {
  const remove = element("button", {
    type: "button", "data-testid": "whitelist-remove", text: "移除",
  });
  remove.addEventListener("click", () => beginRemoveRoot(root.prefix, remove));
  // 解析不出唯一位置的根（F19）：後端 resolved 為 null、problem 說原因——顯示原因，不顯示假路徑。
  const where = root.problem
    ? element("span", { class: "whitelist-problem", "data-testid": "whitelist-problem", text: root.problem })
    : element("span", { class: "whitelist-resolved", text: root.resolved });
  return element("li", { "data-testid": `whitelist-root-${root.prefix}`, "data-prefix": root.prefix }, [
    element("span", { class: "whitelist-prefix", text: root.prefix }),
    where,
    element("span", { class: "whitelist-who", text: `由 ${root.added_by} 於 ${root.added_at}` }),
    remove,
  ]);
}

export async function previewCandidates() {
  whitelistErrorEl.hidden = true;
  const prefix = whitelistAddInput.value.trim();
  if (!prefix) { whitelistPreviewEl.hidden = true; return; }
  const generation = ++previewGeneration;
  try {
    const response = await apiFetch(`${API_BASE}/api/candidate-count?prefix=${encodeURIComponent(prefix)}`);
    const payload = await response.json();
    if (generation !== previewGeneration) return;  // 有更新的預覽／加入開始了，這個回應過時、丟棄
    if (!response.ok) {
      whitelistPreviewEl.hidden = true;
      whitelistErrorEl.textContent = detailText(payload.detail);
      whitelistErrorEl.hidden = false;
      return;
    }
    const shown = payload.capped ? `${payload.count}+` : `${payload.count}`;
    whitelistPreviewEl.textContent = `此路徑下有 ${shown} 個可納管檔。`;
    whitelistPreviewEl.hidden = false;
  } catch (error) {
    if (generation !== previewGeneration) return;
    whitelistPreviewEl.hidden = true;
    whitelistErrorEl.textContent = failureText("計算可納管檔案數", error);
    whitelistErrorEl.hidden = false;
  }
}

export function clearPreview() {
  ++previewGeneration;  // 仍在途的預覽回來時作廢
  whitelistPreviewEl.hidden = true;
  whitelistPreviewEl.textContent = "";
}

export async function addRoot(button) {
  if (isBusy(button)) return;
  whitelistErrorEl.hidden = true;
  clearPreview();  // 舊的預覽不留到這次的結果旁邊——那會被誤認成目前路徑的數字
  const prefix = whitelistAddInput.value.trim();
  if (!prefix) return;
  const showError = (text) => {
    whitelistErrorEl.textContent = text;
    whitelistErrorEl.hidden = false;
  };
  if (!await confirmAddRoot(prefix, showError)) return;
  await whileBusy(button, "加入中…", async () => {
    try {
      const response = await editFetch(`${API_BASE}/api/allowed-roots`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ prefix }),
      });
      const payload = await response.json();
      if (!response.ok) {
        whitelistErrorEl.textContent = detailText(payload.detail);
        whitelistErrorEl.hidden = false;
        return;
      }
      whitelistAddInput.value = "";
      whitelistPreviewEl.hidden = true;
      ++previewGeneration;  // 作廢加入前送出、仍在途的預覽，免得它稍後把已清空的預覽面板顯示回來（#252）
      loadWhitelist();
    } catch (error) {
      whitelistErrorEl.textContent = failureText("加入白名單", error);
      whitelistErrorEl.hidden = false;
    }
  });
}

export async function beginRemoveRoot(prefix, button) {
  if (isBusy(button)) return;
  // 先以 confirmed=false 問後端：有受影響的納管項目就列出＋要求確認，不靜默移除（AC3）。
  // 後端在未確認時一律回 409 confirm_required（含受影響清單，可能為空）。
  whitelistErrorEl.hidden = true;
  try {
    const response = await editFetch(`${API_BASE}/api/allowed-roots`, {
      method: "DELETE",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ prefix, confirmed: false }),
    });
    const payload = await response.json();
    if (response.status === 409 && payload.detail && payload.detail.kind === "confirm_required") {
      if (await confirmRemoval(prefix, payload.detail)) await confirmRemoveRoot(prefix, button);
      return;
    }
    whitelistErrorEl.textContent = detailText(payload.detail);
    whitelistErrorEl.hidden = false;
  } catch (error) {
    whitelistErrorEl.textContent = failureText("移除白名單", error);
    whitelistErrorEl.hidden = false;
  }
}

// 移除的確認走共用的確認對話框（#50）。這段是寫給按按鈕的人看的，由介面自己說：要移除的是哪一個、
// 會怎樣、已納管的受不受影響——受影響的項目列在對話框裡。
export function confirmRemoval(prefix, detail) {
  const affected = (detail.affected || []).map((item) => `${item.ref}：${item.target}`);
  const about = affected.length
    ? `以下 ${affected.length} 份已納管的設定的目標在這個路徑底下——它們不受影響，仍會繼續管理：`
    : "目前沒有已納管的設定的目標在這個路徑底下。";
  return confirmAction(
    `把「${prefix}」從白名單移除？`,
    `移除後這個路徑底下的檔案不能再瀏覽或納管；之後可以再加回來。${about}`,
    "從白名單移除",
    affected,
  );
}

export async function confirmRemoveRoot(prefix, button) {
  await whileBusy(button, "移除中…", async () => {
    try {
      const response = await editFetch(`${API_BASE}/api/allowed-roots`, {
        method: "DELETE",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ prefix, confirmed: true }),
      });
      const payload = await response.json();
      if (!response.ok) {
        whitelistErrorEl.textContent = detailText(payload.detail);
        whitelistErrorEl.hidden = false;
        return;
      }
      loadWhitelist();
    } catch (error) {
      whitelistErrorEl.textContent = failureText("移除白名單", error);
      whitelistErrorEl.hidden = false;
    }
  });
}
export const whitelistAddButton = whitelistView.querySelector("[data-testid='whitelist-add']");

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireWhitelist() {
  whitelistButton.addEventListener("click", showWhitelist);
  whitelistView.querySelector("[data-testid='whitelist-back']")
    .addEventListener("click", () => showList(currentIdentity));
  whitelistView.querySelector("[data-testid='whitelist-preview-button']")
    .addEventListener("click", previewCandidates);
  whitelistAddButton.addEventListener("click", () => addRoot(whitelistAddButton));
  // 路徑一改，先前的預覽就不是這個路徑的了：清掉，不留著讓人誤認。
  whitelistAddInput.addEventListener("input", () => {
    clearPreview();
    whitelistErrorEl.hidden = true;
  });
  browseView.querySelector(".browse-go").addEventListener("click", () => {
    const path = browsePathInput.value.trim();
    if (path) browseTo(path);
  });
}
