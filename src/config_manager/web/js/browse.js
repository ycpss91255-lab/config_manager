// W7 檔案瀏覽（#13）。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { API_BASE, Refused, apiFetch, editFetch, failureText } from "./api.js";
import { element } from "./dom.js";
import { loadErrorText } from "./tree.js";
import { same } from "./list-edit.js";
import { confirmAction, isBusy, whileBusy } from "./dialogs.js";
import { currentIdentity, hideAllPageViews, showList } from "./identity.js";
import { detailText } from "./whitelist.js";
import { onboardStartEl } from "./onboard.js";

// ── W7 檔案瀏覽（#13）─────────────────────────────────────────────────────────
// 受白名單限制的瀏覽，供納管時選定路徑。獨立整頁 view，從工具列「納管」開啟。
// 白名單根為起點（GET /api/allowed-roots）；下鑽用後端回應的每個 entry.path，不在前端
// 拼路徑；麵包屑與目前位置用回應的 path（realpath）。拒絕依 kind＋角色分流（只有
// outside_roots 給開發者「加入白名單」入口，一般使用者看唯讀允許範圍）。
export const browseView = document.querySelector("[data-testid='browse']");
export const browseRootsEl = document.querySelector("[data-testid='browse-roots']");
export const browseListEl = document.querySelector("[data-testid='browse-list']");
export const breadcrumbEl = document.querySelector("[data-testid='breadcrumb']");
export const browsePathInput = document.querySelector("[data-testid='browse-path-input']");
export const browseSelectionEl = document.querySelector("[data-testid='browse-selection']");
export const browseRejectedEl = document.querySelector("[data-testid='browse-rejected']");
export const browseHintEl = document.querySelector("[data-testid='browse-hint']");

export let whitelistRoots = [];
// 每次導覽遞增；回應回來時若世代已變（使用者又點了別的目錄／麵包屑、或用「前往」貼了新路徑），
// 丟棄這個過時回應——否則晚到的舊目錄回應會覆蓋新目錄，或讓被拒面板與成功清單並存（#252）。
export let browseGeneration = 0;

export function showBrowse() {
  // hideAllPageViews 一併藏起確認 view——否則兩個整頁 view 疊著，殘留的「確認寫入」還能送舊
  // 路徑（#14 審查）。並清掉可能殘留的選檔狀態（loadBrowseRoots 會重載根、清列表與麵包屑）。
  hideAllPageViews();
  selectedSourcePath = null;
  onboardStartEl.hidden = true;
  browseView.hidden = false;
  loadBrowseRoots();
}

export async function loadBrowseRoots() {
  breadcrumbEl.replaceChildren();
  browseListEl.replaceChildren();
  browseSelectionEl.hidden = true;
  browseRejectedEl.hidden = true;
  try {
    const response = await apiFetch(`${API_BASE}/api/allowed-roots`);
    if (!response.ok) throw new Refused(await loadErrorText(response));
    whitelistRoots = (await response.json()).prefixes;
    browseRootsEl.replaceChildren(...whitelistRoots.map((prefix) =>
      element("li", { "data-testid": `browse-root-${prefix}`, "data-path": prefix }, [
        element("span", { class: "browse-name", text: prefix }),
      ])
    ));
    browseHintEl.textContent = whitelistRoots.length
      ? "挑一個允許瀏覽的根開始，或在上方貼一個絕對路徑。"
      : "白名單目前是空的，所以沒有可以瀏覽的目錄。下一步：" + (
        currentIdentity && currentIdentity.role === "developer"
          ? "回主畫面按「白名單」，加入要管理的目錄。"
          : "請開發者把要管理的目錄加進白名單。");
  } catch (error) {
    browseHintEl.textContent = failureText("讀取白名單", error);
  }
}

export async function browseTo(path) {
  const generation = ++browseGeneration;
  browseRejectedEl.hidden = true;
  // 換目錄就清掉「已選」——選取屬於某個目錄，離開它之後那個殘留會與目前位置不一致（#13）。
  browseSelectionEl.hidden = true;
  onboardStartEl.hidden = true;
  selectedSourcePath = null;
  try {
    const response = await apiFetch(`${API_BASE}/api/browse?path=${encodeURIComponent(path)}`);
    const payload = await response.json();
    if (generation !== browseGeneration) return;  // 有更新的導覽開始了，這個回應過時、丟棄
    if (!response.ok) {
      renderBrowseRejection(payload.detail, path);
      return;
    }
    // 成功抵達新目錄：再清一次選取狀態並確保被拒面板收起——若在載入途中於舊清單選了檔、或先前
    // 有一則被拒回應，這裡讓成功清單與那些殘留互斥，不會出現「已選：舊目錄的檔」或拒絕面板與清單
    // 並存（#252）。起點根清單也讓位給內容。
    selectedSourcePath = null;
    browseSelectionEl.hidden = true;
    onboardStartEl.hidden = true;
    browseRejectedEl.hidden = true;
    browseRootsEl.replaceChildren();
    browseHintEl.textContent = "";
    renderBreadcrumb(payload.path);
    renderBrowseEntries(payload.entries);
    // 貼的是白名單內一般檔案的路徑（F1、人工驗收 U05）：後端列它所在的目錄並標出它——選好它，
    // 與逐層點進去再點它一樣，不自動納管。在同一個世代檢查過的成功分支裡，過時的回應選不到檔（#252）。
    if (payload.selected) selectBrowseFile(payload.selected);
  } catch (error) {
    if (generation !== browseGeneration) return;
    browseHintEl.textContent = failureText("瀏覽目錄", error);
  }
}

