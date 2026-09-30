#!/usr/bin/env bash
# test-package-repair-host.sh — Mac 端打包指令的行為測試（design D13，工單
# 10.2 的 test 半；介面以 EPHEMERAL-INTERFACE.md §7 為準）。
#
# 在防什麼（真線會咬人的那一種）：
#   改版後**一份安裝包給全家**（D13）：同一份包可以交給每一位家人，包裡不
#   能有任何「每台不同」的東西——否則「一份包」只是說好聽的，實際上是每台
#   各做一份、而錯誤的那一份會把家人 A 的名字/port 裝到家人 B 的機器上。
#   每台不同的東西在改版後全部改成**執行期**取得：名字來自啟動器（D12）、
#   port 從專用段現場挑（D10）。
#
# ============================================================================
# 這支測試定義的介面（impl 落地時照這個；要改介面先問 PM）
# ============================================================================
#
#   ops-scripts/package-repair-host --key-dir <dir> --out <dir>
#                                   --image-sha256 <sha256>
#                                   [--image-url <url>] [--contact-name <name>]
#                                   [--vbox-version <v>] [--vbox-build <b>]
#                                   [--vbox-sha256 <sha>]
#                                   [--include-image --image-file <f>]
#
#   （與舊介面的差別：**沒有 `--name`、沒有 `--seed-dir`**——包不再屬於某
#     一台家人；共用的隧道私鑰來自 setup-repair-key 的 --key-dir。）
#
#   讀（全部經 gh；**不寫任何 GitHub var**）：
#     * CLIENT_* 快照（排除 CLIENT_ACTIONS——與 register-repair-host 同紀律）
#     * NODE_GATEWAY 的 SSH port 與 `ports.repair`（段：預設 [2400,2499]）
#   產出（$OUT/，mode 700）：
#     * Install.cmd、Install-RepairHost.ps1、Start-RepairLauncher.ps1
#     * repair-config.json：`vmName` 固定 `mlp-repair-host`、**沒有
#       `nodeName`**、含 `ports.repair` 段與 Gateway SSH port、映像／VBox
#       的 URL 與 SHA（不含任何家人名字）
#     * 開機資料：user-data（含共用隧道私鑰、CLIENT_* 快照的公鑰）
#       ＋ meta-data（`local-hostname` 不存在或固定 `mlp-repair-host`）
#     * MANIFEST.sha256、README-FAMILY.txt
#
# 要驗的（對應工單第 3 點）：
#   1. 沒有 `--name`（舊旗標現在是未知參數）；正常路徑不含它也會成功
#   2. 包裡不含任何每台不同的資料：config 沒有 `nodeName`、
#      `vmName == "mlp-repair-host"`、meta-data 的 hostname 不是家人名字；
#      另外跑一次**相同輸入**的打包，內容逐位元組相同（除 instance-id）
#   3. 含 port 段：`ports.repair` 與 Gateway SSH port 都進 config，
#      段值來自 NODE_GATEWAY（不是寫死的常數——測試用非預設段值驗）
#   4. 不寫 GitHub var：假 gh 的 log 裡零次 `variable set`
#   5. CLIENT_ACTIONS 不在：開機資料含一般 client 公鑰、不含 actions 公鑰
#   6. 缺私鑰就拒絕：--key-dir 沒有 id_tunnel → rc 非 0、訊息說明、
#      輸出目錄不存在或為空
#
# ---- 這支測試看不到什麼（誠實記在這裡）------------------------------------
# * 假 gh：真 `gh api --paginate` 的逐頁與權限不驗。
# * 不開 VM、不驗 cloud-init 解析；只驗 bundle 的檔案內容與形狀。
# * `.ps1` 的 PowerShell 語法不在這裡（impl 的工單有語言層檢查）。
# * 「相同輸入兩次打包逐位元組相同」若實作放入時間戳（例如 instance-id
#   帶時間），以 instance-id 那一行除外；其他任何位元組差異都算不穩定。
# * 段值用非預設（[2500,2599]）驗「來自 NODE_GATEWAY」，但**段本身的合法
#   範圍**（2400–2499 是不是唯一允許）不在這裡——那是 mlp／文件的涵蓋。
#
# 紅燈現狀（2026-09-30）：現碼是舊介面（`--name`／`--seed-dir` 必填、
# `--key-dir` 未知）——全節以「打包失敗」報紅，這是工單要求的 test-first
# 形狀。`--name` 那一條也是紅（現碼必填它，本介面沒有）。
#
# 全離線；bash 3.2＋5.x。跑測試一律 </dev/null。
# Run: scripts/tests/test-package-repair-host.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

