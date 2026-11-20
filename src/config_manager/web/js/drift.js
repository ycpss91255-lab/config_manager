// W5 差異檢視與處置（#30、#31）、未部署的寫出修復（#306）。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, Refused, apiFetch, editFetch, failureText } from "./api.js";
import { element } from "./dom.js";
import { applyDraftsView, draftUids } from "./drafts.js";
import { load, loadErrorText, rows } from "./tree.js";
import { TYPE_LABEL, mountView, openPanel, panelDetails } from "./workspace.js";
import { displayValue, paramRows, problemText, renderSaveError } from "./params.js";
import { confirmAction, isBusy, whileBusy } from "./dialogs.js";
import {
  clearPromoteBanners, clearedSentence, promoteDoneEl, reloadAfterFailure,
} from "./promote.js";

// ── W5 差異檢視（#30）────────────────────────────────────────────────────────
// 只在偏離時出現（§7.7、ADR-00000008）：橫幅只說目標與來源不同、僅憑差異無法判定原因（#345：回滾沒能
// 還原時也會偏離，不斷言是介面外修改，也不斷言沒有紀錄與作者）；主區域是
// 來源（repo，唯一真實來源）與目標（磁碟現況）的並排參數比對——使用者要做的是「判斷哪一邊是對的」，
// 並排比合併差異更貼這個決策。呈現與 W4 歷史差異同一套（參數為單位、同樣的 data-change 與顏色）；
// 比對方式不同：這裡不帶每個值各自的型別（paramDiff 的 byType）。
// 處置的三個按鈕是 #31。
export function driftBanner(detail, withEntry) {
  const banner = element("div", { class: "notice error drift-banner", "data-testid": "drift-banner" }, [
    element("strong", { text: "偏離" }),
    element("p", {
      text: "目標內容與來源不同；僅憑差異無法判定原因，請比對兩邊及相關紀錄，再決定保留哪一邊。",
    }),
  ]);
  if (withEntry) {
    // 差異與處置確認比的要是**現在**的目標（F32）：區塊可能是在一致時打開、之後才在
    // 清單重載時變偏離（F31 的同步只換標頭與橫幅），手上那份單筆內容是打開當時的。
    // 按下先重讀再開差異檢視。
    const error = element("div", {
      class: "notice error", "data-testid": "panel-diff-error", hidden: "",
    });
    const open = element("button", {
      type: "button", "data-testid": "panel-diff", text: "檢視差異",
    });
    open.addEventListener("click", () => whileBusy(
      open, "讀取中…", () => openCurrentDiff(detail.uid, error),
    ));
    banner.appendChild(element("div", { class: "actions" }, [open]));
    banner.appendChild(error);
  }
  return banner;
}

export async function openCurrentDiff(uid, errorEl) {
  errorEl.hidden = true;
  try {
    const response = await apiFetch(`${API_BASE}/api/configs/${encodeURIComponent(uid)}`);
    if (!response.ok) throw new Refused(await loadErrorText(response));
    const fresh = await response.json();
    panelDetails.set(uid, fresh);
    openDiffView(fresh);
  } catch (error) {
    renderSaveError(errorEl, failureText("讀取目標現況", error));
    errorEl.hidden = false;
  }
}

// 判不出狀態（F5、人工驗收 U18）：區塊裡也寫出原因與下一步。用的是清單給的那一句（帶下一步）；
// 單筆內容另有一句讀目標的錯誤（`target_error`），只有 errno、沒有下一步，給差異檢視用。
export function errorBanner(reason) {
  return element("div", { class: "notice error error-banner", "data-testid": "error-banner" }, [
    element("strong", { text: "判不出狀態：這一份現在無法和來源比對。" }),
    element("pre", { text: reason }),
  ]);
}

