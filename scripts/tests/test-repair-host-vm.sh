#!/usr/bin/env bash
# test-repair-host-vm.sh — VM 端的家人維修承載機（issue #6 tasks 5.1；design
# D5 後半／D7／D8，spec「維修承載機不持有 GitHub 權杖」「失敗時家人看得懂該
# 做什麼」）。
#
# 在防什麼（真線會咬人的那一種）：
#   task 4 已經有「Mac 端登錄指令產出開機資料」的紅測試
#   （test-register-repair-host.sh）。開機資料裡「task 5 加東西」的那個洞
#   （profiles/provider/repair/user-data.tmpl 檔頭寫的「---- task 5 adds its
#   pieces here ----」）目前完全是空的：VM 上沒有東西會擋 GitHub 權杖
#   （D5 後半）、沒有東西會去問 Gateway IP（D2）、也沒有東西會把重試節奏放慢
#   到 fail2ban 的觀察窗以下（D7）。這支測試就是在定義那個洞裡要放什麼，並
#   且證明「現在完全沒有」。
#
# ==============================================================================
# 這支測試定義的介面（impl 落地時照這個；要改介面就同步改本檔）
# ==============================================================================
#
# 安裝位置（VM 上，全部屬於開機資料的 @@LOGIN_USER@@，即 profile.json 的
# login_user="repair"；與既有慣例對齊：pool-tunnel 自己認的狀態目錄就是
# ${HOME}/.mylinuxpool，install.sh 把既有工具裝進 ${HOME}/.mylinuxpool/bin/，
# 這裡沿用同一個目錄，不另開一個 /opt）：
#
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/pool-tunnel           既有檔案，task 5 原樣複製過去
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/tunnel-identity.sh    既有檔案，task 5 原樣複製過去
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/repair-token-guard    NEW — D5 後半
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/repair-gateway-fetch  NEW — D2 取值半
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/repair-gateway-report NEW — D2 回報半
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/repair-tunnel-launch  NEW — D5 守門 + D7 重試節奏
#
# sudo（2026-09-29 使用者決定，tasks 8b.4）：`repair` 帳號要免密碼 sudo。
# 做法：user-data.tmpl 的 write_files 加一個 /etc/sudoers.d/ 底下的檔案
# （路徑名由 impl 決定；本測試只認前綴 /etc/sudoers.d/），內容是一條
# NOPASSWD 規則，principal **只給登入使用者**（@@LOGIN_USER@@，渲染後是
# profile.json 的 login_user="repair"）——不是 ALL、不是群組、不是別的帳號。
# 背景（OUT-live-repair.md 意外 6）：live 驗收時 repair 沒有 root，
# sudo 要密碼而密碼是鎖住的，維修時改網路設定／抓封包都做不到。
# 這一節驗的就是模板（對現碼紅：模板還沒有任何 sudo 設定）。
#
# systemd（**system unit 加 User=**，不是 repo 給一般 provider 用的 user unit
# 加 linger——這是 spike 定案的做法，OUT-spike-repair.md §2「unit 是 system
# unit 加 User=repair，比 user unit 加 linger 在 cloud-init 裡簡單」）：
#
#   /etc/systemd/system/mlp-d2-fetch.service
#       Type=oneshot; User=@@LOGIN_USER@@
#       ExecStart=.../repair-gateway-fetch
#       Before=mlp-tunnel-repair.service（隧道啟動前先試著把 Gateway IP 拿到）
#   /etc/systemd/system/mlp-tunnel-repair.service
#       User=@@LOGIN_USER@@
#       EnvironmentFile=/etc/mlp/tunnel.env         （現有的靜態模式輸入，含
#                                                      placeholder；D3/D4 已交）
#       EnvironmentFile=-/run/mlp/gateway.env        （D2 取到值時覆蓋——同一
#                                                      個變數名在後面的檔案贏，
#                                                      這是 systemd 的既有語意，
#                                                      不需要額外程式碼）
#       ExecStart=.../repair-tunnel-launch
#       After=mlp-d2-fetch.service
#
#   runcmd 在既有的 `systemctl daemon-reload && systemctl restart ssh.socket`
#   之後，再加一行 enable 這兩個 system unit。
#
# ---- repair-token-guard（D5 後半：VM 上出現權杖就拒絕啟動隧道）------------
#   呼叫：repair-token-guard（無參數）
#   檢查：
#     * 檔案 ${HOME}/.mylinuxpool/gh_token 存在（不管內容）
#     * 環境變數 GH_TOKEN / GH_POOL_TOKEN / GITHUB_TOKEN 任一非空
#   命中任一項 → exit 非 0，stderr 印一行說明原因（**必須**提到 "token"
#   這個詞；檔案命中時額外提到檔名，環境變數命中時額外提到變數名——因為 spec
#   要求「記錄原因」，本測試只驗訊息的字面內容，不驗訊息格式）。
#   都沒中 → exit 0，不需要輸出任何東西。
#
# ---- repair-gateway-fetch（D2 取值半）--------------------------------------
#   呼叫：repair-gateway-fetch（無參數）
#   環境：MLP_D2_HOST（預設 10.0.2.2，NAT 下主機的位址——spike D2(c)）、
#         MLP_D2_PORT（預設 18080，spike 用的埠）、
#         MLP_D2_TIMEOUT（預設 3，秒）、
#         MLP_GATEWAY_ENV_FILE（預設 /run/mlp/gateway.env——D3/D4 已交的
#         /etc/mlp/tunnel.env 之外「疊加」的那個檔）
#   行為：GET http://${MLP_D2_HOST}:${MLP_D2_PORT}/gw
#     * 成功且回應非空 → 原子寫入（temp + mv，仿 pool-tunnel 自己的
#       publish_gateway）一行 `POOL_GATEWAY_HOST=<ip>` 到 MLP_GATEWAY_ENV_FILE，
#       exit 0
#     * 失敗（連不上／逾時／空回應）→ **不動** MLP_GATEWAY_ENV_FILE（不寫、
#       不清空既有內容），stderr 說明原因，exit 1。**這不是 fatal**：
#       mlp-d2-fetch.service 只用 Before=，不是 Requires=，隧道 unit 照樣會
#       啟動，讀到的是 /etc/mlp/tunnel.env 裡的 placeholder
#       （gateway-ip-set-at-launch.invalid，D4 已交），對那個位址撥號會在
#       DNS 這一步就明確失敗——這就是 design 對齊的「明確失敗」，不是猜一個
#       能連的預設值。
#
# ---- repair-gateway-report（D2 回報半）-------------------------------------
#   呼叫：repair-gateway-report <up|down>
#   環境：同 MLP_D2_HOST/MLP_D2_PORT/MLP_D2_TIMEOUT
#   行為：POST http://${MLP_D2_HOST}:${MLP_D2_PORT}/state，body `tunnel=<arg>`。
#   任何網路結果（沒有啟動器、逾時、HTTP 錯誤）都 exit 0（純粹是給啟動器顯示
#   狀態用的診斷通道，失敗不能拖累隧道）；唯一的例外是呼叫方自己傳錯參數
#   （不是 up/down）——那是呼叫方的 bug，不是網路狀況，exit 2。
#
# ---- repair-tunnel-launch（D5 守門 + D7 重試節奏；unit 的 ExecStart）-----
#   呼叫：repair-tunnel-launch（無參數；讀環境裡的 POOL_NODE_NAME /
#         POOL_GATEWAY_HOST / POOL_GATEWAY_USER / POOL_GATEWAY_PORT /
#         POOL_GATEWAY_SSH_PORT，跟 pool-tunnel 靜態模式一樣）
#   行為：
#     1. 先呼叫同目錄的 repair-token-guard；guard 拒絕 → **完全不呼叫
#        pool-tunnel**，exit 非 0（D5：權杖存在時隧道不啟動）
#     2. guard 放行 → 迴圈呼叫 `pool-tunnel --once`（同目錄或 PATH 上那份）：
#        * 成功（rc 0）→ 呼叫 repair-gateway-report up，接手 pool-tunnel 自己
#          的 control_alive/health_check 持續監看（不 exit 0）；連線掉了才
#          report down、回到上面的迴圈再撥一次。**不會**在成功當下就退出讓
#          systemd 的 Restart 接手——若 ExecStart 在成功後 exit 0，
#          `Type=simple` 的 unit 會被視為完成而停止，KillMode=control-group
#          會把留在同一個 cgroup 裡的 ssh master 一併殺掉，隧道等於「一連上
#          就被收掉」。只有收到 SIGTERM/SIGINT（unit 被停止）才會 exit 0。
#        * 失敗，且輸出像是 Gateway 拒絕了這把金鑰（ssh 真正被拒時印的標準
#          訊息 `Permission denied`——這是 sshd／fail2ban 場景下 ssh 會印的
#          字面，不是本測試發明的格式）→ 這是 D7 講的「連續被拒」：重試間隔
#          必須拉長到「任何 10 分鐘的滑動視窗內嘗試次數 < 5」（fail2ban 預設
#          10 分鐘內 5 次失敗封 10 分鐘）。**確切的退避數字/演算法由實作決定
#          並寫進 repair-tunnel-launch 自己的註解**（design D7 原文）——本測試
#          只驗這個「視窗內 < 5 次」的結果，不綁實作用了哪個數列
#        * 失敗，且輸出不像是被拒（例如網路不通）→ 不在本測試範圍（design 沒
#          有要求非認證失敗也要放慢，那樣反而拖慢真正的網路恢復）
#
# ---- 可測試性覆寫（只給這支測試用，不是給正式部署用）----------------------
#   MLP_REPAIR_VM_DIR — 覆寫上面四支新腳本所在的目錄（預設
#   profiles/provider/repair）。impl 開發中想先在別的地方驗證這支測試會不會
#   轉綠，不用真的把檔案放進 profiles/provider/repair/，可以：
#     MLP_REPAIR_VM_DIR=/path/to/wip bash scripts/tests/test-repair-host-vm.sh
#
# ==============================================================================
# 要驗的（對應工單 1-5）
# ==============================================================================
#   1. user-data 的性質：沒有 packages:；sshd 只聽 loopback、
#      PasswordAuthentication no；runcmd 重啟 ssh.socket；屬於新使用者的檔案
#      有 defer: true；隧道 unit 是 system unit 加 User=；不含 GitHub 權杖字面；
#      不啟用 pool-sync／pool-resolve；新增的四支腳本路徑真的被模板引用到
#      （1a-1d/1f 對現碼綠——這些是 task 4 已經交的性質；1e/1g 對現碼紅——
#      task 5 還沒加）
#   2. 權杖守衛：token 檔或 GH_*/GH_POOL_TOKEN 環境 → 守衛非 0、隧道不啟動、
#      記錄原因；沒有 → 放行（對現碼紅：repair-token-guard 不存在）
#   3. D2 取值／回報：假服務回 IP → 隧道撥號用那個 IP；服務不在 → 不覆寫，
#      隧道撥號用開機資料裡的 placeholder（明確失敗，DNS 解不出來）；隧道起來
#      後 POST 狀態（對現碼紅：repair-gateway-fetch/report 不存在）
#   4. D7 重試節奏：模擬連續被拒（假 ssh 每次都回 `Permission denied`）→
#      用模擬時間（絕不真的 sleep）跑出至少 10 分鐘份的重試，驗證任何 600 秒
#      滑動視窗內的嘗試次數 < 5（對現碼紅：repair-tunnel-launch 不存在）
#   5. 回歸：非維修模式的 pool-tunnel 直接跑（不經過上面任何新東西）時，它
#      自己的退避數列（2,4,8,16,30,30,...）完全不變（對現碼綠——這是既有
#      pool-tunnel 的行為，task 5 不該去動它，D7 只加在維修模式專用的
#      repair-tunnel-launch 裡）
#
# ---- 正對照（量到 0 不算證據）-----------------------------------------------
#   * §3/§4/§5：假 ssh／假 curl 真的被呼叫過（log 非空）才信後面的斷言
#   * §2：guard 拒絕的兩種案例分別用「檔案存在」與「環境變數非空」單獨驗證，
#     並且在呼叫 guard 之前，測試自己先用 [[ -f ]] 確認 fixture 真的落在
#     guard 文件宣稱的路徑上（不是測試自己放錯地方、guard 其實從沒看見它）
#   * §4c：視窗計數器（count_max_window）先拿一組已知會違規的序列（pool-tunnel
#     自己原生的快速退避數列，套進同一個計數器）自我驗證，確認它真的抓得到
#     違規，不是一個永遠回答「沒問題」的空殼
#
# ---- 注入（有真的原始碼可以動刀的地方才做；沒有的地方用 inj_skip 說明）----
#   * §1：對 user-data.tmpl 的複本動刀（拿掉 defer: true、把 ListenAddress
#     改成 0.0.0.0、加一行 pool-sync 啟用）→ 對應的 1c/1b/1f 必須在複本上翻紅
#   * §5：對 pool-tunnel 的複本動刀（把 next_backoff 的封頂拿掉，改成一路
#     倍增）→ 5b 的數列比對必須在複本上翻紅
#   * §1e/1g、§2-4：subject 還不存在，沒有原始碼可以動刀——現碼本身的紅就是
#     這些檢查「有在量」的證據，注入欄位記 inj_skip 並說明理由（跟
#     test-register-repair-host.sh 對 §7 的處理方式一致）
#
# ==============================================================================
# 這支測試看不到什麼（誠實記在這裡）
# ==============================================================================
#   * 不驗 systemd 的 EnvironmentFile 疊加語意本身（那是 systemd 的既有行為，
#     不是這輪要測的程式）：§3b 用「shell 依序 source 兩個檔案，後面的贏」
#     模擬同樣的疊加順序，不是真的起一個 systemd unit。
#   * 不驗「被拒」的判斷方式一定要是字串比對 `Permission denied`——那是
#     design 留給實作自己決定並寫註解的事。本測試的假 ssh 印的是 ssh 真的
#     被 Gateway 拒絕時會印的標準訊息，只是提供一個「像真的」的輸入；只要
#     repair-tunnel-launch 對這個輸入的最終行為滿足「10 分鐘視窗 < 5 次」，
#     用什麼判斷方式本測試不管。
#   * D7 只驗「連續被拒」這一種失敗模式的節奏；網路不通、DNS 失敗等其他失敗
#     模式的重試節奏不在本輪範圍（design 沒有要求）。
#   * §4 的「10 分鐘」是模擬時間（用假 sleep 推進一個虛擬時鐘），不是真的
#     驗證 repair-tunnel-launch 在真實掛鐘時間下的行為；一個讀虛擬時鐘以外
#     來源計時的實作（例如真的呼叫 date +%s）會被這裡的假時鐘騙過去，但那
#     樣的實作在真機上仍然是用真掛鐘算，行為應該一致——這是模擬測試的通性
#     限制，不是這支測試獨有的洞。
#   * 不連網、不開 VM、不驗 cloud-init 對 user-data.tmpl 的真正解析（那是
#     spike 與真機驗收的事，OUT-spike-repair.md 已經做過一次）。
#   * §1 的「不啟用 pool-sync／pool-resolve」只驗模板裡沒有相關字串；如果
#     task 5 用別的名字包裝同一件事（例如自己重寫一個會打 GitHub 的腳本卻
#     取名 foo），這個字串比對看不到。
#   * repair-gateway-fetch「服務不在時不覆寫檔案」只驗到「這次呼叫不寫」，
#     不驗併發呼叫、半寫入等 race（跟這個 repo 其他測試的一貫限制一致）。
#   * token 掃描（guard）只認檔案存在與否、環境變數是否非空；不掃「權杖被
#     編碼或藏在其他檔案」——這跟 register-repair-host 自己那半的已知限制
#     （t4 報告 §5）是同一種洞，寫在這裡是因為 VM 這半也一樣。
#   * sudo 那一節（1h/1h2）只驗模板裡「有沒有一條 principal 為
#     @@LOGIN_USER@@ 的 NOPASSWD 規則」；不驗 visudo 的語法（那是部署時
#     cloud-init／sudo 自己的事）、不驗檔案的權限位（0440 等）與 owner、
#     也不驗規則的指令範圍（ALL=(ALL) vs 收窄的 Cmnd 清單）——使用者的
#     決定原文是「給免密碼 sudo」，範圍留給 impl。
#
# 全離線：ssh/curl/sleep 走 PATH shim；不連網、不開 VM；bash 3.2 相容。
# Run: scripts/tests/test-repair-host-vm.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

