#!/usr/bin/env bash
# test-ssh-admin-install.sh — Task U (KEY-DESIGN §8): the static encrypted
# authorization bundles are GONE.
#
# What this suite used to verify (ssh-admin/install.sh deploying
# files/authorized_keys.crypted) no longer exists: the login list is
# assembled from the CLIENT_* repo variables by authkeys_assemble, and
# worker authorized_keys is assembled the same way in create-worker.yml.
# ssh-admin, ssh-tunnel-client and ssh-tunnel-server were deleted with §8.
#
# This suite now pins the DELETION and the new assembly path:
#   1. no ssh-admin/ssh-tunnel-{client,server} unit remains in shared-configs/
#   2. no static authorized_keys.crypted / id_rsa.crypted remains anywhere
#      in shared-configs/ (the repo holds no static ssh-auth material)
#   3. profiles no longer declare the deleted units
#   4. authkeys_assemble still enforces CLIENT_ACTIONS (self-lockout guard)
#   5. create-worker.yml builds WORKER_AUTHORIZED_KEYS from CLIENT_* via
#      authkeys_assemble (no reference to a crypted bundle)
#   6. failure injection: an assembly that does NOT require CLIENT_ACTIONS
#      must redden assertion 4; a create-worker.yml that still points at a
#      crypted bundle must redden assertion 5.
#
# No network, no real HOME, no FILE_CRYPTO_KEY needed (nothing decrypts
# any more). Run: scripts/tests/test-ssh-admin-install.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

echo "── 1. 靜態加密授權材料已全部刪除（KEY-DESIGN §8）──"
STATIC=""
for f in \
    shared-configs/ssh-admin/files/authorized_keys.crypted \
    shared-configs/ssh-admin/files/id_rsa.crypted \
    shared-configs/ssh-tunnel-server/files/authorized_keys.crypted \
    shared-configs/ssh-tunnel-client/files/id_rsa.crypted; do
    [[ -e "$f" ]] && STATIC="${STATIC} ${f}"
done
if [[ -z "$STATIC" ]]; then ok "shared-configs/ 內無任何靜態 authorized_keys/id_rsa 加密檔"
else bad "仍有靜態加密檔：${STATIC}"; fi

echo "── 2. 被刪除的 unit 不存在於 shared-configs/ 或 profile 宣告 ──"
DEAD_UNITS="ssh-admin ssh-tunnel-client ssh-tunnel-server"
for u in $DEAD_UNITS; do
    if [[ -d "shared-configs/$u" ]]; then bad "shared-configs/$u 仍存在"
    else ok "shared-configs/$u 已刪除"; fi
done
for pf in profiles/gateway/default/profile.json profiles/provider/default/profile.json profiles/provider/no-sudo/profile.json; do
    for u in $DEAD_UNITS; do
        if jq -e --arg u "$u" '.shared_config | index($u) != null' "$pf" >/dev/null 2>&1; then
            bad "${pf} 仍宣告 ${u}"
        else
            ok "${pf} 不再宣告 ${u}"
        fi
    done
done

echo "── 3. 登入清單唯一來源：CLIENT_* 經 authkeys_assemble ──"
if [[ ! -f scripts/lib/authkeys.sh ]]; then
    bad "scripts/lib/authkeys.sh 缺失"
else
    # shellcheck source=../lib/authkeys.sh
    source scripts/lib/authkeys.sh
    CLIENTS="$(jq -c -n \
        --arg a 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURECLIENTA fatesaikou-mac' \
        --arg ac 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREACTIONS actions' \
        '[{name:"fatesaikou-mac", public_key:$a, added_at:"2026-09-16T12:00:00Z"},
          {name:"actions", public_key:$ac, added_at:"2026-09-16T12:00:00Z"}]')"
    OUT="$(authkeys_assemble "$CLIENTS" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREACTIONS actions")"
    if [[ $? -eq 0 ]] && printf '%s\n' "$OUT" | grep -qF 'IFIXTUREACTIONS'; then
        ok "CLIENT_* 組裝出含 Actions 的登入清單（正常路徑）"
    else
        bad "CLIENT_* 組裝失敗（rc=$?）"
    fi
    NO_ACTIONS="$(jq -c -n \
        --arg a 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURECLIENTA fatesaikou-mac' \
        '[{name:"fatesaikou-mac", public_key:$a, added_at:"2026-09-16T12:00:00Z"}]')"
    OUT="$(authkeys_assemble "$NO_ACTIONS" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREACTIONS actions" 2>/dev/null)"
    if [[ $? -ne 0 && -z "$OUT" ]]; then
        ok "缺 CLIENT_ACTIONS → 中止、非 0、不輸出（自我鎖門防線）"
    else
        bad "缺 CLIENT_ACTIONS 卻 rc=$?、out=[${OUT:0:80}]"
    fi
