#!/usr/bin/env bash
# test-capability-flags.sh — `capabilities` 契約的護欄：每個宣告都要能被證明。
#
# 為什麼要有（2026-09-25 實例，也是設計的現成證據）：
#   fh-proxy-asus 的 capabilities 沒有 wol-sender，但它一整天都是 fh-l 的
#   第一順位代送者、實測叫醒過四次；而 fh-proxy 有那個旗標。一個沒人讀、
#   也沒人驗證的宣告，會安靜地變成假的。所以這套旗標的價值不在格式，
#   在「每個宣告都有辦法被證明是真的」——驗不了的，絕不可回報成真的。
#
# 要釘的事（設計 §7 的前幾條、qa 追加的後幾條、以及遷移）：
#   1. 宣告 worker-host 但 docker 不通 → 註冊失敗（不是成功）。
#   2. 驗證用 docker info 不是 id -nG（群組在、socket 不通時後者照過）。
#   3. value 必須是 object：字串／null／陣列都要被擋，不可放行。
#   4. 不認得的 key 保留不動（merge 不刪；migrate 不刪）。
#   5. create-worker 把 image profile 的 capabilities 複製進 POOL_WORKERS。
#   6. **unverifiable 絕不可退化成 pass**：沒定義驗證的 key（wol-sender、
#      github 的 write/trigger-actions、未知 key、hop 失敗）回報 unverifiable
#      且 exit 3——斷言同時檢查字串與 exit，因為自動化只看 exit。
#      exit 三碼：0 全 ok／1 任一 fail／3 僅 unverifiable；混合時 1（fail
#      優先）。unverifiable 沒有被折成 0。
#   7. **worker profile 宣告 github 要被擋**：禁令是 workflow 裡的實際檢查
#      （Validate profile-declared secrets 步驟），不是文件一句話。
#   8. **畸形 github value 是 fail，不是 unverifiable**：宣告本身壞掉
#      （schema 違反）與「沒定義驗證」是不同的事，且必須零呼叫——
#      「根本沒去驗」與「驗了沒過」不可混。
#   9. **CAP_STATE 初始值必須是 unverifiable**（2026-09-25 qa 根因）：
#      初始值為 pass 時，一條跑 0 圈的迴圈會把「從未檢查」輸出成「true」。
#      靜態釘住兩個 verifier 的初始值——防的是下一條還沒被想到的
#      「沒跑到」路徑（已知形狀都被 schema／顯式分支回答了）。
#   ＋ 遷移冪等：已是 object 的 var 再跑一次是 no-op（不寫入）。
#
# 已知的脆弱處（impl 點名，記錄給下一個取名的人）：
#   `scripts/tests/test-register-provider-tempclone.sh` 用
#   `"verify" in fn` 的子字串比對，把 main 裡第一個名字含 "verify" 的函式
#   當作 tunnel 驗證步驟。所以 register-provider.sh 裡新步驟刻意避開這個字
#   （用 `step7_5_capabilities` 而非 `step7_5_verify_capabilities`）。
#   不要去改那個測試；但改任何 register-provider 的函式名之前先想到它。
#
# 手法：全離線。register-provider.sh 以 `sed '$d'` 剝尾行 `main` 後 source
#   （diff 證只差一行）；gh／docker／pool-resolve 全 PATH stub（記帳）。
#   workflow 的步驟用真 YAML parser 抽出（照 test-create-worker-build.sh），
#   bash 3.2 沒有 mapfile，測試側補一個 shim（workflow 本身宣告 ubuntu）。
#   mlp 的 verify-capabilities 以 source 載入直打函式（bypass check_deps）。
#
# 注入（每條先證明會紅：突變版 bash -n 過＋needle 命中數剛好 1＋實際 got）。
#
# 相容：bash 3.2（測試本體不用陣列、不用 ${var,,}）。
#
# Run: scripts/tests/test-capability-flags.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

RP="ops-scripts/register-provider.sh"
MLP="ops-scripts/mlp"
CW="scripts/create-worker.sh"
LEDGER="scripts/lib/ledger.sh"
PROFILE="scripts/lib/profile.sh"
WORKFLOW=".github/workflows/create-worker.yml"

for f in "$RP" "$MLP" "$CW" "$LEDGER" "$PROFILE" "$WORKFLOW"; do
    if [[ ! -f "$f" ]]; then
        echo "test-capability-flags: ${f} is missing; dependent cases will FAIL" >&2
    fi
done
for tool in jq python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found on PATH" >&2; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: python3 + pyyaml required" >&2; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-capability-flags.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
mkdir -p "$SHIMS" "$HOME_DIR" "$SANDBOX/rp" "$SANDBOX/wf"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- register-provider.sh 載入器 --------------------------------------------
cp -p "$REPO_ROOT/$RP" "$SANDBOX/rp/rp-full.sh"
sed -e '$d' "$SANDBOX/rp/rp-full.sh" > "$SANDBOX/rp/rp.sh"
if diff <(sed -e '$d' "$REPO_ROOT/$RP") "$SANDBOX/rp/rp.sh" >/dev/null 2>&1 \
&& tail -1 "$SANDBOX/rp/rp-full.sh" | grep -qx 'main' \
&& ! tail -1 "$SANDBOX/rp/rp.sh" | grep -qx 'main'; then
    ok "harness. 剝尾 main 的副本與真檔只差一行（載入保真）"
else
    bad "harness. 剝尾 main 失敗——後面的登錄斷言全不可信"
fi

# ---- PATH stubs ---------------------------------------------------------------
# gh：記帳；api 讀 GH_VAR_VALUE（單一 var）、variable set 寫 GH_SET_FILE。
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >> "${GH_LOG:-/dev/null}"
if [[ "${1:-}" == "variable" && "${2:-}" == "set" ]]; then
    cat > "${GH_SET_FILE:-/dev/null}"
    printf 'SET %s\n' "${3:-}" >> "${GH_LOG:-/dev/null}"
    exit 0
fi
if [[ "${1:-}" == "api" ]]; then
    case "$*" in
      *"variables?per_page"*) printf '%s\n' "${GH_VAR_LIST:-NODE_T}"; exit 0 ;;
      *"/actions/variables/NODE_T"*) printf '%s' "${GH_VAR_VALUE:-{\}}"; exit 0 ;;
    esac
