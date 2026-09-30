#!/usr/bin/env bash
# test-setup-repair-key.sh — Mac 端共用跳板金鑰設定指令的行為測試（design D9，
# 工單 10.2 的 test 半；介面以 EPHEMERAL-INTERFACE.md §7 為準）。
#
# 在防什麼（真線會咬人的那一種）：
#   新版臨時跳板用**一把共用的隧道金鑰**（REPAIR_TUNNEL_PUBKEY），全家的
#   安裝包都用它。這把鑰匙的存在與更換全靠 `ops-scripts/setup-repair-key`
#   這一條指令：產生金鑰對、把**公鑰**寫進 GitHub var、觸發 refresh 並等
#   結果。它做錯的三種方式各自傷法不同：
#     * 私鑰印出來／流進 argv → 洩漏（私鑰只該留在 key dir）
#     * 已存在的金鑰被覆蓋 → 全家已發出的安裝包全部失效（且無聲）
#     * 寫了 var 但 refresh 沒等 → 「設定完成」是假的，Gateway 還沒授權
#
# ============================================================================
# 這支測試定義的介面（impl 落地時照這個；要改介面先問 PM）
# ============================================================================
#
#   ops-scripts/setup-repair-key [--key-dir DIR] [--rotate]
#
#   --key-dir DIR  金鑰目錄（預設 ~/.config/mlp/repair-tunnel/），mode 700。
#                  私鑰 id_tunnel（ed25519，mode 600）＋公鑰 id_tunnel.pub。
#   --rotate       已存在金鑰對時：重新產生（換鑰）而不是拒絕。
#
#   行為：
#     1. 目錄不存在 → 建立（mode 700）；權限比 700 寬 → 收緊或拒絕
#     2. 目錄裡沒有金鑰對 → 產生（真 ed25519；本測試用真 ssh-keygen，
#        假的看不出 -f/-N 寫錯）
#     3. 已有金鑰對且**沒有** --rotate → **拒絕**（rc 非 0、訊息說明、
#        金鑰位元組不變、零次 gh 呼叫）
#     4. 已有金鑰對或有 --rotate → 產生新對；舊公鑰不再被寫出
#     5. 寫 `REPAIR_TUNNEL_PUBKEY`（**單行公鑰**，不是 JSON）；值經 stdin
#        給 gh（不放 argv——與 register-client 同一紀律）
#     6. dispatch `refresh-authorized-keys.yml` 並等結果（沿用
#        scripts/lib/refresh-wait.sh 的 dispatch_refresh_and_wait；測試的
#        假 gh 走 nonce 標題回放，與 test-register-repair-host.sh 同手法）
#     7. 私鑰**不得**出現在 stdout／stderr／任何 gh 的 argv／任何 gh 的
#        stdin（公鑰寫 var 的那一次除外——那是公鑰）
#     8. `--rotate` 寫 var 失敗（原子性，工單 test-setup-rotate-atomic）：
#        指令非零並指名；**舊金鑰對逐位元組保留**（先發布成功、才取代舊鑰）、
#        無殘留暫存金鑰檔、私鑰不外洩。現碼的預期紅＝舊鑰被刪。
#
# 可測試性覆寫（只給這支測試用）：
#   GH_REPO            假 repo（假 gh 只認它）
#   HOME               沙盒（預設 key dir 落在 $HOME 下時用到）
#
# 紅燈現狀（2026-09-30）：`ops-scripts/setup-repair-key` **還不存在**——
# 全節以「不存在」報紅，這是工單要求的 test-first 形狀。
#
# ---- 這支測試看不到什麼（誠實記在這裡）------------------------------------
# * 假 gh：真 `gh variable set` 的權限、真 refresh 的 nonce 進 displayTitle
#   （refresh-wait.sh 檔頭已列為未驗）都不在這裡。
# * 目錄權限只驗「建立後是 700」與「已存在 755 時不會被動用」；不做 ACL、
#   不做 mount 選項等平台差異。
# * ssh-keygen 的產物只驗「是 ed25519、公私成對」；不驗熵源。
# * `--rotate` 的舊公鑰「不再被寫出」是指「這次沒有把舊值寫進 var」；
#   舊公鑰檔案會被覆蓋，但舊 var 值是否已從 Gateway 撤下屬 refresh 的涵蓋。
#
# 全離線；bash 3.2＋5.x。跑測試一律 </dev/null。
# Run: scripts/tests/test-setup-repair-key.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

