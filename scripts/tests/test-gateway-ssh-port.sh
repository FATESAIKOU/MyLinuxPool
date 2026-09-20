#!/usr/bin/env bash
# test-gateway-ssh-port.sh — Gateway 的 SSH 監聽埠。
#
# 為什麼這支測試存在：Gateway 是整座 pool 唯一的入口，而這台機器是
# Ubuntu 24.04，sshd 由 **ssh.socket** 啟動。在那種情況下 sshd_config 裡的
# `Port` 會被完全忽略——照直覺改 Port 再 reload，結果是哪個埠都沒在聽，
# 而且沒有退路：repair-gateway 自己就走 SSH，rotate 又把 root 密碼丟棄了，
# 沒有主控台救援。所以監聽埠只能改 ssh.socket 的 ListenStream。
#
# 斷言：
#   1. 設定寫在 ssh.socket 的 drop-in，不是 sshd_config 的 Port。
#   2. drop-in 第一行是空的 ListenStream=——不清空的話 unit 自帶的 22
#      會留著，只是被追加，於是「改埠」變成「多開一個埠」。
#   3. 給多個埠時全部寫進去（遷移期要同時聽舊的與新的）。
#   4. 無效的埠（0、65536、非數字）一律拒絕，不寫檔。
#   5. 空清單拒絕——那會讓 Gateway 完全不可達。
#   6. **防鎖死**：重啟後若某個埠沒真的在聽，drop-in 必須還原成原本的
#      內容並以非 0 結束。這條是整支測試的核心。
#   7. fail2ban 的 jail 要列出所有監聽埠：封鎖規則是 `tcp dport <port>`，
#      jail 還寫著舊埠的話，封鎖會套在沒人敲的埠上，看起來生效實則無效。
#   8. rotate_run_provision 會把埠清單傳下去，且預設 22。
#   9. 注入：拿掉空的 ListenStream= -> 2 轉紅。
#  10. 注入：拿掉重啟後的驗證 -> 6 轉紅。
#
# Run: scripts/tests/test-gateway-ssh-port.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PROV="scripts/provision-gateway.sh"
ROTATE="scripts/rotate-gateway.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-gw-ssh-port.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# systemctl：只記錄。ss：由 FAKE_SS_LISTENING 決定哪些埠「在聽」。
cat > "$SANDBOX/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
[[ "${FAKE_SYSTEMCTL_FAIL:-0}" == "1" && "$1" == "restart" ]] && exit 1
exit 0
FAKE
# FAKE_SS_LISTENING 的每一項是 "<埠>" 或 "<埠>/v6"。後者只產生 IPv6 那一行
# ——2026-09-20 的事故就是這個狀態：機器上看起來在聽，IPv4 全部被拒。
cat > "$SANDBOX/bin/ss" <<'FAKE'
#!/usr/bin/env bash
for e in ${FAKE_SS_LISTENING:-}; do
    p="${e%%/*}"
    case "$e" in
        */v6) echo "LISTEN 0 4096 [::]:${p} [::]:*" ;;
        *)    echo "LISTEN 0 4096 0.0.0.0:${p} 0.0.0.0:*"
              echo "LISTEN 0 4096 [::]:${p} [::]:*" ;;
    esac
done
exit 0
FAKE
# provision-gateway.sh 在頂層做 root 檢查，並從 stdin 讀 FILE_CRYPTO_KEY；
# 兩者都要滿足，否則 source 進來就直接結束，任何函式都跑不到。
cat > "$SANDBOX/bin/id" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == "-u" ]] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
FAKE
chmod +x "$SANDBOX/bin/systemctl" "$SANDBOX/bin/ss" "$SANDBOX/bin/id"

# 把被測腳本沙箱化：改掉絕對路徑，並拿掉結尾的 main 呼叫，只 source 函式。
sandbox_prov() {   # $1 = 輸出路徑, $2 = 額外的 sed（可空）
    sed -e 's|^SSH_SOCKET_CONF="/etc/systemd/system/ssh.socket.d/10-mylinuxpool.conf"$|SSH_SOCKET_CONF="${SANDBOX_SOCKET_CONF:?}"|' \
        -e 's|^FAIL2BAN_CONF="/etc/fail2ban/jail.d/mylinuxpool-ignore.conf"$|FAIL2BAN_CONF="${SANDBOX_F2B_CONF:?}"|' \
        -e '/^main$/d' \
        "$PROV" > "$1"
}

