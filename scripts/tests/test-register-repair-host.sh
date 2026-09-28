#!/usr/bin/env bash
# test-register-repair-host.sh — Mac 端維修承載機登錄指令的行為測試（tasks 4.1）。
#
# 在防什麼（真線會咬人的那一種）：
#   issue #6 的家人 VM 不碰 GitHub、不做任何設定，所以登錄**全部在使用者的
#   Mac 上完成**（spec「登錄全部在使用者的 Mac 上完成」）。指令暫名
#   `ops-scripts/register-repair-host`，接收名稱、provider port（2220–2299）、
#   登入公鑰檔、輸出目錄，產出：`NODE_<NAME>`（經 gh）、一次 refresh 觸發
#   （經 gh workflow run 或既有等待函式）、輸出目錄裡的「開機資料」。
#   開機資料的格式由 spike 決定（NoCloud 或同等物）——本測試**不綁檔名與
#   格式**，只綁性質。
#
# **這支測試定義的介面**（impl 落地時照這個；要改介面就同步改本檔）：
#   register-repair-host --name <name> --gateway-port <port>
#                       --login-key <path-to-login-public-key> --output-dir <dir>
#
# 要驗的（行為面；spec「登錄全部在使用者的 Mac 上完成」／「維修承載機不持有
# GitHub 權杖」）：
#   1. NODE_<NAME> 形狀：role=provider、name 正確、gateway_port=給定值、
#      capabilities 是空物件（沒有 worker-host）、沒有 power、
#      tunnel_public_key 與輸出目錄裡的隧道私鑰成對（ssh-keygen -y 驗）；
#      開機資料的 tunnel env 帶 NODE_GATEWAY 的 tunnel_user／port（§1i/§1j——
#      fixture 現在含 NODE_GATEWAY，見 review OUT-review-repair-t4.md §5b：
#      光補 fixture 不夠，沒有值斷言的話「忽略 NODE_GATEWAY」的退化仍會全綠）
#   2. port 衝突：別的 NODE_* 已用那個 port → 非 0、**零次 variable set**、
#      訊息點名衝突的機器
#   3. port 超出 2220–2299 → 拒絕、零寫入
#   4. 開機資料不含 GitHub 權杖：環境故意放 GH_TOKEN／GH_POOL_TOKEN（假值），
#      輸出目錄的任何檔案（含二進位）都不得出現那些值
#   5. 登入公鑰出現在開機資料裡；隧道金鑰與登入金鑰不是同一把
#   6. refresh 被觸發（gh workflow run refresh-authorized-keys，或等待函式）
#   7. 同名 NODE_<NAME> 已存在 → 拒絕（不覆蓋現役機器）＋零次 variable set。
#      用**全新的空輸出目錄**（不沿用前面章節的 $OUTDIR）：否則「拒絕」可能是
#      被 output-dir 守衛（目錄裡已有別台的 seed）搶先擋下，同名檢查本身從沒
#      被真正驗過（review OUT-review-repair-t4.md 發現 1）。§7a2 另外斷言拒絕
#      訊息是同名檢查的那句（"already exists"），不是 output-dir 守衛的
#      （"already holds the seed for"）。
#
# 正對照（量到 0 不算證據）：
#   * 假 gh 確實被呼叫（§1b）；
#   * 權杖掃描器先在一個故意塞了假權杖的檔案上證明看得見（§4a）；
#   * ssh-keygen -y 的配對驗證在正例上先證明會配對（§1h 的 derived 非空）。
#
# 這支測試檔本身沒有注入框架（不像 test-capability-flags.sh／
# test-callsite-lists.sh）；§7 與 §1i/§1j 的紅／綠對照改在 impl 外的一份
# scratch 複本上手動做一次，證據記在交件報告，不是本檔的斷言。
#
# ---- 這支測試看不到什麼（誠實記在這裡）------------------------------------
# * 指令**還不存在**時全節照樣執行並報紅：§0a 直接說「不存在」，其餘每節
#   在 `if [[ -f ]]` 的 else 報 bad——這是紅測試的預期形狀。
# * 不綁開機資料的檔名與格式（NoCloud user-data／meta-data／seed ISO 皆可）：
#   只掃「輸出目錄裡的所有檔案」。雲端解析不在這裡（spike 的事）。
# * 若實作產 ISO：本檔只把它當二進位檔掃內容，不驗 ISO 9660 結構。
# * 不連 GitHub、不 dispatch、不碰真機：假 gh 只記 argv 與 stdin。
# * 「port 衝突不寫任何 variable」只到「這個指令送出的寫入為零」——真 GitHub
#   的權限與 race 不在這裡。
# * 金鑰生成用真 ssh-keygen（假的不會發現 -f/-N 寫錯）；產物全在沙盒。
# * 名稱字元規範、金鑰檔不存在、輸出目錄不可寫等邊界不在本輪（工單 1–7）。
#
# 全離線；bash 3.2＋5.x。
# Run: scripts/tests/test-register-repair-host.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

