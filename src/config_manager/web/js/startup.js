// 開頁：問後端模式與身分、後端連不上時的提示與重試。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, failureText, readJson, startDeadline } from "./api.js";
import { whileBusy } from "./dialogs.js";
import { EXITED_TEXT } from "./exit.js";
import { identityForm, rememberLabel, showIdentityForm, showList } from "./identity.js";
import { idleRequest } from "./idle.js";

// 已經輸入過身分就直接進清單（重新整理不必再填一次）。
// 模式的中文說法（CONTEXT.md「角色與環境」）。後端回的是代號；不認得的代號原樣顯示，不猜。
export const MODE_TEXT = { development: "開發模式", deployment: "部署模式" };

// 問後端現在是哪個模式（#47）。前端沒有決定權，也沒有端點可改——它只能問。問不到時徽章顯示
// 「模式未知」而不是留白或假設某一種：假設成開發模式會讓之後依模式開關的行為（#48、#288）
// 在部署機上開錯邊。之後的程式碼從 `document.body.dataset.mode` 讀。
// 頁面啟動與「重試」問後端（F35）：模式與身分同時問、共用一個 15 秒期限（先後問最久要 30 秒）。每一次
// 問帶一個世代號：成功、失敗都先核對自己還是最新的那一次——逾時那一次晚到的回應不改徽章、不改提示、
// 不跳頁，也不蓋掉之後那一次重試的狀態。
export let backendAskGeneration = 0;

// 不帶期限單獨呼叫時（只重問模式）：自己起一個 15 秒期限、算是目前這一次，問完更新提示——和 F35 之前
// 單獨呼叫的行為一樣。
export async function loadMode(deadline = null, generation = backendAskGeneration) {
  const badge = document.querySelector("[data-testid='current-mode']");
  const own = deadline ? null : startDeadline();
  try {
    const { mode } = await readJson(`${API_BASE}/api/mode`, deadline || own);
    if (generation !== backendAskGeneration) return;
    document.body.dataset.mode = mode;
    badge.textContent = MODE_TEXT[mode] || mode;
    backendProblems.mode = null;
  } catch (error) {
    if (generation !== backendAskGeneration) return;
    delete document.body.dataset.mode;
    badge.textContent = "模式未知";
    backendProblems.mode = backendProblemText("詢問後端模式", error);
  } finally {
    if (own) own.finish();
  }
  if (own) showBackendProblems();
}

// 身分輸入頁問不到後端（F25）：模式與身分兩個請求各記各的結果——只有一項失敗就只寫那一項；字依原因分：
// 連不上（fetch 丟例外）用「送不出去」那套句型，後端有回但不是 200 用「後端回了 N」那套；兩種都只說
// 觀察到的事，不寫「離線」。
export const unreachableEl = document.querySelector("[data-testid='backend-unreachable']");
export const unreachableText = document.querySelector("[data-testid='backend-unreachable-text']");
export const retryButton = document.querySelector("[data-testid='backend-retry']");
export const backendProblems = { mode: null, identity: null };

export function backendProblemText(action, error) {
  return `問不到後端：${failureText(action, error)}`;
}

export function showBackendProblems() {
  const parts = [backendProblems.mode, backendProblems.identity].filter(Boolean);
  // 問不到的那幾項還沒確認（F35）：寫在最前面——身分頁出現不代表已確認這個瀏覽器沒有身分，模式未知
  // 也不代表是哪一種模式。
  const unconfirmed = [backendProblems.mode && "模式", backendProblems.identity && "身分"]
    .filter(Boolean);
  unreachableText.textContent = parts.length
    ? `${unconfirmed.join("與")}尚未確認。${parts.join(" ")}`
    : "";
  unreachableEl.hidden = parts.length === 0;
}

// 這個瀏覽器宣告過的身分（#288）：有就回它，沒有回 null；問不到回 null 並記下原因。
export async function probeIdentity(deadline, generation) {
  try {
    const identity = await readJson(`${API_BASE}/api/session`, deadline);
    if (generation !== backendAskGeneration) return null;
    backendProblems.identity = null;
    return identity;
  } catch (error) {
    if (generation !== backendAskGeneration) return null;
    // backend 連不上時仍顯示身分輸入頁：那是使用者唯一能操作的東西；原因寫在提示裡、可重試。
    backendProblems.identity = backendProblemText("詢問這個瀏覽器的身分", error);
    return null;
  }
}

// 問一次模式與身分。回 null＝這一次已經過時（有更新的一次開始了），呼叫端什麼都不做；否則回
// { identity }（問不到或沒有身分時是 null，原因已寫進提示）。
export async function askBackend() {
  const generation = ++backendAskGeneration;
  const deadline = startDeadline();
  try {
    const [, identity] = await Promise.all([
      loadMode(deadline, generation),
      probeIdentity(deadline, generation),
    ]);
    if (generation !== backendAskGeneration) return null;
    showBackendProblems();
    return { identity };
  } finally {
    deadline.finish();
  }
}

export async function start() {
  // 身分屬於這個瀏覽器（#288）：後端只回這個瀏覽器自己宣告過的身分，有就直接進清單。等待中頁面上是
  // 「正在向後端詢問模式與身分…」（F35，寫在 HTML 裡、不等程式跑），換到任何一頁時收起。
  const asked = await askBackend();
  if (!asked) return;
  const { identity } = asked;
  if (identity) {
    showList(identity);
    return;
  }
  // 沒有身分：先把身分輸入頁顯示出來（那是使用者唯一能操作的東西，不等任何請求），再問是不是
  // 因閒置被退出的——是的話補上說明（重新整理後也一樣，#48）。
  showIdentityForm();
  const idle = await idleRequest(false);
  if (!idle || identityForm.hidden) return;
  if (idle.left) showIdentityForm(false, EXITED_TEXT);  // 退出後重新整理也說得出是退出（F3）
  else if (idle.timed_out) showIdentityForm(idle.timeout_seconds || true);
}

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireStartup() {
  // 重試只重問模式與身分：不重送表單、不清掉已輸入的姓名、Email、角色；有記住的身分才進清單。
  // 也受同一個 15 秒期限（F35）。
  retryButton.addEventListener("click", () => whileBusy(retryButton, "重試中…", async () => {
    const asked = await askBackend();
    if (!asked) return;
    rememberLabel.hidden = document.body.dataset.mode !== "development";
    if (asked.identity && !identityForm.hidden) showList(asked.identity);
  }));
}
