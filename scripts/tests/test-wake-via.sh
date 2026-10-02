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
# §16-25（PR-C／D6）多一層契約：**wol 決定資格，via 只決定順序**。
#   沒宣告 wol 的代送方一個封包都不送，被略過的那台照樣佔一個 (n/m) 序號；
#   沒有人有資格要明確失敗；宣告讀不到 ≠ 有資格；verify-capabilities 要回報
#   via 裡沒宣告 wol 的機器。細節在那一段自己的註解。
#   斷言只釘行為（序號／訊息／封包數／回傳碼），不綁新的函式名——D6 沒規定
#   Model／ViewModel 怎麼切，綁名稱等於替 impl 決定介面。
#   事件檔多一種行：`WOL <節點>` 只記真正送出封包的那一次（見 wake_run 的 stub）。
#   SEND 數「有沒有為了任何事由去碰這台機器」，WOL 數「送了幾個封包」——分開算，
#   否則「為了讀宣告去查它」會被算成「送了封包」。
#   代送方的宣告從哪裡讀是 impl 的自由，所以 pool-resolve 與 gh 兩個 stub 都從
#   同一份 node-map.json 出答案。
#   ⚠️ bash 3.2 的已知錯：**`$VAR` 後面緊接多位元組字元會被吃掉**（`"（$X）"` 會
#   報 `X?: unbound variable`）。新的訊息裡變數一律用半形括號包。
#
# 相容：只用 bash 3.2 就有的語法（無 nameref、無大小寫轉換、無關聯陣列、
#   空陣列在 set -u 下不直接展開；測試本體連索引陣列都不用，只用字串與檔案）。
#   已在 macOS bash 3.2.57 與 ubuntu 24.04 / bash 5.2.21（--network none）兩邊
#   各跑過一次，結果一致。
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
#   §16 起多一項：代送方的宣告「從哪裡讀」是 impl 的自由（pool-resolve 是
#   正式途徑，直接 gh api 也不是不可能）。兩個讀法都從同一份 NODE_MAP 出答案，
#   斷言才量的是「有沒有篩選資格」，不是「走哪一個讀取器」。查不到的節點回 3，
#   與 pool-resolve 對 404 的回碼一致——「讀不到」必須在兩條路上長得一樣，
#   否則同一個缺陷只在一條路上被測到。
cat > "$SANDBOX/shims/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'CALL %s\n' "$*" >> "${GH_LOG:-/dev/null}"
if [[ -n "${NODE_MAP:-}" && -f "$NODE_MAP" ]]; then
  for a in "$@"; do
    case "$a" in
      repos/*/actions/variables\?*)
        jq -r 'keys_unsorted[] | "NODE_" + (. | ascii_upcase | gsub("-"; "_"))' "$NODE_MAP" 2>/dev/null
        exit 0
        ;;
      repos/*/actions/variables/NODE_*)
        out="$(jq -r --arg v "${a##*/}" \
          'to_entries[] | select("NODE_" + (.key | ascii_upcase | gsub("-"; "_")) == $v) | .value' \
          "$NODE_MAP" 2>/dev/null)"
        if [[ -n "$out" ]]; then printf '%s\n' "$out"; exit 0; fi
        exit 3
        ;;
    esac
  done
fi
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
            # WOL <節點>：只記真正送出封包的那一次（命令裡有 pool-wol）。
            # SEND 數的是「有沒有為了任何事由去碰這台機器」——§16 的資格篩選
            # 會為了讀宣告去查節點，那不是封包。兩個計數分開，才不會把
            # 「查過它」說成「送過它」，也不會把「送過它」藏在 SEND 裡面。
            case "$2" in
                *pool-wol*) printf "WOL %s\n" "$1" >> "$EVENT_LOG" ;;
            esac
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
# D6 之後（PR-C），**真的代送方都會宣告 `wol`**：wake 只把宣告了 `wol` 的那台
# 當成能用的代送方（design.md D6／spec.md「叫醒只交給有資格的代送方」）。
# 這兩個 node 以前**只出現在 fh-l 的 via 清單裡**，`POOL_RESOLVE` 查不到它們，
# 於是 `node_wol_state` 回 2（宣告讀不到）→ 兩台都被略過 → 3a-3d／12 全部
# `SENDS=0`。
#
# 這不是夾具過時，是**夾具沒反映現實**：那個形狀在 PR-C 之後不存在了。
# 而「宣告讀不到就當成有資格」正是 §16.4 的命題、注入 20 專門抓的錯誤方向，
# 所以讓 3a-3d 綠的唯一辦法不是放寬 16.4，而是讓 s1/s2 真的查得到、而且真的
# 宣告 `wol`。命題不變：3a-3d 量的一樣是換人、預算、不謊報。
NODE_S1='{"name":"s1","role":"provider","user":"worker","capabilities":{"worker-host":{"runtime":"docker"},"wol":{"methods":["unicast"]}}}'
NODE_S2='{"name":"s2","role":"provider","user":"worker","capabilities":{"worker-host":{"runtime":"docker"},"wol":{"methods":["unicast"]}}}'
FH_L_VIA2='{"name":"fh-l","role":"provider","gateway_port":2323,"user":"worker","power":{"launch":{"method":"wol-unicast","via":["s1","s2"],"mac":"B4:2E:99:FB:63:5E","target_ip":"192.168.0.136"}}}'
FH_L_VIA1='{"name":"fh-l","role":"provider","gateway_port":2323,"user":"worker","power":{"launch":{"method":"wol-unicast","via":["s1"],"mac":"B4:2E:99:FB:63:5E","target_ip":"192.168.0.136"}}}'
NODE2="{\"fh-l\":${FH_L_VIA2},\"s1\":${NODE_S1},\"s2\":${NODE_S2}}"
NODE1="{\"fh-l\":${FH_L_VIA1},\"s1\":${NODE_S1},\"s2\":${NODE_S2}}"
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