fi
exit 0
FAKE
# docker：info 以 DOCKER_RC 為準；其餘回 0。
cat > "$SHIMS/docker" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
    printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock\n' >&2
    exit "${DOCKER_RC:-1}"
fi
exit 0
FAKE
cat > "$SHIMS/id" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == "-nG" ]]; then
    printf '%s\n' "${FAKE_GROUPS:-staff docker everyone}"
    exit 0
fi
exec /usr/bin/id "$@"
FAKE
chmod +x "$SHIMS/gh" "$SHIMS/docker" "$SHIMS/id"

# rp_source <rp-path> <prefix-extra>：source 載入器並跑一段測試片段。
# 片段以 env 傳入 SRC_EXTRA（前導函式覆寫、變數設定）與 SRC_BODY。
rp_run() {
    local rp_path="$1" extra="$2" body="$3"
    RPSRC="$rp_path" SRC_EXTRA="$extra" SRC_BODY="$body" \
    GH_VAR_VALUE="${GH_VAR_VALUE:-}" GH_VAR_LIST="${GH_VAR_LIST:-NODE_T}" \
    GH_SET_FILE="${GH_SET_FILE:-/dev/null}" GH_LOG="${GH_LOG:-/dev/null}" \
    DOCKER_RC="${DOCKER_RC:-0}" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
    bash -c '
        set -- --name t --gateway-port 2323
        GH_POOL_TOKEN=dummy
        source "$RPSRC" >/dev/null 2>&1
        eval "$SRC_EXTRA"
        eval "$SRC_BODY"
    ' 2>&1
}
# rp_step7 <rp-path> <caps-json> <docker-rc> <override-fn>：
# 跑 step7_5_capabilities，印 RC 與輸出。
rp_step7() {
    local rp_path="$1" caps="$2" docker_rc="$3" override="$4" out err rc
    out="$SANDBOX/s7.out"; err="$SANDBOX/s7.err"; : > "$out"; : > "$err"
    GH_VAR_VALUE="{\"capabilities\":${caps}}" \
    GH_VAR_LIST="NODE_T" DOCKER_RC="$docker_rc" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
    bash -c '
        set -- --name t --gateway-port 2323
        GH_POOL_TOKEN=dummy
        source "'"$rp_path"'" >/dev/null 2>&1
        NO_SUDO=1
        '"$override"'
        step7_5_capabilities >"'"$out"'" 2>"'"$err"'"
    ' 2>/dev/null
    rc=$?
    printf 'RC=%s OUT=[%s] ERR=[%s]' "$rc" \
        "$(tr '\n' '|' < "$out")" "$(tr '\n' '|' < "$err")"
}

echo "=== 0. 先決條件 ==="
missing=0
for fn in step5_register_var step7_5_capabilities step7_5_docker_group cap_shape_ok cap_verify_node cap_migrate_value; do
    if grep -qE "^${fn}\\(\\)" "$RP" || grep -qE "^${fn}\\(\\)" "$MLP"; then
        :
    else
        bad "0. ${fn} 不存在——實作還沒落地？"
        missing=1
    fi
done
if [[ "$missing" -eq 0 ]]; then
    ok "0. 登錄端與 mlp 端的函式都在"
fi

echo "=== 1. worker-host：docker info 為準，不通就要註冊失敗 ==="
# 1a：docker info 失敗 → step7_5_capabilities 非 0（註冊鏈因此中止）。
got="$(rp_step7 "$SANDBOX/rp/rp.sh" '{"worker-host":{"runtime":"docker"}}' 1 '')"
if [[ "$got" == RC=1* ]] && printf '%s' "$got" | grep -qF 'cannot talk to the docker daemon'; then
    ok "1a. docker 不通 → 非 0（點名 daemon，與網路問題不同句）"
else
    bad "1a. docker 不通竟回報通過（got [$got]）"
fi
# 1b：docker info 成功 → 0。
got="$(rp_step7 "$SANDBOX/rp/rp.sh" '{"worker-host":{"runtime":"docker"}}' 0 '')"
if [[ "$got" == "RC=0"* ]]; then
    ok "1b. docker 通 → 0"
else
    bad "1b. docker 通竟失敗（got [$got]）"
fi
# 1c：id -nG 對照組（同夾具下群組在）：證明「群組在」不構成證據。
if PATH="$SHIMS:$PATH" FAKE_GROUPS='staff docker everyone' id -nG 2>/dev/null | grep -qw docker; then
    ok "1c. 同夾具 id -nG 照樣說有 docker 群組（謊言成立，真驗證才擋得住）"
else
    bad "1c. 對照組沒成立——夾具無效"
fi
# 1d：runtime 不是 docker → unverifiable 的警告，且不得執行 docker 檢查。
got="$(rp_step7 "$SANDBOX/rp/rp.sh" '{"worker-host":{"runtime":"podman"}}' 1 'step7_5_docker_group() { echo RAN-DOCKER-CHECK; return 0; }')"
if [[ "$got" == "RC=0"* ]] && printf '%s' "$got" | grep -qF 'no verification is defined' \
&& ! printf '%s' "$got" | grep -qF 'RAN-DOCKER-CHECK'; then
    ok "1d. runtime:podman → 說沒定義驗證，不誤跑 docker 檢查"
else
    bad "1d. 未定義的 runtime 被當成 docker（got [$got]）"
fi

echo "=== 2. 格式：value 必須是 object ==="
# 2a–2c（單元）：字串／null／陣列 value 都要被 cap_shape_ok 擋。
shape_val() {
    local label="$1" caps="$2" want="$3" got
    got="$(CAPS="$caps" MLP_FILE="$REPO_ROOT/$MLP" bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        if cap_shape_ok "$CAPS"; then printf OK; else printf REJECT; fi
    ' 2>/dev/null)"
    if [[ "$got" == "$want" ]]; then
        ok "$label → $want"
    else
        bad "$label → got [$got] want [$want]"
    fi
}
shape_val "2a. value 是字串" '{"worker-host":"docker"}' REJECT
shape_val "2b. value 是 null" '{"worker-host":null}' REJECT
shape_val "2c. capabilities 是陣列" '["docker","worker-host"]' REJECT
shape_val "2d. 正常 object（含未知 key）" '{"worker-host":{"runtime":"docker"},"mystery":{"x":1}}' OK
# 2e：profile 的 capabilities 是陣列 → create_worker_ledger_add 拒絕（非 0）。
printf '{"capabilities":["docker","worker-host"]}\n' > "$SANDBOX/prof-array.json"
got="$(bash -c '
    source "'"$REPO_ROOT/$CW"'"
    create_worker_ledger_add "[]" 2301 pn img cn 2026-01-01T00:00:00Z "" "'"$SANDBOX/prof-array.json"'"
