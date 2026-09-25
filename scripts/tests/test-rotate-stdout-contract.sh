#!/usr/bin/env bash
# test-rotate-stdout-contract.sh — 「stdout 即回傳值」的函式不得把 log 混進去。
#
# 這個 bug 的形狀（比修法重要）：
#   lib/log.sh 的 `log INFO` 走 stdout。一個 stdout 被 `="$(fn ...)"` 捕捉、
#   當成資料（key=value 或 JSON）的函式，只要體內有一行不帶 `>&2` 的
#   `log INFO`，回傳值就被污染——而且它**只在某條從未被走過的分支才印**，
#   所以潛伏很久才在真線炸開：
#     - rotate_create_preview_linode：只在 GATEWAY_ROOT_PASS 有值時
#       （2026-09-25 那天第一次有值）
#     - pool-resolve 的 resolve_node：只在 --refresh 且非 gateway 時
#       （目前沒人這樣呼叫）
#   夾具一定要走到那條分支，否則等於什麼都沒測。
#
# 要釘的：
#   1. 兩函式在觸發分支下的 stdout 必須是純資料（key=value／合法 JSON）。
#   2. workflow 防線：非 key=value 行要 `::error::` 指名它並 exit 1，
#      且 `$GITHUB_OUTPUT` 零寫入——不可靜默丟掉（靜默過濾會讓污染通過，
#      而污染本身才是 bug，Actions 解析錯誤只是症狀）。防線防的不是
#      「會不會壞」，是「壞了看不看得見」。
#   3. workflow 防線以「真 step 端到端」驗證：把真 workflow 的
#      `create_preview` step 用 YAML parser 抽出、代換 inputs、在沙箱 repo
#      裡真跑——污染版讓它 exit 1 並指名那行，乾淨版正常寫入。
#
# 關於「這一類要不要變常設 preflight 檢查」的評估（見報告）：
#   判準是「函式被捕捉且有不帶 >&2 的 log INFO」。impl 的掃描器抓得到
#   本次兩個真地雷，但也會抓到 rotate_wait_for_cloud_init——它刻意不帶
#   >&2，呼叫端 `| tee | tail -1` 只取最後一行，是**合法的例外**。
#   要變常設就得維護排除清單，而這個 repo 對排除清單的立場是「No exclusion
#   list, ever」（preflight 註解）；加上 capture-site 判準跨 YAML/內嵌
#   bash 是啟發式的（漏抓會給假安心）。結論：不常設，改以這支行為測試
#   逐實例釘住（見報告〈preflight 評估〉）。
#
# 全離線。gh／linode-cli／python3 以 stub 或真工具替代；真 workflow step
# 抽取照 test-create-worker-build.sh 的手法（YAML parser，非 grep）。
# bash 3.2 相容（測試本體不用陣列、不用 ${var,,}、無 mapfile）。
#
# Run: scripts/tests/test-rotate-stdout-contract.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

ROTATE="scripts/rotate-gateway.sh"
POOL_RESOLVE="shared-configs/pool-runtime/files/pool-resolve"
WORKFLOW=".github/workflows/rotate-gateway.yml"

for f in "$ROTATE" "$POOL_RESOLVE" "$WORKFLOW"; do
    if [[ ! -f "$f" ]]; then
        echo "test-rotate-stdout-contract: ${f} is missing; dependent cases will FAIL" >&2
    fi
done
for tool in jq python3 envsubst; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found on PATH" >&2; exit 1; }
done
PYEXE="$(python3 -c 'import sys; print(sys.executable)')"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-rotate-stdout.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
REPO="$SANDBOX/repo"
mkdir -p "$SHIMS" "$HOME_DIR/.mylinuxpool" "$REPO/scripts/lib" \
         "$REPO/profiles/gateway/default" "$REPO/shared-configs/pool-runtime/files"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- 沙箱 repo：真檔＋真 lib，讓 SCRIPT_DIR 的相對 source 成立 ----------------
cp -p "$REPO_ROOT/$ROTATE" "$REPO/scripts/rotate-gateway.sh"
cp -p "$REPO_ROOT/scripts/refresh-authkeys.sh" "$REPO/scripts/refresh-authkeys.sh"
cp -p "$REPO_ROOT/scripts/lib/."*.sh "$REPO/scripts/lib/" 2>/dev/null || cp -p "$REPO_ROOT/scripts/lib/"*.sh "$REPO/scripts/lib/"
cp -p "$REPO_ROOT/profiles/gateway/default/cloud-config.yaml" "$REPO/profiles/gateway/default/cloud-config.yaml"
cp -p "$REPO_ROOT/shared-configs/pool-runtime/files/tunnel-identity.sh" "$REPO/shared-configs/pool-runtime/files/tunnel-identity.sh"

