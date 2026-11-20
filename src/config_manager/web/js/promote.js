// 進版與捨棄變更（#22）、「未還原」（#345）。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, editFetch, failureText, readJson } from "./api.js";
import { element } from "./dom.js";
import {
  applyDraftsView, draftDetails, draftParticipants, draftUids, loadDrafts, ownerLabel,
  setDraftDetails, setDrafts,
} from "./drafts.js";
import { load, loadError, rows } from "./tree.js";
import { closeSlot, openPanel, openUids } from "./workspace.js";
import { renderSaveError } from "./params.js";
import { confirmAction, isBusy, whileBusy } from "./dialogs.js";

export const promoteButton = document.querySelector("[data-testid='promote-all']");
export const discardAllButton = document.querySelector("[data-testid='discard-all']");
export const promoteErrorEl = document.querySelector("[data-testid='promote-error']");
export const promoteDoneEl = document.querySelector("[data-testid='promote-done']");
// 「未還原」（#345）：上方的獨立警示、讀不到標示、寫入失敗後重讀清單也失敗。三者都不是普通結果訊息，
// clearPromoteBanners 不收；只有標示真的收起、或重新讀取成功時才收。
export const leftBehindWarningEl = document.querySelector("[data-testid='left-behind-warning']");
export const leftBehindUnreadableEl = document.querySelector("[data-testid='left-behind-unreadable']");
export const statusNotUpdatedEl = document.querySelector("[data-testid='status-not-updated']");
export let leftBehind = { targets: [], repo: null };  // GET /api/left-behind 的最近一次結果

// ── 「未還原」（#345）──────────────────────────────────────────────────────────
// 寫入操作失敗、回滾時某份目標的還原步驟失敗的**診斷標示**，不是新的狀態（狀態照舊只由內容比對決定，
// 所以可能是「偏離＋未還原」或「一致＋未還原」）。還原步驟失敗＝可能留下部分變更，不是證明內容都沒還原。
// 設定庫沒能完整退回、或回滾結果無法確認，記在設定庫那一筆，不標在任何一份上。標示由後端記、放在服務
// 的記憶體（未持久化）：每次讀清單都一起重讀，畫面不自己猜、也不自己收。
export const REPO_RESULT_TEXT = { not_restored: "沒能完整退回", unconfirmed: "結果無法確認" };

export function whenText(at) {
  return new Date(at).toLocaleString("zh-TW", { hour12: false });
}

export function configLabel(uid) {
  const row = rows.find((item) => item.uid === uid);
  return row ? `${row.name}@${row.hostname}` : uid;
}

// 第一次與最近一次：時刻、操作、原因各取自同一個事件，不交叉配對。
export function eventPairs(events, describe) {
  const first = events[0];
  const last = events[events.length - 1];
  if (events.length === 1) return [`發生在 ${whenText(first.at)} 的${first.operation}${describe(first)}`];
  return [
    `第一次：${whenText(first.at)} 的${first.operation}${describe(first)}`,
    `最近一次：${whenText(last.at)} 的${last.operation}${describe(last)}`,
  ];
}

export function leftBehindTag(mark) {
  const first = mark.events[0];
  return element("span", {
    class: "row-left-behind",
    "data-testid": "row-left-behind",
    title: "之前的寫入沒有完成，這份目標的還原步驟失敗，可能留下部分變更"
      + `（第一次：${whenText(first.at)} 的${first.operation}）。`
      + "旁邊的狀態只比對內容；顯示「一致」也不代表擁有者與權限已恢復。打開這份看恢復步驟。",
    text: "未還原",
  });
}

