#!/usr/bin/env bash
# test-wf-dispatch-attribution.sh — `wf_dispatch` 認不出自己的 run 時，不准猜。
#
# 在防什麼（真線會咬人的那一種）：
#   dispatch API 不回傳它建立的 run id，所以舊碼記下「最新的 id」、輪詢等到
#   一個不同的就認領。這個差集分不出**歸屬**：
#     - 別人的 run 先出現 → 認領別人的（順序完全正確也一樣會錯）
#     - 我們的先建、同一個輪詢間隔內別人的也建出來 → `--limit 1` 只看得到
#       最新那筆 → 還是認錯
#   三個呼叫端是 rotate ×2、create-worker、delete-worker；rotate 是**破壞
#   性**的：真正的風險路徑是「rotate 其實成功了卻被報成失敗，人半夜看到紅字
#   重跑一次 rotate」。
#
# 這不是新發明，是既有規則的落實。docs/FWD-DESIGN.md §4（141–152）寫著：
#   `inconclusive` 是「我不知道」，不可以跟任何確定狀態合併，後果要寫進名字。
#   `wake` / `mlp ls` / `gw_probe_port` 三處已是這個先例。
#   本檔驗的是「現況違反既有規則」，不是「新功能有沒有做」。
#
# 要驗的（行為面，不驗實作細節）：
#   1. 恰好一筆新 run → 認領它，行為與從前完全一樣（回歸保護）。
#   2. 兩筆新 run 同時出現 → 不認領任何一筆，兩筆的 URL 都要印出來。
#   3. 別人的先出現、我們的後出現 → 同樣不認領。獨立一條，因為它是
#      「順序完全正確也照樣認錯」的案例；只有第 2 條的話，讀的人會以為
#      「順序對就安全」。
#   4. 零筆新 run → 照舊逾時失敗（回歸保護）。
#   5. **三態可分**：0 成功 / 1 明確失敗 / 3 未知。未知不可折疊成 0
#      （「猜成功」）也不可折疊成 1（「半夜叫人重跑 rotate」）。具體數字
#      由 impl 決定；本檔驗的是三者互異且 3 不是 0 也不是 1。
#
# 注入（照 docs/TESTPLAN.md §1.5 的三問；每個 needle 命中數恰好 1、
# mutant 過語法檢查、紅的 got 值與預測一致）：
#   A. 收集退回 `--limit 1` 的形狀（只看最新那筆）→ 2、3 兩條必須紅，
#      且紅在「它認領了」。
#   B. 把「未知」折疊成「失敗」→ 三態那條必須紅（3 變 1）。
#
# 全離線：gh／sleep 走 PATH stub，gh 套用 `--jq` 的語意與真 gh 相同
#   （沿用 test-worker-tunnel-key.sh:146 的手法）。mlp 以「剝掉尾端
#   standalone main 呼叫」的副本 source（本體是函式庫）。
# bash 3.2 相容（測試本體不用陣列、不用 ${var,,}、無 mapfile）。
#
# Run: scripts/tests/test-wf-dispatch-attribution.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

MLP="ops-scripts/mlp"

if [[ ! -f "$MLP" ]]; then
    echo "test-wf-dispatch-attribution: ${MLP} is missing; every case below will FAIL" >&2
fi
for tool in jq python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found on PATH" >&2; exit 1; }
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-wf-dispatch.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
STATE="$HOME_DIR/state"
mkdir -p "$SHIMS" "$STATE"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- 假 gh：記 argv、套 --jq（真 gh 的語意）、run list 依序回放 --------------
#   $FAKE_STATE/lists：一行代表一次 run list 的 JSON 陣列；用完停在最後一行。
#   $FAKE_STATE/view：run view 的 payload。
#   沿用 test-worker-tunnel-key.sh 的 _apply_jq 手法，不另造一套。
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
_apply_jq() {
    local json="$1"; shift
    local filter="" prev=""
    for a in "$@"; do
        [[ "$prev" == "--jq" ]] && filter="$a"
        prev="$a"
    done
    if [[ -n "$filter" ]]; then printf '%s' "$json" | jq -r "$filter"
    else printf '%s\n' "$json"; fi
}
case "${1:-} ${2:-}" in
  "workflow run") exit "${FAKE_DISPATCH_RC:-0}" ;;
  "run list")
    n=0; [[ -f "$FAKE_STATE/list.idx" ]] && n="$(cat "$FAKE_STATE/list.idx")"
    line="$(sed -n "$((n+1))p" "$FAKE_STATE/lists")"
    [[ -z "$line" ]] && line="$(tail -n 1 "$FAKE_STATE/lists")"
    printf '%s' "$((n+1))" > "$FAKE_STATE/list.idx"
    # 一行 "FAIL" 代表這次讀取失敗（exit 1）——量「讀不到」與「確實沒有」
    # 的差別時用得到（qa §3 的形狀）。
    if [[ "$line" == "FAIL" ]]; then exit 1; fi
    _apply_jq "$line" "$@"
    exit 0 ;;
  "run view")
    _apply_jq "$(cat "$FAKE_STATE/view")" "$@"
    exit 0 ;;
