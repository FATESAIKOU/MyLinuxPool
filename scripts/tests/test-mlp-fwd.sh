#!/usr/bin/env bash
# test-mlp-fwd.sh — fwd（本機暫時轉發）的人造故障護欄。
#
# 在防什麼（每條都是一次真實踩過的坑）：
#   隧道看起來還在、實際早斷了：健康檢測若只問本機那個 master 進程，封包
#   從來沒出網路，線斷了照樣回 OK。護欄要求隧道的 verdict 必須來自一次真的
#   遠端命令往返；換成只問本機的寫法時，「斷線仍回報可用」的斷言必須轉紅。
#   目標分類要看結束碼加 stderr：只看結束碼時，「主機不存在」與「主機在、
#   沒服務」都回 rc=1，前者（No route）卻被誤報成後者（refused），違背
#   「refused 證明封包到達了主機」的承諾。新契約分四態：open、inconclusive
#   （我不知道）、refused（主機在沒服務，仍算健康）、unreachable
#   （我知道到不了，不算健康）。
#   stub 必須忠實：真實 refused 會在 stderr 留字；stub 若只回結束碼，
#   分類測到的就是假東西。這次是被四態契約逼出來才發現的落差。
#   ls 顏色跑版：先上色再墊空白會讓 TTY 欄位錯位，而管線驗證看不見
#   （printf 把跳脫位元組也算進寬度）。護欄比的是「剝掉 ANSI 後，
#   有色與無色兩種輸出的各欄起始位置完全相同」；顏色用變數強制，
#   不走 pty（source 加重定向會熄掉 -t，自建 pty 又有前導雜訊）。
#   同埠重疊五格（PM 第二版規則）：同 bind 擋、活萬用雙向擋、兩異具體放行、
#   死檔清掉放行。第一版「同埠一律擋」是錯的，沒護欄會被改回去。
#   rm 多筆拒絕：裸埠撞多筆絕不靜默挑一條；rm 吃 bind:port（含 IPv6 冒號切分）。
#   主選單三入口：fwd-add/fwd-ls/fwd-rm。
#   第三方目標靜默退回節點自己：spec 裡的第三方主機若被解析丟掉，流量會去
#   錯誤的地方還顯示成功。這是最危險的一類：看起來全綠，實際打錯目標。
#   分層腐爛：Model 回傳資料不印字、ViewModel 決策不印字不挑選。混在一起
#   就測不動，改一個地方壞三個地方。
#   啟動選項沒送出去：起轉發時 -L 若沒拼進 ssh 的參數，轉發靜默不存在，
#   之後的健康檢測只是在測一條不存在的隧道。
#   解析入口失敗炸掉行程：fwd_add 經共用解析拿 Gateway，它失敗時原本直接
#   die，於是 fwd_add 的 resolve 分支是走不到的死碼，stderr 還被弄髒。
#   護欄要求 ViewModel 活著回來（回 3、零輸出），而裸呼叫照舊 die。
#   靜態分層會同盲：grep 圖案漏了某種輸出原語就與實作一起瞎掉，所以另有
#   動態分層——七個函式成功與失敗路徑實際執行，stdout/stderr 都必須 0 位元組。
#
# ---- 17b：跨渲染比對的斷言曾經把即時測量值放進比對範圍 --------------------
#
# **教訓（這是這一條存在的理由）：一個比較兩次獨立渲染的斷言，不可以讓非決定性
# 的值進入比對範圍。否則它的綠只代表那兩次剛好一樣。**
#
# 17b 原本把「無色渲染」與「剝掉 ANSI 的有色渲染」整份逐位元組 cmp。而這張表的最後
# 一欄是 RTT = FWD_PROBE_RTT = `now_ms - start_ms`（ops-scripts/mlp 的
# fwd_probe），**每渲染一次就重新量一次**。兩次渲染的量測值不同時，cmp 會紅，
# 而那一列的欄位起點完全沒動——那種紅把「量測值變了」講成「上色破壞了對齊」，
# 方向剛好相反：它會讓人去查對齊，而真正的問題是斷言比了不該比的东西。
#
# 修法不是把量測值從輸出移走（那會動到被測物），而是**把判準改成它要量的東西**：
# 上色不該改變的是「欄位幾何」，不是「每個 byte」。新的 17b 比：
#   * 標題列（完全沒有量測值）逐位元組；
#   * 每個資料列的 TUNNEL 欄與最後一欄的**起始偏移**。
# 欄位的值可以變，起點不能變。17c 是同一個形狀的**行內**版本（同一份渲染裡三列
# 之間），17b 是**跨渲染**版本；兩者都免疫於量測值。EQ_BYTES 仍然算，但只當
# 診斷資訊印出來，不再是判準。
#
# 兩個注入一起釘住「修法沒有只是把紅燈關掉」：
#   * 注入 22（先上色後墊空白 → 有色版欄位左移）：**17b 的欄位幾何紅**
#     （實測 GA 的 70→69、87→86）。對齊壞掉仍然被抓到。
#     注意這一條原本查的是 color_cmp 的整份 cmp——17b 的判準換成欄位幾何之後，
#     用 color_cmp 查等於替一個沒被改到的判準背書。用錯工具的注入比沒有注入更
#     糟：它會讓人以為覆蓋到位。
#   * 注入 27（兩次渲染的 RTT 不同）：**17b 仍綠**。非對齊的量測值變化不再造成紅。
#
# ---- 兩個平台走不同的 RTT 路徑：注入 27 為什麼兩行都要 patch ---------------
#
# qa 的判斷是「macOS 綠是因為兩次測量剛好相同」。實測之後：**兩次根本都沒有測
# 量**。fwd_probe 用 `python3 -c 'import time;print(int(time.time()*1000))'` 取時
# 間戳；在这个 harness 的環境裡 `command -v python3` **找得到**
# （本機是 asdf shim），但那支 python3 **回空字串**，於是 start_ms/now_ms 空 →
# `if [[ -n "$start_ms" && -n "$now_ms" ]]` 不成立 → 走 else → RTT 恆為字面 0。
# 實測三次渲染的 RTT 欄都是 `0ms`。
#
# 也就是說：**這個 harness 裡** RTT 欄是結構性確定的 0，17b 的綠與「兩次測量
# 相同」無關。但 CI runner（Linux，python3 真的會跑）走的是**另一條**——真量測行
# `FWD_PROBE_RTT="$(( now_ms - start_ms ))"`，RTT 是毫秒抖動。同一條注入如果只
# patch fallback 行，在 Linux 上是**惰性的**（計數檔空），「兩次渲染不同」只剩
# 抖動在撐；兩次剛好量到同一組值時 27 自己 `inj_bad`。**CI 兩次紅
# （306a9b8、0137929 的 `injection-fail 1`）就是這個**，根因診斷見
# `OUT-mlpfwd-flake.md`。所以：
#   * 別把 17b 當成「在 macOS 上是穩定的」——它只是**在這個環境裡**穩定；
#   * 注入 27 **兩條路徑都 patch**（真量測行與 fallback 行），讓「兩次渲染必
#     不同」在任何 python3 行為下都決定性成立。只 patch 一條 = 換一個平台就
#     變惰性注入。
#
# 為什麼不用真實網路：ssh、ps、解析與 gh 全部用 PATH 上的 stub 蓋掉，
#   stub 只記 argv 與回放罐頭答案，不連任何東西。寫法沿用
#   test-client-identity.sh 把 argv 記到檔案的那一套。
#
# 注入（每條都先證明會紅，見檔尾注入各節；新五題各附突變版 bash -n、
#  needle 命中數與實際 got 值）：
#   每一條注入都是把對應修正拿掉後的形狀，跑同一個斷言，確認它真的轉紅。
#   沒先證明會紅的護欄等於沒有護欄。
#
# 相容：刻意只用 bash 3.2 就有的語法（無 nameref、無大小寫轉換、
#   空陣列在 set -u 下不直接展開），新舊 bash 都能跑。
#
# Run: scripts/tests/test-mlp-fwd.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

MLP="ops-scripts/mlp"
SSH_LIB="scripts/lib/ssh.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required but not found on PATH" >&2
    exit 1
fi
if [[ ! -f "$MLP" ]]; then
    echo "test-mlp-fwd: ${MLP} is missing; every case below will FAIL" >&2
fi
if [[ ! -f "$SSH_LIB" ]]; then
    echo "test-mlp-fwd: ${SSH_LIB} is missing; every case below will FAIL" >&2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-mlp-fwd.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/shims" "$SANDBOX/home" "$SANDBOX/fwdstate"

pass=0; fail=0; injfail=0; injpass=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- stubs：全部離線，只記 argv 與回放罐頭答案 ---------------------------
# ssh：argv 一行一個記進 ARGV_LOG，再加一行 CALL-EOL 分隔每一次呼叫。
#   回放規則（順序即優先順序）：
#   -O check neonatal：永遠回 0。本機 master 進程就是這樣回答的——線斷了
#   也說 OK，注入 1 就靠這個行為讓假陽現形。
#   遠端 ledger 查詢：回放 FAKE_WORKERS_FILE 的內容。
#   遠端 TCP 探測字串：以 FAKE_TARGET_RC 離開，並把 FAKE_TARGET_ERR 印到
#   stderr——真實世界長這樣：refused 會留 "Connection refused"，沒路由會留
#   "No route to host"。stub 若只回結束碼不吐字，分類測到的就是假東西
#   （四態契約就是被這種落差逼出來的）。四情境：
#   RC=0 → open；RC=124 → inconclusive；RC=1＋refused 字 → refused；
#   RC=1＋其他字 → unreachable。
#   -O exit：永遠回 0。
#   啟動標記：以 FAKE_START_RC 離開。
#   REPAIR-SCAN-L 在 argv 裡：repair 掃描那一條遠端命令，回放
#     FAKE_REPAIR_SCAN_FILE，並在 SCAN_LOG 記一筆。
#     位置有講究：這條 pattern 與其他都不重疋，但**不能**插到啟動標記或
#     -M 那條之前——第一版探針就是把 -M 提到啟動標記前面，結果搶走
#     fwd_add 的啟動呼叫（OUT-recon-fwd.md §5 的坑）。放在 pool-port-alloc
#     之後、啟動標記之前，兩邊都不動。
#   -M 獨立出現：open_gateway_master 的建連，回 0（由 FAKE_MASTER_RC 控制）。
#   placeholder 加 true：隧道探測，以 FAKE_TUNNEL_RC 離開。
cat > "$SANDBOX/shims/ssh" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a" >> "${ARGV_LOG:-/dev/null}"; done
printf 'CALL-EOL\n' >> "${ARGV_LOG:-/dev/null}"
joined="$*"
case "$joined" in
  *"-O check"*) exit 0 ;;
esac
case "$joined" in
  *"pool-port-alloc"*) cat "${FAKE_WORKERS_FILE:-/dev/null}" 2>/dev/null; exit 0 ;;
esac
case "$joined" in
  *"REPAIR-SCAN-L"*)
    printf 'SCAN\n' >> "${SCAN_LOG:-/dev/null}"
    cat "${FAKE_REPAIR_SCAN_FILE:-/dev/null}" 2>/dev/null
    exit 0
    ;;
esac
case "$joined" in
  *"timeout 3 bash"*) printf '%s' "${FAKE_TARGET_ERR:-}" >&2; exit "${FAKE_TARGET_RC:-0}" ;;
esac
case "$joined" in
  *"-O exit"*) exit 0 ;;
esac
case "$joined" in
  *"mlp-fwd-node="*) exit "${FAKE_START_RC:-0}" ;;
esac
case "$joined" in
  *"-M "*) exit "${FAKE_MASTER_RC:-0}" ;;
esac
case "$joined" in
  *placeholder*true*) exit "${FAKE_TUNNEL_RC:-0}" ;;
esac
exit 0
FAKE
# ps：只回放 FAKE_PS_FILE，不看真實進程表。
cat > "$SANDBOX/shims/ps" <<'FAKE'
#!/usr/bin/env bash
cat "${FAKE_PS_FILE:-/dev/null}" 2>/dev/null
exit 0
FAKE
# 解析 stub：gateway 回固定答案；其餘名字查 FAKE_NODES_JSON，查無即 exit 1。
# 每次呼叫（含 gateway）都寫一行到 PR_LOG。「fwd ls 不重新解析」那格要
# 數的就是這本帳——沒有它，「0 次」量不出來是不是因為根本沒在數。
cat > "$SANDBOX/shims/pool-resolve" <<'FAKE'
#!/usr/bin/env bash
printf 'PR %s\n' "$*" >> "${PR_LOG:-/dev/null}"
if [[ "${1:-}" == "gateway" ]]; then
  if [[ -n "${FAKE_GW_JSON:-}" ]]; then printf '%s\n' "$FAKE_GW_JSON"; else printf '{"ip":"9.9.9.9","user":"gw","port":22}\n'; fi
  exit "${FAKE_GW_RC:-0}"
fi
node="${1:-}"
if [[ -n "${FAKE_NODES_JSON:-}" ]]; then
  out="$(jq -c --arg n "$node" '.[$n] // empty' "$FAKE_NODES_JSON" 2>/dev/null)"
  if [[ -n "$out" ]]; then printf '%s\n' "$out"; exit 0; fi
fi
exit 1
FAKE
# gh：測試不該走到它，留一個永遠成功的空殼以免誤觸網路。
cat > "$SANDBOX/shims/gh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
# fzf：View 的挑選分支不在本測試範圍，誤觸即大聲失敗而非卡住。
cat > "$SANDBOX/shims/fzf" <<'FAKE'
#!/usr/bin/env bash
echo "test stub: refusing fzf" >&2
exit 255
FAKE
chmod +x "$SANDBOX/shims/ssh" "$SANDBOX/shims/ps" "$SANDBOX/shims/pool-resolve" "$SANDBOX/shims/gh" "$SANDBOX/shims/fzf"

MLP_FILE="$REPO_ROOT/$MLP"
SSH_FILE="$REPO_ROOT/$SSH_LIB"

# ---- 小幫手 ---------------------------------------------------------------
# spec_ok <spec> <bind> <entry> <thost> <tport> <label>
spec_ok() {
    local spec="$1" wb="$2" we="$3" wth="$4" wtp="$5" label="$6" got want
    got="$(SPEC="$spec" MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" \
        HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
        bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; if fwd_parse_spec "$SPEC" >/dev/null 2>&1; then printf "%s|%s|%s|%s" "$FWD_SPEC_BIND" "$FWD_SPEC_ENTRY" "$FWD_SPEC_THOST" "$FWD_SPEC_TPORT"; else printf "REJECT"; fi' 2>&1)"
    want="${wb}|${we}|${wth}|${wtp}"
    if [[ "$got" == "$want" ]]; then
        ok "$label"
    else
        bad "$label (got [$got] want [$want])"
    fi
}
# spec_reject <spec> <label>
spec_reject() {
    local spec="$1" label="$2" got
    got="$(SPEC="$spec" MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" \
        HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
        bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; if fwd_parse_spec "$SPEC" >/dev/null 2>&1; then printf "ACCEPT"; else printf "REJECT"; fi' 2>&1)"
    if [[ "$got" == "REJECT" ]]; then
        ok "$label"
    else
        bad "$label (spec [$spec] 竟然被接受)"
    fi
}
# probe_run：以 env 傳入 PROBE_CTL/THOST/TPORT、FAKE_TUNNEL_RC、
#   FAKE_TARGET_RC/FAKE_TARGET_ERR 與 MLP_FILE/SSH_OVERRIDE，
#   印出 RC/TUNNEL/TARGET/OUTBYTES/ERRBYTES。
probe_run() {
    MLP_FILE="$1" SSH_OVERRIDE="$2" \
    HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        if [[ -n "${SSH_OVERRIDE:-}" && "$SSH_OVERRIDE" != "-" ]]; then source "$SSH_OVERRIDE" >/dev/null 2>&1; fi
        FWD_DIR="$FWD_OVERRIDE"
        out="$TMP_OUT"; err="$TMP_ERR"; : > "$out"; : > "$err"
        if fwd_probe "$PROBE_CTL" "$PROBE_THOST" "$PROBE_TPORT" >"$out" 2>"$err"; then rc=0; else rc=$?; fi
        printf "RC=%s TUNNEL=%s TARGET=%s OUT=%s ERR=%s" "$rc" "$FWD_PROBE_TUNNEL" "$FWD_PROBE_TARGET" "$(wc -c < "$out" | tr -d " ")" "$(wc -c < "$err" | tr -d " ")"
    ' 2>&1
}

echo "=== 0. 先決條件：十個函式都在 ==="
missing=0
for fn in target_resolve fwd_parse_spec fwd_records fwd_probe fwd_add fwd_remove fwd_status fwd_is_wild fwd_split_row fwd_menu_add; do
    if grep -qE "^${fn}\\(\\)" "$MLP"; then
        :
    else
        bad "0. ${fn} 不存在——實作還沒落地？"
        missing=1
    fi
done
if [[ "$missing" -eq 0 ]]; then
    ok "0. 十個函式都在（七舊加 is_wild、split_row、menu_add）"
fi

echo "=== 1. spec 解析（含第三方目標） ==="
spec_ok "8080" "127.0.0.1" "8080" "127.0.0.1" "8080" "1a. 8080 → 節點自己的 8080"
spec_ok "9090:8080" "127.0.0.1" "9090" "127.0.0.1" "8080" "1b. 9090:8080 → 節點自己的 8080"
spec_ok "0.0.0.0:9090:8080" "0.0.0.0" "9090" "127.0.0.1" "8080" "1c. 三段式 bind:entry:tport"
spec_ok "8080:192.168.0.50:80" "127.0.0.1" "8080" "192.168.0.50" "80" "1d. 第三方主機不可靜默退回節點自己"
spec_ok "127.0.0.1:8080:10.0.0.5:443" "127.0.0.1" "8080" "10.0.0.5" "443" "1e. 四段式 bind:entry:thost:tport"
spec_reject "abc" "1f. 非數字拒絕"
spec_reject "0" "1g. 埠 0 拒絕"
spec_reject "99999" "1h. 超出 65535 拒絕"
spec_reject "8080::80" "1i. 空主機拒絕"

echo "=== 2. 健康檢測：隧道要真實封包，目標四態（結束碼加 stderr） ==="
T_PROBE_OUT="$SANDBOX/probe-out"; T_PROBE_ERR="$SANDBOX/probe-err"
: > "$T_PROBE_OUT"; : > "$T_PROBE_ERR"
# 2a：隧道活著、目標有服務 → open，回 0。
: > "$SANDBOX/argv.log"
got="$(MLP_FILE="$MLP_FILE" SSH_OVERRIDE="-" FWD_OVERRIDE="$SANDBOX/fwdstate" TMP_OUT="$T_PROBE_OUT" TMP_ERR="$T_PROBE_ERR" PROBE_CTL="$SANDBOX/fwdstate/ctl-a" PROBE_THOST="10.0.0.5" PROBE_TPORT="443" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=0 probe_run "$MLP_FILE" "-")"
if [[ "$got" == "RC=0 TUNNEL=up TARGET=open OUT=0 ERR=0" ]]; then
    ok "2a. 隧道活著且目標有服務 → up/open，回 0 且 Model 無輸出"
else
    bad "2a. 不對（got [$got]）"
