#!/usr/bin/env bash
# test-wake-via.sh — `power.launch.via` 清單 fallback 的回歸護欄。
#
# 在防什麼（設計見 docs/WAKE-VIA-DESIGN.md）：
#   單點代送者：via 是單一字串時，那台機器一關機，所有前端一起失效。
#   清單的每一條規則都是一次踩過或差點踩到的坑：
#   送出結束碼陷阱（最重要）：pool-wol 回 0 只代表封包離開送出端，
#   RUNBOOK 有它從來沒送出過卻照樣回 0 的反例。用結束碼當「醒了」的判準，
#   等於問一個壞掉時不會給出不同答案的問題——本 repo 反覆踩的坑。
#   判準只能是埠輪詢：Gateway 上目標埠有沒有變 up。
#   送不出去要立刻換人：代送者關機／沒裝工具／ssh 不通時，耗掉整個等待
#   預算再換人等於把單點消除變成單點加罰站。
#   舊形狀 var：單一字串等價於單元素陣列，不另立程式碼路徑，否則主本一翻
#   所有舊 var 直接壞掉。
#   最後一台吃剩餘：清單耗盡就沒辦法了，此時提早放棄最虧，總預算維持 300 秒。
#   成功要指名：單點消除後最危險的是「一直在用第二順位，你以為是第一順位」。
#
# 量測手法（斷言要能分辨「等了 90 秒」與「立刻換人」，不只看最終結果）：
#   全離線。ssh / pool-resolve / gh 走 PATH stub；run_on_node 與 gw_probe_port
#   是 shell 函式，子行程載入 mlp 後直接覆寫（記事件、回放罐頭答案）；
#   sleep 走 PATH stub，只把秒數記進事件檔、不真的等。
#   事件檔只有兩種行：SEND <sender> 與 SLEEP <secs>，等待預算歸屬用 awk
#   按 SEND 標記切分（某台 sender 之後的 SLEEP 歸它，直到下一次 SEND）。
#   stub 忠實性：pool-wol 回 0 但埠永遠不 up 的夾具是第一條注入的核心，
#   run_on_node 覆寫的回碼與探測覆寫的 up/down 各自獨立可控。
#
# 契約（實作已落地，直接釘真函式）：
#   wake_senders <json>：Model。WAKE_SENDERS 陣列（去重、剔除被喚醒節點自己、
#   保序），空即回 1；自己一個字都不印。
#   wake_try_sender <sender> <mac> <target_ip> <port> <budget>：ViewModel。
#   回 0 醒了／2 送不出去（快、不花預算）／3 送出但沒醒；WAKE_ELAPSED、
#   WAKE_SEND_ERR 帶回；自己不印字。
#   cmd_wake <node>：View 加流程。非末台 90 秒、末台吃剩餘（總 300 秒）；
#   成功行指名代送者，全敗列出每台原因。
#
# 注入（每條先證明會紅：突變版 bash -n 過＋needle 命中數 == 1＋實際 got 值）：
#   沒先證明會紅的護欄等於沒有護欄。
#   第四態 unknown（送出但無法驗證）：網關 master 打不開 → 回 4（不是 3），
#   因為「沒觀察到」不是「觀察到沒醒」——把不知道說成壞的，與把壞的說成好的
#   同屬答案與現實脫鉤，前者正是 fwd 超時／不可達分家的同類教訓。
#   unknown 照樣往下試；全 unknown 收場不可以說 could not wake（沒驗證過的結論）。
#
# 相容：只用 bash 3.2 就有的語法（無 nameref、無大小寫轉換、無關聯陣列、
#   空陣列在 set -u 下不直接展開；測試本體連索引陣列都不用，只用字串與檔案）。
#
# Run: scripts/tests/test-wake-via.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

MLP="ops-scripts/mlp"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required but not found on PATH" >&2
    exit 1
fi
if ! command -v awk >/dev/null 2>&1; then
    echo "ERROR: awk is required but not found on PATH" >&2
    exit 1
fi
if [[ ! -f "$MLP" ]]; then
    echo "test-wake-via: ${MLP} is missing; every case below will FAIL" >&2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-wake-via.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/shims" "$SANDBOX/home"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- stubs：全部離線 -------------------------------------------------------
# ssh：記 argv；-M 建連回 FAKE_MASTER_RC，其餘回 0。不連任何東西。
cat > "$SANDBOX/shims/ssh" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a" >> "${ARGV_LOG:-/dev/null}"; done
printf 'CALL-EOL\n' >> "${ARGV_LOG:-/dev/null}"
joined="$*"
case "$joined" in
  *"-M "*) exit "${FAKE_MASTER_RC:-0}" ;;
esac
exit 0
FAKE
# pool-resolve：gateway 回 GW_JSON；具名節點查 NODE_MAP；其餘 exit 1。
cat > "$SANDBOX/shims/pool-resolve" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "gateway" ]]; then
  if [[ -n "${GW_JSON:-}" ]]; then printf '%s\n' "$GW_JSON"; else printf '{"ip":"9.9.9.9","user":"gw","port":22}\n'; fi
  exit "${GW_RC:-0}"
fi
node="${1:-}"
if [[ -n "${NODE_MAP:-}" && -f "$NODE_MAP" ]]; then
  out="$(jq -c --arg n "$node" '.[$n] // empty' "$NODE_MAP" 2>/dev/null)"
  if [[ -n "$out" ]]; then printf '%s\n' "$out"; exit 0; fi