export async function loadLeftBehind(deadline) {
  try {
    leftBehind = await readJson(`${API_BASE}/api/left-behind`, deadline);
    leftBehindUnreadableEl.hidden = true;
  } catch (error) {
    // 讀不到：說出來，不把「沒有警示」當成沒有未還原的目標。原因另起一段原樣附上（它自帶下一步）。
    leftBehindUnreadableEl.replaceChildren(
      element("strong", {
        text: "讀不到「未還原」標示：畫面上沒有「未還原」不代表沒有未還原的目標。"
          + "下一步：按「檢查差異」重新讀取。",
      }),
      element("p", { text: failureText("讀取「未還原」標示", error) }),
    );
    leftBehindUnreadableEl.hidden = false;
  }
  renderLeftBehindWarning();
}

export function repoEventText(event) {
  return `（${REPO_RESULT_TEXT[event.state] || event.state}：${event.detail}）`;
}

export function repoWarningLine(repo) {
  const known = repo.state === "not_restored";
  const parts = eventPairs(repo.events, repoEventText);
  const first = repo.events[0];
  const last = repo.events[repo.events.length - 1];
  if (known && first.state !== "not_restored" && last.state !== "not_restored") {
    // 整體是沒能完整退回、但第一次與最近一次都不是那一次：另列最近一次已知失敗，不讓它被蓋掉。
    const lastKnown = [...repo.events].reverse().find((event) => event.state === "not_restored");
    parts.push(`最近一次已知失敗：${whenText(lastKnown.at)} 的${lastKnown.operation}`
      + `（${lastKnown.detail}）`);
  }
  const involved = [...new Set(repo.events.flatMap((event) => event.uids))].map(configLabel).join("、");
  return known
    ? `設定庫：沒能完整退回——${parts.join("；")}；涉及${involved}。`
      + "清單上的狀態是拿目前設定庫的內容比對，可能不是操作前的來源。"
    : `設定庫：回滾結果無法確認——${parts.join("；")}；涉及${involved}。`
      + "設定庫是否已完整退回，請維護者核對；清單上的狀態是拿目前設定庫的內容比對。";
}

export function renderLeftBehindWarning() {
  const { targets, repo } = leftBehind;
  if (!targets.length && !repo) {
    leftBehindWarningEl.hidden = true;
    leftBehindWarningEl.replaceChildren();
    return;
  }
  const items = targets.map((target) => {
    const label = target.name ? `${target.name}@${target.hostname}` : target.uid;
    const pair = target.events.length === 1
      ? `發生在 ${whenText(target.events[0].at)} 的${target.events[0].operation}`
      : `第一次 ${whenText(target.events[0].at)} 的${target.events[0].operation}；`
        + `最近一次 ${whenText(target.events[target.events.length - 1].at)} 的`
        + target.events[target.events.length - 1].operation;
    const open = element("button", {
      type: "button", "data-testid": `left-behind-open-${target.uid}`, text: "打開",
    });
    open.addEventListener("click", () => openPanel(target.uid));
    return element("li", {}, [element("span", { text: `${label}（${target.path}）：未還原——${pair}。` }), open]);
  });
  if (repo) items.push(element("li", { text: repoWarningLine(repo) }));
  leftBehindWarningEl.replaceChildren(
    element("strong", { text: "有寫入沒有完成：有目標的還原步驟失敗，或設定庫的回滾結果有問題，需要維護者處理。" }),
    element("ul", {}, items),
    element("p", {
      text: "這則警示不會被其他操作的成功或失敗訊息收起。每一份的「未還原」只在那一份之後經介面的寫入整個成功、"
        + "寫出同一個目標並照清單設定擁有者與權限時收起；解除納管只會停止追蹤，目標不會被還原。"
        + "設定庫那一筆不會自動收起；本版沒有手動「已核對」收起按鈕。",
    }),
    element("p", {
      text: "這則警示未持久化，服務重啟會遺失；遺失不代表問題已處理，重啟也不是修復或清除問題的方法。"
        + "維護者核對與處理的紀錄請另外保存。沒有這則警示，也不代表所有寫入都已還原——例如「以來源覆蓋目標」"
        + "自己的回滾失敗不會出現在這裡。",
    }),
  );
  leftBehindWarningEl.hidden = false;
}