' 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s' "$got" | grep -qF 'not an object'; then
    ok "2e. profile 的 capabilities 是陣列 → 拒絕（非 0）"
else
    bad "2e. 舊陣列形狀竟被接受（rc=$rc got [$got]）"
fi

echo "=== 3. 不認得的 key 保留（merge 不刪） ==="
printf '%s' '{"name":"t","power":{"launch":{"via":"s"}},"capabilities":{"worker-host":{"runtime":"docker"},"mystery":{"x":1},"wol-sender":{}}}' > "$SANDBOX/existing.json"
GH_SET_FILE="$SANDBOX/set3.json"; : > "$GH_SET_FILE"
GH_VAR_VALUE="$(cat "$SANDBOX/existing.json")" GH_SET_FILE="$GH_SET_FILE" GH_LOG="$SANDBOX/gh3.log" \
PATH="$SHIMS:$PATH" HOME="$HOME_DIR" RPSRC="$SANDBOX/rp/rp.sh" \
bash -c '
    set -- --name t --gateway-port 2323
    GH_POOL_TOKEN=dummy
    source "$RPSRC" >/dev/null 2>&1
    step5_register_var >/dev/null 2>&1
' 2>/dev/null
if jq -e '.capabilities.mystery == {"x":1}' "$SANDBOX/set3.json" >/dev/null 2>&1 \
&& jq -e '.capabilities["wol-sender"] == {}' "$SANDBOX/set3.json" >/dev/null 2>&1 \
&& jq -e '.capabilities["worker-host"].runtime == "docker"' "$SANDBOX/set3.json" >/dev/null 2>&1 \
&& jq -e '.power.launch.via == "s"' "$SANDBOX/set3.json" >/dev/null 2>&1; then
    ok "3a. step5 merge：未知 key 與其他欄位原樣保留"
else
    bad "3a. merge 把不認得的東西弄丟了（寫出 [$(cat "$SANDBOX/set3.json" 2>/dev/null | head -c 240)]）"
fi
# 3b：migrate 對已是 object（含未知 key）不動它。
mkdir -p "$SANDBOX/migshim"
cat > "$SANDBOX/migshim/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >> "${GH_LOG:-/dev/null}"
if [[ "$*" == *"variable set"* ]]; then cat > /dev/null; printf 'WROTE\n' >> "${GH_LOG:-/dev/null}"; exit 0; fi
if [[ "${1:-}" == "api" ]]; then
    case "$*" in
      *"variables?per_page"*) printf 'NODE_A\n'; exit 0 ;;
      *"/actions/variables/NODE_A"*) printf '%s' "${GH_VAR_VALUE:-{\}}"; exit 0 ;;
    esac
fi
exit 0
FAKE
chmod +x "$SANDBOX/migshim/gh"
mig_run() {
    local caps="$1" args="$2" log="$3"
    : > "$log"
    GH_VAR_VALUE="{\"capabilities\":${caps}}" GH_LOG="$log" PATH="$SANDBOX/migshim:$PATH" HOME="$HOME_DIR" \
    MLP_FILE="$REPO_ROOT/$MLP" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        REPO=testowner/testrepo cmd_migrate_capabilities '"$args"' >"'"$SANDBOX/mo"'" 2>&1
    ' 2>/dev/null
}
mig_run '{"worker-host":{"runtime":"docker"},"mystery":{"x":1}}' --real "$SANDBOX/mig-a.log"
if grep -qF 'already the new shape' "$SANDBOX/mo" 2>/dev/null \
&& [[ "$(grep -c WROTE "$SANDBOX/mig-a.log" 2>/dev/null || true)" == "0" ]]; then
    ok "3b. migrate 冪等：已是 object（含未知 key）→ skipped、零寫入"
else
    bad "3b. 已遷移的 var 又被寫（out [$(tr '\n' '|' < "$SANDBOX/mo" 2>/dev/null)] writes=$(grep -c WROTE "$SANDBOX/mig-a.log" 2>/dev/null || true)）"
fi
# 3c：migrate 舊陣列 → 新形狀（dry run 不寫、--real 才寫）。
mig_run '["docker","worker-host"]' '' "$SANDBOX/mig-b.log"
dry_ok=0
if grep -qF '{"worker-host":{"runtime":"docker"}}' "$SANDBOX/mo" 2>/dev/null \
&& grep -qF 'dry run' "$SANDBOX/mo" 2>/dev/null \
&& [[ "$(grep -c WROTE "$SANDBOX/mig-b.log" 2>/dev/null || true)" == "0" ]]; then
    dry_ok=1
fi
mig_run '["wol-sender","wsl2"]' --real "$SANDBOX/mig-c.log"
real_ok=0
if grep -qF -- '-> {}' "$SANDBOX/mo" 2>/dev/null \
&& [[ "$(grep -c WROTE "$SANDBOX/mig-c.log" 2>/dev/null || true)" == "1" ]]; then
    real_ok=1
fi
if [[ "$dry_ok" -eq 1 && "$real_ok" -eq 1 ]]; then
    ok "3c. migrate：舊陣列 dry 只印、--real 才寫；純標籤陣列遷成空 object"
else
    bad "3c. migrate 行為不對（dry_ok=$dry_ok real_ok=$real_ok out [$(tr '\n' '|' < "$SANDBOX/mo" 2>/dev/null)])"
fi

echo "=== 4. create-worker 複製 capabilities 進 POOL_WORKERS ==="
mkdir -p "$SANDBOX/profiles/worker/withcaps" "$SANDBOX/profiles/worker/nocaps"
printf '{"capabilities":{"worker-host":{"runtime":"docker"},"mystery":{"y":2}}}\n' > "$SANDBOX/profiles/worker/withcaps/profile.json"
printf '{"env":{}}\n' > "$SANDBOX/profiles/worker/nocaps/profile.json"
got="$(bash -c '
    source "'"$REPO_ROOT/$CW"'"
    create_worker_ledger_add "[]" 2301 pn withcaps cn 2026-01-01T00:00:00Z PUB "'"$SANDBOX"'/profiles/worker/withcaps/profile.json"