SUBJECT="ops-scripts/package-repair-host"

if [[ ! -f "$SUBJECT" ]]; then
    echo "test-package-repair-host: ${SUBJECT} is missing — every case below will FAIL" >&2
fi
for tool in jq ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: ${tool} not found on PATH" >&2; exit 1; }
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-package-repair.XXXXXX")"
trap 'rm -rf "${SANDBOX}"' EXIT INT TERM
SHIMS="${SANDBOX}/shims"
HOME_DIR="${SANDBOX}/home"
KEYDIR="${SANDBOX}/keys"
OUT="${SANDBOX}/bundle"
mkdir -p "${SHIMS}" "${HOME_DIR}" "${KEYDIR}"
chmod 700 "${KEYDIR}"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

TOOL_DIRS="$(dirname "$(command -v jq)"):$(dirname "$(command -v ssh-keygen)")"

# ---- 共用隧道金鑰（真的 ed25519，落在 key dir；與 setup-repair-key 的產物同形）
ssh-keygen -t ed25519 -N "" -C "repair-shared-test" -f "${KEYDIR}/id_tunnel" >/dev/null 2>&1
chmod 600 "${KEYDIR}/id_tunnel"
TUNNEL_PUB="$(tr -d '\r\n' < "${KEYDIR}/id_tunnel.pub")"

# ---- CLIENT_* fixtures（兩把一般 client + CLIENT_ACTIONS；金鑰是真的，值
# 形狀照 register-client 的 CONTRACT 物件）----------------------------------
CLIENT_KEY_A="${SANDBOX}/client_a"; CLIENT_KEY_B="${SANDBOX}/client_b"; CLIENT_KEY_AC="${SANDBOX}/client_ac"
ssh-keygen -t ed25519 -N "" -C "client-a" -f "${CLIENT_KEY_A}" >/dev/null 2>&1
ssh-keygen -t ed25519 -N "" -C "client-b" -f "${CLIENT_KEY_B}" >/dev/null 2>&1
ssh-keygen -t ed25519 -N "" -C "client-actions" -f "${CLIENT_KEY_AC}" >/dev/null 2>&1
CLIENT_A_PUB="$(tr -d '\r\n' < "${CLIENT_KEY_A}.pub")"
CLIENT_B_PUB="$(tr -d '\r\n' < "${CLIENT_KEY_B}.pub")"
CLIENT_AC_PUB="$(tr -d '\r\n' < "${CLIENT_KEY_AC}.pub")"
CLIENT_A_BLOB="$(printf '%s' "${CLIENT_A_PUB}" | awk '{print $2}')"
CLIENT_B_BLOB="$(printf '%s' "${CLIENT_B_PUB}" | awk '{print $2}')"
CLIENT_AC_BLOB="$(printf '%s' "${CLIENT_AC_PUB}" | awk '{print $2}')"

# NODE_GATEWAY fixture：SSH port 2100、**非預設的 repair 段**（[2500,2599]）
# ——段值必須來自這裡，不是寫死的常數。
GW_PORT="2100"
GW_REPAIR_LO="2500"
GW_REPAIR_HI="2599"
NODE_GW_VAL="$(jq -n --argjson port "${GW_PORT}" --argjson lo "${GW_REPAIR_LO}" --argjson hi "${GW_REPAIR_HI}" \
    '{name:"gateway", role:"gateway", ip:"192.0.2.10", tunnel_user:"sshproxy", port:$port,
      ports:{provider:[2220,2299], worker:[2300,2399], repair:[$lo,$hi]}}')"