// 這一份參與過、留下設定庫那一筆的最近一次事件（沒有就是 null）。
export function repoEventFor(uid) {
  const repo = leftBehind.repo;
  if (!repo) return null;
  return [...repo.events].reverse().find((event) => event.uids.includes(uid)) || null;
}

export function targetEventText(event) {
  return `——還原失敗的那一步：${event.step}（${event.reason}）；原本的失敗：${event.original}。`;
}

// 區塊最上方：這一份有「未還原」→ A；沒有、但它參與的那次操作留下設定庫那一筆 → B；都沒有 → null。
// `signature` 記下據以畫出的資料：重讀清單後資料沒變就不重畫（重新寫出失敗的原因留在橫幅裡）。
export function leftBehindBanner(detail, row) {
  const mark = row && row.left_behind;
  const signature = JSON.stringify([mark, row && row.state, leftBehind.repo]);
  if (!mark) {
    const event = repoEventFor(detail.uid);
    if (!event) return null;
    const note = element("div", { class: "notice warning", "data-testid": "left-behind-repo-note" }, [
      element("p", {
        text: `這份參與了 ${whenText(event.at)} 的${event.operation}，那次的設定庫`
          + `${event.state === "not_restored" ? "沒能完整退回" : "回滾結果無法確認"}（見上方警示）。`
          + "這份目標的還原步驟沒有失敗；但清單上的狀態是拿目前設定庫的內容比對，設定庫確認之前先不要進版、"
          + "覆蓋或納入。",
      }),
    ]);
    note.dataset.signature = signature;
    return note;
  }
  const latest = mark.events[mark.events.length - 1];
  const error = element("div", {
    class: "notice error", "data-testid": "left-behind-rewrite-error", hidden: "",
  });
  const steps = [
    "先保存現況：請維護者把這份目標檔，連同它的擁有者與權限，備份到指定的位置；同時保存這段說明，"
      + "以及「檢視差異」顯示的差異。只記下畫面上的值不能代替完整備份。",
    "原本的失敗交給維護者判斷怎麼處理；擁有者、權限與提權設定由維護者決定，不要為了讓寫入通過而直接改"
      + "擁有者或權限。",
  ];
  const actions = [];
  if (leftBehind.repo) {
    steps.push("先由維護者確認設定庫內容與歷史，確認可採用的來源版本後，再決定恢復方式；目前先不要進版、"
      + "覆蓋或納入。");
  } else if (row.state === "in_sync") {
    steps.push("內容目前和來源一致，但擁有者與權限沒有核對。維護者核對後，要照清單重新設定：按「以來源重新"
      + "寫出」——會重新寫出這份目標、套用清單的擁有者與權限，並記一筆變更紀錄；不保證回到"
      + `${latest.operation}前的擁有者與權限。`);
    const rewrite = element("button", {
      type: "button", class: "editing-only", "data-testid": "left-behind-rewrite", text: "以來源重新寫出",
    });
    rewrite.addEventListener("click", () => rewriteFromSource(detail, latest.operation, rewrite, error));
    actions.push(rewrite);
  } else {
    steps.push("決定保留哪一邊（在下面的差異檢視）：確定要恢復來源的內容：按「以來源覆蓋目標」；要保留目標"
      + "現在的內容：按「將目標現況納入來源」。兩者都會照清單設定擁有者與權限，不保證回到"
      + `${latest.operation}前的擁有者與權限。`);
  }
  steps.push("處理後，重新核對目前的來源、目標及全部草稿，再決定下一步。維護者核對與處理的紀錄請另外保存。");
  const banner = element("div", { class: "notice error left-behind-banner", "data-testid": "left-behind-banner" }, [
    element("strong", { text: "未還原：之前的寫入沒有完成，這份目標的還原步驟失敗。" }),
    ...eventPairs(mark.events, targetEventText).map((text) => element("p", { text })),
    element("p", {
      text: "還原步驟失敗表示目標可能留下部分變更，不代表所有內容都沒還原；內容、擁有者與權限需要重新核對。"
        + "上面的狀態只比對內容；顯示「一致」也不代表擁有者與權限已恢復。",
    }),
    element("p", { text: "下一步：" }),
    element("ol", {}, steps.map((text) => element("li", { text }))),
    element("div", { class: "actions" }, actions),
    error,
    element("p", {
      text: "這個標示只在這一份之後經介面的寫入整個成功、寫出同一個目標並照清單設定擁有者與權限時收起"
        + "（進版含這一份、以來源覆蓋目標、以來源重新寫出、將目標現況納入來源、退版、寫出到目標）；寫入失敗時"
        + "保留。解除納管只會停止追蹤，目標不會被還原。標示未持久化，服務重啟會遺失；遺失不代表問題已處理。",
    }),
  ]);
  banner.dataset.signature = signature;
  return banner;
}

