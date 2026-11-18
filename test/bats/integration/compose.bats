#!/usr/bin/env bats
#
# compose 的接線（T25、#51）——設定解析那一半。
#
# 被觀察的是 **compose 自己解出來的最終設定**（`docker-compose … config`），不是 YAML 的文字：
# 變數的預設值、疊加檔的合併、`${VAR:?…}` 的失敗都是 compose 算的。`config` 只做解析，不需要
# docker daemon，所以這一檔在工具映像裡跑，本機與 CI 是同一組。
#
# **這一檔說得出的是「compose 會照這樣起服務」。** 「這樣起的服務真的只有本機連得到」「重啟後
# 資料還在」要有真的在跑的容器，那一半在 script/compose_smoke.sh（CI 的 Linux runner）。兩種
# 結果分開報，這一檔綠了不代表那一半過了。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  RESOLVED="${BATS_TEST_TMPDIR}/resolved.json"
}

# resolve <compose 檔>… —— 解析這個組合，最終設定寫到 ${RESOLVED}。
#
# 環境是空的（`env -i`）：這台機器上碰巧設了的 CM_* 或 COMPOSE_FILE 不該決定規格的答案。要給
# 變數的規格用 `VARS=(名=值 …)`。`--env-file /dev/null` 同一個理由：開發用的簽出可能有一份
# 不在版控裡的 `.env`，讀了它，測到的是那台機器，不是這個 repo。
resolve() {
  local -a files=()
  local file
  for file in "$@"; do files+=(-f "${REPO_ROOT}/${file}"); done
  run env -i PATH="${PATH}" HOME="${BATS_TEST_TMPDIR}" "${VARS[@]}" \
    docker-compose --project-directory "${REPO_ROOT}" --env-file /dev/null \
    "${files[@]}" config --format json
  [ "${status}" -eq 0 ] && printf '%s\n' "${output}" >"${RESOLVED}"
  return 0
}

# ask <Python 運算式> —— 對最終設定問一個問題。`s` 是 services，`d` 是整份。
ask() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(eval(sys.argv[2], {"d": d, "s": d["services"]}))
' "${RESOLVED}" "$1"
}

VARS=()

# ── 預設：現場部署（定案 2）──────────────────────────────────────────────────

@test "預設解得出來，剛好兩個服務：backend 與 frontend" {
  resolve compose.yaml

  [ "${status}" -eq 0 ]
  [ "$(ask 'sorted(s)')" = "['backend', 'frontend']" ]
}

@test "預設用的是正式映像與部署模式" {
  resolve compose.yaml

  [ "$(ask '(s["backend"]["build"]["target"], s["frontend"]["build"]["target"], s["backend"]["image"], s["backend"]["environment"]["CM_MODE"])')" \
    = "('runtime', 'runtime', 'config_manager:runtime', 'deployment')" ]
}

@test "預設指到的映像階段在 Dockerfile 裡真的存在" {
  resolve compose.yaml

  grep -qE "^FROM .* AS $(ask 's["backend"]["build"]["target"]')\$" "${REPO_ROOT}/Dockerfile"
}

@test "backend 的 config-repo 掛載點與 CM_CONFIG_REPO 是同一個路徑，而且是具名 volume" {
  resolve compose.yaml

  [ "$(ask '[(v["type"], v["target"] == s["backend"]["environment"]["CM_CONFIG_REPO"]) for v in s["backend"]["volumes"] if v["source"] == "config_repo"]')" \
    = "[('volume', True)]" ]
}

@test "backend 掛進來的目標根目錄就是白名單放行的那一個" {
  VARS=(CM_TARGET_ROOT=/srv/site/config)
  resolve compose.yaml

  [ "$(ask '([v["target"] for v in s["backend"]["volumes"] if v["type"] == "bind"], s["backend"]["environment"]["CM_ALLOWED_ROOTS"])')" \
    = "(['/srv/site/config'], '/srv/site/config')" ]
}

@test "frontend 沒有任何掛載" {
  resolve compose.yaml

  [ "$(ask 's["frontend"].get("volumes", [])')" = "[]" ]
}

# ── 開發：疊上 compose.dev.yaml（定案 2）─────────────────────────────────────

@test "疊上開發檔之後是開發映像與開發模式" {
  resolve compose.yaml compose.dev.yaml

  [ "$(ask '(s["backend"]["build"]["target"], s["frontend"]["build"]["target"], s["backend"]["image"], s["backend"]["environment"]["CM_MODE"])')" \
    = "('devel', 'devel', 'config_manager:devel', 'development')" ]
}

@test "開發映像不烤原始碼，所以開發檔把主機的 src 掛進兩個服務，並讓後端的直譯器找得到它" {
  resolve compose.yaml compose.dev.yaml

  [ "$(ask '[(name, [v["target"] for v in s[name]["volumes"] if v["type"] == "bind" and v["source"].endswith("/src")]) for name in sorted(s)]')" \
    = "[('backend', ['/opt/config_manager/src']), ('frontend', ['/opt/config_manager/src'])]" ]
  [ "$(ask 's["backend"]["environment"]["PYTHONPATH"]')" = "/opt/config_manager/src" ]
}