SUBJECT="ops-scripts/register-repair-host"

if [[ ! -f "$SUBJECT" ]]; then
    echo "test-register-repair-host: ${SUBJECT} does not exist yet — the RED lines below are expected; this test defines its behaviour" >&2
fi
for tool in jq python3 ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: ${tool} not found on PATH" >&2; exit 1; }
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-reg-repair.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
OUTDIR="$SANDBOX/boot"
mkdir -p "$SHIMS" "$HOME_DIR" "$OUTDIR"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# 受測指令需要的工具目錄（env -i 之下仍要有 jq／ssh-keygen）。
TOOL_DIRS="$(dirname "$(command -v jq)"):$(dirname "$(command -v ssh-keygen)")"

# ---- NODE_* fixtures（.value 是 JSON 字串，形狀照真 API） --------------------
# NODE_FH_L 佔用 2222（現役 provider）；NODE_FAMILY_OLD 佔用 2250（衝突與
# 同名案例都用它）。NODE_GATEWAY 帶 tunnel_user／port，形狀照真 API（參照
# test-pool-resolve-state.sh 的 NODE_GATEWAY fixture）：沒有這個 fixture，
# read_gateway 永遠走 WARN＋佔位符分支，§1i/§1j 就無從驗證
# Gateway 的值有沒有正確落進 tunnel.env（review §5b 的發現）。
NODE_VAR_0='{"name":"fh-l","role":"provider","gateway_port":2222,"capabilities":{"worker-host":{"runtime":"docker"}}}'
NODE_VAR_1='{"name":"family-old","role":"provider","gateway_port":2250,"capabilities":{}}'
NODE_VAR_GW='{"name":"gateway","role":"gateway","ip":"203.0.113.9","user":"fatesaikou","tunnel_user":"sshproxy","port":2100,"key_secret":"SSH_KEY_ACTIONS"}'
printf '%s\n%s\n%s\n' "$NODE_VAR_0" "$NODE_VAR_1" "$NODE_VAR_GW" > "$SANDBOX/node-vars.txt"

# ---- 假 gh：記 argv、stdin 落檔；api 讀 fixtures；支援 refresh 等待迴圈 ------
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
if [[ ! -t 0 ]]; then cat > "${GH_STDIN:-/dev/null}"; fi
jqf="" prev=""
for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqf="$a"
    prev="$a"