CLIENT_A_VAL="$(jq -n -c --arg pk "${CLIENT_A_PUB}" '{name:"laptop", public_key:$pk, added_at:"2026-09-20T00:00:00Z"}')"
CLIENT_B_VAL="$(jq -n -c --arg pk "${CLIENT_B_PUB}" '{name:"phone", public_key:$pk, added_at:"2026-09-21T00:00:00Z"}')"
CLIENT_AC_VAL="$(jq -n -c --arg pk "${CLIENT_AC_PUB}" '{name:"actions", public_key:$pk, added_at:"2026-09-22T00:00:00Z"}')"
printf '%s\n%s\n' "${CLIENT_A_VAL}" "${CLIENT_B_VAL}" "${CLIENT_AC_VAL}" > "${SANDBOX}/client-vars.txt"

# ---- 假 gh：api 回 NODE_GATEWAY ＋ CLIENT_* 的 envelope（值形狀照真 API：
# .value 是 JSON 字串）；variable set 記一次（斷言：不得發生）；workflow
# 不該被呼叫（打包不 dispatch）；run list 以防萬一。-------------------------
cat > "${SHIMS}/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
if [[ ! -t 0 ]]; then cat > /dev/null; fi
jqf="" prev=""
for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqf="$a"
    prev="$a"
done
_emit() {
    if [[ -n "$jqf" ]]; then printf '%s' "$1" | jq -r "$jqf"
    else printf '%s\n' "$1"; fi
}
case "${1:-}" in
  api)
    env_json="$(jq -n --arg gw "${NODE_GW_VAL:?}" --rawfile cvars "${CLIENT_VARS_FILE:-/dev/null}" '
        def cvars($s): $s | split("\n") | map(select(length>0));
        {total_count: (1 + (cvars($cvars) | length)),
         variables: ([{name:"NODE_GATEWAY", value:$gw}]
                     + (cvars($cvars) | map(. as $v
                         | ($v | fromjson | .name | ascii_upcase | gsub("-"; "_")) as $n
                         | {name: ("CLIENT_" + $n), value: $v})))}')"
    _emit "$env_json"
    ;;
  variable)
    if [[ "${2:-}" == "set" ]]; then
        printf 'VARSET %s\n' "$*" >> "${GH_LOG:-/dev/null}"
    fi
    ;;
  workflow)
    printf 'DISPATCH %s\n' "$*" >> "${GH_LOG:-/dev/null}"
    ;;
esac
exit 0
FAKE
chmod +x "${SHIMS}/gh"

# ---- 執行受測指令 ------------------------------------------------------------
IMAGE_SHA="$(printf '%064d' 0 | tr '0' 'a')"
# run_pack [args...]：清紀錄再跑一次。rc→PK_RC、輸出→PK_OUT。
run_pack() {
    : > "${SANDBOX}/gh.log"
    PK_OUT="$(env -i \
        HOME="${HOME_DIR}" \
        PATH="${SHIMS}:${TOOL_DIRS}:/usr/bin:/bin:/usr/sbin:/sbin" \
        GH_REPO="testowner/testrepo" \
        GH_LOG="${SANDBOX}/gh.log" \
        NODE_GW_VAL="${NODE_GW_VAL}" \
        CLIENT_VARS_FILE="${SANDBOX}/client-vars.txt" \
        TMPDIR="${SANDBOX}" \
        bash "${REPO_ROOT}/${SUBJECT}" \
            --key-dir "${KEYDIR}" --out "${OUT}" --image-sha256 "${IMAGE_SHA}" "$@" </dev/null 2>&1)"
    PK_RC=$?
}
# bundle_files：$OUT 下的檔案。
bundle_files() { find "${OUT}" -type f 2>/dev/null; }
# bundle_matches <fixed-string>：bundle 任一檔案含它。
bundle_matches() {
    local f
    for f in $(bundle_files); do
        grep -qF -- "$1" "$f" 2>/dev/null && return 0
    done
    return 1
}

echo "=== 0. 先決條件 ==="
if [[ -f "${REPO_ROOT}/${SUBJECT}" ]]; then
    ok "0a. ${SUBJECT} 存在"
else
    bad "0a. ${SUBJECT} 不存在——本測試定義它的行為"
fi

