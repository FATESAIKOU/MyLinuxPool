#!/usr/bin/env bash
# test-rotate-resilience.sh — rotate 清理路徑的「不會刪錯機器」護欄。
#
# 為什麼要有：這是今天唯一會**刪 Linode 機器**的程式碼
# （rotate_cleanup_preview、rotate_orphan_sweep）。護欄的重點不是
# 「功能對不對」，是**「它不會刪錯東西」**——而每一條都必須能證明
# 「沒守衛時會刪」。特別注意：斷言不能只看 rc，要看**刪除指令有沒有真的
# 被呼叫**（linode-cli stub 記帳）。只看 rc 的話，有人讓它回 4 卻照樣刪，
# 你不會發現。
#
# 兩層保護（impl，2026-09-25 事故後）：
#   1. label 精確相等 `select(.label == "fws-preview")`——「fws」（正式機）
#      永遠不是候選；比對寫成等號，不是 endswith。
#   2. protected_ip 守衛：目標 ip == NODE_GATEWAY 現值（promote 後的
#      preview 就是正式機）→ rc 4 拒絕，id 路徑與 label 路徑都適用。
#   3. 讀不到清單 → rc 2（沒觀察到 ≠ 安全）；多於一台同名 → rc 3，拒絕猜。
#
# 情境（每個都量 rc＋刪除指令帳）：
#   A 目標就是正式 Gateway（promote 後的 preview id）→ rc 4，零刪除
#   B label 是 fws（正式機）→ 永遠不是候選
#   C API 讀不到清單 → rc 2，零刪除（未觀察 != 安全）
#   D 多於一台同名 → rc 3，拒絕猜，零刪除
#   E id 空、雲端有孤兒 → 用 label 找到並刪掉（重現 2026-09-25）
#   F 正常 preview、protected_ip 不同 → 刪掉
#   G 撞名訊息：id、年齡、「孤兒不是命名問題」
#
# 注入（每條先證明會紅：needle 命中數剛好 1＋突變版 bash -n 先過＋got 值）：
#   1. 拿掉 protected_ip 守衛 → 正式 Gateway 被刪（最重要）
#   2. label 比對從 == 改成 endswith("-preview") → 看行為變不變
#   3. API 讀不到當成「沒有機器」→ 沒觀察到被當成安全
#   4. 退回原始 Linode 錯誤訊息 → 使用者不知道真正原因
#
# 全離線：linode-cli 走 PATH stub（記帳 argv＋回放罐頭答案）。
# bash 3.2 相容（測試本體不用陣列、不用 ${var,,}、無 mapfile）。
#
# Run: scripts/tests/test-rotate-resilience.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

ROTATE="scripts/rotate-gateway.sh"
WORKFLOW=".github/workflows/rotate-gateway.yml"

for f in "$ROTATE" "$WORKFLOW"; do
    if [[ ! -f "$f" ]]; then
        echo "test-rotate-resilience: ${f} is missing; dependent cases will FAIL" >&2
    fi
done
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-rotate-resil.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
REPO="$SANDBOX/repo"
mkdir -p "$SHIMS" "$HOME_DIR" "$REPO/scripts/lib" \
         "$REPO/shared-configs/pool-runtime/files"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- 沙箱 repo：真 rotate＋真 lib（SCRIPT_DIR 的相對 source 才成立） --------
cp -p "$REPO_ROOT/$ROTATE" "$REPO/scripts/rotate-gateway.sh"
cp -p "$REPO_ROOT/scripts/lib/"*.sh "$REPO/scripts/lib/"
cp -p "$REPO_ROOT/shared-configs/pool-runtime/files/tunnel-identity.sh" \
      "$REPO/shared-configs/pool-runtime/files/tunnel-identity.sh"

# ---- linode-cli stub：記帳 argv＋回放 -----------------------------------------
#   linodes list --json   → LC_LIST_FILE（LC_LIST_OK=0 則模擬 API 讀不到）
#   linodes rm <id>       → LC_RM_RC；每次呼叫記一行 RM <id> 進 LC_LOG
#   linodes update/create → 回罐頭 JSON / rc 0
cat > "$SHIMS/linode-cli" <<'FAKE'
#!/usr/bin/env bash
printf 'ARGV %s\n' "$*" >> "${LC_LOG:-/dev/null}"
case "$1 $2" in
  "linodes list")
    if [[ "${LC_LIST_OK:-1}" == "0" ]]; then exit 1; fi
    cat "${LC_LIST_FILE:-/dev/null}"
    exit 0 ;;
  "linodes rm")
    shift 2
    for a in "$@"; do
      case "$a" in
        -*) ;;
        *)
          printf 'RM %s\n' "$a" >> "${LC_LOG:-/dev/null}"
          # 真實語意：rm 一個清單裡不存在的 id 失敗（not found）；清單裡
          # 有的才受 LC_RM_RC 控制（好讓 F2 造「刪除失敗」）。
          if ! grep -q "\"id\":$a" "${LC_LIST_FILE:-/dev/null}" 2>/dev/null; then
            exit 1
          fi
          ;;
      esac
    done
    exit "${LC_RM_RC:-0}" ;;
  "linodes update")
    exit "${LC_UPDATE_RC:-0}" ;;
esac
exit 0
FAKE
chmod +x "$SHIMS/linode-cli"