export function syncLeftBehindBanner(panel, detail, row) {
  const existing = panel.querySelector("[data-testid='left-behind-banner'], [data-testid='left-behind-repo-note']");
  const built = detail ? leftBehindBanner(detail, row) : null;
  if (!built) { if (existing) existing.remove(); return; }
  if (existing && existing.dataset.signature === built.dataset.signature) return;
  if (existing) existing.replaceWith(built);
  else panel.insertBefore(built, panel.children[1] || null);  // 緊接在標頭下、偏離橫幅之前
}

// 收起那一句：只依回應的 `left_behind_cleared`（後端確實收起的），不自己比對前後去猜。
export function clearedSentence(cleared) {
  if (!cleared || !cleared.length) return "";
  if (cleared.length === 1) {
    return "上次的「未還原」標示已收起：這次寫入已改寫這份目標，並照清單設定擁有者與權限。";
  }
  return `上次的「未還原」標示已收起：${cleared.map(configLabel).join("、")}——`
    + "這次寫入已改寫這些目標，並照清單設定擁有者與權限。";
}

// 寫入失敗後（409 drafts_changed 除外）：重新比對清單與標示，開著的區塊跟著換（草稿保留，後端沒清）。
// 重新讀取也失敗時明說畫面上的狀態尚未更新——不讓失敗前的「一致」看起來像現況。
export async function reloadAfterFailure() {
  await load();
  if (loadError === null) return;
  statusNotUpdatedEl.replaceChildren(
    element("strong", {
      text: "寫入失敗後重新讀取清單也失敗：畫面上的狀態是這次寫入之前的，尚未更新。"
        + "下一步：按「檢查差異」重新讀取。",
    }),
    element("p", { text: loadError }),
  );
  statusNotUpdatedEl.hidden = false;
}

export async function rewriteFromSource(detail, operation, button, errorEl) {
  if (isBusy(button)) return;
  const permissions = detail.permissions || {};
  const ok = await confirmAction(
    `以來源重新寫出「${detail.name}」的目標？`,
    "內容目前一致，此操作仍會重新寫出並套用清單的擁有者與權限。"
      + `${detail.target} 會照清單設為 ${permissions.owner}:${permissions.group}、${permissions.mode}，`
      + `並記一筆變更紀錄；不保證回到${operation}前的擁有者與權限。`,
    "重新寫出",
  );
  if (!ok) return;
  await whileBusy(button, "重新寫出中…", async () => {
    errorEl.hidden = true;
    clearPromoteBanners();  // F38：確認後送出就收起上一個結果
    try {
      const response = await editFetch(`${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}/resolve`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ action: "rewrite" }),
      });
      const payload = await response.json();
      if (!response.ok) {
        renderSaveError(errorEl, payload.detail);  // 原因留在橫幅裡；標示照舊，不宣稱收起
        await reloadAfterFailure();
        return;
      }
      promoteDoneEl.textContent = `已以來源重新寫出「${detail.name}」的目標，並記一筆變更紀錄。`
        + clearedSentence(payload.left_behind_cleared);
      promoteDoneEl.hidden = false;
      await load();
      await openPanel(detail.uid);
    } catch (error) {
      renderSaveError(errorEl, failureText("以來源重新寫出", error));
    }
  });
}