# exec_prov <腳本> <socket.conf> <埠清單> <假裝在聽的埠>；回傳 rc，設定 $OUT
exec_prov() {
    OUT="$(
        printf 'dummy-crypto-key' | \
        SANDBOX_SOCKET_CONF="$2" \
        SANDBOX_F2B_CONF="$SANDBOX/f2b.conf" \
        SYSTEMCTL_LOG="$SANDBOX/systemctl.log" \
        FAKE_SS_LISTENING="$4" \
        GATEWAY_SSH_LISTEN_PORTS="$3" \
        PATH="$SANDBOX/bin:$PATH" \
        bash -c '
            set -uo pipefail
            source "$1"
            provision_ssh_listen_ports
        ' _ "$1" 2>&1
    )"
    return $?
}

run_ports() {   # $1 = 埠清單, $2 = 假裝在聽的埠清單
    local prov="$SANDBOX/prov.sh"
    sandbox_prov "$prov"
    exec_prov "$prov" "$SANDBOX/socket.conf" "$1" "$2"
}

echo "=== 0. 預設情況完全不碰 ssh.socket（最重要的一條）==="
# 2026-09-20：寫 drop-in 並重啟 ssh.socket 把現役 Gateway 弄到完全沒有 sshd
# 在聽，重開機也救不回來，最後只能重建。在那個根因被理解並用真實的
# socket-activated sshd 驗證之前，只需要 22 的機器必須原封不動。
command rm -f "$SANDBOX/socket.conf" "$SANDBOX/systemctl.log"
: > "$SANDBOX/systemctl.log"
if run_ports "22" "22"; then
    if [[ -f "$SANDBOX/socket.conf" ]]; then
        bad "0. 預設 22 卻還是寫了 drop-in"
    elif grep -q 'restart ssh.socket' "$SANDBOX/systemctl.log" 2>/dev/null; then
        bad "0. 預設 22 卻還是重啟了 ssh.socket——那正是弄死 Gateway 的那個動作"
    else
        ok "0. 預設 22 且沒有既有 drop-in 時：不寫檔、不重啟，什麼都不做"
    fi
else
    bad "0. 預設情況竟然失敗: ${OUT}"
fi

echo "=== 1-3. 寫對地方、寫對內容 ==="
if grep -q 'SSH_SOCKET_CONF=.*ssh\.socket\.d' "$PROV" && grep -q 'ListenStream' "$PROV"; then
    ok "1a. 設定寫進 ssh.socket 的 drop-in"
else
    bad "1a. 找不到 ssh.socket 的 drop-in"
fi
# sshd_config 那份不該出現 Port——socket 啟動下它無效，留著只會誤導
if awk '/^provision_ssh_listen_ports/{exit} /desired="\$\(cat <<.EOF/,/^EOF$/' "$PROV" | grep -qE '^Port '; then
    bad "1b. sshd_config 區塊裡有 Port——socket 啟動下它不生效，會誤導下一個人"
else
    ok "1b. sshd_config 區塊沒有 Port"
fi

: > "$SANDBOX/socket.conf"
if run_ports "22 2100" "22 2100"; then
    first_stream="$(grep -n 'ListenStream' "$SANDBOX/socket.conf" | head -1)"
    if [[ "$first_stream" == *"ListenStream="* && "$first_stream" != *"ListenStream=2"* ]]; then
        ok "2. 第一個 ListenStream= 是空的（清掉 unit 自帶的 22）"
    else
        bad "2. 沒有先清空 ListenStream=，改埠會變成多開一個埠:"$'\n'"$(cat "$SANDBOX/socket.conf")"
    fi
    # 每個埠都必須明寫 IPv4 與 IPv6 兩行。裸的 ListenStream=<port> 在
    # BindIPv6Only=ipv6-only 之下只會產生 IPv6 socket，IPv4 全部 refused
    # ——那正是把正式 Gateway 弄死、且重開機也救不回來的原因。
    ok3=1
    for p in 22 2100; do
        grep -q "^ListenStream=0\.0\.0\.0:${p}\$" "$SANDBOX/socket.conf" || ok3=0
        grep -q "^ListenStream=\[::\]:${p}\$" "$SANDBOX/socket.conf" || ok3=0
    done
    if grep -qE '^ListenStream=[0-9]+$' "$SANDBOX/socket.conf"; then
        bad "3. 出現裸的 ListenStream=<port>——那只會綁 IPv6，IPv4 會全部被拒"
    elif [[ "$ok3" -eq 1 ]]; then
        ok "3. 每個埠都明寫了 0.0.0.0 與 [::] 兩行"
    else
        bad "3. 位址族沒寫全:"$'\n'"$(cat "$SANDBOX/socket.conf")"
    fi