fi
# 2b：隧道活著、遠端 stderr 留 refused 字（RST 回來了）→ refused，健康。
: > "$SANDBOX/argv.log"
got="$(MLP_FILE="$MLP_FILE" SSH_OVERRIDE="-" FWD_OVERRIDE="$SANDBOX/fwdstate" TMP_OUT="$T_PROBE_OUT" TMP_ERR="$T_PROBE_ERR" PROBE_CTL="$SANDBOX/fwdstate/ctl-a" PROBE_THOST="10.0.0.5" PROBE_TPORT="443" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=1 FAKE_TARGET_ERR="bash: connect: Connection refused" probe_run "$MLP_FILE" "-")"
if [[ "$got" == "RC=0 TUNNEL=up TARGET=refused OUT=0 ERR=0" ]]; then
    ok "2b. 目標沒服務（refused，健康）不被誤報成壞掉：TSTATE 為 refused"
else
    bad "2b. 沒服務被誤報成壞掉（got [$got]）"
fi
# 2c：隧道活著、目標逾時 → inconclusive（誠實說分不出）。
: > "$SANDBOX/argv.log"
got="$(MLP_FILE="$MLP_FILE" SSH_OVERRIDE="-" FWD_OVERRIDE="$SANDBOX/fwdstate" TMP_OUT="$T_PROBE_OUT" TMP_ERR="$T_PROBE_ERR" PROBE_CTL="$SANDBOX/fwdstate/ctl-a" PROBE_THOST="10.0.0.5" PROBE_TPORT="443" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=124 probe_run "$MLP_FILE" "-")"
if [[ "$got" == "RC=0 TUNNEL=up TARGET=inconclusive OUT=0 ERR=0" ]]; then
    ok "2c. 目標逾時 → inconclusive（不假裝知道是沒路由還是被擋）"
else
    bad "2c. 不對（got [$got]）"
fi
# 2d：隧道已死 → down/unknown，回非 0，且只打一次（不再測目標）。
: > "$SANDBOX/argv.log"
got="$(MLP_FILE="$MLP_FILE" SSH_OVERRIDE="-" FWD_OVERRIDE="$SANDBOX/fwdstate" TMP_OUT="$T_PROBE_OUT" TMP_ERR="$T_PROBE_ERR" PROBE_CTL="$SANDBOX/fwdstate/ctl-dead" PROBE_THOST="10.0.0.5" PROBE_TPORT="443" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=1 FAKE_TARGET_RC=0 probe_run "$MLP_FILE" "-")"
if [[ "$got" == "RC=1 TUNNEL=down TARGET=unknown OUT=0 ERR=0" ]]; then
    ok "2d. 隧道已死 → down/unknown，回非 0"
else
    bad "2d. 死掉的隧道沒被認出來（got [$got]）"
fi
calls="$(grep -c 'CALL-EOL' "$SANDBOX/argv.log" 2>/dev/null || true)"
if [[ "$calls" == "1" ]]; then
    ok "2e. 隧道已死時只打一次（不再浪費一次目標探測）"
else
    bad "2e. 呼叫次數不對（want 1 got [$calls]）"
fi
# 2f：隧道探測必須是遠端命令往返，不是只問本機 master。
: > "$SANDBOX/argv.log"
MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" TMP_OUT="$T_PROBE_OUT" TMP_ERR="$T_PROBE_ERR" PROBE_CTL="$SANDBOX/fwdstate/ctl-a" PROBE_THOST="10.0.0.5" PROBE_TPORT="443" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=0 HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; fwd_probe "$PROBE_CTL" "$PROBE_THOST" "$PROBE_TPORT" >/dev/null 2>&1' 2>&1
if grep -q -- '-O check' "$SANDBOX/argv.log" 2>/dev/null; then
    bad "2f. 隧道探測走了只問本機的寫法——線斷了它照樣回 OK"
else
    if grep -q 'placeholder' "$SANDBOX/argv.log" 2>/dev/null && grep -qx 'true' "$SANDBOX/argv.log" 2>/dev/null; then
        ok "2f. 隧道探測走遠端命令往返（有真實封包）"
    else
        bad "2f. 找不到遠端命令往返的痕跡"
    fi
fi
# 2g：同樣 rc=1，但遠端 stderr 是沒路由 → unreachable，不算健康。
#   真線實測：沒路由的 rc 與 refused 一字不差，結束碼給不出不同答案。
: > "$SANDBOX/argv.log"
got="$(MLP_FILE="$MLP_FILE" SSH_OVERRIDE="-" FWD_OVERRIDE="$SANDBOX/fwdstate" TMP_OUT="$T_PROBE_OUT" TMP_ERR="$T_PROBE_ERR" PROBE_CTL="$SANDBOX/fwdstate/ctl-a" PROBE_THOST="10.0.0.5" PROBE_TPORT="443" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=1 FAKE_TARGET_ERR="bash: connect: No route to host" probe_run "$MLP_FILE" "-")"
if [[ "$got" == "RC=0 TUNNEL=up TARGET=unreachable OUT=0 ERR=0" ]]; then
    ok "2g. 主機不可達（unreachable，不健康）不再被誤報成到達"
else
    bad "2g. 主機不存在被誤報成到達（got [$got]）"
fi
# 2h：健康語意——open/refused 算健康，inconclusive/unreachable 不算。
#   四情境同一子行程各跑一次，healthy 函式即契約的健康劃分。
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" ARGV_LOG="$SANDBOX/dyn-argv.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; : > "$ARGV_LOG"; healthy() { case "$1" in open|refused) printf 1;; *) printf 0;; esac; }; FAKE_TUNNEL_RC=0; export FAKE_TUNNEL_RC; FAKE_TARGET_RC=0; FAKE_TARGET_ERR=""; export FAKE_TARGET_RC FAKE_TARGET_ERR; fwd_probe "$FWD_OVERRIDE/ctl-h" 10.0.0.5 443 >/dev/null 2>&1; t1="$FWD_PROBE_TARGET"; FAKE_TARGET_RC=1; FAKE_TARGET_ERR="bash: connect: Connection refused"; export FAKE_TARGET_RC FAKE_TARGET_ERR; fwd_probe "$FWD_OVERRIDE/ctl-h" 10.0.0.5 443 >/dev/null 2>&1; t2="$FWD_PROBE_TARGET"; FAKE_TARGET_RC=124; FAKE_TARGET_ERR=""; export FAKE_TARGET_RC FAKE_TARGET_ERR; fwd_probe "$FWD_OVERRIDE/ctl-h" 10.0.0.5 443 >/dev/null 2>&1; t3="$FWD_PROBE_TARGET"; FAKE_TARGET_RC=1; FAKE_TARGET_ERR="bash: connect: No route to host"; export FAKE_TARGET_RC FAKE_TARGET_ERR; fwd_probe "$FWD_OVERRIDE/ctl-h" 10.0.0.5 443 >/dev/null 2>&1; t4="$FWD_PROBE_TARGET"; printf "%s:%s %s:%s %s:%s %s:%s" "$t1" "$(healthy "$t1")" "$t2" "$(healthy "$t2")" "$t3" "$(healthy "$t3")" "$t4" "$(healthy "$t4")"' 2>&1)"
if [[ "$got" == "open:1 refused:1 inconclusive:0 unreachable:0" ]]; then
    ok "2h. 健康劃分：open/refused 健康，inconclusive/unreachable 不健康"
else
    bad "2h. 健康劃分不對（got [$got]）"
fi

