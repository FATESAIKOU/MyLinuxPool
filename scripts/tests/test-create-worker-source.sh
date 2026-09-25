#!/usr/bin/env bash
# test-create-worker-source.sh — workflow step 必須 source 到它呼叫的函式。
#
# 2026-09-25 真線：`mlp worker new` 死在
#     Record the worker in POOL_WORKERS
#     line 13: create_worker_ledger_add: command not found    exit 127
# 那個 step 只 `source scripts/lib/ledger.sh`，而函式定義在
# `scripts/create-worker.sh`——當天 capabilities 重構換了呼叫的函式名，
# 沒跟著換 source。最貴的代價是**時序**：埠已佔、image 已建、容器已起，
# 才在記錄階段炸掉。
#
# 為什麼 `test-capability-flags.sh` 看不到：它直接 `source scripts/create-worker.sh`
# 再呼叫函式，所以測到的是函式本身，**workflow 的 source 集合未被模擬**。
# 這是今天第三次「測試環境比生產寬容」（前兩次：harness 沒有 -e、
# 舊測試用 sed 過濾 stdout）。
#
# 要釘的：
#   1. 抽出的 "Record the worker in POOL_WORKERS" step，在**它自己寫的
#      source 集合**之下呼叫得到 create_worker_ledger_add——不是「我先
#      source 好再測」。做法：把 step 的 run: 內容代換掉 GitHub 運算式，
#      用乾淨的 bash 執行它自己（source 在裡面）。若只 source ledger.sh，
#      該函式未定義，執行到那行即 127——斷言要求它不發生。
#   2. 同一判準套用到全部 workflow step（行為面，抽真 run: 真跑）。
#      「呼叫我方函式」的清單由 helper 的判準機械決定，不在這裡另寫一份。
#   3. 常設 preflight 檢查（scripts/tests/helpers/wf-fn-sources.py）本身
#      要被釘住：注入「把 source 改回 ledger.sh」→ helper 必須紅。
#   4. 危險排序：列出所有 `if: failure()` / `always()` 的清理步驟，
#      確認它們呼叫的函式**現在**都被自己的 source 定義（今天沒有缺的，
#      但這種步驟缺 source 最危險——出事時救援也壞，平常永遠不會發現）。
#
# 全離線：gh／jq／真實執行都 stub；不連網。
# bash 3.2 相容（測試本體不用陣列、不用 ${var,,}、無 mapfile）。
#
# Run: scripts/tests/test-create-worker-source.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

CW_WF=".github/workflows/create-worker.yml"
HELPER="scripts/tests/helpers/wf-fn-sources.py"
PREFLIGHT="ops-scripts/preflight"

for f in "$CW_WF" "$HELPER" "$PREFLIGHT"; do
    if [[ ! -f "$f" ]]; then
        echo "test-create-worker-source: ${f} is missing; dependent cases will FAIL" >&2
    fi
done
for tool in python3 jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found on PATH" >&2; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: python3 + pyyaml required" >&2; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-cw-source.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
REPO="$SANDBOX/repo"
mkdir -p "$SHIMS" "$HOME_DIR" "$REPO"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- 沙箱 repo：複製會被 source 的樹（scripts/、profiles/…） ------------------
# 用 rsync 保留相對結構，讓 step 裡的 `source scripts/...` 解析得到。
rsync -a --exclude='.git' --exclude='.github' --exclude='scripts/tests' \
    "$REPO_ROOT/scripts/" "$REPO/scripts/" 2>/dev/null \
    || { mkdir -p "$REPO/scripts"; cp -R "$REPO_ROOT/scripts/." "$REPO/scripts/"; rm -rf "$REPO/scripts/tests"; }
mkdir -p "$REPO/profiles/worker/fixture"
printf '{"name":"fixture","role":"worker","secrets":{}}\n' > "$REPO/profiles/worker/fixture/profile.json"

# ---- gh stub：記帳、回罐頭 POOL_WORKERS --------------------------------------
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "$*" in
  *"variables/POOL_WORKERS"*)
    printf '%s' "${POOL_WORKERS_JSON:-[]}" ;;
  *"variable set"*)
    cat > "${GH_SET_FILE:-/dev/null}" ;;
