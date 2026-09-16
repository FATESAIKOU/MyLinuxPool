#!/usr/bin/env bash
# test-client-identity.sh — 「用哪把金鑰以 admin 身分登入」這條規則的回歸測試。
#
# 背景（RUNBOOK §7.12 再一次）：`mlp register client` 產生 ~/.ssh/id_mlp，
# 但 ssh 內建的候選金鑰（id_rsa、id_ed25519…）不含它，所以每一處 ssh 呼叫
# 都必須自己帶 -i。這件事先後在四個地方各寫了一份，補了三份、漏掉
# scripts/lib/ssh.sh 那份，`mlp ssh` 就以 Permission denied 收場。
#
# 第二個 bug 更隱蔽：修 mlp 時把 client_identity_path/client_identity_opts
# 兩個函式**貼進了 open_gateway_master 的函式體內**。語法完全合法，`mlp ls`
# （會先跑 open_gateway_master）照常運作，只有 `mlp ssh <name>` 這條不經過
# 它的路徑會撞上 "command not found"——而那裡的呼叫寫了 `|| true`，於是錯誤
# 被吞掉，身分靜靜地變成空字串。
#
# 斷言：
#   1. 結構：這批腳本裡不得有縮排的函式定義（= 巢狀定義）。這是通例，
#      直接封掉上面第二個 bug 的整個類別。
#   2. 行為：SSH_IDENTITY 有設時，ssh_via_gateway 的 -i 必須同時出現在
#      外層 argv 與 ProxyCommand 字串裡。只補外層的話跳板那一跳先失敗，
#      內層根本輪不到。
#   3. 行為：SSH_IDENTITY 沒設時兩處都不得出現 -i——Actions 靠 ssh-agent，
#      強塞 -i 會讓每一個 workflow 都認不到 agent 裡的金鑰。
#   4. 行為：ssh_gateway_only 同樣受 SSH_IDENTITY 控制。
#   5. 靜態：mlp 的 do_connect 必須真的去問 client_identity_path。
#   6. 靜態：verify-profile 的兩段（SSH_OPTS 與跳板 leg）都要帶身分。
#   7. 注入：把 ProxyCommand 的身分拿掉 -> 2 轉紅。
#   8. 注入：把函式縮排成巢狀 -> 1 轉紅。
#
# Run: scripts/tests/test-client-identity.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

SSH_LIB="scripts/lib/ssh.sh"
MLP="ops-scripts/mlp"
VERIFY="ops-scripts/verify-profile"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-client-identity.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# 假 ssh：把 argv 一行一個記下來就好，不連任何東西。
cat > "$SANDBOX/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
: > "${ARGV_LOG}"
for a in "$@"; do printf '%s\n' "$a" >> "${ARGV_LOG}"; done
exit 0
FAKE
chmod +x "$SANDBOX/bin/ssh"

# ---- 1. 結構：定義位置與呼叫位置必須對得上 -------------------------------
echo "=== 1. 巢狀函式的可見範圍 ==="
SCOPE_CHK="scripts/tests/helpers/nested-fn-scope.py"
scope_out="$(python3 "$SCOPE_CHK" \
    "$MLP" "$SSH_LIB" "$VERIFY" \
    shared-configs/pool-runtime/files/pool-sync \
    shared-configs/pool-runtime/files/pool-status \
    shared-configs/pool-runtime/files/pool-tunnel 2>&1)"
if [[ $? -eq 0 ]]; then
    ok "1. 沒有「定義在某函式內、卻被別處呼叫」的函式"
else
    bad "1. 函式的可見範圍對不上呼叫點:"$'\n'"$scope_out"
fi

# ---- 2-4. 行為：SSH_IDENTITY 控制兩條 leg --------------------------------
echo "=== 2-4. SSH_IDENTITY 對兩條 leg 的作用 ==="
run_leg() {
    # $1 = identity（空字串代表不設）, $2 = 函式名
    local ident="$1" fn="$2"
    ARGV_LOG="$SANDBOX/argv.txt"
    : > "$ARGV_LOG"
    PATH="$SANDBOX/bin:$PATH" ARGV_LOG="$ARGV_LOG" SSH_IDENTITY="$ident" \
        bash -c '
            set -uo pipefail
            . "'"$REPO_ROOT"'/'"$SSH_LIB"'"
            if [[ "$1" == ssh_gateway_only ]]; then
                ssh_gateway_only /tmp/kh admin gw.example 22 true
            else
                ssh_via_gateway /tmp/kh admin gw.example 22 worker 127.0.0.1 2300 true
            fi
        ' _ "$fn" >/dev/null 2>&1
    cat "$ARGV_LOG"
}

argv="$(run_leg "/home/u/.ssh/id_mlp" ssh_via_gateway)"
outer_i=0; proxy_i=0
grep -qx -- '-i' <<< "$argv" && outer_i=1
grep -q -- 'ProxyCommand=ssh -i /home/u/.ssh/id_mlp -o IdentitiesOnly=yes ' <<< "$argv" && proxy_i=1
if [[ $outer_i -eq 1 && $proxy_i -eq 1 ]]; then
    ok "2. ssh_via_gateway：外層與 ProxyCommand 都帶了 -i"
