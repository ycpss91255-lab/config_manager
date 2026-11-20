// 右側工作區（#36）：每份 config 一個槽、選取與關閉、開著的區塊跟著清單走。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, Refused, apiFetch, failureText } from "./api.js";
import { element } from "./dom.js";
import { STATE_TEXT, loadErrorText, rows, tree } from "./tree.js";
import { panelNode } from "./params.js";
import { toggleCollapse } from "./list-edit.js";
import { driftBanner, errorBanner, missingBanner } from "./drift.js";
import { confirmAction, confirmDialog } from "./dialogs.js";
import { syncLeftBehindBanner } from "./promote.js";
import { listView } from "./identity.js";

// ── W3 參數欄位表（#20）──────────────────────────────────────────────────────
// 這不是線上 YAML 編輯器（ADR-00000013、設計 §7.5）：一列一個參數，依型別給控制項——bool 核取方塊、
// int 整數步進、double 允許小數且顯示一定帶小數點、enum 下拉、string 文字框（引號由系統處理）。
// 型別與值都來自 GET /api/configs/{uid}（來源複本解析＋推斷），前端不猜。單擊左側樹節點開啟、一次
// 一份（#20 的 D1；雙擊與多開是 #35／#36）。型別欄兩種角色都是純文字（人工指定是 v0.7.0）。
// list 只列元素、唯讀（新增／移除／排序是 #46）；巢狀物件是可折疊區塊，內部葉照常可編輯（D3）。
// enum 的選項來自 schema（#40）：渲染器已支援 `options`，後端目前不會送——刻意留空，#40 接上。
export const workspace = document.querySelector("[data-testid='workspace']");
// 介面上的型別名稱依設計 §7.5.1（double／object），API 的名稱（float／dict）留在 data-type。
export const TYPE_LABEL = {
  bool: "bool", int: "int", float: "double", string: "string", enum: "enum",
  dict: "object", list: "list", null: "null", unknown: "unknown",
};
// 每次開啟遞增；晚到的舊回應不覆蓋新開的那份（同 load／browse 的世代守門，#252）。
export let panelGeneration = 0;

// 選取記在這裡而不是只記在 DOM 上（樹重畫時 DOM 整棵換掉）。
export let selectedUid = null;

// 別的模組要改這個狀態時走這裡：匯入的名稱是唯讀的（#359）。
export function setSelectedUid(value) {
  selectedUid = value;
}


export function treeItems() {
  return [...tree.querySelectorAll("li[data-uid]")];
}

// 選取一個節點（`uid` 不在樹上就是沒有選取）。Tab 只停在一個節點上——選取的那個，沒有選取就是
// 第一個——節點之間用方向鍵走，不必 Tab 過整棵樹。`focus`：把鍵盤焦點也移過去。
export function selectItem(uid, focus) {
  const items = treeItems();
  const chosen = items.find((node) => node.dataset.uid === uid) || null;
  for (const node of items) {
    if (node === chosen) node.setAttribute("aria-selected", "true");
    else node.removeAttribute("aria-selected");
    node.tabIndex = node === (chosen || items[0]) ? 0 : -1;
  }
  const target = chosen || items[0];
  if (focus && target) {
    target.focus();
    target.scrollIntoView({ block: "nearest" });
  }
}

// ── 右側工作區的堆疊（#36）：每份 config 一個槽（data-uid），槽裡是欄位表／歷史／差異檢視之一，
// 新開的在最上面；各槽各自儲存／捨棄變更。返回（從歷史／差異回欄位表）只換那一槽，其餘不動。
export const workspaceEmpty = document.querySelector("[data-testid='workspace-empty']");

export function slotFor(uid) {
  return [...workspace.querySelectorAll("[data-uid]")].find((node) => node.dataset.uid === uid) || null;
}

export function mountView(uid, view, kind) {
  view.dataset.uid = uid;
  view.dataset.view = kind;
  const existing = slotFor(uid);
  if (existing) existing.replaceWith(view);
  else workspace.prepend(view);
  refreshWorkspaceEmpty();
}