fi
exit 1
FAKE
# gh：具名喚醒走不到它，留空殼以免誤觸網路。
cat > "$SANDBOX/shims/gh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
# sleep：只把秒數記進事件檔，不真的等。等待預算全部用這裡的加總量。
cat > "$SANDBOX/shims/sleep" <<'FAKE'
#!/usr/bin/env bash
printf 'SLEEP %s\n' "$*" >> "${EVENT_LOG:-/dev/null}"
exit 0
FAKE
# fzf：具名路徑用不到，誤觸即大聲失敗而非卡住。
cat > "$SANDBOX/shims/fzf" <<'FAKE'
#!/usr/bin/env bash
echo "test stub: refusing fzf" >&2
exit 255
FAKE
chmod +x "$SANDBOX/shims/ssh" "$SANDBOX/shims/pool-resolve" "$SANDBOX/shims/gh" "$SANDBOX/shims/sleep" "$SANDBOX/shims/fzf"

MLP_FILE="$REPO_ROOT/$MLP"

# ---- 小幫手 ---------------------------------------------------------------
# 事件歸屬：SEND 標記切分，印 "SENDS=n TOT=t W1=name:secs W2=name:secs"。
ev_split() {
    awk '/^SEND/ {ns++; who[ns]=$2} /^SLEEP/ {tot+=$2; per[ns]+=$2} END {printf "SENDS=%d TOT=%d", ns+0, tot+0; for (i=1; i<=ns; i++) printf " W%d=%s:%d", i, who[i], per[i]+0}' "$1" 2>/dev/null
}

echo "=== 0. 先決條件：wake_senders / wake_try_sender 在 ==="
missing=0
for fn in wake_senders wake_try_sender; do
    if grep -qE "^${fn}\\(\\)" "$MLP"; then
        :
    else
        bad "0. ${fn} 不存在——實作還沒落地？"
        missing=1
    fi
done
if [[ "$missing" -eq 0 ]]; then
    ok "0. wake_senders 與 wake_try_sender 都在"
fi

echo "=== 1. wake_senders：字串或陣列正規化成陣列 ==="
# 呼叫形狀：wake_senders "$json"；看 rc、WAKE_SENDERS 內容與零輸出。
# sender_case <標籤> <json> <want_rc> <want_list|-> <want_outbytes>
sender_case() {
    local label="$1" want_rc="$2" want_list="$3" got
    got="$(WJSON="$4" MLP_FILE="$MLP_FILE" OUTF="$SANDBOX/s-out" ERRF="$SANDBOX/s-err" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; if ! declare -F wake_senders >/dev/null 2>&1; then printf "MISSING"; exit 0; fi; : > "$OUTF"; : > "$ERRF"; if wake_senders "$WJSON" >"$OUTF" 2>"$ERRF"; then rc=0; else rc=$?; fi; n="${#WAKE_SENDERS[@]}"; list=""; if [[ "$n" -gt 0 ]]; then list="${WAKE_SENDERS[*]}"; fi; printf "RC=%s N=%s LIST=%s OUT=%s ERR=%s" "$rc" "$n" "$list" "$(wc -c < "$OUTF" | tr -d " ")" "$(wc -c < "$ERRF" | tr -d " ")"' 2>&1)"
    if [[ "$got" == "MISSING" ]]; then
        bad "${label}（wake_senders 未落地）"
        return
    fi
    if [[ "$want_list" == "-" ]]; then
        if [[ "$got" == "RC=${want_rc} N=0 LIST= OUT=0 ERR=0" ]]; then
            ok "$label"
        else
            bad "$label (got [$got])"
        fi
    else
        if [[ "$got" == "RC=${want_rc} N="* ]] && printf '%s' "$got" | grep -q "LIST=${want_list} OUT=0 ERR=0"; then
            ok "$label"
        else
            bad "$label (got [$got] want list [$want_list])"
        fi
    fi
}
J1='{"name":"fh-l","power":{"launch":{"via":"s1"}}}'
sender_case "1a. 舊形狀字串 → 單元素" 0 "s1" "$J1"
J2='{"name":"fh-l","power":{"launch":{"via":["s2","s1"]}}}'
sender_case "1b. 陣列保序（優先序即順序）" 0 "s2 s1" "$J2"
J3='{"name":"fh-l","power":{"launch":{"via":["s1","s1","s2"]}}}'
sender_case "1c. 去重（保序）" 0 "s1 s2" "$J3"
J4='{"name":"fh-l","power":{"launch":{"via":["fh-l","s9"]}}}'
sender_case "1d. 剔除自己（關著的機器不能叫醒自己）" 0 "s9" "$J4"
J5='{"name":"fh-l","power":{"launch":{"via":[]}}}'
sender_case "1e. 空陣列是錯誤（回 1、零輸出）" 1 "-" "$J5"
J6='{"name":"fh-l","power":{"launch":{"method":"wol-unicast"}}}'
sender_case "1f. 缺 via 是錯誤" 1 "-" "$J6"
J7='{"name":"fh-l","power":{"launch":{"via":["fh-l"]}}}'
sender_case "1g. 只剩自己等於空 → 錯誤" 1 "-" "$J7"

echo "=== 2. wake_try_sender：判準是埠輪詢，不是送出結束碼 ==="
# 呼叫形狀：wake_try_sender <sender> <mac> <ip> <port> <budget>；
# run_on_node / gw_probe_port 在子行程覆寫（記事件、回放）。
# try_case <標籤> <send_rc> <up_after> <master_rc> <budget> <want_rc> <want_sleeps>
try_case() {
    local label="$1" send_rc="$2" up_after="$3" master_rc="$4" budget="$5" want_rc="$6" want_sleeps="$7" got
    printf 's1:%s\n' "$send_rc" > "$SANDBOX/send-map"
    got="$(MLP_FILE="$MLP_FILE" BUDGET="$budget" UP_AFTER="$up_after" MAP="$SANDBOX/send-map" EVENT_LOG="$SANDBOX/ev.log" PROBE_COUNT="$SANDBOX/probe-n" FAKE_MASTER_RC="$master_rc" ARGV_LOG="$SANDBOX/argv.log" OUTF="$SANDBOX/t-out" ERRF="$SANDBOX/t-err" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        if ! declare -F wake_try_sender >/dev/null 2>&1; then printf "MISSING"; exit 0; fi
        run_on_node() {
            printf "SEND %s\n" "$1" >> "$EVENT_LOG"
            rc=0
            while IFS=: read -r m r; do
                if [[ "$m" == "$1" ]]; then rc="$r"; break; fi
            done < "$MAP" 2>/dev/null
            case "$rc" in ""|0) return 0;; *) printf "run_on_node stub: %s unreachable\n" "$1"; return 1;; esac
        }
        gw_probe_port() {
            n="$(cat "$PROBE_COUNT" 2>/dev/null || printf 0)"
            n=$((n + 1)); printf "%s" "$n" > "$PROBE_COUNT"
            if [[ "$n" -gt "$UP_AFTER" ]]; then printf "up"; else printf "down"; fi
        }
        : > "$EVENT_LOG"; printf 0 > "$PROBE_COUNT"; : > "$OUTF"; : > "$ERRF"; : > "$ARGV_LOG"
        wake_try_sender s1 "B4:2E:99:FB:63:5E" "192.168.0.136" "2323" "$BUDGET" >"$OUTF" 2>"$ERRF"; rc=$?
        if [[ -n "$WAKE_SEND_ERR" ]]; then e=1; else e=0; fi
        sl=0
        while read -r tag val; do
            if [[ "$tag" == "SLEEP" ]]; then
                case "$val" in ""|*[!0-9]*) ;; *) sl=$((sl + val));; esac
            fi
        done < "$EVENT_LOG" 2>/dev/null
        printf "RC=%s ELAPSED=%s HASERR=%s SLEEPS=%s OUT=%s ERR=%s" "$rc" "$WAKE_ELAPSED" "$e" "$sl" "$(wc -c < "$OUTF" | tr -d " ")" "$(wc -c < "$ERRF" | tr -d " ")"' 2>&1)"
    if [[ "$got" == "MISSING" ]]; then
        bad "${label}（wake_try_sender 未落地）"
        return
    fi
    if [[ "$got" == "RC=${want_rc} ELAPSED="* ]] && printf '%s' "$got" | grep -q "SLEEPS=${want_sleeps} OUT=0 ERR=0"; then
        ok "$label"
    else
        bad "$label (got [$got])"
    fi
}
# 2a：送不出去 → rc 2、有原因、零等待、零輸出。
try_case "2a. 送不出去 → 回 2、有原因、不花預算" 1 999999 0 30 2 0
# 2b：送出 ok 但埠永遠不 up（pool-wol 回 0 的夾具）→ rc 3，且真的等了預算。
try_case "2b. 送出成功但沒醒 → 回 3（不是回 0），等滿預算" 0 999999 0 30 3 30
# 2c：探測立刻 up → rc 0、零等待。
try_case "2c. 探測 up → 回 0、不空等" 0 0 0 30 0 0
# 2d：master 打不開 → 回 4（未知，不是 3）、不燒預算（§10 同斷）。
try_case "2d. master 打不開 → 回 4（未知）、不燒預算" 0 999999 1 30 4 0

