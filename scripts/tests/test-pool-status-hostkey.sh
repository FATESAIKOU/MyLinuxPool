#!/usr/bin/env bash
# test-pool-status-hostkey.sh — behavioral tests for pool-status's host-key
# pinning fix (the declaration is the source of truth, never the resident
# gateway_known_hosts).
#
# Background of the bug: pool-status used $HOME/.mylinuxpool/gateway_known_hosts
# as UserKnownHostsFile. Only pool-tunnel on a PROVIDER maintains that file;
# on the operator's machine (no pool-tunnel) it goes stale forever, and when
# Linode recycles an address it produces "REMOTE HOST IDENTIFICATION HAS
# CHANGED", reporting a healthy Gateway as FAIL. The fix: write the declared
# .host_key into a TEMP known_hosts ("<ip> <host_key>") and point ssh at it,
# falling back to the old file only when the record predates host_key.
#
# All assertions are behavioral: the real pool-status runs in a sandbox
# copy of the repo, with fake pool-resolve (declaration JSON) and fake ssh
# (records every argv AND the content of whichever UserKnownHostsFile it is
# given — so "the declared key was actually used" is proven from what ssh
# saw, not from grepping the source).
#
#   1. with a declared host_key: ssh's UserKnownHostsFile is NOT the
#      resident $HOME/.mylinuxpool/gateway_known_hosts
#   2. the file ssh was given contains "<declared ip> <declared host_key>"
#   3. KEY SCENARIO: a stale gateway_known_hosts (same IP, DIFFERENT key)
#      pre-placed in the fake HOME — pool-status must still use the
#      declared key, not the stale file's
#   4. the temp pin file does not exist after pool-status exits
#   5. no declared host_key -> falls back to the resident file, does not
#      fail
#   6. injection: implementation reverted to always reading the resident
#      file -> assertions 1/3 must go red (reported separately)
#
# bash 3.2 compatible on purpose (macOS ships 3.2).
# Run: scripts/tests/test-pool-status-hostkey.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

POOL_STATUS="shared-configs/pool-runtime/files/pool-status"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi
if [[ ! -f "$POOL_STATUS" ]]; then
    echo "test-pool-status-hostkey: ${POOL_STATUS} is missing; every case below will FAIL" >&2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-pool-status-hostkey.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin" "$SANDBOX/home/.mylinuxpool" "$SANDBOX/copy"

REAL_BASH="$(command -v bash)"

# ---- fakes ---------------------------------------------------------------
# ssh: records every argv, and snapshots the content of the
# UserKnownHostsFile it was pointed at (that content is the behavioral
# proof of WHICH key was in effect). Returns success so pool-status's
# ssh-dependent checks pass.
cat > "$SANDBOX/bin/ssh" <<'FAKE_SSH'
#!/bin/bash
printf 'ssh|%s\n' "$*" >> "$FAKE_SSH_LOG"
for a in "$@"; do
    case "$a" in
        UserKnownHostsFile=*)
            p="${a#UserKnownHostsFile=}"
            printf 'ukh=%s content=[%s]\n' "$p" "$(cat "$p" 2>/dev/null | tr '\n' ' ')" >> "$FAKE_SSH_LOG"
            ;;
    esac
done
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
    *'ss -tln'*|*ss*'-tln'*) exit 0 ;;
    *workers.d*) echo '__POOL_WORKERS_D_MISSING__'; exit 0 ;;
    *) exit 0 ;;
esac
FAKE_SSH
chmod +x "$SANDBOX/bin/ssh"

# bash: intercept tcp_classify's /dev/tcp probe (treat as reachable);
# everything else goes to the real bash.
cat > "$SANDBOX/bin/bash" <<'FAKE_BASH'
#!/bin/bash
case "$*" in
    *'/dev/tcp/'*) exit 0 ;;
esac
exec "$REAL_BASH" "$@"
FAKE_BASH
chmod +x "$SANDBOX/bin/bash"

# gh: only enumerates NODE_* var names — empty answer = no providers.
cat > "$SANDBOX/bin/gh" <<'FAKE_GH'
#!/bin/bash
exit 0
FAKE_GH
chmod +x "$SANDBOX/bin/gh"

# pool-resolve: the DECLARATION. Host key / ip are injected via env so
# the same fake serves the has-key and no-key scenarios.
cat > "$SANDBOX/bin/fake-pool-resolve" <<'FAKE_PR'
#!/bin/bash
printf '%s\n' "$FAKE_GW_JSON"
FAKE_PR
chmod +x "$SANDBOX/bin/fake-pool-resolve"