# ---- stubs --------------------------------------------------------------------
cat > "$SHIMS/linode-cli" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' '[{"id": 4242, "ipv4": ["203.0.113.7"]}]'
FAKE
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
# `gh api repos/<r>/actions/variables/<NAME> --jq .value` → that variable's
# raw value out of VARS_JSON; the list endpoints keep their fixtures.
for a in "$@"; do
  case "$a" in
    */actions/variables/*)
      var="${a##*/actions/variables/}"
      printf '%s' "${VARS_JSON:-}" | jq -r --arg n "$var" '.variables[] | select(.name == $n) | .value // empty'
      exit 0 ;;
  esac
done
case "$*" in
  *"variables?per_page"*)     printf '%s' "${VARS_JSON:-}" ;;
  *"variables/POOL_WORKERS"*) printf '%s' "${WORKERS_JSON:-[]}" ;;
esac
exit 0
FAKE
# python3 用真執行檔（workflow step 用它驗 YAML）；不經 asdf shim 以免
# PATH 受限時找不到。
printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$PYEXE" > "$SHIMS/python3"
cat > "$SHIMS/sudo" <<'FAKE'
#!/usr/bin/env bash
exec "$@"
FAKE
chmod +x "$SHIMS/linode-cli" "$SHIMS/gh" "$SHIMS/python3" "$SHIMS/sudo"

# ---- fixtures -----------------------------------------------------------------
# GATEWAY_ROOT_PASS 有值 = rotate 的分支 under test（沒值時 sibling WARN 本就走 stderr）。
GATEWAY_ROOT_PASS="fixture-root-pass"
# vars：CLIENT_ACTIONS（login 需要）＋ NODE_FH_L（sshproxy 需要）。
cat > "$SANDBOX/vars.json" <<'JSON'
{"total_count":3,"variables":[
 {"name":"CLIENT_ACTIONS","value":"{\"name\":\"actions\",\"public_key\":\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIACT actions\"}"},
 {"name":"NODE_FH_L","value":"{\"role\":\"provider\",\"tunnel_public_key\":\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPROV fh-l\"}"},
 {"name":"NODE_FH_PROXY","value":"{\"name\":\"fh-proxy\",\"ip\":\"10.0.0.5\",\"user\":\"u\",\"port\":2100}"}
]}
JSON
VARS_JSON="$(cat "$SANDBOX/vars.json")"

echo "=== 0. 先決條件 ==="
missing=0
for fn in rotate_create_preview_linode resolve_node; do
    if grep -q "^${fn}() {" "$ROTATE" || grep -q "^${fn}() {" "$POOL_RESOLVE"; then
        :
    else
        bad "0. ${fn} 不存在——實作還沒落地？"
        missing=1
    fi
done
if python3 - "$WORKFLOW" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ok = any(s.get("id") == "create_preview" and s.get("run")
         for s in doc["jobs"]["rotate"]["steps"])
sys.exit(0 if ok else 1)
PY
then
    ok "0. 兩個函式與 workflow create_preview step 都在"
else
    bad "0. workflow create_preview step 不存在——防線斷言無從驗起"
fi

echo "=== 1. rotate_create_preview_linode：分支 under test 下 stdout 純 key=value ==="
# fixture：GATEWAY_ROOT_PASS 有值（正是 2026-09-25 第一次走到的分支）。
preview_run() {
    local mlp_rotate="$1" label="$2" out err
    out="$SANDBOX/pv.out"; err="$SANDBOX/pv.err"; : > "$out"; : > "$err"
    ROT="$mlp_rotate" GATEWAY_ROOT_PASS="$GATEWAY_ROOT_PASS" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
    bash -c '
        source "$ROT" >/dev/null 2>&1
        rotate_create_preview_linode us-east g6-standard-1 linode/ubuntu24.04 /dev/null >"'"$out"'" 2>"'"$err"'"
    ' 2>/dev/null
    echo "RC=$? OUT=[$(tr '\n' '|' < "$out")] ERR=[$(tr '\n' '|' < "$err")]"
}
got="$(preview_run "$REPO/$ROTATE" fixed)"
if [[ "$got" == "RC=0"* ]] \
&& printf '%s' "$got" | grep -qF 'OUT=[preview_id=4242|preview_ip=203.0.113.7|]' \
&& printf '%s' "$got" | grep -qF 'INFO using the caller-supplied root password'; then
    ok "1a. stdout 只有 key=value；那行 INFO 在 stderr（分支確實走到）"
