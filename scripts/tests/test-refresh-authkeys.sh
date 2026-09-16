#!/usr/bin/env bash
# test-refresh-authkeys.sh — direct function tests for
# scripts/refresh-authkeys.sh + scripts/lib/authkeys.sh (task M, rev 3).
#
# Pure functions taking parameters — no gh, no network, no fake tools:
#   refresh_collect_clients <variables_json>
#       raw `gh api .../actions/variables` output; the implementation must
#       accept BOTH top-level shapes (the GitHub API object
#       {"total_count":N,"variables":[...]} AND a bare array [...]) and
#       fromjson each .value (the API returns it as a JSON STRING).
#       stdout: JSON array of every CLIENT_* value; no CLIENT_* -> [] (0).
#       A CLIENT_* whose .value is not valid JSON -> whole call fails,
#       stdout empty (never a partial list, never a silent []).
#   refresh_collect_tunnel_keys <variables_json> <pool_workers_json>
#       stdout: one tunnel_public_key per line; empty is legal (exit 0).
#   refresh_build_install_cmd <remote_path> <content> [--sudo]
#       atomic install command string (temp + chmod + mv, never `>`).
# authkeys_assemble (scripts/lib/authkeys.sh) sourced as-is.
#
# Assertions:
#   1-3.  refresh_collect_clients (both top-level shapes, pollution, empty)
#   3b.   invalid .value -> whole-batch failure, stdout empty
#   4-6.  refresh_collect_tunnel_keys
#   7-9.  refresh_build_install_cmd (atomic / --sudo / idempotent)
#   10-12. end-to-end: collect -> assemble; self-lock guard; injection
#
# bash 3.2 compatible on purpose (macOS ships 3.2).
# Run: scripts/tests/test-refresh-authkeys.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

REFRESH="scripts/refresh-authkeys.sh"
AUTHKEYS="scripts/lib/authkeys.sh"
ROTATE="scripts/rotate-gateway.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-refresh-authkeys.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
ERRF="$SANDBOX/err"
INJ_AUTHKEYS="$SANDBOX/authkeys-inj.sh"

for tool in jq base64; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: $tool is required but not found on PATH" >&2
        exit 1
    }
done

# ---- fixtures: REAL GitHub API shapes -------------------------------------
# gh api .../actions/variables returns:
#   {"total_count":N,"variables":[{"name":...,"value":...}]}
# where .value is a JSON STRING (e.g. "{\"name\":\"actions\",...}").
PUB_A="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREKEYA fatesaikou-mac"
PUB_B="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREKEYB other-user"
PUB_ACTIONS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREACTIONS actions"
KEY_A="$(printf '%s' "$PUB_A" | awk '{print $2}')"
KEY_B="$(printf '%s' "$PUB_B" | awk '{print $2}')"
KEY_ACTIONS="$(printf '%s' "$PUB_ACTIONS" | awk '{print $2}')"
TUNNEL_1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURETUNNEL1"
TUNNEL_2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURETUNNEL2"
TUNNEL_W="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREWORKER1"

# client_value <name> <pubkey> — the CLIENT_* object, JSON
client_value() {
    jq -c -n --arg n "$1" --arg pk "$2" \
        '{name:$n, public_key:$pk, added_at:"2026-09-16T12:00:00Z"}'
}

# str_value <json> — as the API returns it: a JSON string
str_value() {
    jq -c -n --arg v "$1" '{v:$v}' | jq -c '.v' 2>/dev/null
}