export function renderBrowseEntries(entries) {
  if (!entries.length) {
    browseListEl.replaceChildren(element("li", {
      class: "whitelist-empty", "data-testid": "browse-empty",
      text: "這個目錄是空的，沒有可以納管的檔案。下一步：回上一層，或換一個目錄。",
    }));
    return;
  }
  browseListEl.replaceChildren(...entries.map((entry) =>
    element("li", {
      "data-testid": `browse-entry-${entry.name}`,
      "data-kind": entry.kind,
      "data-name": entry.name,
      "data-path": entry.path,
    }, [
      element("span", { class: "browse-name", text: entry.name }),
      element("span", { class: "kind", text: entry.kind === "dir" ? "目錄" : "檔案" }),
    ])
  ));
}

export function renderBreadcrumb(path) {
  // 夾在白名單根為界：找出含這條路徑的根，只從根往下顯示（上溯不越過根）。
  const root = whitelistRoots.find((r) => path === r || path.startsWith(`${r}/`));
  const nodes = [];
  const pushSegment = (label, target) => {
    if (nodes.length) nodes.push(element("span", { class: "sep", text: "›" }));
    const seg = element("button", { type: "button", "data-path": target, text: label });
    seg.addEventListener("click", () => browseTo(target));
    nodes.push(seg);
  };
  if (root) {
    pushSegment(root, root);
    let acc = root;
    for (const part of path.slice(root.length).split("/").filter(Boolean)) {
      acc += `/${part}`;
      pushSegment(part, acc);
    }
  } else {
    // 路徑不在任何已知根底下——不該發生（root_prefixes 與 payload.path 都已 realpath 正規化，
    // 成功瀏覽的路徑必在某根之下）。防禦性地只顯示路徑、**不做可點的祖先**，免得在根不相符時
    // 讓人點到白名單根之上（#13 資安審查）。
    nodes.push(element("span", { class: "sep", text: path }));
  }
  breadcrumbEl.replaceChildren(...nodes);
}

export function selectBrowseFile(path) {
  selectedSourcePath = path;
  browseSelectionEl.textContent = `已選：${path}`;
  browseSelectionEl.hidden = false;
  onboardStartEl.hidden = false;  // 選了檔才出現「檢視並納管」（進 W8 確認）
}

export function renderBrowseRejection(detail, attempted) {
  // detail 是 {kind, message}（#13）。原樣顯示 message（含下一步，不改寫）；依 kind＋角色
  // 決定：只有 outside_roots 給加入白名單入口，開發者可加、一般使用者看唯讀允許範圍。
  const kind = detail && detail.kind;
  const message = (detail && detail.message) || String(detail);
  browseListEl.replaceChildren();
  const children = [
    element("strong", { text: "無法瀏覽這個路徑。" }),
    element("p", { class: "msg", text: message }),
  ];
  if (kind === "outside_roots") {
    if (currentIdentity && currentIdentity.role === "developer") {
      const prefixInput = element("input", {
        type: "text",
        "data-testid": "whitelist-prefix-input",
      });
      // 預填後端建議的目錄前綴（被拒目標的 realpath，檔案則取父目錄），退回 resolved／原字串；
      // 白名單根必須是目錄，用原字串會在目標是檔案或有 symlink 時加入失敗（#13）。可編輯。
      prefixInput.value = detail.suggested || detail.resolved || attempted;
      const addButton = element("button", { type: "button", text: "加入白名單" });
      addButton.addEventListener("click", () => addToWhitelist(prefixInput.value, addButton));
      children.push(element("div", { class: "add-row" }, [prefixInput, addButton]));
    } else {
      children.push(element("p", {
        text: "請開發者代為加入白名單。目前允許瀏覽的範圍：",
      }));
      children.push(element("ul", {
        class: "allowed-range", "data-testid": "allowed-range",
      }, whitelistRoots.map((prefix) => element("li", { text: prefix }))));
    }
  }
  browseRejectedEl.replaceChildren(...children);
  browseRejectedEl.setAttribute("data-kind", kind || "browse_error");
  browseRejectedEl.hidden = false;
}