echo "=== 3. records：只信 socket 檔加進程表 ==="
rm -rf "$SANDBOX/fwdstate"; mkdir -p "$SANDBOX/fwdstate"
CTL1="$SANDBOX/fwdstate/fwd-127.0.0.1-8080"
CTL2="$SANDBOX/fwdstate/fwd-127.0.0.1-9090"
CTL3="$SANDBOX/fwdstate/fwd-0.0.0.0-9091"
touch "$CTL1" "$CTL2" "$CTL3"
printf ' 1234 ssh -S %s -N -f -L 127.0.0.1:8080:192.168.0.50:80 someone@127.0.0.1 mlp-fwd-node=mynode\n 5678 ssh -S %s -N -f -L 127.0.0.1:9090:127.0.0.1:9090 someone@127.0.0.1 mlp-fwd-node=other\n' "$CTL1" "$CTL2" > "$SANDBOX/ps-live.txt"
: > "$SANDBOX/ps-empty.txt"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" FAKE_PS_FILE="$SANDBOX/ps-live.txt" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; out="$REC_OUT"; : > "$out"; fwd_records >"$out" 2>"$REC_ERR"; rc=$?; printf "RC=%s N=%s OUT=%s ERR=%s\n" "$rc" "${#FWD_RECORDS[@]}" "$(wc -c < "$out" | tr -d " ")" "$(wc -c < "$REC_ERR" | tr -d " ")"; for r in "${FWD_RECORDS[@]}"; do printf "ROW:%s\n" "$r"; done' 2>&1)"
# shellcheck disable=SC2034
REC_OUT="$SANDBOX/rec-out"; REC_ERR="$SANDBOX/rec-err"; : > "$REC_OUT"; : > "$REC_ERR"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" FAKE_PS_FILE="$SANDBOX/ps-live.txt" REC_OUT="$REC_OUT" REC_ERR="$REC_ERR" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; : > "$REC_OUT"; : > "$REC_ERR"; fwd_records >"$REC_OUT" 2>"$REC_ERR"; rc=$?; n="${#FWD_RECORDS[@]}"; printf "RC=%s N=%s OUT=%s ERR=%s\n" "$rc" "$n" "$(wc -c < "$REC_OUT" | tr -d " ")" "$(wc -c < "$REC_ERR" | tr -d " ")"; i=0; while [[ "$i" -lt "$n" ]]; do r=""; eval "r=\"\${FWD_RECORDS[$i]}\""; printf "ROW:%s\n" "$r"; i=$((i+1)); done' 2>&1)"
first="$(printf '%s' "$got" | head -1)"
if [[ "$first" == "RC=0 N=3 OUT=0 ERR=0" ]]; then
    ok "3a. 三個 socket 檔 → 三筆記錄，Model 無輸出"
else
    bad "3a. 不對（got [$first] full [$got]）"
fi
if printf '%s' "$got" | grep -q "ROW:127.0.0.1	8080	mynode	192.168.0.50	80	1234"; then
    ok "3b. 存活轉發解析出 node、第三方目標與 pid"
else
    bad "3b. 存活轉發解析不對（got [$got]）"
fi
if printf '%s' "$got" | grep -q "ROW:0.0.0.0	9091					"; then
    ok "3c. 沒有進程的陳舊檔仍列出（空白 pid/node/target），ls 可顯 down、rm 可清"
else
    bad "3c. 陳舊檔被藏起來了——那會變成第二份說謊的來源（got [$got]）"
fi

echo "=== 4. add：解析、建連、驗證一次走完 ==="
printf '{"mynode":{"name":"mynode","role":"provider","gateway_port":2300,"user":"worker"}}\n' > "$SANDBOX/nodes.json"
: > "$SANDBOX/ps-none.txt"
rm -rf "$SANDBOX/fwdstate"; mkdir -p "$SANDBOX/fwdstate"
: > "$SANDBOX/argv.log"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$SANDBOX/ps-none.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=1 FAKE_TARGET_ERR="bash: connect: Connection refused" FAKE_START_RC=0 ADD_OUT="$SANDBOX/add-out" ADD_ERR="$SANDBOX/add-err" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; : > "$ADD_OUT"; : > "$ADD_ERR"; if fwd_add mynode "8080:192.168.0.50:80" >"$ADD_OUT" 2>"$ADD_ERR"; then rc=0; else rc=$?; fi; printf "RC=%s ERR=%s CTL=%s BIND=%s ENTRY=%s NODE=%s THOST=%s TPORT=%s OUT=%s ERRB=%s" "$rc" "$FWD_ERR" "$FWD_ADD_CTL" "$FWD_ADD_BIND" "$FWD_ADD_ENTRY" "$FWD_ADD_NODE" "$FWD_ADD_THOST" "$FWD_ADD_TPORT" "$(wc -c < "$ADD_OUT" | tr -d " ")" "$(wc -c < "$ADD_ERR" | tr -d " ")"' 2>&1)"
want_ctl="$SANDBOX/fwdstate/fwd-127.0.0.1-8080"
if [[ "$got" == "RC=0 ERR= CTL=${want_ctl} BIND=127.0.0.1 ENTRY=8080 NODE=mynode THOST=192.168.0.50 TPORT=80 OUT=0 ERRB=0" ]]; then
    ok "4a. 第三方轉發一次成功，ViewModel 無輸出"
else
    bad "4a. 不對（got [$got]）"
fi
if grep -qx -- '-L' "$SANDBOX/argv.log" 2>/dev/null && grep -qx '127.0.0.1:8080:192.168.0.50:80' "$SANDBOX/argv.log" 2>/dev/null; then
    ok "4b. -L 真的被送進 ssh argv（第三方目標完整保留）"
else
    bad "4b. -L 沒被送出去——轉發靜默不存在"
fi
# 4c：壞 spec → 2/spec。
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$SANDBOX/ps-none.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=0 FAKE_START_RC=0 ADD_OUT="$SANDBOX/add-out" ADD_ERR="$SANDBOX/add-err" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; if fwd_add mynode "abc" >/dev/null 2>&1; then printf "RC=0"; else printf "RC=%s ERR=%s" "$?" "$FWD_ERR"; fi' 2>&1)"
if [[ "$got" == "RC=2 ERR=spec" ]]; then
    ok "4c. 壞 spec → spec，回 2"
else
    bad "4c. 不對（got [$got]）"
fi
# 4d：同 entryport 活著 → inuse，回 4，不覆蓋。
#   檔必須真的存在：在用檢查是「有檔再看進程表」，檔都不在就直接視為可重試。
touch "$want_ctl"
printf ' 9999 ssh -S %s -N -f -L 127.0.0.1:8080:127.0.0.1:8080 someone@127.0.0.1 mlp-fwd-node=mynode\n' "$want_ctl" > "$SANDBOX/ps-live-one.txt"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$SANDBOX/ps-live-one.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=0 FAKE_START_RC=0 HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; if fwd_add mynode "8080" >/dev/null 2>&1; then printf "RC=0"; else printf "RC=%s ERR=%s" "$?" "$FWD_ERR"; fi' 2>&1)"
if [[ "$got" == "RC=4 ERR=inuse" ]]; then
    ok "4d. 活著的 entryport 拒絕覆蓋（inuse，回 4）"
else
    bad "4d. 不對（got [$got]）"
fi
# 4e：啟動後隧道不應答 → verify，回 6，且 socket 收掉。
rm -rf "$SANDBOX/fwdstate"; mkdir -p "$SANDBOX/fwdstate"
: > "$SANDBOX/argv.log"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$SANDBOX/ps-none.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=1 FAKE_TARGET_RC=0 FAKE_START_RC=0 HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; if fwd_add mynode "8080" >/dev/null 2>&1; then printf "RC=0"; else printf "RC=%s ERR=%s" "$?" "$FWD_ERR"; fi; if [[ -e "$FWD_OVERRIDE/fwd-127.0.0.1-8080" ]]; then printf " LEFTOVER"; else printf " CLEANED"; fi' 2>&1)"
if [[ "$got" == "RC=6 ERR=verify CLEANED" ]]; then
    ok "4e. 啟動後隧道不應答 → verify，回 6 且收掉 socket"
else
    bad "4e. 不對（got [$got]）"
fi

echo "=== 5. remove：只認 entryport，精確比對 ==="
rm -rf "$SANDBOX/fwdstate"; mkdir -p "$SANDBOX/fwdstate"
touch "$SANDBOX/fwdstate/fwd-127.0.0.1-80" "$SANDBOX/fwdstate/fwd-127.0.0.1-8080"
: > "$SANDBOX/argv.log"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" ARGV_LOG="$SANDBOX/argv.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; if fwd_remove 80 >/dev/null 2>&1; then rc=0; else rc=$?; fi; printf "RC=%s ERR=%s RM=%s" "$rc" "$FWD_ERR" "$FWD_RM_CTL"; if [[ -e "$FWD_OVERRIDE/fwd-127.0.0.1-8080" ]]; then printf " KEEP8080"; else printf " LOST8080"; fi; if [[ -e "$FWD_OVERRIDE/fwd-127.0.0.1-80" ]]; then printf " LEFT80"; else printf " GONE80"; fi' 2>&1)"
if [[ "$got" == "RC=0 ERR= RM=$SANDBOX/fwdstate/fwd-127.0.0.1-80 KEEP8080 GONE80" ]]; then
    ok "5a. 刪 80 只刪 80（8080 留著，不是前綴比對）"
else
    bad "5a. 不對（got [$got]）"
fi
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" ARGV_LOG="$SANDBOX/argv.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; if fwd_remove 9999 >/dev/null 2>&1; then printf "RC=0"; else printf "RC=%s ERR=%s" "$?" "$FWD_ERR"; fi' 2>&1)"
if [[ "$got" == "RC=3 ERR=notfound" ]]; then
    ok "5b. 不存在的 entryport → notfound，回 3"
else
    bad "5b. 不對（got [$got]）"
fi
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" ARGV_LOG="$SANDBOX/argv.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; if fwd_remove abc >/dev/null 2>&1; then printf "RC=0"; else printf "RC=%s ERR=%s" "$?" "$FWD_ERR"; fi' 2>&1)"
if [[ "$got" == "RC=2 ERR=spec" ]]; then
    ok "5c. 非數字 entryport → spec，回 2"
else
    bad "5c. 不對（got [$got]）"
fi

echo "=== 6. status：records 逐筆配上 probe ==="
rm -rf "$SANDBOX/fwdstate"; mkdir -p "$SANDBOX/fwdstate"
CTL1="$SANDBOX/fwdstate/fwd-127.0.0.1-8080"
CTL2="$SANDBOX/fwdstate/fwd-127.0.0.1-9090"
touch "$CTL1" "$CTL2"
printf ' 1234 ssh -S %s -N -f -L 127.0.0.1:8080:127.0.0.1:8080 someone@127.0.0.1 mlp-fwd-node=mynode\n' "$CTL1" > "$SANDBOX/ps-half.txt"
: > "$SANDBOX/argv.log"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" FAKE_PS_FILE="$SANDBOX/ps-half.txt" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=0 ST_OUT="$SANDBOX/st-out" ST_ERR="$SANDBOX/st-err" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; : > "$ST_OUT"; : > "$ST_ERR"; fwd_status >"$ST_OUT" 2>"$ST_ERR"; rc=$?; n="${#FWD_STATUS_ROWS[@]}"; printf "RC=%s N=%s OUT=%s ERR=%s\n" "$rc" "$n" "$(wc -c < "$ST_OUT" | tr -d " ")" "$(wc -c < "$ST_ERR" | tr -d " ")"; i=0; while [[ "$i" -lt "$n" ]]; do r=""; eval "r=\"\${FWD_STATUS_ROWS[$i]}\""; printf "SROW:%s\n" "$r"; i=$((i+1)); done' 2>&1)"
if printf '%s' "$got" | head -1 | grep -q 'RC=0 N=2 OUT=0 ERR=0'; then
    ok "6a. 兩筆記錄 → 兩筆狀態，ViewModel 無輸出"
else
    bad "6a. 不對（got [$got]）"
fi
if printf '%s' "$got" | grep -q "SROW:127.0.0.1	8080	mynode	127.0.0.1	8080	1234.*	up	open"; then
    ok "6b. 存活那筆配上 up/open"
else
    bad "6b. 存活那筆狀態不對（got [$got]）"
fi
# 陳舊列釘死全欄：空欄必須留在原位（node/thost/tport/pid 空、ctl 末欄），
# down/unknown 收尾。實作已改走 fwd_split_row 純展開，不再擠欄。
if printf '%s' "$got" | grep -q "SROW:127.0.0.1	9090					${CTL2}	down	unknown	0"; then
    ok "6c. 陳舊那筆空欄歸位、直接 down/unknown"
else
    bad "6c. 陳舊那筆狀態不對（got [$got]）"
fi
# 陳舊那筆不可撥號：存活一筆花 2 次呼叫（隧道加目標），陳舊零次，共 2 次。
calls="$(grep -c 'CALL-EOL' "$SANDBOX/argv.log" 2>/dev/null || true)"
if [[ "$calls" == "2" ]]; then
    ok "6d. 陳舊那筆零撥號（總呼叫數 2，全是存活那筆的）"
else
    bad "6d. 呼叫次數不對（want 2 got [$calls]）——陳舊列該跳過探測"
fi

echo "=== 7. target_resolve：解析與連線共用同一份 ==="
printf '{"gw":{"role":"gateway"},"pn":{"role":"provider","gateway_port":2301,"user":"u1"}}\n' > "$SANDBOX/nodes7.json"
printf '[{"container":"w1","port":2401,"provider":"pn"}]\n' > "$SANDBOX/workers7.json"
# 7a：provider。
got="$(MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_NODES_JSON="$SANDBOX/nodes7.json" FAKE_WORKERS_FILE="$SANDBOX/workers7.json" R_OUT="$SANDBOX/r-out" R_ERR="$SANDBOX/r-err" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test; : > "$R_OUT"; : > "$R_ERR"; if target_resolve pn >"$R_OUT" 2>"$R_ERR"; then rc=0; else rc=$?; fi; printf "RC=%s TYPE=%s USER=%s PORT=%s ERR=%s OUT=%s ERRB=%s" "$rc" "$TARGET_TYPE" "$TARGET_USER" "$TARGET_PORT" "$TARGET_ERR" "$(wc -c < "$R_OUT" | tr -d " ")" "$(wc -c < "$R_ERR" | tr -d " ")"' 2>&1)"
if [[ "$got" == "RC=0 TYPE=provider USER=u1 PORT=2301 ERR= OUT=0 ERRB=0" ]]; then
    ok "7a. provider 解析出 type/user/port，Model 無輸出"
else
    bad "7a. 不對（got [$got]）"
fi
# 7b：gateway。
got="$(MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_NODES_JSON="$SANDBOX/nodes7.json" FAKE_WORKERS_FILE="$SANDBOX/workers7.json" R_OUT="$SANDBOX/r-out" R_ERR="$SANDBOX/r-err" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test; if target_resolve gw >"$R_OUT" 2>"$R_ERR"; then rc=0; else rc=$?; fi; printf "RC=%s TYPE=%s USER=%s PORT=%s ERR=%s" "$rc" "$TARGET_TYPE" "$TARGET_USER" "$TARGET_PORT" "$TARGET_ERR"' 2>&1)"
if [[ "$got" == "RC=0 TYPE=gateway USER=gw PORT=22 ERR=" ]]; then
    ok "7b. gateway 回 gateway 身分"
else
    bad "7b. 不對（got [$got]）"
fi
# 7c：worker（容器名與裸埠兩種寫法）。
got="$(MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_NODES_JSON="$SANDBOX/nodes7.json" FAKE_WORKERS_FILE="$SANDBOX/workers7.json" FAKE_MASTER_RC=0 HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test; if target_resolve w1 >/dev/null 2>&1; then printf "RC=%s TYPE=%s USER=%s PORT=%s" "$?" "$TARGET_TYPE" "$TARGET_USER" "$TARGET_PORT"; else printf "RC=%s ERR=%s" "$?" "$TARGET_ERR"; fi' 2>&1)"
if [[ "$got" == "RC=0 TYPE=worker USER=worker PORT=2401" ]]; then
    ok "7c. worker 容器名解析出 worker 身分"
else
    bad "7c. 不對（got [$got]）"
fi
# 7d：查無 → notfound。
got="$(MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_NODES_JSON="$SANDBOX/nodes7.json" FAKE_WORKERS_FILE="$SANDBOX/workers7.json" FAKE_MASTER_RC=0 HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test; if target_resolve nosuchthing >/dev/null 2>&1; then printf "RC=0"; else printf "RC=%s ERR=%s" "$?" "$TARGET_ERR"; fi' 2>&1)"
if [[ "$got" == "RC=1 ERR=notfound" ]]; then
    ok "7d. 查無 → notfound，回 1"
else
    bad "7d. 不對（got [$got]）"
fi

echo "=== 7e. resolve 失敗：ViewModel 活著回來，裸呼叫照舊炸 ==="
# fwd_add 經共用解析拿 Gateway；它失敗時原本直接 die（exit 1），於是
# fwd_add 的 resolve 分支是走不到的死碼。修法是可選首參：帶了靜默回 1
# 並把訊息放全域，裸呼叫維持 die。以下動態量輸出位元組並確認行程存活——
# 不用 $() 取輸出，那會進 subshell，變數傳不回來。
printf '{"mynode":{"name":"mynode","role":"provider","gateway_port":2300,"user":"worker"}}\n' > "$SANDBOX/nodes.json"
: > "$SANDBOX/ps-none.txt"
rm -rf "$SANDBOX/fwdstate"; mkdir -p "$SANDBOX/fwdstate"
# 7e：gateway 查不到（解析器回非 0）→ 回 3、零輸出、活著回來。
MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$SANDBOX/ps-none.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_GW_RC=1 FAKE_MASTER_RC=0 ADD_OUT="$SANDBOX/add7e-out" ADD_ERR="$SANDBOX/add7e-err" ADD_RES="$SANDBOX/add7e-res" ADD_ALIVE="$SANDBOX/add7e-alive" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; rm -f "$ADD_ALIVE" "$ADD_RES"; : > "$ADD_OUT"; : > "$ADD_ERR"; if fwd_add mynode "8080" >"$ADD_OUT" 2>"$ADD_ERR"; then rc=0; else rc=$?; fi; printf "RC=%s ERR=%s OUT=%s ERRB=%s DETAIL=%s" "$rc" "$FWD_ERR" "$(wc -c < "$ADD_OUT" | tr -d " ")" "$(wc -c < "$ADD_ERR" | tr -d " ")" "$RESOLVE_DETAIL" > "$ADD_RES"; : > "$ADD_ALIVE"' 2>/dev/null
childrc=$?
got="$(cat "$SANDBOX/add7e-res" 2>/dev/null || true)"
if [[ "$childrc" -eq 0 && -f "$SANDBOX/add7e-alive" && "$got" == "RC=3 ERR=resolve OUT=0 ERRB=0 DETAIL=pool-resolve gateway failed (exit 1)" ]]; then
    ok "7e. gateway 查不到 → 回 3、stdout/stderr 皆 0 位元組、活著回來"
else
    bad "7e. 不對（childrc=$childrc alive=$([ -f "$SANDBOX/add7e-alive" ] && printf 1 || printf 0) got [$got]）"
fi
# 7f：第二個 die 點——缺 ip/user → 同樣回 3、零輸出、活著回來。
MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$SANDBOX/ps-none.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_GW_JSON='{"user":"gw","port":22}' FAKE_GW_RC=0 FAKE_MASTER_RC=0 ADD_OUT="$SANDBOX/add7f-out" ADD_ERR="$SANDBOX/add7f-err" ADD_RES="$SANDBOX/add7f-res" ADD_ALIVE="$SANDBOX/add7f-alive" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; rm -f "$ADD_ALIVE" "$ADD_RES"; : > "$ADD_OUT"; : > "$ADD_ERR"; if fwd_add mynode "8080" >"$ADD_OUT" 2>"$ADD_ERR"; then rc=0; else rc=$?; fi; printf "RC=%s ERR=%s OUT=%s ERRB=%s DETAIL=%s" "$rc" "$FWD_ERR" "$(wc -c < "$ADD_OUT" | tr -d " ")" "$(wc -c < "$ADD_ERR" | tr -d " ")" "$RESOLVE_DETAIL" > "$ADD_RES"; : > "$ADD_ALIVE"' 2>/dev/null
childrc=$?
got="$(cat "$SANDBOX/add7f-res" 2>/dev/null || true)"
if [[ "$childrc" -eq 0 && -f "$SANDBOX/add7f-alive" && "$got" == "RC=3 ERR=resolve OUT=0 ERRB=0 DETAIL=NODE_GATEWAY is missing ip/user" ]]; then
    ok "7f. 缺 ip/user → 回 3、stdout/stderr 皆 0 位元組、活著回來"
else
    bad "7f. 不對（childrc=$childrc alive=$([ -f "$SANDBOX/add7f-alive" ] && printf 1 || printf 0) got [$got]）"
fi
# 7g/7h/7i：既有呼叫端不得改變——裸呼叫失敗照舊 die，且 stderr 與
# nodie 路徑的訊息逐字相同（同一全域、同一 die，不依賴 git 歷史）。
# 靜態先錨定訊息鏈：兩處訊息只定義一次，裸路徑經 die 原樣送出。
if grep -qF 'RESOLVE_DETAIL="pool-resolve gateway failed (exit ${rc})"' "$MLP" \
&& grep -qF 'RESOLVE_DETAIL="NODE_GATEWAY is missing ip/user"' "$MLP" \
&& grep -qF '[[ $fatal -eq 1 ]] && die "$RESOLVE_DETAIL"' "$MLP" \
&& grep -qF 'echo "mlp: $*" >&2' "$MLP"; then
    ok "7g. 訊息鏈錨定（兩訊息單一定義，裸路徑經 die 原樣送出）"
else
    bad "7g. 訊息鏈對不上——裸路徑恐已改寫訊息"
fi
detail_e="$(sed 's/^.*DETAIL=//' "$SANDBOX/add7e-res" 2>/dev/null || true)"
detail_f="$(sed 's/^.*DETAIL=//' "$SANDBOX/add7f-res" 2>/dev/null || true)"
MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_GW_RC=1 RG_OUT="$SANDBOX/rg7g-out" RG_ERR="$SANDBOX/rg7g-err" RG_RES="$SANDBOX/rg7g-res" RG_ALIVE="$SANDBOX/rg7g-alive" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; rm -f "$RG_ALIVE" "$RG_RES"; : > "$RG_OUT"; : > "$RG_ERR"; resolve_gateway >"$RG_OUT" 2>"$RG_ERR"; printf "RC=%s" "$?" > "$RG_RES"; : > "$RG_ALIVE"' 2>/dev/null
childrc=$?
rgerr="$(cat "$SANDBOX/rg7g-err" 2>/dev/null || true)"
rgoutbytes="$(wc -c < "$SANDBOX/rg7g-out" 2>/dev/null | tr -d " " || true)"
if [[ "$childrc" -eq 1 && ! -f "$SANDBOX/rg7g-alive" && "$rgoutbytes" == "0" && -n "$detail_e" && "$rgerr" == "mlp: ${detail_e}" && "$rgerr" == "mlp: pool-resolve gateway failed (exit 1)" ]]; then
    ok "7h. 裸呼叫失敗照舊 die（exit 1），stderr 與 nodie 訊息逐字相同"
else
    bad "7h. 不對（childrc=$childrc alive=$([ -f "$SANDBOX/rg7g-alive" ] && printf 1 || printf 0) out=$rgoutbytes err=[$rgerr] detail=[$detail_e]）"
fi
MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_GW_JSON='{"user":"gw","port":22}' FAKE_GW_RC=0 RG_OUT="$SANDBOX/rg7i-out" RG_ERR="$SANDBOX/rg7i-err" RG_RES="$SANDBOX/rg7i-res" RG_ALIVE="$SANDBOX/rg7i-alive" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; rm -f "$RG_ALIVE" "$RG_RES"; : > "$RG_OUT"; : > "$RG_ERR"; resolve_gateway >"$RG_OUT" 2>"$RG_ERR"; printf "RC=%s" "$?" > "$RG_RES"; : > "$RG_ALIVE"' 2>/dev/null
childrc=$?
rgerr="$(cat "$SANDBOX/rg7i-err" 2>/dev/null || true)"
rgoutbytes="$(wc -c < "$SANDBOX/rg7i-out" 2>/dev/null | tr -d " " || true)"
if [[ "$childrc" -eq 1 && ! -f "$SANDBOX/rg7i-alive" && "$rgoutbytes" == "0" && -n "$detail_f" && "$rgerr" == "mlp: ${detail_f}" && "$rgerr" == "mlp: NODE_GATEWAY is missing ip/user" ]]; then
    ok "7i. 裸呼叫缺 ip/user 照舊 die，stderr 與 nodie 訊息逐字相同"
else
    bad "7i. 不對（childrc=$childrc alive=$([ -f "$SANDBOX/rg7i-alive" ] && printf 1 || printf 0) out=$rgoutbytes err=[$rgerr] detail=[$detail_f]）"
fi

echo "=== 8. 分層：Model 與 ViewModel 不印字、不挑選 ==="
# 靜態：九個函式體內不得出現輸出原語與挑選器。註解行先拿掉再掃。
# fwd_is_wild 與 fwd_split_row 是共用底層（純判定／純展開），同樣零輸出。
layer_bad=""
for fn in target_resolve fwd_parse_spec fwd_records fwd_probe fwd_add fwd_remove fwd_status fwd_is_wild fwd_split_row; do
    body="$(awk -v want="$fn" 'BEGIN{infn=0} $0 ~ ("^" want "\\(\\)") {infn=1; next} infn && $0 == "}" {infn=0; next} infn {print}' "$MLP")"
    code="$(printf '%s' "$body" | grep -vE '^[[:space:]]*#')"
    if printf '%s' "$code" | grep -qE '(^|[^A-Za-z0-9_])(printf|echo|fzf)([^A-Za-z0-9_]|$)'; then
        layer_bad="${layer_bad} ${fn}"
    fi
done
if [[ -z "$layer_bad" ]]; then
    ok "8a. 九個 Model、ViewModel 與共用底層函式體內無輸出與挑選（靜態）"
else
    bad "8a. 這些函式印字或挑選：${layer_bad}——違反分層即設計沒落實"
fi
echo "=== 8b. 動態分層：成功與失敗路徑實際執行，皆零輸出 ==="
# 靜態 grep 若漏了某種輸出原語會與實作同盲；這裡每函式各跑成功加失敗
# 兩條路徑，量 stdout/stderr 位元組（O/E）並記回傳碼（R）證明兩條都真跑了。
DYN_O1="$SANDBOX/dyn-o1"; DYN_E1="$SANDBOX/dyn-e1"; DYN_O2="$SANDBOX/dyn-o2"; DYN_E2="$SANDBOX/dyn-e2"
: > "$DYN_O1"; : > "$DYN_E1"; : > "$DYN_O2"; : > "$DYN_E2"
# 8b：target_resolve（provider 成／查無敗）。
got="$(MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_NODES_JSON="$SANDBOX/nodes7.json" FAKE_WORKERS_FILE="$SANDBOX/workers7.json" FAKE_MASTER_RC=0 O1="$DYN_O1" E1="$DYN_E1" O2="$DYN_O2" E2="$DYN_E2" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-dyn; target_resolve pn >"$O1" 2>"$E1"; r1=$?; target_resolve nosuchthing >"$O2" 2>"$E2"; r2=$?; printf "R1=%s O1=%s E1=%s R2=%s O2=%s E2=%s" "$r1" "$(wc -c < "$O1" | tr -d " ")" "$(wc -c < "$E1" | tr -d " ")" "$r2" "$(wc -c < "$O2" | tr -d " ")" "$(wc -c < "$E2" | tr -d " ")"' 2>&1)"
if [[ "$got" == "R1=0 O1=0 E1=0 R2=1 O2=0 E2=0" ]]; then
    ok "8b. target_resolve 成敗兩路皆零輸出"
else
    bad "8b. 不對（got [$got]）"
fi
# 8c：fwd_parse_spec（合法成／非法敗）。
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" O1="$DYN_O1" E1="$DYN_E1" O2="$DYN_O2" E2="$DYN_E2" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; fwd_parse_spec "8080" >"$O1" 2>"$E1"; r1=$?; fwd_parse_spec "abc" >"$O2" 2>"$E2"; r2=$?; printf "R1=%s O1=%s E1=%s R2=%s O2=%s E2=%s" "$r1" "$(wc -c < "$O1" | tr -d " ")" "$(wc -c < "$E1" | tr -d " ")" "$r2" "$(wc -c < "$O2" | tr -d " ")" "$(wc -c < "$E2" | tr -d " ")"' 2>&1)"
if [[ "$got" == "R1=0 O1=0 E1=0 R2=1 O2=0 E2=0" ]]; then
    ok "8c. fwd_parse_spec 成敗兩路皆零輸出"
else
    bad "8c. 不對（got [$got]）"
fi
# 8d：fwd_records（有檔成／無目錄敗路——回 0 但零筆）。
rm -rf "$SANDBOX/dyn-live"; mkdir -p "$SANDBOX/dyn-live"
touch "$SANDBOX/dyn-live/fwd-127.0.0.1-8081"
printf ' 1111 ssh -S %s -N -f -L 127.0.0.1:8081:127.0.0.1:8081 someone@127.0.0.1 mlp-fwd-node=n1\n' "$SANDBOX/dyn-live/fwd-127.0.0.1-8081" > "$SANDBOX/dyn-ps.txt"
got="$(MLP_FILE="$MLP_FILE" D1="$SANDBOX/dyn-live" D2="$SANDBOX/dyn-absent" FAKE_PS_FILE="$SANDBOX/dyn-ps.txt" O1="$DYN_O1" E1="$DYN_E1" O2="$DYN_O2" E2="$DYN_E2" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$D1"; fwd_records >"$O1" 2>"$E1"; r1=$?; n1="${#FWD_RECORDS[@]}"; FWD_DIR="$D2"; fwd_records >"$O2" 2>"$E2"; r2=$?; n2="${#FWD_RECORDS[@]}"; printf "R1=%s N1=%s O1=%s E1=%s R2=%s N2=%s O2=%s E2=%s" "$r1" "$n1" "$(wc -c < "$O1" | tr -d " ")" "$(wc -c < "$E1" | tr -d " ")" "$r2" "$n2" "$(wc -c < "$O2" | tr -d " ")" "$(wc -c < "$E2" | tr -d " ")"' 2>&1)"
if [[ "$got" == "R1=0 N1=1 O1=0 E1=0 R2=0 N2=0 O2=0 E2=0" ]]; then
    ok "8d. fwd_records 有筆與無目錄兩路皆零輸出"
else
    bad "8d. 不對（got [$got]）"
fi
# 8e：fwd_probe（隧道活成／隧道死敗）。
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/fwdstate" ARGV_LOG="$SANDBOX/dyn-argv.log" O1="$DYN_O1" E1="$DYN_E1" O2="$DYN_O2" E2="$DYN_E2" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; : > "$ARGV_LOG"; FAKE_TUNNEL_RC=0; FAKE_TARGET_RC=0; export FAKE_TUNNEL_RC FAKE_TARGET_RC; fwd_probe "$FWD_OVERRIDE/ctl-dyn" 10.0.0.5 443 >"$O1" 2>"$E1"; r1=$?; FAKE_TUNNEL_RC=1; export FAKE_TUNNEL_RC; fwd_probe "$FWD_OVERRIDE/ctl-dyn" 10.0.0.5 443 >"$O2" 2>"$E2"; r2=$?; printf "R1=%s O1=%s E1=%s R2=%s O2=%s E2=%s" "$r1" "$(wc -c < "$O1" | tr -d " ")" "$(wc -c < "$E1" | tr -d " ")" "$r2" "$(wc -c < "$O2" | tr -d " ")" "$(wc -c < "$E2" | tr -d " ")"' 2>&1)"
if [[ "$got" == "R1=0 O1=0 E1=0 R2=1 O2=0 E2=0" ]]; then
    ok "8e. fwd_probe 隧道活死兩路皆零輸出"
else
    bad "8e. 不對（got [$got]）"
fi
# 8f：fwd_add（建連成／壞 spec 敗）。
rm -rf "$SANDBOX/dyn-add"; mkdir -p "$SANDBOX/dyn-add"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/dyn-add" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$SANDBOX/ps-none.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_GW_RC=0 FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=1 FAKE_TARGET_ERR="bash: connect: Connection refused" FAKE_START_RC=0 O1="$DYN_O1" E1="$DYN_E1" O2="$DYN_O2" E2="$DYN_E2" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; fwd_add mynode "8081" >"$O1" 2>"$E1"; r1=$?; fwd_add mynode "abc" >"$O2" 2>"$E2"; r2=$?; printf "R1=%s O1=%s E1=%s R2=%s O2=%s E2=%s" "$r1" "$(wc -c < "$O1" | tr -d " ")" "$(wc -c < "$E1" | tr -d " ")" "$r2" "$(wc -c < "$O2" | tr -d " ")" "$(wc -c < "$E2" | tr -d " ")"' 2>&1)"
if [[ "$got" == "R1=0 O1=0 E1=0 R2=2 O2=0 E2=0" ]]; then
    ok "8f. fwd_add 建連成與壞 spec 敗兩路皆零輸出"
else
    bad "8f. 不對（got [$got]）"
fi
# 8g：fwd_remove（刪得掉成／查無敗）。
rm -rf "$SANDBOX/dyn-rm"; mkdir -p "$SANDBOX/dyn-rm"
touch "$SANDBOX/dyn-rm/fwd-127.0.0.1-7070"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/dyn-rm" ARGV_LOG="$SANDBOX/dyn-argv.log" O1="$DYN_O1" E1="$DYN_E1" O2="$DYN_O2" E2="$DYN_E2" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; : > "$ARGV_LOG"; fwd_remove 7070 >"$O1" 2>"$E1"; r1=$?; fwd_remove 7071 >"$O2" 2>"$E2"; r2=$?; printf "R1=%s O1=%s E1=%s R2=%s O2=%s E2=%s" "$r1" "$(wc -c < "$O1" | tr -d " ")" "$(wc -c < "$E1" | tr -d " ")" "$r2" "$(wc -c < "$O2" | tr -d " ")" "$(wc -c < "$E2" | tr -d " ")"' 2>&1)"
if [[ "$got" == "R1=0 O1=0 E1=0 R2=3 O2=0 E2=0" ]]; then
    ok "8g. fwd_remove 刪得掉與查無兩路皆零輸出"
else
    bad "8g. 不對（got [$got]）"
fi
# 8h：fwd_status（有筆成／空目錄敗路——回 0 但零筆）。
rm -rf "$SANDBOX/dyn-st"; mkdir -p "$SANDBOX/dyn-st" "$SANDBOX/dyn-st-empty"
touch "$SANDBOX/dyn-st/fwd-127.0.0.1-8082"
printf ' 2222 ssh -S %s -N -f -L 127.0.0.1:8082:127.0.0.1:8082 someone@127.0.0.1 mlp-fwd-node=n2\n' "$SANDBOX/dyn-st/fwd-127.0.0.1-8082" > "$SANDBOX/dyn-st-ps.txt"
got="$(MLP_FILE="$MLP_FILE" D1="$SANDBOX/dyn-st" D2="$SANDBOX/dyn-st-empty" FAKE_PS_FILE="$SANDBOX/dyn-st-ps.txt" ARGV_LOG="$SANDBOX/dyn-argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=0 O1="$DYN_O1" E1="$DYN_E1" O2="$DYN_O2" E2="$DYN_E2" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; : > "$ARGV_LOG"; FWD_DIR="$D1"; fwd_status >"$O1" 2>"$E1"; r1=$?; n1="${#FWD_STATUS_ROWS[@]}"; FWD_DIR="$D2"; fwd_status >"$O2" 2>"$E2"; r2=$?; n2="${#FWD_STATUS_ROWS[@]}"; printf "R1=%s N1=%s O1=%s E1=%s R2=%s N2=%s O2=%s E2=%s" "$r1" "$n1" "$(wc -c < "$O1" | tr -d " ")" "$(wc -c < "$E1" | tr -d " ")" "$r2" "$n2" "$(wc -c < "$O2" | tr -d " ")" "$(wc -c < "$E2" | tr -d " ")"' 2>&1)"
if [[ "$got" == "R1=0 N1=1 O1=0 E1=0 R2=0 N2=0 O2=0 E2=0" ]]; then
    ok "8h. fwd_status 有筆與空目錄兩路皆零輸出"
else
    bad "8h. 不對（got [$got]）"
fi

echo "=== 9. 啟動選項真的拼進 ssh ==="
if grep -q 'SSH_EXTRA_OPTS' "$SSH_LIB" && grep -q 'SSH_EXTRA_OPTS' "$MLP"; then
    ok "9a. ssh  helper 與 fwd_add 兩端都提到啟動選項（靜態不斷鏈）"
else
    bad "9a. 啟動選項在兩端對不上——一端改名另一端就靜默失效"
fi
# 行為面已由 4b 覆蓋（argv 裡有 -L）；這裡再確認空選項時與過去逐位元組等價：
# 不設 SSH_EXTRA_OPTS 時呼叫 ssh_via_gateway，argv 裡不得有多餘空參數且能通。
got="$(SSH_FILE="$SSH_FILE" ARGV_LOG="$SANDBOX/argv9.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$SSH_FILE" >/dev/null 2>&1; : > "$ARGV_LOG"; unset SSH_EXTRA_OPTS; ssh_via_gateway /tmp/kh admin gw.example 22 worker 127.0.0.1 2300 true >/dev/null 2>&1; rc=$?; printf "RC=%s EMPTY=%s" "$rc" "$(grep -c "^$" "$ARGV_LOG" 2>/dev/null || true)"' 2>&1)"
if [[ "$got" == "RC=0 EMPTY=0" ]]; then
    ok "9b. 空選項時呼叫仍通且 argv 無空洞（與過去等價）"
else
    bad "9b. 不對（got [$got]）"
fi

echo "=== 17. fwd ls 顏色欄寬（先墊空白再上色） ==="
# TTY 才會跑版，管線驗證看不見：顏色用變數強制，不走 pty。
# source 不可加重定向（會熄掉 -t；反正 $() 內本來就非 TTY，顏色一律手動開）。
# 判準：剝掉 ANSI 後，有色輸出必須與無色輸出逐位元組相同。
rm -rf "$SANDBOX/color-fwd"; mkdir -p "$SANDBOX/color-fwd"
CF1="$SANDBOX/color-fwd/fwd-127.0.0.1-8080"
CF2="$SANDBOX/color-fwd/fwd-0.0.0.0-9090"
CF3="$SANDBOX/color-fwd/fwd-127.0.0.1-7070"
touch "$CF1" "$CF2" "$CF3"
printf ' 111 ssh -S %s -N -f -L 127.0.0.1:8080:192.168.0.136:9999 u@127.0.0.1 mlp-fwd-node=mlp-fh-proxy-default-35521634874\n 222 ssh -S %s -N -f -L 0.0.0.0:9090:127.0.0.1:80 u@127.0.0.1 mlp-fwd-node=n2\n' "$CF1" "$CF2" > "$SANDBOX/color-ps.txt"
# color_case <mlp檔> <結果目錄>：同一夾具跑無色加有色各一次，印位元組數。
color_case() {
    local mf="$1" rd="$2"
    mkdir -p "$rd"
    MLP_FILE="$mf" FWD_OVERRIDE="$SANDBOX/color-fwd" FAKE_PS_FILE="$SANDBOX/color-ps.txt" ARGV_LOG="$SANDBOX/color-argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=1 FAKE_TARGET_ERR="bash: connect: Connection refused" PLAIN="$rd/plain" COLORED="$rd/colored" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" 2>/dev/null
        FWD_DIR="$FWD_OVERRIDE"
        : > "$ARGV_LOG"
        fwd_view_ls >"$PLAIN" 2>"$PLAIN.err"
        esc="$(printf "\033")"
        C_BOLD="${esc}[1m"; C_GREEN="${esc}[32m"; C_RED="${esc}[31m"; C_YELLOW="${esc}[33m"; C_RESET="${esc}[0m"
        fwd_view_ls >"$COLORED" 2>"$COLORED.err"
        printf "POUT=%s PERR=%s COUT=%s CERR=%s" "$(wc -c < "$PLAIN" | tr -d " ")" "$(wc -c < "$PLAIN.err" | tr -d " ")" "$(wc -c < "$COLORED" | tr -d " ")" "$(wc -c < "$COLORED.err" | tr -d " ")"' 2>&1
}
# color_cmp <結果目錄>：剝 ANSI 後比對，印 EQ 與 HAS_COLOR。
color_cmp() {
    local rd="$1" esc res
    esc="$(printf '\033')"
    sed -e "s/${esc}\[[0-9;]*[a-zA-Z]//g" -e "s/${esc}(B//g" "$rd/colored" > "$rd/stripped"
    if cmp -s "$rd/stripped" "$rd/plain"; then res="EQ=1"; else res="EQ=0"; fi
    if grep -q "$esc" "$rd/colored" 2>/dev/null; then res="${res} HAS_COLOR=1"; else res="${res} HAS_COLOR=0"; fi
    printf '%s' "$res"
}
# color_geom <無色檔> <剝色後的有色檔>：比對**欄位幾何**。
#
# 為什麼不比整份位元組：這個表的最後一欄是 FWD_PROBE_RTT，而它是
# `now_ms - start_ms` 的即時測量（ops-scripts/mlp 的 fwd_probe），每渲染一次
# 就重新量一次。17a/17b 各渲染一次，兩次的量測值可能不同（實測本機兩次都是
# 0ms——那是運氣），於是舊的整份 cmp 會在一個數字上紅，而那一列的欄位起點完全
# 沒動。那種紅把「量測值變了」講成「上色破壞了對齊」，方向剛好相反：它會讓人
# 去查對齊，而真正的問題是斷言把非決定性的值放進了比對範圍。
#
# 這裡比的是「上色不該改變的東西」：
#   * 標題列：完全沒有量測值，逐位元組比。
#   * 每個資料列：TUNNEL 欄與最後一欄的起始偏移。
# 欄位的**值**不比——值可以變，起點不能變。17c 是同一個形狀的**行內**版本
# （同一份渲染裡三列之間），17b 是**跨渲染**版本；兩者都免疫於量測值。
color_geom() {
    python3 - "$1" "$2" <<'GEOM_PY'
import re, sys

def load(p):
    return [l.rstrip('\n') for l in open(p, encoding='utf-8')]

def geom(lines):
    out = []
    for l in lines:
        if not l or 'listening' in l:
            continue
        m1 = re.search(r' (up|down)  +', l)
        m2 = re.search(r'\S+\s*$', l)
        out.append((m1.start() if m1 else -1, m2.start() if m2 else -1))
    return out

def header(lines):
    for l in lines:
        if l and 'ENTRY' in l:
            return l
    return None

a, b = load(sys.argv[1]), load(sys.argv[2])
ha, hb = header(a), header(b)
ga, gb = geom(a), geom(b)
eq = 1 if (ha == hb and ga == gb and len(ga) == len(gb) and len(ga) > 0) else 0
print('EQ_GEOM=%d HDR=%s N=%d/%d GA=%s GB=%s'
      % (eq, 'same' if ha == hb else 'diff', len(ga), len(gb), ga, gb))
GEOM_PY
}
got="$(color_case "$MLP_FILE" "$SANDBOX/color-ok")"
cmpgot="$(color_cmp "$SANDBOX/color-ok")"
if printf '%s' "$cmpgot" | grep -q 'HAS_COLOR=1' && [[ "$got" != POUT=0* ]]; then
    ok "17a. 有色輸出真的帶跳脫序列且有列被畫出來（非空跑）"
else
    bad "17a. 顏色沒開起來或輸出為空（got [$got] cmp [$cmpgot]）——後面等於沒測"
fi
# 17b 的判準是「**欄位幾何**」，不是整份逐位元組比對。理由見檔頭：表裡有
# RTT 這個即時測量值，兩次渲染之間它會變，而舊的判準會因此在一個**數字**上紅，
# 與欄位對齊無關。EQ_BYTES 仍然算（當診斷資訊印出來），但它不再是判準。
geom="$(color_geom "$SANDBOX/color-ok/plain" "$SANDBOX/color-ok/stripped")"
if printf '%s' "$geom" | grep -q 'EQ_GEOM=1'; then
    ok "17b. 剝掉 ANSI 後欄位幾何相同（標題列逐位元組＋每列欄位起點）"
else
    bad "17b. 有色版欄位偏移（geom [$geom]）"
    diff "$SANDBOX/color-ok/plain" "$SANDBOX/color-ok/stripped" | head -8
fi
pygot="$(python3 - "$SANDBOX/color-ok/stripped" <<'PY'
import re, sys
lines = [l.rstrip('\n') for l in open(sys.argv[1], encoding='utf-8')]
data = [l for l in lines if l and 'listening' not in l]
hdr, rows = data[0], data[1:]
assert 'ENTRY' in hdr and 'RTT' in hdr, "no header"
def col1(l, pat):
    m = re.search(pat, l)
    return m.start() if m else -1
ts = set(col1(l, r' (up|down)  +') for l in rows)
rs = set(col1(l, r'\S+\s*$') for l in rows)
print('ROWS=%d TUN1=%s RTT1=%s' % (len(rows), len(ts) == 1 and -1 not in ts, len(rs) == 1))
PY
)"
if [[ "$pygot" == "ROWS=3 TUN1=True RTT1=True" ]]; then
    ok "17c. 行內自洽：三列的 TUNNEL 與 RTT 起始欄各相同"
else
    bad "17c. 行內欄位沒對齊（got [$pygot]）"
fi
# 27. **兩次渲染的 RTT 不同 → 17b 必須仍然綠。** 這是「修法沒有只是把紅燈關掉」
#     的另一半證明：22 說明對齊壞掉時仍會紅，這一條說明非對齊的量測值變化不再
#     造成紅。兩者同時成立，17b 才是「只量它要量的東西」。
#
#     **注入點是兩條路徑，不是只有 else 分支那一行。** fwd_probe 的 RTT 有
#     兩條路（ops-scripts/mlp:2077 真量測、:2079 fallback），走哪條取決於
#     `python3 -c 'import time;...'` 是否回得出值：
#       * macOS 本機（asdf shim 回空字串）→ fallback；
#       * CI runner／容器（python3 真的會跑）→ 真量測行。
#     只 patch fallback 的話，在 Linux 上注入是**惰性的**——計數檔空、RTT 是
#     毫秒抖動，「兩次渲染不同」靠運氣；兩次剛好相同時 27 自己 inj_bad，
#     CI 就紅在 harness 缺陷上（OUT-mlpfwd-flake.md 的根因）。
#     兩條都 patch 之後，RTT 一律由計數檔決定（每次探測遞增；同一份渲染的三列
#     是連續值，下一次渲染接著遞增），在任何平台上都決定性不同——這條注入在
#     任何環境都真的在測它宣稱要測的東西。
#
#     路徑在 patch 時內插進注入檔，不靠環境變數傳遞（本條第一版用環境變數，
#     穿過 function + command substitution 之後沒生效，而斷言只報「注入沒讓
#     兩次渲染不同」——至少它沒假綠，但浪費了一輪）。
INJ_RTT="$SANDBOX/mutant-rtt-jitter.sh"
python3 - "$MLP" "$INJ_RTT" "$SANDBOX/rtt-jitter-ctr" <<'RTT_PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
ctr = sys.argv[3]
old_real = '        FWD_PROBE_RTT="$(( now_ms - start_ms ))"\n'
old_fb = '        FWD_PROBE_RTT="0"\n'
new = ('        # INJECTED: 每次探測遞增，讓兩次渲染的 RTT 欄不同\n'
       '        _c=$(cat "' + ctr + '" 2>/dev/null || echo 0)\n'
       '        _c=$((_c + 1)); printf %s "$_c" > "' + ctr + '"\n'
       '        FWD_PROBE_RTT="$_c"\n')
# 兩條路徑都要 assert count==1：形狀若變了，這條注入必須大聲壞掉，
# 而不是靜靜變成惰性注入（那正是這張工單修的形狀）。
assert src.count(old_real) == 1, "rtt-real needle count=%d" % src.count(old_real)
assert src.count(old_fb) == 1, "rtt-fallback needle count=%d" % src.count(old_fb)
src = src.replace(old_real, new, 1).replace(old_fb, new, 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
RTT_PY
if [[ $? -ne 0 ]]; then
    inj_bad "27. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ_RTT" 2>/dev/null; then
    inj_bad "27. 注入版語法錯誤——harness 問題"
else
    : > "$SANDBOX/rtt-jitter-ctr"
    color_case "$INJ_RTT" "$SANDBOX/color-jitter" >/dev/null
    cmpjit="$(color_cmp "$SANDBOX/color-jitter")"
    geomjit="$(color_geom "$SANDBOX/color-jitter/plain" "$SANDBOX/color-jitter/stripped")"
    # 先確認這個注入**真的**讓兩次渲染的 RTT 不同，否則這一條什麼都沒測
    if cmp -s "$SANDBOX/color-jitter/plain" "$SANDBOX/color-jitter/stripped"; then
        inj_bad "27. 注入沒有讓兩次渲染的 RTT 不同（cmp [$cmpjit]）——這一條等於沒測"
    elif printf '%s' "$geomjit" | grep -q 'EQ_GEOM=1'; then
        inj_ok "27. 兩次渲染的 RTT 不同（cmp [$cmpjit]）而 17b 仍綠（geom [$geomjit]）——量測值不再混進對齊判準"
    else
        inj_bad "27. RTT 不同時 17b 變紅（geom [$geomjit]）——欄位幾何判準抓到了不該抓的東西"
    fi
fi

echo "=== 18. fwd_add 重疊規則五格（PM 第二版） ==="
# 同 bind 同埠擋／活萬用雙向擋／兩異具體放行／死檔清掉放行。
# 第一版「同埠一律擋」是錯的：127.0.0.1 與 192.168.0.224 同埠是合法並存。
printf '{"mynode":{"name":"mynode","role":"provider","gateway_port":2300,"user":"worker"}}\n' > "$SANDBOX/nodes.json"
MC_DIR="$SANDBOX/mc"; MC_PS="$SANDBOX/mc-ps.txt"; MC_O="$SANDBOX/mc-out"; MC_E="$SANDBOX/mc-err"
# mc_live/mc_dead <檔名>：同埠現有檔，活（進程表有 -S）或死。
mc_live() {
    rm -rf "$MC_DIR"; mkdir -p "$MC_DIR"
    touch "$MC_DIR/$1"
    printf ' 1234 ssh -S %s -N -f -L x someone@127.0.0.1 mlp-fwd-node=mynode\n' "$MC_DIR/$1" > "$MC_PS"
}
mc_dead() {
    rm -rf "$MC_DIR"; mkdir -p "$MC_DIR"
    touch "$MC_DIR/$1"
    : > "$MC_PS"
}
# add_cell <mlp檔> <spec> <want_rc> <want_err> <want_clash> <標籤>
add_cell() {
    local mf="$1" spec="$2" wrc="$3" werr="$4" wclash="$5" label="$6" got want
    got="$(MLP_FILE="$mf" SPEC="$spec" FWD_OVERRIDE="$MC_DIR" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$MC_PS" FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_GW_RC=0 FAKE_START_RC=0 FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=0 ARGV_LOG="$SANDBOX/mc-argv.log" OUTF="$MC_O" ERRF="$MC_E" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; : > "$ARGV_LOG"; : > "$OUTF"; : > "$ERRF"; if fwd_add mynode "$SPEC" >"$OUTF" 2>"$ERRF"; then rc=0; else rc=$?; fi; printf "RC=%s ERR=%s CLASH=%s OUT=%s ERRB=%s" "$rc" "$FWD_ERR" "$FWD_CLASH" "$(wc -c < "$OUTF" | tr -d " ")" "$(wc -c < "$ERRF" | tr -d " ")"' 2>&1)"
    want="RC=${wrc} ERR=${werr} CLASH=${wclash} OUT=0 ERRB=0"
    if [[ "$got" == "$want" ]]; then
        ok "$label"
    else
        bad "$label (got [$got] want [$want])"
    fi
}
mc_live "fwd-127.0.0.1-2222"
add_cell "$MLP_FILE" "2222" 4 "inuse" "127.0.0.1:2222" "18a. 同 bind 同埠活著 → inuse 並指名對手"
mc_live "fwd-0.0.0.0-2222"
add_cell "$MLP_FILE" "2222" 4 "inuse" "0.0.0.0:2222" "18b. 活萬用擋具體 → inuse"
mc_live "fwd-127.0.0.1-2222"
add_cell "$MLP_FILE" "0.0.0.0:2222:22" 4 "inuse" "127.0.0.1:2222" "18c. 活具體擋萬用 → inuse"
mc_live "fwd-127.0.0.1-2222"
add_cell "$MLP_FILE" "192.168.0.224:2222:22" 0 "" "" "18d. 兩異具體同埠 → 放行並存"
if [[ -e "$MC_DIR/fwd-127.0.0.1-2222" ]]; then
    ok "18d2. 放行沒動到原檔"
else
    bad "18d2. 原檔被動到了"
fi
mc_dead "fwd-127.0.0.1-2222"
add_cell "$MLP_FILE" "2222" 0 "" "" "18e. 同埠只有死檔 → 清掉後放行"
if [[ ! -e "$MC_DIR/fwd-127.0.0.1-2222" ]]; then
    ok "18e2. 死檔已被清掉（可重試）"
else
    bad "18e2. 死檔還在"
fi

echo "=== 19. fwd_remove 裸埠撞多筆 → 拒絕 ==="
rm -rf "$SANDBOX/rm-amb"; mkdir -p "$SANDBOX/rm-amb"
touch "$SANDBOX/rm-amb/fwd-127.0.0.1-2222" "$SANDBOX/rm-amb/fwd-0.0.0.0-2222" "$SANDBOX/rm-amb/fwd-127.0.0.1-3333"
: > "$SANDBOX/argv.log"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/rm-amb" ARGV_LOG="$SANDBOX/argv.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; if fwd_remove 2222 >/dev/null 2>&1; then printf "RC=0"; else printf "RC=%s ERR=%s\nCANDS:\n%s" "$?" "$FWD_ERR" "$FWD_RM_CANDS"; fi' 2>&1)"
if printf '%s' "$got" | head -1 | grep -q 'RC=4 ERR=ambiguous' \
&& printf '%s' "$got" | grep -q '0.0.0.0:2222' \
&& printf '%s' "$got" | grep -q '127.0.0.1:2222' \
&& [[ -e "$SANDBOX/rm-amb/fwd-127.0.0.1-2222" && -e "$SANDBOX/rm-amb/fwd-0.0.0.0-2222" && -e "$SANDBOX/rm-amb/fwd-127.0.0.1-3333" ]]; then
    ok "19a. 裸埠撞兩筆 → ambiguous/4、列出候選、一條都沒刪（含他埠未動）"
else
    bad "19a. 不對（got [$got]）"
fi

echo "=== 20. fwd_remove 吃 bind:port（含 IPv6） ==="
rm -rf "$SANDBOX/rm-bind"; mkdir -p "$SANDBOX/rm-bind"
touch "$SANDBOX/rm-bind/fwd-0.0.0.0-2222" "$SANDBOX/rm-bind/fwd-127.0.0.1-2222"
: > "$SANDBOX/argv.log"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/rm-bind" ARGV_LOG="$SANDBOX/argv.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; if fwd_remove "0.0.0.0:2222" >/dev/null 2>&1; then printf "RC=0 RM=%s" "$FWD_RM_CTL"; else printf "RC=%s ERR=%s" "$?" "$FWD_ERR"; fi; if [[ -e "$FWD_OVERRIDE/fwd-127.0.0.1-2222" ]]; then printf " KEEP"; else printf " LOST"; fi' 2>&1)"
if [[ "$got" == "RC=0 RM=$SANDBOX/rm-bind/fwd-0.0.0.0-2222 KEEP" ]]; then
    ok "20a. bind:port 精準命中，只刪那一條"
else
    bad "20a. 不對（got [$got]）"
fi
rm -rf "$SANDBOX/rm-v6"; mkdir -p "$SANDBOX/rm-v6"
touch "$SANDBOX/rm-v6/fwd-::-2443" "$SANDBOX/rm-v6/fwd-127.0.0.1-2443"
got="$(MLP_FILE="$MLP_FILE" FWD_OVERRIDE="$SANDBOX/rm-v6" ARGV_LOG="$SANDBOX/argv.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; if fwd_remove ":::2443" >/dev/null 2>&1; then printf "RC=0 RM=%s" "$FWD_RM_CTL"; else printf "RC=%s ERR=%s" "$?" "$FWD_ERR"; fi; if [[ -e "$FWD_OVERRIDE/fwd-127.0.0.1-2443" ]]; then printf " KEEP"; else printf " LOST"; fi' 2>&1)"
if [[ "$got" == "RC=0 RM=$SANDBOX/rm-v6/fwd-::-2443 KEEP" ]]; then
    ok "20b. IPv6 bind 最後冒號切分，只刪 :: 那一條"
else
    bad "20b. 不對（got [$got]）"
fi

echo "=== 21. 主選單三入口 ==="
menu_body="$(awk '/^main_menu\(\)/{infn=1; next} infn && $0 == "}" {infn=0; next} infn {print}' "$MLP")"
if printf '%s' "$menu_body" | grep -q 'fwd-add' \
&& printf '%s' "$menu_body" | grep -q 'fwd-ls' \
&& printf '%s' "$menu_body" | grep -q 'fwd-rm'; then
    ok "21a. 主選單列出 fwd-add/fwd-ls/fwd-rm"
else
    bad "21a. 主選單缺入口"
fi
if printf '%s' "$menu_body" | grep -q 'fwd-add) fwd_menu_add' \
&& printf '%s' "$menu_body" | grep -q 'fwd-ls) cmd_fwd ls' \
&& printf '%s' "$menu_body" | grep -q 'fwd-rm) cmd_fwd rm'; then
    ok "21b. 三入口各有分派（add 走互動 View，ls/rm 直通）"
else
    bad "21b. 分派缺失"
fi
fma_body="$(awk '/^fwd_menu_add\(\)/{infn=1; next} infn && $0 == "}" {infn=0; next} infn {print}' "$MLP")"
if [[ -n "$fma_body" ]] && printf '%s' "$fma_body" | grep -q 'fwd_view_add' \
&& printf '%s' "$fma_body" | grep -q 'fzf'; then
    ok "21c. fwd_menu_add 屬 View（fzf 挑選後交回正常 add 路）"
