#!/usr/bin/env bash
# test-rotate-authkeys.sh — direct function tests for the rotate-side
# authorized_keys assembly + cloud-config rendering (task S / task U;
# docs/KEY-DESIGN.md).
#
# Task U completed the migration: the shared legacy tunnel key and the
# static authorized_keys bundles are gone (KEY-DESIGN §7). The sshproxy
# list is now built from the per-machine tunnel_public_key values alone —
# there is no shared key to union in. The safety property that replaced
# the old "shared key must be present" guard is: **an empty result must
# abort**, because an empty sshproxy list means no provider can dial in.
# The fatesaikou login list must still contain CLIENT_ACTIONS or the whole
# thing aborts. The rendered cloud-config must be valid YAML with
# ssh_authorized_keys as an ARRAY of multiple entries (not one blob).
#
# Real signatures (scripts/rotate-gateway.sh, sourced — it sets SCRIPT_DIR
# itself):
#   rotate_assemble_login_keys <clients_json> <actions_pubkey>
#       fatesaikou login list (authkeys_assemble inside). Missing Actions
#       key -> non-zero, no output.
#   rotate_assemble_sshproxy_keys <tunnel_keys>
#       sshproxy list = every machine's tunnel_public_key, one per line.
#       Empty result -> non-zero, no output.
#   rotate_render_cloud_config <template> <fatesaikou_pubkeys>
#       <sshproxy_pubkeys>
# The NODE_* role==provider filter lives in
# refresh_collect_tunnel_keys (scripts/refresh-authkeys.sh) and is tested
# here directly too (assertion 4).
#
# Assertions: 1-3 sshproxy assembly via rotate_assemble_sshproxy_keys,
# 4 provider-only filter via refresh_collect_tunnel_keys, 5 empty-result
# guard, 6 CLIENT_ACTIONS guard via rotate_assemble_login_keys,
# 7 rendered YAML valid + array shape, 8 idempotence. Injections:
# empty-result guard removed -> 5 red; multi-key squeezed into ONE string ->
# 7 red.
#
# bash 3.2 compatible on purpose (macOS ships 3.2).
# Run: scripts/tests/test-rotate-authkeys.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

ROTATE="scripts/rotate-gateway.sh"
REFRESH="scripts/refresh-authkeys.sh"

for tool in jq python3 envsubst; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: $tool is required but not found on PATH" >&2
        exit 1
    }
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-rotate-authkeys.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

# ---- fixtures ---------------------------------------------------------------
# Task U: no shared legacy key any more — the list is the machines' own
# tunnel_public_key values. SHARED_KEY is kept only as a "must never appear"
# control below, to prove the assembly is not still unioning something in.
SHARED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURESHARED legacy-shared"
PROV1_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREPROV1 fh-l"
PROV2_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREPROV2 fh-proxy"
WORKER_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREWORKER1 worker-2300"
GW_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREGATEWAY gateway"
CLIENT_A="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURECLIENTA fatesaikou-mac"
CLIENT_ACTIONS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREACTIONS actions"
KEY_ACTIONS="$(printf '%s' "$CLIENT_ACTIONS" | awk '{print $2}')"

# tunnel_keys（呼叫端已蒐集好的多行清單，含 NODE_* provider 與 POOL_WORKERS）
TUNNEL_KEYS="$PROV1_KEY"$'\n'"$PROV2_KEY"$'\n'"$WORKER_KEY"

# vars_json（gh api shape，value 是字串化 JSON）——給 refresh_collect_tunnel_keys
NODE_FH_L_VAL='{"name":"fh-l","role":"provider","tunnel_public_key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREPROV1 fh-l"}'
NODE_FH_PXY_VAL='{"name":"fh-proxy","role":"provider","tunnel_public_key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREPROV2 fh-proxy"}'
NODE_GW_VAL='{"name":"gateway","role":"gateway","tunnel_public_key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREGATEWAY gateway"}'
VARS_JSON="$(jq -n --arg v1 "$NODE_FH_L_VAL" --arg v2 "$NODE_FH_PXY_VAL" --arg vg "$NODE_GW_VAL" \
    '{total_count:3, variables:[
        {name:"NODE_FH_L", value:$v1},
        {name:"NODE_FH_PROXY", value:$v2},
        {name:"NODE_GATEWAY", value:$vg}
    ]}')"
WORKERS_JSON="$(jq -c -n --arg w "$WORKER_KEY" \
    '[{port:2300, tunnel_public_key:$w}]')"