SUBJECT="ops-scripts/setup-repair-key"

if [[ ! -f "$SUBJECT" ]]; then
    echo "test-setup-repair-key: ${SUBJECT} does not exist yet — the RED lines below are expected; this test defines its behaviour" >&2
fi
for tool in jq ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: ${tool} not found on PATH" >&2; exit 1; }
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-setup-repair-key.XXXXXX")"
trap 'rm -rf "${SANDBOX}"' EXIT INT TERM
SHIMS="${SANDBOX}/shims"
HOME_DIR="${SANDBOX}/home"
KEYDIR="${SANDBOX}/keys"
mkdir -p "${SHIMS}" "${HOME_DIR}"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# file_mode <path> — GNU/BSD stat 的旗標不同：BSD 是 `-f '%Lp'`，GNU 是
# `-c '%a'` **而且 GNU 把 `-f` 當「檔案系統資訊」**（照樣 exit 0 並印一坨
# 東西，所以 `BSD || GNU` 的順序在 Linux 上會拿到整段 FS 資訊——2026-09-30
# 在 ubuntu 容器實測）。先試 GNU（BSD 沒有 -c，會失敗落回 BSD）。
file_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"
    else stat -f '%Lp' "$1"; fi
}

# file_sha256 <path> — shasum 是 macOS 內建／perl 附帶，最小 ubuntu 映像沒有；
# sha256sum 是 coreutils。兩個都缺時回傳空字串，呼叫端必須自己處理「拿不到
# 摘要」＝不能當成「沒被動過」（空比空是假綠）。
file_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        printf '%s' ""
    fi
}

# 受測指令需要的工具目錄（env -i 之下仍要有 jq／ssh-keygen）。
TOOL_DIRS="$(dirname "$(command -v jq)"):$(dirname "$(command -v ssh-keygen)")"

# ---- 假 gh：記 argv、stdin 落檔；variable set 收 stdin；workflow run 記
# dispatch；run list/view 回放 nonce 標題（refresh-wait.sh 的認領機制）----
cat > "${SHIMS}/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
if [[ ! -t 0 ]]; then cat > "${GH_STDIN_DIR:-/dev/null}/stdin.$$" 2>/dev/null || true; fi
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
  variable)
    if [[ "${2:-}" == "set" ]]; then
        # 把這次寫的 var 名與 stdin 內容成對記下（stdin 已在上面落檔）。
        cp "${GH_STDIN_DIR}"/stdin.$$ "${GH_SET_FILE:-/dev/null}" 2>/dev/null || true
        printf '%s\n' "$*" >> "${GH_SET_LOG:-/dev/null}"
        # 注入用：GH_FAIL_SET=1 時模擬「GitHub 當下不可達」——寫 var 失敗。
        if [[ "${GH_FAIL_SET:-0}" == "1" ]]; then exit 1; fi
    fi
    ;;
  workflow)
    if [[ "${2:-}" == "run" ]]; then
        printf 'DISPATCH %s\n' "$*" >> "${GH_LOG:-/dev/null}"
        printf '%s' "$*" > "${GH_DISPATCH_ARGS:-/dev/null}"
    fi
    ;;
  run)
    case "${2:-}" in
      list)
        _t=""
        [[ -f "${GH_DISPATCH_ARGS:-/nonexistent}" ]] \
            && _t="refresh-authorized-keys: $(cat "${GH_DISPATCH_ARGS}")"
        _emit "$(jq -c -n --arg t "$_t" \
            '[{databaseId:999,status:"completed",conclusion:"success",displayTitle:$t}]')" ;;
      view) _emit '{"status":"completed","conclusion":"success"}' ;;
    esac
    ;;
esac
exit 0
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "${SHIMS}/sleep"
chmod +x "${SHIMS}/gh" "${SHIMS}/sleep"