echo "=== 3. cmd_wake：走清單、說得出為什麼換人 ==="
# wake_run [up_after [master_rc]]：具名喚醒一次；SEND_MAP 由呼叫端備好；
# 印 RC 與事件統計。master_rc 預設 0（網關正常），傳 1 造全 unknown 夾具。
wake_run() {
    MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" NODE_MAP="$SANDBOX/node-map.json" GW_JSON='{"ip":"9.9.9.9","user":"gw","port":22}' GW_RC=0 MAP="$SANDBOX/send-map" EVENT_LOG="$SANDBOX/ev.log" PROBE_COUNT="$SANDBOX/probe-n" UP_AFTER="$1" FAKE_MASTER_RC="${2:-0}" ARGV_LOG="$SANDBOX/argv.log" OUTF="$SANDBOX/w-out" ERRF="$SANDBOX/w-err" RESDONE="$SANDBOX/w-rc-done" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="$POOL_OVERRIDE"
        run_on_node() {
            printf "SEND %s\n" "$1" >> "$EVENT_LOG"
            rc=0
            while IFS=: read -r m r; do
                if [[ "$m" == "$1" ]]; then rc="$r"; break; fi
            done < "$MAP" 2>/dev/null
            case "$rc" in ""|0) return 0;; *) printf "run_on_node stub: %s unreachable\n" "$1"; return 1;; esac
        }
        gw_probe_port() {
            n="$(cat "$PROBE_COUNT" 2>/dev/null || printf 0)"
            n=$((n + 1)); printf "%s" "$n" > "$PROBE_COUNT"
            if [[ "$n" -gt "$UP_AFTER" ]]; then printf "up"; else printf "down"; fi
        }
        : > "$EVENT_LOG"; printf 0 > "$PROBE_COUNT"; : > "$OUTF"; : > "$ERRF"; : > "$ARGV_LOG"; rm -f "$RESDONE"
        ( cmd_wake fh-l >"$OUTF" 2>"$ERRF" ); rc=$?
        printf "RC=%s" "$rc" > "$RESDONE"' 2>/dev/null
    printf 'RC=%s ' "$(cat "$SANDBOX/w-rc-done" 2>/dev/null | sed 's/^RC=//')"
    ev_split "$SANDBOX/ev.log"
}
NODE2='{"fh-l":{"name":"fh-l","role":"provider","gateway_port":2323,"user":"worker","power":{"launch":{"method":"wol-unicast","via":["s1","s2"],"mac":"B4:2E:99:FB:63:5E","target_ip":"192.168.0.136"}}}}'
NODE1='{"fh-l":{"name":"fh-l","role":"provider","gateway_port":2323,"user":"worker","power":{"launch":{"method":"wol-unicast","via":["s1"],"mac":"B4:2E:99:FB:63:5E","target_ip":"192.168.0.136"}}}}'
# 3a：s1 送出 ok 但永不 up → 必須換人（兩次 SEND），最終失敗、絕不報 up。
printf '%s\n' "$NODE2" > "$SANDBOX/node-map.json"
printf 's1:0\ns2:0\n' > "$SANDBOX/send-map"
got="$(wake_run 999999)"
if [[ "$got" == "RC=1 SENDS=2"* ]] && ! grep -q 'is up' "$SANDBOX/w-out" 2>/dev/null; then
    ok "3a. 送出成功但沒醒 → 換下一台（兩次 SEND），最終失敗不謊報"