done
_emit() {
    if [[ -n "$jqf" ]]; then printf '%s' "$1" | jq -r "$jqf"
    else printf '%s\n' "$1"; fi
}
_envelope() {
    jq -n --rawfile vars "${NODE_VARS_FILE:-/dev/null}" '
        {total_count: ($vars | split("\n") | map(select(length>0)) | length),
         variables: ($vars | split("\n") | map(select(length>0))
                     | map(. as $v | ($v | fromjson | .name | ascii_upcase | gsub("-"; "_")) as $n
                            | {name: ("NODE_" + $n), value: $v}))}'
}
case "${1:-}" in
  api)
    path=""
    for a in "$@"; do
        case "$a" in *actions/variables*) path="$a" ;; esac
    done
    case "$path" in
      *"/actions/variables")
          _emit "$(_envelope)" ;;
      *"/actions/variables/"*)
          nm="${path##*/}"
          hit="$(_envelope | jq -c --arg n "$nm" '[.variables[] | select(.name == $n)] | first // empty')"
          if [[ -z "$hit" ]]; then
              echo "gh: Not Found (HTTP 404)" >&2
              exit 1
          fi
          _emit "$hit" ;;
      *) printf '{}' ;;
    esac
    ;;
  variable)
    if [[ "${2:-}" == "set" ]]; then
        cp "${GH_STDIN:-/dev/null}" "${GH_SET_FILE:-/dev/null}" 2>/dev/null || true
    fi
    ;;
  workflow)
    if [[ "${2:-}" == "run" ]]; then
        printf 'DISPATCH %s\n' "$*" >> "${GH_LOG:-/dev/null}"
        # 把 dispatch 的參數記下來：等待函式（refresh-wait.sh）以標題含
        # nonce 認領自己那次 run；run list 要能回一個含該 nonce 的標題，
        # 否則等待迴圈會空轉到逾時——那是假 gh 的缺口，不是實作的錯。
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
chmod +x "$SHIMS/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIMS/sleep"
chmod +x "$SHIMS/sleep"

# ---- 登入金鑰對（真的 ssh-keygen；產物在沙盒） -------------------------------
LOGIN_KEY="$SANDBOX/login_key"
ssh-keygen -t ed25519 -N "" -C "repair-login-test" -f "$LOGIN_KEY" >/dev/null 2>&1
LOGIN_BLOB="$(awk '{print $2}' "$LOGIN_KEY.pub")"

# ---- 執行受測指令 ------------------------------------------------------------
NAME="repair-1"
PORT="2255"
# run_subject <home>：清紀錄再跑一次。rc→SUBJ_RC、輸出→SUBJ_OUT。
run_subject() {
    local home="$1"
    : > "$SANDBOX/gh.log"
    : > "$SANDBOX/gh-set.json"
    : > "$SANDBOX/gh-stdin.txt"
    rm -f "$SANDBOX/gh-dispatch-args"
    rm -rf "$home"; mkdir -p "$home"
    SUBJ_OUT="$(env -i \
        HOME="$home" \
        PATH="$SHIMS:$TOOL_DIRS:/usr/bin:/bin:/usr/sbin:/sbin" \
        GH_REPO="testowner/testrepo" \
        GH_TOKEN="ghp_FAKE_ENVTOKEN_VALUE_0001" \
        GH_POOL_TOKEN="ghp_FAKE_POOLTOKEN_VALUE_0002" \
        GH_LOG="$SANDBOX/gh.log" \
        GH_STDIN="$SANDBOX/gh-stdin.txt" \
        GH_SET_FILE="$SANDBOX/gh-set.json" \
        GH_DISPATCH_ARGS="$SANDBOX/gh-dispatch-args" \
        NODE_VARS_FILE="$SANDBOX/node-vars.txt" \
        POOL_REFRESH_POLL_INTERVAL=0 \
        TMPDIR="$SANDBOX" \
        bash "$REPO_ROOT/$SUBJECT" \
            --name "$NAME" --gateway-port "$PORT" \
            --login-key "$LOGIN_KEY.pub" --output-dir "$OUTDIR" </dev/null 2>&1)"
    SUBJ_RC=$?
}