esac
exit 0
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIMS/sleep"
chmod +x "$SHIMS/gh" "$SHIMS/sleep"

# ---- 被測物：剝掉尾端 standalone main 的 mlp 副本 ---------------------------
# mlp 尾端是 `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`，
# source 時本來就不會跑 main；但把它剝掉可避免任何 future 變動讓 source
# 意外執行 CLI。diff 證明只差那三行。
python3 - "$REPO_ROOT/$MLP" "$SANDBOX/mlp-lib.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
out = re.sub(
    r'\nif \[\[ "\$\{BASH_SOURCE\[0\]\}" == "\$\{0\}" \]\]; then\n    main "\$@"\nfi\n?\Z',
    '\n', src)
assert 'main "$@"' not in out, "standalone main call not stripped"
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
if [[ $? -eq 0 ]] && ! grep -q 'main "\$@"' "$SANDBOX/mlp-lib.sh"; then
    ok "harness. 剝尾 standalone main 的副本可安全 source"
else
    bad "harness. 剝尾失敗——後面所有斷言都不可信"
fi

# run_wf <mlp-lib-path> <lists-file-content-verbatim> <view-json> \
#        [dispatch-rc]：回傳 rc，stdout→$WF_OUT、stderr→$WF_ERR。
run_wf() {
    local lib="$1" lists="$2" view="$3" dispatch_rc="${4:-0}"
    printf '%s\n' "$lists" > "$STATE/lists"
    printf '%s' "$view" > "$STATE/view"
    : > "$STATE/list.idx"
    : > "$SANDBOX/gh-argv.log"
    LIB="$lib" FAKE_STATE="$STATE" GH_LOG="$SANDBOX/gh-argv.log" \
    FAKE_DISPATCH_RC="$dispatch_rc" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
    OUT="$SANDBOX/wf.out" ERR="$SANDBOX/wf.err" RC_FILE="$SANDBOX/wf.rc" \
    bash -c '
        : > "$OUT"; : > "$ERR"
        source "$LIB" >/dev/null 2>&1
        REPO=testowner/testrepo
        ( wf_dispatch test.yml "label" >"$OUT" 2>"$ERR" ); printf "%s" "$?" > "$RC_FILE"
    ' </dev/null >/dev/null 2>&1
    WF_RC="$(cat "$SANDBOX/wf.rc" 2>/dev/null)"
    WF_OUT="$(cat "$SANDBOX/wf.out" 2>/dev/null)"
    WF_ERR="$(cat "$SANDBOX/wf.err" 2>/dev/null)"
    printf 'RC=%s OUT=[%s] ERR=[%s]' "$WF_RC" \
        "$(printf '%s' "$WF_OUT" | tr '\n' '|')" \
        "$(printf '%s' "$WF_ERR" | tr '\n' '|')"
}

# 常數：before 快照、單筆/雙筆 after、逾時用的重複 after。
BEFORE='[{"databaseId":101},{"databaseId":100}]'
ONE_NEW='[{"databaseId":102},{"databaseId":101},{"databaseId":100}]'
TWO_NEW='[{"databaseId":103},{"databaseId":102},{"databaseId":101},{"databaseId":100}]'
NO_NEW='[{"databaseId":101},{"databaseId":100}]'
VIEW_OK='{"status":"completed","conclusion":"success","jobs":[]}'

echo "=== 0. 先決條件 ==="
if grep -q '^wf_dispatch() {' "$MLP" && grep -q '^wf_follow() {' "$MLP"; then
    ok "0. wf_dispatch 與 wf_follow 都在"
else
    bad "0. wf_dispatch／wf_follow 不存在——實作還沒落地？"
fi

echo "=== 1. 恰好一筆新 run → 認領它（回歸保護） ==="
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$ONE_NEW")" "$VIEW_OK")"
if [[ "$got" == RC=0* ]] \
&& printf '%s' "$got" | grep -qF 'actions/runs/102' \
&& ! printf '%s' "$got" | grep -qF 'actions/runs/103'; then
    ok "1a. 單筆新 run：rc 0、認領 102（行為與從前一樣）"
else
    bad "1a. 單筆新 run 沒被認領（got [$got]）"
fi
# 1b：確真的 follow 了它（run view 帶著那個 id）。
if grep -q '^run view 102 ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "1b. 認領後真的 follow 了 102（run view 帶對 id）"
else
    bad "1b. 沒有對 102 跑 run view（argv [$(tr '\n' '|' < "$SANDBOX/gh-argv.log" | head -c 200)]）"
