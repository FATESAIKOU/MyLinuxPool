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

pass=0; fail=0; injfail=0; injpass=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
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

# run_lib <程式碼> [lib路徑] — 在 sandbox HOME 下執行一段用到 lib 的程式。
#   第二個參數是為了讓注入段能跑「修改過的 lib 副本」；不給就用 repo 裡那份。
run_lib() {
    local _lib="${2:-$REPO_ROOT/$LIB}"
    HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
    TUNNEL_KEY="$SANDBOX/home/.ssh/id_tunnel" \
    bash -c '
        set -uo pipefail
        log() { printf "%s %s\n" "$1" "${*:2}" >&2; }
        . "'"$_lib"'"
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

# ---------------------------------------------------------------------------
# 11-15（issue #7 / openspec D1）：回報「這一次有沒有寫入」，回傳碼語意不變。
#
# 為什麼要有：pool-sync 現在只看 tunnel_key_ensure_published 的回傳碼就決定
# 要不要 dispatch refresh，而 tunnel_key_publish 在「已一致」時也回 0
# （`if [[ … == "$pub" ]]; then return 0`）——於是每個 tick 都 dispatch，
# 一天下來就是 issue #7 裡那 1,000 次以上。
#
# 這裡釘的是「回報方式」（openspec D1：用輸出變數 TUNNEL_KEY_CHANGED，不改
# 回傳碼），不是釘某個實作。同時釘住 D1 親口點名的那個副作用風險：
# 回傳碼一改，register-provider.sh 會在「已一致」時 exit 1、pool-sync 會每輪
# 印一條假的「tunnel key convergence failed」。
# ---------------------------------------------------------------------------
BASE_VAR="$SANDBOX/base-var.json"
printf '%s\n' '{"name":"fh-l","role":"provider","hops":[{"via":"gateway"}],"power":{"wol":"aa:bb"},"capabilities":["docker"]}' > "$BASE_VAR"

changed_after() {   # changed_after <lib路徑> <var> <repo> <pub>
    GH_VAR_FILE="$SANDBOX/var-read.json" \
    run_lib "TUNNEL_KEY_CHANGED=; . '$1' >/dev/null 2>&1; tunnel_key_publish '$2' '$3' '$4' >/dev/null 2>&1; printf '%s' \"\${TUNNEL_KEY_CHANGED:-<unset>}\""
}

# mint_rc <lib路徑> — 只量 tunnel_key_mint 的回傳碼。log() 必須有定義（lib
#   會呼叫它），且它的輸出不能混進來（丟到 /dev/null）。
mint_rc() {
    HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
    TUNNEL_KEY="$SANDBOX/home/.ssh/id_tunnel" \
    bash -c 'set -uo pipefail; log() { :; }; . "$1" >/dev/null 2>&1; tunnel_key_mint fh-l >/dev/null 2>&1; printf "%s" "$?"' _ "$1" 2>/dev/null
}

echo "=== 11-15. issue #7：CHANGED 旗標與回傳碼 ==="

# 11. 剛寫入 → 旗標是 1。
printf '%s\n' "$(cat "$BASE_VAR")" > "$SANDBOX/var-read.json"
: > "$GH_SET_FILE"
got="$(changed_after "$REPO_ROOT/$LIB" NODE_FH_L owner/repo "$PUB1")"
if [[ "$got" == "1" ]]; then
    ok "11. 真的寫入之後 TUNNEL_KEY_CHANGED=1"
else
    bad "11. 寫入之後沒有回報「有寫入」（got [$got] want [1]）——pool-sync 無法判斷要不要 dispatch"
fi

# 12. 已一致 → 旗標是 0。鋪法與第 8 條相同（var 已經含同一把公鑰）。
printf '%s\n' "$(jq -c --arg pk "$PUB1" '. + {tunnel_public_key:$pk}' "$BASE_VAR")" > "$SANDBOX/var-read.json"
: > "$GH_SET_FILE"
got="$(changed_after "$REPO_ROOT/$LIB" NODE_FH_L owner/repo "$PUB1")"
if [[ "$got" == "0" ]]; then
    ok "12. 已一致（沒有寫入）之後 TUNNEL_KEY_CHANGED=0"
else
    bad "12. 沒有寫入卻回報有寫入（got [$got] want [0]）——那會讓 pool-sync 繼續每輪 dispatch"
fi

# 13. 回傳碼語意不變：成功＝0（兩條路都是）、讀不到 var＝非 0。
#     D1 明講「不改回傳碼」，這是它的護欄：改了會讓 register-provider 的
#     「已一致」路徑 exit 1（register-provider.sh:670 的 || exit 1）。
printf '%s\n' "$(cat "$BASE_VAR")" > "$SANDBOX/var-read.json"
rc_wrote="$(GH_VAR_FILE="$SANDBOX/var-read.json" run_lib "tunnel_key_publish NODE_FH_L owner/repo '$PUB1' >/dev/null 2>&1; printf '%s' \$?")"
printf '%s\n' "$(jq -c --arg pk "$PUB1" '. + {tunnel_public_key:$pk}' "$BASE_VAR")" > "$SANDBOX/var-read.json"
rc_same="$(GH_VAR_FILE="$SANDBOX/var-read.json" run_lib "tunnel_key_publish NODE_FH_L owner/repo '$PUB1' >/dev/null 2>&1; printf '%s' \$?")"
rc_noRead="$(GH_VAR_FILE="$SANDBOX/does-not-exist.json" run_lib "tunnel_key_publish NODE_FH_L owner/repo '$PUB1' >/dev/null 2>&1; printf '%s' \$?")"
if [[ "$rc_wrote" == "0" && "$rc_same" == "0" && -n "$rc_noRead" && "$rc_noRead" != "0" ]]; then
    ok "13. 回傳碼不變：寫入 0／已一致 0／讀不到 var ${rc_noRead}（非 0）"
else
    bad "13. 回傳碼語意被改動（寫入=${rc_wrote} 已一致=${rc_same} 讀不到=${rc_noRead}；前三者應為 0/0/非0）"
fi

# 14. tunnel_key_mint 的回傳值不會被「後面多一行程式碼」改掉（D1 的一環）。
#     形狀：函式結尾必須是一個**顯式的** `return 0`。沒有的話，結尾是什麼就
#     回傳什麼——在它後面加任何一行（旗標重設、一行 log）都會悄悄變成這個函式
#     的回傳值。
#     錨點用「找函式本體的最後一行」而不是比對整段文字：實作加了自己的註解
#     之後，文字針就會落空（這是真的發生過一次）。形狀變了（結尾不是 return 0）
#     時下面的 assert 會大聲失敗，不會靜靜變成量不到東西的注入。
#     這條在 D1 落地之前是紅的（那時結尾靠 `if` 湊巧回 0）。
MINT_LIB="$SANDBOX/mint-trailing-stmt.sh"
python3 - "$REPO_ROOT/$LIB" "$MINT_LIB" <<'PYMUT'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
start = next(k for k, l in enumerate(lines) if l == "tunnel_key_mint() {")
end = next(k for k in range(start + 1, len(lines)) if lines[k] == "}")
last = next(l for l in reversed(lines[start + 1:end]) if l.strip())
assert "return 0" in last, "mint does not end with an explicit return 0 (last=%r)" % last
lines[end:end] = ["    false  # INJECTED: 尾巴被加了一行——顯式 return 0 必須蓋掉它"]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
PYMUT
if [[ $? -ne 0 ]]; then
    bad "14. 注入腳本失敗（tunnel_key_mint 的結尾形狀變了）——harness 問題"
elif ! bash -n "$MINT_LIB" 2>/dev/null; then
    bad "14. 注入版語法錯誤——harness 問題"
else
    rc_mut="$(mint_rc "$MINT_LIB")"
    rc_real="$(mint_rc "$REPO_ROOT/$LIB")"
    if [[ "$rc_mut" == "0" ]]; then
        ok "14. tunnel_key_mint 在結尾被加一行非零陳述式之後仍然回 0（結尾是顯式的 return 0；真實碼也回 ${rc_real}）"
    else
        bad "14. tunnel_key_mint 的回傳值會被後面加的程式碼改掉（突變版回 ${rc_mut}，真實碼回 ${rc_real}）"
    fi
    # 14b. 正對照：14 量的是「函式的回傳碼」，不是別的東西。拿一個**明確**
    #      return 1 的突變版當量尺——它必須被讀成 1。讀不出 1，14 就沒有牙。
    MINT_LIB2="$SANDBOX/mint-explicit-rc1.sh"
    python3 - "$REPO_ROOT/$LIB" "$MINT_LIB2" <<'PYMUT2'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
start = next(k for k, l in enumerate(lines) if l == "tunnel_key_mint() {")
end = next(k for k in range(start + 1, len(lines)) if lines[k] == "}")
# 量尺必須是**取代**結尾的 return 0，不是加在它後面——加在後面會被前面的
# return 0 擋掉而永遠讀不到（第一版就這樣量到 0，14b 自己紅了）。
last = max(k for k in range(start + 1, end) if lines[k].strip())
assert "return 0" in lines[last], "mint does not end with an explicit return 0 (last=%r)" % lines[last]
lines[last] = "    return 1  # 量尺：明確的非零回傳必須被讀得到"
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
PYMUT2
    if [[ $? -ne 0 ]]; then
        inj_bad "14b. 量尺突變版造不出來（形狀變了）——harness 問題"
    else
        rc_scale="$(mint_rc "$MINT_LIB2")"
        if [[ "$rc_scale" == "1" ]]; then
            inj_ok "14b. 量尺讀得到 1（明確 return 1 的突變版回 1）——14 的判定有牙"
        else
            inj_bad "14b. 量尺讀成 [${rc_scale}]——這個量法根本沒在讀 tunnel_key_mint 的回傳碼"
        fi
    fi
fi

# 15. 旗標不能帶著上一次的值（同一個 shell 連續兩次呼叫）。
#     為什麼要有：D1 的旗標是**全域變數**，不是回傳碼。pool-sync 每個 tick 一個
#     shell 看不出差別，但任何長壽的 shell（測試、一次跑多台機器的工具、
#     被 source 進來的重複流程）都會：第一次寫入 → 旗標 1；接著 var 已經是最新，
#     第二次呼叫什麼都沒寫——若開頭沒有歸零，旗標會**殘留 1**，呼叫端看到
#     「有寫入」就照樣 dispatch。這正是 issue #7 那個 bug 的同一種病，只是換了
#     一個殘留的位置。
#     手法：兩個呼叫在**同一個** eval 裡（共用同一個 shell 的全域變數），
#     中間把假 gh 寫出的檔案搬回「var」，模擬「第一次的寫入已經生效」。
RP15_VAR="$SANDBOX/rp15-var.json"
RP15_SET="$SANDBOX/rp15-set.json"
# BASE_VAR 是**檔案路徑**（第 11 節定義時就是這麼建的），內容要用 cat 取出來。
printf '%s\n' "$(cat "$BASE_VAR")" > "$RP15_VAR"
: > "$RP15_SET"
RP15_CODE='tunnel_key_publish NODE_FH_L owner/repo "$RP_PUB" >/dev/null 2>&1
printf "after-write=%s " "${TUNNEL_KEY_CHANGED:-<unset>}"
cp -f "$RP15_SET" "$RP15_VAR"; : > "$RP15_SET"
tunnel_key_publish NODE_FH_L owner/repo "$RP_PUB" >/dev/null 2>&1
printf "after-noop=%s" "${TUNNEL_KEY_CHANGED:-<unset>}"'
got="$(GH_VAR_FILE="$RP15_VAR" RP15_VAR="$RP15_VAR" RP15_SET="$RP15_SET" RP_PUB="$PUB1" \
    run_lib "$RP15_CODE")"
if [[ "$got" == "after-write=1 after-noop=0" ]]; then
    ok "15. 同一個 shell 連續兩次：寫入後=1、接著已一致後=0（旗標不殘留）"
else
    bad "15. 旗標帶著上一次的值或寫入沒被回報（got [$got] want [after-write=1 after-noop=0]）"
fi

# 15-inj. 拿掉 publish 開頭的歸零 → 第二次呼叫會殘留 1 → 15 必須轉紅。
#     注意這個注入只有 15 抓得到：11/12/14 都是**單次**呼叫，一次呼叫裡
#     沒有前一次可殘留，所以「開頭歸零」這件事只有連續兩次的形狀看得到。
INJ_R3="$SANDBOX/tk-noreset.sh"
python3 - "$REPO_ROOT/$LIB" "$INJ_R3" <<'PYR3'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "    TUNNEL_KEY_CHANGED=0\n\n"
assert src.count(old) == 1, "reset needle count=%d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, "", 1))
PYR3
if [[ $? -ne 0 ]]; then
    inj_bad "15-inj. 突變腳本失敗（publish 開頭的歸零形狀變了）——harness 問題"
elif ! bash -n "$INJ_R3" 2>/dev/null; then
    inj_bad "15-inj. 突變版語法錯誤——harness 問題"
else
    # BASE_VAR 是**檔案路徑**（第 11 節定義時就是這麼建的），內容要用 cat 取出來。
printf '%s\n' "$(cat "$BASE_VAR")" > "$RP15_VAR"
    : > "$RP15_SET"
    got="$(GH_VAR_FILE="$RP15_VAR" RP15_VAR="$RP15_VAR" RP15_SET="$RP15_SET" RP_PUB="$PUB1" \
        run_lib "$RP15_CODE" "$INJ_R3")"
    # 判「殘留」只看第二次那一段，不要比整串：突變版第一次照樣是 1，重點是
    # after-noop 必須是 1 而**不是** 0。比整串會把「第一次有寫入」也一起
    # 綁進判準，那是另一件事（由 11 負責）。
    if [[ "$got" == *"after-noop=1"* ]]; then
        inj_ok "15-inj. 拿掉開頭歸零後第二次殘留 1（got [$got]）——15 會紅，而且只有 15 抓得到"
    else
        inj_bad "15-inj. 拿掉歸零後第二次沒有殘留（got [$got] want after-noop=1）——15 或這個注入沒在量這件事"
    fi
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
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' "$pass" "$fail" "$injpass" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