varset_count() { grep -c '^variable set ' "$SANDBOX/gh.log" 2>/dev/null | tr -d ' '; }
emitted_var_json() { cat "$SANDBOX/gh-set.json" 2>/dev/null; }
boot_files() { find "$OUTDIR" -type f 2>/dev/null; }
# out_matches <fixed-string>：輸出目錄任何檔案（含二進位）含該字串。
out_matches() {
    local f
    for f in $(boot_files); do
        grep -qF -- "$1" "$f" 2>/dev/null && return 0
    done
    return 1
}

echo "=== 0. 先決條件（紅測試的預期入口） ==="
if [[ -f "$REPO_ROOT/$SUBJECT" ]]; then
    ok "0a. ${SUBJECT} 存在"
else
    bad "0a. ${SUBJECT} 不存在——本測試定義它的行為；impl 落地前這裡是紅（預期）"
fi

echo "=== 1. NODE_<NAME> 的形狀（spec 第一個 scenario） ==="
if [[ -f "$REPO_ROOT/$SUBJECT" ]]; then
    run_subject "$HOME_DIR"
    if [[ "$SUBJ_RC" -eq 0 ]]; then
        ok "1a. 正常登錄回 rc 0"
    else
        bad "1a. 登錄失敗（rc=${SUBJ_RC}）：$(printf '%s' "$SUBJ_OUT" | tail -2 | tr '\n' ' ')"
    fi
    if grep -q 'actions/variables' "$SANDBOX/gh.log" 2>/dev/null; then
        ok "1b. 正對照：假 gh 被呼叫（有 api actions/variables 查詢）"
    else
        bad "1b. 正對照失敗：假 gh 沒被呼叫——後面斷言不可信"
    fi
    if [[ "$(varset_count)" -ge 1 ]]; then
        vj="$(emitted_var_json)"
        if printf '%s' "$vj" | jq -e '.role == "provider"' >/dev/null 2>&1; then
            ok "1c. NODE_<NAME>.role == provider"
        else
            bad "1c. role 不是 provider（got [$(printf '%s' "$vj" | head -c 120)]）"
        fi
        if printf '%s' "$vj" | jq -e --arg n "$NAME" '.name == $n' >/dev/null 2>&1; then
            ok "1d. name 正確（${NAME}）"
        else
            bad "1d. name 不正確（want ${NAME}，got [$(printf '%s' "$vj" | jq -r '.name // "<missing>"' 2>/dev/null)]）"
        fi
        if printf '%s' "$vj" | jq -e --argjson p "$PORT" '.gateway_port == $p' >/dev/null 2>&1; then
            ok "1e. gateway_port == ${PORT}"
        else
            bad "1e. gateway_port 不正確（got [$(printf '%s' "$vj" | jq -r '.gateway_port // "<missing>"' 2>/dev/null)]）"
        fi
        if printf '%s' "$vj" | jq -e '((.capabilities // {}) | type == "object") and ((.capabilities // {}) | has("worker-host") | not)' >/dev/null 2>&1; then
            ok "1f. capabilities 是物件、沒有 worker-host（不承載 worker）"
        else
            bad "1f. capabilities 有 worker-host 或形狀不對（got [$(printf '%s' "$vj" | jq -c '.capabilities' 2>/dev/null)]）"
        fi
        if ! printf '%s' "$vj" | jq -e 'has("power")' >/dev/null 2>&1; then
            ok "1g. 沒有 power（不宣告喚醒／關機）"
        else
            bad "1g. 出現了 power 欄位（got [$(printf '%s' "$vj" | jq -c '.power' 2>/dev/null)]）"
        fi
        tk_blob="$(printf '%s' "$vj" | jq -r '.tunnel_public_key // empty' 2>/dev/null | awk '{print $2}')"
        priv=""
        for f in $(find "$OUTDIR" "$HOME_DIR" -type f \( -name 'id_tunnel' -o -name '*tunnel*' -o -name '*.key' \) 2>/dev/null); do
            head -c 40 "$f" 2>/dev/null | grep -q 'PRIVATE KEY' && { priv="$f"; break; }
        done
        if [[ -z "$priv" ]]; then
            for f in $(find "$OUTDIR" "$HOME_DIR" -type f -size +100c 2>/dev/null); do
                head -c 200 "$f" 2>/dev/null | grep -q 'PRIVATE KEY' && { priv="$f"; break; }
            done
        fi
        if [[ -n "$tk_blob" && -n "$priv" ]]; then
            derived_blob="$(ssh-keygen -y -f "$priv" 2>/dev/null | awk '{print $2}')"
            if [[ -n "$derived_blob" && "$derived_blob" == "$tk_blob" ]]; then
                ok "1h. tunnel_public_key 與輸出目錄裡的隧道私鑰成對（ssh-keygen -y 驗證）"
            else
                bad "1h. tunnel_public_key 與私鑰不成對（derived [${derived_blob:0:24}]… vs pub [${tk_blob:0:24}]…）"
            fi
        else
            bad "1h. 找不到 tunnel_public_key（[${tk_blob:-none}]）或輸出目錄裡的隧道私鑰（[${priv:-none}]）"
        fi
        # 1i/1j：開機資料的 tunnel env 要帶 NODE_GATEWAY 的 tunnel_user／port
        # （fixture 見上：sshproxy／2100），不是 WARN 分支的佔位符。
        # review §5b 的發現：光補 fixture 不夠——沒有這兩條斷言時，
        # 「read_gateway 永遠回佔位符（忽略真值）」的注入測試仍然全綠。
        if out_matches "POOL_GATEWAY_USER=sshproxy"; then
            ok "1i. tunnel env 帶 NODE_GATEWAY.tunnel_user（POOL_GATEWAY_USER=sshproxy）"
        else
            bad "1i. tunnel env 沒有 Gateway tunnel_user（想要 POOL_GATEWAY_USER=sshproxy）"
        fi
        if out_matches "POOL_GATEWAY_SSH_PORT=2100"; then
            ok "1j. tunnel env 帶 NODE_GATEWAY.port（POOL_GATEWAY_SSH_PORT=2100）"
        else
            bad "1j. tunnel env 沒有 Gateway SSH port（想要 POOL_GATEWAY_SSH_PORT=2100）"
        fi
    else
        bad "1c. 沒有送出任何 variable set——NODE_<NAME> 形狀無從驗證"
        bad "1d. （同上）"; bad "1e. （同上）"; bad "1f. （同上）"
        bad "1g. （同上）"; bad "1h. （同上）"
        bad "1i. （同上）"; bad "1j. （同上）"
    fi
