// 草稿：哪些 config 有草稿、草稿是誰的，以及清單上的草稿標示。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, Refused, apiFetch, failureText } from "./api.js";
import { element } from "./dom.js";
import { loadErrorText, render } from "./tree.js";
import { mountNotice } from "./workspace.js";
import { discardAllButton, promoteButton } from "./promote.js";

// 目前有草稿的 uid（#21）。掛在 app 上的階段是唯一來源：每次載入清單一併重讀，儲存成功時以回應更新。
export let draftUids = new Set();

// draftUids 是唯一來源：每次它變（載入、儲存、進版、捨棄）都從這裡重畫樹與工具列。
export function setDrafts(uids) {
  draftUids = new Set(uids);
  render();
  promoteButton.textContent = `進版 (${draftUids.size})`;
  promoteButton.disabled = draftUids.size === 0;
  discardAllButton.disabled = draftUids.size === 0;
}

// 每份草稿是誰存的（ADR-00000032）：uid → {sha, saved_by, touched_by}。後端回 GET／POST／DELETE
// /api/drafts 的同一種形狀，這裡一起收；草稿點的 title、進版前的確認、退出確認都從這裡拿。
export let draftDetails = new Map();

// 別的模組要改這個狀態時走這裡：匯入的名稱是唯讀的（#359）。
export function setDraftDetails(value) {
  draftDetails = value;
}


export function applyDraftsView(payload) {
  draftDetails = new Map((payload.drafts || []).map((draft) => [draft.uid, draft]));
  setDrafts((payload.drafts || []).map((draft) => draft.uid));
}

// 一個參與者在畫面上的稱呼：自己＝「你」；同名同 email 但另一個瀏覽器＝「姓名（另一個瀏覽器身分）」
// ——系統沒有認證，只能說是另一個瀏覽器身分，不說是另一個人；其餘用姓名。票不會出現（後端不回）。
export function ownerLabel(owner) {
  if (!owner) return "存的人不明";
  if (owner.mine) return "你";
  return owner.another_browser ? `${owner.name}（另一個瀏覽器身分）` : owner.name;
}

// 區塊標頭的草稿指示文字：寫最後儲存者（ADR-00000032）；開區塊時與儲存成功後都用這一個。
export function draftMarkText(detail) {
  return detail.draft_saved_by ? `● 草稿（${ownerLabel(detail.draft_saved_by)}）` : "● 草稿";
}

// 逐人列參與份數（同一份多人參與會重複計入），另給不重複的草稿總數。
export function participantsText(byOwner, distinct) {
  const parts = byOwner.map((who) => `${ownerLabel(who)}參與 ${who.count} 份`);
  return `${parts.join("、")}（同一份多人參與會重複計入）；不重複的草稿共 ${distinct} 份`;
}

// 目前草稿裡每個參與者各參與幾份（照首次出現順序）；`others`＝不是自己的那幾位。
export function draftParticipants() {
  const counts = new Map();
  for (const draft of draftDetails.values()) {
    for (const who of draft.touched_by || []) {
      const key = `${who.mine ? "me" : who.name}|${who.email}|${who.another_browser}`;
      const seen = counts.get(key) || { ...who, count: 0 };
      seen.count += 1;
      counts.set(key, seen);
    }
  }
  const all = [...counts.values()];
  return { all, others: all.filter((who) => !who.mine), distinct: draftDetails.size };
}

export async function loadDrafts() {
  try {
    const response = await apiFetch(`${API_BASE}/api/drafts`);
    if (!response.ok) throw new Refused(await loadErrorText(response));
    const payload = await response.json();
    applyDraftsView(payload);
  } catch (error) {
    // 讀不到草稿清單不該悄悄把標記藏掉（不變式 2）：在工作區說出來，樹照常顯示。
    mountNotice(element("div", {
      class: "notice error", "data-testid": "drafts-error",
    }, [
      element("strong", { text: "讀不到草稿清單，樹上的草稿標記可能不準。" }),
      element("pre", { text: failureText("讀取草稿清單", error) }),
    ]));
  }
}
