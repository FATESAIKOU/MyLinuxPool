#!/usr/bin/env bash
# test-wf-dispatch-attribution.sh — `wf_dispatch` 只認有歸屬證據的 run，認不出時不准猜。
#
# 在防什麼（真線會咬人的那一種）：
#   舊碼 dispatch 後記下「最新/可見窗」的差集、認領唯一那筆新 run。那個差集
#   分不出**歸屬**：別人的 run 先出現時照樣被認領（順序完全正確也一樣）；
#   我們的先建、同一輪內別人的也建出來時只看到最新那筆，一樣錯。三個呼叫端
#   是 rotate ×2、create-worker、delete-worker；rotate 是**破壞性**的：真正
#   的風險路徑是「rotate 其實成功了卻被報成失敗，人半夜看到紅字重跑一次」。
#
# ---- 2026-09-27（D2b route C）：歸屬證據換了，這支測試的斷言跟著翻 --------
#
# 新的 `wf_dispatch` 用兩個頻道取得「哪一筆是我們的」：
#   1. 主：`gh workflow run` 的 stdout（gh>=2.87 送 return_run_details，
#      非 TTY 印一行 run URL）→ 直接拿到 run id。
#   2. 退路：dispatch 時帶 `-f nonce=<16hex>`，比對 `displayTitle` 含該 nonce
#      的那筆。三支 workflow 都加了 `nonce` 輸入與 `run-name:` 內插它
#      （refresh-authorized-keys.yml 是第四支，同樣形狀）。
#   兩個都沒有 → rc 3「不知道」，**不退回差集**（「恰好一筆」沒有歸屬證據）。
# 舊斷言的前提（差集是唯一線索、窗的密度重要、baseline 讀不到要另立分支）
# 隨設計一起消失；每一條的翻轉寫在下面各節的註解，完整對照表在
# OUT-d2b-route-c.md。**沒有一條是為了求綠而刪的**：語意還在的斷言都留著
# （8a–8c 呼叫端、讀取失敗、未知不可折疊），只是夾具換成新契約能表達的形狀。
#
# 不驗實作細節：假 gh 同時提供兩個頻道，「新版模式」印 URL、「舊版模式」不
# 印；`displayTitle` 由假 gh 在 run list 時把呼叫端傳的 nonce 內插進標題
# （模擬 run-name 已生效）。判準只看 rc、有沒有 follow 錯人、訊息說不說得出
# 認不出。做法若換成任何等效形式，這些斷言照樣成立。
#
# 全離線：gh／sleep 走 PATH stub，gh 套用 `--json` 投影與 `--jq` 的語意與真
#   gh 相同。mlp 以「剝掉尾端 standalone main 呼叫」的副本 source（本體是
#   函式庫）。
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
mkdir -p "$SHIMS" "$HOME_DIR" "$STATE"

pass=0; fail=0; injfail=0; injpass=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass + 1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- 假 gh：記 argv、套 --json／--jq（真 gh 的語意） -------------------------
# 狀態檔（$FAKE_STATE）：
#   lists  一行 = 一次 run list 的原始 JSON（%NONCE%／%OURID% 會被代換）；
#          一行 "FAIL" 代表該次讀取失敗（exit 1）；用完停在最後一行。
#   view   run view 的 payload（同樣代換）；run view 永遠查得到。
#   mode   new|legacy  workflow run 印不印 run URL
#   nonce  dispatch 時收到的 -f nonce 值（假 gh 自己記）
#   ourid  我們那筆 run 的 databaseId（scenario 用檔指定，預設 102）
#   dispatch_rc  非 0 → dispatch 被拒
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
_apply_jq() {
    local json="$1"; shift
    local fields="" filter="" prev=""
    for a in "$@"; do
        [[ "$prev" == "--json" ]] && fields="$a"
        [[ "$prev" == "--jq" ]] && filter="$a"
        prev="$a"
    done
    if [[ -n "$fields" ]]; then
        if [[ "$json" == \[* ]]; then
            json="$(printf '%s' "$json" | jq -c "[.[] | {${fields}}]")"
        else
            json="$(printf '%s' "$json" | jq -c "{${fields}}")"
        fi
    fi
    if [[ -n "$filter" ]]; then printf '%s' "$json" | jq -r "$filter"
    else printf '%s\n' "$json"; fi
}
_subst() {
    # 把 fixture 的佔位符代換成這次 dispatch 的實況（nonce 是執行時產生的，
    # 夾具寫不了字面值）。
    local s=""
    [[ -f "$FAKE_STATE/nonce" ]] && s="$(cat "$FAKE_STATE/nonce")"
    local o="102"
    [[ -f "$FAKE_STATE/ourid" ]] && o="$(cat "$FAKE_STATE/ourid")"
    printf '%s' "$1" | sed -e "s/%NONCE%/${s}/g" -e "s/%OURID%/${o}/g"
}
case "${1:-} ${2:-}" in
  "workflow run")
    args="$*"
    # 記下 -f nonce= 的值：後面 run list 的標題要靠它。
    for a in "$@"; do
        case "$a" in
            nonce=*) printf '%s' "${a#nonce=}" > "$FAKE_STATE/nonce" ;;
        esac
    done
    if [[ "${FAKE_DISPATCH_RC:-0}" -ne 0 ]]; then
        echo "could not create workflow dispatch event (fake 500)" >&2
        exit 1
    fi
    if [[ "$(cat "$FAKE_STATE/mode")" == "new" ]]; then
        o="102"; [[ -f "$FAKE_STATE/ourid" ]] && o="$(cat "$FAKE_STATE/ourid")"
        printf 'https://github.com/testowner/testrepo/actions/runs/%s\n' "$o"
    fi
    exit 0 ;;
  "run list")
    n=0; [[ -f "$FAKE_STATE/list.idx" ]] && n="$(cat "$FAKE_STATE/list.idx")"
    line="$(sed -n "$((n+1))p" "$FAKE_STATE/lists")"
    [[ -z "$line" ]] && line="$(tail -n 1 "$FAKE_STATE/lists")"
    printf '%s' "$((n+1))" > "$FAKE_STATE/list.idx"
    if [[ "$line" == "FAIL" ]]; then exit 1; fi
    # 真 gh 的列表是新的在前；fixture 可以任意順序寫，這裡照 id 排。
    _apply_jq "$(_subst "$line" | jq -c 'sort_by(-.databaseId)')" "$@"
    exit 0 ;;
  "run view")
    _apply_jq "$(_subst "$(cat "$FAKE_STATE/view")")" "$@"
    exit 0 ;;
esac
exit 0
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIMS/sleep"
chmod +x "$SHIMS/gh" "$SHIMS/sleep"