# gh stub：生產的 cleanup step 用它讀 NODE_GATEWAY 的 ip（protected_ip）。
#   GH_READ_FAIL=1 模擬讀取失敗（網路抖動／限流）——F2 的夾具。
#   成功時回 NODE_GATEWAY_JSON 裡的 .value 字串（gh 的 --jq .value 語意）。
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
[[ "${GH_READ_FAIL:-0}" == "1" ]] && exit 1
if [[ -n "${NODE_GATEWAY_JSON:-}" ]]; then
    printf '%s' "$NODE_GATEWAY_JSON"
else
    printf '%s' '{"ip":""}'
fi
exit 0
FAKE
chmod +x "$SHIMS/gh"

# ---- 夾具：一台正式 Gateway（fws）＋一台 preview ------------------------------
FIX_NORMAL='[
 {"id":1000,"label":"fws","ipv4":["198.51.100.1"],"created":"2026-09-24T00:00:00"},
 {"id":2000,"label":"fws-preview","ipv4":["203.0.113.9"],"created":"2026-09-25T10:00:00"}
]'
FIX_PROMOTED='[
 {"id":3000,"label":"fws","ipv4":["198.51.100.1"],"created":"2026-09-25T10:00:00"}
]'
FIX_TWO_PREVIEW='[
 {"id":2000,"label":"fws-preview","ipv4":["203.0.113.9"],"created":"2026-09-25T10:00:00"},
 {"id":2001,"label":"fws-preview","ipv4":["203.0.113.10"],"created":"2026-09-25T11:00:00"}
]'
FIX_ONLY_FWS='[
 {"id":1000,"label":"fws","ipv4":["198.51.100.1"],"created":"2026-09-24T00:00:00"}
]'
FIX_OTHER_SUFFIX='[
 {"id":1000,"label":"fws","ipv4":["198.51.100.1"],"created":"2026-09-24T00:00:00"},
 {"id":4000,"label":"fwsx-preview","ipv4":["203.0.113.44"],"created":"2026-09-25T10:00:00"}
]'

# rc_run <lib-path> <fixture> <list-ok> <rm-rc> <call-snippet>：
#   source 真 rotate（或突變版），eval 呼叫片段，印 RC、狀態、RM 帳。
rc_run() {
    local lib="$1" fixture="$2" list_ok="$3" rm_rc="$4" snippet="$5"
    printf '%s' "$fixture" > "$SANDBOX/list.json"
    : > "$SANDBOX/lc.log"
    LIB="$lib" LC_LIST_FILE="$SANDBOX/list.json" LC_LIST_OK="$list_ok" \
    LC_RM_RC="$rm_rc" LC_LOG="$SANDBOX/lc.log" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
    SNIPPET="$snippet" OUT="$SANDBOX/run.out" ERR="$SANDBOX/run.err" \
    bash -c '
        : > "$OUT"; : > "$ERR"
        source "$LIB" >/dev/null 2>&1
        eval "$SNIPPET" >"$OUT" 2>"$ERR"
        rc=$?
        printf "RC=%s STATE=%s ID=%s" "$rc" "${ROTATE_PREVIEW_STATE:-}" "${ROTATE_PREVIEW_ID:-}" > "$OUT.rc"
    ' 2>/dev/null
    printf '%s RM=[%s] ARGV=[%s] OUT=[%s] ERR=[%s]' \
        "$(cat "$SANDBOX/run.out.rc" 2>/dev/null)" \
        "$(grep '^RM ' "$SANDBOX/lc.log" 2>/dev/null | tr '\n' '|')" \
        "$(grep '^ARGV linodes rm' "$SANDBOX/lc.log" 2>/dev/null | tr '\n' '|')" \
        "$(tr '\n' '|' < "$SANDBOX/run.out")" \
        "$(tr '\n' '|' < "$SANDBOX/run.err")"
}

echo "=== 0. 先決條件 ==="
missing=0
for fn in rotate_find_preview_linode rotate_precheck_preview_collision rotate_cleanup_preview rotate_orphan_sweep; do
    if grep -q "^${fn}() {" "$ROTATE"; then
        :
    else
        bad "0. ${fn} 不存在——實作還沒落地？"
        missing=1
    fi
done
if [[ "$missing" -eq 0 ]]; then
    ok "0. 四個函式都在（find／precheck／cleanup／sweep）"
fi

echo "=== A. 目標就是正式 Gateway（promote 後的 preview_id）→ rc 4 且零刪除 ==="
# A1：id 路徑。promote 後 preview 已被 relabel 成 fws、ip 與 protected 相同。
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_PROMOTED" 1 0 \
    'rotate_cleanup_preview 3000 198.51.100.1')"
if [[ "$got" == RC=4* ]] && printf '%s' "$got" | grep -qF 'RM=[]' \
&& printf '%s' "$got" | grep -qF 'ARGV=[]' \
&& printf '%s' "$got" | grep -qF 'NODE_GATEWAY currently points at'; then
    ok "A1. id 路徑：rc 4、linode-cli 一次 rm 都沒呼叫（真·不刪）"
else
    bad "A1. 正式 Gateway 被當成孤兒（got [$got]）"
fi
# A2：label 路徑也要擋——受保護 ip 與 label 命中的 preview 相同。
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 1 0 \
    'rotate_cleanup_preview "" 203.0.113.9')"
