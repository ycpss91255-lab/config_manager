// W3 參數欄位表（#20）：屬性、欄位、型別指定、值的控制項與存草稿。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, editFetch, failureText } from "./api.js";
import { devMark, element } from "./dom.js";
import { applyDraftsView, draftDetails, draftMarkText, draftUids, ownerLabel } from "./drafts.js";
import { STATE_TEXT, load, rows } from "./tree.js";
import { hitParams } from "./search.js";
import { TYPE_LABEL, openPanel, requestClose } from "./workspace.js";
import {
  currentValue, listAdd, listOps, refreshParamRow, same, setAt, toggleCollapse, updateOwner,
} from "./list-edit.js";
import { openHistory } from "./history.js";
import { driftBanner, errorBanner, missingBanner } from "./drift.js";
import { confirmAction, isBusy, whileBusy } from "./dialogs.js";
import { clearPromoteBanners, discardDrafts, leftBehindBanner, unmanageConfig } from "./promote.js";
import { currentIdentity } from "./identity.js";

export function panelNode(detail) {
  const row = rows.find((item) => item.uid === detail.uid);
  const state = row ? (row.error ? "錯誤" : STATE_TEXT[row.state] || row.state) : "";
  const close = element("button", {
    type: "button", class: "panel-close", "data-testid": "panel-close", title: "關閉這個區塊", text: "×",
  });
  // 解除納管（#287）：放在標頭，沒有欄位表的 raw 也拿得到；唯讀時不出現。
  const unmanageButton = element("button", {
    type: "button", class: "panel-unmanage editing-only", "data-testid": "panel-unmanage",
    title: "不再管理這份檔案（目標檔案保留）", text: "解除納管",
  });
  // 屬性（#286）：僅開發者——按鈕不在 DOM 裡，不是停用（ADR-00000020）。放在標頭，raw 也拿得到。
  const canEditAttributes = currentIdentity && currentIdentity.role === "developer";
  const attributesButton = canEditAttributes ? element("button", {
    type: "button", class: "panel-attributes editing-only", "data-testid": "panel-attributes",
    title: "修改名稱、群組、主機、說明", text: "屬性",
  }, []) : null;
  if (attributesButton) attributesButton.appendChild(devMark());
  let hasUnsavedEdits = () => false;  // 有欄位表時換成真的（見下）
  const head = element("div", { class: "panel-head", "data-testid": "panel-head" }, [
    element("span", { class: "name", text: detail.name }),
    element("span", { class: "target", text: detail.target }),
    element("span", { class: "state", "data-testid": `panel-status-${detail.uid}`, text: state }),
    element("span", {
      class: "panel-draft", "data-testid": `panel-draft-${detail.uid}`,
      text: draftMarkText(detail),
    }),
    element("button", {
      type: "button", class: "draft-owners", "data-testid": "draft-owners",
      title: "這份草稿的全部參與者", text: "參與者",
    }),
    ...(attributesButton ? [attributesButton] : []),
    unmanageButton,
    close,
  ]);
  const panel = element("section", { class: "panel", "data-testid": `panel-${detail.uid}` }, [head]);
  // 標頭單擊折疊／展開這一塊（右側以可折疊區塊堆疊，§7.4.1）；× 關閉這一槽。
  head.addEventListener("click", (event) => {
    if (event.target.closest("button")) return;
    panel.dataset.collapsed = panel.dataset.collapsed === "true" ? "false" : "true";
  });
  close.addEventListener("click", () => requestClose(detail.uid));
  unmanageButton.addEventListener("click", () => unmanageConfig(detail, unmanageButton));
  if (attributesButton) {
    attributesButton.addEventListener("click", () => {
      const open = panel.querySelector(`[data-testid='attributes-${detail.uid}']`);
      if (open) open.remove();
      else head.after(attributesPanel(detail, () => hasUnsavedEdits()));
    });
  }
  const draftMark = panel.querySelector(`[data-testid='panel-draft-${detail.uid}']`);
  draftMark.hidden = !detail.draft_values;
  // 參與者名單（ADR-00000032）：按鈕（滑鼠、Enter、觸控都能按）展開全部參與者，不只靠 title。
  const ownersButton = panel.querySelector("[data-testid='draft-owners']");
  ownersButton.hidden = !detail.draft_values || !(detail.draft_touched_by || []).length;
  ownersButton.addEventListener("click", () => {
    const open = panel.querySelector("[data-testid='draft-owners-list']");
    if (open) { open.remove(); return; }
    head.after(element("ul", { class: "draft-owners-list", "data-testid": "draft-owners-list" },
      (detail.draft_touched_by || []).map((who, index) => element("li", {
        text: `${index + 1}. ${ownerLabel(who)}（${who.email}）`,
      }))));
  });
  if (detail.format === "raw") {
    // raw 是唯一不受把關的格式——明確標示「未驗證」，使用者看得到自己放棄了什麼（§3.4）。
    head.insertBefore(element("span", {
      class: "panel-unvalidated", "data-testid": `panel-unvalidated-${detail.uid}`,
      title: "raw：只版控、不解析——內容不經任何檢查", text: "未驗證",
    }), close);
  } else if (detail.schema) {
    head.insertBefore(schemaBadge(detail.uid, detail.schema), close);
  }
  const leftBanner = leftBehindBanner(detail, row);  // #345：區塊最上方，在偏離橫幅之前
  if (leftBanner) panel.appendChild(leftBanner);
  if (row && row.state === "drift") panel.appendChild(driftBanner(detail, true));
  if (row && !row.error && row.state === "missing") panel.appendChild(missingBanner(detail));
  if (row && row.error) panel.appendChild(errorBanner(row.error));
  if (detail.schema_error) {
    // schema 讀不出來（#40）：值照樣看得到，但明說這份在修好之前存不了——不讓人改了半天才被擋。
    panel.appendChild(element("div", { class: "notice error", "data-testid": "panel-schema-error" }, [
      element("strong", { text: "這份的 schema 讀不出來，修好之前改動存不了。" }),
      element("pre", { text: detail.schema_error }),
    ]));
  }
  const structured = detail.values && typeof detail.values === "object" && !Array.isArray(detail.values);
  if (detail.format === "raw" || !structured) {
    // §7.5.4：沒有結構就明說「未結構化」——使用者看得到自己失去了型別保護（不變式 2）。
    panel.appendChild(element("p", {
      class: "notice", "data-testid": "panel-unstructured",
      text: detail.format === "raw"
        ? "raw：只版控、不解析——這份 config 沒有欄位表（未結構化）。"
        : "這份 config 的頂層不是物件，無法以欄位表呈現（未結構化）。",
    }));
    return panel;
  }
  // 儲存＝存為草稿：不記錄、不寫出（§7.4.3、T18）。驗證未過時停用；沒有任何改動也停用。
  const saveButton = element("button", {
    type: "button", class: "panel-save editing-only", "data-testid": "panel-save", text: "儲存",
  });
  saveButton.disabled = true;
  const saveError = element("div", {
    class: "notice error panel-save-error", "data-testid": "panel-save-error",
  });
  saveError.hidden = true;
  const entries = [];
  hasUnsavedEdits = () => entries.some((entry) => entry.node.dataset.dirty === "true");
  // 人工指定型別（#285）：僅開發者、且拿得到編輯階段（唯讀分頁沒有身分）。
  const specify = currentIdentity && currentIdentity.role === "developer"
    ? (row, typeName, reset) => specifyType(detail, row, typeName, { entries, error: saveError, reset })
    : null;
  // 儲存這個動作的結果說明（存成了、或為什麼沒存），放在儲存鈕旁；又動了欄位就收掉——那句話說的
  // 是上一次儲存，不是現在畫面上的東西。
  const saveNote = element("span", {
    class: "hint", "data-testid": "panel-save-note", role: "status", hidden: "",
  });
  const refreshSave = () => {
    const invalid = entries.some((entry) => entry.node.dataset.valid === "false");
    const dirty = entries.some((entry) => entry.node.dataset.dirty === "true");
    saveButton.disabled = invalid || !dirty;
    if (dirty) saveNote.hidden = true;
  };
  const list = element("ul", { class: "param-table", "data-testid": "param-table" }, [
    element("li", { class: "param-row param-head" }, [
      element("span", { class: "param-name", text: "參數" }),
      // 型別欄：開發者可以逐列指定型別（#285），所以標題帶開發者記號；一般使用者看到的是純文字。
      element("span", { class: "param-type", "data-testid": "param-type-head", text: "型別" },
        specify ? [devMark()] : []),
      element("span", { class: "param-value-wrap", text: "值" }),
      element("span", { class: "param-source", text: "來源值" }),
      element("span", { class: "param-validation", text: "驗證" }),
    ]),
  ]);
  // 一張欄位表共用的東西：列（entries）、儲存鈕的重算、型別指定、清單增刪調序時重畫用的 detail 與 ul。
  const table = { detail, entries, onChange: refreshSave, specify, list };
  for (const row of paramRows(detail)) list.appendChild(paramRow(row, table));
  if (specify) list.dataset.specifiable = "true";
  list.addEventListener("click", (event) => {
    if (event.target.closest("button")) return;  // 清單的增刪調序鈕在容器列上，不是要折疊
    const container = event.target.closest("li[data-container='true']");
    if (container) toggleCollapse(list, container);
  });
  // 捨棄變更（單一 config）：清掉這份的草稿、回到來源內容；只有有草稿時才出現（#22）。
  const discardButton = element("button", {
    type: "button", class: "editing-only", "data-testid": "panel-discard", text: "捨棄變更",
  });
  discardButton.hidden = !detail.draft_values;
  discardButton.addEventListener("click", () => discardDrafts(detail.uid, detail.name, discardButton));
  // 第 3 層規則的警告區（#44／#45）：違反規則時列出每一條與理由欄，填了理由才存得成。
  const warningsSlot = element("div", { class: "rule-warnings-slot" });
  const ui = {
    save: saveButton, error: saveError, draft: draftMark, discard: discardButton,
    owners: ownersButton, warnings: warningsSlot, entries, note: saveNote,
  };
  saveButton.addEventListener("click", () => whileBusy(saveButton, "儲存中…", () => saveDraft(detail, entries, ui)));
  if ((detail.draft_warnings || []).some((problem) => problem.rule)) {
    // 重開一份有草稿的 config（例如「先納入、待修正」載入的）：還有哪些規則要填理由，一開就看到。
    renderRuleWarnings(detail, ui, detail.draft_warnings, detail.draft_overrides || {}, false);
  }
  // 歷史（W4，#25）：這份 config 的變更紀錄，右側工作區切成歷史檢視、左側樹不動。
  const historyButton = element("button", {
    type: "button", "data-testid": "panel-history", text: "歷史",
  });
  historyButton.addEventListener("click", () => openHistory(detail));
  // 產生 schema 骨架（#38）：僅開發者、還沒有 schema 的才出現——不在 DOM 裡，不是停用（ADR-00000020）。
  const actions = [historyButton];
  if (!detail.schema && currentIdentity && currentIdentity.role === "developer") {
    const schemaButton = element("button", {
      type: "button", class: "editing-only", "data-testid": "panel-schema-draft", text: "產生 schema",
    });
    schemaButton.appendChild(devMark());
    schemaButton.addEventListener("click", () => {
      draftSchema(detail, { button: schemaButton, error: saveError, head, close });
    });
    actions.push(schemaButton);
  }
  // 搜尋命中的參數：標示那幾列，並把第一列捲進視野（「展開時定位到該列」，§7.4.2）。
  const hits = hitParams.get(detail.uid) || [];
  let firstHit = null;
  for (const path of hits) {
    const hitRow = [...list.querySelectorAll("li[data-name]")].find((node) => node.dataset.name === path);
    if (!hitRow) continue;
    hitRow.dataset.hit = "true";
    firstHit = firstHit || hitRow;
  }
  if (firstHit) queueMicrotask(() => firstHit.scrollIntoView({ block: "center" }));
  panel.append(list, warningsSlot, saveError, element("div", { class: "panel-actions" }, [
    ...actions,
    element("span", { class: "hint", text: "「儲存」只是存為草稿——不記錄、不寫到目標；工具列的「進版」才會。草稿只留到服務重啟為止。" }),
    saveNote,
    discardButton,
    saveButton,
  ]));
  refreshSave();
  return panel;
}