// ── 未部署的寫出修復（#306；後端 #29、設計 §5.4）───────────────────────────────
// 目標檔案不在了（被刪、被搬走）：說明是哪個路徑，給「寫出到目標」把來源內容與記下的權限寫回去。
// 設定庫不變、不留紀錄——按之前就寫在這裡。只在**未部署**時出現：偏離是目標「在、但不一樣」，
// 那要人判斷哪一邊對（差異檢視的三個處置），不是一鍵蓋掉。
export function missingBanner(detail) {
  const error = element("div", { class: "notice error", "data-testid": "apply-error", hidden: "" });
  const apply = element("button", { type: "button", "data-testid": "panel-apply", text: "寫出到目標" });
  apply.addEventListener("click", () => whileBusy(apply, "寫出中…", () => applyMissing(detail, error)));
  return element("div", { class: "notice missing-banner", "data-testid": "missing-banner" }, [
    element("strong", { text: "未部署：目標檔案不存在。" }),
    element("p", {
      text: `設定庫裡有這份 config 的來源，但 ${detail.target} 這個位置沒有檔案（可能被刪除或搬走）。`
        + "按「寫出到目標」會把來源內容與記下的權限寫回這個位置；設定庫不變，所以不會多一筆變更紀錄。",
    }),
    error,
    element("div", { class: "actions editing-only" }, [apply]),
  ]);
}

// 畫面上的「未部署」是上一次比對的結果。按下時先重新比對：這段時間目標要是出現了，就不送——
// 換成現況，並依現在的狀態說下一步（偏離去看差異、一致不必處理）。真正擋住覆蓋的是後端：目標
// 已存在它一律 409、不寫（寫出修復不留紀錄，不能蓋掉現場的內容）；這裡只是讓人少碰一次壁。
export function noLongerMissing(detail, fresh) {
  if (!fresh) {
    return `「${detail.name}」已經不在清單裡（可能已被解除納管），所以沒有寫出。`
      + "下一步：看左側的清單確認現況。";
  }
  if (fresh.error) {
    return `目標現在判不出狀態（${fresh.error}），所以沒有寫出。下一步：先排除這個原因，再按「檢查差異」。`;
  }
  if (fresh.state === "drift") {
    return `目標檔案已經存在（${detail.target}），而且內容與來源不同，所以沒有寫出——照寫會不留紀錄地`
      + "蓋掉現場的內容。下一步：按「檢視差異」比對兩邊，再決定以來源覆蓋或把現況納入來源。";
  }
  if (fresh.state === "in_sync") {
    return `目標檔案已經存在（${detail.target}），而且與來源一致，不需要寫出。下一步：不必處理，畫面已是現況。`;
  }
  return null;
}

export async function applyMissing(detail, errorEl) {
  errorEl.hidden = true;
  try {
    const listing = await apiFetch(`${API_BASE}/api/configs`);
    if (!listing.ok) throw new Refused(await loadErrorText(listing));
    const changed = noLongerMissing(detail, (await listing.json()).find((row) => row.uid === detail.uid));
    if (changed) {
      await load();  // 樹先換成現況，重畫的區塊才認得新的狀態
      openPanel(detail.uid, element("div", {
        class: "notice error", "data-testid": "apply-error",
      }, [element("strong", { text: changed })]));
      return;
    }
    clearPromoteBanners();  // F38：重新比對後真的要寫出才收起上一個結果
    const response = await editFetch(`${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}/apply`, {
      method: "POST",
    });
    const payload = await response.json();
    if (!response.ok) {
      renderSaveError(errorEl, payload.detail);  // 後端的原因（哪個路徑、為什麼、下一步）原樣顯示
      return;
    }
    promoteDoneEl.textContent = `已把「${detail.name}」的來源寫出到 ${payload.target}，狀態回到一致。`
      + "設定庫沒有改變，所以沒有變更紀錄。" + clearedSentence(payload.left_behind_cleared);
    promoteDoneEl.hidden = false;
    await load();
    openPanel(detail.uid);
  } catch (error) {
    renderSaveError(errorEl, failureText("寫出到目標", error));
  }
}