# ---- 被測物：剝掉尾端 standalone main 的 mlp 副本 ---------------------------
# mlp 尾端是 `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`，
# source 時本來就不會跑 main；但把它剝掉可避免任何 future 變動讓 source
# 意外執行 CLI。副本放在一棵 symlink 回 repo `scripts/` 的樹下（同
# test-wf-dispatch-own-run.sh）：mlp 現在會 `source ${REPO_ROOT}/scripts/lib/
# refresh-wait.sh`（借 refresh_new_nonce），REPO_ROOT 是「這份副本的上一層」，
# 少了這棵樹，那個 source 會靜默失敗 → nonce 為空 → contains("") 命中每一筆。
TREE="$SANDBOX/tree"
mkdir -p "$TREE/ops-scripts"
ln -s "$REPO_ROOT/scripts" "$TREE/scripts"
python3 - "$REPO_ROOT/$MLP" "$TREE/ops-scripts/mlp-lib.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
out = re.sub(
    r'\nif \[\[ "\$\{BASH_SOURCE\[0\]\}" == "\$\{0\}" \]\]; then\n    main "\$@"\nfi\n?\Z',
    '\n', src)
assert 'main "$@"' not in out, "standalone main call not stripped"
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
LIB_COPY="$TREE/ops-scripts/mlp-lib.sh"
if [[ $? -eq 0 ]] && ! grep -q 'main "\$@"' "$LIB_COPY" \
&& ( bash -c "source '$LIB_COPY' >/dev/null 2>&1; declare -F refresh_new_nonce >/dev/null" ); then
    ok "harness. 剝尾副本可 source，且 refresh_new_nonce（mlp 借用的 nonce 產生器）讀得到"
else
    bad "harness. 剝尾失敗或 refresh_new_nonce 讀不到——後面所有斷言都不可信"
fi

# run_wf <mlp-lib-path> <lists> <view> [dispatch-rc] [mode]
#   mode 預設 legacy（不印 URL → 走 nonce 退路）；'new' 走 run id 主路徑。
#   回傳 rc，stdout→$WF_OUT、stderr→$WF_ERR。
run_wf() {
    local lib="$1" lists="$2" view="$3" dispatch_rc="${4:-0}" mode="${5:-legacy}"
    printf '%s\n' "$lists" > "$STATE/lists"
    printf '%s' "$view" > "$STATE/view"
    printf '%s' "$mode" > "$STATE/mode"
    rm -f "$STATE/nonce"
    printf '102' > "$STATE/ourid"
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

# ---- 夾具常數 ---------------------------------------------------------------
# 外部 run（別人的）：沒有我們的 nonce，標題只是 workflow 名。
FOREIGN100='{"databaseId":100,"status":"completed","conclusion":"success","displayTitle":"Test Worker"}'
FOREIGN101='{"databaseId":101,"status":"completed","conclusion":"success","displayTitle":"Test Worker"}'
FOREIGN103='{"databaseId":103,"status":"completed","conclusion":"success","displayTitle":"Test Worker"}'
FOREIGN104='{"databaseId":104,"status":"completed","conclusion":"success","displayTitle":"Test Worker"}'
# 我們的 run：標題含本次 dispatch 的 nonce（run-name 已生效的形狀）。
OUR102_OK='{"databaseId":%OURID%,"status":"completed","conclusion":"success","displayTitle":"Test Worker %NONCE%"}'
OUR102_FAIL='{"databaseId":%OURID%,"status":"completed","conclusion":"failure","displayTitle":"Test Worker %NONCE%"}'
OUR206_FAIL='{"databaseId":206,"status":"completed","conclusion":"failure","displayTitle":"Test Worker %NONCE%"}'
VIEW_OK='{"status":"completed","conclusion":"success","jobs":[]}'
VIEW_FAIL='{"status":"completed","conclusion":"failure","jobs":[]}'

echo "=== 0. 先決條件＋workflow 端的結構守衛 ==="
if grep -q 'wf_dispatch() {' "$MLP" && grep -q 'wf_follow() {' "$MLP"; then
    ok "0a. wf_dispatch 與 wf_follow 都在"
else
    bad "0a. wf_dispatch／wf_follow 不存在——實作還沒落地？"
fi
# 結構守衛：兩個頻道的其中一個（nonce 標題）靠三支＋refresh 的 yml 宣告。
# 假 gh 對任何 -f 欄位照單全收，所以少了這一段，「忘了在 yml 加 run-name」
# 會讓整支測試照樣綠（OUT-test-d2b-agnostic §7-1 記的正是這個洞）。
guard_py="$(python3 - "$REPO_ROOT" <<'PY'
import sys, yaml
root = sys.argv[1]
want = {
    "create-worker.yml": "Create Worker",
    "delete-worker.yml": "Delete Worker",
    "rotate-gateway.yml": "Rotate Gateway",
    "refresh-authorized-keys.yml": None,  # refresh 的標題前綴不同（小寫），只驗欄位
}
bad = []
for fn, prefix in want.items():
    path = root + "/.github/workflows/" + fn
    try:
        doc = yaml.safe_load(open(path, encoding="utf-8"))
    except Exception as exc:
        bad.append("%s: unreadable (%s)" % (fn, exc))
        continue
    on = doc.get("on") or doc.get(True)  # YAML 會把 on: 讀成布林 True
    inputs = ((on or {}).get("workflow_dispatch") or {}).get("inputs") or {}
    nonce = inputs.get("nonce")
    if not isinstance(nonce, dict) or nonce.get("default") != "":
        bad.append("%s: nonce input missing or default != ''" % fn)
    rn = doc.get("run-name") or ""
    if "inputs.nonce" not in rn:
        bad.append("%s: run-name does not interpolate inputs.nonce (%r)" % (fn, rn))
    if prefix and not rn.startswith(prefix):
        bad.append("%s: run-name %r does not start with %r" % (fn, rn, prefix))
print("; ".join(bad) if bad else "ok")
PY
)"
if [[ "$guard_py" == "ok" ]]; then
    ok "0b. 四支 workflow 都有選填 nonce input（default ''）且 run-name 內插它"
else
    bad "0b. workflow 端結構不完整：[$guard_py]"
fi


# ===========================================================================
# 0c–0e（issue #7 tasks 1.3 / openspec D3）：refresh workflow 的排程形狀。
#
# 為什麼放在這支檔：它已經用真 YAML parser 讀四支 workflow，refresh 也已經在
# 0b 的清單裡。**不要**用 grep 讀 workflow——註解、縮排、多個 `on:` 都會骗過
# grep；這支檔的 0b 已經示範了正確做法。
#
# 一個必須知道的坑（PyYAML / YAML 1.1）：裸 `on:` 會被讀成**布林 True**，
# `doc["on"]` 會 KeyError。0b 用 `doc.get("on") or doc.get(True)` 繞過，
# 下面沿用同一行。
#
# 形狀來源：design D3 與 review 的 OUT-review-issue7-schedule-title.md
# §3.1（run-name 加上 github.event_name，讓每日那筆自我識別）。
# ===========================================================================
WF_REFRESH="$REPO_ROOT/.github/workflows/refresh-authorized-keys.yml"

