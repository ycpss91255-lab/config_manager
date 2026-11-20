// 對 backend 的請求：位址、帶 cookie 的 fetch、讀取期限、編輯中的請求標頭，以及失敗訊息的組法。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { loadErrorText } from "./tree.js";
import { loseEditing, sessionToken } from "./session.js";

// 前端與 backend 是兩個容器、兩個 port（設計文件 §3.1），所以這裡不能用相對路徑
// ——相對路徑會打到供應這個檔案的靜態伺服器上，得到 404。
//
// 由 location 推導而不是寫死 127.0.0.1：用 IP 或主機名開這個頁面時（機器人在
// 區網上的常態），寫死的位址會指到看頁面的那台電腦自己。backend 那邊要放行
// 對應的來源，見 CM_ALLOWED_ORIGINS。
export const API_BASE = window.CM_API_BASE || `${location.protocol}//${location.hostname}:8080`;

// 對 backend 的每一個請求都走這裡：身分綁在後端發給這個瀏覽器的票（cookie）上（#288），而 API 在
// 另一個 port，跨來源的 fetch 預設不帶 cookie——少了 credentials 就等於每次都是「還沒說自己是誰」。
export function apiFetch(url, init = {}) {
  return fetch(url, { credentials: "include", ...init });
}

// ── 讀取的期限（F33、F34、F35；11/9 U04「卡住」補驗）──────────────────────────────────
// 後端卡住（連線收下、不回應）時，fetch 不會自己結束：搜尋一直顯示舊結果、檢查差異一直「檢查中…」、
// 重新載入一直空白。所以讀取有期限：**一個動作**從觸發起 15 秒，這個動作裡的每一次讀取共用同一個
// 期限（檢查差異＝讀清單＋搜尋框有字時的重跑搜尋），而且算到讀完並解析回應為止，不只等到標頭。
// 期限一到就中止請求、當成一次失敗，原因寫「等了 15 秒沒有收到回應」。
// **只給讀取用**（`GET /api/search`、`/api/configs`、`/api/mode`、`/api/session`）：寫入送出後中途放棄
// 不代表後端沒寫，所以寫入、送出身分、取得／續期／釋放編輯權都不經過這裡，照舊等到後端回覆。
export const READ_DEADLINE_MS = 15_000;

export class TimedOut extends Error {}

// 一個動作的期限：`signal` 交給這個動作裡的每一次讀取；動作結束時 `finish()` 收掉計時。
export function startDeadline() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new TimedOut(
    `等了 ${READ_DEADLINE_MS / 1000} 秒沒有收到回應`,
  )), READ_DEADLINE_MS);
  return { signal: controller.signal, finish: () => clearTimeout(timer) };
}

// 在期限內讀一個端點並解析成資料：回應標頭、內容、解析都在同一個 signal 底下，期限一到哪一步都停。
// 後端回絕（不是 200）照舊丟 Refused（原因原樣）；期限到了一律丟 TimedOut——不管瀏覽器那一刻給的是
// 哪一種中止錯誤，也不管當時正在讀錯誤回應的內容。
export async function readJson(url, deadline) {
  try {
    const response = await apiFetch(url, { signal: deadline.signal });
    if (!response.ok) throw new Refused(await loadErrorText(response));
    return await response.json();
  } catch (error) {
    if (deadline.signal.aborted) throw deadline.signal.reason;
    throw error;
  }
}

// 會寫入的請求（F23）：後端只接受持有編輯權的那個分頁——帶上這個分頁的編輯階段識別碼。還沒取得
// （或已轉唯讀）就不帶，讓後端說原因；不送字串 "null"。被擋的原因是「編輯權已失效」、而且送出時
// 用的就是這個分頁現在的識別碼，才轉唯讀——晚到的舊回應不把剛換到的新識別碼清掉。回應照樣交回
// 呼叫端，原因由各處在自己的位置顯示。
export const EDITING_HEADER = "X-CM-Editing-Token";

export async function editFetch(url, init = {}) {
  const headers = new Headers(init.headers || {});
  const used = sessionToken;
  if (used) headers.set(EDITING_HEADER, used);
  const response = await apiFetch(url, { ...init, headers });
  if (response.status === 410 && used && used === sessionToken) {
    const payload = await response.clone().json().catch(() => null);
    const detail = payload && payload.detail;
    if (detail && detail.kind === "editing_lost") loseEditing(detail.message);
  }
  return response;
}

// 後端回絕（4xx／5xx）：訊息是後端寫好的（哪個欄位、為什麼、下一步），原樣顯示。
export class Refused extends Error {}

// 一個動作失敗時要顯示的話（#50）：每則都要說得出發生什麼、在哪裡、該怎麼改。後端回絕的，訊息它
// 已經寫好，原樣給；請求根本沒到後端的（斷線、後端沒起來、這個頁面的來源沒被放行），瀏覽器只給
// 一句「Failed to fetch」——這裡補上是哪個動作、結果如何、下一步。失敗的訊息都從這裡出去，
// 不在各處自己拼一句「送不出去」。
export function failureText(action, error) {
  if (error instanceof Refused) return error.message;
  // 讀取等太久（F33–F35）：請求送出了、沒收到回應——不說「送不出去」，也不猜是離線還是斷線。
  if (error instanceof TimedOut) {
    return `「${action}」${error.message}，已停止等待；這個動作沒有完成。`
      + "下一步：確認後端服務還在回應（例如查看後端服務的紀錄），再試一次。";
  }
  const why = error && error.message ? error.message : String(error);
  return `「${action}」送不出去（${why}）：後端沒有回應，這個動作沒有完成。`
    + "下一步：確認後端服務在執行、這台電腦連得到它，再試一次。";
}
