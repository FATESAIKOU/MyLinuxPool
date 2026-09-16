#!/usr/bin/env bash
# test-tunnel-key-lib.sh — 「這台機器自己產隧道金鑰並發佈公鑰」只能有一份實作。
#
# 這條規則本來只存在於 pool-sync 的 main() 裡，register-provider 完全沒有，
# 結果是**註冊一台全新 provider 根本不會成功**：
#   step 7 啟動 pool-tunnel → 找 ~/.ssh/id_tunnel → 全新機器沒有 → 隧道起不來
#   step 9 用 ~/.ssh/id_pool 驗證 → §8 已刪除的共用金鑰 → 必定失敗
#   step 9.5 才啟用 pool-sync.timer（那才是會產金鑰的東西）→ 永遠到不了
# 2026-09-16 在 fh-l 上實跑才發現。RUNBOOK §7.12 第七次。
#
# 斷言：
#   1. repo 裡沒有任何地方還在用 id_pool 當金鑰路徑（註解說明歷史可以）。
#   2. register-provider 不自行宣告隧道金鑰路徑，而是取 TUNNEL_KEY。
#   3. main() 裡：產金鑰 → 啟動 tunnel(step7) → 驗證(step9)，順序正確。
#   4. 產+發佈的實作只有一份（scripts/lib/tunnel-key.sh）；pool-sync 只能
#      source 它，不能自己再寫一份。
#   5. 行為：缺金鑰時產出、且回傳公鑰。
#   6. 行為：已有金鑰時**不重產**——重產會讓 Gateway 既有的授權失效。
#   7. 行為：發佈是 merge 而非覆寫（hops/power/capabilities 必須留著）。
#   8. 行為：公鑰已經一致時不重寫 var。
#   9. 注入：把 id_pool 放回去 -> 1 轉紅。
#  10. 注入：從 main 拿掉產金鑰那一步 -> 3 轉紅。
#
# Run: scripts/tests/test-tunnel-key-lib.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

LIB="scripts/lib/tunnel-key.sh"
REGP="ops-scripts/register-provider.sh"
POOL_SYNC="shared-configs/pool-runtime/files/pool-sync"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-tunnel-key-lib.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

echo "=== 1-4. 只有一份實作，而且沒有死路徑 ==="

# 只看「拿 id_pool 當路徑」的寫法。排除 docs/ 與任何 tests/ 目錄：測試
# fixture 會刻意造出 ~/.ssh/id_pool，正是為了證明程式**不會**退回用它，
# 那些出現是斷言的一部分，不是違規。
LIVE_IDPOOL="$(grep -rn 'id_pool' --include='*' . 2>/dev/null \
    | grep -v '^\./\.git' \
    | grep -v '/tests/' | grep -vE '^\./docs/' \
    | grep -E '=[[:space:]]*"?[^"]*id_pool|-i[[:space:]]+[^[:space:]]*id_pool|/\.ssh/id_pool"' \
    | grep -v '^\s*#' || true)"
if [[ -z "$LIVE_IDPOOL" ]]; then
    ok "1. 沒有任何地方還把 id_pool 當成金鑰路徑"
else
    bad "1. 還有活的 id_pool 路徑:"$'\n'"$LIVE_IDPOOL"
fi

if grep -qE '^[A-Z_]*(PRIVATE_KEY|TUNNEL_KEY)=.*id_' "$REGP"; then
    bad "2. register-provider 自行宣告了隧道金鑰路徑（第二份定義）"
else
    ok "2. register-provider 不自行宣告路徑"
fi

MAIN="$(awk '/^main\(\) \{/,/^\}/' "$REGP")"
i_mint="$(printf '%s\n' "$MAIN" | grep -n 'tunnel_identity' | head -1 | cut -d: -f1)"
i_sys="$(printf '%s\n' "$MAIN"  | grep -n 'step7_systemd'  | head -1 | cut -d: -f1)"
i_ver="$(printf '%s\n' "$MAIN"  | grep -n 'step9_verify'   | head -1 | cut -d: -f1)"
if [[ -n "$i_mint" && -n "$i_sys" && -n "$i_ver" && $i_mint -lt $i_sys && $i_sys -lt $i_ver ]]; then
    ok "3. main()：產金鑰(${i_mint}) → 啟動 tunnel(${i_sys}) → 驗證(${i_ver})"
else
    bad "3. main() 順序不對（產金鑰=${i_mint:-無} tunnel=${i_sys:-無} 驗證=${i_ver:-無}）"
fi

# pool-sync 只能 source，不能自己實作
if grep -q 'tunnel-key.sh' "$POOL_SYNC" \
   && ! grep -qE 'ssh-keygen -t ed25519.*mlp-tunnel' "$POOL_SYNC"; then
    ok "4. pool-sync 只 source 共用實作，沒有自己的一份"
else
    bad "4. pool-sync 仍自己實作產金鑰（第二份實作，正是這次事故的成因）"
fi

echo "=== 5-8. 行為 ==="
mkdir -p "$SANDBOX/bin" "$SANDBOX/home/.ssh"

# 假 gh：記錄 variable set 的內容
cat > "$SANDBOX/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
case "$1 $2" in
    "api repos/"*|"api "*)
        cat "$GH_VAR_FILE" ;;
    "variable set")
        cat > "$GH_SET_FILE" ;;
    *) exit 0 ;;