else
    bad "2. 正常情況竟然失敗: ${OUT}"
    bad "3. 正常情況竟然失敗（同上）"
fi

echo "=== 4-5. 壞輸入一律拒絕 ==="
allbad=1
for p in "0" "65536" "abc" "22 abc"; do
    command rm -f "$SANDBOX/socket.conf"
    if run_ports "$p" "22 2100"; then
        bad "4. 無效的埠 '${p}' 竟然被接受"
        allbad=0
    elif [[ -f "$SANDBOX/socket.conf" ]]; then
        bad "4. 無效的埠 '${p}' 被拒絕，但還是寫了檔"
        allbad=0
    fi
done
[[ "$allbad" -eq 1 ]] && ok "4. 0／65536／非數字／混入非數字 全部拒絕且不寫檔"

# 空字串 = 未設定 = 預設 22，那是正確且安全的。真正要擋的是「有值但展開
# 後一個埠都沒有」——例如上游把空陣列 join 成了幾個空白。
command rm -f "$SANDBOX/socket.conf"
if run_ports "   " "22"; then
    bad "5. 只有空白的埠清單被接受——會寫出沒有任何 ListenStream 的 unit，Gateway 完全不可達"
elif [[ -f "$SANDBOX/socket.conf" ]]; then
    bad "5. 只有空白的埠清單被拒絕，但還是寫了檔"
else
    ok "5. 只有空白的埠清單被拒絕且不寫檔（空字串則正確地套用預設 22）"
fi

echo "=== 6. 防鎖死：重啟後沒在聽就還原 ==="
# 先建立一個「原本就有」的 drop-in，還原時必須回到它
printf '[Socket]\nListenStream=\nListenStream=22\n' > "$SANDBOX/socket.conf"
before="$(cat "$SANDBOX/socket.conf")"
if run_ports "22 2100" "22 2100/v6"; then   # 2100 只有 IPv6
    bad "6. 2100 只綁到 IPv6 卻回報成功——這正是 2026-09-20 鎖死自己的情況"
else
    after="$(cat "$SANDBOX/socket.conf" 2>/dev/null || echo '<檔案不見了>')"
    if [[ "$after" == "$before" ]]; then
        ok "6. 只綁到 IPv6 時以非 0 結束，且 drop-in 還原成原本的內容"
    else
        bad "6. 以非 0 結束但沒有還原:"$'\n'"got:  ${after}"$'\n'"want: ${before}"
    fi
fi

echo "=== 7-8. fail2ban 與呼叫端 ==="
if grep -q 'ports_csv' "$PROV" && grep -qE '\[sshd\]\\nport' "$PROV"; then
    ok "7. fail2ban jail 會列出監聽埠"
else
    bad "7. fail2ban jail 沒有帶埠——封鎖規則會套在舊埠上，看似生效實則無效"
fi

if grep -q 'GATEWAY_SSH_LISTEN_PORTS=\$(printf' "$ROTATE" \
   && grep -q 'local listen_ports="\${5:-22}"' "$ROTATE"; then
    ok "8. rotate_run_provision 傳遞埠清單，且預設 22"
else
    bad "8. rotate_run_provision 沒有傳埠清單（或沒有安全的預設值）"
fi

echo "=== 11-14. client 側：埠必須來自 NODE_GATEWAY，不能寫死 ==="
MLP="ops-scripts/mlp"
PSTATUS="shared-configs/pool-runtime/files/pool-status"
PTUNNEL="shared-configs/pool-runtime/files/pool-tunnel"

# 11. 沒有任何 client 還把 Gateway 那一跳的埠寫死成 22
hard=""
grep -nE '"\$GW_IP" 22|gateway 22 ""|^ *Port 22$|tcp_classify "\$GW_IP" 22' "$MLP" "$PSTATUS" >/dev/null 2>&1 && hard="有"
if [[ -z "$hard" ]]; then
    ok "11. mlp / pool-status 不再把 Gateway 埠寫死"
else
    bad "11. 還有寫死的 22:"$'\n'"$(grep -nE '"\$GW_IP" 22|gateway 22 ""|^ *Port 22$' "$MLP" "$PSTATUS")"