CLIENTS_JSON="$(jq -c -n --arg a "$CLIENT_A" --arg ac "$CLIENT_ACTIONS" \
    '[{name:"fatesaikou-mac", public_key:$a, added_at:"2026-09-16T12:00:00Z"},
      {name:"actions", public_key:$ac, added_at:"2026-09-16T12:00:00Z"}]')"
CLIENTS_NO_ACTIONS="$(jq -c -n --arg a "$CLIENT_A" \
    '[{name:"fatesaikou-mac", public_key:$a, added_at:"2026-09-16T12:00:00Z"}]')"

# cloud-config template：佔位符行不含縮排；組裝函式輸出的多行清單每行
# 已帶縮排與 - 前綴，置換後成為 YAML 陣列。
TEMPLATE="$SANDBOX/cloud-config.yaml"
cat > "$TEMPLATE" <<'EOF'
#cloud-config
users:
  - name: fatesaikou
    shell: /bin/bash
    ssh_authorized_keys:
${FATESAIKOU_PUBKEYS}
  - name: sshproxy
    shell: /bin/bash
    ssh_authorized_keys:
${SSHPROXY_PUBKEYS}
ssh_pwauth: false
EOF

# ---- load the subjects ------------------------------------------------------
MISSING=0
if [[ ! -f "$ROTATE" ]]; then
    MISSING=1
    echo "test-rotate-authkeys: ${ROTATE} is missing" >&2
else
    # shellcheck source=../rotate-gateway.sh
    source "$ROTATE"
fi
if [[ ! -f "$REFRESH" ]]; then
    MISSING=1
    echo "test-rotate-authkeys: ${REFRESH} is missing" >&2
else
    # shellcheck source=../refresh-authkeys.sh
    source "$REFRESH"
fi

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

echo "── 1-3. rotate_assemble_sshproxy_keys（各機 tunnel_public_key）──"
if ! declare -F rotate_assemble_sshproxy_keys >/dev/null 2>&1; then
    bad "1-3. rotate_assemble_sshproxy_keys 未定義（scripts/rotate-gateway.sh 尚未落地）"
else
    # Task U signature: one argument (the collected tunnel keys). The
    # migration-era two-argument form took the shared key first; if that is
    # still what is installed, passing a single arg makes the shared-key
    # guard fire and every assertion here goes red — which is the intended
    # signal that the implementation has not been migrated yet.
    OUT="$(rotate_assemble_sshproxy_keys "$TUNNEL_KEYS" </dev/null 2>/dev/null)"; RC=$?
    if [[ $RC -eq 0 ]] && printf '%s\n' "$OUT" | grep -qF "$PROV1_KEY" \
       && printf '%s\n' "$OUT" | grep -qF "$PROV2_KEY"; then
        ok "1. sshproxy 清單含所有 provider 的 tunnel_public_key"
    else
        bad "1. provider 公鑰不在清單裡（rc=$RC, out=[${OUT:0:200}]）"
    fi
    if [[ $RC -eq 0 ]] && printf '%s\n' "$OUT" | grep -qF "$WORKER_KEY"; then
        ok "2. 含 POOL_WORKERS 的 tunnel_public_key"
    else
        bad "2. worker 公鑰缺失（rc=$RC, out=[${OUT:0:200}]）"
    fi
    # Task U: the shared/legacy key is gone from the design entirely. It must
    # not appear even though it was never passed in — a union implementation
    # that still decrypts and prepends it would put it here. Gate on the
    # successful single-argument assembly above: with the old signature the
    # output is empty, so "no shared key" would be true for the wrong reason.
    if [[ $RC -eq 0 ]] && printf '%s\n' "$OUT" | grep -qF "$SHARED_KEY"; then
        bad "3. 清單仍含已退役的共用公鑰——KEY-DESIGN §8 未完成（out=[${OUT:0:200}]）"
    elif [[ $RC -ne 0 ]]; then
        bad "3. 無法判定（新的單一參數介面組不出清單，rc=${RC}）"
    else
        ok "3. 不再含已退役的共用公鑰（遷移完成後不該有來源）"
    fi
fi

echo "── 4. refresh_collect_tunnel_keys：role != provider 不被收 ──"
if ! declare -F refresh_collect_tunnel_keys >/dev/null 2>&1; then
    bad "4. refresh_collect_tunnel_keys 未定義（scripts/refresh-authkeys.sh 尚未落地）"
else
    OUT="$(refresh_collect_tunnel_keys "$VARS_JSON" "$WORKERS_JSON" </dev/null 2>/dev/null)"; RC=$?
    if printf '%s\n' "$OUT" | grep -qF "$GW_KEY"; then
        bad "4. role != provider 的 NODE_GATEWAY 被誤收（其鑰在清單裡）"
    elif printf '%s\n' "$OUT" | grep -qF "$PROV1_KEY" && printf '%s\n' "$OUT" | grep -qF "$WORKER_KEY"; then
        ok "4. role != provider 的 NODE_* 不被收（provider/worker 在，gateway 不在）"
    else
        bad "4. 輸出缺 provider/worker（rc=$RC, out=[${OUT:0:200}]）"
    fi