else
    bad "21c. fwd_menu_add 接線不對"
fi

# ==========================================================================
# 22. repair 機器：mlp fwd 的名字／port／選單／訊息／ls 不重解析
#     （openspec/changes/archive/2026-10-01-repair-fwd，tasks 1.1）
#
# ---- 介面（以 openspec/changes/archive/2026-10-01-repair-fwd/ 為準） ------------------------
#   D1 段內的裸數字 port ＝ repair。do_connect 與 fwd_add 各呼叫同一個判斷；
#      段沒設定時裸數字維持舊行為（worker）。**所以 R2 只量 fwd_add 的結果
#      （argv），不去斷言 target_resolve 的內部分支**——共用判斷住在哪一層
#      是實作選擇，argv 才是這裡的契約。寫成「target_resolve 2503 必須回
#      repair」會把 D1 允許的兩種做法（fwd_add 自己短路／改 target_resolve）
#      擋掉一種，是過度約束。
#   D2 fwd 選單每台在線的 repair 一列（名字或 ? ＋ port），**選到的值是
#      port**，靠 D1 解析；段沒設定時不列 repair，選單也不壞掉。
#   D3 fwd_view_add 的訊息比照 do_connect：repair-ambiguous 列出候選 port；
#      notfound 前印 TARGET_DETAIL（未設定段的警告）並多一行說明「repair
#      只在線上時才找得到」。'no such node or worker' 這句維持原樣（7d 釘著）。
#   D4 不跟隨、不重試：fwd ls 不重新解析 node 名字（0 次 pool-resolve、
#      0 次 repair 掃描），舊轉發不會接到之後拿到同 port 的別台機器。
#
# ---- 這節刻意沒釘的東西（別當成已測到） ---------------------------------
#   * R4 只釘「列出兩個候選 port」與「不再誤報 no such node or worker」。
#     D3 還要求「提示改用 port」——那句**措辭**沒釘死：自己生一句措辭再拿
#     自己寫的斷言去量它是自證，不是證據。
#   * R6 用 `interactive_only() { return 0; }` 放行 TTY 閘（非互動行程進不了
#     fwd_menu_add），量的是候選流與「選到就以 port 解析」；閘本身不在本節
#     （21c 靜態釘接線）。
#   * 真 fzf 互動、真機上 down／換 port 的自然斷（D4）都不在這裡，全是 stub。
#   * R7 的「0 次」不是憑空：R1b 用同一套帳在 add 路徑量到掃描 1 次、
#     pool-resolve ≥1 次；R1c 量到成功時 stderr 0 行。零是量出來的，不是漏的。
#
# ---- 紅燈是本節的預期 ---------------------------------------------------
#   impl 之前：R2/R4/R5/R6 紅，R1/R3/R7 綠。檔尾有分節失敗數，可以一眼分辨
#   「本節預期紅」與「0-21 節回歸」。
echo "=== 22. repair 機器：fwd 的名字／port／選單／訊息／ls 不重解析 ==="