if [[ "$got" == RC=4* ]] && printf '%s' "$got" | grep -qF 'RM=[]'; then
    ok "A2. label 路徑：rc 4、零刪除"
else
    bad "A2. label 路徑漏了（got [$got]）"
fi
# A3：對照——protected 不同就該刪（否則 A1/A2 是「一律不刪」的假綠）。
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 1 0 \
    'rotate_cleanup_preview 2000 198.51.100.1')"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'RM=[RM 2000|]' \
&& printf '%s' "$got" | grep -qF 'ARGV=[ARGV linodes rm 2000|]'; then
    ok "A3. 對照組：protected 不同 → 真的刪（A1/A2 不是假綠）"
else
    bad "A3. 對照組不刪——護欄會永遠綠（got [$got]）"
fi

echo "=== B. label 是 fws（正式機）→ 永遠不是候選 ==="
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_ONLY_FWS" 1 0 \
    'rotate_find_preview_linode')"
if [[ "$got" == 'RC=1 STATE=absent ID='* ]] && printf '%s' "$got" | grep -qF 'RM=[]'; then
    ok "B1. 只有 fws → absent（不是 found），零刪除"
else
    bad "B1. fws 被當成 preview 候選（got [$got]）"
fi
# B2：fws 與 fws-preview 並存時，只挑到 preview。
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 1 0 \
    'rotate_find_preview_linode; printf "%s" "$ROTATE_PREVIEW_ID"')"
if printf '%s' "$got" | grep -qF 'STATE=found ID=2000'; then
    ok "B2. 並存時挑 id 2000（preview），不是 1000（fws）"
else
    bad "B2. 挑錯機器（got [$got]）"
fi
# B3：orphan sweep 永不動 fws（連老 fws 都不刪）。
FIX_SWEEP='[
 {"id":1000,"label":"fws","ipv4":["198.51.100.1"],"created":"2020-01-01T00:00:00"},
 {"id":2000,"label":"fws-preview","ipv4":["203.0.113.9"],"created":"2020-01-01T00:00:00"}
]'
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_SWEEP" 1 0 'rotate_orphan_sweep 7200')"
if printf '%s' "$got" | grep -qF 'RM=[RM 2000|]' \
&& ! printf '%s' "$got" | grep -qF 'RM 1000'; then
    ok "B3. sweep 刪老 preview、不碰老 fws（label 排除在程式碼裡看得見）"
else
    bad "B3. sweep 對 fws 出手或漏刪 preview（got [$got]）"
fi

echo "=== C. API 讀不到清單 → rc 2、零刪除（沒觀察到 ≠ 安全） ==="
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 0 0 \
    'rotate_cleanup_preview 2000 198.51.100.1')"
if [[ "$got" == RC=2* ]] && printf '%s' "$got" | grep -qF 'RM=[]' \
&& printf '%s' "$got" | grep -qF 'NOT verified safe'; then
    ok "C1. protected_ip 有值＋清單讀不到 → rc 2、零刪除"
else
    bad "C1. 讀不到清單竟刪（got [$got]）"
fi
# C2：find 本身要說 unknown，不是 absent。
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 0 0 \
    'rotate_find_preview_linode')"
if [[ "$got" == 'RC=2 STATE=unknown ID='* ]]; then
    ok "C2. 讀不到 → STATE=unknown（不是 absent）"
else
    bad "C2. 讀不到竟當 absent（got [$got]）"
fi
# C3：cleanup 無 id 也讀不到 → rc 2、零刪除。
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 0 0 \
    'rotate_cleanup_preview "" 198.51.100.1')"
if [[ "$got" == RC=2* ]] && printf '%s' "$got" | grep -qF 'RM=[]'; then
    ok "C3. label 路徑讀不到 → rc 2、零刪除"
else
    bad "C3. label 路徑讀不到竟當 absent（got [$got]）"
fi

echo "=== D. 多於一台同名 → rc 3、拒絕猜、零刪除 ==="
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_TWO_PREVIEW" 1 0 \
    'rotate_cleanup_preview "" 198.51.100.1')"
if [[ "$got" == RC=3* ]] && printf '%s' "$got" | grep -qF 'RM=[]' \
&& printf '%s' "$got" | grep -qF 'refusing to guess'; then
    ok "D1. 兩台 fws-preview → rc 3、零刪除、訊息說拒絕猜"
else
    bad "D1. 同名多台竟刪（got [$got]）"
fi
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_TWO_PREVIEW" 1 0 \
    'rotate_find_preview_linode')"
if [[ "$got" == 'RC=3 STATE=ambiguous'* ]]; then
    ok "D2. find → STATE=ambiguous"
else
    bad "D2. find 沒說 ambiguous（got [$got]）"
fi

echo "=== E. id 空、雲端有孤兒 → 用 label 找到並刪掉（重現 2026-09-25） ==="
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 1 0 \
    'rotate_cleanup_preview "" 198.51.100.1')"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'RM=[RM 2000|]' \
&& printf '%s' "$got" | grep -qF "found by label 'fws-preview'"; then
    ok "E1. id 空 → label 找到 preview 2000 並刪（不再漏帳）"
else
    bad "E1. id 空時沒用 label 補救（got [$got]）"
fi
# E2：id 有值但機器已不在（id 被清掉）→ 退回 label。
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 1 0 \
    'rotate_cleanup_preview 9999 198.51.100.1')"