# ==== 16-25. D6：wol 決定資格，via 只決定順序 ============================
#
# design.md D6／spec.md「叫醒只交給有資格的代送方」：via 的順序不變，但沒宣告
# wol 的代送方一個封包都不送；被略過的那台照樣佔一個 (n/m) 序號（不佔的話，
# 使用者會以為自己在用第一順位，其實第一順位被吃掉了，而且畫面上看不出來）；
# 沒有人有資格要明確失敗，不能靜靜結束。
#
# 斷言全部釘 cmd_wake 的**行為**（序號、訊息、封包數、回傳碼），不釘任何新的
# 函式名——D6 沒有規定 Model／ViewModel 怎麼切，釘名稱等於替 impl 決定介面，
# 也會讓「實作只是換了個函式名」看起來像通過。
#
# 宣告從哪裡讀是 impl 的自由（pool-resolve 是正式途徑；直接 gh api 也存在過），
# 所以 pool-resolve 與 gh 兩個 stub 都從同一份 node-map.json 出答案。
#
# 每個 case 都寫成 chk_16x <被測 mlp>：回 0 = 符合 D6，實測值放進 LAST_GOT。
# 同一段斷言跑兩次——對產品碼（必須紅，紅的原因是「沒做篩選」而不是指令不存在）
# 與對注入版（INJ-P／INJ-T 必須綠）。注入證明的是這份斷言本身有牙，不是另一份
# 複寫的檢查順便有牙。

D6_ALPHA_NOWOL='{"name":"alpha","role":"provider","user":"worker","capabilities":{"worker-host":{"runtime":"docker"}}}'
D6_ALPHA_WOL='{"name":"alpha","role":"provider","user":"worker","capabilities":{"worker-host":{"runtime":"docker"},"wol":{"methods":["unicast"]}}}'
D6_BRAVO_WOL='{"name":"bravo","role":"provider","user":"worker","capabilities":{"worker-host":{"runtime":"docker"},"wol":{"methods":["unicast"]}}}'
D6_BRAVO_NOWOL='{"name":"bravo","role":"provider","user":"worker","capabilities":{"github":{"repos":{"FATESAIKOU/MyBrain":["read"]}}}}'
D6_CHARLIE_NOWOL='{"name":"charlie","role":"provider","user":"worker","capabilities":{"worker-host":{"runtime":"docker"}}}'
LAST_GOT=""

# d6_fhl <via-json>：被叫醒的節點。它自己宣告 worker-host，讓 verify-capabilities
# 走完整條路徑（沒有宣告時 cap_verify_one 會在列 rows 之前就 return）。
d6_fhl() {
    printf '{"name":"fh-l","role":"provider","gateway_port":2323,"user":"worker","capabilities":{"worker-host":{"runtime":"docker"}},"power":{"launch":{"method":"wol-unicast","via":%s,"mac":"B4:2E:99:FB:63:5E","target_ip":"192.168.0.136"}}}' "$1"
}

# d6_map <via-json> <alpha> <bravo> [charlie]：寫 node-map.json。沒給的節點
# 就不在 map 裡，於是 pool-resolve 與 gh 兩個 stub 都回「查不到」。
d6_map() {
    {
        printf '{"fh-l":%s,"alpha":%s,"bravo":%s' "$(d6_fhl "$1")" "$2" "$3"
        [[ -n "${4:-}" ]] && printf ',"charlie":%s' "$4"
        printf '}\n'
    } > "$SANDBOX/node-map.json"
}

d6_wol()    { awk -v n="$1" '$1 == "WOL" && $2 == n {c++} END {printf "%d", c+0}' "$SANDBOX/ev.log"; }
d6_send()   { awk -v n="$1" '$1 == "SEND" && $2 == n {c++} END {printf "%d", c+0}' "$SANDBOX/ev.log"; }
d6_wol_n()  { awk '$1 == "WOL" {c++} END {printf "%d", c+0}' "$SANDBOX/ev.log"; }
d6_send_n() { awk '$1 == "SEND" {c++} END {printf "%d", c+0}' "$SANDBOX/ev.log"; }
d6_order()  { awk '$1 == "WOL" {printf "%s ", $2}' "$SANDBOX/ev.log"; }
d6_both()   { cat "$SANDBOX/w-out" "$SANDBOX/w-err" > "$SANDBOX/w-both" 2>/dev/null; }