# ---- fixtures (JSON, stringified values like the real API) ----------------
# 注意：.value 是 JSON 字串（內含一層轉義），所以組 fixture 時要用
# --argjson 把「已經字串化好的值」當作 JSON 字面值放進去——用 --arg 會
# 再編碼一次，變成雙重字串化，實作的 fromjson 就解不回物件。
CLIENT_A_OBJ="$(client_value "fatesaikou-mac" "$PUB_A")"
CLIENT_B_OBJ="$(client_value "other-user" "$PUB_B")"
CLIENT_AC_OBJ="$(client_value "actions" "$PUB_ACTIONS")"
STR_A="$(str_value "$CLIENT_A_OBJ")"
STR_B="$(str_value "$CLIENT_B_OBJ")"
STR_AC="$(str_value "$CLIENT_AC_OBJ")"
NODE_FH_L_OBJ="$(jq -c -n --arg t "$TUNNEL_1" '{name:"fh-l", role:"provider", tunnel_public_key:$t}')"
NODE_FH_PROXY_OBJ="$(jq -c -n --arg t "$TUNNEL_2" '{name:"fh-proxy", role:"provider", tunnel_public_key:$t}')"
NODE_GATEWAY_OBJ='{"name":"gateway","role":"gateway","tunnel_public_key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNOREME"}'
STR_FH_L="$(str_value "$NODE_FH_L_OBJ")"
STR_FH_PROXY="$(str_value "$NODE_FH_PROXY_OBJ")"
STR_GW="$(str_value "$NODE_GATEWAY_OBJ")"

# VARS_SHAPE_OBJECT: {"total_count":N,"variables":[...]} — value as JSON string
VARS_SHAPE_OBJECT="$(jq -n \
    --argjson a "$STR_A" --argjson b "$STR_B" --argjson ac "$STR_AC" \
    --argjson t1 "$STR_FH_L" --argjson t2 "$STR_FH_PROXY" --argjson gw "$STR_GW" \
    '{total_count:6,
      variables:[
        {name:"CLIENT_FATESAIKOU_MAC", value:$a},
        {name:"CLIENT_OTHER_USER",     value:$b},
        {name:"CLIENT_ACTIONS",        value:$ac},
        {name:"NODE_FH_L",             value:$t1},
        {name:"NODE_FH_PROXY",         value:$t2},
        {name:"NODE_GATEWAY",          value:$gw}
      ]}')"

# VARS_SHAPE_ARRAY: bare array, same values (value still a JSON string)
VARS_SHAPE_ARRAY="$(printf '%s' "$VARS_SHAPE_OBJECT" | jq -c '.variables')"

# POOL_WORKERS as the API returns it: a JSON string of an array
POOL_WORKERS_JSON="$(jq -c -n --arg w "$TUNNEL_W" \
    '[{port:2300, tunnel_public_key:$w}]' | jq -c .)"

# ---- load the subjects ----------------------------------------------------
MISSING=0
if [[ ! -f "$AUTHKEYS" ]]; then
    MISSING=1
    echo "test-refresh-authkeys: ${AUTHKEYS} is missing" >&2
else
    # shellcheck source=../lib/authkeys.sh
    source "$AUTHKEYS"
fi
if [[ ! -f "$REFRESH" ]]; then
    MISSING=1
    echo "test-refresh-authkeys: ${REFRESH} is missing — collect/build functions not landed yet; every case below FAILs with that reason" >&2
else
    # shellcheck source=../refresh-authkeys.sh
    source "$REFRESH"
fi
# R1-R4（事故迴歸）測的共用函式 rotate_assemble_sshproxy_keys 住在
# rotate-gateway.sh——它設定自己的 SCRIPT_DIR 並 source lib/log.sh，
# 可以安全地整支 source（test-rotate-authkeys.sh 已如此做）。
if [[ ! -f "$ROTATE" ]]; then
    MISSING=1
    echo "test-refresh-authkeys: ${ROTATE} is missing — R1-R4 事故迴歸無法執行" >&2
else
    # shellcheck source=../rotate-gateway.sh
    source "$ROTATE"
fi

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

echo "── S0 被測物可載入 ──"
if [[ "$MISSING" -eq 0 ]]; then
    ok "authkeys.sh + refresh-authkeys.sh 存在且可 source"
else
    bad "被測物缺失（見上方 stderr）"
fi

echo "── 1-3. refresh_collect_clients（兩種頂層形狀）──"
if ! declare -F refresh_collect_clients >/dev/null 2>&1; then
    bad "1-3. refresh_collect_clients 未定義（scripts/refresh-authkeys.sh 尚未落地）"