# ---- 22.1 夾具 ------------------------------------------------------------
# 段用**非預設**的 [2500,2599]（文件寫的預設是 [2400,2499]）：2503 落在
# 預設段外，所以一紅就分得出「讀了設定」與「讀死常數」。
RP_GW_JSON='{"ip":"9.9.9.9","user":"gw","port":22,"ports":{"repair":[2500,2599]}}'
RP_GW_JSON_NOPORTS='{"ip":"9.9.9.9","user":"gw","port":22}'
printf '%s\n' '[{"container":"w1","port":2401,"provider":"pn"}]' > "$SANDBOX/rp-workers.json"
# 掃描回放（形狀照 test-mlp-repair.sh 的 repair-scan-main.txt）：
#   2503 dad-pc   唯一名 → 名字形式
#   2510/2520 twin 同名兩台 → 同名拒絕（R4）與選單逐台可選（R6）
#   2550 沒名牌    → ? ＋ port（D5：listener 是唯一事實）
#   2404 段外      → 不該出現在任何 repair 列（段沒讀錯的另一個證據）
cat > "$SANDBOX/rp-scan.txt" <<'SCAN'
REPAIR-SCAN-L
LISTEN 0 128 127.0.0.1:2404 0.0.0.0:*
LISTEN 0 128 127.0.0.1:2503 0.0.0.0:*
LISTEN 0 128 127.0.0.1:2510 0.0.0.0:*
LISTEN 0 128 127.0.0.1:2520 0.0.0.0:*
LISTEN 0 128 127.0.0.1:2550 0.0.0.0:*
REPAIR-SCAN-N
2503 dad-pc
2510 twin
2520 twin
REPAIR-SCAN-END
SCAN