if printf '%s' "$got" | grep -qF 'RM=[RM 9999|RM 2000|]'; then
    ok "E2. id 已消失 → 先試 id 再退回 label（兩次 rm 都記帳）"
else
    bad "E2. id 消失後沒退回 label（got [$got]）"
fi
# E3：absent → rc 0、零刪除（沒有孤兒是正常結局，不是失敗）。
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_ONLY_FWS" 1 0 \
    'rotate_cleanup_preview "" 198.51.100.1')"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'RM=[]'; then
    ok "E3. absent → rc 0、零刪除（「沒東西刪」是成功）"
else
    bad "E3. absent 被當失敗或亂刪（got [$got]）"
fi

echo "=== F. 正常 preview、protected_ip 不同 → 刪掉 ==="
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 1 0 \
    'rotate_cleanup_preview 2000 198.51.100.1')"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'RM=[RM 2000|]'; then
    ok "F1. 正常路徑：rc 0、真的刪 2000"
else
    bad "F1. 正常路徑不刪（got [$got]）"
fi
# F2：rm 失敗 → rc 1（刪除失敗與「沒有機器」是不同結局）。
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 1 1 \
    'rotate_cleanup_preview 2000 198.51.100.1')"
if [[ "$got" == RC=1* ]]; then
    ok "F2. rm 失敗 → rc 1（不是 0）"
else
    bad "F2. rm 失敗的碼不對（got [$got]）"
fi

echo "=== G. 撞名訊息要說出 id／年齡／「孤兒不是命名問題」 ==="
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 1 0 \
    'rotate_precheck_preview_collision')"
if [[ "$got" == RC=1* ]] \
&& printf '%s' "$got" | grep -qF 'id 2000' \
&& printf '%s' "$got" | grep -qF 'created 2026-09-25T10:00:00' \
&& printf '%s' "$got" | grep -qF 'age' \
&& printf '%s' "$got" | grep -qF 'orphan' \
&& printf '%s' "$got" | grep -qiF 'not a naming problem'; then
    ok "G1. 撞名：rc 1、指名 id／created／age／孤兒不是命名問題"
else
    bad "G1. 撞名訊息不對（got [$got]）"
fi
# G2：無撞名 → 0；讀不到 → 0 但 WARN（不 wedge rotate）。
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_ONLY_FWS" 1 0 \
    'rotate_precheck_preview_collision')"
if [[ "$got" == RC=0* ]]; then
    ok "G2. 無撞名 → rc 0"
else
    bad "G2. 無撞名竟失敗（got [$got]）"
fi
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_NORMAL" 0 0 \
    'rotate_precheck_preview_collision')"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'could not read'; then
    ok "G3. 讀不到 → WARN、rc 0（暫時的 API 打嗝不能卡住 rotate）"
else
    bad "G3. 讀不到時行為不對（got [$got]）"
fi

echo "=== 8-11. 注入：拿掉守衛，斷言必須轉紅 ==="
# 注入檔以 single-quoted heredoc 寫，避免 $VAR 在寫檔時被展開。
mutate() {   # <n>：讀 $SANDBOX/mut-<n>.old/.new，突變真檔到 $SANDBOX/rot-inj<n>.sh
    local n="$1"
    python3 - "$REPO_ROOT/$ROTATE" "$SANDBOX/mut-$n.old" "$SANDBOX/mut-$n.new" \
        "$REPO/scripts/rot-inj$n.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = open(sys.argv[2], encoding="utf-8").read()
new = open(sys.argv[3], encoding="utf-8").read()
assert src.count(old) == 1, "needle count != 1: %d" % src.count(old)
open(sys.argv[4], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
}
mutate_ok() { [[ -f "$1" ]] && bash -n "$1" 2>/dev/null; }

# 8. 拿掉 protected_ip 守衛（id 路徑整塊）→ 正式 Gateway 被刪。
cat > "$SANDBOX/mut-8.old" <<'ND'
        if [[ -n "$protected_ip" && -n "$target_ip" && "$target_ip" == "$protected_ip" ]]; then
            log WARN "refusing to delete linode ${target_id} (by id): it is the machine NODE_GATEWAY currently points at (${protected_ip}) — clean up by hand if it really is an orphan"
            return 4
        fi
ND
printf '%s\n' '# INJECTED: protected-ip guard removed (id path)' > "$SANDBOX/mut-8.new"
if ! mutate 8 2>"$SANDBOX/i8.err" || ! mutate_ok "$REPO/scripts/rot-inj8.sh"; then
    inj_bad "8. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i8.err")"
else
    got="$(rc_run "$REPO/scripts/rot-inj8.sh" "$FIX_PROMOTED" 1 0 'rotate_cleanup_preview 3000 198.51.100.1')"
    if [[ "$got" == "RC=4"* ]] && printf '%s' "$got" | grep -qF 'RM=[]'; then
        inj_bad "8. 拿掉守衛後仍未刪——A1 沒在看刪除帳（got [$got]）"
    else
        if printf '%s' "$got" | grep -qF 'RM=[RM 3000|]'; then
            inj_ok "8. 拿掉 protected_ip 守衛後正式 Gateway 真的被 rm（got [$got]）——A1 會紅"
        else
            inj_bad "8. 行為變了但不是預期的刪除（got [$got]）——harness 問題"
        fi
    fi