' 2>&1)"
if printf '%s' "$got" | jq -e '.[0].capabilities["worker-host"].runtime == "docker" and .[0].capabilities.mystery.y == 2' >/dev/null 2>&1; then
    ok "4a. profile 的 capabilities（含未知 key）複製進 ledger 條目"
else
    bad "4a. capabilities 沒被複製（got [$(printf '%s' "$got" | head -c 240)]）"
fi
got="$(bash -c '
    source "'"$REPO_ROOT/$CW"'"
    create_worker_ledger_add "[]" 2302 pn nocaps cn 2026-01-01T00:00:00Z PUB "'"$SANDBOX"'/profiles/worker/nocaps/profile.json"
' 2>&1)"
if printf '%s' "$got" | jq -e '.[0].capabilities == {}' >/dev/null 2>&1; then
    ok "4b. 沒宣告 capabilities 的 profile → 條目帶 {}（object，不是 null）"
else
    bad "4b. 沒宣告時不是空 object（got [$(printf '%s' "$got" | head -c 240)]）"
fi

echo "=== 5. unverifiable 不可退化成 pass；畸形宣告 fail；exit 三碼分流 ==="
mkdir -p "$SANDBOX/vshim"
cat > "$SANDBOX/vshim/pool-resolve" <<'FAKE'
#!/usr/bin/env bash
printf '%s' "${NODE_JSON:-{}}"
exit 0
FAKE
chmod +x "$SANDBOX/vshim/pool-resolve"
# verify_caps <node-json> <run_on_node-override>：印 RC 與 stdout。
verify_caps() {
    local node_json="$1" override="$2" out rc
    out="$SANDBOX/vc.out"; : > "$out"
    NODE_JSON="$node_json" MLP_FILE="$REPO_ROOT/$MLP" SANDBOX="$SANDBOX" \
    override="$override" HOME="$HOME_DIR" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="$SANDBOX/vshim/pool-resolve"
        eval "$override"
        ( cmd_verify_capabilities t >"'"$out"'" 2>&1 ); rc=$?
        printf "%s" "$rc" > "'"$SANDBOX"'/vc.rc"
    ' 2>/dev/null
    rc="$(cat "$SANDBOX/vc.rc" 2>/dev/null)"
    printf 'RC=%s OUT=[%s]' "$rc" "$(tr '\n' '|' < "$out")"
}
# verify_caps2 <mlp-path> <node-json> <override>：同 verify_caps，但可指定
# 突變檔，且把 run_on_node 的每次呼叫記進行數（CALLS=n）。
verify_caps2() {
    local mlp_path="$1" node_json="$2" override="$3" out rc calls
    out="$SANDBOX/vc2.out"; : > "$out"
    NODE_JSON="$node_json" MLP_FILE="$mlp_path" SANDBOX="$SANDBOX"     override="$override" HOME="$HOME_DIR"     bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="$SANDBOX/vshim/pool-resolve"
        eval "$override"
        ( cmd_verify_capabilities t >"'"$out"'" 2>&1 ); rc=$?
        printf "%s" "$rc" > "'"$SANDBOX"'/vc2.rc"
    ' 2>/dev/null
    rc="$(cat "$SANDBOX/vc2.rc" 2>/dev/null)"
    calls="$(wc -l < "$SANDBOX/ro2.log" 2>/dev/null | tr -d ' ')"
    [[ -n "$calls" ]] || calls=0
    printf 'RC=%s CALLS=%s OUT=[%s]' "$rc" "$calls" "$(tr '\n' '|' < "$out")"
}
# 5a：wol-sender（沒定義驗證）→ 字串 unverifiable＋非 0。
got="$(verify_caps '{"name":"t","capabilities":{"wol-sender":{}}}' 'run_on_node() { printf MLP_DOCKER_OK; }')"
if [[ "$got" == "RC=3"* ]] && printf '%s' "$got" | grep -qF 'unverifiable' \
&& ! printf '%s' "$got" | grep -qF 'ok  '; then
    ok "5a. wol-sender → unverifiable 且 exit 3（不是 pass，也沒折成 0）"
else
    bad "5a. 沒定義驗證的 key 被當成 pass（got [$got]）"
fi
# 5b：github 的 write 沒定義驗證 → unverifiable＋非 0。
got="$(verify_caps '{"name":"t","capabilities":{"github":{"repos":{"o/r":["write"]}}}}' 'run_on_node() { printf MLP_GH_OK; }')"
if [[ "$got" == "RC=3"* ]] && printf '%s' "$got" | grep -qF 'unverifiable' \
&& printf '%s' "$got" | grep -qF 'write/trigger-actions'; then
    ok "5b. github write → unverifiable 且 exit 3"
else
    bad "5b. write 被當成有驗證（got [$got]）"
fi
# 5c：未知 key → unverifiable＋非 0。
got="$(verify_caps '{"name":"t","capabilities":{"mystery":{"x":1}}}' 'run_on_node() { :; }')"
if [[ "$got" == "RC=3"* ]] && printf '%s' "$got" | grep -qF 'unverifiable'; then
    ok "5c. 未知 key → unverifiable 且 exit 3"
else
    bad "5c. 未知 key 靜靜通過（got [$got]）"
fi
# 5d：hop 失敗（run_on_node 非 0）→ unverifiable＋非 0（不是 pass、不是 fail）。
got="$(verify_caps '{"name":"t","capabilities":{"worker-host":{"runtime":"docker"}}}' 'run_on_node() { return 1; }')"
if [[ "$got" == "RC=3"* ]] && printf '%s' "$got" | grep -qF 'unverifiable' \
&& printf '%s' "$got" | grep -qF 'hop/ssh failed'; then
    ok "5d. hop 失敗 → unverifiable 且 exit 3"
else
    bad "5d. 連不上卻回報 pass（got [$got]）"
fi
# 5e：正向控制——全 pass 時 exit 0，避免「一律非 0」也算綠。
got="$(verify_caps '{"name":"t","capabilities":{"worker-host":{"runtime":"docker"}}}' 'run_on_node() { printf MLP_DOCKER_OK; }')"
if [[ "$got" == "RC=0"* ]] && printf '%s' "$got" | grep -qF 'ok'; then
    ok "5e. 正向控制：全部驗得過 → exit 0"