# wf_refresh_shape <yml路徑> — 四件事一起查，印 "ok" 或問題清單：
#   1. on.schedule 存在且 cron == "0 20 * * *"（UTC 每日一次）
#   2. 沒有 concurrency（非目標：使用者裁示不加，釘住「不要有人順手加」）
#   3. run-name 有字面前綴、不是空白-only（空白-only 會讓 GitHub 默默換成
#      event-specific 資訊，整套 nonce 認領機制就建立在這個字串上）
#   4. **沒有任何 step 讀 inputs.\***：排程事件不帶 input，`inputs.nonce` 在
#      schedule 下求值成空字串，所以有 step 讀它就是「排程那筆會不會失敗」
#      的實際風險。允許 inputs.* 出現在 run-name 裡（那正是認領機制要的）。
wf_refresh_shape() {
    python3 - "$1" <<'PY'
import sys, yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
on = doc.get("on") or doc.get(True)   # YAML 1.1：裸 on: 讀成布林 True
on = on or {}
bad = []

# 1. 每日排程 + cron
sched = on.get("schedule")
if not isinstance(sched, list) or not sched:
    bad.append("no on.schedule block")
else:
    crons = [c.get("cron") for c in sched if isinstance(c, dict)]
    if crons != ["0 20 * * *"]:
        bad.append("schedule cron is %r, want ['0 20 * * *']" % (crons,))

# 2. 沒有 concurrency
if doc.get("concurrency") is not None:
    bad.append("concurrency present (%r) — not in scope for this change" % (doc.get("concurrency"),))

# 3. run-name 有字面前綴（非空白-only）
rn = doc.get("run-name")
if not isinstance(rn, str) or not rn.strip():
    bad.append("run-name missing or whitespace-only")

# 4. 沒有任何地方讀 inputs.*（run-name 裡的 inputs.* 是設計要的，不算）。
#    掃描面要蓋住所有能拿到 `inputs` 上下文並在**排程事件下求值成空字串**的
#    位置：step 的 with／run／uses／if／env，job 的 if／env／container.env。
#    （第一版只掃 with/run/uses，漏掉 if 與 env——那是這個檢查器真正的洞，
#     `if: ${{ inputs.x == 'y' }}` 在排程那筆就是空值。）job/step 層的
#    `runs-on`、`timeout-minutes`、`permissions` 不吃 inputs 上下文，不掃。
def _blob(d):
    out = []
    for k in ("if", "run", "uses"):
        if isinstance(d.get(k), str):
            out.append(d[k])
    for k in ("with", "env", "container"):
        v = d.get(k)
        if isinstance(v, dict):
            out += [str(x) for x in v.values()]
            if isinstance(v.get("env"), dict):
                out += [str(x) for x in v["env"].values()]
    return out

for jn, job in (doc.get("jobs") or {}).items():
    for b in _blob(job):
        if "inputs." in b:
            bad.append("job %r reads inputs.* (%r)" % (jn, b[:60]))
    for step in (job.get("steps") or []):
        for b in _blob(step):
            if "inputs." in b:
                bad.append("step %r reads inputs.* (%r)" % (step.get("name"), b[:60]))
print("; ".join(bad) if bad else "ok")
PY
}

sh="$(wf_refresh_shape "$WF_REFRESH")"
if [[ "$sh" == "ok" ]]; then
    ok "0c. refresh workflow：每天 20:00 UTC 排程、沒有 concurrency、run-name 非空白、沒有 step 讀 inputs.*"
else
    bad "0c. workflow 形狀不符：[$sh]"
fi

# 0f. **正對照**：這個檢查器不能是「永遠回問題」——拿一份**已知合格**的合成
#     workflow 餵它，必須回 ok。沒有這條，0c 的紅有可能只是檢查器寫壞。
cat > "$SANDBOX/good-refresh.yml" <<'YML'
name: Refresh Authorized Keys
on:
  workflow_dispatch:
    inputs:
      nonce:
        required: false
        default: ''
        type: string
  schedule:
    - cron: "0 20 * * *"
run-name: refresh-authorized-keys ${{ github.event_name }} ${{ inputs.nonce }}
permissions:
  contents: read
jobs:
  refresh:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Refresh
        run: echo hi
YML
if [[ "$(wf_refresh_shape "$SANDBOX/good-refresh.yml")" == "ok" ]]; then
    ok "0f. 正對照：合成出的一份合格 workflow 讓同一個檢查器回 ok（0c 的紅不是檢查器壞掉）"
else
    inj_bad "0f. 檢查器連合格檔案都判不合格（[$SANDBOX/good-refresh.yml]）——0c 的紅沒意義"
fi

# 注入：每一條都要證明 0c 抓得到。突變寫在沙箱裡，repo 的 workflow 沒動。
# wf_mut <名字> <python片段檔> <輸出路徑> — 片段檔是一段 python，只做
#   `src = src.replace(...)`，在這裡執行後**寫出**結果。repo 的 workflow 不動。
# 注入：每一條都要證明 0c 抓得到。三個突變各自是一段 python、直接寫出突變後的
# yml（不經過「片段檔」那一層——多一層就多一次跳脫地雷，而且出錯時不會報錯，
# 只會看起來像「注入沒抓到」）。突變檔都在沙箱裡，repo 的 workflow 沒動。
mkdir -p "$SANDBOX/wfmut"

# m1：cron 改成每 5 分鐘（正是這次燒掉額度的頻率）。
python3 - "$WF_REFRESH" "$SANDBOX/wfmut/m1.yml" <<'PYM1'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
# **改現有的那一筆 cron**，不要「再插一個 schedule:」——第一版就是插一個，
# 結果 PyYAML 的重複鍵語意（後者覆蓋前者）讓 `*/5` 被檔案裡本來就有的
# `0 20 * * *` 蓋掉，突變靜靜變成 no-op，而檢查器（正確地）回 ok。
# 教訓：注入必須證明自己真的改到檔案，否則「檢查器沒抓到」分不清是檢查器
# 壞掉還是突變沒生效。這裡用 `!= -1` 當場驗收。
old = 'cron: "0 20 * * *"'
new = 'cron: "*/5 * * * *"'
i = src.find(old)
assert i != -1, "m1 needle missing"
src = src[:i] + new + src[i + len(old):]
open(sys.argv[2], "w", encoding="utf-8").write(src)
PYM1

# m2：加一個 concurrency group（非目標，釘住「不要有人順手加」）。
python3 - "$WF_REFRESH" "$SANDBOX/wfmut/m2.yml" <<'PYM2'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "permissions:"
new = "concurrency:\n  group: refresh-authkeys\n  cancel-in-progress: true\n\npermissions:"
assert src.count(old) >= 1, "m2 needle missing"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PYM2

# m3：有 step 用 `if:` 讀 inputs.nonce —— 排程那筆會拿到空值。
#     刻意用 `if:` 而不是 `run:`：掃描面若只看 run/with/uses 就漏掉它。
python3 - "$WF_REFRESH" "$SANDBOX/wfmut/m3.yml" <<'PYM3'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "      - name: Checkout"
new = '      - name: Gate\n        if: ${{ inputs.nonce != \'\' }}\n      - name: Checkout'
assert src.count(old) == 1, "m3 needle count=%d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PYM3

