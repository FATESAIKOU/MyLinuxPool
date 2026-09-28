#!/usr/bin/env bash
# test-create-worker-capability-gate.sh — create-worker 的 worker-host 能力閘門（D6）。
#
# 在防什麼（真線會咬人的那一種）：
#   現行 create-worker 只驗「role == provider 且名字在 NODE_* 清單」
#   （.github/workflows/create-worker.yml 的 Validate inputs），**完全不看
#   capabilities**——所以「維修承載機不承載 worker」目前只是慣例。有人指名
#   一台沒宣告 worker-host 的機器，流程照樣往下走：先 claim 埠、再 build 映像、
#   跑容器，直到某一步才炸——**那時池側已被寫入**（埠被佔、映像被建、
#   POOL_WORKERS 被寫）。正確行為是在**寫入任何狀態之前**就拒絕。
#
# 設計裁示（openspec/changes/family-repair-host/design.md D6）：閘門放在
#   現有「role == provider 且名字在清單」那一步（Validate inputs），
#   沒有宣告 worker-host 就失敗並說明原因。spec（repair-host/spec.md
#   「不承載 worker 是機制，不是慣例」）要求「在寫入任何狀態之前」。
#
# 要驗的（行為面）：
#   1. 有宣告 worker-host 的 provider → 不被閘門擋（rc 0；對現碼綠）
#   2. 沒宣告（capabilities: {}）→ rc != 0、訊息說出原因（對現碼紅）
#   3. 完全沒有 capabilities 欄位 → rc != 0（「沒宣告」的最嚴格形狀；對現碼紅）
#   4. 被拒時**零狀態寫入**：gh log 沒有 variable set／workflow run；step
#      本文沒有 --claim／docker build；且閘門步驟在 claim 步驟之前（YAML 順序）
#   5. 正對照：把一個真的寫入塞進 step 的副本裡，寫入偵測必須看得見（證明
#      「log 裡沒有寫入」不是因為工具看不到寫入）
#   6. 注入：把閘門短路（step 開頭 exit 0）→ 2 的斷言必須會紅；把閘門步驟
#      移到 claim 之後 → 4 的順序斷言必須會紅
#
# 驅動方式：照 test-create-worker-source.sh 的手法——用真 YAML parser 抽出
#   Validate inputs step 的 run:，複製 scripts/ 讓它自己 source，用假 gh
#   餵 NODE_* variables（值的形狀照真 API：.value 是 JSON 字串），並套用
#   --jq 語意（真 jq），所以不管實作把能力判斷寫在 jq 濾鏡或獨立函式都通。
#
# ---- 這支測試看不到什麼（誠實記在這裡）------------------------------------
# * 只驅動 Validate inputs 這一個 step。後面的 claim／build／POOL_WORKERS
#   寫入步驟**沒有真的執行**——「拒絕時零寫入」是「step 沒做寫入 ＋ YAML 上
#   閘門在 claim 之前」兩個事實的組合，不是「跑完整條流程後池側乾淨」的實測。
# * 真 gh／真 Gateway 的權限與行為不在這裡（假 gh 只做資料流）。
# * design D6 把閘門訂在「Validate inputs」那一步；若 impl 移到別步，本檔
#   會以「找不到 Validate inputs」紅（大聲，不靜默）——要同步改本檔。
# * 注入 6 的「移到 claim 之後」改的是 YAML 副本，不是真檔；它證明順序
#   斷言的反應，不證明真檔被動過。
#
# 全離線：gh 走 PATH stub；不連網、不碰 Gateway；bash 3.2 相容。
# Run: scripts/tests/test-create-worker-capability-gate.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

CW_WF=".github/workflows/create-worker.yml"

if [[ ! -f "$CW_WF" ]]; then
    echo "test-create-worker-capability-gate: ${CW_WF} is missing; every case below will FAIL" >&2
fi
for tool in jq python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: ${tool} not found on PATH" >&2; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: python3 + pyyaml required" >&2; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-cw-caps.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
REPO="$SANDBOX/repo"
mkdir -p "$SHIMS" "$HOME_DIR" "$REPO"

pass=0; fail=0; injpass=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- 沙箱 repo：step 會 source scripts/，相對 cwd 解析得到 -------------------
rsync -a --exclude='.git' --exclude='.github' --exclude='scripts/tests' \
    "$REPO_ROOT/scripts/" "$REPO/scripts/" 2>/dev/null \
    || { mkdir -p "$REPO/scripts"; cp -R "$REPO_ROOT/scripts/." "$REPO/scripts/"; rm -rf "$REPO/scripts/tests"; }