// 兩棵值樹以參數為單位比：same／changed／added（右邊有、左邊沒有）／removed（左邊有、右邊沒有）。
// W4（這一筆之前 vs 之後、目前 vs 退回後）與 W5（來源 vs 目標）共用，顏色語言因此一致。
// `byType`（W4，F10）：兩邊都帶後端從各自內容推斷的「每個值各自的型別」（`leaf_types`，鍵是實際
// 路徑 `w[0]`），顯示與比對都用它——清單元素共用的合併型別（`w[]`）會把沒動的那格算成改了、也看不出
// `1 → 1.0`。型別不同也算改了：數字 5 變成字串 "5" 顯示出來的字一樣，不比型別就看不出來；顯示時
// 在值後面標出型別。W5 的左邊帶人工指定的型別，不比。
export function paramDiff(left, right, byType = false) {
  const leaves = (payload) => new Map(
    paramRows({ types: payload.types || {}, values: payload.values || {}, draft_values: null })
      .filter((row) => !row.container)
      .map((row) => {
        const type = byType ? (payload.leaf_types || {})[row.path] || row.type : row.type;
        return [row.path, { text: displayValue(row.value, type), type }];
      }),
  );
  const older = leaves(left);
  const current = leaves(right);
  const paths = [...current.keys(), ...[...older.keys()].filter((path) => !current.has(path))];
  return paths.map((path) => {
    const before = older.get(path);
    const after = current.get(path);
    let change = "same";
    if (before === undefined) change = "added";
    else if (after === undefined) change = "removed";
    else if (before.text !== after.text || (byType && before.type !== after.type)) change = "changed";
    const retyped = byType && before && after && before.type !== after.type;
    const shown = (leaf) => leaf && (retyped ? `${leaf.text}（${TYPE_LABEL[leaf.type] || leaf.type}）` : leaf.text);
    return { path, from: shown(before), to: shown(after), change };
  });
}

export function diffRow(row, fromTestid, toTestid, separator) {
  return element("li", { class: "diff-row", "data-testid": `diff-row-${row.path}`, "data-change": row.change }, [
    element("span", { class: "diff-name", text: row.path.replace(/\\\./g, ".") }),
    element("span", { class: "diff-from", "data-testid": fromTestid, text: row.from === undefined ? "（無）" : row.from }),
    element("span", { text: separator }),
    element("span", { class: "diff-to", "data-testid": toTestid, text: row.to === undefined ? "（無）" : row.to }),
  ]);
}

export function openDiffView(detail) {
  const back = element("button", { type: "button", "data-testid": "diff-back", text: "返回欄位表" });
  back.addEventListener("click", () => openPanel(detail.uid));
  const view = element("section", { class: "panel", "data-testid": `diff-${detail.uid}` }, [
    element("div", { class: "panel-head" }, [
      element("span", { class: "name", text: `差異檢視　${detail.name}` }),
      element("span", { class: "target", text: detail.target }),
      back,
    ]),
    driftBanner(detail, false),
  ]);
  if (detail.target_error) {
    view.appendChild(element("div", { class: "notice error", "data-testid": "diff-target-error" }, [
      element("strong", { text: "目標現況無法比對。" }),
      element("pre", { text: detail.target_error }),
    ]));
  } else {
    // 左＝來源（repo，唯一真實來源）、右＝目標（磁碟現況）：來源在 paramDiff 的 left。
    const rows = paramDiff(
      { types: detail.types, values: detail.values },
      { types: infer(detail.target_values), values: detail.target_values },
    );
    const differing = rows.filter((row) => row.change !== "same").length;
    view.append(
      element("p", {
        class: "diff-summary", "data-testid": "diff-summary",
        text: `${differing} 個參數不同（左邊是 repo 的來源，右邊是目標的磁碟現況）`,
      }),
      element("div", { class: "diff-head" }, [
        element("span", { class: "diff-name", text: "參數" }),
        element("span", { class: "diff-side", "data-testid": "diff-source", text: "repo（唯一真實來源）" }),
        element("span", { class: "diff-side", "data-testid": "diff-target", text: "target（磁碟現況）" }),
      ]),
      element("ul", { class: "param-table" }, rows.map((row) => diffRow(row, "diff-source-value", "diff-target-value", "｜"))),
    );
  }
  view.appendChild(resolveActions(detail, view));
  mountView(detail.uid, view, "diff");
}