for m in m1 m2 m3; do
    case "$m" in
        m1) why="cron 改成每 5 分鐘" ;;
        m2) why="加了 concurrency group" ;;
        m3) why="有 step 用 if 讀 inputs.nonce" ;;
    esac
    if [[ ! -s "$SANDBOX/wfmut/$m.yml" ]]; then
        # 突變沒產出檔案＝needle 落空。這時候**不能**拿檢查器對著空檔案的結論
        # 當證據——那會是「檔案壞掉」而不是「形狀被抓」。
        inj_bad "0-inj-${m}. 突變沒產出檔案（needle 落空？）——harness 問題，這條注入等於沒測"
        continue
    fi
    got="$(wf_refresh_shape "$SANDBOX/wfmut/$m.yml" 2>/dev/null)"
    if [[ "$got" == "ok" ]]; then
        inj_bad "0-inj-${m}. ${why}之後檢查器仍回 ok——它抓不到這個"
    else
        inj_ok "0-inj-${m}. ${why} → 檢查器抓到（[$got]）——0c 紅得有效"
    fi
done

echo "=== 1. 主路徑：gh 印出 run URL → 直接認領（有證據） ==="
# 舊 1a（「恰好一筆新 run → 認領」）的翻轉：認領的理由從「窗內唯一」變成
# 「API 說就是這筆」。rc 的意義不變（我們那次成功=0）。
got="$(run_wf "$LIB_COPY" "$(printf '%s\n%s' "[$FOREIGN101,$FOREIGN100]" "[$OUR102_OK,$FOREIGN101,$FOREIGN100]")" "$VIEW_OK" 0 new)"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'actions/runs/102'; then
    ok "1a. 新版 gh：rc 0、認領 API 回報的 102"
else
    bad "1a. 新版模式下沒認領 API 回報的 run（got [$got]）"
fi
# 1b：確真的 follow 了它（run view 帶著那個 id）。語意不變，保留。
if grep -q '^run view 102 ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "1b. 認領後真的 follow 了 102（run view 帶對 id）"
else
    bad "1b. 沒有對 102 跑 run view（argv [$(tr '\n' '|' < "$SANDBOX/gh-argv.log" | head -c 200)]）"
fi
# 1c（新）：nonce 真的有被傳出去，且是不可預測的 16 hex——退路頻道的存在
# 前提。16 hex 的形狀由 refresh_new_nonce 保證；這裡從 argv 反讀。
nonce_seen="$(sed -n 's/.*-f nonce=\([^ ]*\).*/\1/p' "$SANDBOX/gh-argv.log" | head -n 1)"
if [[ "$nonce_seen" =~ ^[0-9a-f]{16}$ ]]; then
    ok "1c. dispatch 帶了 16-hex nonce（${nonce_seen:0:4}…）——標題頻道的燃料"
else
    bad "1c. dispatch 沒有帶合法的 nonce（argv [$(head -1 "$SANDBOX/gh-argv.log" | head -c 140)]）"
fi
# 1d：同一份 stdout 若沒有 URL，不得把標題裡「長得像 URL」的隨機文字當 id。
got="$(run_wf "$LIB_COPY" "$(printf '%s\n%s' "[$FOREIGN101]" "[$OUR102_OK,$FOREIGN101]")" "$VIEW_OK" 0 legacy)"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'actions/runs/102'; then
    ok "1d. 舊版 gh：rc 0、靠標題裡的 nonce 認領 102（退路頻道真的在工作）"
else
    bad "1d. 舊版模式下沒有靠 nonce 認領（got [$got]）"
fi

echo "=== 2. 兩筆新 run 同時出現：認我們那筆（有 nonce）、不碰別人的 ==="
# 舊 2a（「兩筆 → 不認領、兩筆 URL 都印」）的翻轉：現在有歸屬證據了，正確
# 行為是認領自己的；「印出所有候選讓人自己猜」不再是要求。
got="$(run_wf "$LIB_COPY" "$(printf '%s\n%s' "[$FOREIGN101,$FOREIGN100]" "[$FOREIGN103,$OUR102_OK,$FOREIGN101,$FOREIGN100]")" "$VIEW_OK")"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'actions/runs/102'; then
    ok "2a. 窗內有別人的 103：認領我們帶 nonce 的 102、rc 0"
else
    bad "2a. 有證據時沒認領對的那筆（got [$got]）"
fi
# 2b（舊：未知時零 view）翻轉成「只 follow 我們那筆」：別人一次都不能被 view。
if grep -q '^run view 102 ' "$SANDBOX/gh-argv.log" 2>/dev/null \
&& ! grep -q '^run view 103 ' "$SANDBOX/gh-argv.log" 2>/dev/null \
&& ! grep -q '^run view 101 ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "2b. 只 follow 了 102；103／101（別人的）一次都沒被 view"
else
    bad "2b. follow 了不該 follow 的 id（argv [$(grep '^run view' "$SANDBOX/gh-argv.log" | tr '\n' '|')]）"
fi

echo "=== 3. 別人的先出、我們的後出（或較舊）：仍認我們那筆 ==="
# 舊 3a（「順序完全正確時仍不認領」）的翻轉：舊碼錯的原因正是「先到先贏／
# 只看最新」；現在歸屬看 nonce，與位置、到達順序無關。
got="$(run_wf "$LIB_COPY" "$(printf '%s\n%s' "[$FOREIGN101,$FOREIGN100]" "[$OUR206_FAIL,$FOREIGN101,$FOREIGN100]")" "$VIEW_FAIL")"
if [[ "$got" == RC=1* ]] && printf '%s' "$got" | grep -qF 'actions/runs/206' \
&& ! grep -q '^run view 101 ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "3a. 別人的先出現：認領後到的 206（我們那次失敗 → rc 1）、沒碰 101"
else
    bad "3a. 順序／位置干擾了歸屬（got [$got]）"
fi
# 3b：我們的 id 比別人小（排在列表後面）——證明不是「拿最新」的巧合。
got="$(run_wf "$LIB_COPY" "$(printf '%s\n%s' "[$FOREIGN104,$FOREIGN103]" "[$FOREIGN104,$FOREIGN103,$OUR102_OK,$FOREIGN101,$FOREIGN100]")" "$VIEW_OK")"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'actions/runs/102'; then
    ok "3b. 我們那筆在列表較舊的位置：一樣認 102（不是『拿最新』的巧合）"
else
    bad "3b. 較舊位置時認錯或漏認（got [$got]）"
fi