else
    bad "3a. 沒換人或謊報成功（got [$got]）"
fi
# 3b：s1 送不出去 → 立刻換人（s1 零等待），s2 叫醒，指名 s2。
printf 's1:1\ns2:0\n' > "$SANDBOX/send-map"
got="$(wake_run 0)"
s1wait="$(awk '/^SEND/ {ns++} /^SLEEP/ {per[ns]+=$2} END {printf "%d", per[1]+0}' "$SANDBOX/ev.log")"
if [[ "$got" == "RC=0 SENDS=2"* ]] && [[ "$s1wait" == "0" ]] && grep -qF 'via s2)' "$SANDBOX/w-out" 2>/dev/null; then
    ok "3b. 送不出去立刻換人（s1 零等待），成功指名 s2"
else
    bad "3b. 罰站了或沒換人或沒指名（got [$got] s1wait=[$s1wait]）"
fi
# 3c：兩台都送出 ok 但永不 up → s1 等 90、s2 吃剩餘 210、共 300，列出兩台原因。
printf 's1:0\ns2:0\n' > "$SANDBOX/send-map"
got="$(wake_run 999999)"
if [[ "$got" == "RC=1 SENDS=2 TOT=300 W1=s1:90 W2=s2:210" ]] \
&& grep -qF 's1: sent, but fh-l did not come up within 90s' "$SANDBOX/w-out" 2>/dev/null \
&& grep -qF 's2: sent, but fh-l did not come up within 210s' "$SANDBOX/w-out" 2>/dev/null \
&& grep -qF 'could not wake fh-l' "$SANDBOX/w-out" 2>/dev/null; then
    ok "3c. 末台吃剩餘（90＋210＝300），全敗列出每台原因"
else
    bad "3c. 預算被截斷或原因沒列全（got [$got]）"
fi
# 3d：單台送出 ok、立刻 up → 成功且指名。
printf '%s\n' "$NODE1" > "$SANDBOX/node-map.json"
printf 's1:0\n' > "$SANDBOX/send-map"
got="$(wake_run 0)"
if [[ "$got" == "RC=0 SENDS=1"* ]] && grep -qF 'via s1)' "$SANDBOX/w-out" 2>/dev/null; then
    ok "3d. 成功行指名代送者（via s1）"
else
    bad "3d. 沒指名或沒成功（got [$got]）"
fi

echo "=== 4. 分層：Model 與 ViewModel 不印字 ==="
layer_bad=""
for fn in wake_senders wake_try_sender; do
    body="$(awk -v want="$fn" 'BEGIN{infn=0} $0 ~ ("^" want "\\(\\)") {infn=1; next} infn && $0 == "}" {infn=0; next} infn {print}' "$MLP")"
    if [[ -z "$body" ]]; then
        layer_bad="${layer_bad} ${fn}(missing)"
        continue
    fi
    code="$(printf '%s' "$body" | grep -vE '^[[:space:]]*#')"
    if printf '%s' "$code" | grep -qE '(^|[^A-Za-z0-9_])(printf|echo|fzf)([^A-Za-z0-9_]|$)'; then
        layer_bad="${layer_bad} ${fn}"
    fi
done
if [[ -z "$layer_bad" ]]; then
    ok "4. wake_senders 與 wake_try_sender 體內無輸出（靜態；動態零輸出見 §1§2 的 OUT/ERR）"
else
    bad "4. 分層破口：${layer_bad}"
fi

echo "=== 10. unknown：送出但無法驗證（回 4，不是 3） ==="
# 夾具：送出 ok、網關 master 打不開 → 沒觀察、零等待、帶原因。
printf 's1:0\n' > "$SANDBOX/send-map"
got="$(MLP_FILE="$MLP_FILE" BUDGET=30 UP_AFTER=999999 MAP="$SANDBOX/send-map" EVENT_LOG="$SANDBOX/ev.log" PROBE_COUNT="$SANDBOX/probe-n" FAKE_MASTER_RC=1 ARGV_LOG="$SANDBOX/argv.log" OUTF="$SANDBOX/u-out" ERRF="$SANDBOX/u-err" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c '
    source "$MLP_FILE" >/dev/null 2>&1
    if ! declare -F wake_try_sender >/dev/null 2>&1; then printf "MISSING"; exit 0; fi
    run_on_node() {
        printf "SEND %s\n" "$1" >> "$EVENT_LOG"
        rc=0
        while IFS=: read -r m r; do
            if [[ "$m" == "$1" ]]; then rc="$r"; break; fi
        done < "$MAP" 2>/dev/null
        case "$rc" in ""|0) return 0;; *) printf "run_on_node stub: %s unreachable\n" "$1"; return 1;; esac
    }
    gw_probe_port() { printf "down"; }
    : > "$EVENT_LOG"; printf 0 > "$PROBE_COUNT"; : > "$OUTF"; : > "$ERRF"
    wake_try_sender s1 "B4:2E:99:FB:63:5E" "192.168.0.136" "2323" "$BUDGET" >"$OUTF" 2>"$ERRF"; rc=$?
    if [[ -n "$WAKE_SEND_ERR" ]]; then e=1; else e=0; fi
    sl=0
    while read -r tag val; do
        if [[ "$tag" == "SLEEP" ]]; then
            case "$val" in ""|*[!0-9]*) ;; *) sl=$((sl + val));; esac
        fi
    done < "$EVENT_LOG" 2>/dev/null
    printf "RC=%s ELAPSED=%s HASERR=%s SLEEPS=%s OUT=%s ERR=%s" "$rc" "$WAKE_ELAPSED" "$e" "$sl" "$(wc -c < "$OUTF" | tr -d " ")" "$(wc -c < "$ERRF" | tr -d " ")"' 2>&1)"