fi
# 8b. label 路徑的守衛拿掉 → A2 也紅。
cat > "$SANDBOX/mut-8b.old" <<'ND'
    if [[ -n "$protected_ip" && -n "$target_ip" && "$target_ip" == "$protected_ip" ]]; then
        log WARN "refusing to delete linode ${target_id} (${target_how}): it is the machine NODE_GATEWAY currently points at (${protected_ip}) — clean up by hand if it really is an orphan"
        return 4
    fi
ND
printf '%s\n' '# INJECTED: protected-ip guard removed (label path)' > "$SANDBOX/mut-8b.new"
if ! mutate 8b 2>"$SANDBOX/i8b.err" || ! mutate_ok "$REPO/scripts/rot-inj8b.sh"; then
    inj_bad "8b. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i8b.err")"
else
    got="$(rc_run "$REPO/scripts/rot-inj8b.sh" "$FIX_NORMAL" 1 0 'rotate_cleanup_preview "" 203.0.113.9')"
    if [[ "$got" == "RC=4"* ]] && printf '%s' "$got" | grep -qF 'RM=[]'; then
        inj_bad "8b. label 路徑拿掉守衛後仍未刪（got [$got]）"
    else
        if printf '%s' "$got" | grep -qF 'RM=[RM 2000|]'; then
            inj_ok "8b. label 路徑守衛拿掉後受保護 preview 被 rm（got [$got]）——A2 會紅"
        else
            inj_bad "8b. 行為變了但不是預期的刪除（got [$got]）——harness 問題"
        fi
    fi
fi
# 9. label 比對從 == 改成 endswith("-preview")。
#    「只有 fws」情境下兩者答案相同（fws 不以 -preview 結尾），證明不了
#    影響；會變的是「以 -preview 結尾但不是精確 fws-preview」的機器。
cat > "$SANDBOX/mut-9.old" <<'ND'
    matches="$(printf '%s' "$out" | jq -c --arg l "$ROTATE_PREVIEW_LABEL" '[.[] | select(.label == $l)]' 2>/dev/null)" \
        || { ROTATE_PREVIEW_STATE="unknown"; return 2; }
ND
cat > "$SANDBOX/mut-9.new" <<'ND'
    matches="$(printf '%s' "$out" | jq -c --arg l "$ROTATE_PREVIEW_LABEL" '[.[] | select(.label | endswith("-preview"))]' 2>/dev/null)" \
        || { ROTATE_PREVIEW_STATE="unknown"; return 2; }
ND
if ! mutate 9 2>"$SANDBOX/i9.err" || ! mutate_ok "$REPO/scripts/rot-inj9.sh"; then
    inj_bad "9. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i9.err")"
else
    got="$(rc_run "$REPO/scripts/rot-inj9.sh" "$FIX_OTHER_SUFFIX" 1 0 \
        'rotate_cleanup_preview "" 198.51.100.1')"
    if printf '%s' "$got" | grep -qF 'RM=[RM 4000|]'; then
        inj_ok "9. endswith 突變後 'fwsx-preview' 被當候選並刪（got [$got]）——等號的價值＝只認精確 label"
    else
        inj_bad "9. 突變後行為未變（got [$got]）——harness 問題"
    fi
fi
# 9c. 對照：真碼下 fwsx-preview 不是候選 → absent、零刪除。
got="$(rc_run "$REPO/scripts/rotate-gateway.sh" "$FIX_OTHER_SUFFIX" 1 0 \
    'rotate_cleanup_preview "" 198.51.100.1')"
if [[ "$got" == "RC=0"* ]] && printf '%s' "$got" | grep -qF 'RM=[]'; then
    ok "9c. 真碼：'fwsx-preview' 不是候選（absent、零刪除）——等號擋住了它"
else
    bad "9c. 真碼竟把 fwsx-preview 當候選（got [$got]）"
fi
# 10. API 讀不到改成「當作沒有機器」→ 沒觀察到被當成安全。
cat > "$SANDBOX/mut-10.old" <<'ND'
    out="$(linode-cli linodes list --json 2>/dev/null)" || { ROTATE_PREVIEW_STATE="unknown"; return 2; }
    [[ -n "$out" ]] || { ROTATE_PREVIEW_STATE="unknown"; return 2; }
ND
cat > "$SANDBOX/mut-10.new" <<'ND'
    out="$(linode-cli linodes list --json 2>/dev/null)" || { ROTATE_PREVIEW_STATE="absent"; return 1; }
    [[ -n "$out" ]] || { ROTATE_PREVIEW_STATE="absent"; return 1; }
ND
if ! mutate 10 2>"$SANDBOX/i10.err" || ! mutate_ok "$REPO/scripts/rot-inj10.sh"; then
    inj_bad "10. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i10.err")"
else
    # 最強夾具：目標是 promote 後的正式 Gateway（id 3000）。真碼讀不到清單
    # 時 rc 2 拒絕；突變把「讀不到」當 absent，少了保護依據就 rm 3000。
    got="$(rc_run "$REPO/scripts/rot-inj10.sh" "$FIX_PROMOTED" 0 0 'rotate_cleanup_preview 3000 198.51.100.1')"
    if [[ "$got" == "RC=2"* ]]; then
        inj_bad "10. 讀不到仍 rc 2——注入沒生效（got [$got]）"
    else
        if printf '%s' "$got" | grep -qF 'RM=[RM 3000|]'; then
            inj_ok "10. 讀不到被當 absent → 正式 Gateway 被 rm、無人知道（got [$got]）——C1/C3 會紅"
        else
            inj_bad "10. 行為變了但不是預期的假安全（got [$got]）——harness 問題"
        fi
    fi