fi

echo "=== 2. 兩筆新 run 同時出現 → 不認領、兩筆 URL 都印 ==="
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$TWO_NEW")" "$VIEW_OK")"
if printf '%s' "$got" | grep -qF 'actions/runs/102' \
&& printf '%s' "$got" | grep -qF 'actions/runs/103' \
&& ! printf '%s' "$got" | grep -qF 'run finished'; then
    ok "2a. 兩筆 URL 都印出來、沒有認領任何一筆（沒有 'run finished'）"
else
    bad "2a. 兩筆新 run 時認領了其中一筆或漏印 URL（got [$got]）"
fi
if ! grep -q '^run view ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "2b. 零 run view：真的沒有 follow 任何一筆"
else
    bad "2b. 認領後仍 follow 了（argv [$(grep '^run view' "$SANDBOX/gh-argv.log" | tr '\n' '|')]）"
fi

echo "=== 3. 別人的先出、我們的後出 → 同樣不認領（順序對也照錯） ==="
# 這是「順序完全正確」的案例：舊碼會在第一筆新 run 出現時就認領（--limit 1
# 只看得到最新那筆），於是永遠拿不到真正屬於我們的那一筆。
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$TWO_NEW")" "$VIEW_OK")"
if printf '%s' "$got" | grep -qF 'actions/runs/103' \
&& printf '%s' "$got" | grep -qF 'actions/runs/102' \
&& ! printf '%s' "$got" | grep -qF 'run finished'; then
    ok "3a. 順序正確的兩筆新 run：仍不認領、兩筆都列（不靠『先到先贏』）"
else
    bad "3a. 順序正確時竟認領了（got [$got]）"
fi
# 3b：把「我們的」放在較舊的位置，證明不是「拿最新那筆」的巧合。
OLDER='[{"databaseId":104},{"databaseId":103},{"databaseId":101},{"databaseId":100}]'
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$OLDER")" "$VIEW_OK")"
if printf '%s' "$got" | grep -qF 'actions/runs/103' \
&& printf '%s' "$got" | grep -qF 'actions/runs/104' \
&& ! printf '%s' "$got" | grep -qF 'run finished'; then
    ok "3b. 兩筆新 run 但我們的較舊：一樣不認領（不是『拿最新』的巧合）"
else
    bad "3b. 較舊那筆被誤認領（got [$got]）"
fi

echo "=== 4. 零筆新 run → 逾時失敗（回歸保護） ==="
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$NO_NEW")" "$VIEW_OK")"
if [[ "$got" == RC=1* ]] && printf '%s' "$got" | grep -qF 'never appeared'; then
    ok "4a. 零筆新 run：逾時失敗（rc 1、訊息說 never appeared）"
else
    bad "4a. 零筆新 run 的行為不對（got [$got]）"
fi
# 4b：dispatch 本身失敗 → 明確失敗（不可被誤認為未知）。
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$ONE_NEW")" "$VIEW_OK" 1)"
if [[ "$got" == RC=1* ]] && printf '%s' "$got" | grep -qF 'could not dispatch'; then
    ok "4b. dispatch 失敗：rc 1、明確說 could not dispatch"
else
    bad "4b. dispatch 失敗的行為不對（got [$got]）"
fi

echo "=== 5. 三態可分：未知不是成功、也不是失敗 ==="
# 收集三種情境的 rc：成功（恰好一筆）、明確失敗（零筆逾時）、未知（兩筆歧義）。
rc_ok="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$ONE_NEW")" "$VIEW_OK")"
rc_fail="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$NO_NEW")" "$VIEW_OK")"
rc_unknown="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$TWO_NEW")" "$VIEW_OK")"
r_ok="${rc_ok%% *}"; r_fail="${rc_fail%% *}"; r_unknown="${rc_unknown%% *}"
r_ok="${r_ok#RC=}"; r_fail="${r_fail#RC=}"; r_unknown="${r_unknown#RC=}"
if [[ "$r_ok" == "0" && "$r_fail" == "1" && "$r_unknown" != "0" && "$r_unknown" != "1" ]]; then
    ok "5a. 三態互異：成功=${r_ok}、明確失敗=${r_fail}、未知=${r_unknown}（未知不是 0 也不是 1）"
else
    bad "5a. 三態沒有分開（ok=${r_ok} fail=${r_fail} unknown=${r_unknown}）——未知被折疊成成功或失敗"
fi
# 5b：未知時 stdout 必須說得出「我不能確定」，而不是「成功」或一般失敗訊息。
if printf '%s' "$rc_unknown" | grep -qF 'cannot tell which one is ours'; then
    ok "5b. 未知的輸出直說『認不出來』（不是靜靜回一個碼）"
