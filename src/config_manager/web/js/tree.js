// W2 config 清單：讀清單、依群組或主機排出樹、狀態燈號、重新檢查。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, failureText, readJson, startDeadline } from "./api.js";
import { element } from "./dom.js";
import { draftDetails, draftUids, loadDrafts, ownerLabel } from "./drafts.js";
import { matches, runSearch, search, searchError, searchScope } from "./search.js";
import { selectItem, selectedUid, syncOpenPanels, workspaceEmpty } from "./workspace.js";
import { whileBusy } from "./dialogs.js";
import { leftBehindTag, loadLeftBehind, statusNotUpdatedEl } from "./promote.js";
import { detailText } from "./whitelist.js";

// 狀態的中文說法取自 CONTEXT.md，不在這裡另造。「未納管」不會出現在這份清單裡
// ——它的定義是「不在清單檔中」，而這份清單就是清單檔。它屬於納管流程的畫面。
export const STATE_TEXT = {
  in_sync: "一致",
  drift: "偏離",
  missing: "未部署",
};

export const UNGROUPED = "ungrouped";
export const tree = document.querySelector("[data-testid='config-tree']");
export let rows = [];
// 非 null 表示上次載入失敗。render() 綁在搜尋輸入上、每次無條件從 rows 重畫；少了這個
// 旗標，在錯誤態打字就會把 load-error 靜默蓋成空清單或過期清單（不變式 2：大聲失敗）。
export let loadError = null;
// 每次載入遞增；回應回來時若世代已變（使用者又按了「檢查差異」、或啟動載入與手動重掃交錯），
// 丟棄這個過時回應——否則晚到的舊回應會把新結果覆蓋，或把該顯示的錯誤靜默蓋掉／反之黏住假錯誤（#252）。
export let loadGeneration = 0;

export function groupsOf(row) {
  return row.groups && row.groups.length ? row.groups : [UNGROUPED];
}

// 一份 config 屬多個群組時，在每個群組節點下都出現（T16）。
export function byGroup(items) {
  const buckets = new Map();
  for (const row of items) {
    for (const group of groupsOf(row)) {
      if (!buckets.has(group)) buckets.set(group, []);
      buckets.get(group).push(row);
    }
  }
  return [...buckets.entries()].sort(([a], [b]) => {
    if (a === UNGROUPED) return 1;
    if (b === UNGROUPED) return -1;
    return a.localeCompare(b);
  });
}

export function rowNodeBase(row) {
  if (row.error) {
    // 判不出狀態的那一列（目標是 FIFO／裝置／不可 traverse／讀不到，#214）：標「錯誤」，不畫一個
    // 偽裝的狀態點——把「比不了」講成某個狀態就是靜默失敗（不變式 2）。原因與下一步原樣寫在下一行
    // （F5、人工驗收 U18）：只放在 title 裡，看畫面的人不知道為什麼、該怎麼辦；title 也留著。
    return element("li", {
      "data-testid": `tree-item-${row.uid}`, "data-uid": row.uid, "data-state": "error",
    }, [
      element("span", {
        class: "dot dot-error",
        "data-testid": "status-dot",
        "data-state": "error",
        title: row.error,
      }),
      element("span", { class: "name", text: row.name }),
      element("span", { class: "target", text: row.target }),
      element("span", {
        class: "state",
        "data-testid": "row-error",
        text: "錯誤",
        title: row.error,
      }),
      element("span", { class: "row-reason", "data-testid": "row-error-reason", text: row.error }),
    ]);
  }
  // 狀態色點在左，與草稿標記（右側，隨 T18 加入）分開——UI-ELEMENTS W2 的左側樹。
  // 說明於樹節點滑鼠停留時顯示（§7.4.4、#286）。
  const attributes = { "data-testid": `tree-item-${row.uid}`, "data-uid": row.uid };
  if (row.description) attributes.title = row.description;
  return element("li", attributes, [
    element("span", {
      class: `dot dot-${row.state}`,
      "data-testid": "status-dot",
      "data-state": row.state,
      title: STATE_TEXT[row.state] || row.state,
    }),
    element("span", { class: "name", text: row.name }),
    element("span", { class: "target", text: row.target }),
    element("span", { class: "state", text: STATE_TEXT[row.state] || row.state }),
  ]);
}