mkdir -p "$REPO/profiles/worker/fixture"
printf '{"name":"fixture","role":"worker","secrets":{}}\n' > "$REPO/profiles/worker/fixture/profile.json"

# ---- 假 gh：api 回 variables（套 --jq）、記帳；寫入類指令也記 -----------------
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
jqf="" prev=""
for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqf="$a"
    prev="$a"
done
_emit() {   # <json>
    if [[ -n "$jqf" ]]; then printf '%s' "$1" | jq -r "$jqf"
    else printf '%s\n' "$1"; fi
}
case "${1:-}" in
  api)
    path=""
    for a in "$@"; do
        case "$a" in *actions/variables*) path="$a" ;; esac
    done
    case "$path" in
      *"/actions/variables")  _emit "${VARS_ENVELOPE:-{\"total_count\":0,\"variables\":[]}}" ;;
      *"/actions/variables/"*) nm="${path##*/}"
                               _emit "$(printf '%s' "${VARS_ENVELOPE:-{\"variables\":[]}}" \
                                   | jq -c --arg n "$nm" '[.variables[] | select(.name == $n)] | first // {}')" ;;
      *) printf '{}' ;;
    esac
    ;;
  "variable set")  cat > "${GH_SET_FILE:-/dev/null}" ;;
  "workflow run")  printf 'WORKFLOW-RUN-CALLED\n' >> "${GH_LOG:-/dev/null}" ;;
esac
exit 0
FAKE
chmod +x "$SHIMS/gh"

# ---- NODE_* variables fixture（.value 是 JSON 字串，照真 API） ----------------
V_FH='{"name":"fh-l","role":"provider","gateway_port":2222,"capabilities":{"worker-host":{"runtime":"docker"}},"hops":[{"via":"gateway"}]}'
V_FAM='{"name":"family-1","role":"provider","gateway_port":2250,"capabilities":{}}'
V_LEG='{"name":"legacy","role":"provider","gateway_port":2251}'
VARS_ENVELOPE="$(jq -n --arg a "$V_FH" --arg b "$V_FAM" --arg c "$V_LEG" \
    '{total_count:3,variables:[{name:"NODE_FH_L",value:$a},{name:"NODE_FAMILY_1",value:$b},{name:"NODE_LEGACY",value:$c}]}')"

# extract_validate_step <workflow> <out>
extract_validate_step() {
    python3 - "$1" "$2" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for job in (doc.get("jobs") or {}).values():
    for s in job.get("steps") or []:
        if s.get("name") == "Validate inputs":
            open(sys.argv[2], "w", encoding="utf-8").write(s.get("run") or "")
            sys.exit(0)
sys.exit("step 'Validate inputs' not found")
PY
}

# run_validate <step-file> <provider>：跑 step，設 RC 與 OUT；gh log 重置。
run_validate() {
    local step="$1" provider="$2"
    : > "$SANDBOX/gh.log"
    : > "$SANDBOX/gh-set.txt"
    OUT="$(cd "$REPO" && env IMAGE_IN=fixture NAME_IN=fixture PROVIDER_IN="$provider" \
        GH_REPO=testowner/testrepo VARS_ENVELOPE="$VARS_ENVELOPE" \
        GH_LOG="$SANDBOX/gh.log" GH_SET_FILE="$SANDBOX/gh-set.txt" \
        PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
        bash "$step" 2>&1)"
    RC=$?
}

# reason_stated <text>：訊息有沒有說出「這台不承載 worker」的原因。
reason_stated() {
    printf '%s' "$1" | grep -qiE 'worker-host|worker_host|不承載|無法承載|does not host|cannot host|not host worker|no worker-host'
}

# no_state_write_calls：gh log 沒有寫入類呼叫。
no_state_write_calls() {
    ! grep -q -e 'variable set' -e 'workflow run' "$SANDBOX/gh.log" 2>/dev/null
}

echo "=== 0. 先決條件 ==="
if extract_validate_step "$CW_WF" "$SANDBOX/validate.sh" 2>"$SANDBOX/e0.err"; then
    ok "0a. 抽得出 Validate inputs step（design D6 指定的位置）"
else
    bad "0a. 抽不出 Validate inputs step（harness 問題或步驟改名）: $(cat "$SANDBOX/e0.err")"
