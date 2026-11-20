// W8 納管確認（#14）。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, apiFetch, editFetch, failureText } from "./api.js";
import { element } from "./dom.js";
import { setSelectedUid } from "./workspace.js";
import { whileBusy } from "./dialogs.js";
import { clearPromoteBanners, promoteDoneEl } from "./promote.js";
import { currentIdentity, hideAllPageViews, showList } from "./identity.js";
import { selectedSourcePath, showBrowse } from "./browse.js";

export let currentAmbiguities = [];
// 每次偵測遞增；回應回來時若世代已變（使用者又換了格式、發了新偵測），丟棄這個過時回應
// ——否則晚到的舊回應會覆寫成與當前格式不符的型別/歧義，甚至以較少的歧義繞過確認閘門（#14 審查）。
export let inspectGeneration = 0;

export const onboardStartEl = document.querySelector("[data-testid='onboard-start']");
export const confirmView = document.querySelector("[data-testid='onboard-confirm']");
export const onboardPathEl = document.querySelector("[data-testid='onboard-path']");
export const onboardFormatEl = document.querySelector("[data-testid='onboard-format']");
export const onboardHostnameEl = document.querySelector("[data-testid='onboard-hostname']");
export const onboardHostnameSettingsEl = document.querySelector("[data-testid='onboard-hostname-settings']");
// 偵測回報還沒保存新納管預設主機名稱（#385）：「確認寫入」一律停用，後端也會擋。
export let onboardHostnameMissing = false;
export const onboardPermsEl = document.querySelector("[data-testid='onboard-permissions']");
export const onboardSummaryEl = document.querySelector("[data-testid='onboard-summary']");
export const onboardTypesEl = document.querySelector("[data-testid='onboard-types']");
export const onboardAmbiguitiesEl = document.querySelector("[data-testid='onboard-ambiguities']");
export const onboardErrorEl = document.querySelector("[data-testid='onboard-error']");
export const onboardSubmitEl = document.querySelector("[data-testid='onboard-submit']");

// 副檔名只當**建議**（不變式 8：副檔名不是持續權威，使用者可改、確認後才明寫進清單檔）。
export const FORMAT_BY_EXT = { yaml: "yaml", yml: "yaml", json: "json", toml: "toml", ini: "ini" };
export const TYPE_TEXT = {
  bool: "布林", int: "整數", float: "浮點數", string: "字串",
  dict: "物件", list: "陣列", null: "null", unknown: "未知",
};

export function guessFormat(path) {
  const ext = path.split(".").pop().toLowerCase();
  return FORMAT_BY_EXT[ext] || "raw";
}

export function showConfirm() {
  hideAllPageViews();
  confirmView.hidden = false;
}

export function openConfirm(path) {
  onboardPathEl.textContent = path;
  onboardFormatEl.value = guessFormat(path);
  showConfirm();
  runInspect();
}

export function clearInspectResults() {
  // 每次偵測前清掉上一檔的結果。少了它，偵測失敗時 W8 會殘留前一檔的型別／歧義／hostname，
  // 而殘留的歧義勾選框仍掛著 change→refreshSubmitState——勾滿就把「確認寫入」重新解鎖，於是
  // 對一個偵測失敗的檔案送出納管、還帶著另一檔的歧義確認，繞過 AC4 的確認閘門。
  onboardHostnameEl.textContent = "";
  onboardHostnameMissing = false;
  onboardHostnameSettingsEl.hidden = true;
  onboardPermsEl.textContent = "";
  onboardSummaryEl.textContent = "";
  onboardTypesEl.replaceChildren();
  onboardAmbiguitiesEl.replaceChildren();
  currentAmbiguities = [];
}

export async function runInspect() {
  const generation = ++inspectGeneration;
  onboardErrorEl.hidden = true;
  onboardSubmitEl.disabled = true;
  clearInspectResults();
  try {
    const response = await apiFetch(`${API_BASE}/api/inspect`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        source_path: onboardPathEl.textContent,
        format: onboardFormatEl.value,
      }),
    });
    const payload = await response.json();
    if (generation !== inspectGeneration) return;  // 有更新的偵測開始了，這個回應過時、丟棄
    if (!response.ok) {
      renderOnboardError(payload.detail);
      return;
    }
    renderInspect(payload);
  } catch (error) {
    if (generation !== inspectGeneration) return;
    renderOnboardError(failureText("偵測來源檔案", error));
  }
}

export function renderInspect(payload) {
  onboardHostnameMissing = payload.hostname === null;
  onboardHostnameEl.textContent = onboardHostnameMissing
    ? payload.hostname_problem
    : `將以 hostname＝${payload.hostname} 納管`;
  onboardHostnameEl.dataset.missing = String(onboardHostnameMissing);
  onboardHostnameSettingsEl.hidden = !onboardHostnameMissing;
  const permissions = payload.permissions;
  onboardPermsEl.textContent =
    `原始權限 ${permissions.owner}:${permissions.group} ${permissions.mode}`;
  // raw 不解析——說明語意，不顯示「0 個欄位」這種假訊號（#195 資安審查的同一類）。
  onboardSummaryEl.textContent = payload.format === "raw"
    ? "raw：只版控、不解析，因此沒有欄位、型別或歧義。"
    : `偵測到 ${payload.field_count} 個欄位。`;
  renderTypeTree(payload.types);
  renderAmbiguities(payload.ambiguities);
  refreshSubmitState();
}