# ---- 執行受測指令 ------------------------------------------------------------
# run_subject [args...]：清紀錄再跑一次。rc→SUBJ_RC、輸出→SUBJ_OUT。
# GH_FAIL_SET=1（呼叫端以環境變數帶入）模擬寫 var 失敗。
run_subject() {
    rm -rf "${SANDBOX}/gh-stdins"
    mkdir -p "${SANDBOX}/gh-stdins"
    : > "${SANDBOX}/gh.log"
    : > "${SANDBOX}/gh-set.log"
    : > "${SANDBOX}/gh-set-file"
    rm -f "${SANDBOX}/gh-dispatch-args"
    SUBJ_OUT="$(env -i \
        GH_FAIL_SET="${GH_FAIL_SET:-0}" \
        HOME="${HOME_DIR}" \
        PATH="${SHIMS}:${TOOL_DIRS}:/usr/bin:/bin:/usr/sbin:/sbin" \
        GH_REPO="testowner/testrepo" \
        GH_LOG="${SANDBOX}/gh.log" \
        GH_STDIN_DIR="${SANDBOX}/gh-stdins" \
        GH_SET_LOG="${SANDBOX}/gh-set.log" \
        GH_SET_FILE="${SANDBOX}/gh-set-file" \
        GH_DISPATCH_ARGS="${SANDBOX}/gh-dispatch-args" \
        POOL_REFRESH_POLL_INTERVAL=0 \
        TMPDIR="${SANDBOX}" \
        bash "${REPO_ROOT}/${SUBJECT}" "$@" </dev/null 2>&1)"
    SUBJ_RC=$?
}

