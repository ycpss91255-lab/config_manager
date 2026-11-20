// W4 歷史（#25／#26）：變更紀錄、差異、退回此版本。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, Refused, apiFetch, editFetch, failureText } from "./api.js";
import { element } from "./dom.js";
import { load, loadErrorText, rows } from "./tree.js";
import { mountView, openPanel } from "./workspace.js";
import { diffRow, infer, paramDiff } from "./drift.js";
import { confirmAction, isBusy, whileBusy } from "./dialogs.js";
import { clearPromoteBanners, clearedSentence, reloadAfterFailure } from "./promote.js";
import { detailText } from "./whitelist.js";

// ── W4 歷史（#25／#26）───────────────────────────────────────────────────────
// 使用者看到的是行為，不是代號（§7.6.1）：內部類型只在這張表裡對應成中文，列表上不出現
// cfg／revert／import 這些字。左列表／右差異（圖 13）；差異以參數為單位（§7.6.2）：哪個參數從什麼
// 變成什麼，與 W3 的欄位表語言、顏色一致（改動＝偏離紅）。點一筆看的是「那一次改了什麼」（這一筆
// 寫入之前 → 之後，人工驗收 U25 的回歸，F10）；「退回會改什麼」（目前 → 退回後）另外寫成一行字、
// 確認框逐項列——「目前版本」＝來源複本現況。
export const KIND_TEXT = {
  import: "納入管理", cfg: "修改參數", revert: "退回舊版本",
  adopt: "採納現場調整", meta: "調整設定", unmanage: "解除管理",
};
export const ALL_KINDS = Object.keys(KIND_TEXT).join(",");
export const PICK_A_CHANGE = "選一筆變更，這裡顯示那一次改了什麼（以參數為單位）。";
export let historyGeneration = 0;

export function formatTime(iso) {
  const parsed = new Date(iso);
  return Number.isNaN(parsed.getTime()) ? iso : parsed.toLocaleString("zh-TW", { hour12: false });
}

// 行為描述之外的說明：退回舊版本附「退回到哪一版」（§7.6.1），其餘直接用紀錄的說明。
export function describeChange(change) {
  if (change.kind === "revert") {
    const matched = /rollback to ([0-9a-f]+)/.exec(change.summary);
    if (matched) return `退回到版本 ${matched[1]}`;
  }
  return change.summary;
}

export function openHistory(detail, notice) {
  const generation = ++historyGeneration;
  const back = element("button", { type: "button", "data-testid": "history-back", text: "返回欄位表" });
  back.addEventListener("click", () => openPanel(detail.uid));
  const filter = element("div", { class: "history-filter", "data-testid": "history-filter", role: "group" }, [
    element("button", { type: "button", "data-filter": "content", "aria-pressed": "true", text: "只看內容變更" }),
    element("button", { type: "button", "data-filter": "all", "aria-pressed": "false", text: "全部" }),
  ]);
  const view = element("section", { class: "panel history", "data-testid": `history-${detail.uid}` }, [
    element("div", { class: "panel-head" }, [
      element("span", { class: "name", text: `歷史　${detail.name}` }),
      element("span", { class: "target", text: detail.target }),
      back,
    ]),
    filter,
    element("p", { class: "notice", "data-testid": "history-notice", text: notice || "" }),
    element("div", { class: "history-body" }, [
      element("ul", { class: "history-list", "data-testid": "history-list" }),
      element("div", { class: "history-diff", "data-testid": "history-diff" }, [
        element("p", { class: "notice", text: PICK_A_CHANGE }),
      ]),
    ]),
  ]);
  filter.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-filter]");
    if (!button) return;
    for (const option of filter.querySelectorAll("button[data-filter]")) {
      option.setAttribute("aria-pressed", String(option === button));
    }
    // 列表重畫後沒有選取的那一筆：差異區回到初始說明，不留著照舊篩選寫的「前一筆被篩掉」。
    const diff = view.querySelector("[data-testid='history-diff']");
    delete diff.dataset.sha;
    diff.replaceChildren(element("p", { class: "notice", text: PICK_A_CHANGE }));
    loadHistory(view, detail, button.dataset.filter, ++historyGeneration);
  });
  view.querySelector("[data-testid='history-notice']").hidden = !notice;
  mountView(detail.uid, view, "history");
  loadHistory(view, detail, "content", generation);
}