if [[ "$got" == "MISSING" ]]; then
    bad "10. wake_try_sender 未落地"
elif [[ "$got" == "RC=4 ELAPSED=0 HASERR=1 SLEEPS=0 OUT=0 ERR=0" ]]; then
    ok "10. 網關失敗 → 回 4（未知），有原因、零等待、零輸出"
else
    bad "10. 未知被當成已知（got [$got]）"
fi

echo "=== 11-12. 全 unknown 收場與 fallback ==="
# 夾具：兩台都送出 ok、網關恆失敗 → 兩次 unknown、零等待、最終仍失敗。
printf '%s\n' "$NODE2" > "$SANDBOX/node-map.json"
printf 's1:0\ns2:0\n' > "$SANDBOX/send-map"
MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" NODE_MAP="$SANDBOX/node-map.json" GW_JSON='{"ip":"9.9.9.9","user":"gw","port":22}' GW_RC=0 MAP="$SANDBOX/send-map" EVENT_LOG="$SANDBOX/ev.log" PROBE_COUNT="$SANDBOX/probe-n" UP_AFTER=999999 FAKE_MASTER_RC=1 ARGV_LOG="$SANDBOX/argv.log" OUTF="$SANDBOX/wu-out" ERRF="$SANDBOX/wu-err" RESDONE="$SANDBOX/wu-rc-done" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c '
    source "$MLP_FILE" >/dev/null 2>&1
    POOL_RESOLVE="$POOL_OVERRIDE"
    run_on_node() {
        printf "SEND %s\n" "$1" >> "$EVENT_LOG"
        rc=0
        while IFS=: read -r m r; do
            if [[ "$m" == "$1" ]]; then rc="$r"; break; fi
        done < "$MAP" 2>/dev/null
        case "$rc" in ""|0) return 0;; *) printf "run_on_node stub: %s unreachable\n" "$1"; return 1;; esac
    }
    gw_probe_port() { printf "down"; }
    : > "$EVENT_LOG"; printf 0 > "$PROBE_COUNT"; : > "$OUTF"; : > "$ERRF"; rm -f "$RESDONE"
    ( cmd_wake fh-l >"$OUTF" 2>"$ERRF" ); rc=$?
    printf "RC=%s" "$rc" > "$RESDONE"' 2>/dev/null
got="RC=$(cat "$SANDBOX/wu-rc-done" 2>/dev/null | sed 's/^RC=//') $(ev_split "$SANDBOX/ev.log")"
if [[ "$got" == "RC=1 SENDS=2"* ]]; then
    ok "12. unknown 照樣往下試（兩次 SEND），最終仍失敗"
else
    bad "12. fallback 斷了或誤報成功（got [$got]）"
fi
if grep -qF 'could not wake' "$SANDBOX/wu-out" 2>/dev/null; then
    bad "11. 全 unknown 收場宣稱 could not wake（沒驗證過的結論）"
else
    if grep -qF 'did not come up' "$SANDBOX/wu-out" 2>/dev/null; then
        bad "11. unknown 被說成沒醒（got [$(tr '\n' ' ' < "$SANDBOX/wu-out" | head -c 200)]）"
    else
        ok "11. 全 unknown 收場不宣稱未驗證的結論"
    fi
fi

echo "=== 5-9. 注入：拿掉修正，斷言必須轉紅 ==="
# 5. 觸發條件改回送出結束碼 → 送出成功但沒醒時不會換人。
#   突變：send ok 即 return 0（不再輪詢埠）。
INJ1="$SANDBOX/mutant-rconly.sh"
python3 - "$MLP" "$INJ1" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    if [[ "$rc" -ne 0 ]]; then\n'
       '        WAKE_SEND_ERR="$send_out"\n'
       '        return 2\n'
       '    fi')
new = old + '\n    return 0'
assert src.count(old) == 1, "rconly needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "5. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ1" 2>/dev/null; then
    inj_bad "5. 注入版語法錯誤——harness 問題"