else
    bad "1. ${SUBJECT} 不存在——全節無法驗證（預期紅）"
fi

echo "=== 2. port 衝突：別人已用 → 拒絕、零寫入、點名衝突機器 ==="
if [[ -f "$REPO_ROOT/$SUBJECT" ]]; then
    saved_port="$PORT"; PORT="2250"
    run_subject "$HOME_DIR"
    PORT="$saved_port"
    if [[ "$SUBJ_RC" -ne 0 ]]; then
        ok "2a. 指定已被 family-old 佔用的 2250 → rc ${SUBJ_RC}（非 0）"
    else
        bad "2a. 衝突 port 被接受了（rc=0）——會把現役機器的埠位打爛"
    fi
    if printf '%s' "$SUBJ_OUT" | grep -qF 'family-old'; then
        ok "2b. 訊息點名衝突的機器（family-old）"
    else
        bad "2b. 訊息沒點名衝突機器（out [$(printf '%s' "$SUBJ_OUT" | tr '\n' '|' | head -c 200)]）"
    fi
    if [[ "$(varset_count)" -eq 0 ]]; then
        ok "2c. 零次 gh variable set（拒絕在寫入前）"
    else
        bad "2c. 拒絕時仍送了 $(varset_count) 次 variable set（log [$(grep '^variable set' "$SANDBOX/gh.log" | head -1 | head -c 120)]）"
    fi
else
    bad "2a-2c. ${SUBJECT} 不存在——無法驗證（預期紅）"