else
    bad "5e. 全 pass 竟非 0（got [$got]）——護欄會永遠紅"
fi
# 5f：github read 真的打 API（帳本）。
got="$(verify_caps '{"name":"t","capabilities":{"github":{"repos":{"owner/repo":["read"]}}}}' 'run_on_node() { printf "%s" "$2" >> "'"$SANDBOX"'/gh-cmd.log"; printf MLP_GH_OK; }')"
if [[ "$got" == "RC=0"* ]] && grep -qF 'gh api repos/owner/repo' "$SANDBOX/gh-cmd.log" 2>/dev/null; then
    ok "5f. github read → 真打 gh api repos/owner/repo（不是看 token 檔）"
else
    bad "5f. github read 沒真的打 API（got [$got] log [$(cat "$SANDBOX/gh-cmd.log" 2>/dev/null | head -c 160)]）"
fi
# run_on_node 記帳 stub：每次呼叫記一行，預設回 MLP_GH_OK（模擬連得上）。
RO2_OVERRIDE='ROLOG="$SANDBOX/ro2.log"
run_on_node() { printf "%s\n" "$2" >> "$ROLOG"; printf MLP_GH_OK; }'
# 5g. 五種畸形 github value → fail，且 run_on_node 零呼叫。
#   零呼叫是關鍵證據：證明「根本沒去驗」而非「驗了沒過」。
schema_case() {
    local label="$1" caps="$2" want_state="$3" got
    : > "$SANDBOX/ro2.log"
    got="$(verify_caps2 "$REPO_ROOT/$MLP" "{\"name\":\"t\",\"capabilities\":${caps}}" "$RO_OVERRIDE")"
    if [[ "$got" == "RC=1 CALLS=0"* ]] && printf '%s' "$got" | grep -qF "$want_state"; then
        ok "${label}：fail、零呼叫（${want_state}）"
    else
        bad "${label}：期望 fail＋零呼叫（got [$got]）"
    fi
}
RO_OVERRIDE="$RO2_OVERRIDE"
schema_case "5g. repos 是字串" '{"github":{"repos":"o/r"}}' '.repos must be an object'
schema_case "5h. repos 是陣列（非 object）" '{"github":{"repos":["o/r"]}}' '.repos must be an object'
schema_case "5i. repo 的權限值是字串" '{"github":{"repos":{"o/r":"read"}}}' 'must be an array'
schema_case "5j. 權限字不在 read/write/trigger-actions" '{"github":{"repos":{"o/r":["admin"]}}}' 'read/write/trigger-actions'
schema_case "5k. github 的 value 不是 object" '{"github":"read"}' 'not key:object'
# 5l. exit 三碼分流：0（全 ok）／1（任一 fail）／3（僅 unverifiable）。
#   fail 與 unverifiable 混合時 1（fail 優先）。
#   夾具要真的同時有 fail（畸形的 github）與 unverifiable（wol-sender），
#   否則驗到的是 pass＋unverifiable（那條本來就 3）。
mix_caps='{"github":{"repos":"o/r"},"wol-sender":{}}'
: > "$SANDBOX/ro2.log"
got="$(verify_caps2 "$REPO_ROOT/$MLP" '{"name":"t","capabilities":'"$mix_caps"'}' 'run_on_node() { printf MLP_GH_OK; }')"
if [[ "$got" == "RC=1"* ]] && printf '%s' "$got" | grep -qF 'FAIL' \
&& printf '%s' "$got" | grep -qF 'unverifiable'; then
    ok "5l. fail＋unverifiable 混合 → exit 1（fail 優先，不被 unverifiable 蓋掉）"
else
    bad "5l. 混合碼不對（got [$got]）"
fi
got="$(verify_caps2 "$REPO_ROOT/$MLP" '{"name":"t","capabilities":{"mystery":{"x":1}}}' 'run_on_node() { :; }')"
if [[ "$got" == "RC=3"* ]]; then
    ok "5m. 僅 unverifiable → exit 3（不是 0、也不是 1）"
else
    bad "5m. unverifiable-only 的碼不是 3（got [$got]）"
fi
# 5n. 根因（靜態）：兩個 verifier 的 CAP_STATE 初始值必須是 unverifiable。
#   這道防線擋的不是已知畸形（那些走 schema／顯式分支），而是**任何尚未被
#   想到的「沒跑到」路徑**：初始值是 pass 時，一條跑 0 圈的迴圈會把
#   「從未檢查」輸出成「true」——正是這次 qa 抓到的 bug。
init_bad="$(python3 - "$REPO_ROOT/$MLP" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
bad = []
for fn in ("cap_verify_worker_host", "cap_verify_github"):
    m = re.search(r'^%s\(\) \{.*?^\}' % fn, src, re.M | re.S)
    if not m:
        bad.append("%s missing" % fn)
        continue
    first = re.search(r'CAP_STATE="(\w+)"', m.group(0))
    if not first or first.group(1) != "unverifiable":
        bad.append("%s starts %s" % (fn, first.group(1) if first else "nothing"))
print("; ".join(bad))
PY
)"
if [[ -z "$init_bad" ]]; then
    ok "5n. 兩個 verifier 的 CAP_STATE 初始值都是 unverifiable（根因）"
else
    bad "5n. CAP_STATE 初始值不是 unverifiable：${init_bad}"
fi

echo "=== 6. worker profile 的 github 禁令是實際檢查 ==="
# 從 workflow 用真 YAML parser 抽「Validate profile-declared secrets」步驟，
# 代換 ${{ inputs.image }} 後真的執行；mapfile 是 bash4 內建，測試側補 shim。
python3 - "$WORKFLOW" "$SANDBOX/wf" <<'PY'
import sys, yaml, os
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for s in doc["jobs"]["create"]["steps"]:
    if s.get("name") == "Validate profile-declared secrets exist":
        for image, dst in (("ghprof", "validate-ghprof.sh"), ("cleanprof", "validate-clean.sh")):
            open(os.path.join(sys.argv[2], dst), "w", encoding="utf-8").write(
                s["run"].replace("${{ inputs.image }}", image))
        break