// 收合一份 config 的區塊（按 ×、或在樹上／區塊裡按 Esc）。裡面有還沒儲存的改動就先問——關掉就
// 沒了，不悄悄丟（不變式 2；#50 的破壞性操作二次確認）。已儲存的草稿在後端，不受影響。
export async function requestClose(uid) {
  const slot = slotFor(uid);
  if (!slot) return;
  if (slot.querySelector("[data-dirty='true']")) {
    const row = rows.find((item) => item.uid === uid);
    const ok = await confirmAction(
      "關閉這個區塊？",
      `「${row ? row.name : uid}」有還沒儲存的改動，關閉後這些改動會丟掉；已儲存的草稿不受影響。`,
      "關閉並丟掉改動",
    );
    if (!ok) return;
  }
  const hadFocus = slot.contains(document.activeElement);
  closeSlot(uid);
  // 焦點原本在被收掉的區塊裡：交還給樹上的那個節點，鍵盤才接得下去。
  if (hadFocus) {
    selectedUid = uid;
    selectItem(uid, true);
  }
}

export function saveCurrentPanel(focused) {
  const open = [...workspace.querySelectorAll("[data-uid][data-view='panel']")];
  const fromTree = tree.contains(document.activeElement) && selectedUid ? slotFor(selectedUid) : null;
  const slot = focused || fromTree || (open.length === 1 ? open[0] : null);
  const save = slot ? slot.querySelector("[data-testid='panel-save']") : null;
  if (!save || save.hidden) return;
  const note = slot.querySelector("[data-testid='panel-save-note']");
  if (!save.disabled) {
    note.hidden = true;
    save.click();
    return;
  }
  // 按了卻什麼都沒發生最讓人困惑：說出為什麼沒存（沒有改動，或有欄位沒通過驗證）。
  note.textContent = slot.querySelector("[data-valid='false']")
    ? "有欄位沒通過驗證，還不能儲存。下一步：依那一列的說明修正後再存。"
    : "沒有還沒儲存的改動。";
  note.hidden = false;
}

export function closeSlot(uid) {
  const existing = slotFor(uid);
  if (existing) existing.remove();
  refreshWorkspaceEmpty();
}

export function openUids() {
  return [...workspace.querySelectorAll("[data-uid][data-view='panel']")].map((node) => node.dataset.uid);
}

// ── 開著的區塊跟著清單走（第 6 批 F31）────────────────────────────────────────
// 區塊標頭的狀態與橫幅原本只在開區塊那一刻依清單列算一次；「檢查差異」（或任何讓清單重載的動作）
// 只重畫左側樹，清單列變了區塊卻留著舊狀態、沒有原因。清單每次重載成功後，對每個開著的區塊重算
// 標籤（與那一列逐字相同）、掛上或拆掉判不出／未部署／偏離橫幅。只動標頭文字與橫幅——欄位表不
// 重畫，還沒儲存的輸入、草稿、展開狀態都留著。
export const panelDetails = new Map();  // uid → 開區塊時拿到的單筆內容（未部署／偏離橫幅要 target 等欄位）

export function syncBanner(panel, selector, wanted, build, update) {
  const existing = panel.querySelector(selector);
  if (!wanted) { if (existing) existing.remove(); return; }
  if (existing) { if (update) update(existing); return; }
  const banner = build();
  if (banner) panel.insertBefore(banner, panel.children[1] || null);  // 緊接在標頭下
}

export function syncOpenPanels() {
  for (const uid of openUids()) {
    const panel = workspace.querySelector(`[data-testid='panel-${uid}']`);
    const row = rows.find((item) => item.uid === uid);
    if (!panel || !row) continue;
    const detail = panelDetails.get(uid);
    const label = panel.querySelector(`[data-testid='panel-status-${uid}']`);
    if (label) label.textContent = row.error ? "錯誤" : STATE_TEXT[row.state] || row.state;
    syncBanner(panel, "[data-testid='error-banner']", Boolean(row.error),
      () => errorBanner(row.error),
      (banner) => { banner.querySelector("pre").textContent = row.error; });
    syncBanner(panel, "[data-testid='missing-banner']", !row.error && row.state === "missing",
      () => (detail ? missingBanner(detail) : null));
    syncBanner(panel, "[data-testid='drift-banner']", !row.error && row.state === "drift",
      () => (detail ? driftBanner(detail, true) : null));
    syncLeftBehindBanner(panel, detail, row);  // #345：最後掛，才會在偏離橫幅之上
  }
}

