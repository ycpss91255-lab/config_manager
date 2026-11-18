#!/usr/bin/env bash
#
# 「清理只處理本次擁有的資源」的對照組（#356，T25／T26 的服務實測與演練）。
#
# 名稱不同只是手段：清理安不安全，不從名稱推定。所以在被測的腳本（compose_smoke.sh、
# backup_drill.sh）跑之前，先在同一個 docker daemon 上放幾組**別的擁有者**的同類資源；
# 被測的腳本跑完、清完之後，核對它們都還在，而且就是原本那幾個（識別不變）：
#
#   另一個 run       GITHUB_RUN_ID=0
#   另一個 attempt   GITHUB_RUN_ATTEMPT=0
#   另一個 job       GITHUB_JOB=bystander
#   以本次的鍵開頭   <本次的鍵>0——擋住用名稱前綴或子字串挑資源的清理（docker 的 name 過濾
#                    就是子字串比對）
#
# 每一組各有一個映像、一個容器、一個資料卷，名稱與標籤照被測的腳本會用的樣子取
# （script/ci_owner.sh）。前三組的鍵由 script/ci_key.sh 算，不在這裡另寫一份格式。
#
# 只在 CI 的 Linux runner 上執行（compose-smoke、backup-drill 兩個 job），要 docker daemon。
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_ROOT

usage() {
  cat <<'USAGE'
用法：script/ci_bystanders.sh plant <清單檔>
      script/ci_bystanders.sh check <清單檔>

  plant  在同一個 daemon 上建立四組別的擁有者的映像、容器、資料卷，記進清單檔。
         要有 CM_CI_KEY（script/ci_key.sh --github-env 寫的）與 runner 給的 GITHUB_* 變數。
  check  核對清單檔裡的每一個資源都還在、識別不變，然後把它們全部移除。
         有任何一個不見或被換掉就以 1 結束並逐一指名；清單檔不存在或是空的以 2 結束。
USAGE
}

refuse() {
  printf 'ci_bystanders: %s。下一步：%s\n' "$1" "$2" >&2
  exit 2
}

# 別的擁有者的四個鍵，一行一個。
other_keys() {
  local key="$1"
  GITHUB_RUN_ID=0 "${REPO_ROOT}/script/ci_key.sh"
  GITHUB_RUN_ATTEMPT=0 "${REPO_ROOT}/script/ci_key.sh"
  GITHUB_JOB=bystander "${REPO_ROOT}/script/ci_key.sh"
  printf '%s0\n' "${key}"
}

plant() {
  local manifest="$1"
  [[ -n "${CM_CI_KEY:-}" ]] \
    || refuse "CM_CI_KEY 沒有值，不知道哪一個是本次的擁有者" "先跑 script/ci_key.sh --github-env"
  [[ ! -e "${manifest}" ]] \
    || refuse "清單檔 ${manifest} 已經存在，不覆蓋它" "換一個新的路徑"
  local -a keys=()
  mapfile -t keys < <(other_keys "${CM_CI_KEY}")
  ((${#keys[@]} == 4)) \
    || refuse "算出來的別的擁有者鍵不是四個（${keys[*]:-沒有}）" "看上面 script/ci_key.sh 印出的原因"

  local other image container volume id created
  for other in "${keys[@]}"; do
    [[ "${other}" != "${CM_CI_KEY}" ]] \
      || refuse "別的擁有者鍵 ${other} 與本次的鍵相同，對照組不成立" "檢查 script/ci_key.sh 的格式"
    image="config_manager:runtime-${other}"
    container="config_manager_backend-${other}"
    volume="${other}_config_repo"
    # 空的映像：不必拉任何東西，只要一個帶標籤、名稱照樣子取的映像。CMD 不會被執行，容器只建不起。
    id="$(tar -cf - -T /dev/null | docker image import \
      --change "LABEL cm.ci.owner=${other}" --change 'CMD ["/bystander"]' - "${image}")"
    printf 'image %s %s\n' "${image}" "${id}" >>"${manifest}"
    id="$(docker container create --name "${container}" \
      --label "cm.ci.owner=${other}" --label "com.docker.compose.project=${other}" \
      --label com.docker.compose.service=backend "${image}")"
    printf 'container %s %s\n' "${container}" "${id}" >>"${manifest}"
    docker volume create --label "cm.ci.owner=${other}" --label "com.docker.compose.project=${other}" \
      --label com.docker.compose.volume=config_repo "${volume}" >/dev/null
    created="$(docker volume inspect --format '{{.CreatedAt}}' "${volume}")"
    printf 'volume %s %s\n' "${volume}" "${created}" >>"${manifest}"
    printf 'ci_bystanders: 放好別的擁有者 %s 的映像、容器、資料卷\n' "${other}"
  done
}

# identity <種類> <名稱> —— 現在 daemon 上那個資源的識別；不在就印空字串。
identity() {
  case "$1" in
    image) docker image inspect --format '{{.Id}}' "$2" 2>/dev/null || true ;;
    container) docker container inspect --format '{{.Id}}' "$2" 2>/dev/null || true ;;
    volume) docker volume inspect --format '{{.CreatedAt}}' "$2" 2>/dev/null || true ;;
  esac
}

check() {
  local manifest="$1"
  [[ -s "${manifest}" ]] \
    || refuse "清單檔 ${manifest} 不存在或是空的，沒有對照組可以核對——這不是通過" "確認同一個 job 先跑過 plant"
  local kind name want now
  local -a missing=() containers=() volumes=() images=()
  while read -r kind name want; do
    now="$(identity "${kind}" "${name}")"
    if [[ "${now}" != "${want}" ]]; then
      missing+=("${kind} ${name}（原本 ${want}，現在 ${now:-不在}）")
    fi
    case "${kind}" in
      image) images+=("${name}") ;;
      container) containers+=("${name}") ;;
      volume) volumes+=("${name}") ;;
    esac
  done <"${manifest}"

  # 對照組用完就收。容器先收，映像與資料卷才收得掉。
  docker container rm --force "${containers[@]}" >/dev/null 2>&1 || true
  docker volume rm --force "${volumes[@]}" >/dev/null 2>&1 || true
  docker image rm --force "${images[@]}" >/dev/null 2>&1 || true

  if ((${#missing[@]} > 0)); then
    local joined
    joined="$(printf '%s；' "${missing[@]}")"
    printf 'ci_bystanders: 清單檔 %s 裡別的擁有者的資源被動到了：%s\n' "${manifest}" "${joined%；}" >&2
    printf 'ci_bystanders: 下一步：檢查 script/ci_owner.sh 的 owner_sweep 與被測腳本的清理——只能照完整的 cm.ci.owner=<本次的鍵> 或本次的 compose 專案挑資源，不能照名稱前綴、子字串或沒有值的標籤挑\n' >&2
    exit 1
  fi
  printf 'ci_bystanders: 通過 別的擁有者的 %d 個資源（%d 組）都還在、識別不變\n' \
    "$((${#images[@]} + ${#containers[@]} + ${#volumes[@]}))" "${#images[@]}"
}

main() {
  case "${1:-}" in
    plant | check)
      [[ $# -eq 2 ]] || {
        usage >&2
        return 2
      }
      "$1" "$2"
      ;;
    -h | --help) usage ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
