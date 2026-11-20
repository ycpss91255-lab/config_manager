// 頁面的入口（#359）：index.html 只載入這一個模組，其餘由它匯入。
//
// 各模組的頂層只有宣告；事件接線在各自的 wire 函式裡，這裡依原本在行內腳本裡的順序呼叫，
// 同一個元素上的同一種事件，處理的先後與拆分前相同。最後才開頁（start），與原本最後一段相同。

import { exposePageGlobals } from "./page-globals.js";
import { wireTree } from "./tree.js";
import { wireSearch } from "./search.js";
import { wireWorkspace } from "./workspace.js";
import { wirePromote } from "./promote.js";
import { wireSession } from "./session.js";
import { wireExit } from "./exit.js";
import { wireIdentity } from "./identity.js";
import { wireIdle } from "./idle.js";
import { wireBrowse } from "./browse.js";
import { wireWhitelist } from "./whitelist.js";
import { wireSettings } from "./settings.js";
import { wireOnboard } from "./onboard.js";
import { start, wireStartup } from "./startup.js";

exposePageGlobals();
wireTree();
wireSearch();
wireWorkspace();
wirePromote();
wireSession();
wireExit();
wireIdentity();
wireIdle();
wireBrowse();
wireWhitelist();
wireSettings();
wireOnboard();
wireStartup();
start();