PTUNNEL="shared-configs/pool-runtime/files/pool-tunnel"
TIDENT="shared-configs/pool-runtime/files/tunnel-identity.sh"
# MLP_REPAIR_TEMPLATE：同 MLP_REPAIR_VM_DIR 的自我驗證用途——指向一份「假裝
# task 5 已經落地」的模板複本，不用真的改 profiles/provider/repair/。
TEMPLATE="${MLP_REPAIR_TEMPLATE:-profiles/provider/repair/user-data.tmpl}"
VM_DIR="${MLP_REPAIR_VM_DIR:-profiles/provider/repair}"
GUARD="${VM_DIR}/repair-token-guard"
FETCH="${VM_DIR}/repair-gateway-fetch"
REPORT="${VM_DIR}/repair-gateway-report"
LAUNCH="${VM_DIR}/repair-tunnel-launch"

for tool in python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: ${tool} not found on PATH" >&2; exit 1; }
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-repair-vm.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
mkdir -p "$SHIMS" "$HOME_DIR/.ssh" "$HOME_DIR/.mylinuxpool"
printf 'DUMMY\n' > "$HOME_DIR/.ssh/id_tunnel"
chmod 600 "$HOME_DIR/.ssh/id_tunnel"
cp "$REPO_ROOT/$TIDENT" "$SANDBOX/tunnel-identity.sh"