# d6_line3 <檔> <a> <b> <c>：同一行同時含 a、b，且含 c（大小寫不拘）才回行號。
#   「不是喚醒行」是刻意的：現有的 `waking <node> via <sender> (n/m): unicast
#   WoL to ...` 本身就同時含節點名、序號與 "WoL"，把它算成略過行等於沒斷言。
#   略過行必須是另一行——而且必須寫出原因，這是 D6 唯一要求的訊息內容。
d6_line3() {
    awk -v a="$2" -v b="$3" -v c="$4" 'index($0, a) && index($0, b) && index(tolower($0), c) && !index($0, "waking") {print NR; exit}' "$1"
}
d6_line2() {
    awk -v a="$2" -v b="$3" 'index($0, a) && index($0, b) && !index($0, "waking") {print NR; exit}' "$1"
}
d6_at() { awk -v p="$2" 'index($0, p) {print NR; exit}' "$1"; }
d6_num() { case "$1" in ""|*[!0-9]*) return 1 ;; esac; }

# chk_16x 全部回 0 = 符合 D6。跑完把實測值寫進 LAST_GOT 給失敗訊息用。
# 16.1：via=[alpha,bravo]，只有 bravo 宣告 wol。
chk_161() {
    local save="$MLP_FILE" rc=0 got skip try aw bw
    MLP_FILE="$1"; LAST_GOT=""
    d6_map '["alpha","bravo"]' "$D6_ALPHA_NOWOL" "$D6_BRAVO_WOL"
    printf 'alpha:0\nbravo:0\n' > "$SANDBOX/send-map"
    got="$(wake_run 0)"; d6_both
    skip="$(d6_line3 "$SANDBOX/w-out" 'alpha' '(1/2)' 'wol')"
    try="$(d6_at "$SANDBOX/w-out" 'waking fh-l via bravo (2/2)')"
    aw="$(d6_wol alpha)"; bw="$(d6_wol bravo)"
    LAST_GOT="$got a_wol=$aw b_wol=$bw skip_at=[$skip] try_at=[$try] out=[$(tr '\n' '|' < "$SANDBOX/w-out" | head -c 220)]"
    d6_num "$skip" || rc=1                # 略過行帶序號 1/2 與原因（原因提到 wol）
    d6_num "$try"  || rc=1                # 換到 bravo，序號仍是 2/2（沒有被壓縮成 1/1）
    if d6_num "$skip" && d6_num "$try" && [[ "$skip" -ge "$try" ]]; then rc=1; fi
    [[ "$aw" == "0" ]] || rc=1            # alpha 一個封包都不送
    [[ "$(d6_send alpha)" == "0" ]] || rc=1
    [[ "$bw" == "1" ]] || rc=1
    [[ "$got" == "RC=0 SENDS=1"* ]] || rc=1
    MLP_FILE="$save"; return "$rc"
}

# 16.2：via=[bravo,alpha]，兩台都宣告 wol → 照 via 的順序，先 bravo。
#   這是 16.1 的對照組：如果「永遠跳過第一台」也能過 16.1，這一條會擋下來。
chk_162() {
    local save="$MLP_FILE" rc=0 got order b1 a2
    MLP_FILE="$1"; LAST_GOT=""
    d6_map '["bravo","alpha"]' "$D6_ALPHA_WOL" "$D6_BRAVO_WOL"
    printf 'alpha:0\nbravo:0\n' > "$SANDBOX/send-map"
    got="$(wake_run 999999)"
    order="$(d6_order)"
    b1="$(d6_at "$SANDBOX/w-out" 'waking fh-l via bravo (1/2)')"
    a2="$(d6_at "$SANDBOX/w-out" 'waking fh-l via alpha (2/2)')"
    LAST_GOT="$got order=[$order] bravo_at=[$b1] alpha_at=[$a2]"
    [[ "$order" == "bravo alpha " ]] || rc=1
    d6_num "$b1" || rc=1
    d6_num "$a2" || rc=1
    if d6_num "$b1" && d6_num "$a2" && [[ "$b1" -ge "$a2" ]]; then rc=1; fi
    # 兩台都有資格時，時間預算與既有 §3c 完全相同（90 + 210 = 300）：
    # 篩選不准順手改掉預算。
    [[ "$got" == "RC=1 SENDS=2 TOT=300 W1=bravo:90 W2=alpha:210" ]] || rc=1
    MLP_FILE="$save"; return "$rc"
}

# 16.3：via 裡沒有一台宣告 wol → 失敗、零封包、說明原因。
#   「不得宣稱 every sender failed」是這條的牙：把兩台都 continue 掉、一個
#   封包都不送，卻照舊印出「每一台都失敗」，是對沒有觀察過的事下結論——
#   跟這個 repo 反覆在守的同一件事（§11、§10 的 unknown 不併回 3）。
chk_163() {
    local save="$MLP_FILE" rc=0 got wn sn
    MLP_FILE="$1"; LAST_GOT=""
    d6_map '["alpha","charlie"]' "$D6_ALPHA_NOWOL" "$D6_BRAVO_WOL" "$D6_CHARLIE_NOWOL"
    printf 'alpha:0\ncharlie:0\n' > "$SANDBOX/send-map"
    got="$(wake_run 0)"; d6_both
    wn="$(d6_wol_n)"; sn="$(d6_send_n)"
    LAST_GOT="$got wol=$wn send=$sn both=[$(tr '\n' '|' < "$SANDBOX/w-both" | head -c 240)]"
    [[ "$got" == "RC=0"* ]] && rc=1        # 不能靜靜結束（回 0）
    [[ "$wn" == "0" ]] || rc=1             # 零封包
    [[ "$sn" == "0" ]] || rc=1             # 連 run_on_node 都沒碰過
    grep -qi 'wol' "$SANDBOX/w-both" || rc=1        # 訊息說明原因
    grep -q 'every sender failed' "$SANDBOX/w-both" && rc=1
    grep -q 'did not come up' "$SANDBOX/w-both" && rc=1
    grep -q 'is up' "$SANDBOX/w-both" && rc=1
    MLP_FILE="$save"; return "$rc"
}