// 加入白名單前的預覽與確認（§7.9：顯示「此路徑下有幾個可納管檔」供確認再送出）。兩個入口共用
// ——白名單維護頁，與瀏覽被拒時的「加入白名單」。後者原本一按就生效（人工驗證 U13）。
// 明確寫出即將開放的路徑：加入的是整個目錄（含子目錄），不只是剛才想看的那個檔案。
export async function confirmAddRoot(prefix, showError) {
  // 顯示確認框前先比對目前的白名單：已經在裡面的直接說、不問「要開放嗎」——問了再答已存在，
  // 等於白按一次（複驗回饋）。只比對得出字面或後端解析過的路徑；符號連結等後端送出時仍會擋。
  const wanted = prefix.replace(/\/+$/, "") || prefix;
  try {
    const listed = await apiFetch(`${API_BASE}/api/allowed-roots`);
    if (listed.ok) {
      const roots = (await listed.json()).roots || [];
      const same = roots.find((root) => [root.prefix, root.resolved].includes(wanted));
      if (same) {
        showError(`「${same.prefix}」已經在白名單裡，這次沒有加入；既有的項目不用更動。`);
        return false;
      }
    }
  } catch (_error) {
    // 查不到目前的白名單就略過這一步：後端送出時仍會擋重複。
  }
  let payload;
  try {
    const response = await apiFetch(`${API_BASE}/api/candidate-count?prefix=${encodeURIComponent(prefix)}`);
    payload = await response.json();
    if (!response.ok) {
      showError(detailText(payload.detail));
      return false;
    }
  } catch (error) {
    showError(failureText("計算可納管檔案數", error));
    return false;
  }
  const shown = payload.capped ? `${payload.count} 個以上` : `${payload.count} 個`;
  return confirmAction(
    "加入白名單？",
    `將開放「${prefix}」這個目錄與它底下的所有子目錄，供瀏覽與納管；目前底下有 ${shown}可納管檔。`
      + "這會留下一筆紀錄（誰在何時加入），之後可以在白名單維護移除。",
    "加入白名單",
  );
}

export async function addToWhitelist(prefix, button) {
  if (isBusy(button)) return;
  const showAddError = (text) => {
    const slot = browseRejectedEl.querySelector(".msg");
    if (slot) slot.textContent = text;
  };
  if (!await confirmAddRoot(prefix, showAddError)) return;
  await whileBusy(button, "加入中…", async () => {
    try {
      const response = await editFetch(`${API_BASE}/api/allowed-roots`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ prefix }),
      });
      const payload = await response.json();
      if (!response.ok) {
        // 端點的訊息已可行動（含下一步），原樣顯示，不改寫（不變式 2）。
        const text = typeof payload.detail === "string"
          ? payload.detail
          : (payload.detail && payload.detail.message) || `${response.status}`;
        showAddError(text);
        return;
      }
      whitelistRoots = payload.prefixes;
      browseRejectedEl.hidden = true;
      browseTo(prefix);  // 重跑被拒的瀏覽——該路徑現在在白名單內了
    } catch (error) {
      showAddError(failureText("加入白名單", error));
    }
  });
}

// ── W8 納管確認（#14）───────────────────────────────────────────────────────
// 選檔（W7）→「檢視並納管」→ POST /api/inspect → 顯示格式／型別／歧義／權限／hostname
// 供確認 → 逐條確認歧義後 → POST /api/configs 寫入 → 回清單。型別只顯示不可編輯（編輯是
// W3／#16）。hostname 只顯示、不由前端送（後端納管當下決定並凍結，不變式 8）。
export let selectedSourcePath = null;

// 這個模組的事件接線。由 main.js 依原本的順序呼叫（#359）。
export function wireBrowse() {
  browseRootsEl.addEventListener("click", (event) => {
    const li = event.target.closest("li[data-path]");
    if (li) browseTo(li.dataset.path);
  });

  browseListEl.addEventListener("click", (event) => {
    const li = event.target.closest("li[data-testid^='browse-entry-']");
    if (!li) return;
    if (li.dataset.kind === "dir") browseTo(li.dataset.path);
    else selectBrowseFile(li.dataset.path);
  });

  document.querySelector("[data-testid='open-browse']").addEventListener("click", showBrowse);
  browseView.querySelector(".browse-back").addEventListener("click", () => showList(currentIdentity));
}