pass=0; fail=0; injpass=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }
inj_skip() { printf '  --    (注入略) %s\n' "$1"; }

# ---- 假 ssh：記 argv；依 SSH_STDERR_MODE 決定 stderr 內容 -------------------
# 撥號（-M -S ...）一律失敗；同時若 MLP_TEST_CLOCK 存在，把撥號當下的虛擬時鐘
# 值記到 MLP_TEST_DIAL_TIMES（§4/§5 用來算滑動視窗）。
cat > "$SHIMS/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SSH_LOG:-/dev/null}"
case "$*" in
    *"-M -S"*)
        if [[ -n "${MLP_TEST_DIAL_TIMES:-}" ]]; then
            cur=0
            [[ -f "${MLP_TEST_CLOCK:-}" ]] && cur="$(cat "$MLP_TEST_CLOCK" 2>/dev/null || echo 0)"
            printf '%s\n' "$cur" >> "$MLP_TEST_DIAL_TIMES"
        fi
        printf '%s\n' "${MLP_TEST_SSH_STDERR:-fake ssh: connection refused}" >&2
        exit 255
        ;;
    *"-O check"*) exit 255 ;;
    *"-O exit"*)  exit 0 ;;
esac
printf '%s\n' "${MLP_TEST_SSH_STDERR:-fake ssh: connection refused}" >&2
exit 255
FAKE

# ---- 假 sleep：從不真的睡；把秒數記到 log，推進一個虛擬時鐘檔案。時鐘超過
# MLP_TEST_CLOCK_CAP 時，送 TERM 給呼叫端（模擬「已經跑了 N 分鐘」，不必真的
# 等），呼叫端（pool-tunnel／repair-tunnel-launch）都會 trap TERM 乾淨結束。
cat > "$SHIMS/sleep" <<'FAKE'
#!/usr/bin/env bash
dur="${1:-0}"; dur="${dur%%.*}"; [[ -z "$dur" ]] && dur=0
printf '%s\n' "$dur" >> "${MLP_TEST_SLEEP_LOG:-/dev/null}"
if [[ -n "${MLP_TEST_CLOCK:-}" ]]; then
    cur=0
    [[ -f "$MLP_TEST_CLOCK" ]] && cur="$(cat "$MLP_TEST_CLOCK" 2>/dev/null || echo 0)"
    new=$((cur + dur))
    printf '%s\n' "$new" > "$MLP_TEST_CLOCK"
    cap="${MLP_TEST_CLOCK_CAP:-0}"
    if [[ "$cap" -gt 0 && "$new" -ge "$cap" ]]; then
        kill -TERM "$PPID" 2>/dev/null || true
    fi
fi
exit 0
FAKE

# ---- 假 curl：記 argv；依 URL 是 /gw 還是 /state 分流，依 FAKE_D2_MODE 決定
# /gw 的行為（ip=回一個 IP；down=模擬服務不在，exit 7）。/state 一律 exit 0
# （report 是盡力而為）。
cat > "$SHIMS/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:-/dev/null}"
if [[ ! -t 0 ]]; then cat > "${CURL_STDIN:-/dev/null}" 2>/dev/null; fi
case "$*" in
    *"/gw"*)
        if [[ "${FAKE_D2_MODE:-ip}" == "ip" ]]; then
            printf '%s' "${FAKE_D2_IP:-198.51.100.7}"
            exit 0
        else
            echo "curl: (7) Failed to connect to ${MLP_D2_HOST:-10.0.2.2} port ${MLP_D2_PORT:-18080}" >&2
            exit 7
        fi
        ;;
    *"/state"*) exit 0 ;;
    *) exit 22 ;;
esac
FAKE
chmod +x "$SHIMS/ssh" "$SHIMS/sleep" "$SHIMS/curl"