else
    # 5a 單元層：pool-wol 回 0 但埠永遠不 up → 應回 3。
    printf 's1:0\n' > "$SANDBOX/send-map"
    got="$(MLP_FILE="$INJ1" BUDGET=30 UP_AFTER=999999 MAP="$SANDBOX/send-map" EVENT_LOG="$SANDBOX/ev.log" PROBE_COUNT="$SANDBOX/probe-n" FAKE_MASTER_RC=0 ARGV_LOG="$SANDBOX/argv.log" OUTF="$SANDBOX/t-out" ERRF="$SANDBOX/t-err" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        run_on_node() {
            printf "SEND %s\n" "$1" >> "$EVENT_LOG"
            rc=0
            while IFS=: read -r m r; do
                if [[ "$m" == "$1" ]]; then rc="$r"; break; fi
            done < "$MAP" 2>/dev/null
            case "$rc" in ""|0) return 0;; *) printf "run_on_node stub: %s unreachable\n" "$1"; return 1;; esac
        }
        gw_probe_port() {
            n="$(cat "$PROBE_COUNT" 2>/dev/null || printf 0)"
            n=$((n + 1)); printf "%s" "$n" > "$PROBE_COUNT"
            if [[ "$n" -gt "$UP_AFTER" ]]; then printf "up"; else printf "down"; fi
        }
        : > "$EVENT_LOG"; printf 0 > "$PROBE_COUNT"
        wake_try_sender s1 "B4:2E:99:FB:63:5E" "192.168.0.136" "2323" "$BUDGET" >/dev/null 2>&1; rc=$?
        sl=0
        while read -r tag val; do
            if [[ "$tag" == "SLEEP" ]]; then
                case "$val" in ""|*[!0-9]*) ;; *) sl=$((sl + val));; esac
            fi
        done < "$EVENT_LOG" 2>/dev/null
        printf "RC=%s SLEEPS=%s" "$rc" "$sl"' 2>&1)"
    if [[ "$got" == "RC=3 SLEEPS=30" ]]; then
        inj_bad "5a. 改回結束碼觸發後 2b 仍綠——輪詢沒被量到"
    else
        if [[ "$got" == "RC=0 SLEEPS=0" ]]; then
            inj_ok "5a. 改回結束碼觸發後送出即報成功（got [$got]）——2b 會紅"
        else
            inj_bad "5a. 行為變了但不是預期的假成功（got [$got]）——harness 問題"
        fi
    fi
    # 5b 流程層：同 3a 夾具在突變版上 → 只送一次就報成功，不換人。
    printf '%s\n' "$NODE2" > "$SANDBOX/node-map.json"
    printf 's1:0\ns2:0\n' > "$SANDBOX/send-map"
    MLP_SAVE="$MLP_FILE"; MLP_FILE="$INJ1"
    got="$(wake_run 999999)"
    MLP_FILE="$MLP_SAVE"
    if [[ "$got" == "RC=1 SENDS=2"* ]]; then
        inj_bad "5b. 改回結束碼觸發後 3a 仍綠——換人沒被量到"
    else
        if [[ "$got" == "RC=0 SENDS=1"* ]]; then
            inj_ok "5b. 改回結束碼觸發後一次送出即成功（got [$got]）——3a 會紅"
        else
            inj_bad "5b. 行為變了但不是預期的假成功（got [$got]）——harness 問題"
        fi
    fi
fi
# 6. 送不出去仍耗掉整個等待預算 → 快速略過轉紅。
#   突變：send 失敗分支先睡滿預算再回 2。
INJ2="$SANDBOX/mutant-burnbudget.sh"
python3 - "$MLP" "$INJ2" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    if [[ "$rc" -ne 0 ]]; then\n'
       '        WAKE_SEND_ERR="$send_out"\n'
       '        return 2\n'
       '    fi')
new = ('    if [[ "$rc" -ne 0 ]]; then\n'
       '        WAKE_SEND_ERR="$send_out"\n'
       '        waited=0\n'
       '        while [[ "$waited" -lt "$budget" ]]; do\n'
       '            sleep 5\n'
       '            waited=$((waited + 5))\n'
       '        done\n'
       '        return 2\n'
       '    fi')
assert src.count(old) == 1, "burnbudget needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "6. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ2" 2>/dev/null; then
    inj_bad "6. 注入版語法錯誤——harness 問題"
else
    # 6a 單元層：送失敗、預算 30 → 應回 2 且零等待。
    printf 's1:1\n' > "$SANDBOX/send-map"
    got="$(MLP_FILE="$INJ2" BUDGET=30 UP_AFTER=999999 MAP="$SANDBOX/send-map" EVENT_LOG="$SANDBOX/ev.log" PROBE_COUNT="$SANDBOX/probe-n" FAKE_MASTER_RC=0 ARGV_LOG="$SANDBOX/argv.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        run_on_node() {
            printf "SEND %s\n" "$1" >> "$EVENT_LOG"
            rc=0
            while IFS=: read -r m r; do
                if [[ "$m" == "$1" ]]; then rc="$r"; break; fi
            done < "$MAP" 2>/dev/null
            case "$rc" in ""|0) return 0;; *) printf "run_on_node stub: %s unreachable\n" "$1"; return 1;; esac
        }
        gw_probe_port() { printf "down"; }
        : > "$EVENT_LOG"; printf 0 > "$PROBE_COUNT"
        wake_try_sender s1 "B4:2E:99:FB:63:5E" "192.168.0.136" "2323" "$BUDGET" >/dev/null 2>&1; rc=$?
        sl=0
        while read -r tag val; do
            if [[ "$tag" == "SLEEP" ]]; then
                case "$val" in ""|*[!0-9]*) ;; *) sl=$((sl + val));; esac
            fi
        done < "$EVENT_LOG" 2>/dev/null
        printf "RC=%s SLEEPS=%s" "$rc" "$sl"' 2>&1)"
    if [[ "$got" == "RC=2 SLEEPS=0" ]]; then
        inj_bad "6a. 送失敗仍燒預算後 2a 仍綠——快速略過沒被量到"
    else
        if [[ "$got" == "RC=2 SLEEPS=30" ]]; then
            inj_ok "6a. 送失敗仍燒掉 30 秒（got [$got]）——2a 會紅"
        else
            inj_bad "6a. 行為變了但不是預期的罰站（got [$got]）——harness 問題"
        fi
    fi
    # 6b 流程層：同 3b 夾具在突變版上 → s1 罰站 90 秒才換人。
    printf '%s\n' "$NODE2" > "$SANDBOX/node-map.json"
    printf 's1:1\ns2:0\n' > "$SANDBOX/send-map"
    MLP_SAVE="$MLP_FILE"; MLP_FILE="$INJ2"
    got="$(wake_run 0)"
    s1wait="$(awk '/^SEND/ {ns++} /^SLEEP/ {per[ns]+=$2} END {printf "%d", per[1]+0}' "$SANDBOX/ev.log")"
    MLP_FILE="$MLP_SAVE"
    if [[ "$s1wait" == "0" ]]; then
        inj_bad "6b. 送失敗仍燒預算後 3b 仍綠——立刻換人沒被量到"
    else
        if [[ "$s1wait" == "90" ]]; then
            inj_ok "6b. 送失敗罰站 90 秒才換人（s1wait=90）——3b 會紅"
        else
            inj_bad "6b. 行為變了但不是預期的罰站（s1wait=[$s1wait]）——harness 問題"
        fi
    fi