fi

echo "── 5. 結果為空 → 中止（取代遷移期的「共用鑰必須在」防線）──"
if ! declare -F rotate_assemble_sshproxy_keys >/dev/null 2>&1; then
    bad "5. rotate_assemble_sshproxy_keys 未定義"
else
    # Precondition: assertions 5a/5b are only meaningful under the Task U
    # signature. With the old two-argument form, an empty FIRST argument
    # trips the shared-key guard — the function returns non-zero for the
    # wrong reason, and 5a/5b would "pass" without the empty-result guard
    # existing at all. The real new-contract precondition is that a
    # non-empty tunnel list assembles fine with ONE argument.
    if ! rotate_assemble_sshproxy_keys "$TUNNEL_KEYS" >/dev/null 2>&1; then
        bad "5. 前置不成立：單一參數（新的介面）無法組出清單，空清單防線無從驗證"
    else
        OUT="$(rotate_assemble_sshproxy_keys "" </dev/null 2>/dev/null)"; RC=$?
        if [[ $RC -ne 0 && -z "$OUT" ]]; then
            ok "5a. 空輸入 → 中止、非 0、不輸出"
        else
            bad "5a. 空輸入卻 rc=${RC}、out=[${OUT:0:200}]（空清單＝沒有機器撥得進來，必須硬性中止）"
        fi
        OUT="$(rotate_assemble_sshproxy_keys "$(printf '\n\n')" </dev/null 2>/dev/null)"; RC=$?
        if [[ $RC -ne 0 && -z "$OUT" ]]; then
            ok "5b. 只有空白的輸入 → 中止、非 0、不輸出"
        else
            bad "5b. 空白輸入卻 rc=${RC}、out=[${OUT:0:200}]"
        fi
    fi
fi

echo "── 6. 缺 CLIENT_ACTIONS → 中止 ──"
if ! declare -F rotate_assemble_login_keys >/dev/null 2>&1; then
    bad "6. rotate_assemble_login_keys 未定義（scripts/rotate-gateway.sh 尚未落地）"
else
    OUT="$(rotate_assemble_login_keys "$CLIENTS_JSON" "$CLIENT_ACTIONS" </dev/null 2>/dev/null)"; RC=$?
    if [[ $RC -eq 0 ]] && printf '%s\n' "$OUT" | grep -qF "$KEY_ACTIONS"; then
        ok "6a. 登入清單含 Actions（正常路徑）"
    else
        bad "6a. 正常路徑失敗（rc=$RC, out=[${OUT:0:200}]）"
    fi
    OUT="$(rotate_assemble_login_keys "$CLIENTS_NO_ACTIONS" "$CLIENT_ACTIONS" </dev/null 2>/dev/null)"; RC=$?
    if [[ $RC -ne 0 && -z "$OUT" ]]; then
        ok "6b. 缺 CLIENT_ACTIONS → 中止、非 0、不輸出"
    else
        bad "6b. 缺 CLIENT_ACTIONS 卻 rc=${RC}、out=[${OUT:0:200}]"
    fi
fi

echo "── 7. 渲染後是合法 YAML，ssh_authorized_keys 是多項目陣列 ──"
if ! declare -F rotate_render_cloud_config >/dev/null 2>&1; then
    bad "7. rotate_render_cloud_config 未定義"
else
    FATESAIKOU_LIST="      - $CLIENT_A"$'\n'"      - $CLIENT_ACTIONS"
    SSHPROXY_LIST="      - $PROV1_KEY"$'\n'"      - $PROV2_KEY"$'\n'"      - $WORKER_KEY"
    RENDERED="$SANDBOX/rendered.yaml"
    rotate_render_cloud_config "$TEMPLATE" "$FATESAIKOU_LIST" "$SSHPROXY_LIST" > "$RENDERED" 2>/dev/null
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$RENDERED" 2>/dev/null; then
        ok "7a. 渲染結果是合法 YAML（python3 yaml.safe_load 通過）"
    else
        bad "7a. 渲染結果不是合法 YAML（$(head -c 200 "$RENDERED" | tr '\n' ' ')）"
    fi
    if python3 - "$RENDERED" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