esac
exit 0
FAKE
chmod +x "$SHIMS/gh"

# extract_step <workflow> <step-name> <out-file>：真 YAML parser 抽出 run:。
extract_step() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for job in (doc.get("jobs") or {}).values():
    for s in job.get("steps") or []:
        if s.get("name") == sys.argv[2]:
            open(sys.argv[3], "w", encoding="utf-8").write(s.get("run") or "")
            sys.exit(0)
sys.exit("step %r not found" % sys.argv[2])
PY
}

# run_step <step-file> <tag>：把 GitHub 運算式代換成夾具後，在乾淨的 shell
# 執行 step **自己**（source 在它裡面）——這正是漏掉 127 的原因：不能先
# source 好。${{ ... }} 一律代換成安全值；未代換的殘留會讓語法錯，所以
# 掃一遍確認清空。
run_step() {
    local step="$1" tag="$2"
    python3 - "$step" "$SANDBOX/step-run.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
def sub(m):
    return {
        "steps.port.outputs.port": "2300",
        "inputs.provider": "fh-l",
        "inputs.image": "fixture",
        "inputs.name": "fixture",
        "steps.identity.outputs.container": "mlp-fh-l-fixture-1",
        "steps.identity.outputs.image_tag": "mlp-fh-l-fixture-img",
        "steps.checked_pubkey.outputs.public_key": "ssh-ed25519 AAAAFIXTURE fixture",
        "env.GH_REPO": "testowner/testrepo",
    }.get(m.group(1), "FIXTURE_" + re.sub(r"\W", "_", m.group(1)))
src = re.sub(r"\$\{\{\s*([^}]+?)\s*\}\}", sub, src)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
    : > "$SANDBOX/gh.log"
    ( cd "$REPO" && GH_REPO=testowner/testrepo GH_LOG="$SANDBOX/gh.log" \
        GH_SET_FILE="$SANDBOX/gh-set.txt" POOL_WORKERS_JSON='[]' \
        PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
        bash "$SANDBOX/step-run.sh" ) >"$SANDBOX/$tag.out" 2>"$SANDBOX/$tag.err"
    printf 'RC=%s OUT=[%s] ERR=[%s]' "$?" \
        "$(tr '\n' '|' < "$SANDBOX/$tag.out")" \
        "$(tr '\n' '|' < "$SANDBOX/$tag.err")"
}

echo "=== 0. 先決條件 ==="
if python3 - "$CW_WF" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ok = any(s.get("name") == "Record the worker in POOL_WORKERS"
         for job in (doc.get("jobs") or {}).values()
         for s in job.get("steps") or [])
sys.exit(0 if ok else 1)
PY
then
    ok "0. 目標 step 存在（Record the worker in POOL_WORKERS）"
else
    bad "0. 找不到目標 step——實作改名了？本檔要同步"
fi

echo "=== 1. Record step 在自己的 source 集合下跑得過（127 的回歸） ==="
if ! extract_step "$CW_WF" "Record the worker in POOL_WORKERS" "$SANDBOX/record.sh" 2>"$SANDBOX/e1.err"; then
    bad "1. 抽不出 step（harness 問題）: $(cat "$SANDBOX/e1.err")"
else
    got="$(run_step "$SANDBOX/record.sh" record)"
    if [[ "$got" == "RC=0"* ]] \
    && ! printf '%s' "$got" | grep -qF 'command not found' \
    && ! printf '%s' "$got" | grep -qF 'not defined'; then
        ok "1a. Record step：rc 0、無 command not found（自己 source 得到函式）"
    else
        bad "1a. Record step 失敗——source 集合不足（got [$got]）"
    fi
    # 1b：它真的寫出了 POOL_WORKERS（不是「沒跑到函式所以 rc 0」）。
    if [[ -s "$SANDBOX/gh-set.txt" ]] \
    && jq -e 'type == "array" and .[0].port == 2300' "$SANDBOX/gh-set.txt" >/dev/null 2>&1; then
        ok "1b. Record step 真的把條目寫進 POOL_WORKERS（函式被執行）"
    else
        bad "1b. POOL_WORKERS 沒被寫出（got [$(cat "$SANDBOX/gh-set.txt" 2>/dev/null | head -c 160)]）"
    fi
