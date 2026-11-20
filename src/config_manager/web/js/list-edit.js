// 清單的增刪調序（#46、§7.5.2）。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

import { element } from "./dom.js";
import { rows } from "./tree.js";
import { clone, collectRows, displayValue, paramRow } from "./params.js";

// ── 清單的增刪調序（#46、§7.5.2）────────────────────────────────────────────
// 順序本身就是資料：只給新增／移除的話，要把第三項移到第一位得刪掉重打，重打會遺失原值、也容易
// 打錯。所以每個元素有 ↑↓ 與移除，清單有新增；全部改在擁有者的工作副本上，改完整段重畫。

export const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);

export function setAt(target, segments, value) {
  let node = target;
  for (const segment of segments.slice(0, -1)) node = node[segment];
  node[segments[segments.length - 1]] = value;
}

export function updateOwner(owner, onChange) {
  owner.node.dataset.dirty = String(!same(owner.working, owner.listBaseline));
  owner.node.dataset.changed = String(!same(owner.working, owner.value));
  owner.node.dataset.valid = "true";
  if (onChange) onChange();
}

// 擁有者底下某個清單——`segments` 是它相對擁有者的位置，空的就是擁有者自己——在工作副本與影子裡
// 的那兩個陣列。影子先補到一樣長（新增的元素在影子裡是空位）；影子那邊整段沒有（外層元素本身
// 就是新增的）回 null，那就沒有東西要跟著搬。
export function listsAt(owner, segments) {
  const walk = (root) => segments.reduce(
    (node, segment) => (node === null || node === undefined ? undefined : node[segment]), root,
  );
  const items = walk(owner.working);
  const found = walk(owner.shadow);
  const mirror = Array.isArray(found) ? found : null;
  while (mirror && mirror.length < items.length) mirror.push(undefined);
  return { items, mirror };
}

export function listOps(row, table) {
  const owner = row.owner;
  const parent = row.segments.slice(0, -1);  // 這個元素所在的清單
  const index = row.segments[row.segments.length - 1];
  const last = listsAt(owner, parent).items.length - 1;
  const button = (testid, text, title, disabled, act) => {
    const made = element("button", {
      type: "button", class: "list-op editing-only", "data-testid": testid, title, text,
    });
    made.disabled = disabled;
    made.addEventListener("click", act);
    return made;
  };
  const move = (to) => {
    const { items, mirror } = listsAt(owner, parent);
    [items[index], items[to]] = [items[to], items[index]];
    if (mirror) [mirror[index], mirror[to]] = [mirror[to], mirror[index]];  // 影子跟著搬
    rerenderList(owner, table);
  };
  return element("span", { class: "list-ops" }, [
    button("list-up", "↑", "往上移一位", index === 0, () => move(index - 1)),
    button("list-down", "↓", "往下移一位", index === last, () => move(index + 1)),
    button("list-remove", "✕", "移除這一項", false, () => {
      const { items, mirror } = listsAt(owner, parent);
      items.splice(index, 1);
      if (mirror) mirror.splice(index, 1);
      rerenderList(owner, table);
    }),
  ]);
}

// 新增一項：元素型別一致（§7.5.2）——依清單的元素型別給一個空值；元素是物件時以最後一項為樣板
// （欄位齊、再改值），清單還是空的且不知道元素型別時給空字串（未結構化編輯）。
export const EMPTY_BY_TYPE = { int: 0, float: 0, bool: false, string: "" };

export function listAdd(listRow, table) {
  const owner = listRow.owner || listRow;  // 清單裡的清單由最外層那份擁有
  const segments = listRow.segments || [];
  const button = element("button", {
    type: "button", class: "list-op editing-only", "data-testid": "list-add", text: "＋ 新增",
    title: "在清單末端加一項",
  });
  button.addEventListener("click", () => {
    const elementType = table.detail.types[`${listRow.typePath}[]`] || "unknown";
    const { items } = listsAt(owner, segments);
    const lastItem = items[items.length - 1];
    let fresh = EMPTY_BY_TYPE[elementType];
    if (elementType === "dict" || elementType === "list") fresh = lastItem === undefined ? {} : clone(lastItem);
    if (fresh === undefined) fresh = "";
    items.push(fresh);
    // 影子在同一個位置留空位：新增的元素沒有來源值，就算以最後一項為樣板也一樣。
    listsAt(owner, segments);
    rerenderList(owner, table);
    const added = table.list.querySelector(
      `[data-name='${listRow.path}[${items.length - 1}]'] [data-testid='param-value']`,
    );
    if (added && added.focus) added.focus();
  });
  return button;
}

// 整段重畫擁有者底下的列：舊的列與 entries 拿掉、從工作副本重建。擁有者那一列不動。
export function rerenderList(owner, table) {
  const { detail, entries, list } = table;
  const prefix = `${owner.path}[`;
  for (const node of [...list.querySelectorAll("li[data-name]")]) {
    if (node.dataset.name.startsWith(prefix)) node.remove();
  }
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    if (entries[index].row.owner === owner) entries.splice(index, 1);
  }
  const rows = [];
  owner.working.forEach((child, index) => collectRows(detail, rows, {
    value: owner.shadow[index], draft: child, path: `${owner.path}[${index}]`,
    typePath: `${owner.typePath}[]`, depth: owner.depth + 1, name: `[${index}]`,
    owner, segments: [index],
  }));
  let anchor = owner.node;
  for (const row of rows) {
    const node = paramRow(row, table);
    anchor.after(node);
    anchor = node;
  }
  updateOwner(owner, table.onChange);
}