fi

echo "=== 3. port 超出 2220–2299 → 拒絕、零寫入 ==="
if [[ -f "$REPO_ROOT/$SUBJECT" ]]; then
    badports_ok=1
    for p in 2219 2300 22 65535 abc; do
        saved_port="$PORT"; PORT="$p"
        run_subject "$HOME_DIR"
        PORT="$saved_port"
        if [[ "$SUBJ_RC" -eq 0 ]]; then
            bad "3. 超範圍／非數字 port ${p} 被接受"
            badports_ok=0
        elif [[ "$(varset_count)" -ne 0 ]]; then
            bad "3. port ${p} 被拒絕但送了 $(varset_count) 次 variable set"
            badports_ok=0
        fi
    done
    [[ "$badports_ok" -eq 1 ]] && ok "3. 2219／2300／22／65535／abc 全部拒絕且零寫入"
else
    bad "3. ${SUBJECT} 不存在——無法驗證（預期紅）"
fi

echo "=== 4. 開機資料不含 GitHub 權杖（spec 第二個 scenario） ==="
if [[ -f "$REPO_ROOT/$SUBJECT" ]]; then
    # 4a 正對照：掃描器先在一個故意塞了假權杖的檔案上證明看得見。
    rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"
    printf 'token=%s\n' "ghp_FAKE_ENVTOKEN_VALUE_0001" > "$OUTDIR/canary.txt"
    if out_matches "ghp_FAKE_ENVTOKEN_VALUE_0001"; then
        ok "4a. 正對照：掃描器看得見塞進輸出目錄的假權杖"
    else
        bad "4a. 正對照失敗：掃描器連 canary 都看不到——4b 的空掃不可信"
    fi
    rm -f "$OUTDIR/canary.txt"
    run_subject "$HOME_DIR"
    leaked=""
    for needle in "ghp_FAKE_ENVTOKEN_VALUE_0001" "ghp_FAKE_POOLTOKEN_VALUE_0002"; do
        out_matches "$needle" && leaked="${leaked}${needle} "
    done
    if [[ -z "$leaked" ]]; then
        ok "4b. 輸出目錄任何檔案都沒有 GH_TOKEN／GH_POOL_TOKEN 的值（含二進位掃描）"
    else
        f="$(for x in $(boot_files); do grep -lF -- "ghp_FAKE_ENVTOKEN_VALUE_0001" "$x" 2>/dev/null && break; done)"
        bad "4b. 開機資料洩漏了權杖（${leaked}）——例如檔案 [${f:-?}]"
    fi
else
    bad "4a. ${SUBJECT} 不存在——正對照無從執行（預期紅）"
    bad "4b. ${SUBJECT} 不存在——無法驗證（預期紅）"
fi

echo "=== 5. 登入公鑰在開機資料裡；隧道金鑰不是登入金鑰 ==="
if [[ -f "$REPO_ROOT/$SUBJECT" ]]; then
    run_subject "$HOME_DIR"
    if out_matches "$LOGIN_BLOB"; then
        ok "5a. 開機資料含給定的登入公鑰（key blob 命中）"
    else
        bad "5a. 開機資料找不到登入公鑰（blob [${LOGIN_BLOB:0:24}]…）"
    fi
    tk_blob="$(emitted_var_json | jq -r '.tunnel_public_key // empty' 2>/dev/null | awk '{print $2}')"
    if [[ -n "$tk_blob" && "$tk_blob" != "$LOGIN_BLOB" ]]; then
        ok "5b. 隧道金鑰與登入金鑰不是同一把"
    else
        bad "5b. 隧道金鑰與登入金鑰相同或缺失（tk [${tk_blob:0:24}]… login [${LOGIN_BLOB:0:24}]…）"
    fi
else
    bad "5a. ${SUBJECT} 不存在——無法驗證（預期紅）"
    bad "5b. ${SUBJECT} 不存在——無法驗證（預期紅）"