fi
# 11. 退回原始 Linode 錯誤訊息 → 撞名訊息不再指名真正原因。
cat > "$SANDBOX/mut-11.old" <<'ND'
            log ERROR "that is an orphan from an earlier rotate — not a naming problem, which is what Linode's 'Label must be unique' would have you believe"
ND
cat > "$SANDBOX/mut-11.new" <<'ND'
            log ERROR "Label must be unique among your linodes"
ND
if ! mutate 11 2>"$SANDBOX/i11.err" || ! mutate_ok "$REPO/scripts/rot-inj11.sh"; then
    inj_bad "11. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i11.err")"
else
    got="$(rc_run "$REPO/scripts/rot-inj11.sh" "$FIX_NORMAL" 1 0 'rotate_precheck_preview_collision')"
    if printf '%s' "$got" | grep -qiF 'not a naming problem'; then
        inj_bad "11. 突變後仍說 not a naming problem——注入沒生效（got [$got]）"
    else
        if printf '%s' "$got" | grep -qF 'Label must be unique'; then
            inj_ok "11. 退回原始訊息後只看到『Label must be unique』、真正原因消失（got [$got]）——G1 會紅"
        else
            inj_bad "11. 行為變了但不是預期的退回（got [$got]）——harness 問題"
        fi
    fi
fi
echo "=== P. 生產呼叫形狀：-eo pipefail 下 workflow step 的行為 ==="
# 為什麼多這一組：上面 21 條的 harness 是 `bash -c`（沒有 -e），所以它們
# 看到的是函式的真值 rc——但**生產的呼叫形狀從未被測**。workflow 的
# 清理步驟跑在 `bash -eo pipefail`（GitHub 預設），而它是**裸呼叫**：
#     rotate_cleanup_preview ... ; case $? in ...
# `-e` 之下函式回非 0（absent=1、unknown=2、ambiguous=3、refused=4）
# 直接中止 step，後面的 `case $?` 是死碼，那些 ::warning:: 從來不會印
# ——而 warning 才是使用者會看到的東西。
#
# 這一組抽「真 workflow 的 cleanup step」、以生產選項 `bash -eo pipefail`
# 跑真 step，斷言的是**可觀測結果**：哪一個 ::warning:: 印出來（4 的分支
# vs 一般失敗分支 vs 不印）、以及 linode-cli rm 帳。刻意**不**斷言 step
# 的整體 rc——那是實作可選的設計（清理步驟是否該讓 workflow 失敗），
# 猜它就等於替 impl 決定修法。rc 是否「活著」由「對應分支的 warning 真的
# 印出來」證明：rc 死掉時什麼都不會印（今天的 bug）。
python3 - "$REPO_ROOT/$WORKFLOW" "$SANDBOX/cleanup-step.sh" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for s in doc["jobs"]["rotate"]["steps"]:
    if (s.get("name") or "").startswith("Clean up preview machine"):
        open(sys.argv[2], "w", encoding="utf-8").write(s["run"])
        break
else:
    sys.exit("cleanup step not found")
PY
if [[ ! -s "$SANDBOX/cleanup-step.sh" ]]; then
    bad "P0. 抽不到 cleanup step——harness 問題"