# 16.4：代送方的宣告讀不到（它的 NODE_* 不存在）→ 略過並說明，不能當成有資格。
#   「讀不到」必須與「沒宣告 wol」分開：分開之後才不會出現兩種都算合格的情形。
chk_164() {
    local save="$MLP_FILE" rc=0 got skip try gw gw2 bw
    MLP_FILE="$1"; LAST_GOT=""
    d6_map '["ghost","bravo"]' "$D6_ALPHA_NOWOL" "$D6_BRAVO_WOL"   # ghost 不在 map 裡
    printf 'ghost:0\nbravo:0\n' > "$SANDBOX/send-map"
    got="$(wake_run 0)"; d6_both
    skip="$(d6_line2 "$SANDBOX/w-out" 'ghost' '(1/2)')"
    try="$(d6_at "$SANDBOX/w-out" 'waking fh-l via bravo (2/2)')"
    gw="$(d6_wol ghost)"; gw2="$(d6_send ghost)"; bw="$(d6_wol bravo)"
    LAST_GOT="$got ghost_wol=$gw ghost_send=$gw2 bravo_wol=$bw skip_at=[$skip] try_at=[$try] out=[$(tr '\n' '|' < "$SANDBOX/w-out" | head -c 220)]"
    d6_num "$skip" || rc=1                # 略過行：指名它、帶序號、不是喚醒行
    d6_num "$try"  || rc=1
    if d6_num "$skip" && d6_num "$try" && [[ "$skip" -ge "$try" ]]; then rc=1; fi
    [[ "$gw" == "0" ]] || rc=1            # 讀不到 ≠ 有資格：零封包
    [[ "$gw2" == "0" ]] || rc=1
    [[ "$bw" == "1" ]] || rc=1
    [[ "$got" == "RC=0 SENDS=1"* ]] || rc=1
    MLP_FILE="$save"; return "$rc"
}

# d6_verify <mlp> <node>：cmd_verify_capabilities 跑一節點，出 stdout+stderr 併檔。
d6_verify() {
    MLP_FILE="$1" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" NODE_MAP="$SANDBOX/node-map.json" \
    MLP_REPO_ROOT="$REPO_ROOT" GH_LOG="$SANDBOX/gh.log" ARGV_LOG="$SANDBOX/argv.log" \
    OUTF="$SANDBOX/v-out" ERRF="$SANDBOX/v-err" RESDONE="$SANDBOX/v-rc" \
    HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="$POOL_OVERRIDE"
        : > "$OUTF"; : > "$ERRF"; rm -f "$RESDONE"
        ( cmd_verify_capabilities "$1" >"$OUTF" 2>"$ERRF" )
        printf "RC=%s" "$?" > "$RESDONE"' _ "$2" 2>/dev/null
    D6_VRC="$(sed 's/^RC=//' "$SANDBOX/v-rc" 2>/dev/null)"
    cat "$SANDBOX/v-out" "$SANDBOX/v-err" > "$SANDBOX/v-both" 2>/dev/null
}

# 16.5a：verify-capabilities 要回報 via 裡沒宣告 wol 的機器（這裡是 alpha）。
chk_165a() {
    local rc=0 hit
    LAST_GOT=""
    d6_map '["alpha","bravo"]' "$D6_ALPHA_NOWOL" "$D6_BRAVO_WOL"
    d6_verify "$1" fh-l
    hit="$(awk 'index($0, "alpha") && index(tolower($0), "wol") {print NR; exit}' "$SANDBOX/v-both")"
    LAST_GOT="rc=$D6_VRC hit_at=[$hit] out=[$(tr '\n' '|' < "$SANDBOX/v-both" | head -c 220)]"
    d6_num "$hit" || rc=1
    case "$D6_VRC" in 0|1|3) ;; *) rc=1 ;; esac   # 不得是 usage／崩潰的回碼
    return "$rc"
}

# 16.5b：同一個 via，只是不合格的那台換成 bravo → 報的也必須換成 bravo。
#   這是「照宣告回報」而不是「照位置／照名稱回報」的證據。
chk_165b() {
    local rc=0 hit
    LAST_GOT=""
    d6_map '["alpha","bravo"]' "$D6_ALPHA_WOL" "$D6_BRAVO_NOWOL"
    d6_verify "$1" fh-l
    hit="$(awk 'index($0, "bravo") && index(tolower($0), "wol") {print NR; exit}' "$SANDBOX/v-both")"
    LAST_GOT="rc=$D6_VRC hit_at=[$hit] out=[$(tr '\n' '|' < "$SANDBOX/v-both" | head -c 220)]"
    d6_num "$hit" || rc=1
    case "$D6_VRC" in 0|1|3) ;; *) rc=1 ;; esac
    return "$rc"
}

