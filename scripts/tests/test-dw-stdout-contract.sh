#!/usr/bin/env bash
# test-dw-stdout-contract.sh — `delete_worker_find_claim` 的 stdout 契約護欄。
#
# 為什麼要有：這個函式的 stdout **直接就是 GitHub Actions 的 output**——
# `.github/workflows/delete-worker.yml` 以
#     delete_worker_find_claim ... >> "$GITHUB_OUTPUT"
# 呼叫（重導而非 `$(...)`）。它現在安全**只因為它剛好只用 `log ERROR`
# （走 stderr）**；下一個人在那裡加一行 `log INFO`（lib/log.sh 的 INFO
# 走 stdout），Actions 就會在三個畫面外解析失敗——2026-09-25 炸掉 rotate
# 的形狀一模一樣，只是捕捉方式不同。而那支掃描器看不到「重導到
# $GITHUB_OUTPUT」這種捕捉形式（qa 實測確認）。
#
# 所以這是一個「現在對、但沒有任何東西守著」的契約。要釘的：
#   1. 成功路徑：stdout 每一行都是 key=value（port=/provider=/container=），
#      且值與輸入對得上（by port 與兩種 name 拼法）。
#   2. 失敗路徑（找不到 claim）：stdout 為空、錯誤在 stderr——
#      空 stdout 是刻意的，否則 Actions 會拿到半截 output。
#   3. 注入：在函式**體內**加一行不帶 `>&2` 的 `log INFO` → stdout 多出
#      `[ts] INFO …` → 1 的斷言轉紅。注入打在函式內，因為那正是下一個人
#      會做的事。
#   4. 同一污染下，既有的 `test-delete-worker.sh` 仍然全綠——證明那份舊
#      覆蓋對這個退化是盲的（它只 sed 出 `port=` 行，其他行被無視）。
#      這是「釘在新測試、不動舊測試」的理由。
#
# 意見（不在本檔執行、不改 workflow）：見報告〈workflow 防線評估〉。
# delete-worker.yml 那個呼叫點值得加 rotate 同型防線嗎？值得——理由與
# 建議寫在 scratchpad/dw-guard-test.md，交由 PM 決定是否派給 impl。
#
# 全離線。delete-worker.sh 以 source 載入直打函式；`log` 由真 lib/log.sh
# 提供（INFO→stdout、ERROR→stderr），不覆寫——覆寫就測不到真行為。
# bash 3.2 相容（測試本體不用陣列、不用 ${var,,}、無 mapfile）。
#
# Run: scripts/tests/test-dw-stdout-contract.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

DW="scripts/delete-worker.sh"
WORKFLOW=".github/workflows/delete-worker.yml"

for f in "$DW" "$WORKFLOW"; do
    if [[ ! -f "$f" ]]; then
        echo "test-dw-stdout-contract: ${f} is missing; dependent cases will FAIL" >&2
    fi
done
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-dw-stdout.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

CLAIMS='[{"port":2300,"provider":"fh-l","container":"mlp-fh-l-base-34797544790"},{"port":2301,"provider":"fh-proxy","container":"mlp-fh-proxy-default-34806917738"}]'

# run_claim <fn-lib-path> <port_in> <name_in>：stdout 落檔、stderr 落檔，
# 回傳 rc；印 `RC=<n> OUT=[每行用|接] ERR=[每行用|接]`。
run_claim() {
    local lib="$1" port_in="$2" name_in="$3"
    LIB="$lib" CLAIMS="$CLAIMS" PORT_IN="$port_in" NAME_IN="$name_in" \
    OUT="$SANDBOX/c.out" ERR="$SANDBOX/c.err" \
    bash -c '
        : > "$OUT"; : > "$ERR"
        source "$LIB" >/dev/null 2>&1
        delete_worker_find_claim "$CLAIMS" "$PORT_IN" "$NAME_IN" >"$OUT" 2>"$ERR"
        printf "RC=%s OUT=[%s] ERR=[%s]" "$?" \
            "$(tr "\n" "|" < "$OUT")" "$(tr "\n" "|" < "$ERR")"
    ' 2>/dev/null
}