// 屬性面板（§7.4.4、#286）：名稱、群組（可多個）、主機、說明。從區塊標頭展開，僅開發者。
// 儲存後樹依新的群組／主機重建（load），這一塊重畫；重畫會丟掉還沒儲存的參數改動，所以有的話
// 先擋下、說清楚（不變式 2）。後端指名是哪一項不合法時，標在那個輸入框。
export const ATTRIBUTE_FIELDS = [
  ["name", "名稱", ""],
  ["groups", "群組", "可多個，以逗號分隔；留空＝未分群"],
  ["hostname", "主機", ""],
  ["description", "說明", "用途說明，滑鼠停在樹節點上時顯示"],
];

export function attributesPanel(detail, hasUnsavedEdits) {
  const inputs = {};
  const rows = ATTRIBUTE_FIELDS.map(([key, label, hint]) => {
    const value = key === "groups" ? (detail.groups || []).join(", ") : detail[key] || "";
    inputs[key] = element("input", { type: "text", value, placeholder: hint });
    return element("label", {}, [element("span", { text: label }), inputs[key]]);
  });
  const error = element("div", { class: "notice error", "data-testid": "attributes-error" });
  error.hidden = true;
  const save = element("button", { type: "button", "data-testid": "attributes-save", text: "儲存屬性" });
  const cancel = element("button", { type: "button", "data-testid": "attributes-cancel", text: "取消" });
  const form = element("div", { class: "attributes", "data-testid": `attributes-${detail.uid}` }, [
    ...rows,
    element("span", { class: "hint", text: "屬性的修改會留一筆變更紀錄，與參數內容的修改分開。改名不影響歷史與草稿。" }),
    error,
    element("div", { class: "attributes-actions" }, [cancel, save]),
  ]);
  cancel.addEventListener("click", () => form.remove());
  save.addEventListener("click", () => whileBusy(
    save, "儲存中…", () => saveAttributes(detail, { inputs, error, save, hasUnsavedEdits }),
  ));
  return form;
}