echo "=== 4. 沒有證據時：rc 3『不知道』，不猜、不 follow ==="
# 舊 4a（「零筆新 run → rc 1 never appeared」）的翻轉：新設計裡「沒有新 run」
# 觀測不到——標題沒出現可能是 run-name 沒展開，dispatch 其實成功了。所以
# 「乾淨讀到列表但沒有我們的 nonce」是**未知（rc 3）**，不是明確失敗。
# rc 1 只剩「dispatch 本身失敗」一種（見 4b、8b 的「我們那次失敗」）。
got="$(run_wf "$LIB_COPY" "$(printf '%s\n%s' "[$FOREIGN101,$FOREIGN100]" "[$FOREIGN101,$FOREIGN100]")" "$VIEW_OK")"
if [[ "$got" == RC=3* ]] && printf '%s' "$got" | grep -qF 'no run carries this dispatch nonce' \
&& ! grep -q '^run view ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "4a. 讀得到列表、但沒有我們的 nonce：rc 3、訊息點名 nonce、零 run view"
else
    bad "4a. 無證據時的處理不對（got [$got]）"
fi
# 4b：dispatch 本身失敗 → 明確失敗（不可被誤認為未知）。語意不變。
got="$(run_wf "$LIB_COPY" "$(printf '%s\n%s' "[$FOREIGN101,$FOREIGN100]" "[$OUR102_OK,$FOREIGN101,$FOREIGN100]")" "$VIEW_OK" 1)"
if [[ "$got" == RC=1* ]] && printf '%s' "$got" | grep -qF 'could not dispatch'; then
    ok "4b. dispatch 失敗：rc 1、明確說 could not dispatch"
else
    bad "4b. dispatch 失敗的行為不對（got [$got]）"
fi

echo "=== 5. 三態可分：未知不是成功、也不是失敗 ==="
# 舊 5a 的夾具換了（差集窗 → 兩個頻道），判準不變：0／1／3 互異。
rc_ok="$(run_wf "$LIB_COPY" "[$OUR102_OK,$FOREIGN100]" "$VIEW_OK" 0 new)"
rc_fail="$(run_wf "$LIB_COPY" "[$OUR102_FAIL,$FOREIGN100]" "$VIEW_FAIL")"
rc_unknown="$(run_wf "$LIB_COPY" "[$FOREIGN101,$FOREIGN100]" "$VIEW_OK")"
r_ok="${rc_ok%% *}"; r_fail="${rc_fail%% *}"; r_unknown="${rc_unknown%% *}"
r_ok="${r_ok#RC=}"; r_fail="${r_fail#RC=}"; r_unknown="${r_unknown#RC=}"
if [[ "$r_ok" == "0" && "$r_fail" == "1" && "$r_unknown" != "0" && "$r_unknown" != "1" ]]; then
    ok "5a. 三態互異：成功=${r_ok}、明確失敗=${r_fail}、未知=${r_unknown}（未知不是 0 也不是 1）"
else
    bad "5a. 三態沒有分開（ok=${r_ok} fail=${r_fail} unknown=${r_unknown}）——未知被折疊成成功或失敗"
fi
# 5b：未知時 stdout 必須說得出「我不能確定」。舊措辭（cannot tell which one
# is ours）隨差集邏輯消失；新措辭以「could not identify our run」開頭，
# 這裡用 regex 同時接受兩種（不綁死實作字串）。
if printf '%s' "$rc_unknown" | grep -qE "could not identify|cannot tell which one is ours"; then
    ok "5b. 未知的輸出直說『認不出來』（不是靜靜回一個碼）"
else
    bad "5b. 未知情境沒有說出不能確定（got [$rc_unknown]）"
fi
# 5c：未知不可被 follow——run view 一次都不能發生。語意不變。
if ! grep -q '^run view ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "5c. 未知時零 run view（不 follow 猜測的那一筆）"
else
    bad "5c. 未知時仍 follow 了（argv [$(grep '^run view' "$SANDBOX/gh-argv.log" | tr '\n' '|')]）"
fi

echo "=== 9. 讀不到列表 ≠ 列表裡沒有我們的 nonce（兩種未知要分得開） ==="
# 9a：整段等待中每一次讀取都失敗 → rc 3，訊息說「讀不到」。
#    lists 只有一行 "FAIL"（用完停在最後一行）＝每一次讀取都失敗。
got="$(run_wf "$LIB_COPY" 'FAIL' "$VIEW_OK")"
if [[ "$got" == RC=3* ]] \
&& printf '%s' "$got" | grep -qF 'could not be read at any point' \
&& ! printf '%s' "$got" | grep -qF 'no run carries this dispatch nonce'; then
    ok "9a. 每次讀取都失敗：rc 3、訊息說讀不到、不含『nonce 不在』"
else
    bad "9a. 讀取持續失敗時 rc 或訊息不對（got [$got]）"
fi
# 9b：讀得到、但沒有我們的 nonce → rc 3，訊息說「列表裡沒有這個 nonce」。
# 與 9a 兩句不同、可分辨——這是 PM 追加要求的「兩種未知都寫明」。
got="$(run_wf "$LIB_COPY" "[$FOREIGN101]" "$VIEW_OK")"
if [[ "$got" == RC=3* ]] \
&& printf '%s' "$got" | grep -qF 'no run carries this dispatch nonce' \
&& ! printf '%s' "$got" | grep -qF 'could not be read at any point'; then
    ok "9b. 讀得到但 nonce 不在：rc 3、訊息與 9a 可分辨（點名 nonce）"
else
    bad "9b. 讀得到但沒 nonce 時的 rc 或訊息不對（got [$got]）"
fi
# 9d：其中一輪讀取失敗、之後成功且有一筆我們的 run → 失敗那輪不進結論，
# 最終仍正確認領（不可因單輪抖動誤判）。語意不變。
got="$(run_wf "$LIB_COPY" "$(printf '%s\n%s\n%s' "[$FOREIGN101]" 'FAIL' "[$OUR102_OK,$FOREIGN101]")" "$VIEW_OK")"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'actions/runs/102'; then
    ok "9d. 單輪讀取失敗＋之後恢復：rc 0、輸出含 actions/runs/102"
else
    bad "9d. 單輪失敗後回復時 rc 或認領 id 不符（got [$got]）"
fi

echo "=== 10. 窗的密度不重要：沒有 nonce 就不認，再多筆也一樣 ==="
# 舊 10a／10b 守的是 baseline 讀取（分支已不存在）。翻轉成同樣的判準：
# 「窗裡有幾筆別人的 run」不影響結論——沒有歸屬證據就 rc 3，絕不 follow
# 任何一筆。稀疏窗與密集窗兩條都要求同一件事，正是「密度不再重要」的證明。
got_sparse="$(run_wf "$LIB_COPY" "[$FOREIGN100]" "$VIEW_OK")"
if [[ "$got_sparse" == RC=3* ]] \
&& printf '%s' "$got_sparse" | grep -qF 'no run carries this dispatch nonce' \
&& ! grep -q '^run view ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "10a. 稀疏窗（只有一筆別人的）：rc 3、零 run view"
else
    bad "10a. 稀疏窗時認領了沒有證據的 run（got [$got_sparse]）"
