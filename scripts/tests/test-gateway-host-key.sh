#!/usr/bin/env bash
# test-gateway-host-key.sh — Gateway 只能提供一把 host key，而且必須是
# NODE_GATEWAY 發布的那一把。
#
# 背景：sshd 預設同時提供 rsa / ecdsa / ed25519 三把，而 NODE_GATEWAY.host_key
# 只發布一把。於是 pinning 只對「剛好協商到那一把」的 client 有效——協商到
# 別把的 client 會發現指紋對不上，而最可能的「修法」是把 host key 檢查關掉，
# 等於把保護整個丟棄。pinning 在這裡特別重要，因為 Linode 會回收 IP
# （RUNBOOK §7.8）：回應那個位址的，可能是別人的機器。
#
# 2026-09-21 在拋棄式機器上實測：加上一行 HostKey 之後，強制 ECDSA 會得到
#   Unable to negotiate ... no matching host key type found. Their offer: ssh-ed25519
# 且重開機後仍然如此。
#
# 斷言：
#   1. 佈署寫出的 sshd 設定裡，HostKey 恰好一行。
#   2. 那一行是 ed25519。
#   3. 發布端與提供端一致：rotate 讀回去發布的那個檔，必須就是設定裡指定
#      的那一把。兩邊各自改一個就是漂移，而漂移的症狀是「某些 client 連不上」
#      這種很難追的東西。
#   4. 注入：拿掉 HostKey 那一行 -> 1 轉紅（回到預設三把）。
#   5. 注入：把設定改成 ecdsa 但發布端不動 -> 3 轉紅。
#
# Run: scripts/tests/test-gateway-host-key.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PROV="scripts/provision-gateway.sh"
ROTATE="scripts/rotate-gateway.sh"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# 佈署寫出的 sshd 設定就是 step1 那個 heredoc
sshd_block() { awk "/desired=\"\\\$\\(cat <<'EOF'/,/^EOF\$/" "$1"; }

N="$(sshd_block "$PROV" | grep -c '^HostKey ')"
if [[ "$N" -eq 1 ]]; then
    ok "1. sshd 設定裡 HostKey 恰好一行（命名任一把就會取代整組預設）"
else
    bad "1. HostKey 有 ${N} 行——0 行代表回到預設的三把，多行代表又提供了不只一把"
fi

CONF_KEY="$(sshd_block "$PROV" | grep '^HostKey ' | head -1 | awk '{print $2}')"
if [[ "$CONF_KEY" == */ssh_host_ed25519_key ]]; then
    ok "2. 提供的是 ed25519（${CONF_KEY}）"
else
    bad "2. 提供的不是 ed25519：${CONF_KEY:-<無>}"
fi

# rotate 讀哪個 .pub 去發布
PUB="$(grep -o '/etc/ssh/ssh_host_[a-z0-9]*_key\.pub' "$ROTATE" | head -1)"
if [[ -n "$CONF_KEY" && -n "$PUB" && "${PUB%.pub}" == "$CONF_KEY" ]]; then
    ok "3. 發布端與提供端一致（設定 ${CONF_KEY##*/}，發布 ${PUB##*/}）"
else
    bad "3. 發布的與提供的不是同一把：設定=${CONF_KEY:-<無>} 發布=${PUB:-<無>}"
fi

echo "=== 注入 ==="
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -v '^HostKey ' "$PROV" > "$T/no-hostkey.sh"
if [[ "$(sshd_block "$T/no-hostkey.sh" | grep -c '^HostKey ')" -eq 0 ]]; then
    inj_ok "4. 拿掉 HostKey 那一行後第 1 條會紅（等於回到預設三把）"
else
    inj_bad "4. 注入沒生效"
fi

sed 's|^HostKey /etc/ssh/ssh_host_ed25519_key$|HostKey /etc/ssh/ssh_host_ecdsa_key|' "$PROV" > "$T/ecdsa.sh"
INJ_KEY="$(sshd_block "$T/ecdsa.sh" | grep '^HostKey ' | head -1 | awk '{print $2}')"
if [[ "$INJ_KEY" == */ssh_host_ecdsa_key && "${PUB%.pub}" != "$INJ_KEY" ]]; then
    inj_ok "5. 只把設定改成 ecdsa（發布端不動）後第 3 條會紅"
else
    inj_bad "5. 注入沒生效（注入後設定=${INJ_KEY:-<無>}）"
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