export async function loadHistory(view, detail, filter, generation) {
  const list = view.querySelector("[data-testid='history-list']");
  list.replaceChildren(element("li", { class: "notice", text: "載入中…" }));
  const query = filter === "all" ? `?prefix=${ALL_KINDS}` : "";
  try {
    const response = await apiFetch(`${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}/history${query}`);
    if (!response.ok) throw new Refused(await loadErrorText(response));
    const changes = await response.json();
    if (generation !== historyGeneration) return;
    list.replaceChildren(...changes.map((change) => historyEntry(change, detail, view)));
    if (!changes.length) {
      list.appendChild(element("li", {
        class: "notice", "data-testid": "history-empty",
        text: filter === "all"
          ? "這份 config 還沒有任何變更紀錄。"
          : "這份 config 納管後還沒有改過內容，所以沒有內容變更的紀錄。"
            + "下一步：切到「全部」可看到其他類型（納入管理、調整設定…）。",
      }));
    } else if (filter === "all" && changes.length === 1) {
      // 只有一筆（通常就是納入管理那一筆）：說明為什麼沒有東西可比、可退，不讓人對著一筆紀錄找按鈕。
      list.appendChild(element("li", {
        class: "notice", "data-testid": "history-single",
        text: "目前只有這一筆紀錄——還沒有更早的版本可以比較或退回。修改並進版之後，這裡會多出新的紀錄。",
      }));
    }
  } catch (error) {
    if (generation !== historyGeneration) return;
    list.replaceChildren(element("li", { class: "notice error", "data-testid": "history-error" }, [
      element("strong", { text: "讀不到變更歷史。" }),
      element("pre", { text: failureText("讀取變更歷史", error) }),
    ]));
  }
}

export function historyEntry(change, detail, view) {
  const author = change.author.replace(/\s*<[^>]*>$/, "");  // 列表只顯示姓名；email 在 title
  const node = element("li", {
    class: "history-entry", "data-testid": `history-entry-${change.sha}`, "aria-selected": "false",
  }, [
    element("span", { class: "history-kind", text: KIND_TEXT[change.kind] || "變更" }),
    element("span", { class: "history-summary", text: describeChange(change) }),
    element("span", { class: "history-meta" }, [
      element("span", { "data-testid": "history-author", text: author, title: change.author }),
      element("time", { "data-testid": "history-time", datetime: change.at, text: formatTime(change.at) }),
    ]),
  ]);
  if ((change.drafted_by || []).length) {
    // 這一筆的草稿由別人存（ADR-00000032）：author 是進版者，另寫出誰編輯了草稿。
    const names = change.drafted_by.map((who) => (
      who.another_browser ? `〈${who.name}（另一個瀏覽器身分）〉` : `〈${who.name}〉`
    ));
    node.appendChild(element("span", {
      class: "history-drafted-by", "data-testid": "history-drafted-by",
      text: `含${names.join("、")}存的草稿`,
    }));
  }
  if ((change.overrides || []).length) {
    // 這一筆略過了哪些規則、理由是什麼（#42／#45）：理由出現在變更紀錄中，不只在 commit 內文。
    node.appendChild(element("ul", { class: "history-overrides", "data-testid": "history-overrides" },
      change.overrides.map((item) => element("li", { text: `略過規則 ${item.rule}：${item.reason}` }))));
  }
  node.addEventListener("click", () => selectChange(view, detail, change, node));
  return node;
}