else:
    sys.exit("step 'Validate profile-declared secrets exist' not found")
PY
if [[ $? -ne 0 || ! -s "$SANDBOX/wf/validate-ghprof.sh" ]]; then
    bad "6. 抽不到 workflow 步驟——harness 問題"
else
    printf '{"capabilities":{"worker-host":{"runtime":"docker"},"github":{"repos":{"FATESAIKOU/MyBrain":["read"]}}},"secrets":{}}\n' > "$SANDBOX/profiles/worker/ghprof.profile.json"
    printf '{"capabilities":{"worker-host":{"runtime":"docker"}},"secrets":{}}\n' > "$SANDBOX/profiles/worker/cleanprof.profile.json"
    # 沙箱 repo：workflow 步驟以 repo 相對路徑 source，故照原結構放。
    WFREPO="$SANDBOX/wfrepo"
    mkdir -p "$WFREPO/scripts" "$WFREPO/profiles/worker/ghprof" "$WFREPO/profiles/worker/cleanprof"
    cp -p "$REPO_ROOT/$CW" "$WFREPO/scripts/create-worker.sh"
    cp -R "$REPO_ROOT/scripts/lib" "$WFREPO/scripts/lib"
    cp "$SANDBOX/profiles/worker/ghprof.profile.json" "$WFREPO/profiles/worker/ghprof/profile.json"
    cp "$SANDBOX/profiles/worker/cleanprof.profile.json" "$WFREPO/profiles/worker/cleanprof/profile.json"
    cat > "$SANDBOX/wf/mapfile-shim.sh" <<'SHIM'
mapfile() {
    local opt="$1" name="$2" line
    eval "$name=()"
    while IFS= read -r line; do eval "$name+=(\"\$line\")"; done
}
SHIM
    wf_step() {
        local file="$1"
        ( cd "$WFREPO" && ALL_SECRETS_JSON='{}' bash -c "source '$SANDBOX/wf/mapfile-shim.sh'; source '$file'" ) \
            >"$SANDBOX/wf/out" 2>"$SANDBOX/wf/err"
        echo "$?"
    }
    rc="$(wf_step "$SANDBOX/wf/validate-ghprof.sh")"
    if [[ "$rc" -ne 0 ]] && grep -qF 'violates CAPABILITY-DESIGN.md' "$SANDBOX/wf/out" 2>/dev/null \
    && grep -qF 'declares "github"' "$SANDBOX/wf/err" 2>/dev/null; then
        ok "6a. profile 宣告 github → 該步驟失敗（非 0＋::error)"
    else
        bad "6a. github 禁令沒讓步驟失敗（rc=$rc out [$(tr '\n' '|' < "$SANDBOX/wf/out" 2>/dev/null | head -c 160)]）"
    fi
    rc="$(wf_step "$SANDBOX/wf/validate-clean.sh")"
    if [[ "$rc" -eq 0 ]]; then
        ok "6b. 沒宣告 github 的 profile → 步驟通過（正向控制）"
    else
        bad "6b. 正常 profile 被擋（rc=$rc err [$(tr '\n' '|' < "$SANDBOX/wf/err" 2>/dev/null | head -c 160)]）"
    fi
fi

echo "=== 7-14. 注入：拿掉修正，斷言必須轉紅 ==="
# 共用：把 needle 換成 replacement 寫成沙箱突變檔（保留原檔不動）。
mutate() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = open(sys.argv[2], encoding="utf-8").read()
new = open(sys.argv[3], encoding="utf-8").read()
assert src.count(old) == 1, "needle count != 1: %d" % src.count(old)
open(sys.argv[4], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
}
mktmpf() { printf '%s' "$2" > "$SANDBOX/nd-$1"; }

# 7. 宣告 worker-host 但 docker 不通 → 註冊仍然成功。
mktmpf o7 '                step7_5_docker_group
                ;;
            *)
                log WARN "capability '"'"'${key}'"'"' has no verification defined — not verified (CAPABILITY-DESIGN.md §2)"
'
mktmpf n7 '                log WARN "worker-host: skipping docker verification (INJECTED)"
                ;;
            *)
                log WARN "capability '"'"'${key}'"'"' has no verification defined — not verified (CAPABILITY-DESIGN.md §2)"
'
if ! mutate "$SANDBOX/rp/rp.sh" "$SANDBOX/nd-o7" "$SANDBOX/nd-n7" "$SANDBOX/rp/rp-inj7.sh" 2>"$SANDBOX/i7.err" \
|| ! bash -n "$SANDBOX/rp/rp-inj7.sh" 2>/dev/null; then
    inj_bad "7. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i7.err")"
else
    got="$(rp_step7 "$SANDBOX/rp/rp-inj7.sh" '{"worker-host":{"runtime":"docker"}}' 1 '')"
    if [[ "$got" == "RC=0"* ]]; then
        inj_ok "7. 拿掉 docker 驗證後不通也成功（got [$got]）——1a 會紅"
    else
        inj_bad "7. 拿掉驗證後仍失敗（got [$got]）——注入沒生效"
    fi
fi
# 8. 驗證改成檢查 id -nG → 群組在、socket 不通時通過。
mktmpf o8 '    out="$(run_on_node "$node" "docker info >/dev/null 2>&1 && printf MLP_DOCKER_OK" 2>&1)"
'
mktmpf n8 '    out="$(run_on_node "$node" "id -nG 2>/dev/null | grep -qw docker && printf MLP_DOCKER_OK" 2>&1)"
'
if ! mutate "$REPO_ROOT/$MLP" "$SANDBOX/nd-o8" "$SANDBOX/nd-n8" "$SANDBOX/mlp-inj8.sh" 2>"$SANDBOX/i8.err" \
|| ! bash -n "$SANDBOX/mlp-inj8.sh" 2>/dev/null; then
    inj_bad "8. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i8.err")"