export async function saveAttributes(detail, ui) {
  for (const input of Object.values(ui.inputs)) input.removeAttribute("aria-invalid");
  ui.error.hidden = true;
  if (ui.hasUnsavedEdits()) {
    renderSaveError(ui.error, "這一塊有還沒儲存的參數改動。下一步：先儲存或改回原值，再儲存屬性——儲存屬性會重畫這一塊。");
    return;
  }
  const body = {
    name: ui.inputs.name.value,
    hostname: ui.inputs.hostname.value,
    groups: ui.inputs.groups.value.split(/[,，、]/).map((group) => group.trim()).filter(Boolean),
    description: ui.inputs.description.value,
  };
  ui.save.disabled = true;
  clearPromoteBanners();  // F38
  try {
    const response = await editFetch(`${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}/attributes`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const payload = await response.json();
    if (!response.ok) {
      renderSaveError(ui.error, payload.detail);
      const field = payload.detail && payload.detail.field;
      if (field && ui.inputs[field]) ui.inputs[field].setAttribute("aria-invalid", "true");
      return;
    }
    load();  // 樹依新的群組／主機／名稱重建
    openPanel(detail.uid, element("p", {
      class: "notice", "data-testid": "attributes-saved-notice",
      text: "已更新屬性，並記一筆變更紀錄。",
    }));
  } catch (error) {
    renderSaveError(ui.error, failureText("儲存屬性", error));
  } finally {
    ui.save.disabled = false;
  }
}

// 指定或清除一個參數的型別（#285）。型別一變，那一列的輸入控制項也要換，所以成功後重畫這一塊；
// 重畫會丟掉還沒儲存的改動，因此有未儲存的改動時先擋下、說清楚，不悄悄丟（不變式 2）。
export async function specifyType(detail, row, typeName, ui) {
  ui.error.hidden = true;
  if (ui.entries.some((entry) => entry.node.dataset.dirty === "true")) {
    renderSaveError(ui.error, "這一塊有還沒儲存的改動。下一步：先儲存或改回原值，再改型別——改型別會重畫這張表。");
    ui.reset();
    return;
  }
  clearPromoteBanners();  // F38：指定型別寫的是設定庫的 schema 檔
  try {
    const response = await editFetch(`${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}/types`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: row.path, type: typeName }),
    });
    const payload = await response.json();
    if (!response.ok) {
      renderSaveError(ui.error, payload.detail);
      ui.reset();
      return;
    }
    openPanel(detail.uid, element("p", {
      class: "notice", "data-testid": "type-specified-notice",
      text: typeName === null
        ? `已清除「${row.path}」的型別指定，並記一筆變更紀錄。`
        : `已把「${row.path}」的型別指定為 ${TYPE_LABEL[typeName]}，並記一筆變更紀錄。`,
    }));
  } catch (error) {
    renderSaveError(ui.error, failureText("指定型別", error));
    ui.reset();
  }
}