else
    bad "1a. 回傳值被污染或分支沒走到（got [$got]）"
fi
# 1b：逐行檢查更嚴謹——stdout 每一行都必須符合 key=value。
sanitize_out="$(sed -n 's/.*OUT=\[\(.*\)\] ERR=.*/\1/p' <<< "$got" | tr '|' '\n')"
badline=0
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^=]*$ ]] || badline=1
done <<< "$sanitize_out"
if [[ "$badline" -eq 0 ]]; then
    ok "1b. 逐行皆 key=value（沒有任何 log／空行混入）"
else
    bad "1b. stdout 有非 key=value 行（out [$(printf '%s' "$sanitize_out" | tr '\n' '|')]）"
fi

echo "=== 2. resolve_node --refresh 非 gateway：stdout 純 JSON ==="
# fixture：state.json 有 fh-proxy（非 gateway）→ --refresh 走那條 log INFO 分支。
cat > "$HOME_DIR/.mylinuxpool/state.json" <<'JSON'
{"schema":1,"serial":"7","nodes":{"fh-proxy":{"name":"fh-proxy","ip":"10.0.0.5","user":"u","port":2100}},"workers":[]}
JSON
# pool-resolve 有 CLI 尾巴，source 前先剝掉（照 test-pool-resolve-state.sh 的手法）。
python3 - "$REPO_ROOT/$POOL_RESOLVE" "$SANDBOX/pr-lib.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
assert src.rstrip().endswith('main "$@"'), "CLI tail shape changed"
open(sys.argv[2], "w", encoding="utf-8").write(src[:src.rindex('main "$@"')])
PY
resolve_run() {
    local lib="$1" out err
    out="$SANDBOX/rs.out"; err="$SANDBOX/rs.err"; : > "$out"; : > "$err"
    LIB="$lib" VARS_JSON="$VARS_JSON" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" bash -c '
        source "$LIB" >/dev/null 2>&1
        resolve_node fh-proxy 1 >"'"$out"'" 2>"'"$err"'"
    ' 2>/dev/null
    echo "RC=$? JSONOK=$(jq -e . >/dev/null 2>&1 < "$out" && echo 1 || echo 0) OUT=[$(tr '\n' '|' < "$out")] ERR=[$(tr '\n' '|' < "$err")]"
}
got="$(resolve_run "$SANDBOX/pr-lib.sh")"
if [[ "$got" == "RC=0 JSONOK=1"* ]] \
&& printf '%s' "$got" | grep -qF 'INFO pool-resolve: fh-proxy: serving from state.json' >/dev/null; then
    ok "2a. stdout 是合法 JSON；那行 INFO 在 stderr（--refresh＋state.json 命中）"
else
    bad "2a. 回傳值被污染或分支沒走到（got [$got]）"
fi
# 2b：fall-through 分支（state.json 有檔案但沒有那個節點）。
cat > "$HOME_DIR/.mylinuxpool/state.json" <<'JSON'
{"schema":1,"serial":"7","nodes":{"other":{"name":"other","ip":"10.0.0.9","user":"u","port":2200}},"workers":[]}
JSON
got="$(resolve_run "$SANDBOX/pr-lib.sh")"
if [[ "$got" == "RC=0 JSONOK=1"* ]] \
&& printf '%s' "$got" | grep -qF 'state.json present but node not in it'; then
    ok "2b. fall-through 分支：stdout 仍是合法 JSON（INFO 在 stderr）"
else
    bad "2b. fall-through 分支污染了回傳值（got [$got]）"
fi
# 還原 fixture 供後續使用
cat > "$HOME_DIR/.mylinuxpool/state.json" <<'JSON'
{"schema":1,"serial":"7","nodes":{"fh-proxy":{"name":"fh-proxy","ip":"10.0.0.5","user":"u","port":2100}},"workers":[]}
JSON

echo "=== 3. workflow 防線（真 step 端到端） ==="
# 真 YAML 抽出 create_preview step，代換 inputs，在沙箱 repo 裡真跑。
python3 - "$REPO_ROOT/$WORKFLOW" "$SANDBOX/step.sh" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for s in doc["jobs"]["rotate"]["steps"]:
    if s.get("id") == "create_preview":
        run = s["run"]
        for expr, val in (("${{ inputs.region }}", "us-east"),
                          ("${{ inputs.type }}", "g6-standard-1"),
                          ("${{ inputs.image }}", "linode/ubuntu24.04")):
            run = run.replace(expr, val)
        open(sys.argv[2], "w", encoding="utf-8").write(run)
        break