echo "=== 0. 先決條件 ==="
if grep -q '^delete_worker_find_claim() {' "$DW"; then
    ok "0. delete_worker_find_claim 存在"
else
    bad "0. delete_worker_find_claim 不存在——實作還沒落地？"
fi
# 呼叫點必須還是「stdout 直接進 $GITHUB_OUTPUT」——契約就是從這裡來的。
if grep -q 'delete_worker_find_claim "\$CLAIMS_JSON" "\$PORT_IN" "\$NAME_IN" >> "\$GITHUB_OUTPUT"' "$WORKFLOW"; then
    ok "0b. workflow 仍以 >> \$GITHUB_OUTPUT 呼叫（本檔守的形狀）"
else
    bad "0b. workflow 呼叫形狀變了——契約前提不再，請重讀測試"
fi

echo "=== 1. 成功路徑：stdout 每一行都是 key=value ==="
# 1a：by port。
got="$(run_claim "$REPO_ROOT/$DW" 2300 "")"
if [[ "$got" == 'RC=0 OUT=[port=2300|provider=fh-l|container=mlp-fh-l-base-34797544790|] ERR=[]' ]]; then
    ok "1a. by port：恰三行 key=value、stderr 空"
else
    bad "1a. 不對（got [$got]）"
fi
# 1b：裸名（create-worker 回報的拼法）。
got="$(run_claim "$REPO_ROOT/$DW" "" "fh-proxy-default-34806917738")"
if [[ "$got" == 'RC=0 OUT=[port=2301|provider=fh-proxy|container=mlp-fh-proxy-default-34806917738|] ERR=[]' ]]; then
    ok "1b. 裸名：恰三行 key=value、stderr 空"
else
    bad "1b. 不對（got [$got]）"
fi
# 1c：容器名（mlp ls 顯示的拼法）。
got="$(run_claim "$REPO_ROOT/$DW" "" "mlp-fh-proxy-default-34806917738")"
if [[ "$got" == 'RC=0 OUT=[port=2301|provider=fh-proxy|container=mlp-fh-proxy-default-34806917738|] ERR=[]' ]]; then
    ok "1c. 容器名：恰三行 key=value、stderr 空"
else
    bad "1c. 不對（got [$got]）"
fi
# 1d：逐行檢查——stdout 不得有任何一行不符合 key=value。這是契約的核心，
# 比對整串字串更強（多一行 log 就紅，值內容不影響）。
linecheck() {
    local outfile="$1" badline=0 line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^=]*$ ]] || badline=1
    done < "$outfile"
    printf '%s' "$badline"
}
run_claim "$REPO_ROOT/$DW" 2300 "" >/dev/null
if [[ "$(linecheck "$SANDBOX/c.out")" == "0" ]]; then
    ok "1d. 逐行皆 key=value（沒有任何 log／空行混入）"
else
    bad "1d. stdout 有非 key=value 行（out [$(tr '\n' '|' < "$SANDBOX/c.out")]）"
fi

echo "=== 2. 失敗路徑：stdout 空、錯誤在 stderr ==="
got="$(run_claim "$REPO_ROOT/$DW" 9999 "")"
if [[ "$got" == RC=1* ]] \
&& printf '%s' "$got" | grep -qF 'OUT=[]' \
&& printf '%s' "$got" | grep -qF 'no worker port claim found'; then
    ok "2a. 找不到 claim：rc 1、stdout 空、訊息在 stderr"
else
    bad "2a. 失敗路徑不對（got [$got]）"
fi
# 2b：找不到名字同理（同一個 else 分支，但覆蓋呼叫形狀）。
got="$(run_claim "$REPO_ROOT/$DW" "" "no-such-worker")"
if [[ "$got" == RC=1* ]] && printf '%s' "$got" | grep -qF 'OUT=[]'; then
    ok "2b. 找不到名字：rc 1、stdout 空"