export function currentValue(control, row) {
  if (control.choices) return control.choices[control.selectedIndex];
  if (row.type === "bool") return control.checked;
  if (row.type === "int" || row.type === "float") return Number(control.value);
  // 型別未知（#383）：控制項裡只有文字。文字沒被改過就送回原本的值——否則混型清單的數字 1 一經過
  // 控制項就變成 "1"，清單被判定改過，存別的欄位時整份重寫。改過的照字面存成文字（未結構化編輯）。
  if ((row.type === "unknown" || row.type === "null")
      && control.value === displayValue(row.baseline, row.type)) {
    return row.baseline;
  }
  return control.value;
}

// 值相對 schema 的範圍／倍數（#40）。回原因與修法；合格回空字串。倍數以容許誤差比（0.3 ÷ 0.1 在
// 浮點數上不是整數）。
export function rangeProblem(number, hint) {
  if (!hint) return "";
  if (hint.minimum !== undefined && number < hint.minimum) return `超出範圍：不可小於 ${hint.minimum}`;
  if (hint.maximum !== undefined && number > hint.maximum) return `超出範圍：不可大於 ${hint.maximum}`;
  if (hint.exclusiveMinimum !== undefined && number <= hint.exclusiveMinimum) {
    return `超出範圍：必須大於 ${hint.exclusiveMinimum}`;
  }
  if (hint.exclusiveMaximum !== undefined && number >= hint.exclusiveMaximum) {
    return `超出範圍：必須小於 ${hint.exclusiveMaximum}`;
  }
  if (hint.multipleOf !== undefined) {
    const ratio = number / hint.multipleOf;
    if (Math.abs(ratio - Math.round(ratio)) > 1e-9) return `必須是 ${hint.multipleOf} 的倍數`;
  }
  return "";
}

// 字串相對 schema 的長度（F6）。以字元（code point）計，與後端 jsonschema 用的 Python len 相同——
// `.length` 數的是 UTF-16 單位，一個 emoji 會算成 2，介面就和後端說法不一致。
export function lengthProblem(text, hint) {
  if (!hint) return "";
  const length = [...text].length;
  if (hint.minLength !== undefined && length < hint.minLength) {
    return hint.minLength === 1 ? "不可空白：至少要填 1 個字" : `太短：至少要 ${hint.minLength} 個字`;
  }
  if (hint.maxLength !== undefined && length > hint.maxLength) return `太長：最多 ${hint.maxLength} 個字`;
  return "";
}

export function localProblem(control, row) {
  if (control.choices) {
    const outside = control.selectedOptions[0] && control.selectedOptions[0].dataset.outside;
    return outside ? "目前的值不在允許的值裡，請改選一個" : "";
  }
  if (row.type === "string") return lengthProblem(control.value, row.hint);
  if (row.type !== "int" && row.type !== "float") return "";
  if (control.validity.badInput) return row.type === "int" ? "必須是整數，不接受小數或文字" : "必須是數字";
  if (control.value === "") return "不可為空";
  const number = Number(control.value);
  if (row.type === "int" && !Number.isInteger(number)) return "必須是整數，不接受小數或文字";
  return rangeProblem(number, row.hint);
}

export function refreshParamRow(node, control, row, source, validation) {
  const problem = localProblem(control, row);
  validation.textContent = problem;
  node.dataset.valid = problem ? "false" : "true";
  delete node.dataset.warning;  // 規則的警告是後端標的；值一改就重算，標記由下一次儲存重標
  const current = displayValue(currentValue(control, row), row.type);
  const changed = current !== displayValue(row.value, row.type);  // 相對來源（「來源值」欄標色）
  node.dataset.changed = String(changed);
  node.dataset.dirty = String(current !== displayValue(row.baseline, row.type));  // 相對已存的草稿
  if (changed) source.setAttribute("data-changed", "true");
  else source.removeAttribute("data-changed");
}

export function toggleCollapse(list, container) {
  // 折疊狀態記在容器身上，再依「任一祖先折疊了嗎」重算每列可見性（與 W8 型別樹同一做法）。
  container.dataset.collapsed = container.dataset.collapsed === "true" ? "false" : "true";
  const collapsed = [...list.querySelectorAll("li[data-container='true']")]
    .filter((node) => node.dataset.collapsed === "true")
    .map((node) => node.dataset.name);
  for (const node of list.querySelectorAll("li[data-name]")) {
    const name = node.dataset.name;
    const hidden = collapsed.some(
      (prefix) => name !== prefix && (name.startsWith(`${prefix}.`) || name.startsWith(`${prefix}[`))
    );
    node.classList.toggle("is-collapsed-child", hidden);
  }
}