export function clearPromoteBanners() {
  promoteErrorEl.hidden = true;
  promoteDoneEl.hidden = true;
}

// 進版前的條件確認（ADR-00000032）：這批草稿的參與者含別人 → 先問；全是自己的 → 直接進版。
// 回 null＝取消；回 undefined＝不必確認；回 [{uid, sha}]＝確認當下的簽章，送出時帶著，後端比對不符就不進版。
export async function confirmPromotingOthersDrafts(note = "") {
  const { all, others, distinct } = draftParticipants();
  if (!others.length) return undefined;
  const items = [
    ...all.map((who) => `${ownerLabel(who)}：參與 ${who.count} 份`),
    `不重複的草稿共 ${distinct} 份（同一份多人參與會重複計入）`,
  ];
  const ok = await confirmAction(
    "進版？這批含別人存的草稿",
    `${note}紀錄的作者會是你；每一筆的內文會逐份註明草稿由誰存。進版後草稿清空、寫出到目標。`,
    "進版",
    items,
  );
  if (!ok) return null;
  return [...draftDetails.values()].map((draft) => ({ uid: draft.uid, sha: draft.sha }));
}

export async function promoteFlow() {
  if (isBusy(promoteButton)) return;
  let expected = await confirmPromotingOthersDrafts();
  if (expected === null) return;
  // 確認期間草稿變了：後端 409 drafts_changed → 重讀草稿、重開確認（內文說草稿已變），不悄悄進版。
  while (true) {
    const changed = await whileBusy(promoteButton, "進版中…", () => promoteAll(expected));
    if (!changed) return;
    await loadDrafts();
    expected = await confirmPromotingOthersDrafts("草稿已變（確認之後有人改了草稿），以下是現在的草稿。");
    if (expected === null || expected === undefined) return;
  }
}

export async function promoteAll(expected) {
  clearPromoteBanners();
  promoteButton.disabled = true;
  try {
    const init = { method: "POST" };
    if (expected) {
      init.headers = { "content-type": "application/json" };
      init.body = JSON.stringify({ expected });
    }
    const response = await editFetch(`${API_BASE}/api/promote`, init);
    const payload = await response.json();
    if (response.status === 409 && payload.detail && payload.detail.kind === "drafts_changed") {
      setDrafts(draftUids);  // 草稿保留，按鈕恢復；呼叫端重新確認
      return true;
    }
    if (!response.ok) {
      renderSaveError(promoteErrorEl, payload.detail);  // 同一種結構化形：message＋逐條行號／原因／建議
      const detail = payload.detail;
      if (detail && detail.uid) openPanel(detail.uid);  // 把人帶到沒過的那一份
      setDrafts(draftUids);  // 草稿保留，按鈕恢復
      await reloadAfterFailure();  // #345：不留著失敗前的狀態——回滾沒還原的那一份要看得到
      return false;
    }
    setDraftDetails(new Map());
    setDrafts([]);  // 進版後草稿清空（T18）
    promoteDoneEl.textContent = `已進版 ${payload.promoted.length} 份，各記一筆變更紀錄並寫出至目標。`
      + clearedSentence(payload.left_behind_cleared);
    promoteDoneEl.hidden = false;
    // 目標變了：重掃完才重畫打開的那幾份（現在來源＝剛進版的內容）。偏離的 config 進版後回到一致，
    // 不等重掃，欄位表會照舊清單寫「偏離」（F12，同 resolveDrift）。
    await load();
    await Promise.all(openUids().map((uid) => openPanel(uid)));
  } catch (error) {
    renderSaveError(promoteErrorEl, failureText("進版", error));
    setDrafts(draftUids);
    return false;
  }
}

