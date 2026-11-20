// 確認對話框與「忙碌中」的按鈕狀態。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { element } from "./dom.js";
import { exitButton } from "./exit.js";

// ── 進版與捨棄變更（#22）─────────────────────────────────────────────────────
// 進版是全域動作：全部草稿一次驗證、記錄、寫出，整批原子（§7.4.3、T18）。任一份沒過整批不進版，
// 後端指名哪一份（uid）的哪些參數（行號／原因／建議）——原樣列在橫幅上並打開那份。捨棄變更清草稿、
// 回到來源內容，不動來源也不動目標；不可逆，先經 W6 的確認對話框。
export const confirmDialog = document.querySelector("[data-testid='confirm-dialog']");

// 所有要先確認的動作共用這一個對話框（#50），文案與行為一致：標題是問句、指名對象；內文說會
// 發生什麼、什麼不會變、能不能復原；確認鈕寫的是那個動作本身（`okLabel`，不是一律「確認」），
// 取消鈕永遠在、Esc 也是取消；**開啟時焦點在取消**——手滑按到 Enter 不會把東西刪掉。
// `items` 是要一併列給人看的清單（例如移除白名單時受影響的項目），沒有就不顯示。
// 開著的確認框的「取消」：回身分輸入頁時呼叫，確認框跟著關掉——留著的話，之後按下去會替已經離開的
// 身分做事（F3）。沒開著是 null。
export let cancelOpenConfirm = null;

export function confirmAction(title, body, okLabel = "確認", items = [], warning = "") {
  confirmDialog.querySelector("[data-testid='confirm-title']").textContent = title;
  confirmDialog.querySelector("[data-testid='confirm-body']").textContent = body;
  const warningLine = confirmDialog.querySelector("[data-testid='confirm-warning']");
  warningLine.textContent = warning;
  warningLine.hidden = !warning;
  const list = confirmDialog.querySelector("[data-testid='confirm-items']");
  list.replaceChildren(...items.map((text) => element("li", { text })));
  list.hidden = items.length === 0;
  confirmDialog.querySelector("[data-testid='confirm-ok']").textContent = okLabel;
  return new Promise((resolve) => {
    const finish = (answer) => {
      cancelOpenConfirm = null;
      okButton.removeEventListener("click", onOk);
      cancelButton.removeEventListener("click", onCancel);
      confirmDialog.removeEventListener("cancel", onCancel);
      if (confirmDialog.open) confirmDialog.close();
      resolve(answer);
    };
    const onOk = () => finish(true);
    const onCancel = () => finish(false);
    const okButton = confirmDialog.querySelector("[data-testid='confirm-ok']");
    const cancelButton = confirmDialog.querySelector("[data-testid='confirm-cancel']");
    okButton.addEventListener("click", onOk);
    cancelButton.addEventListener("click", onCancel);
    // Esc 走 `cancel` 事件，不聽 `close`：`close` 連我們自己關對話框時也會發、而且是晚一拍才發——
    // 上一個確認剛關、下一個確認緊接著開的話，那個晚到的 `close` 會把新的這一個當成被取消。
    confirmDialog.addEventListener("cancel", onCancel);
    cancelOpenConfirm = onCancel;
    confirmDialog.showModal();
    cancelButton.focus();
  });
}

// 進行中的指示（#50）：會寫入或要等一下的動作，按下後那顆按鈕標成進行中（`aria-busy`、文字換成
// 「…中」、不能再按），做完還原——看得出有在跑，也不會因為多按一下而送出兩次。
export async function whileBusy(button, label, work) {
  if (!button) return work();
  if (isBusy(button)) return undefined;  // 已經在跑：這一下不算（例如表單被 Enter 再送一次）
  const idle = button.textContent;
  button.setAttribute("aria-busy", "true");
  button.inert = true;  // 滑鼠與鍵盤都按不到；不動 disabled——那是各個動作自己在管的
  button.textContent = label;
  refreshExitButton();
  try {
    return await work();
  } finally {
    button.removeAttribute("aria-busy");
    button.inert = false;
    // 動作自己改過按鈕文字（例如進版後變成「進版 (0)」）就不動它。
    if (button.textContent === label) button.textContent = idle;
    refreshExitButton();
  }
}

// 有動作正在跑（進版、寫出…）時不能退出（F3）：退出會釋放編輯權、清掉草稿，跑到一半的動作會被擋下。
export function refreshExitButton() {
  // 樹的 aria-busy（F33：搜尋等待中）標的是「畫面內容還不是這次的」，不是一個跑到一半的動作——
  // 不算進來，否則搜尋卡住時會連帶擋住退出。
  exitButton.disabled =
    document.querySelector("[aria-busy='true']:not([data-testid='config-tree'])") !== null;
}

// 要先確認的動作在最前面問這個：已經在跑就不再開一次確認對話框。
export function isBusy(button) {
  return Boolean(button) && button.getAttribute("aria-busy") === "true";
}