# 16.6a：略過一台之後時間預算不變。序號仍然照 via 走（被略過的照樣佔號），
#   所以唯一被嘗試的那台是末台，吃剩餘，總計仍是 300，被略過的那台零等待。
chk_166a() {
    local save="$MLP_FILE" rc=0 got
    MLP_FILE="$1"; LAST_GOT=""
    d6_map '["alpha","bravo"]' "$D6_ALPHA_NOWOL" "$D6_BRAVO_WOL"
    printf 'alpha:0\nbravo:0\n' > "$SANDBOX/send-map"
    got="$(wake_run 999999)"
    LAST_GOT="$got"
    [[ "$got" == "RC=1 SENDS=1 TOT=300 W1=bravo:300" ]] || rc=1
    MLP_FILE="$save"; return "$rc"
}

# 16.6b：被略過的那台存在時，第四態仍然是第四態（不能因為少試一台就降級成
#   「沒醒」，也不能變成 could not wake）。這是 D6「四態與時間預算都不動」。
chk_166b() {
    local save="$MLP_FILE" rc=0 got
    MLP_FILE="$1"; LAST_GOT=""
    d6_map '["alpha","bravo"]' "$D6_ALPHA_NOWOL" "$D6_BRAVO_WOL"
    printf 'alpha:0\nbravo:0\n' > "$SANDBOX/send-map"
    got="$(wake_run 999999 1)"; d6_both
    LAST_GOT="$got both=[$(tr '\n' '|' < "$SANDBOX/w-both" | head -c 220)]"
    [[ "$got" == "RC=1 SENDS=1"* ]] || rc=1
    grep -q 'could not wake' "$SANDBOX/w-out" && rc=1
    grep -q 'could not verify whether fh-l woke' "$SANDBOX/w-out" || rc=1
    MLP_FILE="$save"; return "$rc"
}

# 16.7 混合情境：`via=[alpha(沒宣告 wol), bravo(有)]`，bravo 送出之後**證實沒醒**
#   （rc=3）。這是 16.6a 的同一個情境多問一句：16.6a 只量計數器
#   （`SENDS=1 TOT=300 W1=bravo:300`），量不到那句結語。
#
#   命題：最終結語**不得**出現 `every sender failed:`。alpha 從未被試過——
#   說它「失敗」是對沒有觀察過的事情下結論（WAKE-VIA-DESIGN.md §6 花 27 行在
#   避的那件事，跟 §10／§11 的 unknown 不併回 3、跟 §16.3 的
#   「不得宣稱 every sender failed」是同一條原則）。§16.3 那條牙只蓋「全部被略過」，
#   這條蓋「有人被略過、有人真的失敗了」——那才是混合情境，也是最容易漏掉的那個。
#
#   同時釘住幾件事，避免用錯的方式變綠：
#     * 仍然要說「沒醒」（不能改成什麼都不說）；
#     * 仍然要說是 bravo 沒醒、且原因是沒在預算內起來（逐台原因不能被拿掉）；
#     * **不准**改成 unknown 那一族——這裡 n_unknown=0，宣稱「無法確認」是另一個
#       方向的假話；
#     * **stderr 的 die 訊息不得寫成「all 2 wake sender(s) failed」**——同樣是
#       over-claim 的另一半：那一行用 `total`（via 的台數），而實際只試了 1 台。
#       stdout 的標題說「could not wake」是對的，stderr 補一句「all 2 failed」把它
#       抵消掉，使用者看到的還是同一個錯誤結論。
#
# 失敗時把「哪一條子句紅了」放進 LAST_WHY。注入 25／26 各只壞一件事，於是它們能
# 證明自己的那條子句真的被量到——如果只看「16.7 紅了」，兩個注入會互相顶包。
chk_167() {
    local save="$MLP_FILE" rc=0 got aw bw overclaim die_all die_n die_line why=""
    MLP_FILE="$1"; LAST_GOT=""; LAST_WHY=""
    d6_map '["alpha","bravo"]' "$D6_ALPHA_NOWOL" "$D6_BRAVO_WOL"
    printf 'alpha:0\nbravo:0\n' > "$SANDBOX/send-map"
    got="$(wake_run 999999)"; d6_both
    aw="$(d6_wol alpha)"; bw="$(d6_wol bravo)"
    overclaim="$(grep -c 'every sender failed' "$SANDBOX/w-out" 2>/dev/null || true)"
    # 「all 2 wake sender…」這個過度宣稱的字面，出現幾次。容忍中間的字
    # （`all 2 tried wake sender…` 也是同一個缺陷的變體）。
    die_all="$(grep -cE 'all 2 .*wake sender' "$SANDBOX/w-err" 2>/dev/null || true)"
    # 那一行 die（若有）報的台數。只認 `all N … wake sender(s) failed` 這個形狀，
    # 中間可以夾任何字（impl 寫成 `all 1 tried …` 也讀得出來）。換成別的措辭時
    # 下面兩個判斷自動不成立——**不報台數的訊息不會 over-claim**。
    die_line="$(grep -m1 'sender(s) failed' "$SANDBOX/w-err" 2>/dev/null || true)"
    die_n="$(printf '%s' "$die_line" | sed -n 's/^mlp: all \([0-9][0-9]*\) .*wake sender(s) failed.*/\1/p')"
    LAST_GOT="$got alpha_wol=$aw bravo_wol=$bw overclaim_lines=$overclaim die_all2=$die_all die_n=[${die_n:-none}] err=[$(tr '\n' '|' < "$SANDBOX/w-err" 2>/dev/null | head -c 120)] out=[$(tr '\n' '|' < "$SANDBOX/w-out" | head -c 240)]"
    [[ "$got" == "RC=1 SENDS=1"* ]] || { rc=1; why="${why} setup"; }
    [[ "$aw" == "0" ]] || { rc=1; why="${why} setup"; }   # 混合情境的前提：alpha 零封包
    [[ "$bw" == "1" ]] || { rc=1; why="${why} setup"; }   # bravo 送出了
    # ← 命題（stdout）：結語不得說「每一台都失敗」
    [[ "$overclaim" == "0" ]] || { rc=1; why="${why} heading"; }
    grep -q 'could not wake' "$SANDBOX/w-out" || { rc=1; why="${why} lost-wording"; }
    grep -q 'could not verify whether fh-l woke' "$SANDBOX/w-out" && { rc=1; why="${why} wrong-unknown"; }
    grep -qF 'bravo: sent, but fh-l did not come up' "$SANDBOX/w-out" || { rc=1; why="${why} lost-reason"; }
    # ← 命題（stderr）：die 訊息不得說「all 2 … failed」，也不得報 2 這個台數
    [[ "$die_all" == "0" ]] || { rc=1; why="${why} die-all2"; }
    [[ "$die_n" == "1" || -z "$die_n" ]] || { rc=1; why="${why} die-count"; }
    LAST_WHY="$why"
    MLP_FILE="$save"; return "$rc"
}