// ── W5 三種處置（#31、§5.4、A3）──────────────────────────────────────────────
// 偏離不自動處置（設計原則 N-2）：三個相反方向的出口由人選，後果在按下之前就寫在按鈕旁。
// 覆蓋與先納入不可逆（丟掉現場改動／載入的草稿要人接手）→ W6 確認；納入走完整驗證，含非法值被拒。
export const RESOLVE_OPTIONS = [
  {
    action: "overwrite", label: "以來源覆蓋目標", testid: "resolve-overwrite",
    why: "現場改動是不該保留的臨時測試：把 repo 的來源寫回目標、捨棄現場修改；記一筆紀錄。",
    confirm: [
      "以來源覆蓋目標？",
      "目標檔案會被 repo 的來源覆蓋，現場的修改全部丟掉，無法復原；會記一筆變更紀錄。",
      "以來源覆蓋",
    ],
  },
  {
    action: "adopt", label: "將目標現況納入來源", testid: "resolve-adopt",
    why: "現場改動是有效的調整：走完整驗證後成為來源、記一筆採納紀錄；含非法值會被拒。",
    // F13（10/31 定案 D1）：採納會改設定庫的來源，和覆蓋、先納入一樣先確認——內文說會改什麼、
    // 這份有沒有草稿；項目逐項列「來源 → 現況」（和差異檢視同一套比對）。
    confirm: (detail) => adoptConfirmation(detail),
  },
  {
    action: "adopt_draft", label: "先納入、待修正", testid: "resolve-adopt-draft",
    why: "現場改動含非法值但不該丟：載入草稿供修正，進版前須改正；來源與目標都先不動。",
    confirm: [
      "先納入、待修正？",
      "目標現況會載入為這份 config 的草稿（覆蓋既有草稿），非法值以警告標示，進版前須改正。"
        + "來源與目標都先不動；不要了可以捨棄這份草稿。",
      "先納入",
    ],
  },
];

export function resolveActions(detail, view) {
  const error = element("div", { class: "notice error resolve-error", "data-testid": "resolve-error" });
  error.hidden = true;
  const options = RESOLVE_OPTIONS.map((option) => {
    const button = element("button", { type: "button", "data-testid": option.testid, text: option.label });
    button.addEventListener("click", () => resolveDrift(detail, option, view, error, button));
    return element("div", { class: "resolve-option" }, [button, element("span", { class: "why", text: option.why })]);
  });
  return element("div", {}, [error, element("div", { class: "resolve-actions editing-only" }, options)]);
}

// 採納的確認框內容（F13）：差異列和差異檢視同一套 `paramDiff`（來源 vs 磁碟現況）；草稿影響看樹上的草稿標記。
export function adoptConfirmation(detail) {
  const target = { types: infer(detail.target_values), values: detail.target_values };
  const rows = paramDiff(detail, target).filter((row) => row.change !== "same");
  const drafts = draftUids.has(detail.uid)
    ? "這份目前有 1 份未進版草稿：草稿留著，但它比對的來源值會換成現況。"
    : "這份目前沒有未進版草稿。";
  return [
    "將目標現況納入來源？",
    `設定庫的來源會被改成目標現況：repo 會多一筆「採納現場調整」紀錄、作者是你；目標檔本身不變。${drafts}`,
    "納入來源",
    rows.map((row) => `${row.path.replace(/\\\./g, ".")}：來源 ${row.from === undefined ? "（無）" : row.from}`
      + ` → 現況 ${row.to === undefined ? "（無）" : row.to}`),
  ];
}