else
    # step_run <fixture> <list-ok> <rm-rc> <preview-id> <gw-json> <tag>：
    # 代換 ${{ ...preview_id }}，在 `bash -eo pipefail` 下跑真 step，量
    # 刪除帳與 ::warning:: 行。印 `RM=[...] WARN=[...] OUT=[...]`。
    step_run() {
        local fixture="$1" list_ok="$2" rm_rc="$3" want_id="$4" gw="$5" tag="$6"
        local gh_fail="${7:-0}"
        printf '%s' "$fixture" > "$SANDBOX/list.json"
        : > "$SANDBOX/lc.log"
        python3 - "$SANDBOX/cleanup-step.sh" "$want_id" "$SANDBOX/step-run.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
src = src.replace('${{ steps.create_preview.outputs.preview_id }}', sys.argv[2])
open(sys.argv[3], "w", encoding="utf-8").write(src)
PY
        ( cd "$REPO" && GH_REPO=testowner/testrepo NODE_GATEWAY_JSON="$gw" \
            GH_READ_FAIL="$gh_fail" \
            LC_LIST_FILE="$SANDBOX/list.json" LC_LIST_OK="$list_ok" LC_RM_RC="$rm_rc" \
            LC_LOG="$SANDBOX/lc.log" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
            bash -eo pipefail "$SANDBOX/step-run.sh" ) >"$SANDBOX/p-$tag.out" 2>"$SANDBOX/p-$tag.err"
        printf 'RM=[%s] WARN=[%s] OUT=[%s] ERR=[%s]' \
            "$(grep '^RM ' "$SANDBOX/lc.log" 2>/dev/null | tr '\n' '|')" \
            "$(grep -o '::warning::[^"]*' "$SANDBOX/p-$tag.out" 2>/dev/null | sed 's/::warning:://' | tr '\n' '|')" \
            "$(tr '\n' '|' < "$SANDBOX/p-$tag.out")" \
            "$(tr '\n' '|' < "$SANDBOX/p-$tag.err")"
    }
    # P1：目標是正式 Gateway（protected）→ 使用者應看到「refused …
    #     NODE_GATEWAY still points at it」這個**專屬** warning（不是一般
    #     的那個），且零刪除。warning 印出來即證明 rc=4 活著抵達 case。
    got="$(step_run "$FIX_PROMOTED" 1 0 3000 '{"ip":"198.51.100.1"}' p1)"
    if printf '%s' "$got" | grep -qF 'RM=[]' \
    && printf '%s' "$got" | grep -qF 'refused to delete the preview because NODE_GATEWAY still points at it' \
    && ! printf '%s' "$got" | grep -qF 'could not delete preview linode'; then
        ok "P1. -eo pipefail 下 protected：refused warning 印出、零刪除（rc 4 活著抵達分支）"
    else
        bad "P1. refused warning 沒印（rc 在真實呼叫點失效）或刪錯（got [$got]）"
    fi
    # P2：rm 失敗（函式 rc 1）→ 一般失敗 warning 印出。
    got="$(step_run "$FIX_NORMAL" 1 1 2000 '{"ip":"198.51.100.1"}' p2)"
    if printf '%s' "$got" | grep -qF 'could not delete preview linode' \
    && printf '%s' "$got" | grep -qF 'RM=[RM 2000|'; then
        ok "P2. -eo pipefail 下 rm 失敗：一般失敗 warning 印出、刪除有嘗試"
    else
        bad "P2. rm 失敗路徑的 warning 沒印（got [$got]）"
    fi
    # P3：unknown（清單讀不到）→ 使用者必須看到**某個** warning（確切文字
    #     是 impl 的選擇：它可以與一般失敗分開，如現在的
    #     「could not read the Linode list … nothing was deleted」），且零刪除。
    #     契約是「有訊息、沒刪」，不是特定句子。
    got="$(step_run "$FIX_PROMOTED" 0 0 3000 '{"ip":"198.51.100.1"}' p3)"
    if printf '%s' "$got" | grep -qF 'WARN=[' \
    && printf '%s' "$got" | grep -qF 'RM=[]' \
    && printf '%s' "$got" | grep -qF '::warning::'; then
        ok "P3. -eo pipefail 下清單讀不到：warning 印出、零刪除"
    else
        bad "P3. 清單讀不到時 warning 沒印或誤刪（got [$got]）"
    fi
    # P4：正常成功 → 無任何 warning、刪對機器。
    got="$(step_run "$FIX_NORMAL" 1 0 2000 '{"ip":"198.51.100.1"}' p4)"
    if printf '%s' "$got" | grep -qF 'RM=[RM 2000|' \
    && ! printf '%s' "$got" | grep -qF '::warning::'; then
        ok "P4. -eo pipefail 下成功：無 warning、刪對機器"
    else
        bad "P4. 成功路徑不對（got [$got]）"
    fi
    # P5（靜態，輔助）：呼叫端不得是「裸呼叫緊接 case $?」——-e 下 case 是
    # 死碼。任一被接受的形狀（|| rc=$?、$() 捕捉、或不再裸呼叫）即可；
    # 這條不取代 P1-P4，只是讓 F1 的失敗訊息更直指病灶。
    if python3 - "$WORKFLOW" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
for i, l in enumerate(lines):
    if re.match(r'^\s*rotate_cleanup_preview\b', l):
        if '||' in l or '$(' in l or 'rc=' in l:
            continue
        nxt = next((x.strip() for x in lines[i+1:] if x.strip() and not x.strip().startswith('#')), '')
        # 只認「裸呼叫緊接 case $?」這個確切的死碼形狀；其他重構都是實作自由。
        if re.match(r'^case\s+\$\?\s+in', nxt):
            sys.exit(1)
sys.exit(0)
PY
    then
        ok "P5. 呼叫端的 rc 是活的（非裸呼叫＋case \$?）"
    else
        bad "P5. rotate_cleanup_preview 仍是裸呼叫＋case \$?——-e 下 case 是死碼（F1）"
    fi
    # P6（F2，fail-open 的生產形狀）：讀 protected_ip 失敗 → 今天被當成
    #     「呼叫者聲明不需要保護」→ 唯一活著的機器（promote 後就是正式
    #     Gateway）被刪。斷言只看底線——**受保護的機器不得被刪**（RM 不含
    #     3000）；訊息形狀是 impl 的自由。這是「讀不到 ≠ 不需要保護」在
    #     真實呼叫點的樣子。
    # 夾具必須讓函式真的走到刪除路徑（清單裡另有一台 preview，find 回 0），
    # 才是在測 F2 而不是被 -e 中止掩蓋。目標 3000 是 relabel 後的正式
    # Gateway（label fws、ip == 原 protected）；gh 讀 protected 失敗。
    FIX_GHFAIL='[
     {"id":3000,"label":"fws","ipv4":["198.51.100.1"],"created":"2026-09-25T10:00:00"},
     {"id":4000,"label":"fws-preview","ipv4":["203.0.113.44"],"created":"2026-09-25T11:00:00"}
    ]'
    got="$(step_run "$FIX_GHFAIL" 1 0 3000 '{"ip":"198.51.100.1"}' p6 1)"
    if printf '%s' "$got" | grep -q 'RM=\[\]'; then
        ok "P6. protected_ip 讀不到 → 零刪除（沒觀察到不等於安全）"
    else
        bad "P6. protected_ip 讀不到竟把受保護機器刪了（F2 fail-open；got [$got]）"
    fi