else:
    sys.exit("create_preview step not found")
PY
if [[ ! -s "$SANDBOX/step.sh" ]]; then
    bad "3. 抽不到 create_preview step——harness 問題"
else
    # step_run <repo-dir> <step-file> <gateway-root-pass>：
    # 印 rc、$GITHUB_OUTPUT 內容、stderr 的 ::error:: 行。
    step_run() {
        local repo_dir="$1" step="$2" grp="$3" gho="$SANDBOX/gho.txt"
        : > "$gho"
        ( cd "$repo_dir" && GATEWAY_ROOT_PASS="$grp" GH_REPO=testowner/testrepo \
            VARS_JSON="$VARS_JSON" WORKERS_JSON='[]' RUNNER_TEMP="$SANDBOX" \
            GITHUB_OUTPUT="$gho" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
            bash "$step" ) >"$SANDBOX/step.out" 2>"$SANDBOX/step.err"
        printf 'RC=%s GHO=[%s] OUT=[%s] ERR=[%s]' "$?" "$(tr '\n' '|' < "$gho")" \
            "$(tr '\n' '|' < "$SANDBOX/step.out")" "$(tr '\n' '|' < "$SANDBOX/step.err")"
    }
    # 3a. 乾淨版（真 rotate，含 >&2）：rc 0、兩行寫進 $GITHUB_OUTPUT。
    got="$(step_run "$REPO" "$SANDBOX/step.sh" "$GATEWAY_ROOT_PASS")"
    if [[ "$got" == "RC=0 GHO=[preview_id=4242|preview_ip=203.0.113.7|]"* ]] \
    && ! printf '%s' "$got" | grep -qF '::error::'; then
        ok "3a. 乾淨版：rc 0、KEY=value 寫入、無 ::error::（含分支已走到）"
    else
        bad "3a. 乾淨版不對（got [$got]）"
    fi
    # 3b. 污染版（沙箱 rotate 拿掉 >&2）→ 真 step 必須 fail loudly、
    #     指名那一行、且 $GITHUB_OUTPUT 零寫入。這同時驗證了
    #     「函式真的會污染」與「防線真的抓得到」。
    python3 - "$REPO/scripts/rotate-gateway.sh" "$REPO/scripts/rotate-polluted.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'log INFO "using the caller-supplied root password (LISH rescue stays valid)" >&2'
assert src.count(old) == 1, "rotate >&2 needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, old.replace(" >&2", ""), 1))
PY
    if [[ $? -ne 0 ]] || ! bash -n "$REPO/scripts/rotate-polluted.sh" 2>/dev/null; then
        inj_bad "3. 污染版注入失敗（needle 落空或語法錯）——harness 問題"
    else
        # 沙箱 repo 的 rotate-gateway.sh 換成污染版（step source 的就是它）。
        cp -p "$REPO/scripts/rotate-gateway.sh" "$SANDBOX/rotate-clean-keep"
        cp -p "$REPO/scripts/rotate-polluted.sh" "$REPO/scripts/rotate-gateway.sh"
        got="$(step_run "$REPO" "$SANDBOX/step.sh" "$GATEWAY_ROOT_PASS")"
        cp -p "$SANDBOX/rotate-clean-keep" "$REPO/scripts/rotate-gateway.sh"
        if [[ "$got" == "RC=0 GHO=[preview_id=4242|preview_ip=203.0.113.7|]"* ]]; then
            inj_bad "3. 污染版竟一路成功——防線沒被量到（got [$got]）"
        else
            if [[ "$got" == "RC=1 GHO=[]"* ]] \
            && printf '%s' "$got" | grep -qF 'wrote a non-KEY=value line to stdout' \
            && printf '%s' "$got" | grep -qF 'INFO using the caller-supplied root password'; then
                inj_ok "3. 污染版：真 step rc 1、\$GITHUB_OUTPUT 零寫入、::error:: 指名污染行"
            else
                inj_bad "3. 污染版行為不對（got [$got]）——harness 問題"
            fi
        fi
    fi
fi