fi

echo "=== 6. refresh 被觸發 ==="
if [[ -f "$REPO_ROOT/$SUBJECT" ]]; then
    run_subject "$HOME_DIR"
    if grep -q 'workflow run.*refresh-authorized-keys' "$SANDBOX/gh.log" 2>/dev/null; then
        ok "6. 有觸發 refresh-authorized-keys 的 dispatch"
    else
        bad "6. 沒有看到 refresh 的 dispatch（log [$(grep '^workflow run' "$SANDBOX/gh.log" 2>/dev/null | head -1 | head -c 120)]）——新公鑰不會被 Gateway 授權"
    fi
else
    bad "6. ${SUBJECT} 不存在——無法驗證（預期紅）"
fi

echo "=== 7. 同名 NODE_<NAME> 已存在 → 拒絕（不覆蓋現役） ==="
if [[ -f "$REPO_ROOT/$SUBJECT" ]]; then
    # fixtures 裡已有 NODE_FAMILY_OLD（不屬於本次登錄）；換一個空閒 port，
    # 只讓「同名」成為拒絕原因。
    # **全新的空輸出目錄**：前面章節的 $OUTDIR 這時已經裝著 repair-1 的
    # seed（meta-data 的 local-hostname=repair-1），如果沿用它，§7 的拒絕
    # 有可能是 output-dir 守衛（"already holds the seed for 'repair-1'"）
    # 先開口，同名檢查本身反而從沒被驗過——這正是 review 發現 1 的形狀：
    # 拿掉同名檢查（Inj4）時，沿用舊目錄的版本仍然 20/0 全綠。換一個乾淨、
    # 從未寫過任何 seed 的目錄，才能讓 §7 的紅只可能來自同名檢查。
    saved_port="$PORT"; PORT="2256"
    saved_name="$NAME"; NAME="family-old"
    saved_outdir="$OUTDIR"; OUTDIR="$SANDBOX/boot-fresh7"; mkdir -p "$OUTDIR"
    run_subject "$HOME_DIR"
    NAME="$saved_name"; PORT="$saved_port"; OUTDIR="$saved_outdir"
    if [[ "$SUBJ_RC" -ne 0 ]]; then
        ok "7a. 已存在的 NODE_FAMILY_OLD → rc ${SUBJ_RC}（非 0，不覆蓋）"
    else
        bad "7a. 已存在的名字被接受了（rc=0）——會覆蓋現役機器"
    fi
    # 7a2：拒絕訊息必須是同名檢查那句（"already exists"），不是
    # output-dir 守衛那句（"already holds the seed for"）——只驗 rc!=0
    # 驗不出「是哪一條守衛在講話」，用全新目錄消掉 output-dir 守衛的機會
    # 之後，這裡再把訊息釘死，兩層一起擋住「表面像同名測試，其實測的是
    # 別的守衛」。
    if printf '%s' "$SUBJ_OUT" | grep -qF 'already exists' \
    && ! printf '%s' "$SUBJ_OUT" | grep -qF 'already holds the seed for'; then
        ok "7a2. 拒絕訊息是同名檢查的（already exists），不是 output-dir 守衛的（already holds the seed for）"
    else
        bad "7a2. 拒絕訊息不是同名檢查的（out [$(printf '%s' "$SUBJ_OUT" | tr '\n' '|' | head -c 200)]）"
    fi
    if [[ "$(varset_count)" -eq 0 ]]; then
        ok "7b. 零次 variable set"
    else
        bad "7b. 拒絕時仍送了 $(varset_count) 次 variable set"
    fi
else
    bad "7a. ${SUBJECT} 不存在——無法驗證（預期紅）"
    bad "7a2. ${SUBJECT} 不存在——無法驗證（預期紅）"
    bad "7b. ${SUBJECT} 不存在——無法驗證（預期紅）"
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
[[ "$fail" -ne 0 ]] && exit 1
exit 0