export function renderTypeTree(types) {
  // 後端回的 types 已含容器（dict／list）與葉，鍵為前序走訪的欄位路徑（. 相接、[] 標元素）。
  // key 裡的字面點跳脫成 \.（#219），所以深度只算「未跳脫的點」與 []，葉名取最後一段後把
  // \. 還原成 .——否則含點 key 會被算錯層、或葉名被切半。
  onboardTypesEl.replaceChildren(...Object.keys(types).map((path) => {
    const type = types[path];
    const depth = (path.match(/(?<!\\)\.|\[\]/g) || []).length;
    const leaf = path.split(/(?<!\\)\./).pop().replace(/\\\./g, ".");
    const node = element("li", {
      "data-testid": `onboard-type-${path}`,
      "data-name": path,
      "data-type": type,
    }, [
      element("span", { text: `${"　".repeat(depth)}${leaf}` }),
      element("span", { class: "type", text: TYPE_TEXT[type] || type }),
    ]);
    if (type === "dict" || type === "list") node.setAttribute("data-container", "true");
    return node;
  }));
}

export function renderAmbiguities(ambiguities) {
  currentAmbiguities = ambiguities;
  onboardAmbiguitiesEl.replaceChildren(...ambiguities.map((ambiguity) => {
    const ack = element("input", {
      type: "checkbox",
      "data-testid": `onboard-ambiguity-ack-${ambiguity.line}`,
    });
    ack.addEventListener("change", refreshSubmitState);
    return element("div", {
      class: "onboard-ambiguity",
      "data-testid": `onboard-ambiguity-${ambiguity.line}`,
    }, [
      element("label", {}, [
        ack,
        element("span", { text: `第 ${ambiguity.line} 行「${ambiguity.value}」` }),
      ]),
      element("p", { class: "readings", text: ambiguity.readings.join("；") }),
    ]);
  }));
}

export function refreshSubmitState() {
  // 每個歧義都要勾了才解鎖「確認寫入」（AC4：確認後才繼續）。無歧義時 every 回 true。
  // 錯誤顯示中一律停用：偵測失敗的檔案不該送得出去，即使有殘留／勾選的框（縱深防禦，
  // 主要仍靠 clearInspectResults 不留殘留框）。
  const acks = [...onboardAmbiguitiesEl.querySelectorAll("input[type='checkbox']")];
  onboardSubmitEl.disabled = !onboardErrorEl.hidden || onboardHostnameMissing
    || !acks.every((box) => box.checked);
}

export function renderOnboardError(detail) {
  // detail 三形狀：字串（onboard）、{message,file,line}（inspect）、list（FastAPI 驗證）。
  let message;
  if (typeof detail === "string") {
    message = detail;
  } else if (Array.isArray(detail)) {
    message = detail.map((item) => item.msg || JSON.stringify(item)).join("；");
  } else if (detail && detail.message) {
    // 只顯示 message：inspect 的語法錯誤訊息本身已內嵌「（第 N 行）」，前端不再補一次（#14 審查）。
    message = detail.message;
  } else {
    message = String(detail);
  }
  onboardErrorEl.textContent = message;
  onboardErrorEl.hidden = false;
  onboardSubmitEl.disabled = true;
}

export async function submitOnboard() {
  // 歧義確認彙整進 commit 內文，供日後追溯當時怎麼確認的（onboard 原樣寫入、不解析）。
  const note = currentAmbiguities
    .map((ambiguity) => `第 ${ambiguity.line} 行「${ambiguity.value}」已確認`)
    .join("；");
  onboardErrorEl.hidden = true;
  clearPromoteBanners();  // F38：送出就收起上一個結果，不等成功
  try {
    const response = await editFetch(`${API_BASE}/api/configs`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        source_path: onboardPathEl.textContent,
        format: onboardFormatEl.value,
        ambiguity_note: note,
      }),
    });
    const payload = await response.json();
    if (!response.ok) {
      renderOnboardError(payload.detail);
      return;
    }
    // 回清單（load() 會重掃，新條目出現在左側樹）、選到剛納管的那一份、說一聲納管成了。
    setSelectedUid(payload.uid);
    showList(currentIdentity);
    promoteDoneEl.textContent = `已納管「${payload.ref}」，並記一筆變更紀錄。目標檔案：${payload.target}。`;
    promoteDoneEl.hidden = false;
  } catch (error) {
    renderOnboardError(failureText("納管", error));
  }
}

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireOnboard() {
  onboardStartEl.addEventListener("click", () => {
    if (selectedSourcePath) openConfirm(selectedSourcePath);
  });
  onboardFormatEl.addEventListener("change", runInspect);
  onboardSubmitEl.addEventListener("click", () => whileBusy(onboardSubmitEl, "納管中…", submitOnboard));
  onboardTypesEl.addEventListener("click", (event) => {
    const container = event.target.closest("li[data-container='true']");
    if (!container) return;
    // 折疊狀態記在容器自己身上（data-collapsed），再依「任一祖先折疊了嗎」重算每個節點的可見性
    // ——不用 toggle 逐一翻子節點：巢狀時「先折內層再折外層」會把已折疊的深層子節點翻回來（#14 審查）。
    container.dataset.collapsed = container.dataset.collapsed === "true" ? "false" : "true";
    const collapsed = [...onboardTypesEl.querySelectorAll("li[data-container='true']")]
      .filter((node) => node.dataset.collapsed === "true")
      .map((node) => node.dataset.name);
    for (const node of onboardTypesEl.querySelectorAll("li")) {
      const name = node.dataset.name;
      const hidden = collapsed.some(
        (prefix) => name !== prefix && (name.startsWith(`${prefix}.`) || name.startsWith(`${prefix}[`))
      );
      node.classList.toggle("is-collapsed-child", hidden);
    }
  });
  confirmView.querySelector(".onboard-cancel").addEventListener("click", showBrowse);
}