rsync -a --exclude=.git ./ "$SANDBOX/copy/" 2>/dev/null \
    || cp -R . "$SANDBOX/copy/" 2>/dev/null
cp "$SANDBOX/bin/fake-pool-resolve" "$SANDBOX/copy/shared-configs/pool-runtime/files/pool-resolve"

# ---- assertions -----------------------------------------------------------
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# run_status <subject-copy-path> <out> <err> — one pool-status run
run_status() {
    local subject="$1" out="$2" err="$3"
    : > "$SANDBOX/ssh.log"
    HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
    REAL_BASH="$REAL_BASH" FAKE_SSH_LOG="$SANDBOX/ssh.log" \
    FAKE_GW_JSON="$FAKE_GW_JSON" POOL_REPO="testowner/testrepo" \
    /bin/bash "$subject" </dev/null > "$out" 2> "$err"
}

# ukh_of <ssh-log> — the UserKnownHostsFile ssh was pointed at
ukh_of() {
    sed -n 's/^ukh=\([^ ]*\) .*/\1/p' "$1" 2>/dev/null | head -1
}

# kh_content_of <ssh-log> — the content snapshot of that file (the
# snapshot collapses newlines to spaces, so a trailing space is stripped).
kh_content_of() {
    sed -n 's/^ukh=[^ ]* content=\[\(.*\)\]$/\1/p' "$1" 2>/dev/null | head -1 | sed 's/ $//'
}

DECL_IP="172.104.114.31"
DECL_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECLAREDKEY"
STALE_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISTALEKEY"

GW_JSON_WITH_KEY="{\"name\":\"gateway\",\"role\":\"gateway\",\"ip\":\"${DECL_IP}\",\"user\":\"testuser\",\"tunnel_user\":\"tunneluser\",\"host_key\":\"${DECL_KEY}\",\"generation\":8,\"ports\":{\"worker\":[2300,2399]}}"
GW_JSON_NO_KEY="{\"name\":\"gateway\",\"role\":\"gateway\",\"ip\":\"${DECL_IP}\",\"user\":\"testuser\",\"tunnel_user\":\"tunneluser\",\"generation\":8,\"ports\":{\"worker\":[2300,2399]}}"

echo "── 1-4. 宣告有 host_key ──"
FAKE_GW_JSON="$GW_JSON_WITH_KEY"
rm -rf "$SANDBOX/home/.mylinuxpool"; mkdir -p "$SANDBOX/home/.mylinuxpool"
run_status "$SANDBOX/copy/shared-configs/pool-runtime/files/pool-status" \
    "$SANDBOX/out1" "$SANDBOX/err1"

SSH_LOG="$SANDBOX/ssh.log"
UKH="$(ukh_of "$SSH_LOG")"
KH_CONTENT="$(kh_content_of "$SSH_LOG")"
FALLBACK="$SANDBOX/home/.mylinuxpool/gateway_known_hosts"

if [[ -z "$UKH" ]]; then
    bad "1. 沒有 ssh 呼叫帶 UserKnownHostsFile（ssh log: $(tr '\n' ' ' < "$SSH_LOG" | head -c 300)）"
elif [[ "$UKH" != "$FALLBACK" ]]; then
    ok "1. ssh 的 UserKnownHostsFile 不是常駐 gateway_known_hosts（用了 ${UKH}）"
else
    bad "1. ssh 仍被指向常駐 gateway_known_hosts（${UKH}）——宣告的 host_key 沒生效"
fi

if [[ "$KH_CONTENT" == "${DECL_IP} ${DECL_KEY}" ]]; then
    ok "2. ssh 拿到的檔案內容是「宣告 ip + 宣告 host_key」"
else
    bad "2. 檔案內容=[${KH_CONTENT:-<none>}]，期望「${DECL_IP} ${DECL_KEY}」"
fi

echo "── 3. 過期 gateway_known_hosts（同 IP、不同 key）──"
# 重跑：假 HOME 先放一把「同 IP 但不同 key」的常駐檔（Mac 上的過期檔）。
# pool-status 仍必須用宣告的那把。
rm -rf "$SANDBOX/home/.mylinuxpool"; mkdir -p "$SANDBOX/home/.mylinuxpool"
printf '%s %s\n' "$DECL_IP" "$STALE_KEY" > "$FALLBACK"
run_status "$SANDBOX/copy/shared-configs/pool-runtime/files/pool-status" \
    "$SANDBOX/out3" "$SANDBOX/err3"