fi
# 7. 只吃陣列不吃字串 → 舊形狀 var 直接壞掉。
INJ3="$SANDBOX/mutant-arrayonly.sh"
python3 - "$MLP" "$INJ3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'elif type == "string" then . else empty end'
new = 'else empty end'
assert src.count(old) == 1, "arrayonly needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "7. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ3" 2>/dev/null; then
    inj_bad "7. 注入版語法錯誤——harness 問題"
else
    got="$(WJSON="$J1" MLP_FILE="$INJ3" OUTF="$SANDBOX/s-out" ERRF="$SANDBOX/s-err" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; : > "$OUTF"; : > "$ERRF"; if wake_senders "$WJSON" >"$OUTF" 2>"$ERRF"; then rc=0; else rc=$?; fi; n="${#WAKE_SENDERS[@]}"; list=""; if [[ "$n" -gt 0 ]]; then list="${WAKE_SENDERS[*]}"; fi; printf "RC=%s N=%s LIST=%s" "$rc" "$n" "$list"' 2>&1)"
    if [[ "$got" == "RC=0 N=1 LIST=s1" ]]; then
        inj_bad "7. 只吃陣列後 1a 仍綠——字串形狀沒被量到"
    else
        if [[ "$got" == "RC=1 N=0 LIST=" ]]; then
            inj_ok "7. 只吃陣列後舊形狀字串變錯誤（got [$got]）——1a 會紅"
        else
            inj_bad "7. 行為變了但不是預期的壞掉（got [$got]）——harness 問題"
        fi
    fi
fi
# 8. 最後一台不吃剩餘 → 總等待被算術提早截斷。
INJ4="$SANDBOX/mutant-fixed90.sh"
python3 - "$MLP" "$INJ4" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'budget=$((300 - waited_total))'
assert src.count(old) == 1, "fixed90 needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, 'budget=90', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "8. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ4" 2>/dev/null; then
    inj_bad "8. 注入版語法錯誤——harness 問題"
else
    printf '%s\n' "$NODE2" > "$SANDBOX/node-map.json"
    printf 's1:0\ns2:0\n' > "$SANDBOX/send-map"
    MLP_SAVE="$MLP_FILE"; MLP_FILE="$INJ4"
    got="$(wake_run 999999)"
    MLP_FILE="$MLP_SAVE"
    if [[ "$got" == "RC=1 SENDS=2 TOT=300 W1=s1:90 W2=s2:210" ]]; then
        inj_bad "8. 末台固定 90 後 3c 仍綠——剩餘預算沒被量到"
    else
        if [[ "$got" == "RC=1 SENDS=2 TOT=180 W1=s1:90 W2=s2:90" ]]; then
            inj_ok "8. 末台固定 90 後總等待剩 180（got [$got]）——3c 會紅"
        else
            inj_bad "8. 行為變了但不是預期的截斷（got [$got]）——harness 問題"
        fi
    fi
fi
# 9. 成功訊息不指名代送者 → §6 可觀測性轉紅。
INJ5="$SANDBOX/mutant-noname.sh"
python3 - "$MLP" "$INJ5" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "(after %ss, via %s)\\n' \"$C_GREEN\" \"$node\" \"$C_RESET\" \"$((waited_total + elapsed))\" \"$sender\""
new = "(after %ss)\\n' \"$C_GREEN\" \"$node\" \"$C_RESET\" \"$((waited_total + elapsed))\""
assert src.count(old) == 1, "noname needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "9. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ5" 2>/dev/null; then
    inj_bad "9. 注入版語法錯誤——harness 問題"
else
    printf '%s\n' "$NODE1" > "$SANDBOX/node-map.json"
    printf 's1:0\n' > "$SANDBOX/send-map"
    MLP_SAVE="$MLP_FILE"; MLP_FILE="$INJ5"
    got="$(wake_run 0)"
    MLP_FILE="$MLP_SAVE"
    if grep -qF 'via s1)' "$SANDBOX/w-out" 2>/dev/null; then
        inj_bad "9. 拿掉指名後 3d 仍綠——成功行沒被量到"
    else
        if [[ "$got" == "RC=0 SENDS=1"* ]] && grep -qF 'is up' "$SANDBOX/w-out" 2>/dev/null; then
            inj_ok "9. 拿掉指名後成功行不帶代送者（out [$(tr '\n' ' ' < "$SANDBOX/w-out" | head -c 120)]）——3d 會紅"
        else
            inj_bad "9. 行為變了但不是預期的匿名成功（got [$got]）——harness 問題"
        fi
    fi
fi

echo "=== 13-15. 注入（unknown）：拿掉修正，斷言必須轉紅 ==="
# 13. 把 unknown 併回 3 → 網關失敗被說成「沒在預算內起來」。
#   突變：master 打不開回 3（不是 4）。
INJ6="$SANDBOX/mutant-unknown3.sh"
python3 - "$MLP" "$INJ6" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    if ! open_gateway_master 2>/dev/null; then\n'
       '        WAKE_SEND_ERR="gateway unreachable, cannot verify wake"\n'
       '        close_gateway_master\n'
       '        return 4\n'
       '    fi')
new = ('    if ! open_gateway_master 2>/dev/null; then\n'
       '        WAKE_SEND_ERR="gateway unreachable, cannot verify wake"\n'
       '        close_gateway_master\n'
       '        return 3\n'
       '    fi')
assert src.count(old) == 1, "unknown3 needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "13. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ6" 2>/dev/null; then
    inj_bad "13. 注入版語法錯誤——harness 問題"
