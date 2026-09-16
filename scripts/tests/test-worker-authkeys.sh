#!/usr/bin/env bash
# test-worker-authkeys.sh — 「誰可以登入 worker」這件事必須是**活的**。
#
# 原本的作法是 create-worker 把組好的清單用 -e WORKER_AUTHORIZED_KEYS 灌進
# 容器，entrypoint 寫成 ~worker/.ssh/authorized_keys。後果分兩種，第二種才
# 是真正嚴重的：
#   - 新增一個 client：既有的 worker 收不到，要重建容器才生效。
#   - **撤銷**一個 client：那把金鑰在 worker 上永遠有效，直到容器被刪掉。
#     撤銷傳不到的地方，就等於沒有撤銷。
#
# 現在 provider 把組好的清單放在 ~/.mylinuxpool/clients/，唯讀掛進每個容器
# 的 /run/mlp-clients，worker 的 sshd 透過 AuthorizedKeysCommand 每次登入時
# 讀它；provider 的 pool-sync 每輪重寫該檔。
#
# 斷言：
#   1. docker run 掛上 /run/mlp-clients（唯讀）。
#   2. docker run **不再**帶 -e WORKER_AUTHORIZED_KEYS。留著它就等於留著
#      一份不會更新的靜態清單。
#   3. 種入清單的 base64 是單行——Linux 的 base64 會在 76 欄折行，折了就會
#      在單行情境被截斷（RUNBOOK §7.13 的金鑰洩漏就是這個 trap 的親戚）。
#   4. 那段 base64 解回來要與組出來的清單**逐字元相同**。
#   5. entrypoint 不寫靜態 authorized_keys，而且會刪掉舊 image 留下的那份
#      （sshd 會同時看 AuthorizedKeysFile 與 AuthorizedKeysCommand，留著
#      就等於撤銷照樣傳不到）。
#   6. Dockerfile 設好 AuthorizedKeysCommand / AuthorizedKeysCommandUser，
#      而且真的 COPY 了那支腳本。
#   7. 行為：worker-authkeys 對 worker 回傳清單、對別的使用者回傳空、
#      掛載不存在時回傳空且 rc=0（不能把過期的 provider 變成無法解釋的
#      Permission denied）。
#   8. pool-sync 會收斂 clients/ 那一份。
#   9. 注入：拿掉 pool-sync 的第二次收斂 -> 8 轉紅。
#  10. 注入：把 -e WORKER_AUTHORIZED_KEYS 加回去 -> 2 轉紅。
#
# Run: scripts/tests/test-worker-authkeys.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

CREATE="scripts/create-worker.sh"
ENTRY="profiles/worker/default/entrypoint.sh"
DOCKERFILE="profiles/worker/default/Dockerfile"
AUTHCMD="profiles/worker/default/worker-authkeys"
POOL_SYNC="shared-configs/pool-runtime/files/pool-sync"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-worker-authkeys.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- 建出一條真的 docker run 指令 ---------------------------------------
AK_LIST='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREACTIONS actions
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREFATESAIKOU fatesaikou-fwm'
PROFILE="$SANDBOX/profile.json"
printf '%s\n' '{"secrets":[],"env":[]}' > "$PROFILE"

CMD="$(
    set -uo pipefail
    source "$CREATE" 2>/dev/null
    create_worker_build_run_cmd \
        mlp-fh-l-default-1 mylinuxpool-worker-default 2300 203.0.113.9 \
        sshproxy fh-l "$AK_LIST" "$PROFILE" '{}' 2>/dev/null
)"
if [[ -z "$CMD" ]]; then
    bad "harness: create_worker_build_run_cmd 產不出指令，後面的斷言都跑不了"
    printf 'passed %d / failed %d\n' "$pass" "$fail"; exit 1
fi

echo "=== 1-4. docker run 指令 ==="
if grep -q -- '-v \$HOME/.mylinuxpool/clients:/run/mlp-clients:ro' <<<"$CMD"; then
    ok "1. 掛上了 /run/mlp-clients（唯讀）"
else
    bad "1. 沒有掛 /run/mlp-clients"
fi

if grep -q -- '-e WORKER_AUTHORIZED_KEYS' <<<"$CMD"; then
    bad "2. 仍然注入 WORKER_AUTHORIZED_KEYS——那是一份不會更新的靜態清單，撤銷傳不到"
else
    ok "2. 不再注入 WORKER_AUTHORIZED_KEYS"
fi

b64="$(grep -o "printf '%s' [A-Za-z0-9+/=]* | base64 -d" <<<"$CMD" | awk '{print $3}')"
if [[ -n "$b64" ]]; then
    ok "3. 種入清單的 base64 是單行（沒有在 76 欄折掉）"
else
    bad "3. 找不到單行的 base64——可能被折行了:"$'\n'"$CMD"
fi

if [[ -n "$b64" ]]; then
    decoded="$(printf '%s' "$b64" | base64 -d 2>/dev/null)"
    if [[ "$decoded" == "$AK_LIST" ]]; then
        ok "4. base64 解回來與組出來的清單逐字元相同"
    else
        bad "4. 解出來的清單不一致:"$'\n'"got:  ${decoded}"$'\n'"want: ${AK_LIST}"
    fi
fi

echo "=== 5-6. image 這一側 ==="
if grep -q 'rm -f "${WORKER_HOME}/.ssh/authorized_keys"' "$ENTRY" \
   && ! grep -q '> "${WORKER_HOME}/.ssh/authorized_keys"' "$ENTRY"; then
    ok "5. entrypoint 刪掉舊的靜態清單，且不再寫入新的"