SSH_LOG="$SANDBOX/ssh.log"
UKH="$(ukh_of "$SSH_LOG")"
KH_CONTENT="$(kh_content_of "$SSH_LOG")"
if [[ "$KH_CONTENT" == "${DECL_IP} ${DECL_KEY}" ]]; then
    ok "3. 過期檔存在仍用宣告的 key（內容=${KH_CONTENT}）"
else
    bad "3. 用了過期檔的 key（內容=[${KH_CONTENT:-<none>}]，期望宣告的 ${DECL_IP} ${DECL_KEY}）——過期檔污染了健康檢查"
fi

echo "── 4. 暫存 pin 檔結束後不存在 ──"
# 結束後由被測物的 EXIT trap 清掉：從 ssh 記錄拿到的暫存路徑必須已消失。
if [[ -n "$UKH" && "$UKH" != "$FALLBACK" ]]; then
    if [[ -e "$UKH" ]]; then
        bad "4. 暫存 pin 檔結束後仍存在：${UKH}"
    else
        ok "4. 暫存 pin 檔結束後不存在（${UKH}）"
    fi
else
    bad "4. 沒有暫存 pin 檔可驗（ssh 的 UserKnownHostsFile 是常駐檔）"
fi

echo "── 5. 宣告沒有 host_key → 退回常駐檔 ──"
rm -rf "$SANDBOX/home/.mylinuxpool"; mkdir -p "$SANDBOX/home/.mylinuxpool"
printf '%s %s\n' "$DECL_IP" "$STALE_KEY" > "$FALLBACK"
FAKE_GW_JSON="$GW_JSON_NO_KEY"
run_status "$SANDBOX/copy/shared-configs/pool-runtime/files/pool-status" \
    "$SANDBOX/out5" "$SANDBOX/err5"
SSH_LOG="$SANDBOX/ssh.log"
UKH="$(ukh_of "$SSH_LOG")"
if [[ "$UKH" == "$FALLBACK" ]]; then
    ok "5. 無宣告 host_key → 退回常駐 gateway_known_hosts"
else
    bad "5. 無宣告 host_key 卻用 [${UKH:-<none>}]（期望退回 ${FALLBACK}）——不該直接失敗"
fi
if grep -q '^\[FAIL\]' "$SANDBOX/out5"; then
    bad "5. 無 host_key 的 run 出現 FAIL（不該直接失敗）"
else
    ok "5b. 無宣告 host_key 的 run 沒有 FAIL"
fi

echo "── 6. 注入：改回寫死讀常駐檔 ──"
# 把實作改回「永遠用常駐檔」：在沙箱副本把宣告 pin 分支失效化（等價於
# 寫死讀 gateway_known_hosts）。第 1/3 條必須紅。
sed 's/if \[\[ -n "\$GW_HOST_KEY" && -n "\$GW_IP" \]\]; then/if false; then/' \
    "$SANDBOX/copy/shared-configs/pool-runtime/files/pool-status" \
    > "$SANDBOX/copy/shared-configs/pool-runtime/files/pool-status.inj"
INJ_SUBJECT="$SANDBOX/copy/shared-configs/pool-runtime/files/pool-status.inj"
INJ_RED=0

rm -rf "$SANDBOX/home/.mylinuxpool"; mkdir -p "$SANDBOX/home/.mylinuxpool"
printf '%s %s\n' "$DECL_IP" "$STALE_KEY" > "$FALLBACK"
FAKE_GW_JSON="$GW_JSON_WITH_KEY"
run_status "$INJ_SUBJECT" "$SANDBOX/out6" "$SANDBOX/err6"
SSH_LOG="$SANDBOX/ssh.log"
UKH="$(ukh_of "$SSH_LOG")"
KH_CONTENT="$(kh_content_of "$SSH_LOG")"
if [[ "$UKH" == "$FALLBACK" ]]; then
    printf '  inj ok    %s\n' "注入後 ssh 被指回常駐檔（第 1 條會紅）"
    INJ_RED=1
else
    bad "注入後 ssh 竟仍用暫存檔——注入沒生效（harness 問題）"
fi
if [[ "$KH_CONTENT" == "${DECL_IP} ${STALE_KEY}" ]]; then
    printf '  inj ok    %s\n' "注入後過期檔污染生效（第 3 條會紅）"
    INJ_RED=1
else
    bad "注入後沒用到過期檔——注入沒生效（harness 問題）"
fi
if [[ "$INJ_RED" -eq 0 ]]; then
    bad "注入：第 1/3 條都沒紅——斷言是空轉（vacuous）"
else
    ok "注入：回歸寫死常駐檔的實作被第 1/3 條抓出（會紅）"
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
exit "$fail"