# count_max_window <timestamps-file> <window-seconds>
#   印出「任何一個長度 window-seconds 的視窗內，最多落了幾個時間戳」。
#   [t, t+window] 兩端都算在內（跟 fail2ban 的「10 分鐘內」同一種算法：寧可
#   算寬一點，不要因為端點沒算到而放過一個實際上會被封鎖的節奏）。
count_max_window() {
    local file="$1" window="$2"
    if [[ ! -s "$file" ]]; then echo 0; return; fi
    python3 - "$file" "$window" <<'PY'
import sys
times = sorted(int(l) for l in open(sys.argv[1]) if l.strip())
window = int(sys.argv[2])
best = 0
for t0 in times:
    c = sum(1 for t in times if t0 <= t <= t0 + window)
    best = max(best, c)
print(best)
PY
}

# ---- user-data.tmpl 的性質：每個 prop_* 對「一個模板檔案路徑」回真/假 ------
prop_no_packages()          { ! grep -qE '^packages:' "$1" 2>/dev/null; }
prop_sshd_loopback()        { grep -q 'ListenAddress 127.0.0.1' "$1" 2>/dev/null \
                               && grep -q 'ListenAddress ::1' "$1" 2>/dev/null \
                               && grep -q 'PasswordAuthentication no' "$1" 2>/dev/null; }
prop_runcmd_restart_socket() { grep -q 'restart ssh.socket' "$1" 2>/dev/null; }
# 「有任何一個 defer: true」不夠：一份模板可以在隧道私鑰那塊拿掉 defer、卻在
# 別的檔案留一個合法的 defer，這樣量整份檔案「有沒有 defer」還是會綠（review
# OUT-review-repair-t5.md §2 抓到的洞——這曾經是「defer 只能有一個」的形狀
# 巧合在撐綠，不是真的在量私鑰有沒有 defer）。改成只認「隧道私鑰那一塊」：
# 以 `path:` 那行含 id_tunnel（渲染後的真實路徑，tunnel-identity.sh 的單一
# 定義）或 TUNNEL_KEY_PATH（本檔測的是未渲染模板，那一行字面是
# @@TUNNEL_KEY_PATH@@ 這個 placeholder）為錨，區塊往下延伸到下一個
# `- path:` 或 write_files 區段結束（下一個沒有縮排的頂層 key，例如
# runcmd:）為止；defer: true 必須落在這個區塊裡面才算數。這樣「私鑰掉
# defer、別的檔案留 defer」不再誤判成綠，「模板多一個合法 deferred 檔案」
# 也不再誤判 1x 的注入失效。
prop_key_defer_true() {
    awk '
        BEGIN { inkey = 0; keyseen = 0; deferred = 0 }
        /^[[:space:]]*-[[:space:]]*path:/ {
            inkey = ($0 ~ /id_tunnel|TUNNEL_KEY_PATH/) ? 1 : 0
            if (inkey) keyseen = 1
            next
        }
        /^[^[:space:]]/ { inkey = 0 }
        inkey && /^[[:space:]]*defer:[[:space:]]*true[[:space:]]*$/ { deferred = 1 }
        END { exit (keyseen && deferred) ? 0 : 1 }
    ' "$1" 2>/dev/null
}
prop_no_sync_resolve()      { ! grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -qE 'pool-sync|pool-resolve'; }
prop_no_token_literal()     { ! grep -Eq '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})' "$1" 2>/dev/null; }
prop_tunnel_unit_system_user() {
    grep -q '/etc/systemd/system/mlp-tunnel-repair.service' "$1" 2>/dev/null \
    && grep -q 'User=@@LOGIN_USER@@' "$1" 2>/dev/null
}
prop_new_scripts_referenced() {
    grep -q '.mylinuxpool/bin/repair-token-guard' "$1" 2>/dev/null \
    && grep -q '.mylinuxpool/bin/repair-gateway-fetch' "$1" 2>/dev/null \
    && grep -q '.mylinuxpool/bin/repair-gateway-report' "$1" 2>/dev/null \
    && grep -q '.mylinuxpool/bin/repair-tunnel-launch' "$1" 2>/dev/null
}

# ---- sudo 的性質（2026-09-29 決定，tasks 8b.4） -----------------------------
# 只認 write_files 裡一個 path 以 /etc/sudoers.d/ 開頭的檔案，並且它的
# content 區塊（縮排比 path 那行深、到下一個 - path: 或頂層 key 為止）含一條
# NOPASSWD 規則、principal 是 @@LOGIN_USER@@（渲染後 repair）。
# 不看具體檔名（impl 決定），不看註解裡的說明——只認實際寫進去的 content。
# 為什麼要「只給該帳號」：sudoers 的 principal 若寫成 ALL，等於任何本機
# 使用者（或未來任何被建立的帳號）都有免密碼 root；NOPASSWD 的 blast radius
# 必須跟「這一個登入使用者」對齐（AI 也會用這個帳號，這是使用者的知情決定）。
prop_sudoers_nopasswd() {
    awk '
        BEGIN { insudo = 0; seen = 0; nopass = 0 }
        /^[[:space:]]*-[[:space:]]*path:[[:space:]]*\/etc\/sudoers\.d\// {
            insudo = 1; seen = 1
            # path 行本身也算這個區塊的一部分
        }
        /^[[:space:]]*-[[:space:]]*path:/ && $0 !~ /\/etc\/sudoers\.d\// { insudo = 0 }
        /^[^[:space:]]/ { insudo = 0 }
        insudo && /NOPASSWD/ { nopass = 1 }
        END { exit (seen && nopass) ? 0 : 1 }
    ' "$1" 2>/dev/null
}
# principal 只給登入使用者：sudoers 區塊裡的規則行（含 NOPASSWD 的那些），
# 行首第一個欄位（principal）必須是 @@LOGIN_USER@@，且不得出現 principal 為
# 裸 ALL 的 NOPASSWD 規則。`@@LOGIN_USER@@ ALL=(ALL) NOPASSWD: ALL` 合法
# （principal 就是那一個使用者）；`ALL ALL=(ALL) NOPASSWD: ALL` 是要擋的
# 形狀（任何本機帳號都能免密碼 root，例如未來多開一個低權限帳號）。
prop_sudoers_login_user_only() {
    awk '
        BEGIN { insudo = 0; seen = 0; userline = 0; bad_all = 0 }
        /^[[:space:]]*-[[:space:]]*path:[[:space:]]*\/etc\/sudoers\.d\// { insudo = 1; seen = 1 }
        /^[[:space:]]*-[[:space:]]*path:/ && $0 !~ /\/etc\/sudoers\.d\// { insudo = 0 }
        /^[^[:space:]]/ { insudo = 0 }
        insudo && /NOPASSWD/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]].*$/, "", line)
            if (line == "@@LOGIN_USER@@") userline = 1
            if (line == "ALL") bad_all = 1
        }
        END { exit (seen && userline && !bad_all) ? 0 : 1 }
    ' "$1" 2>/dev/null
}

echo "=== 0. 先決條件 ==="
if [[ -f "$REPO_ROOT/$PTUNNEL" ]]; then
    ok "0a. ${PTUNNEL} 存在（§5 回歸的對象）"
else
    bad "0a. ${PTUNNEL} 不存在——§5 無法驗證"
fi
TMPL_PATH="$REPO_ROOT/$TEMPLATE"; [[ -f "$TMPL_PATH" ]] || TMPL_PATH="$TEMPLATE"
if [[ -f "$TMPL_PATH" ]]; then
    ok "0b. ${TEMPLATE} 存在（§1 的對象）"