fi

echo "=== 2. 所有 workflow step：呼叫的我方函式都能被自己的 source 定義 ==="
# 用 helper 的判準（機械事實）跑當前樹。行為面由 §1 與 §4 補。
helper_out="$(python3 "$HELPER" "$REPO_ROOT" 2>&1)"
helper_rc=$?
if [[ "$helper_rc" -eq 0 ]]; then
    ok "2a. 全 workflow 掃描：零 finding"
else
    bad "2a. 有 step 呼叫了它 source 不到的函式:"$'\n'"$helper_out"
fi
# 2b：確認 helper 真的在做事（不是永遠回 0）：對一個突變的 workflow 紅。
mkdir -p "$SANDBOX/wfdir/.github/workflows"
python3 - "$REPO_ROOT" "$SANDBOX/wfdir" <<'PY'
import glob, os, shutil, sys
root, dst = sys.argv[1], sys.argv[2]
shutil.copytree(os.path.join(root, ".github"), os.path.join(dst, ".github"), dirs_exist_ok=True)
for d in ("scripts", "ops-scripts", "shared-configs"):
    shutil.copytree(os.path.join(root, d), os.path.join(dst, d), dirs_exist_ok=True)
shutil.rmtree(os.path.join(dst, "scripts", "tests"), ignore_errors=True)
PY
python3 - "$SANDBOX/wfdir/$CW_WF" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
a = src.index('- name: Record the worker in POOL_WORKERS')
b = src.index('- name:', a + 10)
block = src[a:b]
old = 'source scripts/create-worker.sh'
assert block.count(old) == 1, "source needle count != 1: %d" % block.count(old)
open(p, "w", encoding="utf-8").write(src[:a] + block.replace(old, 'source scripts/lib/ledger.sh', 1) + src[b:])
PY
if [[ $? -ne 0 ]]; then
    inj_bad "2b. 注入腳本失敗（needle 落空）——harness 問題"
else
    inj_out="$(python3 "$HELPER" "$SANDBOX/wfdir" 2>&1)"
    inj_rc=$?
    if [[ "$inj_rc" -eq 1 ]] && printf '%s' "$inj_out" | grep -qF 'create_worker_ledger_add()'; then
        inj_ok "2b. 把 source 改回 ledger.sh → helper 紅並指名函式（got [$(printf '%s' "$inj_out" | head -c 160)]）"
    else
        inj_bad "2b. helper 對注入沒反應（rc=$inj_rc out [$(printf '%s' "$inj_out" | head -c 160)]）——判準沒在看這個"
    fi
fi

echo "=== 3. 注入：Record step 自己退回只 source ledger.sh → §1 應紅（127） ==="
# 直接在沙箱 repo 的 step 副本上退 source，跑同一個 run_step。
if ! extract_step "$CW_WF" "Record the worker in POOL_WORKERS" "$SANDBOX/record.sh" 2>/dev/null; then
    inj_bad "3. 抽不出 step——harness 問題"
else
    python3 - "$SANDBOX/record.sh" "$SANDBOX/record-inj.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'source scripts/create-worker.sh'
assert src.count(old) == 1, "needle count != 1: %d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, 'source scripts/lib/ledger.sh', 1))
PY
    if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/record-inj.sh" 2>/dev/null; then
        inj_bad "3. 注入腳本失敗（needle 落空或語法錯）——harness 問題"
    else
        got="$(run_step "$SANDBOX/record-inj.sh" record-inj)"
        if [[ "$got" == "RC=0"* ]] && ! printf '%s' "$got" | grep -qF 'command not found'; then
            inj_bad "3. 退回 ledger.sh 後 §1 仍綠——它沒在模擬 step 自己的 source 集合（got [$got]）"
        else
            if printf '%s' "$got" | grep -qF 'create_worker_ledger_add: command not found'; then
                inj_ok "3. 退回 ledger.sh 後 127：create_worker_ledger_add: command not found（got [$(printf '%s' "$got" | head -c 170)]）——1a 會紅"
            else
                inj_bad "3. 失敗了但不是預期的 127（got [$got]）——harness 問題"
            fi
        fi
    fi