else
    # 夾具：run_on_node 模擬「群組在、docker info 不通」的節點：
    # id -nG 有 docker、docker info 失敗。id 版本會回 MLP_DOCKER_OK。
    inj_got="$(NODE_JSON='{"name":"t","capabilities":{"worker-host":{"runtime":"docker"}}}' MLP_FILE="$SANDBOX/mlp-inj8.sh" SANDBOX="$SANDBOX" HOME="$HOME_DIR" \
      bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="$SANDBOX/vshim/pool-resolve"
        run_on_node() {
            case "$2" in
              *"docker info"*) return 1 ;;
              *"id -nG"*) printf MLP_DOCKER_OK ;;
              *) return 1 ;;
            esac
        }
        ( cmd_verify_capabilities t >/dev/null 2>&1 ); printf "%s" "$?"
      ' 2>/dev/null)"
    if [[ "$inj_got" == "0" ]]; then
        inj_ok "8. 改 id -nG 後群組在即 pass（got rc=${inj_got}）——1a/5d 會紅"
    else
        inj_bad "8. 改 id -nG 後仍失敗（got rc=${inj_got}）——注入沒生效"
    fi
fi
# 9. value 寫成字串而不是 object → 格式檢查沒擋住。
mktmpf o9 "    jq -e 'type == \"object\" and all(.[]; type == \"object\")' >/dev/null 2>&1 <<< \"\${1:-null}\"
"
mktmpf n9 "    jq -e 'type == \"object\"' >/dev/null 2>&1 <<< \"\${1:-null}\"
"
if ! mutate "$REPO_ROOT/$MLP" "$SANDBOX/nd-o9" "$SANDBOX/nd-n9" "$SANDBOX/mlp-inj9.sh" 2>"$SANDBOX/i9.err" \
|| ! bash -n "$SANDBOX/mlp-inj9.sh" 2>/dev/null; then
    inj_bad "9. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i9.err")"
else
    inj_got="$(CAPS='{"worker-host":"docker"}' MLP_FILE="$SANDBOX/mlp-inj9.sh" bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        if cap_shape_ok "$CAPS"; then printf OK; else printf REJECT; fi
    ' 2>/dev/null)"
    if [[ "$inj_got" == "REJECT" ]]; then
        inj_bad "9. 放寬形狀檢查後仍 REJECT——格式斷言沒被量到"
    else
        if [[ "$inj_got" == "OK" ]]; then
            inj_ok "9. 放寬後字串 value 被放行（got [$inj_got]）——2a 會紅"
        else
            inj_bad "9. 行為變了但不是預期的放行（got [$inj_got]）——harness 問題"
        fi
    fi
fi
# 10. 不認得的 key 被刪掉 → 保留規則失效。
#   保留規則由兩半合成：`*`（遞迴合併，未知 key 活著）＋ RHS 的
#   `$existing.capabilities // ...`（既有能力原樣帶回）。只改一半不會刪到
#   （實測：`+` 搭配原 RHS 仍保留；`*` 搭配預設值仍遞迴合併）。忠實的「刪掉」
#   是兩半都退化：運算子改 `+`（淺層覆蓋）且 RHS 只留預設。needle 兩枚，
#   命中數各剛好 1。
python3 - "$SANDBOX/rp/rp.sh" "$SANDBOX/rp/rp-inj10.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needles = [
    ("        '$existing * {\n", "        '$existing + {\n"),
    ('            capabilities: ($existing.capabilities // {"worker-host": {"runtime": "docker"}})\n',
     '            capabilities: {"worker-host": {"runtime": "docker"}}\n'),
]
for old, new in needles:
    assert src.count(old) == 1, "needle count != 1: %r" % old[:50]
    src = src.replace(old, new, 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/rp/rp-inj10.sh" 2>/dev/null; then
    inj_bad "10. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    : > "$SANDBOX/set10.json"
    GH_VAR_VALUE="$(cat "$SANDBOX/existing.json")" GH_SET_FILE="$SANDBOX/set10.json" \
    PATH="$SHIMS:$PATH" HOME="$HOME_DIR" RPSRC="$SANDBOX/rp/rp-inj10.sh" \
    bash -c '
        set -- --name t --gateway-port 2323
        GH_POOL_TOKEN=dummy
        source "$RPSRC" >/dev/null 2>&1
        step5_register_var >/dev/null 2>&1
    ' 2>/dev/null
    if jq -e '.capabilities.mystery == {"x":1}' "$SANDBOX/set10.json" >/dev/null 2>&1 \
    || jq -e '.capabilities["wol-sender"] == {}' "$SANDBOX/set10.json" >/dev/null 2>&1; then
        inj_bad "10. 突變後未知 key 仍在——注入沒生效（caps [$(jq -c '.capabilities' "$SANDBOX/set10.json" 2>/dev/null)]）"
    else
        inj_ok "10. 突變版刪掉未知 key（寫出 [$(jq -c '.capabilities' "$SANDBOX/set10.json" 2>/dev/null)]）——3a 會紅"
    fi
fi
# 11. create-worker 沒複製 capabilities → worker 的能力消失。
mktmpf o11 '    ledger_add "$workers_json" "$port" "$provider" "$image" "$container" \
        "$created_at" "$tunnel_public_key" "$caps"
'
mktmpf n11 '    ledger_add "$workers_json" "$port" "$provider" "$image" "$container" \
        "$created_at" "$tunnel_public_key"
'
# create-worker.sh sources scripts/lib/ relative to its own location, so the
# mutant must live next to a real lib/ to load at all.
mkdir -p "$SANDBOX/cw/lib"
cp -R "$REPO_ROOT/scripts/lib/." "$SANDBOX/cw/lib/"
if ! mutate "$REPO_ROOT/$CW" "$SANDBOX/nd-o11" "$SANDBOX/nd-n11" "$SANDBOX/cw/cw-inj11.sh" 2>"$SANDBOX/i11.err" \
|| ! bash -n "$SANDBOX/cw/cw-inj11.sh" 2>/dev/null; then
    inj_bad "11. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i11.err")"
else
    inj_got="$(bash -c '
        source "'"$SANDBOX"'/cw/cw-inj11.sh"
        create_worker_ledger_add "[]" 2301 pn withcaps cn 2026-01-01T00:00:00Z PUB "'"$SANDBOX"'/profiles/worker/withcaps/profile.json"
    ' 2>&1)"
    if printf '%s' "$inj_got" | jq -e '.[0].capabilities["worker-host"].runtime == "docker"' >/dev/null 2>&1; then
        inj_bad "11. 拿掉複製後 4a 仍綠——capabilities 沒被量到"
    else
        if printf '%s' "$inj_got" | jq -e '.[0] | has("capabilities") | not' >/dev/null 2>&1; then
            inj_ok "11. 拿掉複製後條目沒有 capabilities（got [$(printf '%s' "$inj_got" | head -c 160)]）——4a 會紅"
        else
            inj_bad "11. 行為變了但不是預期的消失（got [$(printf '%s' "$inj_got" | head -c 160)]）——harness 問題"
        fi
    fi