fi

# 12. pool-tunnel 真的把 -p 帶進 ssh
if grep -q '\-p "\${GW_SSH_PORT:-22}"' "$PTUNNEL"; then
    ok "12. pool-tunnel 撥號時帶 -p（provider 與 worker 的隧道都靠它）"
else
    bad "12. pool-tunnel 的 ssh 沒有帶 -p——埠一改，所有隧道都連不上"
fi

# 13. 行為：gateway.json 的往返。worker 沒有 GitHub 憑證，這個檔是它唯一的來源
mkdir -p "$SANDBOX/gw"
printf '{"ip":"1.2.3.4","tunnel_user":"sshproxy","ssh_port":2100,"generation":"17","host_key":"k"}\n' \
    > "$SANDBOX/gw/new.json"
printf '{"ip":"1.2.3.4","tunnel_user":"sshproxy","generation":"16","host_key":"k"}\n' \
    > "$SANDBOX/gw/old.json"
newp="$(jq -r '.ssh_port // 22' < "$SANDBOX/gw/new.json")"
oldp="$(jq -r '.ssh_port // 22' < "$SANDBOX/gw/old.json")"
if [[ "$newp" == "2100" && "$oldp" == "22" ]]; then
    ok "13. gateway.json 帶 ssh_port 時讀到它；舊檔沒有該欄位時退回 22"
else
    bad "13. gateway.json 的埠讀取不對（新檔=${newp} 舊檔=${oldp}）"
fi

# 14. publish_gateway 要把 ssh_port 寫出去，且變更偵測要看它
pg_write=0; pg_detect=0
grep -q '"ssh_port":%s' "$PTUNNEL" && pg_write=1
grep -q 'ssh_port // 22) | tostring) == \$port' "$PTUNNEL" && pg_detect=1
if [[ $pg_write -eq 1 && $pg_detect -eq 1 ]]; then
    ok "14. provider 會把 ssh_port 發布給 worker，且埠變了會重新發布"
else
    bad "14. publish_gateway 不完整（寫出=${pg_write} 變更偵測=${pg_detect}）——worker 不會知道埠變了"
fi

echo "=== 9-10. 注入 ==="
# 重現 2026-09-20 的真兇：把兩行位址族換回裸的 ListenStream=<port>。
# 在 BindIPv6Only=ipv6-only 之下那只會產生 IPv6 socket，IPv4 全部 refused，
# 而機器上的 `ss` 看起來一切正常——正式 Gateway 就是這樣死的，重開機也沒救。
inj="$SANDBOX/prov-inj1.sh"
sandbox_prov "$inj"
python3 - "$inj" <<'INJ'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = ('        desired+=$\'\\n\'"ListenStream=0.0.0.0:${p}"\n'
       '        desired+=$\'\\n\'"ListenStream=[::]:${p}"\n')
assert old in s, "both-family needle not found"
new = '        desired+=$\'\\n\'"ListenStream=${p}"\n'
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
INJ
if [[ $? -ne 0 ]]; then
    inj_bad "9. 注入腳本失敗（被測物形狀變了）——harness 問題"
else
    command rm -f "$SANDBOX/socket-inj.conf"
    exec_prov "$inj" "$SANDBOX/socket-inj.conf" "22 2100" "22 2100"
    if grep -qE '^ListenStream=[0-9]+$' "$SANDBOX/socket-inj.conf" 2>/dev/null; then
        inj_ok "9. 換回裸的 ListenStream=<port> 後第 3 條會紅（重現真正的事故成因）"
    else
        inj_bad "9. 注入沒生效（檔案裡沒有裸的 ListenStream）"
    fi
fi

inj2="$SANDBOX/prov-inj2.sh"
sandbox_prov "$inj2"
python3 - "$inj2" <<'INJ2'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = '''    if [[ -n "$missing" ]]; then'''
new = '''    missing=""
    if [[ -n "$missing" ]]; then'''
assert old in s, "verification needle"
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
INJ2
printf '[Socket]\nListenStream=\nListenStream=22\n' > "$SANDBOX/socket-inj2.conf"
if exec_prov "$inj2" "$SANDBOX/socket-inj2.conf" "22 2100" "22"; then
    inj_ok "10. 拿掉重啟後的驗證，2100 沒在聽也會回報成功——第 6 條擋得住"
else
    inj_bad "10. 注入後仍然失敗——注入沒生效（harness 問題）: ${OUT}"
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
