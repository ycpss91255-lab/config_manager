// 參數層級搜尋（#37、§7.4.2）：走 GET /api/search，不在前端自己比對。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, failureText, readJson, startDeadline } from "./api.js";
import { load, loadError, markSummaryUnconfirmed, render, tree } from "./tree.js";

export const search = document.querySelector("[data-testid='search-input']");

// ── 參數層級搜尋（#37、§7.4.2）：走 GET /api/search（#32），不在前端自己比對——「哪些 config 有
// max_vel」是索引層級的問題，前端只拿到清單列。命中的 config 留在樹上，命中的參數在展開時標示並定位。
export const searchScope = document.querySelector("[data-testid='search-scope']");
export let searchHits = null;  // null＝沒有查詢（全部顯示）；否則是命中的 uid 集合
export let hitParams = new Map();  // uid → 命中的參數路徑
export let searchError = null;
// 上一次搜尋失敗過（F26）：清空搜尋框時不拿記憶體裡停機前的清單充數，重新讀一次——讀得到才是現況。
export let searchFailed = false;
export let searchGeneration = 0;
export let searchTimer = null;
export let hitsQuery = "";  // 樹上現在的命中是哪一個搜尋字查到的（F33 的等待標示要說得出來）
export const searchPendingEl = document.querySelector("[data-testid='search-pending']");

export function scheduleSearch() {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(runSearch, 150);  // 打字中不每字打一次端點
}

// `deadline`：檢查差異重跑搜尋時沿用它的期限（一個動作共用一個，F34）；其他時候這次搜尋自己起一個。
export async function runSearch(deadline = null) {
  const generation = ++searchGeneration;
  const query = search.value.trim();
  if (!query) {
    showSearchPending(null);
    searchHits = null;
    hitParams = new Map();
    searchError = null;
    if (searchFailed) {
      // 失敗過的那段期間清單可能已經不是現況（後端停過）：重新讀，讀不到就是黏性的「讀不到」。
      searchFailed = false;
      await load();
      return;
    }
    render();
    return;
  }
  showSearchPending(query);
  const own = deadline ? null : startDeadline();
  try {
    const params = new URLSearchParams({ q: query, scope: searchScope.value });
    const payload = await readJson(`${API_BASE}/api/search?${params}`, deadline || own);
    // 成功、失敗都先核對自己還是最新的那一次：較新的搜尋（或清空）開始之後，這一次的結果、錯誤、
    // 等待標示一律不碰（F33：逾時的那一次晚到也一樣）。
    if (generation !== searchGeneration) return;
    searchHits = new Set(payload.hits.map((hit) => hit.uid));
    hitParams = new Map(payload.hits.map((hit) => [hit.uid, hit.params.map((param) => param.path)]));
    hitsQuery = query;
    searchError = null;
    searchFailed = false;
  } catch (error) {
    if (generation !== searchGeneration) return;
    // 搜尋失敗不能靜默顯示成「沒有符合的項目」——那會讓人以為參數不存在（不變式 2、T14）。
    searchError = failureText("搜尋", error);
    searchFailed = true;
    markSummaryUnconfirmed();
  } finally {
    if (own) own.finish();  // 只收自己起的計時；共用的期限由起它的動作收
  }
  showSearchPending(null);
  render();
}

// 搜尋等待中（F33）：樹上還是上一次的畫面——寫明那是哪一次的、還不是這次的，樹標成進行中（淡化），
// 不讓人把舊結果當成這次查到的。`query` 為 null＝收起來。
export function showSearchPending(query) {
  if (query === null) {
    searchPendingEl.hidden = true;
    tree.removeAttribute("aria-busy");
    return;
  }
  let shown = `下方仍是「${hitsQuery}」的結果，還不是這次的。`;
  if (searchError !== null || loadError !== null) shown = "下方還不是這次的結果。";
  else if (searchHits === null) shown = "下方仍是完整清單，還不是這次的結果。";
  searchPendingEl.textContent = `正在搜尋「${query}」…${shown}`;
  searchPendingEl.hidden = false;
  tree.setAttribute("aria-busy", "true");
}

export function matches(row) {
  return searchHits === null || searchHits.has(row.uid);
}

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireSearch() {
  search.addEventListener("input", scheduleSearch);
  searchScope.addEventListener("change", scheduleSearch);
}