else
    OUT="$(refresh_collect_clients "$VARS_SHAPE_OBJECT" </dev/null 2>"$ERRF")"
    RC=$?
    if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | jq -e 'type == "array" and length == 3' >/dev/null 2>&1; then
        ok "1a. 頂層物件形狀（total_count+variables）→ 陣列長度 3"
    else
        bad "1a. 頂層物件形狀輸出非長度 3 陣列（rc=$RC, out=[${OUT:0:200}]）"
    fi
    if printf '%s' "$OUT" | jq -e --arg a "$PUB_A" --arg b "$PUB_B" \
        'any(.[]; .public_key == $a) and any(.[]; .public_key == $b)' >/dev/null 2>&1; then
        ok "1b. 內容含兩把使用者公鑰（fromjson 後可讀 .public_key）"
    else
        bad "1b. 內容缺公鑰或 .value 未 fromjson（out=[${OUT:0:200}]）"
    fi
    if printf '%s' "$OUT" | jq -e 'all(.[]; (.name | type == "string"))' >/dev/null 2>&1 \
       && ! printf '%s' "$OUT" | grep -q 'NODE_\|POOL_WORKERS\|IGNOREME'; then
        ok "2. NODE_* / 其他 var 不被誤收（含 role!=provider 的 gateway）"
    else
        bad "2. collect 混入 NODE_* 資料（out=[${OUT:0:200}]）"
    fi
    OUT="$(refresh_collect_clients "$VARS_SHAPE_ARRAY" </dev/null 2>/dev/null)"; RC=$?
    if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | jq -e 'type == "array" and length == 3' >/dev/null 2>&1; then
        ok "3a. 裸陣列形狀 → 陣列長度 3"
    else
        bad "3a. 裸陣列形狀輸出非長度 3 陣列（rc=$RC, out=[${OUT:0:200}]）"
    fi
    EMPTY_OBJ='{"total_count":0,"variables":[]}'
    OUT="$(refresh_collect_clients "$EMPTY_OBJ" </dev/null 2>/dev/null)"; RC=$?
    if [[ $RC -eq 0 && "$OUT" == "[]" ]]; then
        ok "3b. 完全沒有 CLIENT_* → 輸出 []、回傳 0"
    else
        bad "3b. 空集輸出 [${OUT:-<empty>}]（rc=${RC}），期望 [] 回 0"
    fi
fi

echo "── 3c. CLIENT_* 的 .value 不是合法 JSON → 整批失敗、stdout 空 ──"
if ! declare -F refresh_collect_clients >/dev/null 2>&1; then
    bad "3c. refresh_collect_clients 未定義（scripts/refresh-authkeys.sh 尚未落地）"