export async function discardDrafts(uid, name, button = discardAllButton) {
  if (isBusy(button)) return;
  const scope = uid ? `「${name}」的草稿` : `全部 ${draftUids.size} 份草稿`;
  const ok = await confirmAction(
    `捨棄${uid ? "這份" : "全部"}變更？`,
    `${scope}會被清除、回到來源內容。來源與目標檔案都不會改變；這個動作無法復原。`,
    "捨棄變更",
  );
  if (!ok) return;
  await whileBusy(button, "捨棄中…", async () => {
    clearPromoteBanners();
    try {
      const path = uid ? `/api/drafts/${encodeURIComponent(uid)}` : "/api/drafts";
      const response = await editFetch(`${API_BASE}${path}`, { method: "DELETE" });
      const payload = await response.json();
      if (!response.ok) {
        renderSaveError(promoteErrorEl, payload.detail);
        return;
      }
      applyDraftsView(payload);
      promoteDoneEl.textContent = uid
        ? `已捨棄「${name}」的草稿，畫面回到來源內容。來源與目標檔案都沒有改變。`
        : "已捨棄全部草稿，畫面回到來源內容。來源與目標檔案都沒有改變。";
      promoteDoneEl.hidden = false;
      for (const open of openUids()) {
        if (!uid || uid === open) openPanel(open);  // 畫面回到來源內容
      }
    } catch (error) {
      renderSaveError(promoteErrorEl, failureText("捨棄變更", error));
    }
  });
}

// 解除納管（#287，後端 #28）：不可逆，先說實際會發生的事再做（設計原則 2）。成功後這份從樹與
// 工作區消失；目標檔案不動。後端拒絕（有草稿、寫入失敗）時原因原樣顯示，項目留在原處。
export async function unmanageConfig(detail, button) {
  if (isBusy(button)) return;
  const marked = (rows.find((item) => item.uid === detail.uid) || {}).left_behind;
  const ok = await confirmAction(
    `解除「${detail.name}」的納管？`,
    `系統不再追蹤這份檔案，它會從清單消失。目標檔案 ${detail.target} 保留、內容不動；`
      + "過去的變更歷史仍留在設定庫裡。之後要再管理它，得重新納管。"
      + (marked
        ? `這份有「未還原」標示（第一次：${whenText(marked.events[0].at)} 的${marked.events[0].operation}）。`
          + "解除納管只是停止追蹤：標示會拿掉，但目標沒有被還原，內容、擁有者與權限仍需要維護者核對。"
        : ""),
    "解除納管",
  );
  if (!ok) return;
  await whileBusy(button, "解除中…", async () => {
    clearPromoteBanners();
    try {
      const response = await editFetch(`${API_BASE}/api/configs/${encodeURIComponent(detail.uid)}`, {
        method: "DELETE",
      });
      const payload = await response.json();
      if (!response.ok) {
        renderSaveError(promoteErrorEl, payload.detail);
        return;
      }
      closeSlot(detail.uid);
      promoteDoneEl.textContent = `已解除「${detail.name}」的納管，並記一筆變更紀錄。目標檔案保留在 ${detail.target}。`
        + ((payload.left_behind_untracked || []).length
          ? "這份原本有「未還原」標示；解除納管只是停止追蹤，目標沒有被還原。"
          : "");
      promoteDoneEl.hidden = false;
      load();
    } catch (error) {
      renderSaveError(promoteErrorEl, failureText("解除納管", error));
    }
  });
}

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wirePromote() {
  promoteButton.addEventListener("click", promoteFlow);
  discardAllButton.addEventListener("click", () => discardDrafts(null, null));
}