# ---- 22.2 跑法與量法 ------------------------------------------------------
RP_COMMON=(
  "POOL_OVERRIDE=$SANDBOX/shims/pool-resolve"
  "FAKE_GW_RC=0" "FAKE_MASTER_RC=0"
  "FAKE_PS_FILE=$SANDBOX/ps-none.txt" "FAKE_NODES_JSON=$SANDBOX/nodes.json"
  "FAKE_WORKERS_FILE=$SANDBOX/rp-workers.json"
  "FAKE_REPAIR_SCAN_FILE=$SANDBOX/rp-scan.txt"
  "FAKE_START_RC=0" "FAKE_TUNNEL_RC=0" "FAKE_TARGET_RC=1"
  "FAKE_TARGET_ERR=bash: connect: Connection refused"
  "SSH_REAL=$SSH_FILE" "HOME=$SANDBOX/home" "PATH=$SANDBOX/shims:$PATH"
)
# 三本帳：argv／pool-resolve／repair 掃描。清帳 + 開新的 FWD 目錄。
rp_reset() {
    rm -rf "$SANDBOX/rp-$1"
    mkdir -p "$SANDBOX/rp-$1"
    : > "$SANDBOX/$1-argv.log"
    : > "$SANDBOX/$1-pr.log"
    : > "$SANDBOX/$1-scan.log"
    : > "$SANDBOX/$1-out"
    : > "$SANDBOX/$1-err"
}
# rp_case <前綴> <mlp檔> <gwjson> <node> <spec> [VAR=VAL ...]
#   跑 fwd_add（ViewModel），印 RC/ERR/NODE/OUT位元組/ERR位元組。
#   沙箱突變檔的 SCRIPT_DIR 會指進沙箱、source 不到真的 ssh.sh，走
#   ssh_via_gateway 就 command not found——三個跑法都在 source 之後補 source
#   真的那份（與注入 24 同一個坑）。
rp_case() {
    local pfx="$1" mf="$2" gwjson="$3" node="$4" spec="$5"; shift 5
    local d="$SANDBOX/rp-$pfx"
    rp_reset "$pfx"
    env "${RP_COMMON[@]}" "MLP_FILE=$mf" "FWD_OVERRIDE=$d" "FAKE_GW_JSON=$gwjson" \
        "ARGV_LOG=$SANDBOX/$pfx-argv.log" "PR_LOG=$SANDBOX/$pfx-pr.log" \
        "SCAN_LOG=$SANDBOX/$pfx-scan.log" "ADD_OUT=$SANDBOX/$pfx-out" \
        "ADD_ERR=$SANDBOX/$pfx-err" "RP_NODE=$node" "RP_SPEC=$spec" \
        "$@" \
        bash -c 'source "$MLP_FILE" >/dev/null 2>&1
                 source "$SSH_REAL" >/dev/null 2>&1
                 FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"
                 : > "$ADD_OUT"; : > "$ADD_ERR"
                 if fwd_add "$RP_NODE" "$RP_SPEC" >"$ADD_OUT" 2>"$ADD_ERR"; then rc=0; else rc=$?; fi
                 printf "RC=%s ERR=%s NODE=%s OUT=%s ERRB=%s" "$rc" "$FWD_ERR" "$FWD_ADD_NODE" \
                   "$(wc -c < "$ADD_OUT" | tr -d " ")" "$(wc -c < "$ADD_ERR" | tr -d " ")"' 2>&1
}
# rp_view <前綴> <mlp檔> <gwjson> <node> <spec> [VAR=VAL ...]
#   跑 fwd_view_add（View，R4/R5 量的是人真的看到的那段）。die 會 exit，
#   所以放在子殼層裡跑，rc 才量得到。
rp_view() {
    local pfx="$1" mf="$2" gwjson="$3" node="$4" spec="$5"; shift 5
    local d="$SANDBOX/rp-$pfx"
    rp_reset "$pfx"
    env "${RP_COMMON[@]}" "MLP_FILE=$mf" "FWD_OVERRIDE=$d" "FAKE_GW_JSON=$gwjson" \
        "ARGV_LOG=$SANDBOX/$pfx-argv.log" "PR_LOG=$SANDBOX/$pfx-pr.log" \
        "SCAN_LOG=$SANDBOX/$pfx-scan.log" "ADD_OUT=$SANDBOX/$pfx-out" \
        "ADD_ERR=$SANDBOX/$pfx-err" "RP_NODE=$node" "RP_SPEC=$spec" \
        "$@" \
        bash -c 'source "$MLP_FILE" >/dev/null 2>&1
                 source "$SSH_REAL" >/dev/null 2>&1
                 FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"
                 : > "$ADD_OUT"; : > "$ADD_ERR"
                 ( fwd_view_add "$RP_NODE" "$RP_SPEC" >"$ADD_OUT" 2>"$ADD_ERR" )
                 rc=$?
                 printf "RC=%s" "$rc"' 2>&1
}
# rp_menu <前綴> <mlp檔> <gwjson> <spec> [VAR=VAL ...]
#   跑 fwd_menu_add（不帶參數的選單）。spec 用 here-string 餵 stdin；TTY 閘
#   用 interactive_only 放行（見節首）。候選流由 fzf stub 落盤。
rp_menu() {
    local pfx="$1" mf="$2" gwjson="$3" spec="$4"; shift 4
    local d="$SANDBOX/rp-$pfx"
    rp_reset "$pfx"
    : > "$SANDBOX/$pfx-menu-out"
    : > "$SANDBOX/$pfx-menu-err"
    : > "$SANDBOX/$pfx-menu-res"
    ( env "${RP_COMMON[@]}" "MLP_FILE=$mf" "FWD_OVERRIDE=$d" "FAKE_GW_JSON=$gwjson" \
        "ARGV_LOG=$SANDBOX/$pfx-argv.log" "PR_LOG=$SANDBOX/$pfx-pr.log" \
        "SCAN_LOG=$SANDBOX/$pfx-scan.log" "FZF_STDIN_LOG=$SANDBOX/$pfx-fzf.stdin" \
        "RP_SPEC=$spec" "MENU_RES=$SANDBOX/$pfx-menu-res" "$@" \
        bash -c 'source "$MLP_FILE" >/dev/null 2>&1
                 source "$SSH_REAL" >/dev/null 2>&1
                 FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"
                 interactive_only() { return 0; }
                 fwd_menu_add
                 printf "RC=%s" "$?" > "$MENU_RES"' <<< "$spec" \
        > "$SANDBOX/$pfx-menu-out" 2> "$SANDBOX/$pfx-menu-err" ) || true
    printf '%s' "$(cat "$SANDBOX/$pfx-menu-res" 2>/dev/null || true)"
}
# rp_ls <前綴> <mlp檔> <gwjson>：fwd ls 一筆 repair 轉發，回 RC/PR次數/SCAN次數。
#   ps 回放那一筆的 node 名是 dad-pc，但這條路**不該**去解析它。
rp_ls() {
    local pfx="$1" mf="$2" gwjson="$3"
    local d="$SANDBOX/rp-$pfx"
    rp_reset "$pfx"
    touch "$d/fwd-127.0.0.1-8080"
    printf ' 4444 ssh -S %s -N -f -L 127.0.0.1:8080:192.168.0.50:80 repair@127.0.0.1 mlp-fwd-node=dad-pc\n' \
        "$d/fwd-127.0.0.1-8080" > "$SANDBOX/rp-ls-ps.txt"
    env "${RP_COMMON[@]}" "MLP_FILE=$mf" "FWD_OVERRIDE=$d" "FAKE_GW_JSON=$gwjson" \
        "FAKE_PS_FILE=$SANDBOX/rp-ls-ps.txt" \
        "ARGV_LOG=$SANDBOX/$pfx-argv.log" "PR_LOG=$SANDBOX/$pfx-pr.log" \
        "SCAN_LOG=$SANDBOX/$pfx-scan.log" "LS_OUT=$SANDBOX/$pfx-out" \
        "LS_ERR=$SANDBOX/$pfx-err" \
        bash -c 'source "$MLP_FILE" >/dev/null 2>&1
                 source "$SSH_REAL" >/dev/null 2>&1
                 FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"
                 fwd_view_ls >"$LS_OUT" 2>"$LS_ERR"
                 printf "RC=%s PR=%s SCAN=%s" "$?" \
                   "$(grep -c "^PR " "$PR_LOG" 2>/dev/null || true)" \
                   "$(grep -c "^SCAN$" "$SCAN_LOG" 2>/dev/null || true)"' 2>&1
}
# 量法小幫手。
rp_has()   { grep -qxF -- "$2" "$1" 2>/dev/null; }
rp_lack()  { ! grep -qxF -- "$2" "$1" 2>/dev/null; }
# rp_opt <argv檔> <選項> <值>：<選項> 的**下一個** argv 就是 <值>
#   （不只抓「整份裡某處有這個值」——那會被別處的同值假綠）。
rp_opt()   { awk -v o="$2" -v v="$3" 'p == o && $0 == v { found = 1; exit } { p = $0 } END { exit (found ? 0 : 1) }' "$1" 2>/dev/null; }
rp_count() { grep -c "$2" "$1" 2>/dev/null || true; }
# rp_lines <檔>：非空白行數（die 訊息與說明行的計數基準）。
rp_lines() { grep -c '[^[:space:]]' "$1" 2>/dev/null || true; }
# rp_row <候選流檔> <token> <token>：有一列同時含這兩個 token（不綁死欄位形狀）。
rp_row()   { grep -F -- "$2" "$1" 2>/dev/null | grep -qF -- "$3"; }
# rp_tail <檔>：最後一個非空白行。
rp_tail()  { grep '[^[:space:]]' "$1" 2>/dev/null | tail -1; }

pre22_pass="$pass"; pre22_fail="$fail"

# ---- R1. 名字形式：現碼就該能用（recon §1 量過） -------------------------
got="$(rp_case r1 "$MLP_FILE" "$RP_GW_JSON" dad-pc "8080:192.168.0.50:80")"
if [[ "$got" == "RC=0 ERR= NODE=dad-pc OUT=0 ERRB=0" ]] \
   && rp_opt "$SANDBOX/r1-argv.log" -p 2503 \
   && rp_has "$SANDBOX/r1-argv.log" 'repair@127.0.0.1' \
   && rp_has "$SANDBOX/r1-argv.log" '-L' \
   && rp_has "$SANDBOX/r1-argv.log" '127.0.0.1:8080:192.168.0.50:80' \
   && rp_has "$SANDBOX/r1-argv.log" 'mlp-fwd-node=dad-pc' \
   && rp_lack "$SANDBOX/r1-argv.log" 'worker@127.0.0.1'; then
    ok "R1a. 名字形式：-p 2503 + repair@127.0.0.1 + -L 完整 + mlp-fwd-node=dad-pc"
else
    bad "R1a. 名字形式不對（got [$got] argv=[$(tr '\n' '|' < "$SANDBOX/r1-argv.log")]）"
fi
r1_scan="$(rp_count "$SANDBOX/r1-scan.log" '^SCAN$')"
r1_pr="$(rp_count "$SANDBOX/r1-pr.log" '^PR ')"
if [[ "$r1_scan" == "1" && "$r1_pr" -ge 1 ]]; then
    ok "R1b. 計數器對照：同一套帳在 add 路徑量得到（掃描 ${r1_scan} 次、pool-resolve ${r1_pr} 次）"
else
    bad "R1b. 計數器在 add 路徑就量不到（scan=${r1_scan} pr=${r1_pr}）——R7 的 0 次會是假零"
fi
r1_errlines="$(rp_lines "$SANDBOX/r1-err")"
if [[ "$r1_errlines" == "0" ]]; then
    ok "R1c. 計數器對照：同樣的行數量法在成功時量到 stderr ${r1_errlines} 行——R5 要求的「多一行」有基準"
else
    bad "R1c. 成功路徑的 stderr 不該有內容，量到 ${r1_errlines} 行"
fi

# ---- R2. 段內 port 形式：現碼紅（第二跳會是 worker@127.0.0.1） -----------
got="$(rp_case r2 "$MLP_FILE" "$RP_GW_JSON" 2503 "8080")"
if [[ "$got" == "RC=0 ERR= NODE=2503 OUT=0 ERRB=0" ]] \
   && rp_opt "$SANDBOX/r2-argv.log" -p 2503 \
   && rp_has "$SANDBOX/r2-argv.log" 'repair@127.0.0.1' \
   && rp_lack "$SANDBOX/r2-argv.log" 'worker@127.0.0.1' \
   && rp_has "$SANDBOX/r2-argv.log" '127.0.0.1:8080:127.0.0.1:8080'; then
    ok "R2. 段內裸數字 port → 第二跳用 repair@127.0.0.1"
else
    bad "R2. 段內 port 沒被當 repair（got [$got] argv=[$(tr '\n' '|' < "$SANDBOX/r2-argv.log")]）"
fi

# ---- R3. 段外／未設定段：裸數字維持 worker（D1 的語意邊界，回歸保護） -----
#   2401 落在**文件預設段** [2400,2499] 裡但不在設定的 [2500,2599] 裡：
#   讀死常數的實作會在這裡現形。2503 ＋ 未設定段是 Definition 1。
got3a="$(rp_case r3a "$MLP_FILE" "$RP_GW_JSON" 2401 "8080")"
if [[ "$got3a" == "RC=0 ERR= NODE=2401 OUT=0 ERRB=0" ]] \
   && rp_opt "$SANDBOX/r3a-argv.log" -p 2401 \
   && rp_has "$SANDBOX/r3a-argv.log" 'worker@127.0.0.1' \
   && rp_lack "$SANDBOX/r3a-argv.log" 'repair@127.0.0.1'; then
    ok "R3a. 段外裸數字（2401，卻在預設段內）維持 worker——段是讀設定的"
else
    bad "R3a. 段外 port 被誤認成 repair（got [$got3a] argv=[$(tr '\n' '|' < "$SANDBOX/r3a-argv.log")]）"
fi
got3b="$(rp_case r3b "$MLP_FILE" "$RP_GW_JSON_NOPORTS" 2503 "8080")"
if [[ "$got3b" == "RC=0 ERR= NODE=2503 OUT=0 ERRB=0" ]] \
   && rp_opt "$SANDBOX/r3b-argv.log" -p 2503 \
   && rp_has "$SANDBOX/r3b-argv.log" 'worker@127.0.0.1' \
   && rp_lack "$SANDBOX/r3b-argv.log" 'repair@127.0.0.1'; then
    ok "R3b. ports.repair 未設定時裸數字維持 worker（Def1，不猜段）"
else
    bad "R3b. 未設定段卻把裸數字當 repair（got [$got3b] argv=[$(tr '\n' '|' < "$SANDBOX/r3b-argv.log")]）"
fi

# ---- R4. 同名 repair：拒絕並列 port（現碼紅：說成 no such node or worker）-
got="$(rp_view r4 "$MLP_FILE" "$RP_GW_JSON" twin 8080)"
if [[ "$got" != "RC=0" ]] \
   && grep -q '2510' "$SANDBOX/r4-err" \
   && grep -q '2520' "$SANDBOX/r4-err" \
   && ! grep -q 'no such node or worker' "$SANDBOX/r4-err"; then
    ok "R4. 同名 repair → 非零、列出兩個候選 port、不再誤報 no such node or worker"
else
    bad "R4. 同名 repair 的處理不對（got [$got] err=[$(tr '\n' '|' < "$SANDBOX/r4-err")]）"
fi

# ---- R5. 找不到／未設定段：多一行說明，generic 字串留著（現碼紅） ---------
#   7d 回歸釘的 'no such node or worker' 這裡一起量：它必須是**最後一行**，
#   前面那行才是新增的說明。「多一行」與「generic 沒被改寫」同時成立。
got="$(rp_view r5a "$MLP_FILE" "$RP_GW_JSON" ghost-pc 8080)"
r5a_lines="$(rp_lines "$SANDBOX/r5a-err")"
r5a_last="$(rp_tail "$SANDBOX/r5a-err")"
if [[ "$got" != "RC=0" && "$r5a_lines" -ge 2 \
   && "$r5a_last" == *"no such node or worker: ghost-pc"* ]]; then
    ok "R5a. repair 名字查無 → 多一行說明（在線才找得到），generic 那句留著當最後一行"
else
    bad "R5a. 查無時沒有說明行（got [$got] 行數 [${r5a_lines}] want ≥2 末行 [${r5a_last}]）"
fi
got="$(rp_view r5b "$MLP_FILE" "$RP_GW_JSON_NOPORTS" ghost-pc 8080)"
r5b_lines="$(rp_lines "$SANDBOX/r5b-err")"
r5b_last="$(rp_tail "$SANDBOX/r5b-err")"
if [[ "$got" != "RC=0" && "$r5b_lines" -ge 2 \
   && "$r5b_last" == *"no such node or worker: ghost-pc"* ]] \
   && grep -q 'ports.repair' "$SANDBOX/r5b-err"; then
    ok "R5b. ports.repair 未設定 → 印出警告行（TARGET_DETAIL），generic 那句留著"
else
    bad "R5b. 未設定段沒有警告行（got [$got] 行數 [${r5b_lines}] 末行 [${r5b_last}] err=[$(tr '\n' '|' < "$SANDBOX/r5b-err")]）"
fi

# ---- R6. 不帶參數的選單：候選含在線 repair，選到就以 port 解析（現碼紅） ---
# fzf stub（test-mlp-repair.sh §10 同一手法）：先把整份候選流落盤，再挑出同時
# 含 FZF_PICK_NAME 與 FZF_PICK_PORT 的那一列回傳（真 fzf 挑不到就是 exit 1
# 且無輸出）。**刻意不綁欄位位置**：D2 只說「顯示名字（或 ?）與 port、選到的
# 值是 port」，欄位形狀是實作選擇；要量的是「那一列最後被當成 port 解析」。
# 兩個 FZF_PICK_* 都沒給時維持原本的大聲拒絕（不該有靜默 fzf）。
cat > "$SANDBOX/shims/fzf" <<'FAKE'
#!/usr/bin/env bash
if [[ -z "${FZF_PICK_NAME:-}" && -z "${FZF_PICK_PORT:-}" ]]; then
    echo "test stub: refusing fzf (no FZF_PICK_* set)" >&2
    exit 255
fi
cat > "${FZF_STDIN_LOG:-/dev/null}"
n="${FZF_PICK_NAME:-}"
p="${FZF_PICK_PORT:-}"
while IFS= read -r line; do
    if [[ "$line" == *"$n"* && "$line" == *"$p"* ]]; then
        printf '%s\n' "$line"
        exit 0
    fi
done < "${FZF_STDIN_LOG:-/dev/null}"
exit 1
FAKE
chmod +x "$SANDBOX/shims/fzf"

got="$(rp_menu r6a "$MLP_FILE" "$RP_GW_JSON" 8080 FZF_PICK_NAME=dad-pc FZF_PICK_PORT=2503)"
if rp_row "$SANDBOX/r6a-fzf.stdin" 'dad-pc' '2503' \
   && rp_row "$SANDBOX/r6a-fzf.stdin" 'gateway' 'gateway' \
   && rp_row "$SANDBOX/r6a-fzf.stdin" 'w1' 'w1'; then
    ok "R6a. 選單候選含在線 repair（dad-pc ＋ 2503），gateway 與 worker 沒被擠掉"
else
    bad "R6a. 選單裡沒有 repair 候選（候選流=[$(tr '\n' '|' < "$SANDBOX/r6a-fzf.stdin" 2>/dev/null)]）"
fi
if [[ "$got" == "RC=0" ]] && rp_opt "$SANDBOX/r6a-argv.log" -p 2503 \
   && rp_has "$SANDBOX/r6a-argv.log" 'repair@127.0.0.1' \
   && rp_lack "$SANDBOX/r6a-argv.log" 'worker@127.0.0.1'; then
    ok "R6b. 選到 dad-pc 那列 → 以 port 2503 起 repair 轉發"
else
    bad "R6b. 選到 repair 那列沒以 port 解析（got [$got] argv=[$(tr '\n' '|' < "$SANDBOX/r6a-argv.log" 2>/dev/null)]）"
fi
# R6c 是「以 port 解析」唯一有辨識力的那格：twin 同名兩台，選名字必定
# ambiguity 拒絕，選 port 2510 會直達 2510。dad-pc 那格分辨不出這件事。
got="$(rp_menu r6c "$MLP_FILE" "$RP_GW_JSON" 8080 FZF_PICK_NAME=twin FZF_PICK_PORT=2510)"
if [[ "$got" == "RC=0" ]] && rp_opt "$SANDBOX/r6c-argv.log" -p 2510 \
   && rp_has "$SANDBOX/r6c-argv.log" 'repair@127.0.0.1' \
   && ! grep -q 'matches multiple' "$SANDBOX/r6c-menu-err"; then
    ok "R6c. 同名的 twin 選 2510 那台就直達 2510——不是走名字（那會被拒）"
else
    bad "R6c. 同名列沒以 port 解析（got [$got] argv=[$(tr '\n' '|' < "$SANDBOX/r6c-argv.log" 2>/dev/null)] err=[$(tr '\n' '|' < "$SANDBOX/r6c-menu-err" 2>/dev/null)]）"
fi
# R6d：沒有名牌的 listener 也要能選（D5 形狀：顯示 ? ＋ port）。
got="$(rp_menu r6d "$MLP_FILE" "$RP_GW_JSON" 8080 FZF_PICK_NAME='?' FZF_PICK_PORT=2550)"
if [[ "$got" == "RC=0" ]] && rp_opt "$SANDBOX/r6d-argv.log" -p 2550 \
   && rp_has "$SANDBOX/r6d-argv.log" 'repair@127.0.0.1'; then
    ok "R6d. 沒有名牌的那台（? ＋ 2550）也在候選裡，選到就以 2550 起"
else
    bad "R6d. 沒有名牌的 repair 選不到（got [$got] argv=[$(tr '\n' '|' < "$SANDBOX/r6d-argv.log" 2>/dev/null)]）"
fi
# R6e：段沒設定 → 不列 repair，且選單要正常收掉（不能壞掉、不能誤列）。
got="$(rp_menu r6e "$MLP_FILE" "$RP_GW_JSON_NOPORTS" 8080 FZF_PICK_NAME=dad-pc FZF_PICK_PORT=2503)"
if rp_row "$SANDBOX/r6e-fzf.stdin" 'gateway' 'gateway' \
   && ! grep -q '2503' "$SANDBOX/r6e-fzf.stdin" \
   && grep -q 'aborted' "$SANDBOX/r6e-menu-out"; then
    ok "R6e. 段沒設定時不列 repair，選單仍正常收掉（aborted，不是崩）"
else
    bad "R6e. 未設定段的選單形狀不對（got [$got] 候選流=[$(tr '\n' '|' < "$SANDBOX/r6e-fzf.stdin" 2>/dev/null)] out=[$(tr '\n' '|' < "$SANDBOX/r6e-menu-out" 2>/dev/null)]）"
fi

# ---- R7. fwd ls 不重新解析 node 名字（D4 的機制） -------------------------
got="$(rp_ls r7 "$MLP_FILE" "$RP_GW_JSON")"
if [[ "$got" == "RC=0 PR=0 SCAN=0" ]] && grep -q 'dad-pc' "$SANDBOX/r7-out"; then
    ok "R7. fwd ls 不重新解析：0 次 pool-resolve、0 次 repair 掃描，名字仍從 ps 顯示"
else
    bad "R7. fwd ls 有重新解析（got [$got] 輸出=[$(tr '\n' '|' < "$SANDBOX/r7-out")]）"
fi

# ---- 22-inj. 對照：把目標行為**做壞**，斷言必須轉紅 ------------------------
# 紅燈那幾格光看「現在是紅的」不足以證明斷言在量東西——也可能是 harness 壞掉。
# 所以每一格都配一次對照突變。實作落地（openspec D1–D4）之後角色反轉了：
# **目標行為現在就是產品碼本身**，紅燈格已轉綠，所以還留著的對照全部改成
# 「做壞它，斷言必須轉紅」——這才是現在唯一還有牙的形狀。
# 轉不到就是 harness 問題（inj_bad），不是被測物的問題。
# 注意突變檔都寫在沙箱裡，SCRIPT_DIR 會指錯，所以三個跑法都補 source 真的 ssh.sh。
#
# 錨點一律用「行比對 + 形狀 assert」，不用整段字串比對：措辭改了不該讓護欄報假警，
# 但**形狀**變了（分支不見、換成別的形狀、函式被改寫）必須大聲壞掉——寧可
# inj_bad 說「形狀變了」，也不要靜靜留一條量不到東西的注入。

# 22-inj1：**已移除（PM 裁定 2026-10-01，工單 test-repair-fwd-injections）**。
#   它是「把目標行為做出來」的突變（把段內裸數字的短路塞回 fwd_add），只套得在
#   還沒有 D1 的產品碼上：真實實作把那三行放進 `else`、縮排變 8 空白，字串針就
#   落空了（OUT-impl-repair-fwd.md §5.2）。它的意圖現在由 **R2 本身**接手——
#   R2 斷言的正是「段內 port 的第二跳是 repair@127.0.0.1」，而真的程式碼就是
#   那個目標行為，所以 R2 綠就是這個意圖被滿足的證據。再留一條會把同一件事
#   用假造的程式碼再證一次。
#
# 22-inj2（D1 的壞形狀：共用判斷 repair_port_p 對**任何**裸數字都回真）。
#   R3a（段外的 2401）／R3b（段未設定的 2503）必須轉紅。
#   這條從「改 fwd_add 的解析」改成「改 D1 那個共用判斷本身」——形狀隨實作變了，
#   意圖沒變，而且這是唯一一條能守住「段界沒被拿掉」的護欄。
#   三個條件一起拿掉（兩個界非空、-ge/-le）是刻意的：只拿掉 -ge/-le 時，
#   `GW_REPAIR_LO=""` 會讓 `[[ 2503 -ge "" ]]` 自己回 false，R3b 變不出差異
#   （OUT-impl-repair-fwd.md §5.4 第 3 點量過）。全數字那個條件留著。
INJ_R2="$SANDBOX/rp-mut-norange.sh"
python3 - "$MLP" "$INJ_R2" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('repair_port_p() {\n'
       '    [[ "$1" =~ ^[0-9]+$ ]] || return 1\n'
       '    [[ -n "${GW_REPAIR_LO:-}" && -n "${GW_REPAIR_HI:-}" ]] || return 1\n'
       '    [[ "$1" -ge "$GW_REPAIR_LO" && "$1" -le "$GW_REPAIR_HI" ]]\n'
       '}\n')
new = ('repair_port_p() {\n'
       '    [[ "$1" =~ ^[0-9]+$ ]] || return 1\n'
       '    # INJECTED: 段界被拿掉——任何裸數字都當 repair\n'
       '    return 0\n'
       '}\n')
assert src.count(old) == 1, "repair_port_p needle count=%d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "22-inj2. 突變腳本失敗（D1 的共用判斷形狀變了）——harness 問題"
elif ! bash -n "$INJ_R2" 2>/dev/null; then
    inj_bad "22-inj2. 突變版語法錯誤——harness 問題"
else
    got3a="$(rp_case rinj2a "$INJ_R2" "$RP_GW_JSON" 2401 "8080")"
    got3b="$(rp_case rinj2b "$INJ_R2" "$RP_GW_JSON_NOPORTS" 2503 "8080")"
    if rp_has "$SANDBOX/rinj2a-argv.log" 'repair@127.0.0.1' \
       && rp_lack "$SANDBOX/rinj2a-argv.log" 'worker@127.0.0.1' \
       && rp_has "$SANDBOX/rinj2b-argv.log" 'repair@127.0.0.1' \
       && rp_lack "$SANDBOX/rinj2b-argv.log" 'worker@127.0.0.1'; then
        inj_ok "22-inj2. 段界拿掉後段外與未設定段都被認成 repair（${got3a}/${got3b}）——R3a/R3b 會紅"
    else
        inj_bad "22-inj2. 段界拿掉後 R3a/R3b 仍綠（${got3a}/${got3b}）——R3 是空的"
    fi
fi

# 22-inj3（D3 的 repair-ambiguous 那一格被**拿掉**）。R4 必須轉紅。
#   方向在 2026-10-01 翻過來（工單 test-repair-fwd-injections-2）：實作落地後
#   「把目標行為做出來」已無意義——真實程式碼就是那個目標行為，突變插進去的那份
#   是死碼，R4 靠真實程式碼本來就會綠。當時量到的證據：突變的訊息一次都沒被印
#   出來（OUT-test-repair-fwd-injections.md §4）。所以改成反向：**拿掉那一格**，
#   同名 repair 必須又變回 no such node or worker、兩個候選 port 一個都不列，
#   R4 才會紅。這條從「必定通過」變成有牙。
#   錨點用行比對而不是整段字串比對：措辭改了不該讓這條報假警，但**形狀**變了
#   （分支不見、或換成別的形狀）必須大聲壞掉，而不是靜靜變成惰性注入。
INJ_R3="$SANDBOX/rp-mut-ambiguous.sh"
python3 - "$MLP" "$INJ_R3" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
anchor = '            if [[ "$TARGET_ERR" == "repair-ambiguous" ]]; then'
hits = [k for k, l in enumerate(lines) if l == anchor]
assert len(hits) == 1, "ambiguous-branch anchor count=%d" % len(hits)
i = hits[0]
assert lines[i + 1].lstrip().startswith('die "repair name '), "expected a die line right after, got %r" % lines[i + 1]
assert lines[i + 2] == "            fi", "expected the branch to close there, got %r" % lines[i + 2]
del lines[i:i + 3]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "22-inj3. 突變腳本失敗（D3 的分支形狀變了）——harness 問題"
elif ! bash -n "$INJ_R3" 2>/dev/null; then
    inj_bad "22-inj3. 突變版語法錯誤——harness 問題"
else
    got="$(rp_view rinj3 "$INJ_R3" "$RP_GW_JSON" twin 8080)"
    # R4 的判準要整個翻面：非零仍成立，但兩個候選 port 都不列、generic 那句回來。
    if [[ "$got" != "RC=0" ]] && grep -q 'no such node or worker: twin' "$SANDBOX/rinj3-err" \
       && ! grep -q '2510' "$SANDBOX/rinj3-err" && ! grep -q '2520' "$SANDBOX/rinj3-err"; then
        inj_ok "22-inj3. 拿掉 repair-ambiguous 分支後同名又變回 no such node or worker、兩個 port 一個都沒列（got [$got]）——R4 會紅"
    else
        inj_bad "22-inj3. 拿掉那一格後 R4 仍綠（got [$got] err=[$(tr '\n' '|' < "$SANDBOX/rinj3-err")]）——R4 的訊息護欄是空的"
    fi
fi

# 22-inj4：把 notfound 路徑上的說明行 ＋ TARGET_DETAIL 印出拿掉 → R5a/R5b 必須轉紅。
#   兩行一起拿掉：只拿掉說明行，R5b 還剩 TARGET_DETAIL 的警告行撐著，不會紅。
#   錨點認角色不認位置：generic 往上連續兩個有意義的行，依序必須是「會印說明行」
#   的與「TARGET_DETAIL 的印出」。不能改成掃整個分支——unreachable 子路徑也有一行
#   TARGET_DETAIL，掃到兩行就分不出要拿哪一行。
INJ_R4="$SANDBOX/rp-mut-offline.sh"
python3 - "$MLP" "$INJ_R4" <<'PY'
import re, sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")

def meaningful(k):
    s = lines[k].strip()
    return bool(s) and not s.startswith("#")

def is_note_emitter(s):
    t = s.strip()
    return bool(re.search(r"\brepair_note\b\s*$", t)) or t.startswith("printf 'note: a repair host")

dies = [k for k, l in enumerate(lines) if l.strip() == 'die "no such node or worker: ${node}"']
assert len(dies) == 1, "fwd-generic count=%d" % len(dies)
j = dies[0]
above = [k for k in range(j - 1, -1, -1) if meaningful(k)][:2]
assert len(above) == 2, "expected two meaningful lines above the generic, got %d" % len(above)
note, detail = above
assert is_note_emitter(lines[note]), "line %d is not a note emitter: %r" % (note + 1, lines[note])
assert "TARGET_DETAIL" in lines[detail] and ">&2" in lines[detail], \
    "line %d is not the TARGET_DETAIL print: %r" % (detail + 1, lines[detail])
for k in sorted(above, reverse=True):
    del lines[k]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "22-inj4. 突變腳本失敗（D3 的說明行形狀變了）——harness 問題"
elif ! bash -n "$INJ_R4" 2>/dev/null; then
    inj_bad "22-inj4. 突變版語法錯誤——harness 問題"
else
    got="$(rp_view rinj4a "$INJ_R4" "$RP_GW_JSON" ghost-pc 8080)"
    la="$(rp_lines "$SANDBOX/rinj4a-err")"
    la_last="$(rp_tail "$SANDBOX/rinj4a-err")"
    gotb="$(rp_view rinj4b "$INJ_R4" "$RP_GW_JSON_NOPORTS" ghost-pc 8080)"
    lb="$(rp_lines "$SANDBOX/rinj4b-err")"
    lb_last="$(rp_tail "$SANDBOX/rinj4b-err")"
    # 用 R5a/R5b 自己的判準式（:1246／:1255）評一次突變後的值：兩式都必須為 false。
    r5a_holds=1; r5b_holds=1
    [[ "$la" -ge 2 && "$la_last" == *"no such node or worker: ghost-pc"* ]] || r5a_holds=0
    [[ "$lb" -ge 2 && "$lb_last" == *"no such node or worker: ghost-pc"* ]] \
        && grep -q 'ports.repair' "$SANDBOX/rinj4b-err" || r5b_holds=0
    # 兩格都該掉回「只剩 generic 那一句」：R5a 的 ≥2 行、R5b 的 ≥2 行＋ports.repair
    # 警告同時失效。
    if [[ "$la" == "1" && "$lb" == "1" \
       && "$la_last" == *"no such node or worker: ghost-pc"* \
       && "$lb_last" == *"no such node or worker: ghost-pc"* ]] \
       && ! grep -q 'ports.repair' "$SANDBOX/rinj4b-err" \
       && [[ "$r5a_holds" -eq 0 && "$r5b_holds" -eq 0 ]]; then
        inj_ok "22-inj4. 拿掉說明行與 TARGET_DETAIL 後 R5a/R5b 的判準式都轉 false（行數 ${la}/${lb}）——兩格都會紅"
    else
        inj_bad "22-inj4. 拿掉那兩行後 R5 仍綠（行數 ${la}/${lb} 末行 [${la_last}]/[${lb_last}]）——護欄是空的"
    fi
fi

# 22-inj5：**已移除（PM 裁定 2026-10-01，工單 test-repair-fwd-injections）**。
#   它是「把 D2 的選單做出來」的突變（插 repair 迴圈 ＋ 收斂成 port），同樣只
#   套得在還沒有 D2 的產品碼上：任何正確的 D2 實作都必須在 `gather_targets`
#   與 `} | fzf` 之間插東西，插完那段原文就不存在了（OUT-impl-repair-fwd.md
#   §5.3）。它的意圖由 **R6a–R6e 五格**接手：候選流（r6a 數得到 dad-pc ＋
#   2503）、以 port 解析（r6c 選同名的 twin/2510 直達 2510，不是走名字）、段
#   未設定時不列 repair 也不壞掉（r6e）——真的選單就是那個目標行為。
#   （當初量到「D2 依賴 D1」的那個證據也一起沒了：那需要一個只有選單、沒有 D1
#   的產品碼才量得到。**2026-10-01 由 22-inj7 接手**——見那條。）

# 22-inj6（D4 的反面：ls 偏要重新解析）。R7 必須轉紅——證明「0 次」這個
#   數字是量出來的，不是因為根本沒在數。
INJ_R6="$SANDBOX/rp-mut-ls-reresolve.sh"
python3 - "$MLP" "$INJ_R6" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    FWD_STATUS_ROWS=()\n'
       '    fwd_records\n')