else
    BAD_VARS="$(printf '%s' "$VARS_SHAPE_OBJECT" | jq -c \
        '.variables[0].value = "not-json{"')"
    OUT="$(refresh_collect_clients "$BAD_VARS" </dev/null 2>/dev/null)"; RC=$?
    if [[ $RC -ne 0 && -z "$OUT" ]]; then
        ok "3c. 壞 .value → 整批失敗（非 0）、stdout 空"
    else
        bad "3c. 壞 .value 卻 rc=${RC}、out=[${OUT:0:200}]（部分成功或靜默 [] 都是假象）"
    fi
fi

echo "── 4-6. refresh_collect_tunnel_keys ──"
if ! declare -F refresh_collect_tunnel_keys >/dev/null 2>&1; then
    bad "4-6. refresh_collect_tunnel_keys 未定義（scripts/refresh-authkeys.sh 尚未落地）"
else
    OUT="$(refresh_collect_tunnel_keys "$VARS_SHAPE_OBJECT" "$POOL_WORKERS_JSON" </dev/null 2>/dev/null)"; RC=$?
    CNT="$(printf '%s\n' "$OUT" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ $RC -eq 0 && "$CNT" -eq 3 ]]; then
        ok "4. 兩 provider + 一 worker → 三行"
    else
        bad "4. 期望三行，got ${CNT}（rc=$RC, out=[${OUT:0:200}]）"
    fi
    if printf '%s\n' "$OUT" | grep -qF "$TUNNEL_1" && printf '%s\n' "$OUT" | grep -qF "$TUNNEL_2" \
       && printf '%s\n' "$OUT" | grep -qF "$TUNNEL_W"; then
        ok "4b. 三把鑰都在"
    else
        bad "4b. 缺鑰（out=[${OUT:0:200}]）"
    fi
    if printf '%s\n' "$OUT" | grep -q 'IGNOREME'; then
        bad "5. role != provider 的 NODE_* 被誤收（gateway 鑰在裡面）"
    else
        ok "5. role != provider 的 NODE_* 不被收"
    fi
    OUT="$(refresh_collect_tunnel_keys '{"total_count":0,"variables":[]}' '[]' </dev/null 2>/dev/null)"; RC=$?
    if [[ $RC -eq 0 && -z "$(printf '%s' "$OUT" | sed '/^$/d')" ]]; then
        ok "6. 都沒有 → 空輸出、回傳 0（空是合法狀態）"
    else
        bad "6. 空集輸出 [${OUT:0:100}]（rc=${RC}），期望空輸出回 0"
    fi
fi

echo "── 7-9. refresh_build_install_cmd ──"
if ! declare -F refresh_build_install_cmd >/dev/null 2>&1; then
    bad "7-9. refresh_build_install_cmd 未定義（scripts/refresh-authkeys.sh 尚未落地）"
else
    # 實作輸出整串指令的 base64（單行）；斷言一律先解碼再查形狀。
    cmd_of() { printf '%s' "$1" | base64 -d 2>/dev/null; }
    OUT="$(refresh_build_install_cmd "/home/fatesaikou/.ssh/authorized_keys" "$PUB_A" </dev/null 2>/dev/null)"; RC=$?
    DEC="$(cmd_of "$OUT")"
    if printf '%s' "$DEC" | grep -qE 'mktemp -d|mktemp' && printf '%s' "$DEC" | grep -q 'mv -f' \
       && ! printf '%s' "$DEC" | grep -qE '>\s*/home/[^ ]*authorized_keys'; then
        ok "7. 解碼後指令有「寫暫存 → chmod → mv」原子形狀，無直接覆蓋"
    else
        bad "7. 解碼後指令看不出原子形狀（rc=$RC, decoded=[${DEC:0:300}]）"
    fi
    OUT2="$(refresh_build_install_cmd "/home/sshproxy/.ssh/authorized_keys" "$TUNNEL_1" --sudo </dev/null 2>/dev/null)"
    DEC2="$(cmd_of "$OUT2")"
    if printf '%s' "$DEC2" | grep -q 'sudo '; then
        ok "8. --sudo 時指令帶 sudo"
    else
        bad "8. --sudo 指令沒有 sudo（decoded=[${DEC2:0:200}]）"
    fi
    C1="$(refresh_build_install_cmd "/home/fatesaikou/.ssh/authorized_keys" "$PUB_A" </dev/null 2>/dev/null | cksum)"
    C2="$(refresh_build_install_cmd "/home/fatesaikou/.ssh/authorized_keys" "$PUB_A" </dev/null 2>/dev/null | cksum)"
    if [[ "$C1" == "$C2" ]]; then
        ok "9. 同樣輸入 → 位元組相同（冪等）"
    else
        bad "9. 兩次輸出不同（$C1 vs ${C2}）"
    fi

    # 7c/7d: 輸出必須是「恰好一行」的 base64——$GITHUB_OUTPUT 的 key=value
    # 不吃多行，而 Linux base64 每 76 字元折行；只有把 base64 壓成單行，
    # 指令字串才能安全地放進 ${GITHUB_OUTPUT}。用一個很長的內容（20 把
    # 公鑰）測——短內容不會折行，測不出這個 bug。
    LONG_CONTENT=""
    for k in $(seq 1 20); do
        LONG_CONTENT="${LONG_CONTENT}ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREKEY${k} user${k}\n"
    done
    OUT="$(refresh_build_install_cmd "/home/fatesaikou/.ssh/authorized_keys" "$LONG_CONTENT" </dev/null 2>/dev/null)"; RC=$?
    if [[ "$OUT" != *$'\n'* ]]; then
        ok "7c. 長內容（20 把鑰）→ 輸出恰好一行（base64 單行，key=value 才吃得了）"
    else
        bad "7c. 輸出是多行（base64 折行沒被壓平）——放進 \$GITHUB_OUTPUT 的 key=value 會整步失敗"
    fi
    DECODED="$(printf '%s' "$OUT" | base64 -d 2>/dev/null)"
    if printf '%s' "$DECODED" | grep -qE 'mktemp -d|mktemp' \
       && printf '%s' "$DECODED" | grep -q 'mv -f' \
       && ! printf '%s' "$DECODED" | grep -qE '>\s*/home/[^ ]*authorized_keys'; then
        ok "7d. 解碼回來仍是原子安裝指令（寫暫存 → chmod → mv，無直接覆蓋）"
    else
        bad "7d. 解碼回來不是原子安裝指令（decoded=[${DECODED:0:300}]）"
    fi

    # 注入：把單行化移除 → 7c 必須紅。注意本機（macOS）base64 預設
    # 不折行，拿掉 tr -d 也還是單行，測不出這個 bug——所以注入用
    # `fold -w 76` 模擬 GNU base64 的 76 字元折行（workflow 跑在 Linux
    # runner 上），正是實作要壓平的形狀。
    INJ_REFRESH="$SANDBOX/refresh-inj.sh"
    python3 - "$REFRESH" "$INJ_REFRESH" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
src = src.replace("| base64 | tr -d '\\n'", "| base64 | fold -w 76")
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
    INJ_OUT="$(bash -c "
set -uo pipefail
source '$INJ_REFRESH'
refresh_build_install_cmd '/home/fatesaikou/.ssh/authorized_keys' \"\$1\"
" _ "$LONG_CONTENT" </dev/null 2>/dev/null)"
    if [[ "$INJ_OUT" == *$'\n'* ]]; then
        printf '  inj ok    %s\n' "注入後（模擬 GNU 折行的 base64）輸出多行——7c 條會紅"
    else
        bad "注入後輸出仍單行——注入沒生效（harness 問題）"
    fi
fi

echo "── 10-12. 端到端：collect → assemble ──"
if [[ "$MISSING" -ne 0 ]] || ! declare -F refresh_collect_clients >/dev/null 2>&1 \
   || ! declare -F authkeys_assemble >/dev/null 2>&1; then
    bad "10-12. 端到端無法跑（缺 refresh_collect_clients 或 authkeys_assemble）"
else
    CLIENTS="$(refresh_collect_clients "$VARS_SHAPE_OBJECT" </dev/null 2>/dev/null)"
    ASSEMBLED="$(authkeys_assemble "$CLIENTS" "$PUB_ACTIONS" </dev/null 2>"$ERRF")"; RC=$?
    if [[ $RC -eq 0 ]] && printf '%s\n' "$ASSEMBLED" | grep -qF "$KEY_A" \
       && printf '%s\n' "$ASSEMBLED" | grep -qF "$KEY_B" \
       && printf '%s\n' "$ASSEMBLED" | grep -qF "$KEY_ACTIONS"; then
        ok "10. 登入清單含所有 CLIENT_* 公鑰（含 Actions）"
    else
        bad "10. 清單缺鑰或失敗（rc=$RC, out=[${ASSEMBLED:0:200}]）"
    fi

    NOA_VARS="$(printf '%s' "$VARS_SHAPE_OBJECT" | jq -c 'del(.variables[] | select(.name == "CLIENT_ACTIONS"))')"
    CLIENTS_NOA="$(refresh_collect_clients "$NOA_VARS" </dev/null 2>/dev/null)"
    ASSEMBLED="$(authkeys_assemble "$CLIENTS_NOA" "$PUB_ACTIONS" </dev/null 2>/dev/null)"; RC=$?
    if [[ $RC -ne 0 ]]; then
        ok "11a. 缺 Actions → authkeys_assemble 非 0"
    else
        bad "11a. 缺 Actions 卻回 0（自鎖防線失效）"
    fi
    if [[ -z "$ASSEMBLED" ]]; then
        ok "11b. 缺 Actions → assemble 無輸出（不會產生任何安裝指令的原料）"
    else
        bad "11b. 缺 Actions 卻有輸出（out=[${ASSEMBLED:0:200}]）"
    fi

    echo "── 12. 注入：拿掉 required_pubkey 檢查 ──"
    INJ_AUTHKEYS="$SANDBOX/authkeys-inj.sh"
    python3 - "$AUTHKEYS" "$INJ_AUTHKEYS" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
src = src.replace(
    "| if $has_req == 0 then empty else .[] end",
    "| if false then empty else .[] end")
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
    INJ_ASSEMBLED="$(bash -c "
set -uo pipefail
source '$INJ_AUTHKEYS'
authkeys_assemble \"\$1\" \"\$2\"
" _ "$CLIENTS_NOA" "$PUB_ACTIONS" </dev/null 2>/dev/null)"; RC=$?
    if [[ $RC -eq 0 && -n "$INJ_ASSEMBLED" ]]; then
        printf '  inj ok    %s\n' "注入後 assemble 回 0 且有輸出——第 11 條會紅（自鎖防線被拿掉）"
    else
        bad "注入後 assemble 仍失敗/無輸出——注入沒生效（harness 問題）"
    fi
fi

# ---------------------------------------------------------------------------
# R1–R4: 事故迴歸測試（優先度最高）——2026-09-16 實機事故。
# refresh-authorized-keys.yml 把 Gateway 的 sshproxy authorized_keys 整份
# 覆蓋成只有一把新的各機鑰，把共用公鑰刷掉了。當時只有 fh-l 有自產鑰，
# fh-proxy 唯一能用的就是共用那把、而且它沒有任何遠端退路——差一次隧道
# 重啟就永久失聯。根因：refresh 那條路走的組裝邏輯沒有防線，任何非預期
# 的結果都會被照寫。
#
# Task U 拆掉了共用鑰（KEY-DESIGN §8），所以「共用鑰必須在」這條防線沒有
# 對象了。事故的**教訓**沒有消失：覆蓋 sshproxy 清單前必須有硬性防線。
# 取代它的是「結果為空 → 中止」——空清單代表沒有任何機器撥得進來，正是
# 這個事故的終極形態（全部鎖在外面）。這幾條會擋住一個已經真的發生過的
# 失聯事故，不得刪，只改語意。
# ---------------------------------------------------------------------------
R_FHL="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURERFHL fh-l"
R_FHPROXY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURERFHPROXY fh-proxy"

# refresh 路的 tunnel_keys = refresh_collect_tunnel_keys 的輸出（各機新鑰）
TUNNEL_KEYS="$R_FHL"$'\n'"$R_FHPROXY"

echo "── R1-R2. 事故迴歸：refresh 的 sshproxy 清單＝各機鑰完整集合 ──"
if ! declare -F rotate_assemble_sshproxy_keys >/dev/null 2>&1; then
    bad "R1-R2. rotate_assemble_sshproxy_keys 未定義（scripts/rotate-gateway.sh 尚未落地）"
else
    OUT="$(rotate_assemble_sshproxy_keys "$TUNNEL_KEYS" </dev/null 2>/dev/null)"; RC=$?
    # R1 的原始語意（「清單必須含各機鑰，不能只剩一把」）在 Task U 後
    # 變成完整集合檢查：事故當下 fh-proxy 沒有任何自產鑰，現在它有了，
    # 這條確認它的鑰真的進了清單——漏掉它就是同一種失聯。
    if [[ $RC -eq 0 ]] && printf '%s\n' "$OUT" | grep -qF "$R_FHL" \
       && printf '%s\n' "$OUT" | grep -qF "$R_FHPROXY"; then
        ok "R1. 各機鑰完整進清單（事故情境：少一把就是一台機器失聯）"
    else
        bad "R1. 清單缺各機鑰（rc=$RC, out=[${OUT:0:200}]）——事故重演：被漏掉的那台會鎖在外面"
    fi
    # R2 的原始語意（「共用與各機並存」）沒有對象了；對應的新不變式是
    # 清單不得憑空多出任何東西——只放進去的那些鑰，逐行都是輸入的子集。
    R2_OK=1
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "$line" in
            "$R_FHL"|"$R_FHPROXY") ;;
            *) R2_OK=0 ;;
        esac
    done <<< "$OUT"
    if [[ $RC -eq 0 && "$R2_OK" -eq 1 ]]; then
        ok "R2. 清單恰好是輸入的集合（沒有多餘或來源不明的鑰）"
    else
        bad "R2. 清單含輸入以外的行（rc=$RC, out=[${OUT:0:200}]）"
    fi