else
    bad "5b. 未知情境沒有說出不能確定（got [$rc_unknown]）"
fi
# 5c：未知不可被 follow——run view 一次都不能發生。
if ! grep -q '^run view ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "5c. 未知時零 run view（不 follow 猜測的那一筆）"
else
    bad "5c. 未知時仍 follow 了（argv [$(grep '^run view' "$SANDBOX/gh-argv.log" | tr '\n' '|')]）"
fi

echo "=== 9. 讀取失敗 ≠ 確實沒有新 run（qa 缺口 1） ==="
# 這兩件事意義相反，現在都走同一個 die：
#   - 讀取成功但窗內確實沒有新 run → 「確定沒有」→ rc 1
#   - 讀取本身持續失敗 → 「沒觀察到」→ rc 3（未知）
# 夾具：lists 的第一行是 before，之後每行是一次輪詢的 after；一行 "FAIL"
# 代表該次讀取失敗（gh exit 1）。
# 9a：before 成功（有內容）、after 20 次全 FAIL → rc 3，且輸出說「沒有乾淨
#     看一眼」，不是 never appeared。
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' '[{"databaseId":101},{"databaseId":100}]' 'FAIL')" "$VIEW_OK")"
if [[ "$got" == RC=3* ]] \
&& printf '%s' "$got" | grep -qF 'the last read of the run list failed' \
&& ! printf '%s' "$got" | grep -qF 'never appeared'; then
    ok "9a. after 讀取持續失敗：rc 3、輸出含 'the last read of the run list failed'、不含 'never appeared'"
else
    bad "9a. 讀取持續失敗時 rc 不是 3 或出現 never appeared（got [$got]）"
fi
# 9b：before 成功但空（workflow 尚無 run）、after 全 FAIL → 同樣 rc 3。
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' '[]' 'FAIL')" "$VIEW_OK")"
if [[ "$got" == RC=3* ]] && printf '%s' "$got" | grep -qF 'the last read of the run list failed'; then
    ok "9b. 空 baseline＋讀取失敗：rc 3、不含 never appeared"
else
    bad "9b. 空 baseline＋讀取失敗時 rc 或訊息不符（got [$got]）"
fi
# 9c（回歸）：before 成功、after 成功但確實沒有新 run → rc 1 never appeared。
#     這一條不能因為 9a/9b 的修正而被改壞——「確定沒有」仍是明確失敗。
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' '[{"databaseId":101},{"databaseId":100}]' '[{"databaseId":101},{"databaseId":100}]')" "$VIEW_OK")"
if [[ "$got" == RC=1* ]] && printf '%s' "$got" | grep -qF 'never appeared'; then
    ok "9c. 讀取成功且窗內無新 run：rc 1、輸出含 never appeared"
else
    bad "9c. 讀取成功且無新 run 時 rc 或訊息不符（got [$got]）"
fi
# 9d：before 成功、其中一輪 after FAIL、之後成功且有一筆新 run →
#     失敗那輪不進差集，最終仍正確認領（不可因單輪抖動誤判）。
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s\n%s' '[{"databaseId":101},{"databaseId":100}]' 'FAIL' '[{"databaseId":102},{"databaseId":101},{"databaseId":100}]')" "$VIEW_OK")"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'actions/runs/102'; then
    ok "9d. 單輪讀取失敗＋之後恢復：rc 0、輸出含 actions/runs/102"
else
    bad "9d. 單輪失敗後回復時 rc 或認領 id 不符（got [$got]）"
fi

echo "=== 10. before 讀失敗 → 未知，與窗的密度無關（qa 缺口 2） ==="
# 完整窗之所以安全是**意外的**：30 筆全被當新 → 超過一筆 → rc 3。稀疏窗
# 下同樣的 bug 會「認出」一筆從未 dispatch 的 run（qa §3 子情況 2）。
# 這裡同時涵蓋完整窗與稀疏窗，訊息寫明驗的是「before 讀不到就未知」，
# 不是「窗裡筆數夠多所以安全」。
# 10a：before FAIL＋稀疏窗（1 筆）→ rc 3、零認領、零 follow。
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' 'FAIL' '[{"databaseId":100}]')" "$VIEW_OK")"
if [[ "$got" == RC=3* ]] \
&& printf '%s' "$got" | grep -qF 'the run list could not be read when the dispatch went out' \
&& ! printf '%s' "$got" | grep -qF 'actions/runs/100' \
&& ! grep -q '^run view ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "10a. before 讀不到＋稀疏窗（1 筆）：rc 3、輸出無 actions/runs/100、零 run view 呼叫、含 'the run list could not be read when the dispatch went out'"
else
    bad "10a. before 讀不到且窗只有 1 筆時 rc 不是 3、或認領了那筆、或 follow 了（got [$got]）"
