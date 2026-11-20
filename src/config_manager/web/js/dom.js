// 共用的 DOM 小工具：建元素、開發者記號。
//
// 原本是 index.html 的行內腳本；拆成原生 ES 模組時只搬位置，行為不變（#359）。

export function element(tag, attributes, children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes || {})) {
    if (key === "text") node.textContent = value;
    else node.setAttribute(key, value);
  }
  for (const child of children || []) node.appendChild(child);
  return node;
}

// 開發者專屬操作的記號（#54、CONTEXT.md「角色與環境」）。附在入口自己的字後面——記號帶著字，
// 不只靠圖示：扳手圖示單獨出現時說不出它是什麼意思，螢幕閱讀器也只會念出「扳手」。
// 一般使用者的畫面上沒有它：那些入口對一般使用者本來就不出現（ADR-00000020）。
//
// 記號的樣子寫在 HTML 的 <template> 裡，這裡只複製：那個圖示是基本平面外的字元，放進這段
// script 會讓 V8 的位移與覆蓋率工具的字串索引對不齊（test/pytest/system/v8_coverage.py 會擋）。
export const devMarkTemplate = document.getElementById("dev-mark-template");
export function devMark() {
  return devMarkTemplate.content.firstElementChild.cloneNode(true);
}

// 一個常駐在 DOM 裡、依角色顯示或隱藏的入口（標題列的「白名單」）：記號跟著角色加上或拿掉。
export function markDeveloperOnly(node, on) {
  const existing = node.querySelector("[data-testid='dev-mark']");
  if (on && !existing) node.appendChild(devMark());
  if (!on && existing) existing.remove();
}