# ── 只允許本機存取：host 網路（定案 3）───────────────────────────────────────

@test "預設是 host 網路，兩個服務都只聽 127.0.0.1" {
  resolve compose.yaml

  [ "$(ask '[(name, s[name]["network_mode"]) for name in sorted(s)]')" = "[('backend', 'host'), ('frontend', 'host')]" ]
  [ "$(ask 's["backend"]["command"][s["backend"]["command"].index("--host") + 1]')" = "127.0.0.1" ]
  [ "$(ask 's["frontend"]["command"][s["frontend"]["command"].index("--bind") + 1]')" = "127.0.0.1" ]
}

@test "host 網路下沒有任何埠號對應" {
  # host 模式的埠號對應會被 docker 丟掉；寫了等於留一行看起來有保護、其實沒作用的設定。
  resolve compose.yaml

  [ "$(ask '[s[name].get("ports", []) for name in sorted(s)]')" = "[[], []]" ]
}

@test "疊上開發檔不會把服務打開到本機以外" {
  resolve compose.yaml compose.dev.yaml

  [ "$(ask '(s["backend"]["command"][s["backend"]["command"].index("--host") + 1], s["frontend"]["command"][s["frontend"]["command"].index("--bind") + 1])')" \
    = "('127.0.0.1', '127.0.0.1')" ]
}

# ── 自動重啟（定案 4）────────────────────────────────────────────────────────

@test "現場部署的兩個服務在當掉或機器重開後自己起來，手動停掉的不會" {
  resolve compose.yaml

  [ "$(ask '[s[name]["restart"] for name in sorted(s)]')" = "['unless-stopped', 'unless-stopped']" ]
}

@test "開發不自動重啟" {
  # 開發時服務起不來是要讓人看見的；一直重試只會把第一則錯誤訊息洗掉。
  resolve compose.yaml compose.dev.yaml

  [ "$(ask '[s[name].get("restart", "no") for name in sorted(s)]')" = "['no', 'no']" ]
}

# ── bridge 網路：疊上 compose.bridge.yaml（定案 1、3）────────────────────────

@test "疊上 bridge 檔之後兩個服務都是 bridge 網路" {
  resolve compose.yaml compose.bridge.yaml

  [ "$(ask '[s[name]["network_mode"] for name in sorted(s)]')" = "['bridge', 'bridge']" ]
}

@test "bridge 下埠號對應的主機端只綁 127.0.0.1" {
  resolve compose.yaml compose.bridge.yaml

  [ "$(ask '[(name, [(p["host_ip"], p["published"], p["target"]) for p in s[name]["ports"]]) for name in sorted(s)]')" \
    = "[('backend', [('127.0.0.1', '8080', 8080)]), ('frontend', [('127.0.0.1', '8081', 8081)])]" ]
}

@test "bridge 下服務在容器內聽 0.0.0.0，對應進來的連線才到得了" {
  # 容器內聽 127.0.0.1 的話，docker 把主機的埠轉到容器的網卡上，那裡沒有人在聽。對外的限制
  # 由上一則的主機端位址負責，不是這個。
  resolve compose.yaml compose.bridge.yaml

  [ "$(ask '(s["backend"]["command"][s["backend"]["command"].index("--host") + 1], s["frontend"]["command"][s["frontend"]["command"].index("--bind") + 1])')" \
    = "('0.0.0.0', '0.0.0.0')" ]
}

# ── 主機名稱不再由環境變數決定（#385）────────────────────────────────────────
# 新納管的預設主機名稱改由介面確認後存在清單檔；容器裡的舊 CM_HOSTNAME 會讓 entrypoint 停止啟動，
# 所以三種組合都不能再把它帶進去——主機上有沒有設定都一樣。

@test "三種組合都不把 CM_HOSTNAME 帶進容器，主機有設定也一樣（#385）" {
  local combo
  for combo in "compose.yaml" "compose.yaml compose.dev.yaml" "compose.yaml compose.bridge.yaml"; do
    VARS=(CM_HOSTNAME=amr01)
    # shellcheck disable=SC2086 # 刻意拆成多個檔名
    resolve ${combo}
    [ "${status}" -eq 0 ]
    [ "$(ask 'any("CM_HOSTNAME" in (v.get("environment") or {}) for v in s.values())')" = "False" ]
  done
}

# 容器名的後綴（#356）：CI 以擁有者的鍵當後綴，讓同一個 daemon 上不同 job 的容器名不撞；
# 不設時是部署一直以來的那兩個名字，預設不變。