fi
# 10b：before FAIL＋完整窗（多筆）→ 同樣 rc 3，且訊息與 10a 相同——證明
#      判定來自分支（baseline 讀不到），不是來自「窗裡剛好有很多筆」。
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' 'FAIL' '[{"databaseId":903},{"databaseId":902},{"databaseId":901},{"databaseId":900}]')" "$VIEW_OK")"
if [[ "$got" == RC=3* ]] \
&& printf '%s' "$got" | grep -qF 'the run list could not be read when the dispatch went out' \
&& ! printf '%s' "$got" | grep -qF 'cannot tell which one is ours'; then
    ok "10b. before 讀不到＋完整窗（4 筆）：rc 3、同一句 'the run list could not be read when the dispatch went out'、不含 'cannot tell which one is ours'"
else
    bad "10b. before 讀不到且窗有 4 筆時走了別條分支（got [$got]）"
fi
# 10c（回歸）：before 成功但空（真的沒有任何 run）是合法 baseline →
#      之後出現一筆新 run 就該認領它（不可把「空 baseline」誤當「讀不到」）。
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' '[]' '[{"databaseId":700}]')" "$VIEW_OK")"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'actions/runs/700'; then
    ok "10c. 空 baseline（rc 0、無內容）→ rc 0、輸出含 actions/runs/700"
else
    bad "10c. 空 baseline 時 rc 或認領 id 不符（got [$got]）"
fi

echo "=== 11. 跨輪詢 sequential race（已知限制，記錄用） ==="
# 別人的第 1 輪出現、我們的第 2 輪才出現。在 1 筆窗之下，第 1 輪就會看到
# 恰好一筆新 run 而認領它——即使 before 完全正常。**這條修不掉**（根因是
# 沒有 nonce，屬於另一個決策）；斷言寫成「目前認錯，這是已知限制」，
# 不寫成「應該要對」。若哪天加上 nonce 而修好了，這條會轉紅，提醒把它
# 改成「應該要對」。
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s\n%s' '[]' '[{"databaseId":101}]' '[{"databaseId":102},{"databaseId":101}]')" "$VIEW_OK")"
if [[ "$got" == RC=0* ]] \
&& printf '%s' "$got" | grep -qF 'actions/runs/101' \
&& ! printf '%s' "$got" | grep -qF 'actions/runs/102'; then
    ok "11a. sequential race（第 1 輪 [101]、第 2 輪 [102,101]）：rc 0、輸出含 actions/runs/101、不含 actions/runs/102——已知限制"
else
    if [[ "$got" == RC=3* ]] || printf '%s' "$got" | grep -qF 'actions/runs/102'; then
        bad "11a. 認領的 id 變了（got [$got]）——若 nonce 已落地，請改寫這條斷言"
    else
        bad "11a. 行為變了但不預期（got [$got]）——harness 問題"
    fi
fi
# 11b：同一 race 在窗內一次給兩筆（第 1 輪就同時看到）→ 正確地未知。
#      對照 11a，說明差別只在「何時被看到」，不在「有沒有守衛」。
got="$(run_wf "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' '[]' '[{"databaseId":102},{"databaseId":101}]')" "$VIEW_OK")"
if [[ "$got" == RC=3* ]] && printf '%s' "$got" | grep -qF 'cannot tell which one is ours'; then
    ok "11b. 同一 race 兩筆同輪出現：rc 3、輸出含 cannot tell which one is ours"
else
    bad "11b. 兩筆同輪時 rc 或訊息不符（got [$got]）"
fi


echo "=== 6-7. 注入：拿掉修正，斷言必須轉紅 ==="
# 6. 收集退回「只看最新一筆」（--limit 1 的舊形狀）→ 2、3 必須紅，
#    且紅在「它認領了」。needle 是新的兩行收集窗；mutant 改成拿最新一筆。
python3 - "$REPO_ROOT/$MLP" "$SANDBOX/mutant-limit1.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '''        new_ids="$(comm -13 <(printf '%s\\n' "$before" | sort) \\
                            <(printf '%s\\n' "$after" | sort) | grep . || true)"'''