# 產品碼上的實測：每一條都必須紅，而且紅的原因是「沒做資格篩選」。
D6_CASES="161 162 163 164 165a 165b 166a 166b 167"
D6_WAKE_CASES="161 162 163 164 166a 166b"
D6_VERIFY_CASES="165a 165b"
d6_report() {   # d6_report <mlp>：跑全部 case，逐條 ok/bad
    local c fn label rc_any=0
    for c in $D6_CASES; do
        fn="chk_${c}"
        case "$c" in
            161) label="16.1 via=[A,B] 只有 B 宣告 wol：A 帶序號 1/2 被略過且零封包，改用 B (2/2)" ;;
            162) label="16.2 兩台都有資格時照 via 順序（先 B），預算仍是 90＋210" ;;
            163) label="16.3 沒有人宣告 wol：非 0、零封包、說明原因，且不宣稱「每一台都失敗」" ;;
            164) label="16.4 代送方宣告讀不到：略過並帶序號，不能當成有資格" ;;
            165a) label="16.5a verify-capabilities 回報 via 裡沒宣告 wol 的機器（alpha）" ;;
            165b) label="16.5b 同一個 via 換一台不合格（bravo）→ 回報也換成 bravo" ;;
            166a) label="16.6a 略過一台後時間預算不變：末台吃剩餘，總計 300，略過者零等待" ;;
            166b) label="16.6b 略過一台後第四態仍是第四態（unknown，不降級成 could not wake）" ;;
            167) label="16.7 混合情境（alpha 被略過、bravo 送出但沒醒）：結語不得說 every sender failed" ;;
        esac
        if "$fn" "$1"; then ok "$label"; else bad "$label (got [$LAST_GOT])"; rc_any=1; fi
    done
    return "$rc_any"
}

echo "=== 16-25. D6：wol 決定資格，via 只決定順序 ==="
d6_report "$MLP_FILE"

# d6_inject <突變檔> <case 清單>：同一組斷言在突變版上必須全綠。全綠回 0。
d6_inject() {
    local c fn red=""
    for c in $2; do
        fn="chk_${c}"
        "$fn" "$1" || red="${red} ${c}"
    done
    LAST_GOT="紅的 case:${red:-<無>}"
    [[ -z "$red" ]]
}

# inj_gate <編號> <突變檔>：突變檔沒產生或語法錯就是 harness 問題，不是斷言的問題。
inj_gate() {
    if [[ ! -f "$2" ]]; then
        inj_bad "${1}. 突變腳本失敗（被測物形狀變了）——harness 問題"
        return 1
    fi
    if ! bash -n "$2" 2>/dev/null; then
        inj_bad "${1}. 突變版語法錯誤——harness 問題"
        return 1
    fi
    return 0
}

# 18-21、23、24. 注入：拿掉 D6 的修正，斷言必須轉紅。
#
# 18-21、23、24：D6 落地後這幾條是「拿掉修正」；命題不變。錨點全部對到 impl 實際的形狀。

# 18：16.2 必須仍綠——它證明「兩台都有資格」時本來就與篩選無關。
INJP="$SANDBOX/mutant-no-wol-gate.sh"
python3 - "$MLP" "$INJP" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('        node_wol_state "$sender"; wst=$?\n'
       '        if [[ "$wst" -ne 0 ]]; then\n'
       '            if [[ "$wst" -eq 2 ]]; then\n'
       '                skip_reasons+=("cannot read its declaration \u2014 not usable as a wol sender")\n'
       '            else\n'
       '                skip_reasons+=("does not declare the wol capability")\n'
       '            fi\n'
       '            skip_names+=("$sender")\n'
       '            printf \'  %s (%d/%d): skipped \u2014 %s\\n\' "$sender" "$i" "$total" "${skip_reasons[${#skip_reasons[@]}-1]}"\n'
       '            continue\n'
       '        fi\n')