# gh_set_value：最後一次 variable set 的 stdin（寫進 var 的值）。
gh_set_value() { cat "${SANDBOX}/gh-set-file" 2>/dev/null; }
# private material anywhere it must not be：回傳 0＝有洩漏。
# 注意用 `grep -qF -- "$needle"`（needle 以 `-` 開頭時會被當選項）；
# 金鑰內容以 `-----BEGIN` 開頭——少了 `--` 會讓 grep 自己炸掉，
# 而爆掉的 grep 回非 0，「沒洩漏」就變成假綠（本測試第一版就是這樣）。
leaks_private_key() {
    local priv="${KEYDIR}/id_tunnel" needle
    [[ -f "${priv}" ]] || return 1
    needle="$(head -c 40 "${priv}")"
    # argv（gh log）
    grep -qF -- "${needle}" "${SANDBOX}/gh.log" 2>/dev/null && return 0
    # stdout/stderr（受測指令輸出）
    printf '%s' "${SUBJ_OUT}" | grep -qF -- "${needle}" && return 0
    # gh 的 stdin 檔（公鑰那次除外——公鑰不含 PRIVATE KEY 字樣）
    local f
    for f in "${SANDBOX}"/gh-stdins/*; do
        [[ -f "${f}" ]] || continue
        grep -qF -- 'PRIVATE KEY' "${f}" 2>/dev/null && return 0
    done
    return 1
}

echo "=== 0. 先決條件（紅測試的預期入口） ==="
if [[ -f "${REPO_ROOT}/${SUBJECT}" ]]; then
    ok "0a. ${SUBJECT} 存在"
else
    bad "0a. ${SUBJECT} 不存在——本測試定義它的行為；impl 落地前這裡是紅（預期）"
fi

echo "=== 1. 首次設定：產金鑰對、目錄 700、私鑰 600 ==="
if [[ -f "${REPO_ROOT}/${SUBJECT}" ]]; then
    rm -rf "${KEYDIR}"
    run_subject --key-dir "${KEYDIR}"
    if [[ "${SUBJ_RC}" -eq 0 ]]; then
        ok "1a. 首次設定 rc 0"
    else
        bad "1a. 首次設定失敗（rc=${SUBJ_RC}）：$(printf '%s' "${SUBJ_OUT}" | tail -2 | tr '\n' ' ')"
    fi
    if [[ -f "${KEYDIR}/id_tunnel" && -f "${KEYDIR}/id_tunnel.pub" ]]; then
        ok "1b. 產出金鑰對（${KEYDIR}/id_tunnel＋.pub）"
    else
        bad "1b. 缺金鑰檔（dir=[$(ls "${KEYDIR}" 2>/dev/null | tr '\n' ' ')]）"
    fi
    dir_mode="$(file_mode "${KEYDIR}")"
    if [[ "${dir_mode}" == "700" ]]; then
        ok "1c. key dir mode 700"
    else
        bad "1c. key dir mode=${dir_mode:-?}（期望 700）"
    fi
    key_mode="$(file_mode "${KEYDIR}/id_tunnel")"
    if [[ "${key_mode}" == "600" ]]; then
        ok "1d. 私鑰 mode 600"
    else
        bad "1d. 私鑰 mode=${key_mode:-?}（期望 600）"
    fi
    # 是 ed25519、公私成對（ssh-keygen -y 驗）。
    derived="$(ssh-keygen -y -f "${KEYDIR}/id_tunnel" 2>/dev/null | awk '{print $2}')"
    pub_blob="$(awk '{print $2}' "${KEYDIR}/id_tunnel.pub" 2>/dev/null)"
    if [[ -n "${derived}" && "${derived}" == "${pub_blob}" ]]; then
        ok "1e. 金鑰是 ed25519 且公私成對（ssh-keygen -y 驗證）"
    else
        bad "1e. 公私不成對或不是 ed25519（derived [${derived:0:20}]… pub [${pub_blob:0:20}]…）"
    fi
    # 寫 var：名字正確、值是單行公鑰（不是 JSON）。
    if [[ -s "${SANDBOX}/gh-set.log" ]]; then
        if grep -q 'REPAIR_TUNNEL_PUBKEY' "${SANDBOX}/gh-set.log"; then
            ok "1f. 寫的是 REPAIR_TUNNEL_PUBKEY"
        else
            bad "1f. 寫的 var 不是 REPAIR_TUNNEL_PUBKEY（log [$(head -1 "${SANDBOX}/gh-set.log")]）"
        fi
        val="$(gh_set_value)"
        if printf '%s' "${val}" | grep -q '^ssh-ed25519 ' && [[ "$(printf '%s' "${val}" | wc -l | tr -d ' ')" -le 1 ]]; then
            ok "1g. var 值是單行 OpenSSH 公鑰（不是 JSON）"
        else
            bad "1g. var 值形狀不對（got [$(printf '%s' "${val}" | head -c 80)]）"
        fi
        if [[ "$(printf '%s' "${val}" | awk '{print $2}')" == "${pub_blob}" ]]; then
            ok "1h. var 值與 key dir 的公鑰一致"
        else
            bad "1h. var 值與公鑰不一致（var [$(printf '%s' "${val}" | awk '{print $2}' | head -c 20)]… pub [${pub_blob:0:20}]…）"
        fi
    else
        bad "1f. 沒有送出任何 variable set"
        bad "1g. （同上）"; bad "1h. （同上）"
    fi
    # dispatch refresh（等待函式會經假 gh 看到）。
    if grep -q 'workflow run.*refresh-authorized-keys' "${SANDBOX}/gh.log" 2>/dev/null; then
        ok "1i. 有觸發 refresh-authorized-keys 的 dispatch"
    else
        bad "1i. 沒有 refresh dispatch（log [$(grep '^workflow run' "${SANDBOX}/gh.log" 2>/dev/null | head -1 | head -c 120)]）——Gateway 還沒授權就說設定完成"
    fi
    # 私鑰不洩漏。
    if ! leaks_private_key; then
        ok "1j. 私鑰沒有出現在 stdout／stderr／gh argv／gh stdin"
    else
        bad "1j. 私鑰洩漏了（見 gh.log／輸出／stdin 檔）"
    fi
else
    for id in 1a 1b 1c 1d 1e 1f 1g 1h 1i 1j; do
        bad "${id}. ${SUBJECT} 不存在——無法驗證（預期紅）"
    done
fi

echo "=== 2. 已存在且沒 --rotate → 拒絕、金鑰不變、零 gh 呼叫 ==="
if [[ -f "${REPO_ROOT}/${SUBJECT}" && -f "${KEYDIR}/id_tunnel" ]]; then
    priv_before="$(file_sha256 "${KEYDIR}/id_tunnel")"
    pub_before="$(file_sha256 "${KEYDIR}/id_tunnel.pub")"
    run_subject --key-dir "${KEYDIR}"
    if [[ "${SUBJ_RC}" -ne 0 ]]; then
        ok "2a. 已存在金鑰對、未給 --rotate → rc ${SUBJ_RC}（非 0，拒絕）"
    else
        bad "2a. 沒給 --rotate 卻接受了（rc=0）——會無聲換掉全家安裝包用的鑰匙"
    fi
    priv_after="$(file_sha256 "${KEYDIR}/id_tunnel")"
    pub_after="$(file_sha256 "${KEYDIR}/id_tunnel.pub")"
    if [[ -n "${priv_before}" && "${priv_before}" == "${priv_after}" \
       && -n "${pub_before}" && "${pub_before}" == "${pub_after}" ]]; then
        ok "2b. 拒絕時金鑰位元組不變"
    else
        bad "2b. 拒絕時金鑰被動過或摘要不可得（priv [${priv_before:0:8}]→[${priv_after:0:8}] pub [${pub_before:0:8}]→[${pub_after:0:8}]）"
    fi
    if [[ ! -s "${SANDBOX}/gh.log" ]]; then
        ok "2c. 拒絕時零次 gh 呼叫（沒有寫 var、沒有 dispatch）"
    else
        bad "2c. 拒絕時仍呼叫了 gh（log [$(head -1 "${SANDBOX}/gh.log")]）"
    fi
else
    bad "2a. 前置不成立（缺 subject 或金鑰）——無法驗證（預期紅）"
    bad "2b. （同上）"; bad "2c. （同上）"
fi

echo "=== 3. --rotate → 換新金鑰，寫的新公鑰與舊不同 ==="
if [[ -f "${REPO_ROOT}/${SUBJECT}" && -f "${KEYDIR}/id_tunnel.pub" ]]; then
    old_blob="$(awk '{print $2}' "${KEYDIR}/id_tunnel.pub")"
    run_subject --key-dir "${KEYDIR}" --rotate
    if [[ "${SUBJ_RC}" -eq 0 ]]; then
        ok "3a. --rotate rc 0"
    else
        bad "3a. --rotate 失敗（rc=${SUBJ_RC}）：$(printf '%s' "${SUBJ_OUT}" | tail -2 | tr '\n' ' ')"
    fi
    new_blob="$(awk '{print $2}' "${KEYDIR}/id_tunnel.pub" 2>/dev/null)"
    if [[ -n "${new_blob}" && "${new_blob}" != "${old_blob}" ]]; then
        ok "3b. 換出新金鑰（blob 與舊不同）"
    else
        bad "3b. 金鑰沒換（old [${old_blob:0:16}]… new [${new_blob:0:16}]…）"
    fi
    val="$(gh_set_value)"
    if printf '%s' "${val}" | grep -qF "${new_blob}" && ! printf '%s' "${val}" | grep -qF "${old_blob}"; then
        ok "3c. 寫進 var 的是新公鑰，舊公鑰不再出現"
    else
        bad "3c. var 值不對（新在？[$(printf '%s' "${val}" | grep -cF "${new_blob}")] 舊在？[$(printf '%s' "${val}" | grep -cF "${old_blob}")]）"
    fi
    if ! leaks_private_key; then
        ok "3d. 換鑰路徑私鑰不洩漏"
    else
        bad "3d. 換鑰路徑私鑰洩漏了"
    fi
else
    bad "3a. 前置不成立（缺 subject 或金鑰）——無法驗證（預期紅）"
    bad "3b. （同上）"; bad "3c. （同上）"; bad "3d. （同上）"
fi

echo "=== 4. key dir 已存在且權限過寬 → 收緊或拒絕（不靜默沿用） ==="
if [[ -f "${REPO_ROOT}/${SUBJECT}" ]]; then
    LOOSE_DIR="${SANDBOX}/loose-keys"
    rm -rf "${LOOSE_DIR}"; mkdir -p "${LOOSE_DIR}"; chmod 755 "${LOOSE_DIR}"
    run_subject --key-dir "${LOOSE_DIR}"
    mode_now="$(file_mode "${LOOSE_DIR}")"
    if [[ "${SUBJ_RC}" -ne 0 ]]; then
        ok "4a. 目錄 755 → 拒絕（rc ${SUBJ_RC}），不靜默沿用過寬權限"
    elif [[ "${mode_now}" == "700" ]]; then
        ok "4b. 接受但把目錄收緊為 700（不靜默沿用）"
    else
        bad "4b. 目錄 755 被沿用（rc=0 且 mode=${mode_now:-?}）——私鑰放在別人可讀的目錄"
    fi
else
    bad "4a. ${SUBJECT} 不存在——無法驗證（預期紅）"
fi

echo "=== 5. --help 必須零副作用（self-location 探針會用它） ==="
# scripts/tests/test-script-self-location.sh 用 `--help` 驅動每一支需要自我
# 定位的 ops-script（走符號連結、在**真實環境**、預設 $HOME）。這意味著
# `--help` 必須在**碰任何東西之前**回答並 exit 0：少了這條，探針會在使用者
# 的 ~/.config/mlp 下真的產生一把金鑰、甚至呼叫 gh——實測在 2026-09-30 發生
# 過一次（proof 實作沒做 help-first，探針把真 HOME 寫進了金鑰目錄）。
# 這條測的是「無害」：在假 HOME 下跑 --help，跑完之後那個 HOME 不該多出
# 任何檔案，也不該呼叫過 gh。
if [[ -f "${REPO_ROOT}/${SUBJECT}" ]]; then
    HELP_HOME="${SANDBOX}/help-home"; rm -rf "${HELP_HOME}"; mkdir -p "${HELP_HOME}"
    : > "${SANDBOX}/gh.log"
    HELP_OUT="$(env -i \
        HOME="${HELP_HOME}" \
        PATH="${SHIMS}:${TOOL_DIRS}:/usr/bin:/bin:/usr/sbin:/sbin" \
        GH_REPO="testowner/testrepo" GH_LOG="${SANDBOX}/gh.log" \
        TMPDIR="${SANDBOX}" \
        bash "${REPO_ROOT}/${SUBJECT}" --help </dev/null 2>&1)"
    HELP_RC=$?
    if [[ "${HELP_RC}" -eq 0 ]]; then
        ok "5a. --help rc 0"
    else
        bad "5a. --help rc ${HELP_RC}（期望 0）"
    fi
    help_files="$(find "${HELP_HOME}" -type f 2>/dev/null | head -n 3 | tr '\n' ' ')"
    if [[ -z "${help_files}" ]]; then
        ok "5b. --help 沒在 HOME 下留下任何檔案（探針跑在真環境也安全）"
    else
        bad "5b. --help 留下檔案（[${help_files}]）——self-location 探針會污染真 HOME"
    fi
    if [[ ! -s "${SANDBOX}/gh.log" ]]; then
        ok "5c. --help 零 gh 呼叫"
    else
        bad "5c. --help 呼叫了 gh（log [$(head -1 "${SANDBOX}/gh.log")]）"
    fi
else
    bad "5a. ${SUBJECT} 不存在——無法驗證（預期紅）"
    bad "5b. （同上）"; bad "5c. （同上）"
fi

echo "=== 6. --rotate 寫 var 失敗 → 原子性：舊鑰逐位元組保留 ==="
# 依據 OUT-review-ephemeral-mac.md §3／建議 1：現碼 --rotate 先刪舊鑰才寫 var，
# 寫 var 失敗＝舊鑰已刪、新鑰未發布、var 未更新——本地與 var 不一致，之後打包
# 會產出「私鑰永遠連不上」的包。正確行為：舊鑰是全家已發包的根，寫 var 成功
# 之前不准動它（先產暫存、寫 var 成功才取代）。
if [[ -f "${REPO_ROOT}/${SUBJECT}" ]]; then
    rm -rf "${KEYDIR}"
    GH_FAIL_SET=0 run_subject --key-dir "${KEYDIR}"
    if [[ "${SUBJ_RC}" -eq 0 && -f "${KEYDIR}/id_tunnel" && -f "${KEYDIR}/id_tunnel.pub" ]]; then
        ok "6a. 前置：正常設定一次成功（才有舊鑰可保）"
        priv_sha_before="$(file_sha256 "${KEYDIR}/id_tunnel")"
        pub_sha_before="$(file_sha256 "${KEYDIR}/id_tunnel.pub")"
        GH_FAIL_SET=1 run_subject --key-dir "${KEYDIR}" --rotate
        if [[ "${SUBJ_RC}" -ne 0 ]]; then
            ok "6b. 寫 var 失敗 → rc ${SUBJ_RC}（非 0，且不是崩潰）"
        else
            bad "6b. 寫 var 失敗卻回報成功（rc=0）——『設定完成』是假的"
        fi
        if printf '%s' "${SUBJ_OUT}" | grep -qi 'REPAIR_TUNNEL_PUBKEY\|could not write'; then
            ok "6c. 訊息指名失敗的 var（$(printf '%s' "${SUBJ_OUT}" | grep -io 'REPAIR_TUNNEL_PUBKEY\|could not write' | head -1)）"
        else
            bad "6c. 失敗訊息沒指名（got [$(printf '%s' "${SUBJ_OUT}" | tail -1 | head -c 120)]）"
        fi
        priv_sha_after="$(file_sha256 "${KEYDIR}/id_tunnel")"
        pub_sha_after="$(file_sha256 "${KEYDIR}/id_tunnel.pub")"
        if [[ -n "${priv_sha_after}" && "${priv_sha_before}" == "${priv_sha_after}" \
           && -n "${pub_sha_after}" && "${pub_sha_before}" == "${pub_sha_after}" ]]; then
            ok "6d. 舊鑰對逐位元組保留（priv ${priv_sha_before:0:8}／pub ${pub_sha_before:0:8}）"
        else
            bad "6d. 寫 var 失敗動到了舊鑰（priv [${priv_sha_before:0:8}]→[${priv_sha_after:0:8}] pub [${pub_sha_before:0:8}]→[${pub_sha_after:0:8}]）——已發出的包被無聲作廢"
        fi
        # 沒有殘留的暫存金鑰檔：key dir 只該有 id_tunnel 與 id_tunnel.pub。
        stray="$(ls -A "${KEYDIR}" 2>/dev/null | grep -v '^id_tunnel$' | grep -v '^id_tunnel\.pub$' | tr '\n' ' ')"
        if [[ -z "${stray}" ]]; then
            ok "6e. key dir 無殘留暫存檔（只有 id_tunnel＋.pub）"
        else
            bad "6e. 殘留暫存檔：[${stray}]"
        fi
        # 沒有殘留的暫存金鑰檔（內容掃描：整個 SANDBOX 除了本節的 KEYDIR 與
        # 第 4 節自建的 loose-keys 之外，沒有第二份私鑰材料；正確解可能用
        # 暫存名，所以不能只靠 id_tunnel* 檔名比對）。
        stray2=""
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            [[ "$f" == "${KEYDIR}/id_tunnel" ]] && continue
            [[ "$f" == "${SANDBOX}/loose-keys/"* ]] && continue
            stray2="${stray2}${f} "
        done < <(grep -rl 'PRIVATE KEY' "${SANDBOX}" 2>/dev/null | head -n 5)
        if [[ -z "${stray2}" ]]; then
            ok "6f. key dir 外無任何私鑰材料（內容掃描；loose-keys 為第 4 節既有夾具）"
        else
            bad "6f. key dir 外有私鑰材料殘留：[${stray2}]"
        fi
        if ! leaks_private_key; then
            ok "6g. 失敗路徑私鑰不洩漏（argv／stdin／輸出）"
        else
            bad "6g. 失敗路徑私鑰洩漏了"
        fi
    else
        bad "6a. 前置不成立（正常 --key-dir 設定失敗，rc=${SUBJ_RC}）——無法驗證（預期紅）"
        for id in 6b 6c 6d 6e 6f 6g; do bad "${id}. （同上）"; done
    fi
else
    bad "6a. ${SUBJECT} 不存在——無法驗證（預期紅）"
    for id in 6b 6c 6d 6e 6f 6g; do bad "${id}. （同上）"; done
fi

echo
printf 'passed %d / failed %d\n' "${pass}" "${fail}"
[[ "${fail}" -ne 0 ]] && exit 1
exit 0