users = {u["name"]: u for u in doc.get("users", [])}
f = users.get("fatesaikou", {}).get("ssh_authorized_keys")
s = users.get("sshproxy", {}).get("ssh_authorized_keys")
ok = (isinstance(f, list) and len(f) >= 2
      and isinstance(s, list) and len(s) >= 3
      and not any(isinstance(x, str) and "\n" in x for x in (f + s)))
sys.exit(0 if ok else 1)
PY
    then
        ok "7b. fatesaikou/sshproxy 的 ssh_authorized_keys 都是多項目陣列（非單一字串）"
    else
        bad "7b. ssh_authorized_keys 不是多項目陣列（被塞成單一字串？）（$(head -c 300 "$RENDERED" | tr '\n' ' ')）"
    fi
fi

echo "── 8. 冪等：同輸入渲染兩次，位元組相同 ──"
if ! declare -F rotate_render_cloud_config >/dev/null 2>&1; then
    bad "8. rotate_render_cloud_config 未定義"
else
    C1="$(rotate_render_cloud_config "$TEMPLATE" "$FATESAIKOU_LIST" "$SSHPROXY_LIST" 2>/dev/null | cksum)"
    C2="$(rotate_render_cloud_config "$TEMPLATE" "$FATESAIKOU_LIST" "$SSHPROXY_LIST" 2>/dev/null | cksum)"
    if [[ "$C1" == "$C2" ]]; then
        ok "8. 兩次渲染位元組相同"
    else
        bad "8. 兩次渲染不同（$C1 vs ${C2}）"
    fi
fi

# ---------------------------------------------------------------------------
# 注入 1：拿掉空清單防線 → 第 5 條必須紅
# ---------------------------------------------------------------------------
echo "── 注入 1：拿掉空清單防線 ──"
if ! declare -F rotate_assemble_sshproxy_keys >/dev/null 2>&1; then
    bad "注入 1. rotate_assemble_sshproxy_keys 未定義，無從注入"
else
    INJ1="$SANDBOX/rotate-inj1.sh"
    python3 - "$ROTATE" "$INJ1" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# 中性化空清單防線：把「結果為空 → return 1」的 if 區塊換成 if false
# （guard 永遠不執行）。形狀可能是 -z "$all"、-z "$tunnel_keys" 或對
# 輸出行數的檢查，所以用較寬的比對：guard 區塊內提到 empty / -z 的那個 if。
pat = re.compile(
    r'if \[\[[^\n]*(?:-z "\$all"|-z "\$tunnel_keys"|empty)[^\n]*\]\][^\n]*\n(?:[^\n]*\n)*?^\s*fi\n',
    re.M)
new_src, n = pat.subn('if false; then\n    :\nfi\n', src)
if n == 0:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(new_src)
PY
    if [[ ! -s "$INJ1" ]]; then
        bad "注入 1. 找不到空清單 guard 可中性化（needle 落空）——harness 問題"
    else
        INJ_OUT="$(bash -c "
set -uo pipefail
source '$INJ1'
rotate_assemble_sshproxy_keys \"\$1\"
" _ "" </dev/null 2>/dev/null)"; RC=$?
        if [[ $RC -eq 0 ]]; then
            printf '  inj ok    %s\n' "注入後（拿掉空清單防線）空輸入仍 rc=0——第 5 條會紅"
        else
            bad "注入 1. 注入後仍非 0（rc=${RC}）——注入沒生效（harness 問題）"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 注入 2：多把公鑰塞成單一字串 → 第 7 條必須紅
# ---------------------------------------------------------------------------
echo "── 注入 2：ssh_authorized_keys 塞成單一字串 ──"
if ! declare -F rotate_render_cloud_config >/dev/null 2>&1; then
    bad "注入 2. rotate_render_cloud_config 未定義，無從注入"
else
    ONE_LINE_SSHPROXY="      - $(printf '%s %s' "$PROV1_KEY" "$PROV2_KEY")"
    BAD_RENDERED="$SANDBOX/rendered-bad.yaml"
    rotate_render_cloud_config "$TEMPLATE" "$FATESAIKOU_LIST" "$ONE_LINE_SSHPROXY" > "$BAD_RENDERED" 2>/dev/null
    if python3 - "$BAD_RENDERED" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
users = {u["name"]: u for u in doc.get("users", [])}
s = users.get("sshproxy", {}).get("ssh_authorized_keys")
ok = (isinstance(s, list) and len(s) >= 2
      and not any(isinstance(x, str) and "\n" in x for x in s))
sys.exit(0 if ok else 1)
PY
    then
        bad "注入 2. 單一字串塞法仍通過陣列檢查——第 7 條是空轉"
    else
        printf '  inj ok    %s\n' "注入後（單一字串塞法）陣列檢查變紅——第 7 條抓得到"
    fi
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
exit "$fail"