export async function resolveDrift(detail, option, view, errorEl, button) {
  if (isBusy(button)) return;
  if (option.confirm) {
    const spec = typeof option.confirm === "function" ? option.confirm(detail) : option.confirm;
    const ok = await confirmAction(...spec);
    if (!ok) return;
  }
  await whileBusy(button, "處理中…", async () => {
    errorEl.hidden = true;
    clearPromoteBanners();  // F38：確認後送出就收起上一個結果，不等成功
    for (const button of view.querySelectorAll(".resolve-actions button")) button.disabled = true;
    try {
      const response = await editFetch(`${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}/resolve`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ action: option.action }),
      });
      const payload = await response.json();
      if (!response.ok) {
        // 422（納入：現況含非法值，列行號／原因／建議並指去先納入待修正）／409／500：原樣顯示，差異區保留。
        renderSaveError(errorEl, payload.detail);
        await reloadAfterFailure();  // #345：重新比對清單與標示（差異區不重畫，原因留著）
        return;
      }
      if (option.action === "adopt_draft") {
        applyDraftsView(payload);
        // 來源與目標都沒動，狀態本來就仍是偏離，不必重掃；等欄位表換上，finally 才放開處置按鈕
        await openPanel(detail.uid, adoptDraftNotice(payload.warnings));
        return;
      }
      promoteDoneEl.textContent = (option.action === "overwrite"
        ? `已以來源覆蓋「${detail.name}」的目標，並記一筆變更紀錄。`
        : `已將「${detail.name}」的目標現況納入來源（採納現場調整），並寫出。`)
        + clearedSentence(payload.left_behind_cleared);
      promoteDoneEl.hidden = false;
      // 覆蓋／納入後狀態回到一致：樹先換成現況，重畫的區塊才認得新的狀態。欄位表的狀態與偏離橫幅讀的
      // 是清單——不等重掃就重開，內容先回來時欄位表會照舊清單寫「偏離」（人工驗收 U27、U28，F12）。
      // 也等重開完才讓 finally 放開處置按鈕。
      await load();
      await openPanel(detail.uid);
    } catch (error) {
      renderSaveError(errorEl, failureText("處置偏離", error));
    } finally {
      for (const button of view.querySelectorAll(".resolve-actions button")) button.disabled = false;
    }
  });
}

export function adoptDraftNotice(warnings) {
  const notice = element("div", {
    class: warnings.length ? "notice error" : "notice", "data-testid": "adopt-draft-notice",
  }, [
    element("strong", {
      text: warnings.length
        ? `目標現況已載入為草稿，含 ${warnings.length} 個問題——進版前須改正（整批進版會被擋）。`
        : "目標現況已載入為草稿，沒有發現問題；儲存或進版即可。",
    }),
  ]);
  if (warnings.length) {
    notice.appendChild(element("ul", {}, warnings.map((problem) => element("li", {
      text: problemText(problem),
    }))));
  }
  return notice;
}

// 目標現況沒有型別表（型別由來源推斷、不由前端猜）：只借來源的型別表走訪路徑，來源沒有的欄位
// 以值的樣子給個粗略型別讓它顯示得出來——這裡只是「顯示」，不是判定。
export function infer(values) {
  const out = {};
  const walk = (value, path) => {
    if (path) out[path] = value === null ? "null" : Array.isArray(value) ? "list" : typeof value === "object" ? "dict" : typeof value === "boolean" ? "bool" : typeof value === "number" ? (Number.isInteger(value) ? "int" : "float") : "string";
    if (value && typeof value === "object" && !Array.isArray(value)) {
      for (const [key, child] of Object.entries(value)) walk(child, path ? `${path}.${String(key).replace(/\./g, "\\.")}` : String(key).replace(/\./g, "\\."));
    } else if (Array.isArray(value)) {
      value.forEach((child) => walk(child, `${path}[]`));
    }
  };
  walk(values || {}, "");
  return out;
}