echo "=== 1. 沒有 --name：正常路徑不含它、舊旗標是未知參數（對現碼紅） ==="
# 基準閘門：後面的斷言全部要看「新的打包路徑真的跑起來」。現碼是舊介面，
# `--key-dir` 未知 → rc 2，後面的否定式斷言（不寫 var、缺 key 才拒、
# CLIENT_ACTIONS 不在…）會**空轉成綠**（量到 0 不是證據）。所以先記下
# 基準結果，後續區塊只在前置成立時才判定。
BASE_OK=0
if [[ -f "${REPO_ROOT}/${SUBJECT}" ]]; then
    rm -rf "${OUT}"
    run_pack
    if [[ "${PK_RC}" -eq 0 ]]; then
        BASE_OK=1
        ok "1a. 正常路徑（無 --name）rc 0"
    else
        bad "1a. 打包失敗（rc=${PK_RC}）：$(printf '%s' "${PK_OUT}" | tail -2 | tr '\n' ' ')"
    fi
    rm -rf "${OUT}"
    run_pack --name fam-test
    # 只認「--name 被當成未知參數」的具體訊息。**不可以**只 grep `--name`：
    # 舊介面的 usage 文字本身含 `--name`，會在現碼上誤綠（本測試第一版
    # 就是這樣，2026-09-30 抓到）。
    if [[ "${BASE_OK}" -eq 1 ]] \
       && [[ "${PK_RC}" -ne 0 ]] \
       && printf '%s' "${PK_OUT}" | grep -qE 'unknown argument: --name|unrecognized.*--name'; then
        ok "1b. 舊旗標 --name 被當成未知參數拒絕（rc ${PK_RC}）——包不再屬於某一台"
    elif [[ "${BASE_OK}" -eq 1 ]] && [[ "${PK_RC}" -eq 0 ]]; then
        bad "1b. --name 仍被接受（rc=0）——每台不同的資料還在介面上"
    elif [[ "${BASE_OK}" -eq 1 ]]; then
        bad "1b. --name 被拒但訊息沒點名它是未知參數（out [$(printf '%s' "${PK_OUT}" | tail -1 | head -c 120)]）"
    else
        bad "1b. 前置不成立（基準打包失敗，rc=${PK_RC}）——無法判定 --name 的處置（預期紅）"
    fi
else
    bad "1a. ${SUBJECT} 不存在——無法驗證（預期紅）"
    bad "1b. （同上）"
fi

echo "=== 2. 包裡不含任何每台不同的資料（對現碼紅） ==="
# 全部由 BASE_OK 把關：現碼的基準打包失敗時，這些「沒有 X」的斷言不該
# 空轉成綠（沒有 bundle 所以「沒有 nodeName」不是發現）。
if [[ "${BASE_OK}" -eq 1 ]]; then
    # §1b 的 --name 測試把 $OUT 刪掉了；這裡重跑一次基準打包（§2 的對象）。
    rm -rf "${OUT}"
    run_pack
    if [[ -s "${OUT}/repair-config.json" ]]; then
        if jq -e 'has("nodeName") | not' "${OUT}/repair-config.json" >/dev/null 2>&1; then
            ok "2a. repair-config.json 沒有 nodeName（不再釘某一台家人的名字）"
        else
            bad "2a. config 仍有 nodeName=$(jq -r '.nodeName // "<none>"' "${OUT}/repair-config.json" 2>/dev/null)"
        fi
        if jq -e '.vmName == "mlp-repair-host"' "${OUT}/repair-config.json" >/dev/null 2>&1; then
            ok "2b. vmName 固定 mlp-repair-host（全家同一台 VM 名）"
        else
            bad "2b. vmName 不是固定值（got [$(jq -r '.vmName // "<none>"' "${OUT}/repair-config.json" 2>/dev/null)]）"
        fi
    else
        bad "2a. 沒有 repair-config.json（pack 失敗？rc=${PK_RC}）"
        bad "2b. （同上）"
    fi
    # meta-data 的 hostname：不存在或固定 mlp-repair-host（名字執行期才給）。
    if [[ -f "${OUT}/meta-data" ]]; then
        lh="$(sed -n 's/^local-hostname:[[:space:]]*//p' "${OUT}/meta-data" | head -1)"
        if [[ -z "${lh}" || "${lh}" == "mlp-repair-host" ]]; then
            ok "2c. meta-data 的 hostname 是空的或固定 mlp-repair-host"
        else
            bad "2c. meta-data 釘了 hostname [${lh}]——名字必須執行期由啟動器給"
        fi
    else
        bad "2c. 沒有 meta-data"
    fi
    # 相同輸入的第二次打包：內容逐位元組相同（instance-id 除外）。
    if [[ -s "${OUT}/user-data" ]]; then
        cp "${OUT}/user-data" "${SANDBOX}/user-data.first"
        rm -rf "${OUT}"
        run_pack
        if cmp -s "${SANDBOX}/user-data.first" "${OUT}/user-data" 2>/dev/null; then
            ok "2d. 相同輸入兩次打包的 user-data 逐位元組相同（無每台／每次變動的內容）"
        else
            bad "2d. 兩次打包的 user-data 不同——內容含變動資料（diff [$(
                diff "${SANDBOX}/user-data.first" "${OUT}/user-data" 2>/dev/null | head -4 | tr '\n' ' ')]）"
        fi
    else
        bad "2d. 沒有 user-data（pack 失敗？）"
    fi