export async function selectChange(view, detail, change, node) {
  const generation = ++historyGeneration;
  for (const entry of view.querySelectorAll("li[data-testid^='history-entry-']")) {
    entry.setAttribute("aria-selected", String(entry === node));
  }
  const diff = view.querySelector("[data-testid='history-diff']");
  delete diff.dataset.sha;
  diff.replaceChildren(element("p", { class: "notice", text: "載入中…" }));
  try {
    const url = `${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}/history/${change.sha}`;
    const response = await apiFetch(url);
    if (!response.ok) throw new Refused(await loadErrorText(response));
    const version = await response.json();
    if (generation !== historyGeneration) return;
    renderDiff(diff, version, detail, view, change);
  } catch (error) {
    if (generation !== historyGeneration) return;
    diff.replaceChildren(element("div", { class: "notice error", "data-testid": "history-diff-error" }, [
      element("strong", { text: "讀不到這一版的內容。" }),
      element("pre", { text: failureText("讀取這一版的內容", error) }),
    ]));
  }
}

// 那一次改了什麼，以參數為單位（§7.6.2）：這一筆寫入之前（左）→ 之後（右），same／changed／
// added（之前沒有）／removed（之後沒有）。前後兩邊的型別都由後端從各自的內容推斷（F10）：人工指定
// 不算改了，內容裡的型別真的變了（整數變小數、數字變字串）照樣算。
export function renderDiff(target, version, detail, view, change) {
  target.dataset.sha = version.sha;
  const parts = [];
  if (version.previous) {
    const compared = paramDiff(version.previous, version, true);
    const changed = compared.filter((row) => row.change !== "same").length;
    if (changed) {
      parts.push(element("p", {
        class: "diff-summary", "data-testid": "history-diff-summary",
        text: `這一筆改了 ${changed} 個參數（左邊是改之前，右邊是這一筆之後）`,
      }));
    } else {
      parts.push(element("p", { class: "notice", "data-testid": "history-diff-note", text: unchangedText(change) }));
    }
    const hidden = hiddenPreceding(view, version.preceding);
    if (hidden) parts.push(hidden);
    parts.push(element("ul", {}, compared.map((row) => diffRow(row, "diff-from", "diff-to", "→"))));
  } else if (version.previous_error) {
    parts.push(element("div", { class: "notice error", "data-testid": "history-diff-note" }, [
      element("strong", { text: "算不出這一筆改了什麼：前一版讀不到。" }),
      element("pre", { text: version.previous_error }),
    ]));
  } else {
    parts.push(element("p", {
      class: "notice", "data-testid": "history-diff-note",
      text: "這是第一筆（納入管理），沒有更早的版本可比。",
    }));
  }
  parts.push(revertSection(view, detail, version));
  target.replaceChildren(...parts);
}

// 以來源覆蓋目標只記一筆空的「修改參數」（io/drift.py 的 OVERWRITE_SUMMARY）：設定庫沒變、目標被改回來源。
export const OVERWRITE_SUMMARY = "以來源覆蓋目標（捨棄現場修改）";
// 以來源重新寫出（#345）也只記一筆空的「修改參數」（io/drift.py 的 REWRITE_SUMMARY）。
export const REWRITE_SUMMARY = "以來源重新寫出目標（照清單重設擁有者與權限）";

// 參數值沒變的那一筆在做什麼：不留白，不讓人以為壞掉或什麼都沒做。
export function unchangedText(change) {
  if (change.kind === "meta") return "參數值沒變：這一筆改的是屬性或 schema（含型別指定）。";
  if (change.summary === REWRITE_SUMMARY) {
    return "參數值沒變：設定庫的內容沒變，這一筆是照清單重新寫出機器上的目標檔、重設擁有者與權限；"
      + "不代表回到進版前的擁有者與權限。";
  }
  if (change.summary === OVERWRITE_SUMMARY) {
    return "參數值沒變：設定庫的內容沒變，這一筆是把機器上的目標檔改回來源內容；被蓋掉的現場值沒有紀錄。";
  }
  return "參數值沒變。";
}