fi

echo "── R3. 結果為空 → 中止、不寫入（事故的終極形態）──"
if ! declare -F rotate_assemble_sshproxy_keys >/dev/null 2>&1; then
    bad "R3. rotate_assemble_sshproxy_keys 未定義"
else
    # 前置：新型介面在正常輸入下要能成功，否則空清單斷言會因為舊的兩參數
    # guard 而假通過。必須在 subshell 裡呼叫：舊介面會讓 `$2` unbound，
    # set -u 下直接呼叫會把整支測試殺掉。
    if [[ -z "$(rotate_assemble_sshproxy_keys "$TUNNEL_KEYS" 2>/dev/null)" ]]; then
        bad "R3. 前置不成立：單一參數無法組出清單，空清單防線無從驗證"
    else
        OUT="$(rotate_assemble_sshproxy_keys "" </dev/null 2>/dev/null)"; RC=$?
        if [[ $RC -ne 0 && -z "$OUT" ]]; then
            ok "R3. 空清單 → 中止、非 0、不輸出（絕不寫出沒有機器的清單）"
        else
            bad "R3. 空清單卻 rc=${RC}、out=[${OUT:0:200}]——正是事故的寫入行為"
        fi
    fi
fi

echo "── R4. 注入：拿掉空清單防線（模擬事故當下「沒有防線直接寫」）──"
if ! declare -F rotate_assemble_sshproxy_keys >/dev/null 2>&1; then
    bad "R4. rotate_assemble_sshproxy_keys 未定義，無從注入"