export function refreshWorkspaceEmpty() {
  workspaceEmpty.hidden = workspace.querySelector("[data-uid]") !== null;
}

export function mountNotice(node) {
  const previous = workspace.querySelector(`[data-testid='${node.dataset.testid}']`);
  if (previous) previous.replaceWith(node);
  else workspace.prepend(node);
}

export const panelGenerations = new Map();  // 每份 config 自己的世代（晚到的舊回應不覆蓋新開的）
// 工作區的世代：回身分輸入頁（退出、逾時）時加一。上一個身分還在路上的區塊內容回來時不放回工作區（F3）。
export let workspaceEpoch = 0;

// 別的模組要改這個狀態時走這裡：匯入的名稱是唯讀的（#359）。
export function setWorkspaceEpoch(value) {
  workspaceEpoch = value;
}


export async function openPanel(uid, notice) {
  const generation = (panelGenerations.get(uid) || 0) + 1;
  panelGenerations.set(uid, generation);
  const epoch = workspaceEpoch;
  const stale = () => epoch !== workspaceEpoch || generation !== panelGenerations.get(uid);
  if (!slotFor(uid)) {
    mountView(uid, element("p", {
      class: "notice", "data-testid": "panel-loading", text: "載入中…",
    }), "loading");
  }
  try {
    const response = await apiFetch(`${API_BASE}/api/configs/${encodeURIComponent(uid)}`);
    if (!response.ok) throw new Refused(await loadErrorText(response));
    const detail = await response.json();
    if (stale()) return;
    panelDetails.set(uid, detail);
    const panel = panelNode(detail);
    if (notice) panel.insertBefore(notice, panel.children[1] || null);  // 上一個動作的結果放在標頭下
    // 重畫一個已經開著的區塊（進版、捨棄、改屬性之後）：位置在換上去之前才量，換完還原。
    const previous = slotFor(uid);
    const position = previous && previous.dataset.view === "panel" ? panelPosition(previous) : null;
    mountView(uid, panel, "panel");
    if (position) restorePanelPosition(panel, position);
  } catch (error) {
    if (stale()) return;
    // 大聲失敗（不變式 2）：說出讀不到，不留一個空表假裝這份 config 沒有參數。
    mountView(uid, element("div", {
      class: "notice error", "data-testid": `panel-error-${uid}`,
    }, [
      element("strong", { text: "讀不到這份 config 的內容。" }),
      element("pre", { text: failureText("讀取這份 config 的內容", error) }),
    ]));
  }
}

// 工作區上方的東西變高或變矮時（結果橫幅出現／消失、唯讀橫幅、閒置提示、工具列換行），下面的內容
// 會整個被推動——人正在看的那一列就從眼前跑掉。這裡在畫出來之前把捲動位置補回同樣的量，畫面上的
// 內容不動。在頁面頂端時不補：那時橫幅本來就該被看見、內容往下讓位。
export let workspaceTop = null;

export function keepWorkspaceInPlace() {
  const now = workspace.getBoundingClientRect().top + window.scrollY;
  if (workspaceTop !== null && window.scrollY > 0 && !listView.hidden) {
    window.scrollBy(0, now - workspaceTop);
  }
  workspaceTop = now;
}

// 操作後的位置保持（#50）：區塊因為進版、捨棄、改屬性而整個重畫時，人剛才的位置要留著——折疊了
// 哪些巢狀參數、整個區塊是不是收著、頁面捲到哪、鍵盤焦點在哪一列。不留的話每做一個動作，畫面
// 就跳回區塊開頭、全部展開，得重新找剛才在看的那一列。
export function panelPosition(panel) {
  const active = panel.contains(document.activeElement) ? document.activeElement : null;
  const row = active ? active.closest("li[data-name]") : null;
  return {
    collapsed: [...panel.querySelectorAll("li[data-container='true'][data-collapsed='true']")]
      .map((node) => node.dataset.name),
    folded: panel.dataset.collapsed === "true",
    scrollY: window.scrollY,
    focusRow: row ? row.dataset.name : null,
    focusControl: active && !row ? active.dataset.testid || null : null,
  };
}