echo "=== 4-6. 注入：拿掉修正，斷言必須轉紅 ==="
# 4. 把 rotate 那行的 >&2 拿掉 → §1 轉紅（直接函式層）。
python3 - "$REPO_ROOT/$ROTATE" "$REPO/scripts/rotate-inj1.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'log INFO "using the caller-supplied root password (LISH rescue stays valid)" >&2'
assert src.count(old) == 1, "rotate >&2 needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, old.replace(" >&2", ""), 1))
PY
if [[ $? -ne 0 ]] || ! bash -n "$REPO/scripts/rotate-inj1.sh" 2>/dev/null; then
    inj_bad "4. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    got="$(preview_run "$REPO/scripts/rotate-inj1.sh" inj1)"
    if [[ "$got" == "RC=0 OUT=[preview_id=4242|preview_ip=203.0.113.7|]"* ]]; then
        inj_bad "4. 拿掉 >&2 後 1 仍綠——污染沒被量到（got [$got]）"
    else
        # 污染指紋：OUT 的第一行是 log 行（[ts] INFO …），不是 key=value。
        if printf '%s' "$got" | grep -qE 'OUT=\[\[2[0-9-]+T[0-9:]+Z\] INFO'; then
            inj_ok "4. 拿掉 >&2 後 INFO 混進 stdout 第一行（got [$got]）——1a/1b 會紅"
        else
            inj_bad "4. 行為變了但不是預期的污染（got [$got]）——harness 問題"
        fi
    fi
fi
# 5. 把 pool-resolve 兩行的 >&2 拿掉 → §2 轉紅（JSON 解析失敗）。
python3 - "$SANDBOX/pr-lib.sh" "$SANDBOX/pr-inj2.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needles = [
    'log INFO "pool-resolve: ${name}: serving from state.json (${STATE_FILE})" >&2',
    'log INFO "pool-resolve: ${name}: state.json present but node not in it — falling through to GitHub" >&2',
]
for old in needles:
    assert src.count(old) == 1, "pool-resolve >&2 needle count != 1: %s" % old[:50]
    src = src.replace(old, old.replace(" >&2", ""), 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/pr-inj2.sh" 2>/dev/null; then
    inj_bad "5. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    got="$(resolve_run "$SANDBOX/pr-inj2.sh")"
    if [[ "$got" == "RC=0 JSONOK=1"* ]]; then
        inj_bad "5. 拿掉 >&2 後 2 仍綠——污染沒被量到（got [$got]）"
    else
        if [[ "$got" == "RC=0 JSONOK=0"* ]]; then
            inj_ok "5. 拿掉 >&2 後 stdout 不再是合法 JSON（got [$got]）——2a/2b 會紅"
        else
            inj_bad "5. 行為變了但不是預期的解析失敗（got [$got]）——harness 問題"
        fi
    fi
fi
# 6. workflow 防線改成靜默過濾 → 污染通過而沒有人知道（§3 轉紅）。
#   突變只動抽出的 step 文字（真 workflow 檔不動）。
python3 - "$SANDBOX/step.sh" "$SANDBOX/step-silent.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = """  else
    echo "::error::rotate_create_preview_linode wrote a non-KEY=value line to stdout (contract: stdout is the return value): ${line}"
    exit 1
  fi
"""
assert src.count(old) == 1, "silent-filter needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, "  fi\n", 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "6. 注入失敗（needle 落空）——harness 問題"
elif [[ ! -s "$SANDBOX/step-silent.sh" ]]; then
    inj_bad "6. 注入產物不存在——harness 問題"
else
    # 用污染版 rotate＋靜默版 step：靜默版會 rc 0 且不報錯地丟掉污染行。
    cp -p "$REPO/scripts/rotate-gateway.sh" "$REPO/scripts/rotate-gateway.sh.keep"
    cp -p "$REPO/scripts/rotate-polluted.sh" "$REPO/scripts/rotate-gateway.sh" 2>/dev/null
    got="$(step_run "$REPO" "$SANDBOX/step-silent.sh" "$GATEWAY_ROOT_PASS")"
    cp -p "$REPO/scripts/rotate-gateway.sh.keep" "$REPO/scripts/rotate-gateway.sh"
    if [[ "$got" == "RC=1"* ]] && printf '%s' "$got" | grep -qF '::error::'; then
        inj_bad "6. 靜默過濾版仍失敗——注入沒生效（got [$got]）"
    else
        if [[ "$got" == "RC=0"* ]] && ! printf '%s' "$got" | grep -qF '::error::'; then
            inj_ok "6. 靜默過濾版 rc 0、無 ::error::、污染被悄悄丟掉（got [$(printf '%s' "$got" | head -c 160)]）——3b 會紅"
        else
            inj_bad "6. 行為變了但不是預期的靜默通過（got [$got]）——harness 問題"
        fi
    fi
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