new = '''        new_ids="$(printf '%s\\n' "$after" | head -n 1 | grep . || true)"'''
assert src.count(old) == 1, "limit1 needle count != 1: %d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/mutant-limit1.sh" 2>/dev/null; then
    inj_bad "6. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    got="$(run_wf "$SANDBOX/mutant-limit1.sh" "$(printf '%s\n%s' "$BEFORE" "$TWO_NEW")" "$VIEW_OK")"
    # 釘死被認領的是 103（最新那筆）——只說「有認領」不夠精確。
    if printf '%s' "$got" | grep -qF 'run finished' \
    && printf '%s' "$got" | grep -qF 'actions/runs/103' \
    && ! printf '%s' "$got" | grep -qF 'cannot tell which one is ours'; then
        inj_ok "6a. 退回只看最新一筆後，它認領了 103 並跑完（got [$(printf '%s' "$got" | head -c 150)]）——2a 會紅"
    else
        inj_bad "6a. 退回只看最新一筆後 2a 仍綠或認領的不是 103（got [$got]）"
    fi
    # 6b：順序正確的案例（別人的先出）也要紅。
    got="$(run_wf "$SANDBOX/mutant-limit1.sh" "$(printf '%s\n%s' "$BEFORE" "$OLDER")" "$VIEW_OK")"
    if printf '%s' "$got" | grep -qF 'run finished' \
    && printf '%s' "$got" | grep -qF 'actions/runs/104' \
    && ! printf '%s' "$got" | grep -qF 'actions/runs/103'; then
        inj_ok "6b. 退回只看最新一筆後，認領了 104（最新那筆；103 才是我們的）（got [$(printf '%s' "$got" | head -c 150)]）——3b 會紅"
    else
        inj_bad "6b. 退回只看最新一筆後 3b 仍綠或認領的不是 104（got [$got]）"
    fi
fi
# 7. 把「未知」折疊成「失敗」→ 三態那條必須紅（3 變 1）。needle 是
#    未知分支的 `return 3`。
python3 - "$REPO_ROOT/$MLP" "$SANDBOX/mutant-fold-fail.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
# 只改 wf_dispatch 歧義分支的那個 return 3（檔內第一個恰好是這一個？
# 不——先定位到歧義訊息，再改它後面的 return 3）。
# 定位到 ambiguous 分支的收尾句（impl 的措辭可能微調；取該分支的
# return 3 即可）。退而求其次：找「cannot tell which one is ours」之後。
marker = "look yourself before doing anything else"
i = src.index("cannot tell which one is ours")
_ = src.index(marker, i) if marker in src[i:] else i
j = src.index("return 3", i)
assert src[j - 8:j + 8] == "        return 3", repr(src[j - 8:j + 8])
src = src[:j] + "return 1" + src[j + 8:]
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/mutant-fold-fail.sh" 2>/dev/null; then
    inj_bad "7. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    got="$(run_wf "$SANDBOX/mutant-fold-fail.sh" "$(printf '%s\n%s' "$BEFORE" "$TWO_NEW")" "$VIEW_OK")"
    if [[ "$got" == RC=3* ]]; then
        inj_bad "7. 折疊成失敗後仍回 3——注入沒生效（got [$got]）"
    else
        if [[ "$got" == RC=1* ]]; then
            inj_ok "7. 未知被折疊成失敗（rc 3→1；got [$(printf '%s' "$got" | head -c 130)]）——5a 會紅"
        else
            inj_bad "7. 行為變了但不是預期的折疊（got [$got]）——harness 問題"
        fi
    fi
fi

echo "=== 8. 呼叫端：未知不可以被折成成功或失敗（rotate 的半夜重跑風險） ==="
# 真正的風險路徑不在 wf_dispatch 本身，在它的破壞性呼叫端：rotate 其實
# 成功了卻被報成失敗 → 人半夜看到紅字重跑一次 rotate。所以釘 cmd_rotate：
# 未知時 rc 必須仍是 3（不是 0、不是 1），且輸出要說「可能已經換掉 Gateway」。
# 需要 resolve_gateway 的夾具（只走 --real 分支才用得到）。
cat > "$SHIMS/ssh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$SHIMS/ssh"

# run_cmd_rotate <mlp-lib-path> <lists> <view> <confirm-text>：
# 跑 `cmd_rotate --real`，確認字串從 stdin 餵入；印 rc 與輸出。
run_cmd_rotate() {
    local lib="$1" lists="$2" view="$3" confirm_text="$4"
    printf '%s\n' "$lists" > "$STATE/lists"
    printf '%s' "$view" > "$STATE/view"
    : > "$STATE/list.idx"
    : > "$SANDBOX/gh-argv.log"
    LIB="$lib" FAKE_STATE="$STATE" GH_LOG="$SANDBOX/gh-argv.log" \
    FAKE_DISPATCH_RC=0 PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
    OUT="$SANDBOX/rot.out" ERR="$SANDBOX/rot.err" RC_FILE="$SANDBOX/rot.rc" \
    CONFIRM="$confirm_text" POOLRES="$SANDBOX/fake-pool-resolve" \
    bash -c '
        : > "$OUT"; : > "$ERR"
        source "$LIB" >/dev/null 2>&1
        REPO=testowner/testrepo
        POOL_RESOLVE="$POOLRES"
        GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22
        ( printf "%s\n" "$CONFIRM" | cmd_rotate --real >"$OUT" 2>"$ERR" )
        printf "%s" "$?" > "$RC_FILE"
    ' </dev/null >/dev/null 2>&1
    local rc; rc="$(cat "$SANDBOX/rot.rc" 2>/dev/null)"
    printf 'RC=%s OUT=[%s] ERR=[%s]' "$rc" \
        "$(tr '\n' '|' < "$SANDBOX/rot.out")" \
        "$(tr '\n' '|' < "$SANDBOX/rot.err")"
}
# pool-resolve stub：resolve_gateway 需要它回 gateway JSON。
cat > "$SANDBOX/fake-pool-resolve" <<'FAKE'
#!/usr/bin/env bash
# 只支援 resolve_gateway 的呼叫形狀（gateway --refresh）；其他一律失敗，
# 讓夾具不會靜默走進沒預期的分支。
[[ "${1:-}" == "gateway" ]] || exit 1
printf '{"ip":"9.9.9.9","user":"gw","port":22,"generation":"1"}\n'
exit 0
FAKE
chmod +x "$SANDBOX/fake-pool-resolve"