else
    bad "5. entrypoint 仍會寫（或不刪）靜態 authorized_keys"
fi

d_cmd=0; d_user=0; d_copy=0
grep -q "AuthorizedKeysCommand /usr/local/bin/worker-authkeys" "$DOCKERFILE" && d_cmd=1
grep -q "AuthorizedKeysCommandUser root" "$DOCKERFILE" && d_user=1
grep -q "COPY profiles/worker/default/worker-authkeys" "$DOCKERFILE" && d_copy=1
if [[ $d_cmd -eq 1 && $d_user -eq 1 && $d_copy -eq 1 ]]; then
    ok "6. Dockerfile 設好 AuthorizedKeysCommand 並 COPY 了那支腳本"
else
    bad "6. Dockerfile 不完整（command=${d_cmd} user=${d_user} copy=${d_copy}）"
fi

echo "=== 7. worker-authkeys 的行為 ==="
mkdir -p "$SANDBOX/run/mlp-clients"
printf '%s\n' "$AK_LIST" > "$SANDBOX/run/mlp-clients/authorized_keys"
# 把腳本裡的絕對路徑改指到 sandbox，其餘照跑
sed "s#/run/mlp-clients#${SANDBOX}/run/mlp-clients#" "$AUTHCMD" > "$SANDBOX/worker-authkeys"
chmod +x "$SANDBOX/worker-authkeys"

got="$("$SANDBOX/worker-authkeys" worker 2>/dev/null)"
if [[ "$got" == "$AK_LIST" ]]; then
    ok "7a. 對 worker 回傳掛載進來的清單"
else
    bad "7a. 對 worker 的回傳不對:"$'\n'"$got"
fi

got="$("$SANDBOX/worker-authkeys" root 2>/dev/null)"
if [[ -z "$got" ]]; then
    ok "7b. 對其他使用者回傳空清單"
else
    bad "7b. 把 worker 的金鑰交給了 root:"$'\n'"$got"
fi

command rm -f "$SANDBOX/run/mlp-clients/authorized_keys"
got="$("$SANDBOX/worker-authkeys" worker 2>/dev/null)"; rc=$?
if [[ -z "$got" && $rc -eq 0 ]]; then
    ok "7c. 掛載不存在時回傳空且 rc=0"
else
    bad "7c. 掛載不存在時的行為不對（rc=${rc}）:"$'\n'"$got"
fi

echo "=== 8. provider 這一側 ==="
if awk '/^    sync_authorized_keys\(\) \{/,/^    \}/' "$POOL_SYNC" \
   | grep -q 'refresh_sync_local_authorized_keys "\$vars_json" *\\*$' \
   && awk '/^    sync_authorized_keys\(\) \{/,/^    \}/' "$POOL_SYNC" \
   | grep -q '\.mylinuxpool/clients/authorized_keys'; then
    ok "8. pool-sync 每輪也收斂 clients/authorized_keys"
else
    bad "8. pool-sync 沒有收斂 clients/authorized_keys——撤銷傳不到既有的 worker"
fi

echo "=== 9-10. 注入 ==="
inj="$SANDBOX/pool-sync-inj"
python3 - "$POOL_SYNC" "$inj" <<'INJ'
import sys, re
s = open(sys.argv[1], encoding='utf-8').read()
s = re.sub(r'\n *refresh_sync_local_authorized_keys "\$vars_json" \\\n'
           r' *"\$\{HOME\}/\.mylinuxpool/clients/authorized_keys" \|\| \{\n'
           r'.*?\n *\}\n', '\n', s, count=1, flags=re.S)
open(sys.argv[2], 'w', encoding='utf-8').write(s)
INJ
if grep -q '\.mylinuxpool/clients/authorized_keys' "$inj"; then
    inj_bad "9. 注入沒生效（needle 落空）——harness 問題"
elif awk '/^    sync_authorized_keys\(\) \{/,/^    \}/' "$inj" | grep -q '\.mylinuxpool/clients/authorized_keys'; then
    inj_bad "9. 拿掉第二次收斂後第 8 條仍為綠"
else
    inj_ok "9. 拿掉 pool-sync 的第二次收斂後第 8 條會紅"
fi

inj2="$SANDBOX/create-worker-inj.sh"
sed 's|cmd+=" -e POOL_NODE_NAME=${node_name_q}"|cmd+=" -e POOL_NODE_NAME=${node_name_q} -e WORKER_AUTHORIZED_KEYS=x"|' \
    "$CREATE" > "$inj2"
if ! grep -q 'WORKER_AUTHORIZED_KEYS=x' "$inj2"; then
    inj_bad "10. 注入沒生效（needle 落空）——harness 問題"
else
    CMD2="$(
        set -uo pipefail
        source "$inj2" 2>/dev/null
        create_worker_build_run_cmd mlp-x mylinuxpool-worker-default 2300 203.0.113.9 \
            sshproxy fh-l "$AK_LIST" "$PROFILE" '{}' 2>/dev/null
    )"
    if grep -q -- '-e WORKER_AUTHORIZED_KEYS' <<<"$CMD2"; then
        inj_ok "10. 把靜態清單加回去後第 2 條會紅"
    else
        inj_bad "10. 加回去了卻沒被第 2 條看到——它沒在看 docker run 指令"
    fi
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