assert src.count(old) == 1, "wol-gate needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, '', 1))
PY
if inj_gate 18 "$INJP"; then
    red=""
    for c in $D6_WAKE_CASES; do
        fn="chk_${c}"
        "$fn" "$INJP" || red="${red} ${c}"
    done
    LAST_GOT="紅的 case:${red:-<無>}"
    if [[ "$red" == " 161 163 164 166a 166b" ]]; then
        inj_ok "18. 拿掉 wake 的篩選 → 16.1/16.3/16.4/16.6a/16.6b 紅、16.2 仍綠——篩選是這些斷言的唯一支點"
    else
        inj_bad "18. 拿掉篩選後紅的不是那五條 ($LAST_GOT)——harness 問題"
    fi
fi

INJQ="$SANDBOX/mutant-wol-noordinal.sh"
python3 - "$MLP" "$INJQ" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '            printf \'  %s (%d/%d): skipped \u2014 %s\\n\' "$sender" "$i" "$total" "${skip_reasons[${#skip_reasons[@]}-1]}"\n'
new = '            printf \'  %s: skipped \u2014 %s\\n\' "$sender" "${skip_reasons[${#skip_reasons[@]}-1]}"\n'
assert src.count(old) == 1, "ordinal needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if inj_gate 19 "$INJQ"; then
    red=""
    chk_161 "$INJQ" || red="${red} 161"
    chk_164 "$INJQ" || red="${red} 164"
    others=1
    chk_162 "$INJQ" || others=0
    chk_163 "$INJQ" || others=0
    chk_166a "$INJQ" || others=0
    LAST_GOT="紅的 case:${red:-<無>}；其餘綠=$others"
    if [[ "$red" == " 161 164" ]] && [[ "$others" -eq 1 ]]; then
        inj_ok "19. 拿掉序號後 16.1／16.4 紅 ($LAST_GOT)——序號斷言有牙"
    else
        inj_bad "19. 拿掉序號後紅的不是 161+164 ($LAST_GOT)——harness 問題"
    fi
fi

# 20：把「不知道」當成「可以」，是這個 repo 反覆在守的方向錯誤。
INJR="$SANDBOX/mutant-wol-readok.sh"
python3 - "$MLP" "$INJR" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '        if [[ "$wst" -ne 0 ]]; then\n'
new = '        if [[ "$wst" -eq 1 ]]; then\n'
assert src.count(old) == 1, "readok needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if inj_gate 20 "$INJR"; then
    if chk_164 "$INJR"; then
        inj_bad "20. 讀不到當成有資格後 16.4 仍綠——『讀不到 ≠ 有資格』沒被量到"
    else
        if chk_161 "$INJR" && chk_163 "$INJR"; then
            inj_ok "20. 讀不到當成有資格後 16.4 紅（ghost 收到封包）、16.1／16.3 仍綠——16.4 有牙"
        else
            inj_bad "20. 紅的不只 16.4——harness 問題"
        fi
    fi
fi

INJS="$SANDBOX/mutant-wol-reversed.sh"
python3 - "$MLP" "$INJS" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    for sender in "${WAKE_SENDERS[@]}"; do\n'
       '        i=$((i + 1))\n')
new = ('    local ri\n'
       '    for (( ri=${#WAKE_SENDERS[@]}-1; ri>=0; ri-- )); do\n'
       '        sender="${WAKE_SENDERS[$ri]}"\n'
       '        i=$((i + 1))\n')
assert src.count(old) == 1, "reversed needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if inj_gate 21 "$INJS"; then
    red=""
    chk_162 "$INJS" || red="${red} 162"
    order_seen="$(d6_order)"
    LAST_GOT="紅的 case:${red:-<無>}；實際送出順序=[$order_seen]"
    if [[ "$red" == " 162" ]] && [[ "$order_seen" == "alpha bravo " ]]; then
        inj_ok "21. 順序弄反後 16.2 紅且實際先送 alpha ($LAST_GOT)——via 順序有牙"
    else
        inj_bad "21. 順序弄反後 16.2 沒紅或順序沒反 ($LAST_GOT)——harness 問題"
    fi
fi

INJT="$SANDBOX/mutant-no-via-wol-report.sh"
python3 - "$MLP" "$INJT" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    # D6: which of this node\'s via senders cannot be used \u2014 same declaration\n'
       '    # check wake uses, so the two can\'t disagree.\n'
       '    local s wst\n'
       '    while IFS= read -r s; do\n'
       '        [[ -n "$s" ]] || continue\n'
       '        node_wol_state "$s"; wst=$?\n'
       '        [[ "$wst" -eq 0 ]] && continue\n'
       '        if [[ "$wst" -eq 2 ]]; then\n'
       '            printf \'  %-14s %-14s %s\\n\' "via:$s" "${C_YELLOW}unverifiable${C_RESET}" \\\n'
       '                "cannot read its declaration \u2014 not usable as a wol sender"\n'
       '        else\n'
       '            printf \'  %-14s %-14s %s\\n\' "via:$s" "${C_YELLOW}unverifiable${C_RESET}" \\\n'
       '                "does not declare wol \u2014 mlp wake will skip it"\n'
       '        fi\n'
       '    done < <(wake_sender_names "$json")\n')