export function schemaBadge(uid, path) {
  return element("span", {
    class: "panel-schema", "data-testid": `panel-schema-${uid}`,
    title: `修改會依 ${path} 檢查型別`, text: "有 schema",
  });
}

// 產生 schema 骨架（#38）。不可悄悄開啟一道把關：先說會發生什麼。成功後就地換上標示、拿掉按鈕，
// **不重畫欄位表**——還沒儲存的改動不能因此消失（不變式 2）。
export async function draftSchema(detail, ui) {
  if (isBusy(ui.button)) return;
  const ok = await confirmAction(
    `替「${detail.name}」產生 schema？`,
    "會依目前的值記下每個參數的型別，存進設定庫的 .schemas/ 並留一筆變更紀錄。"
      + "之後這份 config 的修改會依它檢查型別。只記型別，不限制必填、多出來的參數或數值範圍。",
    "產生 schema",
  );
  if (!ok) return;
  await whileBusy(ui.button, "產生中…", async () => {
    ui.error.hidden = true;
    ui.button.disabled = true;
    clearPromoteBanners();  // F38
    try {
      const response = await editFetch(
        `${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}/schema`, { method: "POST" },
      );
      const payload = await response.json();
      if (!response.ok) {
        renderSaveError(ui.error, payload.detail);
        return;
      }
      detail.schema = payload.schema;
      ui.button.remove();
      ui.head.insertBefore(schemaBadge(detail.uid, payload.schema), ui.close);
      ui.head.after(element("p", {
        class: "notice", "data-testid": "schema-drafted-notice",
        text: `已產生 schema（${payload.schema}），並記一筆變更紀錄。`,
      }));
    } catch (error) {
      renderSaveError(ui.error, failureText("產生 schema", error));
    } finally {
      ui.button.disabled = false;
    }
  });
}

// 後端回的問題若指名了欄位（第 2 層帶 `path`，#39），就標在那一列：標紅、寫出原因與修正建議
// （§7.5.1）。介面沒擋到、後端擋下的（例如 schema 的 pattern）靠這個讓人知道是哪一列。那一列再被
// 改動時由 refreshParamRow 重算，標記自然清掉。
// 規則的警告區（#44／#45）：每一條規則一列——原因、建議、略過的理由欄。`missing`＝剛送出時有
// 規則沒填理由；`saved`＝已帶理由存成。警告的列標成琥珀色，與紅色的硬擋分得開。
export function renderRuleWarnings(detail, ui, problems, reasons, missing, saved = false) {
  const byRule = new Map();
  for (const problem of problems) {
    if (problem.rule && !byRule.has(problem.rule)) byRule.set(problem.rule, problem);
  }
  markWarnings(ui.entries, problems);
  const inputs = {};
  const items = [...byRule.values()].map((problem) => {
    inputs[problem.rule] = element("input", {
      type: "text", "data-testid": `override-reason-${problem.rule}`,
      value: reasons[problem.rule] || "", placeholder: "為什麼要這樣設（會寫進變更紀錄）",
    });
    return element("li", { "data-testid": `rule-warning-${problem.rule}` }, [
      element("span", { text: `規則 ${problem.rule}：${problemText(problem)}` }),
      element("label", {}, [element("span", { text: "略過的理由" }), inputs[problem.rule]]),
    ]);
  });
  const submit = element("button", {
    type: "button", class: "editing-only", "data-testid": "save-with-overrides", text: "填理由後儲存",
  });
  submit.addEventListener("click", () => {
    const given = Object.fromEntries(Object.entries(inputs).map(([rule, input]) => [rule, input.value]));
    whileBusy(submit, "儲存中…", () => saveDraft(detail, ui.entries, ui, given));
  });
  const children = [
    element("strong", {
      text: saved
        ? `已儲存，已略過 ${byRule.size} 條規則的警告；理由會在進版時寫進變更紀錄。`
        : `有 ${byRule.size} 條規則的警告。警告不擋存檔，但要填寫略過的理由才能儲存；理由會寫進變更紀錄。`,
    }),
    element("ul", {}, items),
  ];
  if (missing) {
    children.push(element("p", {
      class: "override-error", "data-testid": "override-error",
      text: "還有規則沒填理由。下一步：對每一條填寫理由後再按「填理由後儲存」，或把值改回規則接受的範圍。",
    }));
  }
  if (saved) children.push(element("p", { class: "override-done", text: "改了理由再按一次「填理由後儲存」即可更新。" }));
  children.push(submit);
  ui.warnings.replaceChildren(
    element("div", { class: "notice warning", "data-testid": "rule-warnings" }, children),
  );
}