export function restorePanelPosition(panel, position) {
  const list = panel.querySelector("[data-testid='param-table']");
  const rowNamed = (name) => (list
    ? [...list.querySelectorAll("li[data-name]")].find((node) => node.dataset.name === name)
    : null);
  for (const name of position.collapsed) {
    const container = rowNamed(name);
    // 那個參數可能已經不在了（退版、改型別）：沒有就略過，其餘照樣還原。
    if (container && container.dataset.container === "true" && container.dataset.collapsed !== "true") {
      toggleCollapse(list, container);
    }
  }
  if (position.folded) panel.dataset.collapsed = "true";
  window.scrollTo(window.scrollX, position.scrollY);
  const row = position.focusRow ? rowNamed(position.focusRow) : null;
  const control = row
    ? row.querySelector("input, select, textarea, button")
    : position.focusControl && panel.querySelector(`[data-testid='${position.focusControl}']`);
  if (control && !control.hidden) control.focus({ preventScroll: true });
}

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireWorkspace() {
  // 單擊＝選取（高亮），雙擊＝展開到右側工作區堆疊（§7.4.1、#35）。
  tree.addEventListener("click", (event) => {
    const item = event.target.closest("li[data-uid]");
    if (!item) return;
    selectedUid = item.dataset.uid;
    selectItem(selectedUid, false);
  });
  tree.addEventListener("dblclick", (event) => {
    const item = event.target.closest("li[data-uid]");
    if (item) openPanel(item.dataset.uid);
  });

  // 鍵盤操作（#50、§7.10）：↑／↓ 在節點之間移動（Home／End 到頭尾）、Enter 展開到工作區、Esc 收合
  // 那一份的區塊。跨群組照畫面上的順序走。
  tree.addEventListener("keydown", (event) => {
    const item = event.target.closest("li[data-uid]");
    if (!item) return;
    const items = treeItems();
    const at = items.indexOf(item);
    const moves = { ArrowDown: at + 1, ArrowUp: at - 1, Home: 0, End: items.length - 1 };
    if (event.key in moves) {
      event.preventDefault();
      const next = items[Math.min(items.length - 1, Math.max(0, moves[event.key]))];
      selectedUid = next.dataset.uid;
      selectItem(selectedUid, true);
    } else if (event.key === "Enter") {
      event.preventDefault();
      selectedUid = item.dataset.uid;
      selectItem(selectedUid, false);
      openPanel(selectedUid);
    } else if (event.key === "Escape") {
      event.preventDefault();
      requestClose(item.dataset.uid);
    }
  });

  // Esc 在區塊裡也是收合那個區塊——但正在輸入框裡打字時不是（那裡的 Esc 是瀏覽器自己的事）。
  // Ctrl+S／⌘S 儲存「目前區塊」：焦點所在的那個區塊；焦點在樹上就是選取的那一份；都不是而只開著
  // 一個區塊，就是它。主畫面上一律不讓瀏覽器跳出「另存網頁」。
  document.addEventListener("keydown", (event) => {
    if (listView.hidden || confirmDialog.open) return;
    const active = document.activeElement;
    const slot = active && active.closest ? active.closest("[data-testid='workspace'] [data-uid]") : null;
    if (event.key === "Escape" && slot && !active.matches("input, select, textarea")) {
      event.preventDefault();
      requestClose(slot.dataset.uid);
      return;
    }
    if (!(event.ctrlKey || event.metaKey) || event.key.toLowerCase() !== "s") return;
    event.preventDefault();
    saveCurrentPanel(slot);
  });

  if (window.ResizeObserver) {
    const above = new ResizeObserver(keepWorkspaceInPlace);
    for (const node of document.querySelectorAll("header, main > .banner, main > .scan-status")) {
      above.observe(node);
    }
  }
}