fi

# 12. 生產形狀的回歸注入：把 F1 的修法拿掉（裸呼叫＋case $?）→ P1/P3/P5 轉紅。
#     注入打在**抽出的 step 文字**上（真 workflow 檔不動），這正是 qa 描述
#     的原始形狀。
if [[ ! -s "$SANDBOX/cleanup-step.sh" ]]; then
    inj_bad "12. 抽出的 cleanup step 不存在——harness 問題"
else
    python3 - "$SANDBOX/cleanup-step.sh" "$SANDBOX/cleanup-nof1.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
src = src.replace('rc=0\n', '', 1)
src = src.replace(' || rc=$?', '')
src = src.replace('case "$rc" in', 'case $? in')
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
    # step_run2：同 step_run 但可指定 step 檔。
    step_run2() {
        local step="$1" fixture="$2" list_ok="$3" rm_rc="$4" want_id="$5" gw="$6" tag="$7"
        local gh_fail="${8:-0}"
        printf '%s' "$fixture" > "$SANDBOX/list.json"
        : > "$SANDBOX/lc.log"
        python3 - "$step" "$want_id" "$SANDBOX/step-run2.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
src = src.replace('${{ steps.create_preview.outputs.preview_id }}', sys.argv[2])
open(sys.argv[3], "w", encoding="utf-8").write(src)
PY
        ( cd "$REPO" && GH_REPO=testowner/testrepo NODE_GATEWAY_JSON="$gw" \
            GH_READ_FAIL="$gh_fail" \
            LC_LIST_FILE="$SANDBOX/list.json" LC_LIST_OK="$list_ok" LC_RM_RC="$rm_rc" \
            LC_LOG="$SANDBOX/lc.log" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
            bash -eo pipefail "$SANDBOX/step-run2.sh" ) >"$SANDBOX/p-$tag.out" 2>"$SANDBOX/p-$tag.err"
        printf 'RM=[%s] WARN=[%s] OUT=[%s]' \
            "$(grep '^RM ' "$SANDBOX/lc.log" 2>/dev/null | tr '\n' '|')" \
            "$(grep -o '::warning::[^"]*' "$SANDBOX/p-$tag.out" 2>/dev/null | sed 's/::warning:://' | tr '\n' '|')" \
            "$(tr '\n' '|' < "$SANDBOX/p-$tag.out")"
    }
    got="$(step_run2 "$SANDBOX/cleanup-nof1.sh" "$FIX_PROMOTED" 1 0 3000 '{"ip":"198.51.100.1"}' i12)"
    if printf '%s' "$got" | grep -qF '::warning::'; then
        inj_bad "12. 拿掉 F1 後 warning 仍印——P1/P3 沒在看真實呼叫形狀（got [$got]）"
    else
        inj_ok "12. 拿掉 F1（裸呼叫＋case \$?）後 warning 全消失（got [$got]）——P1/P3/P5 會紅"
    fi
fi
# 13. 把 F2 的 sentinel 退化回空字串（fail-open）→ P6 轉紅。
python3 - "$REPO_ROOT/$WORKFLOW" "$SANDBOX/wf-nof2.txt" <<'PY'
import sys, re
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
out, i = [], 0
while i < len(lines):
    l = lines[i]
    if 'NODE_GATEWAY" --jq .value' in l and 'protected_ip="' in l:
        indent = l[:len(l) - len(l.lstrip())]
        # the F2 block is 3 lines: assignment, || sentinel, [[ -n ]] guard
        out.append(indent + 'protected_ip="$(gh api "repos/${GH_REPO}/actions/variables/NODE_GATEWAY" --jq .value 2>/dev/null | jq -r \'.ip // empty\' 2>/dev/null || true)"')
        j = i + 1
        while j < len(lines) and lines[j].strip() and not lines[j].strip().startswith(('rc=', 'rotate_cleanup_preview', 'case')):
            j += 1
        i = j
        continue
    out.append(l)
    i += 1
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "13. 注入腳本失敗（needle 落空）——harness 問題"
else
    python3 - "$SANDBOX/wf-nof2.txt" "$SANDBOX/cleanup-nof2.sh" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for s in doc["jobs"]["rotate"]["steps"]:
    if (s.get("name") or "").startswith("Clean up preview machine"):
        open(sys.argv[2], "w", encoding="utf-8").write(s["run"])
        break
PY
    got="$(step_run2 "$SANDBOX/cleanup-nof2.sh" "$FIX_GHFAIL" 1 0 3000 '{"ip":"198.51.100.1"}' i13 1)"
    if printf '%s' "$got" | grep -qF 'RM=[RM 3000|]'; then
        inj_ok "13. sentinel 退化成空字串後正式 Gateway 被刪（got [$(printf '%s' "$got" | head -c 130)]）——P6 會紅"
    else
        inj_bad "13. 拿掉 F2 後受保護機器仍沒被刪（got [$got]）——P6 沒在看 fail-open"
    fi
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