export function markWarnings(entries, problems) {
  for (const problem of problems || []) {
    const entry = problem.path && entries.find((candidate) => candidate.row.path === problem.path);
    if (!entry || entry.node.dataset.valid === "false") continue;  // 硬擋的紅色優先
    entry.node.dataset.warning = "true";
    entry.node.querySelector("[data-testid='param-validation']").textContent = `警告：${problem.message}`;
  }
}

export function markServerProblems(entries, problems) {
  for (const problem of problems || []) {
    const entry = problem.path && entries.find((candidate) => candidate.row.path === problem.path);
    if (!entry) continue;
    entry.node.dataset.valid = "false";
    entry.node.querySelector("[data-testid='param-validation']").textContent =
      `${problem.message}。建議：${problem.suggestion}`;
  }
}

export function markedInvalid(entries) {
  return entries.some((entry) => entry.node.dataset.valid === "false");
}

// 送出的是相對**來源**的全部改動（後端以來源複本為底重建草稿文字），不是相對上一份草稿的差量。
// 哪些欄位送（F15）：人動過的（touched）送現值；沒碰的欄位若已有草稿值（已存的草稿≠來源）就原樣送那個
// 草稿值——不拿控制項裡的現值，瀏覽器對它做的任何正規化（例如 input 拿掉換行）才不會變成改動；
// 改回來源值的欄位不送（草稿裡那一欄就回到來源）。
// `overrides`：規則代號 → 略過的理由（#42／#45）。違反第 3 層規則而沒帶理由時後端回 409
// override_required——不是錯誤，是還缺使用者的一個決定：列出警告與理由欄，填了再送一次。
export async function saveDraft(detail, entries, ui, overrides = {}) {
  const edits = {};
  for (const entry of entries) {
    const { row } = entry;
    if (row.owner) continue;  // 清單底下的列由擁有者整個清單一起送
    if (row.working) {
      if (!same(row.working, row.value)) edits[row.path] = row.working;  // 整個清單替換（#46）
      continue;
    }
    const sourceText = displayValue(row.value, row.type);
    if (entry.touched) {
      const current = currentValue(entry.control, row);
      if (displayValue(current, row.type) !== sourceText) edits[row.path] = current;
    } else if (displayValue(row.baseline, row.type) !== sourceText) {
      edits[row.path] = row.baseline;  // 沒碰、但已有草稿值：原樣保留
    }
  }
  ui.error.hidden = true;
  ui.save.disabled = true;
  clearPromoteBanners();  // F38：存草稿也是一次寫入，送出就收起上一個結果（例如「已進版…」）
  try {
    const response = await editFetch(`${API_BASE}/api/drafts`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ uid: detail.uid, edits, overrides }),
    });
    const payload = await response.json();
    if (response.status === 409 && payload.detail && payload.detail.kind === "override_required") {
      renderRuleWarnings(detail, ui, payload.detail.problems, overrides, Object.keys(overrides).length > 0);
      ui.save.disabled = false;
      return;
    }
    if (!response.ok) {
      renderSaveError(ui.error, payload.detail);
      markServerProblems(entries, payload.detail && payload.detail.problems);
      ui.save.disabled = markedInvalid(entries);
      return;
    }
    applyDraftsView(payload);  // 樹上的草稿標記、工具列的計數、誰存的
    for (const entry of entries) {
      if (entry.row.working) entry.row.listBaseline = clone(entry.row.working);
      else entry.row.baseline = currentValue(entry.control, entry.row);
      entry.touched = false;  // 存好了：之後沒再碰就送已存的草稿值
    }
    for (const entry of entries) entry.refresh();  // 畫面＝已存的草稿：不再 dirty、儲存回到停用
    ui.draft.hidden = !draftUids.has(detail.uid);
    ui.discard.hidden = !draftUids.has(detail.uid);
    // 區塊在儲存前就開著：標頭的草稿指示與參與者按鈕也照回應更新，不是只取消隱藏（第 5 批重驗 A2）。
    // 參與者名單是按下時依 detail 重畫的，所以先把 detail 換成剛存好的主人，再把舊名單收起來。
    const saved = draftDetails.get(detail.uid);
    detail.draft_saved_by = saved ? saved.saved_by : null;
    detail.draft_touched_by = saved ? saved.touched_by : [];
    ui.draft.textContent = draftMarkText(detail);
    ui.owners.hidden = ui.draft.hidden || !detail.draft_touched_by.length;
    const openList = ui.owners.closest(".panel").querySelector("[data-testid='draft-owners-list']");
    if (openList) openList.remove();
    const skipped = (payload.warnings || []).filter((problem) => problem.rule);
    if (skipped.length) renderRuleWarnings(detail, ui, skipped, overrides, false, true);
    else if (ui.warnings) ui.warnings.replaceChildren();
    // 存成了要說一聲（#50）：畫面留在原處不動，只靠一個小圓點看不出剛才那一下有沒有生效。
    if (ui.note) {
      ui.note.textContent = "已存為草稿——還沒進版；要記錄並寫到目標，按工具列的「進版」。服務重啟後，沒進版的草稿不會留著。";
      ui.note.hidden = false;
    }
  } catch (error) {
    renderSaveError(ui.error, failureText("儲存草稿", error));
    ui.save.disabled = false;
  }
}

// 第 1 層沒過的 422 是結構化的 {message, uid, problems:[{line, message, suggestion}]}；逐條列出
// 行號／原因／建議（三要素），不改寫。其他形狀（字串、FastAPI 驗證 list）原樣顯示。
// 一個驗證問題的一行說明。第 2 層（schema）的問題不一定給得出行號——給不出就不印「第 null 行」，
// 訊息本身已經指名欄位（#39）。
export function problemText(problem) {
  const where = problem.line === null || problem.line === undefined ? "" : `第 ${problem.line} 行：`;
  return `${where}${problem.message}。建議：${problem.suggestion}`;
}