else
    bad "2a. 前置不成立（基準打包失敗，rc=${PK_RC}）——無 bundle 可驗（預期紅）"
    bad "2b. （同上）"; bad "2c. （同上）"; bad "2d. （同上）"
fi

echo "=== 3. port 段進 config（值來自 NODE_GATEWAY，非寫死；對現碼紅） ==="
if [[ "${BASE_OK}" -eq 1 ]]; then
    if [[ -s "${OUT}/repair-config.json" ]]; then
        if jq -e --argjson lo "${GW_REPAIR_LO}" --argjson hi "${GW_REPAIR_HI}" \
            '.ports.repair == [$lo, $hi]' "${OUT}/repair-config.json" >/dev/null 2>&1; then
            ok "3a. config 的 ports.repair == [${GW_REPAIR_LO},${GW_REPAIR_HI}]（來自 NODE_GATEWAY fixture）"
        else
            bad "3a. ports.repair 不是 fixture 的值（got [$(jq -c '.ports.repair // "<none>"' "${OUT}/repair-config.json" 2>/dev/null)]）——段值寫死或沒抄進去"
        fi
        if jq -e --argjson p "${GW_PORT}" '.gatewaySshPort == $p' "${OUT}/repair-config.json" >/dev/null 2>&1; then
            ok "3b. config 帶 Gateway SSH port（${GW_PORT}）"
        else
            bad "3b. config 沒有 Gateway SSH port（got [$(jq -r '.gatewaySshPort // "<none>"' "${OUT}/repair-config.json" 2>/dev/null)]）"
        fi
    else
        bad "3a. 沒有 repair-config.json"
        bad "3b. （同上）"
    fi
else
    bad "3a. 前置不成立（基準打包失敗）——無 config 可驗（預期紅）"
    bad "3b. （同上）"
fi

echo "=== 4. 不寫任何 GitHub var（回歸保護；由 BASE_OK 把關） ==="
if [[ "${BASE_OK}" -eq 1 ]]; then
    if ! grep -q 'variable set' "${SANDBOX}/gh.log" 2>/dev/null; then
        ok "4a. 假 gh 的 log 零次 variable set"
    else
        bad "4a. 打包竟然寫了 GitHub var（log [$(grep 'variable set' "${SANDBOX}/gh.log" | head -1 | head -c 120)]）"
    fi
    if ! grep -q 'DISPATCH' "${SANDBOX}/gh.log" 2>/dev/null; then
        ok "4b. 也沒有 dispatch 任何 workflow"
    else
        bad "4b. 打包竟然 dispatch 了 workflow（log [$(grep DISPATCH "${SANDBOX}/gh.log" | head -1 | head -c 120)]）"
    fi
else
    bad "4a. 前置不成立（基準打包失敗）——「沒寫 var」不具資訊量（預期紅）"
    bad "4b. （同上）"
fi