new = ('    FWD_STATUS_ROWS=()\n'
       '    fwd_records\n'
       '    # INJECTED: 每列偏要重新解析一次（D4 明說不做）\n'
       '    local _rp_r\n'
       '    resolve_gateway nodie || true\n'
       '    for _rp_r in ${FWD_RECORDS[@]+"${FWD_RECORDS[@]}"}; do\n'
       '        fwd_split_row "$_rp_r"\n'
       '        target_resolve "$FWD_C3" || true\n'
       '    done\n')
assert src.count(old) == 1, "fwd_status needle count=%d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "22-inj6. 突變腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ_R6" 2>/dev/null; then
    inj_bad "22-inj6. 突變版語法錯誤——harness 問題"
else
    got="$(rp_ls rinj6 "$INJ_R6" "$RP_GW_JSON")"
    if [[ "$got" == "RC=0 PR=0 SCAN=0" ]]; then
        inj_bad "22-inj6. 塞了重新解析之後 R7 仍綠（got [$got]）——R7 的 0 次不是量出來的"
    else
        if [[ "$got" == "RC=0 PR="* && "$got" == *"SCAN=1" ]]; then
            inj_ok "22-inj6. 塞了重新解析後 R7 的計數會動（got [$got]）——R7 的 0 次是量出來的"
        else
            inj_bad "22-inj6. 行為變了但不是預期的重新解析（got [$got]）——harness 問題"
        fi
    fi
fi

# 22-inj7（「D2 依賴 D1」那條護欄，工單 test-repair-fwd-injections-2 新增）。
#   把 D1 的共用判斷 `repair_port_p` 改成**對所有 port 都回假**（＝ D1 整個失效），
#   於是 fwd_add 對數字走回 target_resolve 的裸數字分支 → 第二跳變成
#   worker@127.0.0.1。**R6b／R6c／R6d 必須轉紅，而 R6a（候選列表）仍然綠。**
#   這個對比就是這條存在的理由：列表長得完全正確、互動也沒壞，撥出去卻是錯的
#   帳號——repair VM 上沒有 worker 這個人，轉發會在 `fwd ls` 裡看起來健康、
#   卻一個封包都帶不過去。D2 與 D1 必須同一批上，這是當初 inj5 量到的結論
#   （OUT-test-repair-fwd.md §5 第 5 點），inj5 移除後由這條接手。
#   錨點同樣是行比對：repair_port_p 的內文改寫（合併條件、改 case）時這條會
#   大聲報「形狀變了」，不會靜靜變惰性注入。
INJ_R7="$SANDBOX/rp-mut-noport.sh"
python3 - "$MLP" "$INJ_R7" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
hits = [k for k, l in enumerate(lines) if l == "repair_port_p() {"]
assert len(hits) == 1, "repair_port_p anchor count=%d" % len(hits)
i = hits[0]
assert lines[i + 4] == "}", "expected a 5-line function, got %r" % lines[i + 4]
assert "=~ ^[0-9]+$" in lines[i + 1], "unexpected first condition %r" % lines[i + 1]
assert "GW_REPAIR_LO" in lines[i + 2] and "GW_REPAIR_HI" in lines[i + 2], "unexpected bounds check %r" % lines[i + 2]
assert "-ge" in lines[i + 3] and "-le" in lines[i + 3], "unexpected range check %r" % lines[i + 3]
lines[i:i + 5] = [
    "repair_port_p() {",
    "    # INJECTED: 段內判斷對所有 port 都回假——D1 整個失效",
    "    return 1",
    "}",
]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "22-inj7. 突變腳本失敗（D1 的共用判斷形狀變了）——harness 問題"
elif ! bash -n "$INJ_R7" 2>/dev/null; then
    inj_bad "22-inj7. 突變版語法錯誤——harness 問題"
else
    ga="$(rp_menu rinj7a "$INJ_R7" "$RP_GW_JSON" 8080 FZF_PICK_NAME=dad-pc FZF_PICK_PORT=2503)"
    gc="$(rp_menu rinj7c "$INJ_R7" "$RP_GW_JSON" 8080 FZF_PICK_NAME=twin FZF_PICK_PORT=2510)"
    gd="$(rp_menu rinj7d "$INJ_R7" "$RP_GW_JSON" 8080 FZF_PICK_NAME='?' FZF_PICK_PORT=2550)"
    # 判準：候選列表**照舊**含 repair（所以 R6a 仍綠），但三格的第二跳都變成
    # worker@127.0.0.1（所以 R6b/R6c/R6d 會紅）。兩個都要量，只量一半會漏掉
    # 「列表也壞了」那種退化。
    if rp_row "$SANDBOX/rinj7a-fzf.stdin" 'dad-pc' '2503' \
       && rp_has "$SANDBOX/rinj7a-argv.log" 'worker@127.0.0.1' \
       && rp_lack "$SANDBOX/rinj7a-argv.log" 'repair@127.0.0.1' \
       && rp_opt "$SANDBOX/rinj7a-argv.log" -p 2503 \
       && rp_has "$SANDBOX/rinj7c-argv.log" 'worker@127.0.0.1' \
       && rp_lack "$SANDBOX/rinj7c-argv.log" 'repair@127.0.0.1' \
       && rp_opt "$SANDBOX/rinj7c-argv.log" -p 2510 \
       && rp_has "$SANDBOX/rinj7d-argv.log" 'worker@127.0.0.1' \
       && rp_lack "$SANDBOX/rinj7d-argv.log" 'repair@127.0.0.1' \
       && rp_opt "$SANDBOX/rinj7d-argv.log" -p 2550; then
        inj_ok "22-inj7. D1 失效時列表照舊（R6a 仍綠）但三格全撥成 worker@127.0.0.1（${ga}/${gc}/${gd}）——R6b/R6c/R6d 會紅"
    else
        inj_bad "22-inj7. D1 拿掉後 R6b/R6c/R6d 仍綠（${ga}/${gc}/${gd} argv=[$(tr '\n' '|' < "$SANDBOX/rinj7c-argv.log" 2>/dev/null)]）——列表與身分綁在一起那道護欄是空的"
    fi
fi

echo "=== 10-16、22-26. 注入：拿掉修正，斷言必須轉紅 ==="
# 10. 健康檢測換成只問本機 → 隧道已死仍回報 up，2d 必須紅。
INJ1="$SANDBOX/mutant-probe-check.sh"
python3 - "$MLP" "$INJ1" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'ssh -S "$ctl" -o BatchMode=yes -o ConnectTimeout=5 placeholder true'
new = 'ssh -S "$ctl" -O check placeholder'
assert old in src, "tunnel-probe needle not found"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "10. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ1" 2>/dev/null; then
    inj_bad "10. 注入版語法錯誤——harness 問題"
elif ! grep -q -- '-O check placeholder' "$INJ1"; then
    inj_bad "10. 注入沒生效（needle 落空）——harness 問題"
else
    : > "$SANDBOX/argv.log"
    got="$(MLP_FILE="$INJ1" SSH_OVERRIDE="-" FWD_OVERRIDE="$SANDBOX/fwdstate" TMP_OUT="$T_PROBE_OUT" TMP_ERR="$T_PROBE_ERR" PROBE_CTL="$SANDBOX/fwdstate/ctl-dead" PROBE_THOST="10.0.0.5" PROBE_TPORT="443" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=1 FAKE_TARGET_RC=0 probe_run "$INJ1" "-")"
    if [[ "$got" == "RC=1 TUNNEL=down TARGET=unknown OUT=0 ERR=0" ]]; then
        inj_bad "10. 換成只問本機後 2d 仍綠——它沒在測真實封包"
    else
        if printf '%s' "$got" | grep -q 'TUNNEL=up'; then
            inj_ok "10. 換成只問本機後死隧道回報 up——2d 會紅（got [$got]）"
        else
            inj_bad "10. 行為變了但不是預期的假陽（got [$got]）——harness 問題"
        fi
    fi
fi
# 11. 目標 refused 當成不健康（併進 unreachable）→ 2b 必須紅。
#   四態下 refused 是唯一的「到達卻沒服務」證據，拿掉它等於沒服務永遠被說壞。
INJ2="$SANDBOX/mutant-probe-refused.sh"
python3 - "$MLP" "$INJ2" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'FWD_PROBE_TARGET="refused"'
assert src.count(old) == 1, "refused needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, 'FWD_PROBE_TARGET="unreachable"', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "11. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ2" 2>/dev/null; then
    inj_bad "11. 注入版語法錯誤——harness 問題"
else
    : > "$SANDBOX/argv.log"
    got="$(MLP_FILE="$INJ2" SSH_OVERRIDE="-" FWD_OVERRIDE="$SANDBOX/fwdstate" TMP_OUT="$T_PROBE_OUT" TMP_ERR="$T_PROBE_ERR" PROBE_CTL="$SANDBOX/fwdstate/ctl-a" PROBE_THOST="10.0.0.5" PROBE_TPORT="443" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=1 FAKE_TARGET_ERR="bash: connect: Connection refused" probe_run "$INJ2" "-")"
    if [[ "$got" == "RC=0 TUNNEL=up TARGET=refused OUT=0 ERR=0" ]]; then
        inj_bad "11. 把 refused 當不健康後 2b 仍綠——它沒在看沒服務的情況"
    else
        if printf '%s' "$got" | grep -q 'TARGET=unreachable'; then
            inj_ok "11. 把 refused 當不健康後沒服務被記成 unreachable——2b 會紅（got [$got]）"
        else
            inj_bad "11. 行為變了但不是預期的誤報（got [$got]）——harness 問題"
        fi
    fi
fi
# 12. spec 把第三方主機丟掉 → 1d 必須紅。
INJ3="$SANDBOX/mutant-spec.sh"
python3 - "$MLP" "$INJ3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'FWD_SPEC_THOST="${parts[1]}"'
assert src.count(old) == 1, "spec-thost needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, 'FWD_SPEC_THOST="127.0.0.1"', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "12. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ3" 2>/dev/null; then
    inj_bad "12. 注入版語法錯誤——harness 問題"
else
    got="$(SPEC="8080:192.168.0.50:80" MLP_FILE="$INJ3" FWD_OVERRIDE="$SANDBOX/fwdstate" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; if fwd_parse_spec "$SPEC" >/dev/null 2>&1; then printf "%s|%s|%s|%s" "$FWD_SPEC_BIND" "$FWD_SPEC_ENTRY" "$FWD_SPEC_THOST" "$FWD_SPEC_TPORT"; else printf "REJECT"; fi' 2>&1)"
    if [[ "$got" == "127.0.0.1|8080|192.168.0.50|80" ]]; then
        inj_bad "12. 丟掉第三方主機後 1d 仍綠——解析沒在看目標欄"
    else
        if [[ "$got" == "127.0.0.1|8080|127.0.0.1|80" ]]; then
            inj_ok "12. 丟掉第三方主機後靜默退回節點自己——1d 會紅（got [$got]）"
        else
            inj_bad "12. 行為變了但不是預期的退回（got [$got]）——harness 問題"
        fi
    fi