export function renderSaveError(target, detail) {
  target.replaceChildren();
  if (detail && typeof detail === "object" && !Array.isArray(detail) && detail.message) {
    target.appendChild(element("strong", { text: detail.message }));
    target.appendChild(element("ul", {}, (detail.problems || []).map((problem) => element("li", {
      text: problemText(problem),
    }))));
  } else if (Array.isArray(detail)) {
    target.appendChild(element("strong", {
      text: detail.map((item) => item.msg || JSON.stringify(item)).join("；"),
    }));
  } else {
    target.appendChild(element("strong", { text: String(detail) }));
  }
  target.hidden = false;
}

// 前序走訪值樹，配上 types 裡的型別（list 元素的型別鍵是 `path[]`，值的路徑是 `path[i]`）。
// key 裡的字面點跳脫成 \.（#219），路徑文法與 set_value 一致（`a.b\.c[2]`）。
export const clone = (value) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)));
export const escapeKey = (key) => String(key).replace(/\./g, "\\.");

export function paramRows(detail) {
  const out = [];
  // value 是來源值（「來源值」欄、改動的比較基準）；draft 是草稿裡對應的值（有草稿時當「目前值」的
  // 起點，#21）。兩棵樹並行走訪，草稿樹缺該路徑就退回來源值。
  const drafts = detail.draft_values;
  for (const [key, value] of Object.entries(detail.values)) {
    const draft = drafts && typeof drafts === "object" ? drafts[key] : undefined;
    collectRows(detail, out, {
      value, draft, path: escapeKey(key), typePath: escapeKey(key), depth: 0, name: key,
      owner: null, segments: null,
    });
  }
  return out;
}

// 一個欄位與它底下的全部列。清單（#46）：最外層的清單是「擁有者」，有一份可以改的工作副本
// （`working`，從目前值複製）；它底下的每一列都掛在它身上（`owner`＋相對位置 `segments`），
// 改值寫回工作副本，增刪調序改工作副本後整段重畫。清單裡再有清單，一併由最外層那份擁有。
//
// 擁有者另有一份**來源的影子**（`shadow`，從來源值複製）：增刪調序時與工作副本做同樣的搬動，
// 但**改值從不碰它**。底下每一列的「來源值」都從影子的同一個位置取——所以來源值跟著元素走
// （alpha 上移後它的來源值仍是 alpha 原本的值），新增的元素在影子裡是空位（顯示「—」）。
// 重畫只讀影子，不讀工作副本：還沒儲存的編輯值不會變成來源值（人工驗證 U36）。
export function collectRows(detail, out, scope) {
  const { value, draft, path, typePath, depth, name, owner, segments } = scope;
  const type = detail.types[typePath] || "unknown";
  const container = type === "dict" || type === "list";
  const baseline = draft === undefined ? value : draft;
  // schema 對這個欄位的提示（範圍／步進／列舉選項／說明，#40；字串長度，F6）；沒有 schema 或沒有提示就是 null。
  const hint = (!container && (detail.constraints || {})[typePath]) || null;
  // 這個欄位的型別是不是人工指定的（#285）；清單元素不能個別指定。
  const manual = !owner && Boolean((detail.manual_types || {})[typePath]);
  const row = { path, type, typePath, value, baseline, depth, name, container, hint, manual, owner, segments };
  if (type === "list" && !owner) {
    row.working = clone(baseline) || [];
    row.listBaseline = clone(baseline) || [];
    row.shadow = Array.isArray(value) ? clone(value) : [];
  }
  out.push(row);
  const under = (childValue, childDraft, childPath, childTypePath, childName, segment) => collectRows(
    detail, out, {
      value: childValue, draft: childDraft, path: childPath, typePath: childTypePath,
      depth: depth + 1, name: childName,
      owner: owner || (type === "list" ? row : null),
      segments: owner || type === "list" ? [...(segments || []), segment] : null,
    },
  );
  if (type === "dict") {
    // 以目前值（草稿／工作副本）的鍵走訪：清單裡新增的物件元素在來源裡沒有對應項，來源值那邊
    // 取不到就是 undefined（顯示成「—」）。
    const sourceKeys = value && typeof value === "object" ? value : {};
    for (const [key, child] of Object.entries(baseline || {})) {
      under(sourceKeys[key], draft === undefined ? undefined : child,
        `${path}.${escapeKey(key)}`, `${typePath}.${escapeKey(key)}`, key, key);
    }
  } else if (type === "list") {
    // 元素從目前值畫（擁有者＝工作副本）；來源值從影子的同一個位置取。擁有者底下的清單，`value`
    // 一路都是從影子傳下來的，所以裡面那層也一樣。
    const source = row.working ? row.shadow : (Array.isArray(value) ? value : []);
    (row.working || baseline || []).forEach((child, index) =>
      under(source[index], child, `${path}[${index}]`, `${typePath}[]`, `[${index}]`, index));
  }
}

// double 顯示一定帶小數點（`5` → `5.0`）——擋 ROS 2 的 1 vs 1.0 型別錯誤（§7.5.2）。
export function formatDouble(number) {
  return Number.isInteger(number) ? number.toFixed(1) : String(number);
}