got="$(run_cmd_rotate "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$TWO_NEW")" "$VIEW_OK" "9.9.9.9")"
if [[ "$got" == RC=3* ]] \
&& printf '%s' "$got" | grep -qF 'could not be identified' \
&& printf '%s' "$got" | grep -qF 'may have replaced the live Gateway' \
&& printf '%s' "$got" | grep -qF 'trust-gateway'; then
    ok "8a. cmd_rotate 未知：rc 3、警告『可能已換掉』＋仍提示 trust-gateway（不是紅字叫人重跑）"
else
    bad "8a. cmd_rotate 把未知折疊了或不說明後果（got [$got]）"
fi
# 8b：明確失敗（零筆逾時）→ rc 1，且**不**提示 trust-gateway（沒換機）。
got="$(run_cmd_rotate "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$NO_NEW")" "$VIEW_OK" "9.9.9.9")"
if [[ "$got" == RC=1* ]] && ! printf '%s' "$got" | grep -qF 'trust-gateway'; then
    ok "8b. cmd_rotate 明確失敗：rc 1、不提示 trust-gateway（沒有換機）"
else
    bad "8b. 明確失敗的處理不對（got [$got]）"
fi
# 8c：成功 → rc 0，提示 trust-gateway（回歸保護）。
got="$(run_cmd_rotate "$SANDBOX/mlp-lib.sh" "$(printf '%s\n%s' "$BEFORE" "$ONE_NEW")" "$VIEW_OK" "9.9.9.9")"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'trust-gateway'; then
    ok "8c. cmd_rotate 成功：rc 0、提示 trust-gateway（與從前一樣）"
else
    bad "8c. 成功路徑的行為變了（got [$got]）"
fi

# 8. 把呼叫端的「未知」折疊成失敗（`|| return 1` 的舊形狀）→ 8a 必須紅。
#    這正是「rotate 其實成功卻報成失敗、人半夜重跑」的形狀。
python3 - "$REPO_ROOT/$MLP" "$SANDBOX/mutant-caller-fold.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "\n".join([
    '    local rc=0',
    '    wf_dispatch rotate-gateway.yml "rotate" -f dry_run=false || rc=$?',
    '    if [[ "$rc" -eq 0 || "$rc" -eq 3 ]]; then',
    '        echo ""',
    '        echo "next: run \'mlp trust-gateway\' to accept the new machine\'s host key."',
    '    fi',
    '    if [[ "$rc" -eq 3 ]]; then',
    '        echo ""',
    '        printf \'%sthe rotate run could not be identified \u2014 it may have replaced the live Gateway.%s\\n\' \\',
    '            "$C_YELLOW" "$C_RESET"',
    '        echo "check what was printed above (and \'mlp ls\') before running rotate again."',
    '    fi',
    '    return "$rc"',
])
new = "\n".join([
    '    wf_dispatch rotate-gateway.yml "rotate" -f dry_run=false || return 1',
    '    echo ""',
    '    echo "next: run \'mlp trust-gateway\' to accept the new machine\'s host key."',
    '    return 0',
])
assert src.count(old) == 1, "caller-fold needle count != 1: %d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/mutant-caller-fold.sh" 2>/dev/null; then
    inj_bad "8. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    got="$(run_cmd_rotate "$SANDBOX/mutant-caller-fold.sh" "$(printf '%s\n%s' "$BEFORE" "$TWO_NEW")" "$VIEW_OK" "9.9.9.9")"
    if [[ "$got" == RC=3* ]]; then
        inj_bad "8. 呼叫端折疊後仍回 3——注入沒生效（got [$got]）"
    else
        if [[ "$got" == RC=1* ]] && ! printf '%s' "$got" | grep -qF 'could not be identified'; then
            inj_ok "8. 呼叫端把未知折成失敗（rc 3→1、無『認不出來』警告；got [$(printf '%s' "$got" | head -c 140)]）——8a 會紅"
        else
            inj_bad "8. 行為變了但不是預期的折疊（got [$got]）——harness 問題"
        fi
    fi