assert src.count(old) == 1, "via-report needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, '', 1))
PY
if inj_gate 23 "$INJT"; then
    # chk_* 回 0 = 斷言成立（綠）。拿掉回報之後它們必須變成紅（回非 0）。
    if ! chk_165a "$INJT" && ! chk_165b "$INJT"; then
        inj_ok "23. 拿掉 verify 的 via 回報 → 16.5a/16.5b 紅——回報這兩條斷言的唯一支點就是它"
    else
        inj_bad "23. 拿掉 via 回報後斷言仍綠 ($LAST_GOT)——harness 問題"
    fi
fi

INJU="$SANDBOX/mutant-via-firstonly.sh"
python3 - "$MLP" "$INJU" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '    done < <(wake_sender_names "$json")\n'
new = '    done < <(wake_sender_names "$json" | head -1)\n'
assert src.count(old) == 1, "firstonly needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if inj_gate 24 "$INJU"; then
    if chk_165b "$INJU"; then
        inj_bad "24. 固定回報第一台後 16.5b 仍綠——照宣告回報沒被量到"
    else
        if chk_165a "$INJU"; then
            inj_ok "24. 固定回報第一台後 16.5b 紅、16.5a 仍綠——回報確實照宣告"
        else
            inj_bad "24. 紅的不只 16.5b——harness 問題"
        fi
    fi
fi

# 25：錨點用 regex，impl 改措辭就不必重錨；形狀真的變了會報 harness 問題，不會默默通過。
INJV="$SANDBOX/mutant-overclaim-heading.sh"
python3 - "$MLP" "$INJV" <<'PY'
import re
import sys
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r'^[ \t]*echo "could not wake \$\{node\}[^"]*"$', re.M)
new, n = pat.subn('        echo "could not wake ${node} \u2014 every sender failed:"', src)
assert n >= 1, "overclaim-heading regex matched 0 times (shape changed?)"
open(sys.argv[2], "w", encoding="utf-8").write(new)
PY
if inj_gate 25 "$INJV"; then
    if chk_167 "$INJV"; then
        inj_bad "25. 把結語寫回 over-claim 版後 16.7 仍綠——『不得宣稱沒試過的代送方失敗』沒被量到"
    else
        got167="$LAST_GOT"          # 先留份證據：下面的迴圈會覆寫 LAST_GOT
        why167="$LAST_WHY"
        others=1
        for c in 161 163 164 166a 166b; do
            fn="chk_${c}"
            "$fn" "$INJV" || others=0
        done
        LAST_GOT="${got167}｜紅的子句=[${why167}]｜其餘仍綠=$others"
        # 紅的子句必須是 heading：這個突變只動 stdout 的標題，die 那行沒碰。
        if [[ "$others" -eq 1 && "$why167" == " heading" ]]; then
            inj_ok "25. 結語寫回 over-claim 版後 16.7 紅在 heading 子句、其餘仍綠 ($LAST_GOT)"
        else
            inj_bad "25. 紅的子句不是 heading（或連帶壞到別條）($LAST_GOT)——harness 問題"
        fi
    fi
fi

# 26. die 訊息改回用 `total`（`all 2 wake sender(s) failed`，實際只試了 1 台）
# 26：專抓 stdout 對、stderr 抵消掉的情況。錨在變數（attempted→total），分支怎麼寫都不受影響。
INJW="$SANDBOX/mutant-die-total.sh"
python3 - "$MLP" "$INJW" <<'PY'
import re
import sys
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r'^([ \t]*die "all )\$\{attempted\}', re.M)
new, n = pat.subn(r'\1${total}', src)
assert n >= 1, "die-total regex matched 0 times (shape changed?)"
open(sys.argv[2], "w", encoding="utf-8").write(new)
PY
if inj_gate 26 "$INJW"; then
    if chk_167 "$INJW"; then
        inj_bad "26. die 訊息寫回 all 2 … failed 後 16.7 仍綠——stderr 的 over-claim 沒被量到"
    else
        got167="$LAST_GOT"
        why167="$LAST_WHY"
        others=1
        for c in 161 163 164 166a 166b; do
            fn="chk_${c}"
            "$fn" "$INJW" || others=0
        done
        LAST_GOT="${got167}｜紅的子句=[${why167}]｜其餘仍綠=$others"
        # 紅的子句必須只有 die 那兩個：stdout 標題這個突變沒碰，必須仍然綠。
        case "$why167" in
            " die-all2"|" die-count"|" die-all2 die-count"|" die-count die-all2")
                if [[ "$others" -eq 1 ]]; then
                    inj_ok "26. die 訊息寫回 all 2 … failed 後 16.7 紅在 die 子句、heading 仍綠 ($LAST_GOT)"
                else
                    inj_bad "26. 紅的子句是對的但連帶壞到別條 ($LAST_GOT)——harness 問題"
                fi ;;
            *) inj_bad "26. 紅的子句不是 die 那兩個 (got [$why167])——harness 問題" ;;
        esac
    fi
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