export function displayValue(value, type) {
  if (type === "float") return formatDouble(value);
  if (value === null || typeof value === "object") return JSON.stringify(value);
  return String(value);
}

// 列舉（#40）：選項來自 schema，結構上不可能選到不存在的值（§7.5.2）。目前的值若不在選項裡
// （schema 是後來才收緊的），另列一個標明「不在允許的值裡」的選項並把這一列標成有問題——不悄悄
// 換成第一個選項（那等於替人改了值）。`choices` 與選項一一對應，取值時拿回原本型別的值。
export function enumControl(row) {
  const choices = [...row.hint.enum];
  const labels = choices.map((choice) => displayValue(choice, row.type));
  let selected = choices.findIndex((choice) =>
    displayValue(choice, row.type) === displayValue(row.baseline, row.type));
  if (selected < 0) {
    choices.unshift(row.baseline);
    labels.unshift(`${displayValue(row.baseline, row.type)}（不在允許的值裡）`);
    selected = 0;
  }
  const control = element("select", {}, labels.map((label, index) =>
    element("option", { value: String(index), text: label })));
  if (choices.length > row.hint.enum.length) control.options[0].dataset.outside = "true";
  control.selectedIndex = selected;
  control.choices = choices;
  return control;
}

// 數值範圍（#40）：輸入框套 min／max／step（§7.5.2）。只設上下界與步進的屬性供瀏覽器的增減鈕用；
// 「合不合」由 refreshParamRow 自己算——瀏覽器的步進檢查以 min 為起點，與 schema 的倍數語意不同。
export function applyRange(control, hint) {
  if (!hint) return;
  const low = hint.minimum ?? hint.exclusiveMinimum;
  const high = hint.maximum ?? hint.exclusiveMaximum;
  if (low !== undefined) control.min = String(low);
  if (high !== undefined) control.max = String(high);
  if (hint.multipleOf !== undefined) control.step = String(hint.multipleOf);
}

// 字串的控制項（F15）：值含換行就用 textarea——`<input type=text>` 會把換行拿掉，多行的值一打開
// 就變了、而且被當成已改。單行維持 input。兩種都掛同一個 data-testid（param-value）。
export function stringControl(value, multiline = /[\r\n]/.test(String(value))) {
  const text = String(value);
  const control = multiline
    ? element("textarea", { rows: String(Math.min(8, text.split("\n").length + 1)) })
    : element("input", { type: "text" });
  control.value = text;
  return control;
}

// 「多行」切換（F15 的 D1）：只換控制項、值照搬——不算人動過、不標已改、不送出。值已含換行時不能切回
// 單行（input 會把換行拿掉，那正是 F15）。ini 的字串列沒有這個鈕：ini 的值只能一行（B1），後端會拒絕。
export function multilineToggle(entry, listen) {
  const button = element("button", {
    type: "button", class: "param-multiline", "data-testid": "param-multiline",
  });
  const relabel = () => {
    const multiline = entry.control.tagName === "TEXTAREA";
    button.textContent = multiline ? "單行" : "多行";
    button.disabled = multiline && /[\r\n]/.test(entry.control.value);
    button.title = button.disabled
      ? "值裡有換行，先改成一行才能切回單行輸入"
      : "切換單行／多行輸入；不會改值";
  };
  button.addEventListener("click", () => {
    const next = stringControl(entry.control.value, entry.control.tagName !== "TEXTAREA");
    next.setAttribute("data-testid", "param-value");
    entry.control.replaceWith(next);
    entry.control = next;
    listen(next);
    relabel();
    next.focus();
  });
  entry.relabel = relabel;
  relabel();
  return button;
}

export function valueControl(row) {
  let control;
  const hasChoices = row.hint && Array.isArray(row.hint.enum) && row.type !== "bool";
  switch (hasChoices ? "enum" : row.type) {
    case "bool":
      control = element("input", { type: "checkbox" });
      control.checked = row.baseline === true;
      break;
    case "int":
      control = element("input", { type: "number", step: "1", value: String(row.baseline) });
      applyRange(control, row.hint);
      break;
    case "float":
      control = element("input", { type: "number", step: "any", value: formatDouble(row.baseline) });
      applyRange(control, row.hint);
      break;
    case "enum":
      control = enumControl(row);
      break;
    case "string":
      control = stringControl(row.baseline);  // 引號由系統處理；含換行用 textarea 保留換行（F15）
      break;
    default:
      // 型別未知（null、空陣列的元素…）：退回文字編輯，列上明確標示「未結構化編輯」——使用者看得到
      // 自己失去了型別保護（§7.5.4、#46）；這類項目應優先補 schema。控制項與字串同一個：值含換行時
      // 是 textarea，否則單行輸入框——單行輸入框保不住換行，改過之後換行會變成空格（#383，F15 同一個
      // 問題在字串上修過；附錄 C.2：退回文字區塊時 textarea 已足夠）。
      control = stringControl(displayValue(row.baseline, row.type));
  }
  control.setAttribute("data-testid", "param-value");
  return control;
}

// 型別欄（§7.5.3、#285）。開發者對單一參數看到的是下拉選單——選了就把那個型別人工指定下去；
// 其餘情況（一般使用者、唯讀、容器、清單元素、型別未知）是純文字，選單根本不在 DOM 裡。
// 人工指定過的列標「已指定」（誰都看得到），開發者另有「清除」（逐欄位，回到指定之前）。
export const SPECIFIABLE = ["int", "float", "bool", "string"];