fi

# 9. 把「輪詢讀取失敗」記成成功讀取（last_read_ok 恆 1）→ 9a/9b 必須紅：
#    讀不到被折成「確定沒有」，回 rc 1。
python3 - "$REPO_ROOT/$MLP" "$SANDBOX/mutant-readok.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = """        if [[ $? -ne 0 ]]; then
            # A failed read observed nothing, so it must not enter the
            # difference: an empty "after" would otherwise make every entry
            # of the baseline look new (or, in a one-entry baseline, look
            # like one new run). Record that the latest observation is
            # dark and keep waiting.
            last_read_ok=0
            printf '.'
            continue
        fi
        last_read_ok=1"""
new = """        last_read_ok=1"""
assert src.count(old) == 1, "readok needle count != 1: %d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/mutant-readok.sh" 2>/dev/null; then
    inj_bad "9. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    # 9a 夾具：before 有內容、after 全 FAIL。折疊後：after 空字串 → 差集
    # 為空 → count 0 → 20 輪迴圈 → last read「看似成功」→ never appeared rc 1。
    got="$(run_wf "$SANDBOX/mutant-readok.sh" "$(printf '%s\n%s' '[{"databaseId":101},{"databaseId":100}]' 'FAIL')" "$VIEW_OK")"
    if [[ "$got" == RC=3* ]]; then
        inj_bad "9. 讀取失敗被記成成功後仍回 3——注入沒生效（got [$got]）"
    else
        if [[ "$got" == RC=1* ]] && printf '%s' "$got" | grep -qF 'never appeared'; then
            inj_ok "9. 讀不到被折成『確定沒有』（rc 3→1、never appeared；got [$(printf '%s' "$got" | head -c 130)]）——9a/9b 會紅"
        else
            inj_bad "9. 行為變了但不是預期的折疊（got [$got]）——harness 問題"
        fi
    fi
fi
# 10. 拿掉 baseline 讀取守衛（把「讀不到」當成空 baseline）→ 10a 必須紅：
#     稀疏窗下認領一筆從未 dispatch 的 run。
python3 - "$REPO_ROOT/$MLP" "$SANDBOX/mutant-nobaseline.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = """    before_rc=$?
    # A baseline that could not be read is not an empty baseline. Diffing
    # against "" calls every visible run "new" — which is only accidentally
    # safe while the window happens to hold several runs; with a sparse
    # window it "singles out" a run we never dispatched (qa 2026-09-25).
    # Empty output WITH rc 0 is a real baseline (the workflow has no runs
    # yet), and must not be confused with this case.
    [[ "$before_rc" -eq 0 ]] || baseline_ok=0"""
new = """    before_rc=$?
    : "$before_rc\""""
assert src.count(old) == 1, "nobaseline needle count != 1: %d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/mutant-nobaseline.sh" 2>/dev/null; then
    inj_bad "10. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    # 10a 夾具：before FAIL、稀疏窗 1 筆。拿掉守衛後 before="" → 100 看似新
    # → 認領 100（rc 0、錯 id）。
    got="$(run_wf "$SANDBOX/mutant-nobaseline.sh" "$(printf '%s\n%s' 'FAIL' '[{"databaseId":100}]')" "$VIEW_OK")"
    if [[ "$got" == RC=3* ]]; then
        inj_bad "10. 拿掉 baseline 守衛後仍回 3——注入沒生效（got [$got]）"
    else
        if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'actions/runs/100'; then
            inj_ok "10. before 讀不到被當空 baseline，稀疏窗下認領了從未 dispatch 的 100（got [$(printf '%s' "$got" | head -c 130)]）——10a 會紅"
        else
            inj_bad "10. 行為變了但不是預期的誤認（got [$got]）——harness 問題"
        fi
    fi
    # 10b 對照：完整窗下同一注入走 ambiguous（意外的安全）——證明 10b 的
    # 訊息「判準是讀不到，不是筆數」是對的觀測。
    got="$(run_wf "$SANDBOX/mutant-nobaseline.sh" "$(printf '%s\n%s' 'FAIL' '[{"databaseId":903},{"databaseId":902},{"databaseId":901},{"databaseId":900}]')" "$VIEW_OK")"
    if [[ "$got" == RC=3* ]] && printf '%s' "$got" | grep -qF 'cannot tell which one is ours'; then
        inj_ok "10b. 同一注入在完整窗下靠『筆數多』僥倖回 3（got [$(printf '%s' "$got" | head -c 110)]）——證明完整窗的安全是意外的"
    else
        inj_bad "10b. 完整窗未展現預期的僥倖路徑（got [$got]）——harness 問題"
    fi
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