// 草稿標記在節點右側，與左側的狀態色點分開（§7.4.3、UI-ELEMENTS W2）：草稿與四種狀態正交，
// 一份「一致」的 config 可以同時有草稿。有沒有草稿以 GET /api/drafts 為準（#21）。
export function rowNode(row) {
  const node = rowNodeBase(row);
  if (row.left_behind) node.appendChild(leftBehindTag(row.left_behind));
  if (draftUids.has(row.uid)) {
    const draft = draftDetails.get(row.uid);
    const who = draft && draft.saved_by ? `（${ownerLabel(draft.saved_by)} 存）` : "";
    node.appendChild(element("span", {
      class: "dot dot-draft", "data-testid": "draft-dot", title: `有未進版的草稿${who}`,
    }));
  }
  return node;
}

// 樹每次重畫（重掃、搜尋、草稿變動）都整棵換掉：選取與鍵盤焦點要跟著留下來（#50），否則用方向鍵
// 走到一半、背景重掃一次就掉回開頭。
export function render() {
  const hadFocus = tree.contains(document.activeElement);
  renderTree();
  selectItem(selectedUid, hadFocus);
}

export function renderTree() {
  if (loadError !== null) {
    // 載入失敗是黏性的：重畫 load-error，不讀 rows。否則搜尋輸入一觸發 render 就把錯誤
    // 蓋成空清單／過期清單，而「讀不到」與「沒有」該做的處置完全不同（不變式 2）。
    tree.replaceChildren(element("div", {
      class: "notice error",
      "data-testid": "load-error",
    }, [
      element("strong", { text: "讀不到 config 清單。" }),
      element("pre", { text: loadError }),
    ]));
    return;
  }

  const visible = rows.filter(matches);
  tree.replaceChildren();
  if (searchError !== null) {
    // 重新搜尋（F33）：同一個字、同一個範圍再問一次，不清搜尋框。
    const retry = element("button", { type: "button", "data-testid": "search-retry", text: "重新搜尋" });
    retry.addEventListener("click", () => runSearch());
    tree.appendChild(element("div", { class: "notice error", "data-testid": "search-error" }, [
      element("strong", { text: "搜尋失敗。" }),
      element("pre", { text: searchError }),
      retry,
    ]));
    return;
  }

  // 空狀態（#50）：每一種「這裡沒有東西」都說出是哪一種、接下來可以做什麼——一片空白會被讀成壞了，
  // 而「還沒納管」與「搜尋沒找到」該做的事完全不同。
  workspaceEmpty.textContent = rows.length
    ? "從左側雙擊一份 config（或選取後按 Enter），這裡會顯示它的參數欄位表。"
    : "納管第一份 config 之後，這裡會顯示它的參數欄位表。";
  if (!rows.length) {
    // 什麼都還沒納管是合法狀態，不是錯誤。
    tree.appendChild(element("p", {
      class: "notice",
      "data-testid": "empty-state",
      text: "還沒有納管任何 config。" + (document.body.dataset.readonly === "true"
        ? "" : "下一步：按上方的「納管」，挑一份檔案交給系統管理。"),
    }));
    return;
  }
  if (!visible.length) {
    const query = search.value.trim();
    const scope = searchScope.value;
    tree.appendChild(element("p", {
      class: "notice",
      "data-testid": "no-matches",
      text: `沒有符合的項目：在「${scope}」範圍內找不到含「${query}」的 config。`
        + (scope === "全部"
          ? "下一步：換個關鍵字，或清空搜尋框看全部。"
          : "下一步：換個關鍵字，或把搜尋範圍改成「全部」。"),
    }));
    return;
  }

  if (treeLayout.value === "host") {
    // 依主機：第一層 hostname（依名字排序）、第二層群組。主機節點的色點彙總其下全部 config。
    for (const [hostname, rows_] of byHost(visible)) {
      const worst = worstState(rows_);
      tree.appendChild(element("section", {
        class: "host", "data-testid": `tree-host-${hostname}`,
      }, [
        element("h2", {}, [statusDot(worst), element("span", { text: hostname })]),
        ...byGroup(rows_).map(([group, items]) => groupNode(group, items)),
      ]));
    }
    return;
  }
  for (const [group, items] of byGroup(visible)) tree.appendChild(groupNode(group, items));
}