else
    # 13a 單元層：同 §10 夾具在突變版上 → 應回 4 卻回 3。
    printf 's1:0\n' > "$SANDBOX/send-map"
    got="$(MLP_FILE="$INJ6" BUDGET=30 UP_AFTER=999999 MAP="$SANDBOX/send-map" EVENT_LOG="$SANDBOX/ev.log" PROBE_COUNT="$SANDBOX/probe-n" FAKE_MASTER_RC=1 ARGV_LOG="$SANDBOX/argv.log" OUTF="$SANDBOX/u-out" ERRF="$SANDBOX/u-err" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        run_on_node() {
            printf "SEND %s\n" "$1" >> "$EVENT_LOG"
            rc=0
            while IFS=: read -r m r; do
                if [[ "$m" == "$1" ]]; then rc="$r"; break; fi
            done < "$MAP" 2>/dev/null
            case "$rc" in ""|0) return 0;; *) printf "run_on_node stub: %s unreachable\n" "$1"; return 1;; esac
        }
        gw_probe_port() { printf "down"; }
        : > "$EVENT_LOG"; printf 0 > "$PROBE_COUNT"
        wake_try_sender s1 "B4:2E:99:FB:63:5E" "192.168.0.136" "2323" "$BUDGET" >/dev/null 2>&1; rc=$?
        printf "RC=%s" "$rc"' 2>&1)"
    if [[ "$got" == "RC=4" ]]; then
        inj_bad "13a. 併回 3 後 §10 仍綠——未知態沒被量到"
    else
        if [[ "$got" == "RC=3" ]]; then
            inj_ok "13a. 併回 3 後網關失敗回 3（got [$got]）——§10 會紅"
        else
            inj_bad "13a. 行為變了但不是預期的併回（got [$got]）——harness 問題"
        fi
    fi
    # 13b 流程層：同 §11 夾具（網關恆失敗，真 unknown）在突變版上 →
    # 出現「沒起來」的宣稱。master_rc 傳 1 是關鍵，否則探測走輪詢、
    # 試驗全是真 3，紅證是空心的（曾因此誤報 inj_ok）。
    printf '%s\n' "$NODE2" > "$SANDBOX/node-map.json"
    printf 's1:0\ns2:0\n' > "$SANDBOX/send-map"
    MLP_SAVE="$MLP_FILE"; MLP_FILE="$INJ6"
    got="$(wake_run 999999 1)"
    MLP_FILE="$MLP_SAVE"
    if grep -qF 'did not come up' "$SANDBOX/w-out" 2>/dev/null; then
        inj_ok "13b. 併回 3 後 unknown 被說成沒起來（got [$got]）——流程斷言會紅"
    else
        inj_bad "13b. 併回 3 後仍無宣稱（got [$got]）——harness 問題"
    fi
fi
# 14. 全 unknown 時結尾說 could not wake → 宣稱了沒驗證過的結論。
#   突變：全 unknown 結尾改回 could not wake（退回不分 unknown 的舊結尾）。
INJ8="$SANDBOX/mutant-couldnotwake.sh"
python3 - "$MLP" "$INJ8" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'echo "could not verify whether ${node} woke — every sender unverified:"'
assert src.count(old) == 1, "couldnotwake needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, 'echo "could not wake ${node} — every sender failed:"', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "14. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ8" 2>/dev/null; then
    inj_bad "14. 注入版語法錯誤——harness 問題"
else
    printf '%s\n' "$NODE2" > "$SANDBOX/node-map.json"
    printf 's1:0\ns2:0\n' > "$SANDBOX/send-map"
    MLP_SAVE="$MLP_FILE"; MLP_FILE="$INJ8"
    got="$(wake_run 999999 1)"
    MLP_FILE="$MLP_SAVE"
    if grep -qF 'could not wake' "$SANDBOX/w-out" 2>/dev/null; then
        inj_ok "14. 結尾退回 could not wake（got [$got]）——§11 會紅"
    else
        inj_bad "14. 退回舊結尾後仍無該宣稱（got [$got]）——harness 問題"
    fi
fi
# 15. unknown 不再往下一台試 → fallback 被誤當成成功或終止。
#   突變：trc 4 直接回 0（誤當成功；終止同理，斷言只看 SEND 數與 rc）。
INJ7="$SANDBOX/mutant-nofallback.sh"
python3 - "$MLP" "$INJ7" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('        if [[ "$trc" -eq 2 ]]; then\n'
       '            reason="$WAKE_SEND_ERR"\n'
       '            [[ -n "$reason" ]] || reason="unknown error"\n'
       '            printf \'  %s: could not send (%s)\\n\' "$sender" "$reason"\n'
       '            fail_names+=("$sender")\n'
       '            fail_reasons+=("could not send: $reason")\n'
       '            continue\n'
       '        fi')
new = old + ('\n'
       '        if [[ "$trc" -eq 4 ]]; then\n'
       '            return 0\n'
       '        fi')
assert src.count(old) == 1, "nofallback needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "15. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ7" 2>/dev/null; then
    inj_bad "15. 注入版語法錯誤——harness 問題"
else
    printf '%s\n' "$NODE2" > "$SANDBOX/node-map.json"
    printf 's1:0\ns2:0\n' > "$SANDBOX/send-map"
    MLP_SAVE="$MLP_FILE"; MLP_FILE="$INJ7"
    got="$(wake_run 999999 1)"
    MLP_FILE="$MLP_SAVE"
    if [[ "$got" == "RC=1 SENDS=2"* ]]; then
        inj_bad "15. 不再往下試後 §12 仍綠——fallback 沒被量到"
    else
        if [[ "$got" == "RC=0 SENDS=1"* ]]; then
            inj_ok "15. 不再往下試後一次 unknown 即成功（got [$got]）——§12 會紅"
        else
            inj_bad "15. 行為變了但不是預期的截斷（got [$got]）——harness 問題"
        fi
    fi
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