else
    bad "2. ssh_via_gateway 身分不完整（outer=${outer_i} proxy=${proxy_i}）:"$'\n'"$argv"
fi

argv="$(run_leg "" ssh_via_gateway)"
if grep -qx -- '-i' <<< "$argv" || grep -q -- 'ProxyCommand=ssh -i ' <<< "$argv"; then
    bad "3. SSH_IDENTITY 未設卻仍塞了 -i——Actions 的 ssh-agent 會被忽略:"$'\n'"$argv"
else
    ok "3. SSH_IDENTITY 未設時兩處都沒有 -i，交還給 ssh/agent 決定"
fi

argv="$(run_leg "/home/u/.ssh/id_mlp" ssh_gateway_only)"
if grep -qx -- '-i' <<< "$argv" && grep -qx -- '/home/u/.ssh/id_mlp' <<< "$argv" \
   && grep -qx -- 'IdentitiesOnly=yes' <<< "$argv"; then
    ok "4. ssh_gateway_only 帶上了 -i 與 IdentitiesOnly"
else
    bad "4. ssh_gateway_only 沒帶身分:"$'\n'"$argv"
fi

# ---- 5. mlp 的 do_connect 要去問單一來源 ---------------------------------
echo "=== 5-6. 呼叫端有沒有接上 ==="
if awk '/^do_connect\(\)/,/^}/' "$MLP" | grep -q 'SSH_IDENTITY=.*client_identity_path'; then
    ok "5. do_connect 由 client_identity_path 決定身分"
else
    bad "5. do_connect 沒有設定 SSH_IDENTITY——mlp ssh 會退回 ssh 內建候選金鑰"
fi

# ---- 6. verify-profile 的兩段 -------------------------------------------
v_opts=0; v_leg=0
grep -q 'IDENT_OPTS\[@\]' "$VERIFY" && v_opts=1
grep -q 'leg="ssh \${IDENT_LEG}' "$VERIFY" && v_leg=1
if [[ $v_opts -eq 1 && $v_leg -eq 1 ]]; then
    ok "6. verify-profile 的 SSH_OPTS 與跳板 leg 都帶身分"
else
    bad "6. verify-profile 身分不完整（opts=${v_opts} leg=${v_leg}）"
fi

# ---- 7-8. 注入 -----------------------------------------------------------
echo "=== 7-8. 注入（拿掉修正，斷言必須轉紅）==="
inj="$SANDBOX/ssh-inj.sh"
sed 's/\[\[ -n "${SSH_IDENTITY:-}" \]\] && proxy_ident="-i ${SSH_IDENTITY} -o IdentitiesOnly=yes "/: # 注入：ProxyCommand 不帶身分/' \
    "$SSH_LIB" > "$inj"
if ! grep -q '注入：ProxyCommand 不帶身分' "$inj"; then
    inj_bad "7. 注入沒生效（needle 落空）——harness 問題"
else
    ARGV_LOG="$SANDBOX/argv-inj.txt"; : > "$ARGV_LOG"
    PATH="$SANDBOX/bin:$PATH" ARGV_LOG="$ARGV_LOG" SSH_IDENTITY=/home/u/.ssh/id_mlp \
        bash -c '. "$1"; ssh_via_gateway /tmp/kh admin gw.example 22 worker 127.0.0.1 2300 true' \
        _ "$inj" >/dev/null 2>&1
    if grep -q 'ProxyCommand=ssh -i ' "$ARGV_LOG"; then
        inj_bad "7. 拔掉 ProxyCommand 身分後第 2 條仍綠——它沒在看跳板那一段"
    else
        inj_ok "7. 拔掉 ProxyCommand 身分後第 2 條會紅"
    fi
fi

inj2="$SANDBOX/mlp-inj"
python3 - "$MLP" "$inj2" <<'INJ'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
# 重現原始 bug：把 client_identity_path 整塊搬進 open_gateway_master 的函式體
m = re.search(r'^client_identity_path\(\) \{.*?^\}\n', s, re.S | re.M)
block = m.group(0)
s = s.replace(block, '', 1)
s = s.replace('open_gateway_master() {\n',
              'open_gateway_master() {\n' + ''.join('    ' + l + '\n' for l in block.split('\n')[:-1]),
              1)
open(dst, 'w', encoding='utf-8').write(s)
INJ
if grep -qE '^[[:space:]]+client_identity_path\(\)[[:space:]]*\{' "$inj2"; then
    if python3 "$SCOPE_CHK" "$inj2" >/dev/null 2>&1; then
        inj_bad "8. 把函式搬進 open_gateway_master 後第 1 條仍為綠——規則抓不到原本那個 bug"
    else
        inj_ok "8. 把函式搬進 open_gateway_master 後第 1 條會紅（重現原始 bug）"
    fi
else
    inj_bad "8. 注入沒生效（needle 落空）——harness 問題"
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