echo "=== 5. CLIENT_ACTIONS 不在開機資料；一般 client 在（對現碼紅） ==="
if [[ "${BASE_OK}" -eq 1 ]]; then
    if bundle_matches "${CLIENT_A_BLOB}" && bundle_matches "${CLIENT_B_BLOB}"; then
        ok "5a. 一般 client 公鑰（laptop／phone）在開機資料裡"
    else
        bad "5a. 一般 client 公鑰不在（A in？[$(bundle_matches "${CLIENT_A_BLOB}" && echo y || echo n)] B in？[$(bundle_matches "${CLIENT_B_BLOB}" && echo y || echo n)]）"
    fi
    if ! bundle_matches "${CLIENT_AC_BLOB}"; then
        ok "5b. CLIENT_ACTIONS 的公鑰不在（Actions 不進家人 VM）"
    else
        bad "5b. CLIENT_ACTIONS 的公鑰出現在 bundle 裡——能跑 workflow 的東西就能進家人的網路"
    fi
else
    bad "5a. 前置不成立（基準打包失敗）——無 bundle 可掃（預期紅）"
    bad "5b. （同上）"
fi

echo "=== 6. 缺私鑰就拒絕（對現碼紅：現碼不看 --key-dir） ==="
if [[ -f "${REPO_ROOT}/${SUBJECT}" ]]; then
    EMPTY_KEYS="${SANDBOX}/empty-keys"; rm -rf "${EMPTY_KEYS}"; mkdir -p "${EMPTY_KEYS}"; chmod 700 "${EMPTY_KEYS}"
    EMPTY_OUT="${SANDBOX}/bundle-nokey"; rm -rf "${EMPTY_OUT}"
    : > "${SANDBOX}/gh.log"
    PK_OUT="$(env -i \
        HOME="${HOME_DIR}" \
        PATH="${SHIMS}:${TOOL_DIRS}:/usr/bin:/bin:/usr/sbin:/sbin" \
        GH_REPO="testowner/testrepo" GH_LOG="${SANDBOX}/gh.log" \
        NODE_GW_VAL="${NODE_GW_VAL}" CLIENT_VARS_FILE="${SANDBOX}/client-vars.txt" \
        TMPDIR="${SANDBOX}" \
        bash "${REPO_ROOT}/${SUBJECT}" \
            --key-dir "${EMPTY_KEYS}" --out "${EMPTY_OUT}" --image-sha256 "${IMAGE_SHA}" </dev/null 2>&1)"
    PK_RC=$?
    if [[ "${PK_RC}" -ne 0 ]]; then
        # 前置成立的判準不是「rc 非 0」而是「rc 非 0 **且基準會成功**」：
        # 現碼對整個新介面都 rc 2，這條會在前置不成立時說清楚。
        if [[ "${BASE_OK}" -eq 1 ]]; then
            ok "6a. 缺私鑰（key dir 空）→ rc ${PK_RC}（非 0，拒絕）"
        else
            bad "6a. 前置不成立：rc ${PK_RC} 可能只是新介面未落地（基準打包也失敗）——本條在 impl 落地後才有資訊量"
        fi
    else
        bad "6a. 缺私鑰竟接受了（rc=0）——包裡沒有隧道鑰，家人永遠連不上"
    fi
    if [[ "${BASE_OK}" -eq 1 ]]; then
        if printf '%s' "${PK_OUT}" | grep -qiE 'key|金鑰|id_tunnel|missing|not found'; then
            ok "6b. 拒絕訊息說明與 key 有關"
        else
            bad "6b. 拒絕訊息沒說原因（out [$(printf '%s' "${PK_OUT}" | tr '\n' '|' | head -c 160)]）"
        fi
        if [[ ! -e "${EMPTY_OUT}" || -z "$(find "${EMPTY_OUT}" -type f 2>/dev/null)" ]]; then
            ok "6c. 拒絕時沒有產出任何 bundle 檔案"
        else
            bad "6c. 拒絕時仍寫了檔案（[$(find "${EMPTY_OUT}" -type f 2>/dev/null | head -n 3 | tr '\n' ' ')]）"
        fi
    else
        bad "6b. 前置不成立：訊息可能只是舊介面的 usage／unknown-argument，不是在講缺 key（預期紅）"
        bad "6c. 前置不成立：沒有產出是因為整個介面未落地，不是「拒絕時不寫」（預期紅）"
    fi
else
    bad "6a-6c. ${SUBJECT} 不存在——無法驗證（預期紅）"
fi

echo
printf 'passed %d / failed %d\n' "${pass}" "${fail}"
[[ "${fail}" -ne 0 ]] && exit 1
exit 0