else
    INJ_R="$SANDBOX/rotate-inj-r.sh"
    python3 - "scripts/rotate-gateway.sh" "$INJ_R" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# 模擬事故當下：沒有「結果為空必須中止」的防線，空輸入就照樣輸出
# （空的清單被寫進 Gateway 的 authorized_keys → 全部鎖在外面）。
pat = re.compile(
    r'if \[\[[^\n]*(?:-z "\$all"|-z "\$tunnel_keys"|empty)[^\n]*\]\][^\n]*\n(?:[^\n]*\n)*?^\s*fi\n',
    re.M)
new_src, n = pat.subn('if false; then\n    :\nfi\n', src)
if n == 0:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(new_src)
PY
    if [[ ! -s "$INJ_R" ]]; then
        bad "R4. 找不到空清單 guard 可中性化（needle 落空）——harness 問題"
    else
        INJ_OUT="$(bash -c "
set -uo pipefail
source '$INJ_R'
rotate_assemble_sshproxy_keys \"\$1\"
" _ "" </dev/null 2>/dev/null)"; RC=$?
        if [[ $RC -eq 0 ]]; then
            printf '  inj ok    %s\n' "注入後（拿掉空清單防線）空輸入仍 rc=0——R3 條會紅（事故行為被重現並擋住）"
        else
            bad "R4. 注入後仍非 0（rc=${RC}）——注入沒生效（harness 問題）"
        fi
    fi
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
exit "$fail"