export const treeLayout = document.querySelector("[data-testid='tree-layout']");

export function byHost(items) {
  const buckets = new Map();
  for (const row of items) {
    if (!buckets.has(row.hostname)) buckets.set(row.hostname, []);
    buckets.get(row.hostname).push(row);
  }
  return [...buckets.entries()].sort(([a], [b]) => a.localeCompare(b));
}

export function statusDot(worst) {
  return element("span", {
    class: `dot dot-${worst}`, "data-testid": "group-status-dot", "data-state": worst,
    title: worst === "error" ? "有一筆判不出狀態" : STATE_TEXT[worst] || worst,
  });
}

export function groupNode(group, items) {
  return element("section", {
    class: "group",
    "data-testid": `tree-group-${group}`,
  }, [
    element("h2", {}, [statusDot(worstState(items)), element("span", { text: group === UNGROUPED ? "未分群" : group })]),
    element("ul", {}, items.map(rowNode)),
  ]);
}

// 父節點彙總子節點最嚴重的狀態（§7.4.1）：偏離 > 未部署 > 一致；判不出狀態的（#214）排最前——
// 那一筆連比都比不了，比偏離更需要人先看。
export const STATE_SEVERITY = ["error", "drift", "missing", "in_sync"];

export function worstState(items) {
  const states = items.map((row) => (row.error ? "error" : row.state));
  return STATE_SEVERITY.find((state) => states.includes(state)) || "in_sync";
}

// 後端把清單檔／白名單設定執行期讀不了包成 {detail:{message,file}}，指名壞掉的檔與下一步
// （不變式 2，routes.py 的 _preflight_error）。這幾個 GET 載入器原樣取出該訊息，取不到才退回
// HTTP 狀態——否則使用者只看到籠統的「500 Internal Server Error」，後端特地結構化的可行動訊息
// 被丟掉，與同檔其餘 handler（identity／whitelist／browse／onboard 都呈現 detail）不一致（#252）。
export async function loadErrorText(response) {
  const payload = await response.json().catch(() => null);
  const detail = payload && payload.detail;
  if (detail) return detailText(detail);
  // 回應不是後端寫的那種形狀（中間有代理、或後端崩了）：至少說出狀態碼與去哪裡看原因。
  return `後端回了 ${response.status} ${response.statusText}，沒有附原因。`
    + "下一步：查看後端服務的紀錄（log）找出這個請求為什麼失敗。";
}

// `deadline`：「檢查差異」傳進它那個動作的期限（讀清單與重跑搜尋共用，F34）；其他呼叫者不傳，這次
// 載入自己起一個 15 秒的。
export async function load(deadline = null) {
  const generation = ++loadGeneration;
  const own = deadline ? null : startDeadline();
  try {
    const data = await readJson(`${API_BASE}/api/configs`, deadline || own);
    if (generation !== loadGeneration) return;  // 有更新的載入開始了，這次過時、丟棄
    rows = data;
    loadError = null;
    statusNotUpdatedEl.hidden = true;
    // 「未還原」標示（#345）跟著清單一起重讀：開頁、重新整理、檢查差異、寫入後、退出再進入都經這裡。
    await loadLeftBehind(deadline || own);
    if (generation !== loadGeneration) return;
    // 搜尋框有字就重跑搜尋（F27）：清單是現在的，命中（或失敗的原因）也要是現在的——否則
    // 「檢查完成」和停機時留下的「搜尋失敗」紅框並排。重跑仍失敗時紅框留著、摘要另說。
    // 重跑沿用同一個期限：從按下「檢查差異」起合計 15 秒，不是各 15 秒（F34）。
    if (search.value.trim()) await runSearch(deadline || own);
    else render();
    // 重跑搜尋的那段等待裡可能已經有更新的載入開始了：摘要、開著的區塊、草稿數交給那一次寫，
    // 這一次的收尾不蓋掉它（F34）。
    if (generation !== loadGeneration) return;
    refreshScanSummary();
    syncOpenPanels();  // 開著的區塊跟著清單走（第 6 批 F31）
    loadDrafts();
  } catch (error) {
    // 大聲失敗（不變式 2）：說出是什麼壞了，不是顯示一份空清單假裝沒事——空清單與「讀不到
    // 清單」看起來一樣，而那兩件事該做的處置完全不同。旗標讓錯誤黏住，經 render 重畫（見上）。
    if (generation !== loadGeneration) return;  // 過時的失敗不覆寫新結果
    loadError = failureText("讀取 config 清單", error);
    render();
    refreshScanSummary();
  } finally {
    if (own) own.finish();  // 只收自己起的計時；共用的期限由起它的動作收
  }
}
// 手動「檢查差異」：重掃並說出結果。與一般的載入分開——開頁面時的自動載入不需要這一行回饋。
export const rescanButton = document.querySelector("[data-testid='rescan']");
export const scanStatus = document.querySelector("[data-testid='scan-status']");
export const SCAN_PARTS = [["error", "份判不出狀態"], ["drift", "份偏離"], ["missing", "份未部署"]];