fi

# 12. unverifiable 被當成 pass → 沒驗到卻回報通過（字串與碼都要轉）。
#   兩個 needle：初始值（根因）與 unverifiable 分支的碼。needle 各剛好 1。
python3 - "$REPO_ROOT/$MLP" "$SANDBOX/mlp-inj12.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needles = [
    ('    CAP_STATE="unverifiable"\n    CAP_DETAIL=""\n',
     '    CAP_STATE="pass"\n    CAP_DETAIL=""\n'),
    ('            *)    mark="${C_YELLOW}unverifiable${C_RESET}"; [[ "$rc" -eq 0 ]] && rc=3 ;;\n',
     '            *)    mark="${C_YELLOW}unverifiable${C_RESET}"; rc=0 ;;\n'),
]
for old, new in needles:
    assert src.count(old) == 1, "needle count != 1: %r" % old[:50]
    src = src.replace(old, new, 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/mlp-inj12.sh" 2>/dev/null; then
    inj_bad "12. 注入失敗（needle 落空或語法錯）——harness 問題"
else
    inj_got="$(NODE_JSON='{"name":"t","capabilities":{"wol-sender":{}}}' MLP_FILE="$SANDBOX/mlp-inj12.sh" SANDBOX="$SANDBOX" HOME="$HOME_DIR" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="$SANDBOX/vshim/pool-resolve"
        run_on_node() { :; }
        ( cmd_verify_capabilities t >"'"$SANDBOX"'/vc12.out" 2>&1 ); printf "%s" "$?"
    ' 2>/dev/null)"
    if [[ "$inj_got" == "3" ]] && grep -qF 'unverifiable' "$SANDBOX/vc12.out" 2>/dev/null; then
        inj_bad "12. 突變後仍 unverifiable＋3——注入沒生效"
    else
        if [[ "$inj_got" == "0" ]]; then
            inj_ok "12. 初始值／碼退化後 unverifiable 回報 exit 0（got rc=${inj_got}）——5a 會紅"
        else
            inj_bad "12. 行為變了但不是預期的假通過（rc=${inj_got} out [$(tr '\n' '|' < "$SANDBOX/vc12.out" 2>/dev/null | head -c 140)]）——harness 問題"
        fi
    fi
fi
# 14. 根因針：把 CAP_STATE 的初始值改回 pass → 沒觀察就回報 true 的門又開了。
#   為什麼是靜態斷言（而非某個畸形 input）：schema 檢查＋「空 repos 顯式
#   pass」＋observed 護欄已把所有已知形狀都給出顯式答案，沒有任何 input
#   會走到「初始值直接出場」。初始值的價值正在於**下一條還沒被想到的
#   「沒跑到」路徑**——所以針要扎在初始值本身的宣告上。
#   兩枚 needle（github 與 worker-host 的初始值），命中數各剛好 1。
python3 - "$REPO_ROOT/$MLP" "$SANDBOX/mlp-inj14.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needles = [
    ('    # Starts unverifiable, like cap_verify_github: only a path that actually\n'
     '    # observed something may raise the verdict to pass (2026-09-25 qa\n'
     '    # finding — an initial pass leaks "never inspected" out as "true").\n'
     '    CAP_STATE="unverifiable"; CAP_DETAIL=""\n',
     '    CAP_STATE="pass"; CAP_DETAIL=""\n'),
    ('    CAP_STATE="unverifiable"\n    CAP_DETAIL=""\n',
     '    CAP_STATE="pass"\n    CAP_DETAIL=""\n'),
]
for old, new in needles:
    assert src.count(old) == 1, "needle count != 1: %r" % old[:60]
    src = src.replace(old, new, 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -ne 0 ]] || ! bash -n "$SANDBOX/mlp-inj14.sh" 2>/dev/null; then
    inj_bad "14. 注入失敗（初始值 needle 落空或語法錯）——harness 問題"
else
    inj_init="$(python3 - "$SANDBOX/mlp-inj14.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
bad = []
for fn in ("cap_verify_worker_host", "cap_verify_github"):
    m = re.search(r'^%s\(\) \{.*?^\}' % fn, src, re.M | re.S)
    body = m.group(0)
    first = re.search(r'CAP_STATE="(\w+)"', body)
    if first and first.group(1) != "unverifiable":
        bad.append("%s starts %s" % (fn, first.group(1)))
print("; ".join(bad))
PY
)"
    if [[ -n "$inj_init" ]]; then
        inj_ok "14. 初始值改回 pass 後 5n 會紅（got [${inj_init}]）——根因被釘住"
    else
        inj_bad "14. 初始值改回 pass 後 5n 仍綠——注入沒生效"
    fi
fi
# 13. worker profile 宣告 github 沒被擋 → 禁令退回成文件上的一句話。
#   突變目標是 workflow 抽出的步驟文字（真檔不動），把 guard 整塊拿掉。
if [[ -s "$SANDBOX/wf/validate-ghprof.sh" ]]; then
    python3 - "$SANDBOX/wf/validate-ghprof.sh" "$SANDBOX/wf/validate-ghprof-inj.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('if ! profile_validate_no_github "$profile"; then\n'
       '  echo "::error::${profile} violates CAPABILITY-DESIGN.md \u00a72 \u2014 see message above"\n'
       '  exit 1\n'
       'fi\n')
assert src.count(old) == 1, "github-guard needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, "", 1))
PY
    if [[ $? -ne 0 ]]; then
        inj_bad "13. 注入腳本失敗（needle 落空）——harness 問題"
    else
        rc="$(wf_step "$SANDBOX/wf/validate-ghprof-inj.sh")"
        if [[ "$rc" -ne 0 ]]; then
            inj_bad "13. 拿掉 guard 後步驟仍失敗——禁令沒被量到"
        else
            inj_ok "13. 拿掉 guard 後宣告 github 的 profile 一路通過（got rc=${rc}）——6a 會紅"
        fi
    fi
else
    inj_bad "13. 抽出的步驟不存在——harness 問題"
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