export function typeCell(row, specify) {
  const label = row.hint && Array.isArray(row.hint.enum)
    ? TYPE_LABEL.enum : TYPE_LABEL[row.type] || row.type;
  const cell = element("span", { class: "param-type" });
  const choosable = specify && !row.container && !row.owner && SPECIFIABLE.includes(row.type);
  if (choosable) {
    // 唯讀（沒拿到編輯階段、或階段中途失效）時選單不出現，改顯示純文字——會寫入的控制項一律如此。
    const select = element("select", {
      class: "editing-only", "data-testid": "param-type", title: "指定這個參數的型別",
    }, SPECIFIABLE.map((name) => element("option", { value: name, text: TYPE_LABEL[name] })));
    select.value = row.type;
    select.addEventListener("change", () => specify(row, select.value, () => { select.value = row.type; }));
    cell.append(select, element("span", {
      class: "readonly-only", "data-testid": "param-type-text", text: label,
    }));
  } else {
    cell.appendChild(element("span", { "data-testid": "param-type", text: label }));
  }
  if (row.manual) {
    cell.appendChild(element("span", {
      class: "type-overridden", "data-testid": "type-overridden",
      title: "這個型別是人工指定的，不是系統推斷的", text: "已指定",
    }));
    if (specify) {
      const clearButton = element("button", {
        type: "button", class: "type-clear editing-only", "data-testid": "type-clear",
        title: "清除這一欄的型別指定，回到指定之前", text: "清除",
      });
      clearButton.addEventListener("click", () => specify(row, null, () => {}));
      cell.appendChild(clearButton);
    }
  }
  return cell;
}

export function paramRow(row, table) {
  const { entries, onChange, specify } = table;
  const attributes = {
    class: "param-row",
    "data-testid": `param-${row.path}`,
    "data-name": row.path,
    "data-type": row.type,
    "data-depth": String(row.depth),
  };
  if (row.container) attributes["data-container"] = "true";
  const node = element("li", attributes, [
    element("span", {
      class: "param-name",
      text: `${"　".repeat(row.depth)}${row.container ? "▾ " : ""}${row.name}`,
    }),
    typeCell(row, specify),
  ]);
  row.node = node;
  // 清單的元素（不管在第幾層）：這一列有 ↑↓ 與移除。元素的最後一段位置是數字，物件的欄位是鍵。
  if (row.owner && typeof row.segments[row.segments.length - 1] === "number") {
    node.appendChild(listOps(row, table));
  }
  if (row.container) {
    if (row.working) {
      // 清單的擁有者：新增元素的入口在這一列；清單整體有沒有改動也標在這一列（#46）。
      node.appendChild(listAdd(row, table));
      entries.push({ row, node, refresh: () => updateOwner(row, onChange) });
      updateOwner(row, null);
    } else if (row.type === "list" && row.owner) {
      node.appendChild(listAdd(row, table));  // 清單裡的清單：一樣可以加一項
    }
    return node;
  }
  if (row.hint && row.hint.description) {
    // schema 的說明顯示在欄位旁，滑鼠停留看得到全文（§7.5.1）。
    const name = node.querySelector(".param-name");
    name.title = row.hint.description;
    name.appendChild(element("span", {
      class: "param-description", "data-testid": "param-description",
      title: row.hint.description, "aria-label": row.hint.description, text: " ⓘ",
    }));
  }
  if (row.type === "unknown" || row.type === "null") {
    node.querySelector(".param-name").appendChild(element("span", {
      class: "param-unstructured", "data-testid": "param-unstructured",
      title: "這個欄位沒有型別保護，輸入什麼都照字面存成文字。請優先補 schema 給它型別。",
      text: " 未結構化編輯",
    }));
  }
  const control = valueControl(row);
  const source = element("span", {
    class: "param-source", "data-testid": "param-source-value",
    text: row.value === undefined ? "—" : displayValue(row.value, row.type),
  });
  const validation = element("span", { class: "param-validation", "data-testid": "param-validation" });
  const wrap = element("span", { class: "param-value-wrap" }, [control]);
  node.append(wrap, source, validation);
  // entry.control 可能被「多行」切換換掉，所以一律從 entry 拿；touched＝人真的輸入過（input 事件），
  // 取得焦點、切換控制項都不算（F15：沒碰的欄位不送出，瀏覽器的正規化才不會變成假改動）。
  const entry = { row, control, node, touched: false, refresh: null, relabel: null };
  const refresh = () => {
    refreshParamRow(node, entry.control, row, source, validation);
    if (row.owner) {
      // 清單底下的列：把值寫回擁有者的工作副本，整個清單的變動與否由擁有者那一列說。
      setAt(row.owner.working, row.segments, currentValue(entry.control, row));
      updateOwner(row.owner, null);
    }
    if (entry.relabel) entry.relabel();
    if (onChange) onChange();
  };
  entry.refresh = refresh;
  const listen = (target) => {
    target.addEventListener("input", () => {
      entry.touched = true;
      refresh();
    });
    target.addEventListener("change", () => {
      // double：離開欄位時把整數樣子的輸入正規化成帶小數點（打字中不動，否則沒法打出 52）。
      if (row.type === "float" && target.value !== "" && !target.validity.badInput) {
        target.value = formatDouble(Number(target.value));
      }
      refresh();
    });
  };
  listen(control);
  if (row.type === "string" && table.detail && table.detail.format !== "ini") {
    wrap.appendChild(multilineToggle(entry, listen));
  }
  entries.push(entry);
  refresh();  // 一開始就標好 data-valid／data-changed，讓「尚未改動」與「改成一樣的值」是同一個狀態
  return node;
}