else
    bad "0b. ${TEMPLATE} 不存在——§1 無法驗證"
fi
for f in "$GUARD" "$FETCH" "$REPORT" "$LAUNCH"; do
    if [[ ! -f "$REPO_ROOT/$f" && ! -f "$f" ]]; then
        echo "test-repair-host-vm: ${f} does not exist yet — this test defines its behaviour (interface in the file header); the RED lines below are expected" >&2
    fi
done

echo
echo "=== 1. user-data 的性質 ==="
if [[ -f "$TMPL_PATH" ]]; then
    prop_no_packages "$TMPL_PATH"          && ok "1a. 沒有 packages:"          || bad "1a. 出現 packages: —— 家人的網路可能連不上 apt 鏡像"
    prop_sshd_loopback "$TMPL_PATH"        && ok "1b. sshd 只聽 loopback，PasswordAuthentication no" || bad "1b. sshd 設定不符（只聽 loopback／禁密碼登入）"
    prop_runcmd_restart_socket "$TMPL_PATH" && ok "1c. runcmd 有重啟 ssh.socket（spike pitfall 1）" || bad "1c. runcmd 沒有重啟 ssh.socket"
    prop_key_defer_true "$TMPL_PATH"       && ok "1d. 隧道私鑰那一塊有 defer: true（spike pitfall 2）" || bad "1d. 隧道私鑰那一塊沒有 defer: true"
    prop_no_sync_resolve "$TMPL_PATH"      && ok "1f. 模板沒有提到 pool-sync／pool-resolve（不該在維修承載機上跑）" || bad "1f. 模板提到 pool-sync／pool-resolve"
    prop_no_token_literal "$TMPL_PATH"     && ok "1g0. 模板本身沒有權杖字面（generator 半在 register-repair-host 已驗，這裡只是模板不該內建任何字面）" || bad "1g0. 模板含疑似 GitHub 權杖字面"
    prop_tunnel_unit_system_user "$TMPL_PATH" && ok "1e. 隧道 unit 是 system unit（/etc/systemd/system/mlp-tunnel-repair.service）且帶 User=@@LOGIN_USER@@" \
        || bad "1e. 模板還沒有 system unit + User=——task 5 尚未落地（預期紅）"
    prop_new_scripts_referenced "$TMPL_PATH" && ok "1g. 模板引用了四支新腳本的安裝路徑" \
        || bad "1g. 模板還沒引用 repair-token-guard/-gateway-fetch/-gateway-report/-tunnel-launch——task 5 尚未落地（預期紅）"
    prop_sudoers_nopasswd "$TMPL_PATH" && ok "1h. 模板有 /etc/sudoers.d/ 的 NOPASSWD sudo 規則（2026-09-29 決定）" \
        || bad "1h. 模板沒有任何 /etc/sudoers.d/ 的 NOPASSWD 規則——repair 帳號在 VM 上沒有 root（8b.4，預期紅）"
    prop_sudoers_login_user_only "$TMPL_PATH" && ok "1h2. sudo 規則的 principal 只給登入使用者，不是 ALL" \
        || bad "1h2. sudo 規則的 principal 不是只有 @@LOGIN_USER@@（出現裸 ALL？）——blast radius 要對齐一個帳號（預期紅）"
else
    for id in 1a 1b 1c 1d 1e 1f 1g 1g0 1h 1h2; do bad "${id}. ${TEMPLATE} 不存在——無法驗證"; done
fi

echo "--- 1x. 注入：對模板複本動刀，證明上面的比對真的在看內容 ---"
mk_mutant() {
    # mk_mutant <needle-desc> <python-expr-on-src>（stdin 是原始碼，stdout 是改過的）
    python3 - "$TMPL_PATH" "$1" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
mode = sys.argv[2]
if mode == "no-defer":
    # 只拿掉「隧道私鑰那一塊」的 defer: true（跟 prop_key_defer_true 用同一個
    # 錨：path: 那行含 id_tunnel 或 TUNNEL_KEY_PATH，區塊到下一個 - path: 或
    # 頂層 key 為止），不是檔案裡第一個出現的 defer: true——這樣模板裡就算
    # 多一個合法的 deferred 檔案（且剛好排在私鑰前面），這個注入砍的仍然是
    # 私鑰那一塊，不會誤砍別的檔案。
    import re
    lines = src.splitlines(keepends=True)
    path_idxs = [i for i, l in enumerate(lines) if re.match(r'^[ \t]*-[ \t]*path:', l)]
    key_j = None
    for j, i in enumerate(path_idxs):
        if re.search(r'id_tunnel|TUNNEL_KEY_PATH', lines[i]):
            key_j = j
            break
    assert key_j is not None, "key block (id_tunnel/TUNNEL_KEY_PATH) not found"
    start = path_idxs[key_j]
    end = path_idxs[key_j + 1] if key_j + 1 < len(path_idxs) else len(lines)
    block = lines[start:end]
    removed = False
    for k, l in enumerate(block):
        if re.match(r'^[ \t]*defer:[ \t]*true[ \t]*$', l.rstrip("\n")):
            del block[k]
            removed = True
            break
    assert removed, "key block has no defer: true to remove"
    lines[start:end] = block
    src = "".join(lines)
elif mode == "listen-any":
    assert "ListenAddress 127.0.0.1" in src
    src = src.replace("ListenAddress 127.0.0.1", "ListenAddress 0.0.0.0", 1)
elif mode == "add-sync":
    src += "\n# injected for test-repair-host-vm.sh\nruncmd_extra: [ systemctl, enable, --now, pool-sync.timer ]\n"
elif mode == "sudo-all":
    # 把 sudoers 規則的 principal 改成 ALL（模擬「不只有該帳號」的退化：
    # 任何本機帳號都能免密碼 root）。只動 sudoers 區塊裡的主體欄位。
    lines = src.splitlines(keepends=True)
    outs = []
    insudo = False
    for l in lines:
        if re.match(r'^[ \t]*-[ \t]*path:[ \t]*/etc/sudoers\.d/', l):
            insudo = True
        elif re.match(r'^[ \t]*-[ \t]*path:', l) or re.match(r'^[^ \t]', l):
            insudo = False
        if insudo and re.match(r'^[ \t]*@@LOGIN_USER@@[ \t]', l):
            l = re.sub(r'^([ \t]*)@@LOGIN_USER@@', r'\1ALL', l, count=1)
        outs.append(l)
    new = "".join(outs)
    assert new != src, "no sudoers principal line to change"
    src = new
else:
    raise SystemExit("unknown mode " + mode)
sys.stdout.write(src)
PY
}
if [[ -f "$TMPL_PATH" ]]; then
    m1="$SANDBOX/tmpl-no-defer.tmpl"; mk_mutant "no-defer" > "$m1" 2>"$SANDBOX/mk1.err"
    if [[ -s "$m1" ]] && ! prop_key_defer_true "$m1"; then
        inj_ok "1x. 拿掉隧道私鑰那一塊的 defer: true 後 1d 會紅"
    else
        inj_bad "1x. 拿掉隧道私鑰那一塊的 defer: true 後 1d 仍綠——注入沒生效或斷言沒在量內容（$(cat "$SANDBOX/mk1.err" 2>/dev/null)）"
    fi
    m2="$SANDBOX/tmpl-listen-any.tmpl"; mk_mutant "listen-any" > "$m2" 2>"$SANDBOX/mk2.err"
    if [[ -s "$m2" ]] && ! prop_sshd_loopback "$m2"; then
        inj_ok "1x. ListenAddress 改成 0.0.0.0 後 1b 會紅"
    else
        inj_bad "1x. ListenAddress 改掉後 1b 仍綠（$(cat "$SANDBOX/mk2.err" 2>/dev/null)）"
    fi
    m3="$SANDBOX/tmpl-add-sync.tmpl"; mk_mutant "add-sync" > "$m3" 2>"$SANDBOX/mk3.err"
    if [[ -s "$m3" ]] && ! prop_no_sync_resolve "$m3"; then
        inj_ok "1x. 加一行 pool-sync 啟用後 1f 會紅"
    else
        inj_bad "1x. 加了 pool-sync 啟用後 1f 仍綠（$(cat "$SANDBOX/mk3.err" 2>/dev/null)）"
    fi
    # sudo-all：只有當模板已有一行 principal 是 @@LOGIN_USER@@ 的 sudo 規則
    # 才注入（現碼還沒有，注入會以 mk 失敗收場——那是預期，以 inj_skip 記）。
    if grep -qE '^[[:space:]]*@@LOGIN_USER@@[[:space:]]' "$TMPL_PATH" 2>/dev/null; then
        m4="$SANDBOX/tmpl-sudo-all.tmpl"; mk_mutant "sudo-all" > "$m4" 2>"$SANDBOX/mk4.err"
        if [[ -s "$m4" ]] && ! prop_sudoers_login_user_only "$m4"; then
            inj_ok "1x. principal 改成 ALL 後 1h2 會紅"
        else
            inj_bad "1x. principal 改成 ALL 後 1h2 仍綠（$(cat "$SANDBOX/mk4.err" 2>/dev/null)）"
        fi
    else
        inj_skip "1x. 模板還沒有 NOPASSWD 規則（1h/1h2 現碼本身就是紅）；等 impl 落地後這個注入才有刀可動"
    fi