export function setScanStatus(state, text) {
  scanStatus.dataset.state = state;
  scanStatus.textContent = text;
  scanStatus.hidden = false;
}

// 摘要說的是「清單現在的樣子」，所以它跟著清單走：每次清單載入完（成功或失敗）都重寫一次。
// 載入清單本來就是一次真的比對（後端每個請求都重掃），所以時間與份數是實在的。只在按「檢查
// 差異」時寫一次的話，之後的動作（寫出修復、進版、處置偏離、解除納管…）把樹更新了、摘要卻
// 停在上一次——畫面上同時寫著「一致」與「1 份未部署」（人工驗證 U30）。
// 還沒按過「檢查差異」就不出現：開頁面的自動載入不需要這一行。
export function refreshScanSummary() {
  if (scanStatus.hidden) return;
  if (loadError !== null) {
    setScanStatus("failed", "檢查失敗：讀不到清單，原因見下方。修正後再按一次「檢查差異」。");
    return;
  }
  if (searchError !== null) {
    // 清單讀到了、重跑的搜尋卻失敗（F27）：說清楚哪一半成功、哪一半沒有，不寫成「檢查完成」。
    const when = new Date().toLocaleTimeString("zh-TW", { hour12: false });
    setScanStatus("failed",
      `${when} 清單已重新讀到，共 ${rows.length} 份，但搜尋失敗（${searchError}）。修正後再按一次「檢查差異」。`);
    return;
  }
  const counts = {};
  for (const row of rows) {
    const key = row.error ? "error" : row.state;
    counts[key] = (counts[key] || 0) + 1;
  }
  const found = SCAN_PARTS.filter(([key]) => counts[key]).map(([key, text]) => `${counts[key]} ${text}`);
  const at = new Date().toLocaleTimeString("zh-TW", { hour12: false });
  scanStatus.dataset.at = at;
  setScanStatus("done", `${at} 檢查完成，共 ${rows.length} 份：${found.length ? found.join("、") : "全部一致"}。`);
}

// 搜尋失敗（F26）：摘要列不能和紅框並排寫著「檢查完成」——那一次的結果已經無法確認是不是現況。
// 原因原樣帶進來（後端或瀏覽器給的），不寫死「後端沒有回應」。
export function markSummaryUnconfirmed() {
  if (scanStatus.hidden || scanStatus.dataset.state !== "done") return;
  setScanStatus("failed",
    `${scanStatus.dataset.at} 的檢查結果尚未重新確認：搜尋失敗（${searchError}）。修正後再按一次「檢查差異」。`);
}

// 一次「檢查差異」一個期限（F34）：讀清單與搜尋框有字時的重跑搜尋合計 15 秒。期限到了 load() 照讀不到
// 清單處理（黏性的讀不到、摘要檢查失敗），這裡結束等待——按鈕可再按，忙碌標記拿掉後「退出」依 F3 的
// 規則自己恢復（那條規則不改：寫入進行中照舊不能退出）。
export async function rescan() {
  rescanButton.disabled = true;
  setScanStatus("running", "檢查中…");  // 從這裡開始摘要是看得見的；結果由 load() 寫上去
  const deadline = startDeadline();
  try {
    await load(deadline);
  } finally {
    deadline.finish();
    rescanButton.disabled = false;
  }
}

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireTree() {
  treeLayout.addEventListener("change", render);

  rescanButton.addEventListener("click", () => whileBusy(rescanButton, "檢查中…", rescan));
}