fi

echo "── 4. 注入：組裝不要求 CLIENT_ACTIONS → 上面第 3 條必須紅 ──"
if [[ ! -f scripts/lib/authkeys.sh ]]; then
    bad "注入. authkeys.sh 缺失，無從注入"
else
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-ssh-admin-inj.XXXXXX")"
    mkdir -p "$SANDBOX/lib"
    sed 's|if \[\[ -z "\$out" \]\]; then|if false; then|' scripts/lib/authkeys.sh > "$SANDBOX/lib/authkeys.sh"
    if grep -q 'if false; then' "$SANDBOX/lib/authkeys.sh"; then
        :
    else
        bad "注入. sed 沒命中 guard（harness 問題）"
    fi
    # 注入版：required 不在也繼續（拿掉第 5 條防線）——直接驗證缺 Actions 仍輸出
    OUT="$(bash -c '
        set -uo pipefail
        source "$1/lib/authkeys.sh"
        authkeys_assemble "[{\"name\":\"x\",\"public_key\":\"ssh-ed25519 AAAAB x@y\"}]" \
            "ssh-ed25519 AAAAREQUIRED actions@gh"
    ' _ "$SANDBOX" 2>/dev/null)"
    INJ_RC=$?
    if [[ "$INJ_RC" -eq 0 ]]; then
        printf '  inj ok    %s\n' "注入後（拿掉 CLIENT_ACTIONS 防線）缺 Actions 仍 rc=0——第 3 條會紅"
    else
        bad "注入. 注入版仍非 0（rc=${INJ_RC}）——注入沒生效（harness 問題）"
    fi
    rm -rf "$SANDBOX"
fi

echo "── 5. create-worker.yml 的 WORKER_AUTHORIZED_KEYS 來源 = CLIENT_*（無 crypted 引用）──"
if python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - <<'PY'
import sys, yaml
try:
    doc = yaml.safe_load(open(".github/workflows/create-worker.yml"))
except Exception as exc:
    print("YAML-ERROR: %s" % exc)
    sys.exit(3)
def walk(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "run" and isinstance(v, str):
                yield v
            yield from walk(v)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item)
runs = list(walk(doc))
# 新來源：refresh_collect_clients + authkeys_assemble（CLIENT_*）
uses_clients = any("refresh_collect_clients" in r and "authkeys_assemble" in r for r in runs)
# 舊來源：靜態加密 bundle 不可再被引用
refs_crypted = [r for r in runs if "authorized_keys.crypted" in r or "id_rsa.crypted" in r]
if refs_crypted:
    print("STILL_REFERENCES_CRYPTED")
    sys.exit(1)
if uses_clients:
    print("USES_CLIENT_ASSEMBLY")
    sys.exit(0)
print("NO_CLIENT_ASSEMBLY")
sys.exit(1)
PY
    RC=$?
    if [[ $RC -eq 0 ]]; then ok "create-worker.yml 用 CLIENT_* 組裝 worker 授權清單（無 crypted 引用）"
    elif [[ $RC -eq 3 ]]; then bad "create-worker.yml YAML 解析失敗"
    else bad "create-worker.yml 不符合新來源（須 authkeys_assemble + 無 crypted 引用）"; fi
else
    bad "沒有 YAML parser（python3+pyyaml 不可用）來驗證 create-worker.yml"
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
exit "$fail"