fi
# 13. Model 裡加一個輸出 → 8a 必須紅。
INJ4="$SANDBOX/mutant-model-printf.sh"
python3 - "$MLP" "$INJ4" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'fwd_records() {'
assert src.count(old) == 1, "records-fn needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, 'fwd_records() {\n    printf "x\\n"', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "13. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ4" 2>/dev/null; then
    inj_bad "13. 注入版語法錯誤——harness 問題"
else
    body="$(awk '/^fwd_records\(\)/{infn=1; next} infn && $0 == "}" {infn=0; next} infn {print}' "$INJ4")"
    code="$(printf '%s' "$body" | grep -vE '^[[:space:]]*#')"
    if printf '%s' "$code" | grep -qE '(^|[^A-Za-z0-9_])(printf|echo|fzf)([^A-Za-z0-9_]|$)'; then
        inj_ok "13. Model 多一個輸出後 8a 會紅（靜態）"
    else
        inj_bad "13. Model 多一個輸出後 8a 仍綠——分層檢查沒在看輸出"
    fi
    # 同一突變跑動態 8d：records stdout 必有位元組，動態亦須轉紅。
    rm -rf "$SANDBOX/dyn-inj"; mkdir -p "$SANDBOX/dyn-inj"
    touch "$SANDBOX/dyn-inj/fwd-127.0.0.1-8081"
    printf ' 1111 ssh -S %s -N -f -L 127.0.0.1:8081:127.0.0.1:8081 someone@127.0.0.1 mlp-fwd-node=n1\n' "$SANDBOX/dyn-inj/fwd-127.0.0.1-8081" > "$SANDBOX/dyn-inj-ps.txt"
    got="$(MLP_FILE="$INJ4" FWD_OVERRIDE="$SANDBOX/dyn-inj" FAKE_PS_FILE="$SANDBOX/dyn-inj-ps.txt" O1="$DYN_O1" E1="$DYN_E1" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; fwd_records >"$O1" 2>"$E1"; printf "O1=%s E1=%s" "$(wc -c < "$O1" | tr -d " ")" "$(wc -c < "$E1" | tr -d " ")"' 2>&1)"
    if [[ "$got" == "O1=0 E1=0" ]]; then
        inj_bad "13b. Model 多輸出後動態仍零位元組——動態檢查沒在看輸出"
    else
        inj_ok "13b. Model 多輸出後動態量到位元組（got [$got]）——動態亦會紅"
    fi
fi
# 14. helper 不帶啟動選項 → 4b 必須紅。
INJ5="$SANDBOX/mutant-ssh-noextra.sh"
python3 - "$SSH_LIB" "$INJ5" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '${SSH_EXTRA_OPTS[@]+"${SSH_EXTRA_OPTS[@]}"}'
assert src.count(old) == 1, "extra-opts needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, ':', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "14. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ5" 2>/dev/null; then
    inj_bad "14. 注入版語法錯誤——harness 問題"
else
    rm -rf "$SANDBOX/fwdstate"; mkdir -p "$SANDBOX/fwdstate"
    : > "$SANDBOX/argv.log"
    MLP_FILE="$MLP_FILE" SSH_OVERRIDE="$INJ5" FWD_OVERRIDE="$SANDBOX/fwdstate" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$SANDBOX/ps-none.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=1 FAKE_TARGET_ERR="bash: connect: Connection refused" FAKE_START_RC=0 HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; source "$SSH_OVERRIDE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; fwd_add mynode "8080" >/dev/null 2>&1' 2>&1
    if grep -qx -- '-L' "$SANDBOX/argv.log" 2>/dev/null; then
        inj_bad "14. 拿掉啟動選項後 4b 仍綠——它沒在確認 -L 真的送出去"
    else
        inj_ok "14. 拿掉啟動選項後 argv 裡沒有 -L——4b 會紅"
    fi
fi
# 15. fwd_add 的 resolve_gateway nodie 改回裸呼叫 → 7e 必須紅。
#   裸呼叫失敗即 die：子行程被 exit 殺掉（回 1、無存活標記），die 文字還進
#   了 stderr——7e 要求的「回 3、零輸出、活著」三項全破。
INJ6="$SANDBOX/mutant-resolve-nodie.sh"
python3 - "$MLP" "$INJ6" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'resolve_gateway nodie'
assert src.count(old) == 1, "nodie needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, 'resolve_gateway', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "15. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ6" 2>/dev/null; then
    inj_bad "15. 注入版語法錯誤——harness 問題"
elif grep -q 'resolve_gateway nodie' "$INJ6"; then
    inj_bad "15. 注入沒生效（nodie 還在）——harness 問題"
else
    rm -rf "$SANDBOX/fwdstate"; mkdir -p "$SANDBOX/fwdstate"
    MLP_FILE="$INJ6" FWD_OVERRIDE="$SANDBOX/fwdstate" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$SANDBOX/ps-none.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_GW_RC=1 FAKE_MASTER_RC=0 ADD_OUT="$SANDBOX/add15-out" ADD_ERR="$SANDBOX/add15-err" ADD_RES="$SANDBOX/add15-res" ADD_ALIVE="$SANDBOX/add15-alive" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; rm -f "$ADD_ALIVE" "$ADD_RES"; : > "$ADD_OUT"; : > "$ADD_ERR"; if fwd_add mynode "8080" >"$ADD_OUT" 2>"$ADD_ERR"; then rc=0; else rc=$?; fi; printf "RC=%s ERR=%s OUT=%s ERRB=%s" "$rc" "$FWD_ERR" "$(wc -c < "$ADD_OUT" | tr -d " ")" "$(wc -c < "$ADD_ERR" | tr -d " ")" > "$ADD_RES"; : > "$ADD_ALIVE"' 2>/dev/null
    childrc=$?
    got="$(cat "$SANDBOX/add15-res" 2>/dev/null || true)"
    if [[ "$childrc" -eq 0 && -f "$SANDBOX/add15-alive" && "$got" == "RC=3 ERR=resolve OUT=0 ERRB=0" ]]; then
        inj_bad "15. 改回裸呼叫後 7e 仍綠——resolve 失敗路徑沒被量到"
    else
        if [[ "$childrc" -eq 1 && ! -f "$SANDBOX/add15-alive" ]]; then
            inj_ok "15. 改回裸呼叫後子行程被 exit 殺掉（childrc=1、無存活）——7e 會紅"
        else
            inj_bad "15. 行為變了但不是預期的被殺掉（childrc=$childrc got [$got]）——harness 問題"
        fi
    fi
fi
# 16. unreachable 併回 refused（退回只看結束碼的舊寫法）→ 2g 必須紅。
#   舊寫法下 rc=1 只有一種答案：主機不存在與沒服務長得一模一樣，
#   前者被說成到達了——正是隧道段 -O check 覆轍的目標版。
INJ7="$SANDBOX/mutant-probe-rconly.sh"
python3 - "$MLP" "$INJ7" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    elif [[ "$target_err" == *"Connection refused"* ]]; then\n'
       '        FWD_PROBE_TARGET="refused"\n'
       '    else\n'
       '        FWD_PROBE_TARGET="unreachable"')
new = ('    else\n'
       '        FWD_PROBE_TARGET="refused"')
assert src.count(old) == 1, "rconly needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "16. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ7" 2>/dev/null; then
    inj_bad "16. 注入版語法錯誤——harness 問題"
else
    : > "$SANDBOX/argv.log"
    got="$(MLP_FILE="$INJ7" SSH_OVERRIDE="-" FWD_OVERRIDE="$SANDBOX/fwdstate" TMP_OUT="$T_PROBE_OUT" TMP_ERR="$T_PROBE_ERR" PROBE_CTL="$SANDBOX/fwdstate/ctl-a" PROBE_THOST="10.0.0.5" PROBE_TPORT="443" ARGV_LOG="$SANDBOX/argv.log" FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=1 FAKE_TARGET_ERR="bash: connect: No route to host" probe_run "$INJ7" "-")"
    if [[ "$got" == "RC=0 TUNNEL=up TARGET=unreachable OUT=0 ERR=0" ]]; then
        inj_bad "16. 退回只看結束碼後 2g 仍綠——分類沒在看 stderr"
    else
        if printf '%s' "$got" | grep -q 'TARGET=refused'; then
            inj_ok "16. 退回只看結束碼後沒路由被記成 refused——2g 會紅（got [$got]）"
        else
            inj_bad "16. 行為變了但不是預期的誤報（got [$got]）——harness 問題"
        fi
    fi
fi
# 22. 先上色再墊空白（舊寫法）→ 有色版欄位左移，17b 必須紅。
INJ8="$SANDBOX/mutant-color-first.sh"
python3 - "$MLP" "$INJ8" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('            printf -v bind_disp "%-${bindwidth}s" "${bind}*"\n'
       '            bind_disp="${C_RED}${bind_disp}${C_RESET}"')
new = ('            bind_disp="${C_RED}${bind}*${C_RESET}"\n'
       '            printf -v bind_disp "%-${bindwidth}s" "$bind_disp"')
assert src.count(old) == 1, "color-first needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "22. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ8" 2>/dev/null; then
    inj_bad "22. 注入版語法錯誤——harness 問題"
else
    got="$(color_case "$INJ8" "$SANDBOX/color-inj")"
    cmpgot="$(color_cmp "$SANDBOX/color-inj")"
    # **用 17b 真正的判準（color_geom）**，不要用 color_cmp 的整份 cmp。
    # 2026-09-26 之前這一條查的是 color_cmp 的結果，而 17b 的判準已經換成欄位
    # 幾何——那樣這條注入會替一個沒被改到的判準背書。用錯工具的注入比沒有注入
    # 更糟：它會讓人以為覆蓋到位。
    geominj="$(color_geom "$SANDBOX/color-inj/plain" "$SANDBOX/color-inj/stripped")"
    if printf '%s' "$geominj" | grep -q 'EQ_GEOM=1'; then
        inj_bad "22. 改回先上色後 17b 仍綠——欄寬斷言沒在看顏色（geom [$geominj]）"
    else
        if printf '%s' "$cmpgot" | grep -q 'HAS_COLOR=1'; then
            inj_ok "22. 改回先上色後 17b 的欄位幾何紅（geom [$geominj]）——上色破壞對齊仍被抓到"
        else
            inj_bad "22. 顏色沒開起來（cmp [$cmpgot]）——harness 問題"
        fi
    fi
fi
# 23. 重疊退回同埠一律擋（PM 第一版）→ 18d 必須紅。
INJ9="$SANDBOX/mutant-overlap-blockall.sh"
python3 - "$MLP" "$INJ9" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('        if [[ "$fbind" == "$bind" ]]; then\n'
       '            FWD_ERR="inuse"; FWD_CLASH="${fbind}:${fentry}"; return 4\n'
       '        fi\n'
       '        if fwd_is_wild "$fbind" || fwd_is_wild "$bind"; then\n'
       '            FWD_ERR="inuse"; FWD_CLASH="${fbind}:${fentry}"; return 4\n'
       '        fi')
new = '        FWD_ERR="inuse"; FWD_CLASH="${fbind}:${fentry}"; return 4'
assert src.count(old) == 1, "blockall needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "23. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ_RTT" 2>/dev/null; then
    inj_bad "23. 注入版語法錯誤——harness 問題"
else
    mc_live "fwd-127.0.0.1-2222"
    got="$(MLP_FILE="$INJ9" SPEC="192.168.0.224:2222:22" FWD_OVERRIDE="$MC_DIR" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$MC_PS" FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_GW_RC=0 FAKE_START_RC=0 FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=0 ARGV_LOG="$SANDBOX/mc-argv.log" OUTF="$MC_O" ERRF="$MC_E" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; if fwd_add mynode "$SPEC" >/dev/null 2>&1; then printf "RC=0"; else printf "RC=%s ERR=%s CLASH=%s" "$?" "$FWD_ERR" "$FWD_CLASH"; fi' 2>&1)"
    if [[ "$got" == "RC=0"* ]]; then
        inj_bad "23. 退回一律擋後 18d 仍綠——矩陣沒在看位址"
    else
        if [[ "$got" == "RC=4 ERR=inuse CLASH=127.0.0.1:2222" ]]; then
            inj_ok "23. 退回一律擋後兩異具體也被擋（got [$got]）——18d 會紅"
        else
            inj_bad "23. 行為變了但不是預期的一律擋（got [$got]）——harness 問題"
        fi
    fi
fi
# 24. 拿掉萬用判斷（fwd_is_wild 恆回假）→ 18b 與 18c 必須紅。
INJ10="$SANDBOX/mutant-nowild.sh"
python3 - "$MLP" "$INJ10" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('fwd_is_wild() {\n'
       '    case "$1" in\n'
       '        ""|"0.0.0.0"|"::") return 0 ;;\n'
       '        *) return 1 ;;\n'
       '    esac\n'
       '}')
new = ('fwd_is_wild() {\n'
       '    return 1\n'
       '}')
assert src.count(old) == 1, "nowild needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "24. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ10" 2>/dev/null; then
    inj_bad "24. 注入版語法錯誤——harness 問題"
else
    # 沙箱突變檔的 SCRIPT_DIR 指進沙箱，ssh.sh 須另行載入真正的（探測類突變
    # 到不了 ssh_via_gateway 才沒事；走到啟動的一律要補）。
    mc_live "fwd-0.0.0.0-2222"
    gotb="$(MLP_FILE="$INJ10" SPEC="2222" FWD_OVERRIDE="$MC_DIR" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$MC_PS" FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_GW_RC=0 FAKE_START_RC=0 FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=0 ARGV_LOG="$SANDBOX/mc-argv.log" SSH_REAL="$SSH_FILE" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; source "$SSH_REAL" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; if fwd_add mynode "$SPEC" >/dev/null 2>&1; then printf "RC=0"; else printf "RC=%s ERR=%s" "$?" "$FWD_ERR"; fi' 2>&1)"
    mc_live "fwd-127.0.0.1-2222"
    gotc="$(MLP_FILE="$INJ10" SPEC="0.0.0.0:2222:22" FWD_OVERRIDE="$MC_DIR" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" FAKE_PS_FILE="$MC_PS" FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_GW_RC=0 FAKE_START_RC=0 FAKE_TUNNEL_RC=0 FAKE_TARGET_RC=0 ARGV_LOG="$SANDBOX/mc-argv.log" SSH_REAL="$SSH_FILE" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; source "$SSH_REAL" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; POOL_RESOLVE="$POOL_OVERRIDE"; if fwd_add mynode "$SPEC" >/dev/null 2>&1; then printf "RC=0"; else printf "RC=%s ERR=%s" "$?" "$FWD_ERR"; fi' 2>&1)"
    if [[ "$gotb" == "RC=4"* && "$gotc" == "RC=4"* ]]; then
        inj_bad "24. 拿掉萬用後 18b/18c 仍綠——矩陣沒在看萬用"
    else
        if [[ "$gotb" == "RC=0" && "$gotc" == "RC=0" ]]; then
            inj_ok "24. 拿掉萬用後兩格都放行（got [$gotb/$gotc]）——18b/18c 會紅"
        else
            inj_bad "24. 行為變了但不是預期的雙放行（got [$gotb/$gotc]）——harness 問題"
        fi
    fi
fi
# 25. rm 裸埠改挑第一筆 → 19a 必須紅（含「有轉發被刪掉」）。
INJ11="$SANDBOX/mutant-rm-first.sh"
python3 - "$MLP" "$INJ11" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '            *) FWD_ERR="ambiguous"; return 4 ;;'
assert src.count(old) == 1, "ambiguous needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, '            *) : ;;', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "25. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ11" 2>/dev/null; then
    inj_bad "25. 注入版語法錯誤——harness 問題"
else
    rm -rf "$SANDBOX/rm-inj"; mkdir -p "$SANDBOX/rm-inj"
    touch "$SANDBOX/rm-inj/fwd-127.0.0.1-2222" "$SANDBOX/rm-inj/fwd-0.0.0.0-2222"
    MLP_FILE="$INJ11" FWD_OVERRIDE="$SANDBOX/rm-inj" ARGV_LOG="$SANDBOX/argv.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; if fwd_remove 2222 >/dev/null 2>&1; then printf "RC=0"; else printf "RC=%s ERR=%s" "$?" "$FWD_ERR"; fi' 2>&1 > "$SANDBOX/rm-inj-got"
    got="$(cat "$SANDBOX/rm-inj-got")"
    left=0
    [[ -e "$SANDBOX/rm-inj/fwd-127.0.0.1-2222" ]] && left=$((left+1))
    [[ -e "$SANDBOX/rm-inj/fwd-0.0.0.0-2222" ]] && left=$((left+1))
    if [[ "$got" == "RC=4 ERR=ambiguous" && "$left" -eq 2 ]]; then
        inj_bad "25. 改挑第一筆後 19a 仍綠——拒絕邏輯沒被量到"
    else
        if [[ "$got" == "RC=0" && "$left" -eq 1 ]]; then
            inj_ok "25. 改挑第一筆後靜默刪掉一條（got [$got] 剩 $left 條）——19a 會紅"
        else
            inj_bad "25. 行為變了但不是預期的靜默刪（got [$got] 剩 $left 條）——harness 問題"
        fi
    fi
fi
# 26. rm 退回只吃裸埠 → 20a 必須紅。
INJ12="$SANDBOX/mutant-rm-bare.sh"
python3 - "$MLP" "$INJ12" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('        *:*)\n'
       '            bind="${arg%:*}"\n'
       '            entry="${arg##*:}"\n'
       '            ;;\n')
assert src.count(old) == 1, "bindport needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, '', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "26. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ12" 2>/dev/null; then
    inj_bad "26. 注入版語法錯誤——harness 問題"
else
    rm -rf "$SANDBOX/rm-inj2"; mkdir -p "$SANDBOX/rm-inj2"
    touch "$SANDBOX/rm-inj2/fwd-0.0.0.0-2222" "$SANDBOX/rm-inj2/fwd-127.0.0.1-2222"
    got="$(MLP_FILE="$INJ12" FWD_OVERRIDE="$SANDBOX/rm-inj2" ARGV_LOG="$SANDBOX/argv.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; FWD_DIR="$FWD_OVERRIDE"; if fwd_remove "0.0.0.0:2222" >/dev/null 2>&1; then printf "RC=0 RM=%s" "$FWD_RM_CTL"; else printf "RC=%s ERR=%s" "$?" "$FWD_ERR"; fi' 2>&1)"
    if [[ "$got" == "RC=0 RM=$SANDBOX/rm-inj2/fwd-0.0.0.0-2222" ]]; then
        inj_bad "26. 退回裸埠後 20a 仍綠——bind 切分沒被量到"
    else
        if [[ "$got" == "RC=2 ERR=spec" ]]; then
            inj_ok "26. 退回裸埠後 bind:port 變非法（got [$got]）——20a 會紅"
        else
            inj_bad "26. 行為變了但不是預期的拒收（got [$got]）——harness 問題"
        fi
    fi
fi

echo
# 分節失敗數：22 節（repair）是紅燈批次的預期紅，0-21 節必須維持全綠。
# 只印總數會讓「預期紅」與「回歸」混在一起看不出來。
rp22_fail=$((fail - pre22_fail))
rp22_pass=$((pass - pre22_pass))
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' "$pass" "$fail" "$injpass" "$injfail"
printf '  其中 0-21 節：passed %d / failed %d（回歸守門，必須全綠）\n' "$pre22_pass" "$pre22_fail"
printf '       22 節 repair：passed %d / failed %d（紅燈批次的預期紅；impl 落地後 failed 應為 0）\n' "$rp22_pass" "$rp22_fail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