else
    inj_skip "1x. 模板不存在，無法動刀"
fi
inj_skip "1e/1g. 兩項在 task 5 落地後已綠（見上）；注入 1x 的三個模板突變各自對應 1d/1b/1f。1h/1h2 的注入（sudo-all）在模板出現 NOPASSWD 規則後才會執行，理由見該處。"

echo
echo "=== 2. 權杖守衛（D5 後半） ==="
if [[ ! -x "$REPO_ROOT/$GUARD" && ! -x "$GUARD" ]]; then
    for id in 2a 2b 2c 2d; do bad "${id}. ${GUARD} 不存在——本測試定義它的行為（預期紅）"; done
else
    GUARD_BIN="$REPO_ROOT/$GUARD"; [[ -x "$GUARD_BIN" ]] || GUARD_BIN="$GUARD"
    run_guard() {
        env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" "$@" "$GUARD_BIN"
    }
    # 2a：都沒有 → 放行
    out="$(run_guard 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && ok "2a. 沒有權杖檔也沒有 GH_* 環境變數 → 放行（rc 0）" \
        || bad "2a. 乾淨環境下 guard 卻拒絕（rc ${rc}，out [${out}]）"

    # 2b：token 檔存在
    rm -f "$HOME_DIR/.mylinuxpool/gh_token"
    printf 'ghp_notarealtokenxxxxxxxxxxxxxxxxxxxx\n' > "$HOME_DIR/.mylinuxpool/gh_token"
    if [[ -f "$HOME_DIR/.mylinuxpool/gh_token" ]]; then
        ok "2b0. 正對照：測試自己確認 fixture 真的落在 guard 文件宣稱的路徑上"
    else
        bad "2b0（正對照失敗）：fixture 沒有真的建立——後面的 2b 不可信"
    fi
    out="$(run_guard 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        ok "2b. token 檔存在 → guard 拒絕（rc ${rc}）"
        printf '%s' "$out" | grep -qi token && ok "2b1. 拒絕訊息提到 token" || bad "2b1. 拒絕訊息沒提到 token（out [${out}]）"
    else
        bad "2b. token 檔存在但 guard 仍放行（rc 0）"
    fi
    rm -f "$HOME_DIR/.mylinuxpool/gh_token"

    # 2c：GH_TOKEN 環境變數
    out="$(run_guard GH_TOKEN=notarealtoken 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        ok "2c. GH_TOKEN 非空 → guard 拒絕（rc ${rc}）"
    else
        bad "2c. GH_TOKEN 非空但 guard 仍放行（rc 0）"
    fi

    # 2d：GH_POOL_TOKEN 環境變數
    out="$(run_guard GH_POOL_TOKEN=notarealtoken 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        ok "2d. GH_POOL_TOKEN 非空 → guard 拒絕（rc ${rc}）"
    else
        bad "2d. GH_POOL_TOKEN 非空但 guard 仍放行（rc 0）"
    fi
fi
inj_skip "2. repair-token-guard 現碼不存在，沒有原始碼可以動刀——本節的紅（或落地後的綠）本身就是量測結果"

echo
echo "=== 3. D2 取值／回報 ==="
if [[ ! -x "$REPO_ROOT/$FETCH" && ! -x "$FETCH" ]]; then
    for id in 3a 3b 3c 3d; do bad "${id}. ${FETCH}／${REPORT} 不存在——本測試定義它的行為（預期紅）"; done
else
    FETCH_BIN="$REPO_ROOT/$FETCH"; [[ -x "$FETCH_BIN" ]] || FETCH_BIN="$FETCH"
    REPORT_BIN="$REPO_ROOT/$REPORT"; [[ -x "$REPORT_BIN" ]] || REPORT_BIN="$REPORT"

    # 3a: 服務回 IP → 寫入 gateway.env
    GWENV="$SANDBOX/gateway.env"
    : > "$SANDBOX/curl.log"
    rm -f "$GWENV"
    out="$(env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" \
        CURL_LOG="$SANDBOX/curl.log" FAKE_D2_MODE=ip FAKE_D2_IP=198.51.100.7 \
        MLP_GATEWAY_ENV_FILE="$GWENV" MLP_D2_HOST=10.0.2.2 MLP_D2_PORT=18080 \
        "$FETCH_BIN" 2>&1)"; rc=$?
    if [[ -s "$SANDBOX/curl.log" ]]; then
        ok "3a0. 正對照：假 curl 真的被呼叫（log 非空）"
        if [[ $rc -eq 0 ]] && grep -q 'POOL_GATEWAY_HOST=198.51.100.7' "$GWENV" 2>/dev/null; then
            ok "3a. 服務回 IP → ${GWENV} 含 POOL_GATEWAY_HOST=198.51.100.7（rc ${rc}）"
        else
            bad "3a. 服務回 IP 但 ${GWENV} 沒有對的值（rc ${rc}, content [$(cat "$GWENV" 2>/dev/null)]）"
        fi
    else
        bad "3a0（正對照失敗）：假 curl 沒被呼叫——3a 不可信（out [${out}]）"
    fi

    # 3b: 把 fetch 出來的值疊到 pool-tunnel 的撥號上（模擬 EnvironmentFile 疊加）
    BASE_ENV="$SANDBOX/tunnel.env"
    cat > "$BASE_ENV" <<ENVEOF