esac
FAKEGH
chmod +x "$SANDBOX/bin/gh"

export GH_VAR_FILE="$SANDBOX/var.json"
export GH_SET_FILE="$SANDBOX/set.json"
cat > "$GH_VAR_FILE" <<'JSON'
{"name":"fh-l","role":"provider","hops":[{"via":"gateway"}],"power":{"wol":"aa:bb"},"capabilities":["docker"]}
JSON
: > "$GH_SET_FILE"

run_lib() {   # 在 sandbox HOME 下執行一段用到 lib 的程式
    HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
    TUNNEL_KEY="$SANDBOX/home/.ssh/id_tunnel" \
    bash -c '
        set -uo pipefail
        log() { printf "%s %s\n" "$1" "${*:2}" >&2; }
        . "'"$REPO_ROOT/$LIB"'"
        eval "$1"
    ' _ "$1" 2>"$SANDBOX/err"
}

PUB1="$(run_lib 'tunnel_key_mint fh-l && printf "%s" "$TUNNEL_KEY_PUB"')"
if [[ "$PUB1" == ssh-ed25519\ * ]] && [[ -f "$SANDBOX/home/.ssh/id_tunnel" ]]; then
    ok "5. 缺金鑰時產出一把並回傳公鑰"
else
    bad "5. 沒有產出可用的金鑰（回傳 [${PUB1}]）"
fi

PUB2="$(run_lib 'tunnel_key_mint fh-l && printf "%s" "$TUNNEL_KEY_PUB"')"
if [[ -n "$PUB1" && "$PUB1" == "$PUB2" ]]; then
    ok "6. 已有金鑰時不重產——不會讓 Gateway 既有的授權失效"
else
    bad "6. 第二次呼叫換掉了金鑰"
fi

run_lib "tunnel_key_publish NODE_FH_L owner/repo '$PUB1'" >/dev/null
if [[ -s "$GH_SET_FILE" ]]; then
    kept="$(jq -r '[.power.wol, (.hops|length|tostring), (.capabilities|join(","))] | join("|")' "$GH_SET_FILE" 2>/dev/null)"
    got="$(jq -r '.tunnel_public_key' "$GH_SET_FILE" 2>/dev/null)"
    if [[ "$kept" == "aa:bb|1|docker" && "$got" == "$PUB1" ]]; then
        ok "7. 發佈是 merge：hops/power/capabilities 都留著，公鑰寫進去了"
    else
        bad "7. 發佈覆寫了其他欄位（保留=[${kept}] 公鑰=[${got:0:20}]）"
    fi
else
    bad "7. 沒有寫出任何東西"
fi

# 已一致時不該再寫
command cp -f "$GH_SET_FILE" "$GH_VAR_FILE"
: > "$GH_SET_FILE"
run_lib "tunnel_key_publish NODE_FH_L owner/repo '$PUB1'" >/dev/null
if [[ ! -s "$GH_SET_FILE" ]]; then
    ok "8. 公鑰已一致時不重寫 var"
else
    bad "8. 公鑰沒變卻又寫了一次"
fi

echo "=== 9-10. 注入 ==="
inj="$SANDBOX/regp-idpool.sh"
sed 's|# TUNNEL_KEY is resolved in step 6.5, once the repo clone exists.|PRIVATE_KEY="${SSH_DIR}/id_pool"|' "$REGP" > "$inj"
if grep -q 'PRIVATE_KEY="${SSH_DIR}/id_pool"' "$inj"; then
    if grep -E '=[[:space:]]*"?[^"]*id_pool' "$inj" | grep -qv '^\s*#'; then
        inj_ok "9. 把 id_pool 放回去後第 1 條會紅"
    else
        inj_bad "9. 放回去了卻抓不到——第 1 條的規則太鬆"
    fi
else
    inj_bad "9. 注入沒生效（needle 落空）"
fi

inj2="$SANDBOX/regp-nomint.sh"
sed '/^    step6_5_tunnel_identity$/d' "$REGP" > "$inj2"
MAIN2="$(awk '/^main\(\) \{/,/^\}/' "$inj2")"
if printf '%s\n' "$MAIN2" | grep -q 'tunnel_identity'; then
    inj_bad "10. 注入沒生效（main 裡仍有那一步）"
else
    inj_ok "10. 從 main 拿掉產金鑰那一步後第 3 條會紅"
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