fi
# 正對照：假 gh 真的會被這個 step 呼叫（資料流有通）——用綠色案例量。
if [[ -f "$SANDBOX/validate.sh" ]]; then
    run_validate "$SANDBOX/validate.sh" "fh-l"
    if grep -q 'actions/variables' "$SANDBOX/gh.log" 2>/dev/null; then
        ok "0b. 正對照：假 gh 確實被呼叫到（step 有讀 actions/variables）"
    else
        bad "0b. 正對照失敗：假 gh 沒被呼叫——後面斷言不可信（rc=${RC} out [$(printf '%s' "$OUT" | tr '\n' '|' | head -c 160)]）"
    fi
fi

echo "=== 1. 有宣告 worker-host → 不被擋（回歸保護；對現碼綠） ==="
if [[ -f "$SANDBOX/validate.sh" ]]; then
    run_validate "$SANDBOX/validate.sh" "fh-l"
    if [[ "$RC" -eq 0 ]]; then
        ok "1a. fh-l（worker-host 已宣告）→ rc 0"
    else
        bad "1a. fh-l 被擋了（rc=${RC} out [$(printf '%s' "$OUT" | tr '\n' '|' | head -c 200)]）——不能擋正常 provider"
    fi
    if no_state_write_calls; then
        ok "1b. 綠案例零狀態寫入（這個 step 本來就不該寫）"
    else
        bad "1b. Validate inputs 竟然發了寫入呼叫（log [$(tr '\n' '|' < "$SANDBOX/gh.log" | head -c 200)]）"
    fi
fi

echo "=== 2. capabilities 空 object → 拒絕＋說明原因（對現碼紅） ==="
if [[ -f "$SANDBOX/validate.sh" ]]; then
    run_validate "$SANDBOX/validate.sh" "family-1"
    if [[ "$RC" -ne 0 ]]; then
        ok "2a. family-1（capabilities {}）→ rc ${RC}（非 0）"
    else
        bad "2a. family-1 沒有被擋（rc=0）——沒宣告 worker-host 的機器照樣會被寫入狀態（假綠：先 claim 埠才可能炸）"
    fi
    if reason_stated "$OUT"; then
        ok "2b. 訊息說出原因（不承載 worker／未宣告 worker-host）"
    else
        bad "2b. 有拒絕但沒說原因（out [$(printf '%s' "$OUT" | tr '\n' '|' | head -c 200)]）——操作者會不知道為什麼"
    fi
    if no_state_write_calls; then
        ok "2c. 拒絕時零狀態寫入（gh log 無 variable set／workflow run）"
    else
        bad "2c. 拒絕時仍有寫入呼叫（log [$(tr '\n' '|' < "$SANDBOX/gh.log" | head -c 200)]）——不是『寫入前』拒絕"
    fi
    # 靜態：閘門所在的 step 本文不得含任何寫入動作（claim／build／寫變數）。
    if grep -q -e '--claim' -e 'docker build' -e 'variable set' "$SANDBOX/validate.sh" 2>/dev/null; then
        bad "2d. Validate inputs 的本文含寫入動作（$(grep -h -e '--claim' -e 'docker build' -e 'variable set' "$SANDBOX/validate.sh" | head -n 1 | head -c 80)）——閘門不可以和寫入同一步"
    else
        ok "2d. Validate inputs 本文無 --claim／docker build／variable set"
    fi
fi

echo "=== 3. 完全沒有 capabilities 欄位 → 也要拒絕（對現碼紅） ==="
if [[ -f "$SANDBOX/validate.sh" ]]; then
    run_validate "$SANDBOX/validate.sh" "legacy"
    if [[ "$RC" -ne 0 ]] && reason_stated "$OUT"; then
        ok "3. legacy（無 capabilities 欄位）→ rc ${RC}、訊息說原因"
    else
        bad "3. legacy 未被擋（rc=${RC}）或沒說原因——『沒宣告』的最嚴格形狀要擋"
    fi
fi

echo "=== 4. 順序：閘門步驟必須在 claim 之前（YAML 順序） ==="
cat > "$SANDBOX/order_check.py" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = []
for job in (doc.get("jobs") or {}).values():
    steps.extend(job.get("steps") or [])
g = c = -1
for i, s in enumerate(steps):
    if s.get("name") == "Validate inputs" and g < 0:
        g = i
    sid = s.get("id") or ""
    nm = s.get("name") or ""
    if c < 0 and (sid in ("claim", "claim_cmd") or nm.startswith("Claim a worker port") or nm.startswith("Build claim-port")):
        c = i
if g < 0:
    print("RED: no 'Validate inputs' step"); sys.exit(1)
if c < 0:
    print("RED: no claim/build-claim step found"); sys.exit(1)