fi

echo "=== 4. 危險排序：failure()/always() 清理步驟的函式是否可達 ==="
# 這種步驟最危險：出事時救援也壞，平常永遠不會發現。今天沒有缺的，
# 但要以行為面確認——抽每個這類 step，在它自己的 source 下解析函式是否存在。
python3 - "$REPO_ROOT" "$SANDBOX/risky.txt" <<'PY'
import glob, os, re, sys, yaml
root, out = sys.argv[1], sys.argv[2]
DEF = re.compile(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', re.M)
SRC = re.compile(r'^\s*(?:source|\.)\s+([^\s#;]+)', re.M)
CMD = re.compile(r'(?:^|[;&|(]|\$\(|`)\s*([a-z_][a-z0-9_]*)\b', re.M)
KW = re.compile(r'^\s*(?:then|do|else)\s+([a-z_][a-z0-9_]*)\b', re.M)
def defs():
    d = {}
    for p in (glob.glob(os.path.join(root, "scripts/*.sh")) +
              glob.glob(os.path.join(root, "scripts/lib/*.sh")) +
              glob.glob(os.path.join(root, "ops-scripts/*")) +
              glob.glob(os.path.join(root, "shared-configs/*/files/*"))):
        if "/tests/" in p:
            continue
        try:
            t = open(p, encoding="utf-8").read()
        except OSError:
            continue
        for m in DEF.finditer(t):
            d.setdefault(m.group(1), set()).add(os.path.normpath(os.path.relpath(p, root)))
    return d
D = defs()
def reach(path, seen=None):
    seen = seen if seen is not None else set()
    n = os.path.normpath(path)
    if n in seen:
        return set()
    seen.add(n)
    full = os.path.join(root, n)
    if not os.path.exists(full):
        return {n}
    s = {n}
    for m in SRC.finditer(open(full, encoding="utf-8").read()):
        t = m.group(1).strip('"\'')
        if "$" in t or "`" in t:
            continue
        s |= reach(os.path.normpath(os.path.join(os.path.dirname(n), t)), seen)
    return s
lines = []
for wf in sorted(glob.glob(os.path.join(root, ".github/workflows/*.yml"))):
    doc = yaml.safe_load(open(wf, encoding="utf-8"))
    for jn, job in (doc.get("jobs") or {}).items():
        for st in job.get("steps") or []:
            cond = st.get("if") or ""
            if "failure()" not in cond and "always()" not in cond:
                continue
            run = st.get("run") or ""
            if not run:
                continue
            avail = set()
            for m in SRC.finditer(run):
                t = m.group(1).strip('"\'')
                if "$" in t or "`" in t:
                    continue
                for f in reach(t):
                    for fn, where in D.items():
                        if f in where:
                            avail.add(fn)
            called = sorted((set(CMD.findall(run)) | set(KW.findall(run))) & set(D))
            missing = [c for c in called if c not in avail]
            lines.append("%s | %s | if: %s | calls: %s | missing: %s" % (
                os.path.basename(wf), st.get("name"), cond[:40],
                ",".join(called) or "-", ",".join(missing) or "-"))
open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
if [[ ! -s "$SANDBOX/risky.txt" ]]; then
    bad "4. 找不到任何 failure()/always() 清理步驟——判準壞了"
else
    risky_missing="$(grep -v 'missing: -$' "$SANDBOX/risky.txt" || true)"
    if [[ -z "$risky_missing" ]]; then
        ok "4a. 所有 failure()/always() 步驟呼叫的函式都可達（$(grep -c . "$SANDBOX/risky.txt") 個步驟）"
    else
        bad "4a. 有救援步驟缺 source（最危險的一類）:"$'\n'"$risky_missing"
    fi
    # 4c（注入）：把 create-worker 的失敗回滾步驟 source 拿掉 →
    #     §4 的危險清單必須紅。這條是「出事時救援也壞、平常不會發現」
    #     那一類的守衛證明。
    cp -p "$REPO_ROOT/$CW_WF" "$SANDBOX/wfdir/$CW_WF"
    python3 - "$SANDBOX/wfdir/$CW_WF" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
a = src.index('- name: On failure, remove the entry from POOL_WORKERS')
# 這是 job 的最後一個 step——找不到下一個 `- name:` 時取到檔尾。
try:
    b = src.index('- name:', a + 10)
except ValueError:
    b = len(src)
block = src[a:b]
old = 'source scripts/lib/ledger.sh'
assert block.count(old) == 1, "needle count != 1: %d" % block.count(old)
open(p, "w", encoding="utf-8").write(src[:a] + block.replace(old, '# source removed (INJECTED)', 1) + src[b:])
PY
    if [[ $? -ne 0 ]]; then
        inj_bad "4c. 注入腳本失敗（needle 落空）——harness 問題"
    else
        inj_out="$(python3 "$HELPER" "$SANDBOX/wfdir" 2>&1)"
        if printf '%s' "$inj_out" | grep -qF 'On failure, remove the entry from POOL_WORKERS' \
        && printf '%s' "$inj_out" | grep -qF 'ledger_remove()'; then
            inj_ok "4c. 失敗回滾步驟缺 source → helper 紅並指名它（got [$(printf '%s' "$inj_out" | grep 'On failure' | head -c 150)]）"
        else
            inj_bad "4c. 失敗路徑缺 source 沒被 helper 抓到（out [$(printf '%s' "$inj_out" | head -c 200)]）——最危險的一類沒護欄"
        fi
    fi
    # 4b：至少涵蓋已知的救援步驟，避免「0 個步驟」也算過。
    if grep -q 'On failure, remove the entry from POOL_WORKERS' "$SANDBOX/risky.txt" \
    && grep -q 'Clean up preview machine' "$SANDBOX/risky.txt"; then
        ok "4b. 涵蓋已知救援步驟（create-worker 失敗回滾、rotate 清理）"
    else
        bad "4b. 救援步驟清單不完整（$(cat "$SANDBOX/risky.txt" | head -c 200)）"
    fi
fi

echo "=== 5. preflight 已接上這條檢查（常設化的證據） ==="
if grep -qF 'wf-fn-sources.py' "$PREFLIGHT"; then
    ok "5a. preflight 呼叫 helper"
else
    bad "5a. preflight 沒接上 wf-fn-sources.py"
fi
# 5b：在私有 git 副本裡真跑 preflight，確認這條檢查真的執行且會紅。
PREPO="$SANDBOX/prepo"
rsync -a --exclude='.git' "$REPO_ROOT/" "$PREPO/" 2>/dev/null
if [[ -d "$PREPO/.github" ]]; then
    rm -rf "$PREPO/.git"
    git -C "$PREPO" init -q 2>/dev/null && git -C "$PREPO" add -A 2>/dev/null
    base_out="$(cd "$PREPO" && bash ops-scripts/preflight 2>&1)"
    python3 - "$PREPO/$CW_WF" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
a = src.index('- name: Record the worker in POOL_WORKERS')
b = src.index('- name:', a + 10)
block = src[a:b]
old = 'source scripts/create-worker.sh'
assert block.count(old) == 1
open(p, "w", encoding="utf-8").write(src[:a] + block.replace(old, 'source scripts/lib/ledger.sh', 1) + src[b:])
PY
    git -C "$PREPO" add -A 2>/dev/null
    inj_out="$(cd "$PREPO" && bash ops-scripts/preflight 2>&1)"
    if printf '%s' "$base_out" | grep -qF 'workflow step 呼叫的函式都被它 source 的東西定義'; then
        ok "5b. 私有副本 baseline：preflight 有跑這條檢查"
    else
        bad "5b. baseline 沒看到這條檢查的 ok 行"
    fi
    if printf '%s' "$inj_out" | grep -qF 'create_worker_ledger_add()' \
    && printf '%s' "$inj_out" | grep -qF 'FAIL'; then
        inj_ok "5c. 副本退回 source 後 preflight 轉紅並指名函式"
    else
        inj_bad "5c. preflight 對注入沒反應——常設化沒有牙"
    fi
else
    bad "5b/5c. 私有副本建立失敗——harness 問題"
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