POOL_NODE_NAME=repair-test
POOL_GATEWAY_PORT=2255
POOL_GATEWAY_USER=sshproxy
POOL_GATEWAY_SSH_PORT=2100
POOL_GATEWAY_HOST=gateway-ip-set-at-launch.invalid
ENVEOF
    : > "$SANDBOX/ssh.log"
    (
        set -a
        # shellcheck disable=SC1090
        . "$BASE_ENV"
        [[ -f "$GWENV" ]] && . "$GWENV"
        set +a
        env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" SSH_LOG="$SANDBOX/ssh.log" \
            POOL_NODE_NAME="$POOL_NODE_NAME" POOL_GATEWAY_PORT="$POOL_GATEWAY_PORT" \
            POOL_GATEWAY_USER="$POOL_GATEWAY_USER" POOL_GATEWAY_SSH_PORT="$POOL_GATEWAY_SSH_PORT" \
            POOL_GATEWAY_HOST="$POOL_GATEWAY_HOST" \
            bash "$REPO_ROOT/$PTUNNEL" --once >/dev/null 2>&1
    )
    dial="$(grep -e '-M -S' "$SANDBOX/ssh.log" 2>/dev/null | tail -n 1)"
    if [[ -n "$dial" ]]; then
        ok "3b0. 正對照：假 ssh 收到撥號呼叫"
        if printf '%s' "$dial" | grep -q '198.51.100.7'; then
            ok "3b. D2 取到的 IP 真的傳到 pool-tunnel 的撥號 argv（不是取而不用）"
        else
            bad "3b. gateway.env 有值，但撥號 argv 沒用到它（argv [${dial}]）"
        fi
    else
        bad "3b0（正對照失敗）：假 ssh 沒被呼叫——3b 不可信"
    fi

    # 3c: 服務不在 → 不覆寫；之後撥號用 placeholder（明確失敗）
    GWENV2="$SANDBOX/gateway2.env"
    printf 'POOL_GATEWAY_HOST=stale-should-not-be-touched.invalid\n' > "$GWENV2"
    : > "$SANDBOX/curl.log"
    env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" \
        CURL_LOG="$SANDBOX/curl.log" FAKE_D2_MODE=down \
        MLP_GATEWAY_ENV_FILE="$GWENV2" MLP_D2_HOST=10.0.2.2 MLP_D2_PORT=18080 \
        "$FETCH_BIN" >/dev/null 2>&1
    if grep -q 'stale-should-not-be-touched.invalid' "$GWENV2" 2>/dev/null; then
        ok "3c. 服務不在（curl 失敗）→ 沒有覆寫既有的 gateway.env"
    else
        bad "3c. 服務不在時 gateway.env 被動過（content [$(cat "$GWENV2" 2>/dev/null)]）——family VM 可能連去猜出來的位址"
    fi
    : > "$SANDBOX/ssh.log"
    (
        set -a
        # shellcheck disable=SC1090
        . "$BASE_ENV"
        set +a
        env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" SSH_LOG="$SANDBOX/ssh.log" \
            POOL_NODE_NAME="$POOL_NODE_NAME" POOL_GATEWAY_PORT="$POOL_GATEWAY_PORT" \
            POOL_GATEWAY_USER="$POOL_GATEWAY_USER" POOL_GATEWAY_SSH_PORT="$POOL_GATEWAY_SSH_PORT" \
            POOL_GATEWAY_HOST="$POOL_GATEWAY_HOST" \
            bash "$REPO_ROOT/$PTUNNEL" --once >/dev/null 2>&1
    )
    dial2="$(grep -e '-M -S' "$SANDBOX/ssh.log" 2>/dev/null | tail -n 1)"
    if printf '%s' "$dial2" | grep -q 'gateway-ip-set-at-launch.invalid'; then
        ok "3c2. 沒有 D2 值時，撥號用開機資料裡的 placeholder（明確失敗，不是亂猜一個能連的位址）"
    else
        bad "3c2. 沒有 D2 值時撥號沒有用 placeholder（argv [${dial2}]）"
    fi

    # 3d: report
    : > "$SANDBOX/curl.log"
    env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" \
        CURL_LOG="$SANDBOX/curl.log" MLP_D2_HOST=10.0.2.2 MLP_D2_PORT=18080 \
        "$REPORT_BIN" up >/dev/null 2>&1
    if [[ -s "$SANDBOX/curl.log" ]]; then
        ok "3d0. 正對照：report 的假 curl 真的被呼叫"
        if grep -q '/state' "$SANDBOX/curl.log" && grep -q 'tunnel=up' "$SANDBOX/curl.log"; then
            ok "3d. 隧道起來後 report 用 POST 送出 tunnel=up 給 /state"
        else
            bad "3d. report 沒有送出對的 URL／body（log [$(cat "$SANDBOX/curl.log")]）"
        fi
    else
        bad "3d0（正對照失敗）：report 沒有呼叫假 curl——3d 不可信"
    fi
fi
inj_skip "3. repair-gateway-fetch/-report 現碼不存在，沒有原始碼可以動刀"

echo
echo "=== 4. D7 重試節奏（模擬時間，絕不真的 sleep） ==="
if [[ ! -x "$REPO_ROOT/$LAUNCH" && ! -x "$LAUNCH" ]]; then
    for id in 4a 4b; do bad "${id}. ${LAUNCH} 不存在——本測試定義它的行為（預期紅）"; done
else
    LAUNCH_BIN="$REPO_ROOT/$LAUNCH"; [[ -x "$LAUNCH_BIN" ]] || LAUNCH_BIN="$LAUNCH"
    DIAL_TIMES="$SANDBOX/dial-times-4.log"
    CLOCK="$SANDBOX/clock-4"
    : > "$DIAL_TIMES"; printf '0\n' > "$CLOCK"
    # 700 秒的模擬時間就足夠看「任何 10 分鐘視窗」——超過一個視窗長度即可。
    RUNENV=(
        PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR"
        SSH_LOG="$SANDBOX/ssh-4.log" MLP_TEST_DIAL_TIMES="$DIAL_TIMES"
        MLP_TEST_CLOCK="$CLOCK" MLP_TEST_CLOCK_CAP=700
        MLP_TEST_SSH_STDERR="Permission denied (publickey)."
        MLP_TEST_SLEEP_LOG="$SANDBOX/sleep-4.log"
        MLP_REPAIR_POOL_TUNNEL_BIN="$REPO_ROOT/$PTUNNEL"
        POOL_NODE_NAME=repair-test POOL_GATEWAY_PORT=2255
        POOL_GATEWAY_USER=sshproxy POOL_GATEWAY_SSH_PORT=2100
        POOL_GATEWAY_HOST=203.0.113.9
    )
    if command -v timeout >/dev/null 2>&1; then
        # belt and suspenders：虛擬時鐘的 TERM 才是真正的終止機制（見假
        # sleep 的註解），這裡的真實 20 秒只是防呆，不是用來模擬 10 分鐘。
        timeout -k 5 20 env -i "${RUNENV[@]}" "$LAUNCH_BIN" >/dev/null 2>&1
    else
        env -i "${RUNENV[@]}" "$LAUNCH_BIN" >/dev/null 2>&1 &
        lpid=$!
        wait "$lpid" 2>/dev/null
    fi
    n_dials="$(wc -l < "$DIAL_TIMES" 2>/dev/null | tr -d '[:space:]')"; [[ -z "$n_dials" ]] && n_dials=0
    if [[ "${n_dials:-0}" -ge 2 ]]; then
        ok "4a. 正對照：模擬 700 秒內假 ssh 收到 ${n_dials} 次撥號嘗試（不是 0 次或 1 次就沒動靜）"
        maxw="$(count_max_window "$DIAL_TIMES" 600)"
        if [[ "$maxw" -lt 5 ]]; then
            ok "4b. 任何 600 秒（10 分鐘）滑動視窗內的嘗試次數 < 5（量到最多 ${maxw} 次）"
        else
            bad "4b. 有一個 600 秒視窗內嘗試 ${maxw} 次（>=5）——會撞到 fail2ban 預設的 10 分鐘 5 次門檻"
        fi
    else
        bad "4a（正對照失敗）：700 秒模擬時間內只收到 ${n_dials} 次撥號——4b 不可信（repair-tunnel-launch 可能整個沒跑起來，或退避拉太長）"
    fi