fi
got_dense="$(run_wf "$LIB_COPY" "[$FOREIGN104,$FOREIGN103,$FOREIGN101,$FOREIGN100]" "$VIEW_OK")"
if [[ "$got_dense" == RC=3* ]] \
&& printf '%s' "$got_dense" | grep -qF 'no run carries this dispatch nonce' \
&& ! grep -q '^run view ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "10b. 密集窗（四筆別人的）：同一種 rc 3、同一句訊息——判準與筆數無關"
else
    bad "10b. 密集窗走了別條分支（got [$got_dense]）"
fi
# 10c：窗裡只有我們自己的 run（帶 nonce）→ 認領它。翻轉自舊「空 baseline」
# 案例：證據是 nonce，不是「窗裡只有一筆」。
got="$(run_wf "$LIB_COPY" "[$OUR102_OK]" "$VIEW_OK")"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'actions/runs/102'; then
    ok "10c. 窗裡只有我們那筆（帶 nonce）→ rc 0、認領 102"
else
    bad "10c. 只有我們那筆時 rc 或認領 id 不符（got [$got]）"
fi

echo "=== 11. 跨輪詢 race（舊的已知限制，已修） ==="
# 舊 11a 的斷言是「認錯 101，這是已知限制（根因：沒有 nonce）」，並註明
# 「若哪天加上 nonce 而修好了，這條會轉紅，提醒把它改成應該要對」。
# 就是現在：翻轉成「認對 102」。
got="$(run_wf "$LIB_COPY" "$(printf '%s\n%s\n%s' '[]' "[$FOREIGN101]" "[$OUR102_FAIL,$FOREIGN101]")" "$VIEW_FAIL")"
if [[ "$got" == RC=1* ]] \
&& printf '%s' "$got" | grep -qF 'actions/runs/102' \
&& ! grep -q '^run view 101 ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "11a. sequential race（第 1 輪只看到 101、第 2 輪才出現 102）：認 102（我們失敗→rc 1）、沒碰 101"
else
    bad "11a. race 下認錯或沒認出（got [$got]）"
fi
# 舊 11b（兩筆同輪 → rc 3）翻轉：同輪也認得出（nonce 在標題裡）。
got="$(run_wf "$LIB_COPY" "[$FOREIGN103,$OUR102_OK]" "$VIEW_OK")"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'actions/runs/102' \
&& ! grep -q '^run view 103 ' "$SANDBOX/gh-argv.log" 2>/dev/null; then
    ok "11b. 兩筆同輪出現：認 102（帶 nonce）、不碰 103"
else
    bad "11b. 兩筆同輪時認錯或沒認出（got [$got]）"
fi

echo "=== 12. nonce 取不到時：拒絕 dispatch（零次）、非 0、說出原因 ==="
# 2026-09-27 review 實測的假綠：`refresh_new_nonce` 不存在 → nonce 空 →
# 退路 `contains("")` 命中每一筆 → 認領別人的 run、回 0。這條把「沒有歸屬
# 憑證就不得發動」釘住：**dispatch 之前**檢查，不成立就拒絕（rc 1）且
# gh 一個字都沒送出去。
#
# 夾具：把 mlp 副本的 `refresh_new_nonce` 覆寫成回空字串（模擬函式壞掉／
# 被改名／回空），掛在副本尾端（與注入 mutant 同一手法）。
# 判準三件事：rc 非 0、stderr 說出原因（提到 nonce／refusing）、**零 dispatch**。
# 「零 dispatch」由假 gh 的 argv log 驗——dispatch 若送出去，log 會有
# `workflow run`。
# 用 legacy 模式（stdout 不印 URL）＋一個「有 run 可被誤認」的列表：舊寫法
# 在這裡會認領 101 並回 0（12 的注入就是重演這個）。
mk_nonce_empty() {  # <dst>
    { cat "$LIB_COPY"; printf '%s\n' 'refresh_new_nonce() { printf ""; }'; } > "$1"
    bash -n "$1" 2>/dev/null
}
EMPTY_LIB="$TREE/ops-scripts/mlp-nonce-empty.sh"
if mk_nonce_empty "$EMPTY_LIB"; then
    : > "$SANDBOX/gh-argv.log"
    got="$(run_wf "$EMPTY_LIB" "[$FOREIGN101,$FOREIGN100]" "$VIEW_OK")"
    if [[ "$got" != RC=0* ]] \
    && printf '%s' "$got" | grep -qiE 'nonce|refus' \
    && ! grep -q '^workflow run' "$SANDBOX/gh-argv.log" 2>/dev/null; then
        ok "12a. refresh_new_nonce 回空：拒絕 dispatch（rc ${got%% *}）、訊息說出原因、零次 workflow run"
    else
        bad "12a. 空 nonce 時沒有拒絕（dispatch 送出了或訊息沒說原因；got [$got]；argv [$(head -1 "$SANDBOX/gh-argv.log" 2>/dev/null | head -c 120)]）"
    fi
    # 12b：函式**不存在**（source 不到 refresh-wait.sh 的形狀）→ 同樣拒絕。
    # 用 `unset -f`（副本尾端）模擬；bash -c 子程序每次重開，不會污染別的案例。
    NOFN_LIB="$TREE/ops-scripts/mlp-nonce-nofn.sh"
    { cat "$LIB_COPY"; printf '%s\n' 'unset -f refresh_new_nonce'; } > "$NOFN_LIB"
    if bash -n "$NOFN_LIB" 2>/dev/null; then
        : > "$SANDBOX/gh-argv.log"
        got="$(run_wf "$NOFN_LIB" "[$FOREIGN101,$FOREIGN100]" "$VIEW_OK")"
        if [[ "$got" != RC=0* ]] \
        && printf '%s' "$got" | grep -qiE 'nonce|refus' \
        && ! grep -q '^workflow run' "$SANDBOX/gh-argv.log" 2>/dev/null; then
            ok "12b. refresh_new_nonce 不存在：同樣拒絕（rc ${got%% *}）、零次 workflow run"
        else
            bad "12b. 函式不存在時沒拒絕（got [$got]）"
        fi
    else
        bad "12b. 夾具建不起來（語法錯）——harness 問題"
    fi
    # 12c：非空但**不符字元集**（例如挾帶 shell／jq 中繼字元）→ 一樣拒絕。
    # 這一條守的是「不要拿一個會破壞 --jq 或 -f 的值去 dispatch」。
    BADCH_LIB="$TREE/ops-scripts/mlp-nonce-badchars.sh"
    { cat "$LIB_COPY"; printf '%s\n' 'refresh_new_nonce() { printf "abc\"; touch /tmp/pwned; echo \"x"; }'; } > "$BADCH_LIB"
    if bash -n "$BADCH_LIB" 2>/dev/null; then
        : > "$SANDBOX/gh-argv.log"
        got="$(run_wf "$BADCH_LIB" "[$FOREIGN101,$FOREIGN100]" "$VIEW_OK")"
        if [[ "$got" != RC=0* ]] && ! grep -q '^workflow run' "$SANDBOX/gh-argv.log" 2>/dev/null; then
            ok "12c. nonce 挾帶中繼字元：拒絕（rc ${got%% *}）、零次 workflow run"
        else
            bad "12c. 不符字元集的 nonce 沒有被拒（got [$got]）"
        fi
    else
        bad "12c. 夾具建不起來（語法錯）——harness 問題"
    fi
