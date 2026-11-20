// W10 設定：新納管預設主機名稱（#385）。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, Refused, apiFetch, editFetch, failureText } from "./api.js";
import { element } from "./dom.js";
import { loadErrorText } from "./tree.js";
import { currentIdentity, header, hideAllPageViews, showList } from "./identity.js";

// ── W10 設定：新納管預設主機名稱（#385）──────────────────────────────────────────
// GET /api/host-name 查看（不需要編輯權）；PUT 確認或修改（限開發者、需要編輯權，後端也擋）。
// 候選與預填都只是預填，**不自動保存**，也不修改既有 config 的 hostname。來源不一致時兩個都列、
// 不預填，由開發者確認。
export const settingsView = document.querySelector("[data-testid='settings']");
export const settingsButton = document.querySelector("[data-testid='open-settings']");
export const hostNameEl = (name) => settingsView.querySelector(`[data-testid='host-name-${name}']`);
export const SOURCE_TEXT = { candidate: "本次啟動取得的候選", entries: "既有條目都使用" };

export function showSettings() {
  hideAllPageViews();
  header.hidden = false;
  settingsView.hidden = false;
  hostNameEl("error").hidden = true;
  hostNameEl("done").hidden = true;
  loadHostName();
}

export async function loadHostName() {
  try {
    const response = await apiFetch(`${API_BASE}/api/host-name`);
    if (!response.ok) throw new Refused(await loadErrorText(response));
    renderHostName(await response.json());
  } catch (error) {
    hostNameEl("error").textContent = failureText("讀取新納管預設主機名稱", error);
    hostNameEl("error").hidden = false;
  }
}

export function renderHostName(view) {
  hostNameEl("saved").textContent = view.saved === null
    ? "還沒保存新納管預設主機名稱：納管新 config 之前，要先在這裡確認或輸入這台機器的名稱。"
    : `保存的納管預設名稱：${view.saved}`;
  const candidate = hostNameEl("candidate");
  candidate.hidden = view.candidate === null;
  candidate.textContent = view.candidate === null
    ? ""
    : `本次啟動取得的候選：${view.candidate}（不保證是即時的主機名稱）`;
  const unconfirmed = hostNameEl("unconfirmed");
  unconfirmed.hidden = view.unconfirmed === null;
  unconfirmed.textContent = view.unconfirmed === null
    ? ""
    : `目前主機名稱尚未確認：${view.unconfirmed}`;
  const sources = hostNameEl("sources");
  sources.hidden = view.sources.length < 2;
  sources.replaceChildren(...view.sources.map((source) => element("li", {
    "data-testid": `host-name-source-${source.kind}`,
    text: `${SOURCE_TEXT[source.kind]}：${source.hostname}`,
  })));
  if (view.sources.length >= 2 && view.prefill === null) {
    sources.appendChild(element("li", {
      text: "名稱來源不一致，不會自動選一個——請確認要保存哪一個，或直接輸入。",
    }));
  }
  const developer = Boolean(currentIdentity && currentIdentity.role === "developer");
  const input = hostNameEl("input");
  input.value = view.prefill ?? view.saved ?? "";
  input.disabled = !developer;
  hostNameEl("save").hidden = !developer;
  hostNameEl("readonly").hidden = developer;
}

export async function saveHostName() {
  const button = hostNameEl("save");
  hostNameEl("error").hidden = true;
  hostNameEl("done").hidden = true;
  button.disabled = true;
  try {
    const response = await editFetch(`${API_BASE}/api/host-name`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ hostname: hostNameEl("input").value.trim() }),
    });
    if (!response.ok) throw new Refused(await loadErrorText(response));
    const view = await response.json();
    renderHostName(view);
    hostNameEl("done").textContent =
      `已保存新納管預設主機名稱：${view.saved}。已納管項目的 hostname 沒有改。`;
    hostNameEl("done").hidden = false;
  } catch (error) {
    hostNameEl("error").textContent = failureText("保存新納管預設主機名稱", error);
    hostNameEl("error").hidden = false;
  } finally {
    button.disabled = false;
  }
}

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireSettings() {
  settingsButton.addEventListener("click", showSettings);
  // 納管確認頁的「到設定」（#385）：缺少名稱時從那裡直接過去。
  document.querySelector("[data-testid='onboard-hostname-settings']")
    .addEventListener("click", showSettings);
  hostNameEl("save").addEventListener("click", saveHostName);
  settingsView.querySelector("[data-testid='settings-back']").addEventListener("click", () => {
    if (currentIdentity) showList(currentIdentity);
    else location.reload();
  });
}