fi

echo "--- 4c. 自我驗證：視窗計數器不是一個永遠回答「沒問題」的空殼 ---"
BAD_SCHEDULE="$SANDBOX/bad-schedule.times"
python3 - > "$BAD_SCHEDULE" <<'PY'
# 仿 pool-tunnel 自己原生的退避數列 2,4,8,16,30,30,30,...，看它在 600 秒視窗
# 內會不會被抓到違規（它本來就會——這是 D7 存在的理由）。
t = 0
times = [t]
backoffs = [2, 4, 8, 16, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
for b in backoffs:
    t += b
    times.append(t)
for x in times:
    print(x)
PY
maxw_bad="$(count_max_window "$BAD_SCHEDULE" 600)"
if [[ "$maxw_bad" -ge 5 ]]; then
    ok "4c. 計數器對 pool-tunnel 原生退避數列正確回報違規（${maxw_bad} 次 >= 5）——不是空殼"
else
    bad "4c. 計數器對已知會違規的數列（${maxw_bad} 次）沒有抓到——計數器本身有問題，4b 的綠不可信"
fi
GOOD_SCHEDULE="$SANDBOX/good-schedule.times"
python3 -c "print('\n'.join(str(i*180) for i in range(6)))" > "$GOOD_SCHEDULE"
maxw_good="$(count_max_window "$GOOD_SCHEDULE" 600)"
if [[ "$maxw_good" -lt 5 ]]; then
    ok "4c2. 計數器對平坦 180 秒間隔的數列正確回報不違規（${maxw_good} 次 < 5）"
else
    bad "4c2. 計數器對合理數列（${maxw_good} 次）誤報違規"
fi
inj_skip "4. repair-tunnel-launch 現碼不存在，沒有原始碼可以動刀；4c/4c2 是對計數器本身的自我驗證，不是對 subject 的注入"

echo
echo "=== 5. 回歸：非維修模式的 pool-tunnel backoff 不變 ==="
run_ptunnel_backoff() {
    # run_ptunnel_backoff <lib-path> — 跑到收集滿 6 次撥號或虛擬時鐘到頂為止。
    local lib="$1"
    local dial="$SANDBOX/dial-5.log" clock="$SANDBOX/clock-5" sleeplog="$SANDBOX/sleep-5.log"
    : > "$dial"; printf '0\n' > "$clock"; : > "$sleeplog"
    local runenv=(
        PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR"
        SSH_LOG="$SANDBOX/ssh-5.log" MLP_TEST_DIAL_TIMES="$dial"
        MLP_TEST_CLOCK="$clock" MLP_TEST_CLOCK_CAP=120
        MLP_TEST_SLEEP_LOG="$sleeplog"
        POOL_NODE_NAME=repair-test POOL_GATEWAY_PORT=2255
        POOL_GATEWAY_USER=sshproxy POOL_GATEWAY_SSH_PORT=2100
        POOL_GATEWAY_HOST=203.0.113.9
    )
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 5 20 env -i "${runenv[@]}" bash "$lib" >/dev/null 2>&1
    else
        env -i "${runenv[@]}" bash "$lib" >/dev/null 2>&1 &
        wait $! 2>/dev/null
    fi
    RB_SLEEPS="$(grep -v '^1$' "$sleeplog" 2>/dev/null | head -n 6 | tr '\n' ',' )"
    RB_DIALS="$(wc -l < "$dial" 2>/dev/null | tr -d '[:space:]')"; [[ -z "$RB_DIALS" ]] && RB_DIALS=0
}

run_ptunnel_backoff "$REPO_ROOT/$PTUNNEL"
if [[ "${RB_DIALS:-0}" -ge 2 ]]; then
    ok "5a. 正對照：非維修模式下假 ssh 收到 ${RB_DIALS} 次撥號嘗試"
    if [[ "$RB_SLEEPS" == "2,4,8,16,30,30,"* || "$RB_SLEEPS" == "2,4,8,16,30,30" ]]; then
        ok "5b. pool-tunnel 自己的退避數列仍是 2,4,8,16,30,30,...（got [${RB_SLEEPS}]）"
    else
        bad "5b. pool-tunnel 的退避數列變了（got [${RB_SLEEPS}]，預期以 2,4,8,16,30,30 開頭）——D7 不該碰到非維修模式的節奏"
    fi
else
    bad "5a（正對照失敗）：非維修模式下假 ssh 只收到 ${RB_DIALS:-0} 次撥號——5b 不可信"
fi

echo "--- 5x. 注入：拿掉 pool-tunnel 退避的封頂，5b 必須翻紅 ---"
inj_lib="$SANDBOX/ptunnel-nocap"
mkdir -p "$inj_lib"
python3 - "$REPO_ROOT/$PTUNNEL" "$inj_lib/pool-tunnel" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r'next_backoff\(\) \{\n(.*?)\n\}\n', re.S)
m = pat.search(src)
assert m, "next_backoff needle not found"
new_body = (
    'next_backoff() {\n'
    '    echo $(( $1 * 2 ))\n'
    '}\n'
)
src = src[:m.start()] + new_body + src[m.end():]
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -eq 0 ]] && bash -n "$inj_lib/pool-tunnel" 2>/dev/null; then
    cp "$SANDBOX/tunnel-identity.sh" "$inj_lib/tunnel-identity.sh"
    run_ptunnel_backoff "$inj_lib/pool-tunnel"
    if [[ "${RB_DIALS:-0}" -ge 2 && "$RB_SLEEPS" != "2,4,8,16,30,30,"* && "$RB_SLEEPS" != "2,4,8,16,30,30" ]]; then
        inj_ok "5x. 拿掉封頂（一路倍增）後 5b 會紅（got [${RB_SLEEPS}]）"
    else
        inj_bad "5x. 拿掉封頂後 5b 仍然「通過」——注入沒生效，或斷言沒在量退避數列（dials=${RB_DIALS:-0}, got [${RB_SLEEPS}]）"
    fi
else
    inj_bad "5x. 注入腳本失敗（needle 落空或語法錯）——harness 問題"
fi

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' \
    "$pass" "$fail" "$injpass" "$injfail"
[[ "$fail" -ne 0 ]] && exit 1
[[ "$injfail" -ne 0 ]] && exit 2
exit 0