else
    bad "12. 空 nonce 夾具建不起來（語法錯）——harness 問題"
fi

echo "=== 6-7. 注入：拿掉修正，斷言必須轉紅 ==="
# 6. 收集換成「不看 nonce、拿列表第一筆（最新）」→ 2a／3a 必須紅，且紅在
#    「它認領了別人的」。needle 是新的 nonce 過濾；mutant 換成整表第一筆。
python3 - "$REPO_ROOT/$MLP" "$TREE/ops-scripts/mutant-first-entry.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = """        row="$(gh run list --workflow="$wf" --repo "$REPO" --limit 50 \\
            --json databaseId,status,displayTitle \\
            --jq '[.[] | select((.displayTitle // "") | contains("'"${nonce}"'"))] | first // empty | "\\(.databaseId // 0)"' \\
            2>/dev/null)\""""
new = """        row="$(gh run list --workflow="$wf" --repo "$REPO" --limit 50 \\
            --json databaseId,status,displayTitle \\
            --jq 'first // empty | "\\(.databaseId // 0)"' \\
            2>/dev/null)\""""
assert src.count(old) == 1, "first-entry needle count != 1: %d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]] || ! bash -n "$TREE/ops-scripts/mutant-first-entry.sh" 2>/dev/null; then
    inj_bad "6. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    got="$(run_wf "$TREE/ops-scripts/mutant-first-entry.sh" "$(printf '%s\n%s' "[$FOREIGN101,$FOREIGN100]" "[$FOREIGN103,$OUR102_OK,$FOREIGN101,$FOREIGN100]")" "$VIEW_OK")"
    if printf '%s' "$got" | grep -qF 'run finished' \
    && ! printf '%s' "$got" | grep -qF 'actions/runs/102'; then
        inj_ok "6a. 換成拿列表第一筆後，它認領了別人的 ${got##*actions/runs/}並跑完（got [$(printf '%s' "$got" | head -c 150)]）——2a 會紅"
    else
        inj_bad "6a. 換成拿列表第一筆後 2a 仍綠或認領對了（got [$got]）"
    fi
    # 6b：我們的在較舊位置時也要紅（拿最新的形狀）。
    got="$(run_wf "$TREE/ops-scripts/mutant-first-entry.sh" "$(printf '%s\n%s' "[$FOREIGN104,$FOREIGN103]" "[$FOREIGN104,$FOREIGN103,$OUR102_OK,$FOREIGN101,$FOREIGN100]")" "$VIEW_OK")"
    if printf '%s' "$got" | grep -qF 'actions/runs/104' \
    && printf '%s' "$got" | grep -qF 'run finished' \
    && ! printf '%s' "$got" | grep -qF 'actions/runs/102'; then
        inj_ok "6b. 拿列表第一筆後認領了 104（102 才是我們的）（got [$(printf '%s' "$got" | head -c 150)]）——3b 會紅"
    else
        inj_bad "6b. 換成拿列表第一筆後 3b 仍綠（got [$got]）"
    fi
fi
# 7. 把「未知」折疊成「失敗」→ 三態那條必須紅（3 變 1）。needle 是未知
#    分支收尾的那個 `return 3`（在「could not identify」訊息之後）。
python3 - "$REPO_ROOT/$MLP" "$TREE/ops-scripts/mutant-fold-fail.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
marker = 'echo "  the dispatch went out — look yourself before doing anything else"\n        return 3'
j = src.index(marker)
k = src.index("return 3", j)
src = src[:k] + "return 1" + src[k + len("return 3"):]
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -ne 0 ]] || ! bash -n "$TREE/ops-scripts/mutant-fold-fail.sh" 2>/dev/null; then
    inj_bad "7. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    got="$(run_wf "$TREE/ops-scripts/mutant-fold-fail.sh" "$(printf '%s\n%s' "[$FOREIGN101,$FOREIGN100]" "[$FOREIGN101,$FOREIGN100]")" "$VIEW_OK")"
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
# 夾具換成新契約（legacy＋nonce），判準與舊版一字不差。
cat > "$SHIMS/ssh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$SHIMS/ssh"

# run_cmd_rotate <mlp-lib-path> <lists> <view> <confirm-text> [mode]：
# 跑 `cmd_rotate --real`，確認字串從 stdin 餵入；印 rc 與輸出。
run_cmd_rotate() {
    local lib="$1" lists="$2" view="$3" confirm_text="$4" mode="${5:-legacy}"
    printf '%s\n' "$lists" > "$STATE/lists"
    printf '%s' "$view" > "$STATE/view"
    printf '%s' "$mode" > "$STATE/mode"
    rm -f "$STATE/nonce"
    printf '102' > "$STATE/ourid"
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

# 8a：未知（沒有我們的 nonce）→ rc 3、警告『可能已換掉』＋仍提示 trust-gateway。
got="$(run_cmd_rotate "$LIB_COPY" "[$FOREIGN101,$FOREIGN100]" "$VIEW_OK" "9.9.9.9")"
if [[ "$got" == RC=3* ]] \
&& printf '%s' "$got" | grep -qF 'could not be identified' \
&& printf '%s' "$got" | grep -qF 'may have replaced the live Gateway' \
&& printf '%s' "$got" | grep -qF 'trust-gateway'; then
    ok "8a. cmd_rotate 未知：rc 3、警告『可能已換掉』＋仍提示 trust-gateway（不是紅字叫人重跑）"
else
    bad "8a. cmd_rotate 把未知折疊了或不說明後果（got [$got]）"
fi
# 8b：明確失敗（認到我們那筆、結論 failure）→ rc 1，且**不**提示 trust-gateway。
#     舊版靠 NO_NEW 夾具得到 rc 1；現在 rc 1 的來源是「我們那次失敗」，夾具
#     換成帶 nonce 的失敗 run。
got="$(run_cmd_rotate "$LIB_COPY" "[$OUR102_FAIL,$FOREIGN101,$FOREIGN100]" "$VIEW_FAIL" "9.9.9.9")"
if [[ "$got" == RC=1* ]] && ! printf '%s' "$got" | grep -qF 'trust-gateway'; then
    ok "8b. cmd_rotate 明確失敗：rc 1、不提示 trust-gateway（沒有換機）"
else
    bad "8b. 明確失敗的處理不對（got [$got]）"
fi
# 8c：成功（認到我們那筆、結論 success）→ rc 0，提示 trust-gateway。
got="$(run_cmd_rotate "$LIB_COPY" "[$OUR102_OK,$FOREIGN101,$FOREIGN100]" "$VIEW_OK" "9.9.9.9")"
if [[ "$got" == RC=0* ]] && printf '%s' "$got" | grep -qF 'trust-gateway'; then
    ok "8c. cmd_rotate 成功：rc 0、提示 trust-gateway（與從前一樣）"
else
    bad "8c. 成功路徑的行為變了（got [$got]）"
fi

# 8. 把呼叫端的「未知」折疊成失敗（`|| return 1` 的舊形狀）→ 8a 必須紅。
#    這正是「rotate 其實成功卻報成失敗、人半夜重跑」的形狀。cmd_rotate 的
#    原文沒動，needle 與舊版一字不差。
python3 - "$REPO_ROOT/$MLP" "$TREE/ops-scripts/mutant-caller-fold.sh" <<'PY'
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
if [[ $? -ne 0 ]] || ! bash -n "$TREE/ops-scripts/mutant-caller-fold.sh" 2>/dev/null; then
    inj_bad "8. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    got="$(run_cmd_rotate "$TREE/ops-scripts/mutant-caller-fold.sh" "[$FOREIGN101,$FOREIGN100]" "$VIEW_OK" "9.9.9.9")"
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

# 9. 把「讀取失敗」記成成功讀取 → 9a 的訊息必須紅（兩種未知被混成一句）。
#    needle 是輪詢裡判斷讀取失敗的 if 行；mutant 讓它永遠不成立。
python3 - "$REPO_ROOT/$MLP" "$TREE/ops-scripts/mutant-readok.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "        if [[ $? -ne 0 ]]; then"
assert src.count(old) == 1, "readok needle count != 1: %d" % src.count(old)
src = src.replace(old, "        if false; then", 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -ne 0 ]] || ! bash -n "$TREE/ops-scripts/mutant-readok.sh" 2>/dev/null; then
    inj_bad "9. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    got="$(run_wf "$TREE/ops-scripts/mutant-readok.sh" "$(printf '%s\n%s' "[$FOREIGN101]" 'FAIL')" "$VIEW_OK")"
    if [[ "$got" == RC=3* ]] && printf '%s' "$got" | grep -qF 'could not be read at any point'; then
        inj_bad "9. 讀取失敗被記成成功後仍說『讀不到』——注入沒生效（got [$got]）"
    else
        if [[ "$got" == RC=3* ]] && printf '%s' "$got" | grep -qF 'no run carries this dispatch nonce'; then
            inj_ok "9. 讀取失敗被折成『讀到了、只是沒 nonce』（訊息變了；got [$(printf '%s' "$got" | head -c 130)]）——9a 會紅"
        else
            inj_bad "9. 行為變了但不是預期的折疊（got [$got]）——harness 問題"
        fi
    fi
fi
# 10. 空 nonce（contains("") 命中每一筆）→ 2a／3a 必須紅：它會認領列表
#     第一筆（別人的）。needle 是 nonce 內插那一小段。
python3 - "$REPO_ROOT/$MLP" "$TREE/ops-scripts/mutant-empty-nonce.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = """contains("'"${nonce}"'")"""
assert src.count(old) == 1, "empty-nonce needle count != 1: %d" % src.count(old)
# 換成空字串：contains("") 對每個標題都真 → 永遠命中第一筆。
src = src.replace(old, 'contains("")', 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -ne 0 ]] || ! bash -n "$TREE/ops-scripts/mutant-empty-nonce.sh" 2>/dev/null; then
    inj_bad "10. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    got="$(run_wf "$TREE/ops-scripts/mutant-empty-nonce.sh" "$(printf '%s\n%s' "[$FOREIGN101,$FOREIGN100]" "[$FOREIGN103,$OUR102_OK,$FOREIGN101,$FOREIGN100]")" "$VIEW_OK")"
    if printf '%s' "$got" | grep -qF 'run finished' \
    && ! printf '%s' "$got" | grep -qF 'actions/runs/102'; then
        inj_ok "10a. 空 nonce 命中每一筆、認領了別人的（非 102；got [$(printf '%s' "$got" | head -c 150)]）——2a 會紅"
    else
        inj_bad "10a. 空 nonce 後 2a 仍綠或認領對了（got [$got]）"
    fi
    got="$(run_wf "$TREE/ops-scripts/mutant-empty-nonce.sh" "$(printf '%s\n%s' "[$FOREIGN104,$FOREIGN103]" "[$FOREIGN104,$FOREIGN103,$OUR102_OK,$FOREIGN101,$FOREIGN100]")" "$VIEW_OK")"
    if printf '%s' "$got" | grep -qF 'run finished' \
    && ! printf '%s' "$got" | grep -qF 'actions/runs/102'; then
        inj_ok "10b. 空 nonce 後認領了別人的（非 102；got [$(printf '%s' "$got" | head -c 150)]）——3b 會紅"
    else
        inj_bad "10b. 空 nonce 後 3b 仍綠或認領對了（got [$got]）"
    fi
fi
# 11（空 nonce 護欄的注入）：把「dispatch 前的 nonce 檢查」拿掉，再讓
#    refresh_new_nonce 回空 → **12a 必須紅**。這是 review 實測的假綠重演：
#    沒有護欄時，空 nonce 會被拿去 dispatch，退路 `contains("")` 命中每一筆，
#    認領別人的 run 並回 0。needle 是護欄的 if 條件整行。
python3 - "$REPO_ROOT/$MLP" "$TREE/ops-scripts/mutant-no-guard.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = """    if [[ -z "$nonce" || ! "$nonce" =~ ^[0-9a-f-]+$ || "${#nonce}" -lt 12 ]]; then"""
assert src.count(old) == 1, "no-guard needle count != 1: %d" % src.count(old)
# 條件反轉成「永不成立」＝護欄不在，但保留 return 那幾行的語法形狀。
src = src.replace(old, """    if false; then""", 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -ne 0 ]] || ! bash -n "$TREE/ops-scripts/mutant-no-guard.sh" 2>/dev/null; then
    inj_bad "11. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    # 把 mutant 的 refresh_new_nonce 再覆寫成回空（與 12a 同一夾具）。
    NOGUARD_EMPTY="$TREE/ops-scripts/mutant-no-guard-empty.sh"
    { cat "$TREE/ops-scripts/mutant-no-guard.sh"; printf '%s\n' 'refresh_new_nonce() { printf ""; }'; } > "$NOGUARD_EMPTY"
    : > "$SANDBOX/gh-argv.log"
    got="$(run_wf "$NOGUARD_EMPTY" "[$FOREIGN101,$FOREIGN100]" "$VIEW_OK")"
    if [[ "$got" == RC=0* ]] \
    && grep -q '^workflow run' "$SANDBOX/gh-argv.log" 2>/dev/null \
    && printf '%s' "$got" | grep -qF 'run finished'; then
        inj_ok "11. 拿掉護欄＋空 nonce：dispatch 出去了（空 nonce 照送）、認領了別人的 run 並回 ${got%% *}（got [$(printf '%s' "$got" | head -c 150)]）——12a 會紅（重演 review 的假綠）"
    else
        inj_bad "11. 拿掉護欄後 12a 仍綠（got [$got]；argv [$(head -1 "$SANDBOX/gh-argv.log" 2>/dev/null | head -c 120)]）——守衛沒在守這個"
    fi
fi

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' "$pass" "$fail" "$injpass" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