// 緊鄰的前一筆紀錄不在目前的篩選裡（例如前一筆是調整設定）：可見的紀錄前後值會接不起來，說清楚。
export function hiddenPreceding(view, preceding) {
  if (!preceding || view.querySelector(`[data-testid='history-entry-${preceding.sha}']`)) return null;
  return element("p", {
    class: "notice", "data-testid": "history-hidden-preceding",
    text: `上一筆紀錄是「${KIND_TEXT[preceding.kind] || "變更"}」（${preceding.sha.slice(0, 7)}），`
      + "目前的篩選沒有列出；這裡的「改之前」是那一筆之後的內容。切到「全部」可以看到它。",
  });
}

// 退回會改什麼（#27、§5.3 圖 7、§7.1 原則 2）：目前 → 退回後。一行看得到的字（唯讀也看得到，
// 不只放在滑鼠停留的提示裡）；「退回此版本」只在編輯中出現，不可逆 → W6 確認框逐項列出。
export function revertSection(view, detail, version) {
  const changes = paramDiff(version.current, version, true).filter((row) => row.change !== "same");
  const effect = changes.length
    ? `退回這一版會改變 ${changes.length} 個參數。`
    : "這一版的參數就是目前的內容，沒有東西可退。";
  const revertButton = element("button", {
    type: "button", class: "editing-only", "data-testid": "history-revert", text: "退回此版本",
  });
  revertButton.disabled = changes.length === 0;
  revertButton.title = changes.length === 0 ? effect : "";
  revertButton.addEventListener("click", () => revertTo(view, detail, version, changes, revertButton));
  return element("div", { class: "revert-section" }, [
    element("p", { class: "revert-effect", "data-testid": "history-revert-effect", text: effect }),
    element("div", { class: "panel-actions" }, [
      element("span", {
        class: "hint",
        text: "退回＝內容回到這一筆完成後的樣子（不是撤銷這一筆）。退版會產生一筆新的變更紀錄並寫出到目標；"
          + "歷史不會被改寫，之後仍可再退。",
      }),
      revertButton,
    ]),
  ]);
}

// 退版時 schema 跟著回到那一版（#39 的定案）。會改到開發者設的限制，所以確認框先說、完成後再說一次，
// 不讓它悄悄發生。沒有影響（null）就不提。
export const SCHEMA_EFFECT_TEXT = {
  restore: "這份的 schema 也會回到那一版當時的內容——之後才加上的限制會一併退掉。",
  remove: "那一版當時還沒有 schema：退回後這份不再有 schema，修改不再依它檢查。",
};
export const SCHEMA_DONE_TEXT = {
  restore: "schema 也回到了那一版當時的內容。",
  remove: "這份現在沒有 schema。",
};

// 退版確認框先看機器上的現況（F21，10/31 定案 C1）：按下當下重讀單筆內容，不信清單列的狀態。
// 目標與來源不同 → 紅字提醒現場修改會被蓋掉、項目多一欄「現況」；讀不到／解析不了／太大 → 明說無法確認，
// 不當成沒有偏離；不存在 → 說會寫出。一律註明是當下快照：確認到執行之間若有人改動，這裡看不到。
// 回 { warning, note, drift }：warning 是要標紅的獨立段落（前兩種），note 接在內文裡（未部署）。
export async function describeTargetBeforeRevert(detail) {
  const response = await apiFetch(`${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}`);
  if (!response.ok) throw new Refused(await loadErrorText(response));
  const fresh = await response.json();
  if (fresh.target_error) {
    return {
      warning: `⚠ 無法確認機器上的現況（${fresh.target_error}）。退版會照樣寫出，可能蓋掉看不到的現場修改。`,
      note: "", drift: new Map(),
    };
  }
  if (fresh.target_values === null || fresh.target_values === undefined) {
    return { warning: "", note: "目標目前不存在（未部署），退版會把它寫出。", drift: new Map() };
  }
  const rows = paramDiff(fresh, { types: infer(fresh.target_values), values: fresh.target_values })
    .filter((row) => row.change !== "same");
  if (!rows.length) return { warning: "", note: "", drift: new Map() };
  return {
    warning: `⚠ 機器上這份檔目前和來源不同（有 ${rows.length} 個參數的現場修改），退版會把它一起蓋掉；要保留請先走偏離處置。`,
    note: "",
    drift: new Map(rows.map((row) => [row.path, row.to === undefined ? "（無）" : row.to])),
  };
}