else
    bad "2b. 失敗路徑不對（got [$got]）"
fi

echo "=== 3-4. 注入：在函式體內加一行 log INFO（下一個人會做的事） ==="
# 3. 突變檔住在 repo/scripts/ 內（delete-worker.sh 找 ../lib/log.sh）。
mkdir -p "$SANDBOX/repo/scripts"
cp -R "$REPO_ROOT/scripts/lib" "$SANDBOX/repo/scripts/lib"
# needle：函式體的 `local match`（該函式獨有，全檔唯一）。
python3 - "$REPO_ROOT/$DW" "$SANDBOX/repo/scripts/delete-worker-mut.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '    local match\n'
assert src.count(old) == 1, "fn-body needle count != 1: %d" % src.count(old)
new = old + '    log INFO "finding claim for ${port_in}${name_in}"\n'
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/repo/scripts/delete-worker-mut.sh" 2>/dev/null; then
    inj_bad "3. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    got="$(run_claim "$SANDBOX/repo/scripts/delete-worker-mut.sh" 2300 "")"
    if [[ "$got" == 'RC=0 OUT=[port=2300|provider=fh-l|container=mlp-fh-l-base-34797544790|] ERR=[]' ]]; then
        inj_bad "3. 加 log INFO 後 1 仍綠——污染沒被量到（got [$got]）"
    else
        if printf '%s' "$got" | grep -qE 'OUT=\[\[2[0-9-]+T[0-9:]+Z\] INFO'; then
            inj_ok "3. 加 log INFO 後 stdout 第一行變 log（got [$got]）——1a/1d 會紅"
        else
            inj_bad "3. 行為變了但不是預期的污染（got [$got]）——harness 問題"
        fi
    fi
    # 3b：同樣的污染下，§1d 的逐行檢查也必須紅（不只整串比對）。
    run_claim "$SANDBOX/repo/scripts/delete-worker-mut.sh" 2300 "" >/dev/null
    if [[ "$(linecheck "$SANDBOX/c.out")" == "1" ]]; then
        inj_ok "3b. 同一污染下逐行檢查（1d）也轉紅"
    else
        inj_bad "3b. 逐行檢查對污染無感——1d 沒在看完整 stdout"
    fi
fi
# 4. 既有 test-delete-worker.sh 對同一污染仍然全綠：
#    它只 sed 出 port= 那一行，其他行被無視——這正是需要新護欄的理由。
#    （不動舊測試；本條只證明舊覆蓋是盲的。）
# 舊測試開頭 `cd "$(dirname "${BASH_SOURCE[0]}")/../.."`，所以它必須放在
# `scripts/tests/` 底下、而污染版擺 `scripts/`——整個迷你 repo 自成一格。
mkdir -p "$SANDBOX/oldtree/scripts/tests"
cp -R "$REPO_ROOT/scripts/lib" "$SANDBOX/oldtree/scripts/lib"
cp -p "$SANDBOX/repo/scripts/delete-worker-mut.sh" "$SANDBOX/oldtree/scripts/delete-worker.sh"
cp -p "$REPO_ROOT/scripts/tests/test-delete-worker.sh" "$SANDBOX/oldtree/scripts/tests/old-test.sh"
old_out="$( bash "$SANDBOX/oldtree/scripts/tests/old-test.sh" 2>&1 )"
old_rc=$?
if [[ "$old_rc" -eq 0 ]] && printf '%s' "$old_out" | grep -q 'passed'; then
    inj_ok "4. 既有 test-delete-worker.sh 對同一污染全綠（舊覆蓋是盲的，故需本檔）"
else
    inj_bad "4. 舊測試竟抓到污染（rc=$old_rc out [$(printf '%s' "$old_out" | tr '\n' '|' | head -c 160)]）——前提變了，請重讀"
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