if g >= c:
    print("RED: Validate inputs (#%d) is not before claim (#%d)" % (g, c)); sys.exit(1)
print("OK: gate step #%d < claim step #%d" % (g, c)); sys.exit(0)
PY
if [[ -f "$SANDBOX/validate.sh" ]]; then
    if python3 "$SANDBOX/order_check.py" "$CW_WF" > "$SANDBOX/order.out" 2>&1; then
        ok "4. $(cat "$SANDBOX/order.out")"
    else
        bad "4. 順序不成立：$(cat "$SANDBOX/order.out")"
    fi
fi

echo "=== 5. 正對照：寫入偵測看得見寫入（免得 2c 是空綠） ==="
# 把寫入插在 step 的**最前面**（任何檢查與 exit 之前），這樣它必然執行；
# 跑 family-1（會被閘門拒絕也無妨）。若 log 看不到這個寫入，2c 的
# 「零寫入」就只是工具瞎了。
if [[ -f "$SANDBOX/validate.sh" ]]; then
    python3 - "$SANDBOX/validate.sh" "$SANDBOX/validate-write.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
for i, l in enumerate(lines):
    if l.strip():
        lines.insert(i + 1, 'printf %s "[]" | gh variable set POOL_WORKERS --repo "$GH_REPO"')
        break
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
PY
    if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/validate-write.sh" 2>/dev/null; then
        bad "5. 正對照注入腳本失敗——harness 問題"
    else
        run_validate "$SANDBOX/validate-write.sh" "family-1"
        if grep -q 'variable set' "$SANDBOX/gh.log" 2>/dev/null; then
            ok "5. 塞入一個 variable set 後 log 看得見（寫入偵測不是空的）"
        else
            bad "5. 塞入寫入後 log 仍看不到——2c 的『零寫入』不可信"
        fi
    fi
fi

echo "=== 6. 注入 ==="
if [[ -f "$SANDBOX/validate.sh" ]]; then
    # 6a：短路閘門（step 開頭 exit 0）→ case 2 的斷言必須會紅（即：此時 family-1 rc 0）。
    python3 - "$SANDBOX/validate.sh" "$SANDBOX/validate-short.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
# 插在第一個非空行（set -euo pipefail）之後，保證在任何檢查前退出。
for i, l in enumerate(lines):
    if l.strip():
        lines.insert(i + 1, "exit 0")
        break
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
PY
    if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/validate-short.sh" 2>/dev/null; then
        inj_bad "6a. 注入腳本失敗——harness 問題"
    else
        run_validate "$SANDBOX/validate-short.sh" "family-1"
        if [[ "$RC" -eq 0 ]]; then
            inj_ok "6a. 閘門短路後 family-1 rc 0——2a 會紅（got [$(printf '%s' "$OUT" | tr '\n' '|' | head -c 80)]）"
        else
            inj_bad "6a. 短路後仍被擋（rc=${RC}）——注入沒生效或斷言不是靠閘門在擋"
        fi
    fi
    # 6b：把 Validate inputs 移到 claim 之後 → 4 的順序斷言必須會紅。
    python3 - "$CW_WF" "$SANDBOX/wf-moved.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
job = list(doc["jobs"].values())[0]
steps = job["steps"]
gi = ci = None
for i, s in enumerate(steps):
    if s.get("name") == "Validate inputs" and gi is None:
        gi = i
    if ci is None and ((s.get("id") in ("claim", "claim_cmd")) or (s.get("name") or "").startswith("Claim a worker port")):
        ci = i
assert gi is not None and ci is not None, "positions not found"
step = steps.pop(gi)
if gi < ci:
    ci -= 1
steps.insert(ci + 1, step)
open(sys.argv[2], "w", encoding="utf-8").write(yaml.safe_dump(doc, allow_unicode=True))
PY
    if [[ $? -ne 0 ]]; then
        inj_bad "6b. 注入腳本失敗——harness 問題"
    elif python3 "$SANDBOX/order_check.py" "$SANDBOX/wf-moved.yml" >/dev/null 2>&1; then
        inj_bad "6b. 把閘門移到 claim 之後，順序斷言仍綠——它沒在看順序"
    else
        inj_ok "6b. 把閘門移到 claim 之後，順序斷言轉紅（$(python3 "$SANDBOX/order_check.py" "$SANDBOX/wf-moved.yml" 2>&1 | head -c 100)）"
    fi
fi

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' \
    "$pass" "$fail" "$injpass" "$injfail"
[[ "$fail" -ne 0 ]] && exit 1
[[ "$injfail" -ne 0 ]] && exit 2
exit 0