export async function revertTo(view, detail, version, changes, button) {
  if (isBusy(button)) return;
  const short = version.sha.slice(0, 7);
  let target;
  try {
    target = await describeTargetBeforeRevert(detail);
  } catch (error) {
    view.querySelector("[data-testid='history-diff']").prepend(element("div", { class: "notice error", "data-testid": "history-revert-error" }, [
      element("strong", { text: "沒有退版。" }),
      element("pre", { text: failureText("重讀目標現況", error) }),
    ]));
    return;
  }
  const ok = await confirmAction(
    "退回此版本？",
    `「${detail.name}」會回到版本 ${short} 完成後的內容：下面 ${changes.length} 個參數會從目前的值改成退回後的值，`
      + "並寫出到目標。這會產生一筆新的變更紀錄；歷史不會被改寫，之後仍可再退。"
      + (SCHEMA_EFFECT_TEXT[version.schema_effect] || "")
      + (target.note ? ` ${target.note}` : "")
      + " 以上是確認當下的快照，之後到執行之間若有人改動不在此列。",
    "退回此版本",
    changes.map((row) => {
      const path = row.path.replace(/\\\./g, ".");
      const now = row.from === undefined ? "（無）" : row.from;
      const live = target.drift.has(row.path) ? ` ／ 現況 ${target.drift.get(row.path)}` : "";
      return `${path}：目前 ${now}${live} → 退回後 ${row.to === undefined ? "（無）" : row.to}`;
    }),
    target.warning,
  );
  if (!ok) return;
  await whileBusy(button, "退版中…", async () => {
    const diff = view.querySelector("[data-testid='history-diff']");
    clearPromoteBanners();  // F38：退版的結果寫在歷史區，上方不再留著前一個動作的訊息
    try {
      const response = await editFetch(`${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}/revert`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ version: version.sha }),
      });
      const payload = await response.json();
      if (!response.ok) {
        // 409（有未進版草稿）／422／500：原樣顯示後端的原因與下一步，差異區保留讓人重看。
        diff.prepend(element("div", { class: "notice error", "data-testid": "history-revert-error" }, [
          element("strong", { text: "沒有退版。" }),
          element("pre", { text: detailText(payload.detail) }),
        ]));
        reloadAfterFailure();  // #345：重新比對清單與標示（歷史區不重畫，原因留著）
        return;
      }
      // 目前版本變了：重抓單筆內容、重開歷史（列表多一筆退回舊版本），左側樹重掃狀態。
      load();
      const fresh = await apiFetch(`${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}`);
      const freshDetail = fresh.ok ? await fresh.json() : detail;
      openHistory(freshDetail, `已退回到版本 ${short}，並寫出到目標。${SCHEMA_DONE_TEXT[payload.schema_effect] || ""}`
        + clearedSentence(payload.left_behind_cleared));
    } catch (error) {
      diff.prepend(element("div", { class: "notice error", "data-testid": "history-revert-error" }, [
        element("strong", { text: "沒有退版。" }),
        element("pre", { text: failureText("退回此版本", error) }),
      ]));
    }
  });
}