@test "不設 CM_NAME_SUFFIX 時容器名是 config_manager_backend 與 config_manager_frontend（#356）" {
  resolve compose.yaml

  [ "$(ask '(s["backend"]["container_name"], s["frontend"]["container_name"])')" \
    = "('config_manager_backend', 'config_manager_frontend')" ]
}

@test "設了 CM_NAME_SUFFIX 時三種組合的容器名都加上它（#356）" {
  local combo
  for combo in "compose.yaml" "compose.yaml compose.dev.yaml" "compose.yaml compose.bridge.yaml"; do
    VARS=(CM_NAME_SUFFIX=-cm-4242-1-compose-smoke)
    # shellcheck disable=SC2086 # 刻意拆成多個檔名
    resolve ${combo}
    [ "${status}" -eq 0 ]
    [ "$(ask '(s["backend"]["container_name"], s["frontend"]["container_name"])')" \
      = "('config_manager_backend-cm-4242-1-compose-smoke', 'config_manager_frontend-cm-4242-1-compose-smoke')" ]
  done
}

@test "疊上 bridge 檔不再要求 CM_HOSTNAME（#385）" {
  resolve compose.yaml compose.bridge.yaml

  [ "${status}" -eq 0 ]
}

@test "執行期目錄 /run/config_manager 不在任何掛載裡（#385）" {
  # 候選只對一次啟動有效：不是資料卷、不是 bind mount，也不是 tmpfs——它在容器自己的可寫層。
  local combo
  for combo in "compose.yaml" "compose.yaml compose.dev.yaml" "compose.yaml compose.bridge.yaml"; do
    # shellcheck disable=SC2086 # 刻意拆成多個檔名
    resolve ${combo}
    [ "${status}" -eq 0 ]
    [ "$(ask 'any(str(m.get("target", "")).startswith("/run/config_manager") or str(m).find("/run/config_manager") >= 0 for v in s.values() for m in (v.get("volumes") or []) + [{"target": t} for t in (v.get("tmpfs") or [])])')" = "False" ]
  done
}

# ── 不提供開放區網的開關（定案 3）────────────────────────────────────────────

# 一個服務「只有本機連得到」的兩種成立方式：host 網路且自己只聽 127.0.0.1（沒有埠號對應），
# 或 bridge 網路且每一條埠號對應的主機端都綁 127.0.0.1。其餘一律不算。
local_only='all(
  (v["network_mode"] == "host" and not v.get("ports")
     and "127.0.0.1" in v["command"] and "0.0.0.0" not in v["command"])
  or (v["network_mode"] == "bridge" and v.get("ports")
     and all(p.get("host_ip") == "127.0.0.1" for p in v["ports"]))
  for v in s.values())'

@test "四種組合裡沒有任何一種把服務綁到本機以外的位址" {
  local combination
  for combination in "compose.yaml" "compose.yaml compose.dev.yaml" \
                     "compose.yaml compose.bridge.yaml" "compose.yaml compose.dev.yaml compose.bridge.yaml"; do
    # shellcheck disable=SC2086  # 要的就是拆成多個檔名
    resolve ${combination}
    [ "${status}" -eq 0 ] || { printf '%s 解不出來：%s\n' "${combination}" "${output}" >&2; return 1; }
    [ "$(ask "${local_only}")" = "True" ] || { printf '%s 有服務綁到本機以外\n' "${combination}" >&2; return 1; }
  done
}

@test "環境變數改不動監聽位址" {
  # 沒有開關的意思是：就算有人設了看起來像開關的變數，解出來的位址也不變。
  VARS=(CM_HOST=0.0.0.0 CM_BIND=0.0.0.0 CM_LISTEN=0.0.0.0 HOST=0.0.0.0)
  resolve compose.yaml

  [ "$(ask "${local_only}")" = "True" ]
}

# ── 停得掉（#51 驗收條件：exec 交棒之後 SIGTERM 才送得到、容器才停得掉）──────

@test "前端用 SIGINT 當停止訊號，因為它是 PID 1 而 http.server 不接 SIGTERM" {
  # entrypoint 以 exec 交棒，服務就是 PID 1——而 PID 1 對「沒有自己裝處理函式」的訊號一律不理。
  # 後端（uvicorn）自己接 SIGTERM，停得掉；`python -m http.server` 沒接，實測要等滿 10 秒寬限
  # 才被強制終止（結束碼 137）。Python 預設會接的是 SIGINT，所以把停止訊號換成它：實測立即
  # 結束、結束碼 0。真的停得掉那一半在 script/compose_smoke.sh 量。
  local combination
  for combination in "compose.yaml" "compose.yaml compose.dev.yaml" "compose.yaml compose.bridge.yaml"; do
    # shellcheck disable=SC2086  # 要的就是拆成多個檔名
    resolve ${combination}
    [ "$(ask 's["frontend"].get("stop_signal")')" = "SIGINT" ] || { printf '%s 的前端停止訊號不是 SIGINT\n' "${combination}" >&2; return 1; }
  done
}
