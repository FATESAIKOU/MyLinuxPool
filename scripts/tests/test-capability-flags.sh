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
# gh：記帳；api 讀 GH_VAR_VALUE（**單一 var 回信封** {name,value}，真實 gh 就是這個
#   形狀，--jq .value 才有作用）、讀 repo（回 .full_name，gh 能力就是「讀得到這些
#   repo」）；variable set 寫 GH_SET_FILE。
#
# 單一 var 為什麼要改成信封（2026-10-02）：step5_register_var 與
# step7_5_capabilities 都是 `gh api …/variables/<NAME> --jq .value`。舊的假 gh
# 直接吐裸值、**完全忽略 --jq**，於是那兩個步驟讀到的 var 內容其實是「假 gh 自己
# 印的東西」，等於沒有驗證讀取路徑。回信封之後形狀才對得上真實 gh。
# 讀取分支**必須自己套 --jq**（真實 gh 就是這樣：`--jq` 是 gh 端的過濾器）。
# 舊的假 gh 完全忽略 --jq、直接印裸值，於是 step5_register_var 與
# step7_5_capabilities 的 `gh api … --jq .value` 讀到的是「假 gh 自己印的東西」，
# 讀取路徑等於沒被驗證。回信封之後這一條特別關鍵：沒有套 --jq，呼叫端會把
# 整個信封 {"name":…,"value":"…"} 當成 var 的內容。
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >> "${GH_LOG:-/dev/null}"
if [[ "${1:-}" == "variable" && "${2:-}" == "set" ]]; then
    cat > "${GH_SET_FILE:-/dev/null}"
    printf 'SET %s\n' "${3:-}" >> "${GH_LOG:-/dev/null}"
    exit 0
fi
if [[ "${1:-}" == "api" ]]; then
    body=""
    case "$*" in
      *"variables?per_page"*) body="\"${GH_VAR_LIST:-NODE_T}\"" ;;
      # gh 能力的判準會對 profile 裡的每個 repo 打一次 `gh api --include
      # repos/<repo> --jq .full_name`；讀得到 = exit 0 並回 .full_name 的值。
      repos/*) body="\"${GH_REPO_FULL_NAME:-FATESAIKOU/MyBrain}\"" ;;
      *"/actions/variables/NODE_T"*)
          body="$(jq -c -n --arg n "NODE_T" --arg v "${GH_VAR_VALUE:-{\}}" '{name:$n,value:$v}')" ;;
      *) body="null" ;;
    esac
    filter=""; prev=""
    for a in "$@"; do
        [[ "$prev" == "--jq" ]] && filter="$a"
        prev="$a"
    done
    if [[ -n "$filter" ]]; then
        printf '%s' "$body" | jq -r "$filter"
    else
        printf '%s\n' "$body"
    fi
    exit 0
fi
exit 0
FAKE
# docker：info 以 DOCKER_RC 為準；**每一行 argv 都記進 DOCKER_LOG**——
#   第 1 組要用它當「docker 檢查有沒有真的跑過」的探針（舊的 1d 是用覆寫
#   step7_5_docker_group 當 sentinel，而那個函式已經不在能力路徑上了）。
cat > "$SHIMS/docker" <<'FAKE'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${DOCKER_LOG:-/dev/null}"
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
# getent：worker-host 單位靠它分辨「確定不成立(1)」與「無法確認(2)」
#   （/etc/group 的 docker 群組有這個使用者，但這個 process 的群組沒有）。
#   macOS 沒有 getent、Linux CI 上則是「查無此群組」——兩邊都剛好是 1，
#   但那是巧合，不是契約。所以在這裡釘死它。
cat > "$SHIMS/getent" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "group" && "${2:-}" == "docker" ]]; then
    if [[ -n "${FAKE_DOCKER_GROUP_HAS_USER:-}" ]]; then
        printf 'docker:x:999:%s\n' "$(id -un)"
    else
        printf 'docker:x:999:someone-else\n'
    fi
    exit 0
fi
exit 2
FAKE
chmod +x "$SHIMS/gh" "$SHIMS/docker" "$SHIMS/id" "$SHIMS/getent"

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
# ---- 假 fetched repo（D8 之後，能力步驟是從 clone 裡跑的）--------------------
# step7_5_capabilities 從 REPO_DIR（register-provider 的臨時 clone）讀
# scripts/lib/capability.sh 與 profiles/provider/<PROFILE_NAME>/profile.json，
# runner 再從**同一個根**現場查 shared-configs/*/unit.json 並跑該單位的 --check。
# 這三個單位是**真的**（PR-A 已經驗過它們），不是再造一個假的：這一組斷言量的
# 就是「register-provider 透過 runner 得到 worker-host 的結果」，用假單位量的
# 會變成另一個命題。
# make_fixture_repo <dest> <profile-capabilities-json>
make_fixture_repo() {
    local dest="$1" caps="$2" f
    rm -rf "$dest"
    mkdir -p "$dest/scripts/lib" "$dest/profiles/provider/default"
    cp "$REPO_ROOT/scripts/lib/capability.sh" "$dest/scripts/lib/capability.sh"
    for u in worker-host gh wol; do
        mkdir -p "$dest/shared-configs/$u/files"
        cp "$REPO_ROOT/shared-configs/$u/unit.json"   "$dest/shared-configs/$u/unit.json"
        cp "$REPO_ROOT/shared-configs/$u/install.sh"  "$dest/shared-configs/$u/install.sh"
        chmod +x "$dest/shared-configs/$u/install.sh"
        if [[ -f "$REPO_ROOT/shared-configs/$u/files/pool-wol" ]]; then
            cp "$REPO_ROOT/shared-configs/$u/files/pool-wol" "$dest/shared-configs/$u/files/pool-wol"
        fi
    done
    jq -n --argjson caps "$caps" \
        '{role:"provider",shared_config:[],capabilities:$caps}' > "$dest/profiles/provider/default/profile.json"
}

# 沙箱裡的 HOME 要有那兩樣東西，否則能力的判準一定不成立：
#   gh_token  —— gh 單位的第一個判準就是「有沒有憑證」
#   pool-wol  —— wol 單位的判準是「已安裝的那一份與單位的 files/pool-wol 逐位元組相同」；
#                這裡就是照真的單元 install 那樣複製（cp + chmod），不是造一個假檔。
seed_home() {
    mkdir -p "$HOME_DIR/.mylinuxpool/bin"
    printf 'ghp_FIXTURE_TOKEN_not_a_real_credential\n' > "$HOME_DIR/.mylinuxpool/gh_token"
    if [[ -f "$REPO_ROOT/shared-configs/wol/files/pool-wol" ]]; then
        cp "$REPO_ROOT/shared-configs/wol/files/pool-wol" "$HOME_DIR/.mylinuxpool/bin/pool-wol"
        chmod +x "$HOME_DIR/.mylinuxpool/bin/pool-wol"
    fi
}

# rp_step7 <rp-path> <profile-capabilities-json> <var-capabilities-json>
#          <docker-rc> <override-fn>
#   profile 的 capabilities 決定「宣告哪些能力」；var 裡既有的宣告決定「要不要寫」。
#   印 RC 與 stdout／stderr。REPO_DIR 指向剛組好的假 fetched repo——這是
#   register-provider 自己 mktemp 出來的那個目錄，能力步驟只認它。
rp_step7() {
    local rp_path="$1" profile_caps="$2" var_caps="$3" docker_rc="$4" override="$5"
    local out err rc fix
    out="$SANDBOX/s7.out"; err="$SANDBOX/s7.err"; : > "$out"; : > "$err"
    fix="$SANDBOX/fixrepo"; make_fixture_repo "$fix" "$profile_caps"; seed_home
    FIXTURE_REPO="$fix" RPSRC="$rp_path" \
    GH_VAR_VALUE="{\"capabilities\":${var_caps}}" \
    GH_VAR_LIST="NODE_T" DOCKER_RC="$docker_rc" DOCKER_LOG="$SANDBOX/docker.log" \
    PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
    bash -c '
        set -- --name t --gateway-port 2323
        GH_POOL_TOKEN=dummy
        source "$RPSRC" >/dev/null 2>&1
        # 剝掉 register-provider 自己那個「刪掉 REPO_DIR」的 trap：REPO_DIR 現在
        # 指向測試組出來的假 fetched repo，而且同一組要跑好幾次。
        trap - EXIT INT TERM
        REPO_DIR="$FIXTURE_REPO"
        PROFILE_JSON="$FIXTURE_REPO/profiles/provider/default/profile.json"
        NO_SUDO=1
        '"$override"'
        step7_5_capabilities >"'"$out"'" 2>"'"$err"'"
    ' 2>/dev/null
    rc=$?
    printf 'RC=%s OUT=[%s] ERR=[%s]' "$rc" \
        "$(tr '\n' '|' < "$out")" "$(tr '\n' '|' < "$err")"
}
# 同一個假 fetched repo，直接問 runner 某個鍵（不經過 register-provider）：
# runner_check <fixture-root> <鍵> <參數JSON> [額外環境…] → 印回傳碼
runner_check() {
    local fix="$1" key="$2" params="$3"; shift 3
    env MLP_REPO_ROOT="$fix" REPO_ROOT="$fix" HOME="$HOME_DIR" PATH="$SHIMS:$PATH" \
        DOCKER_RC="${DOCKER_RC:-0}" DOCKER_LOG="$SANDBOX/docker.log" \
        FAKE_GROUPS="${FAKE_GROUPS:-staff docker everyone}" \
        FAKE_DOCKER_GROUP_HAS_USER="${FAKE_DOCKER_GROUP_HAS_USER:-}" "$@" \
        bash -c 'source "$MLP_REPO_ROOT/scripts/lib/capability.sh" >/dev/null 2>&1
                 capability_check "$1" "$2"' _ "$key" "$params"
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
# 这一組的被對象換掉了（D8 把 docker 判準搬進 worker-host 單位，register-provider
# 只透過 runner 問），命題沒換：
#   1a  docker 不通 → 註冊失敗，而且訊息要指得出是「確定不成立」（不是「無法確認」）
#   1b  docker 通 → 註冊通過
#   1c  群組在、socket 不通 → 仍然是 1（群組在不算證據）
#   1d  runtime 不是 docker → 不去碰 docker（原本用覆寫 step7_5_docker_group 當
#       sentinel；那個函式已經不在能力路徑上，現在改用 docker 的呼叫紀錄當探針）
PROF_DOCKER='{"worker-host":{"runtime":"docker"},"github":{"repos":{"FATESAIKOU/MyBrain":["read"]}},"wol":{"methods":["unicast"]}}'
VAR_WH='{"worker-host":{"runtime":"docker"}}'

# 1-pre：沙箱健全性。**這是第 1 組的前提**，沒有它，下面每一條紅燈都分不清是
#   「能力真的不成立」還是「假 fetched repo 缺東西」。三個能力都必須能被
#   這棵假 repo 驗到（gh 有 token、pool-wol 與單位的檔逐位元組相同、docker 可用）。
: > "$SANDBOX/docker.log"
FIX="$SANDBOX/fixrepo"; make_fixture_repo "$FIX" "$PROF_DOCKER"; seed_home
pre_err=""
DOCKER_RC=0 runner_check "$FIX" worker-host '{"runtime":"docker"}' || pre_err="${pre_err} worker-host(docker 通)≠0"
DOCKER_RC=0 runner_check "$FIX" github '{"repos":{"FATESAIKOU/MyBrain":["read"]}}' || pre_err="${pre_err} github≠0"
DOCKER_RC=0 runner_check "$FIX" wol '{"methods":["unicast"]}' || pre_err="${pre_err} wol≠0"
DOCKER_RC=1 runner_check "$FIX" worker-host '{"runtime":"docker"}' \
    && pre_err="${pre_err} worker-host(docker 不通)竟然=0"
cmp -s "$HOME_DIR/.mylinuxpool/bin/pool-wol" "$REPO_ROOT/shared-configs/wol/files/pool-wol" \
    || pre_err="${pre_err} 已安裝的 pool-wol 與單位的檔不是逐位元組相同"
if [[ -z "$pre_err" ]]; then
    ok "1-pre. 沙箱健全：三個能力都能被這棵假 fetched repo 驗到（gh 有 token、pool-wol 逐位元組相同、docker 可用）"
else
    bad "1-pre. 沙箱不健全：${pre_err}——下面每一條都量不到東西（harness 問題）"
fi

# 1b 先跑：1d 要用它當正向控制（見下面）。
got_b="$(rp_step7 "$SANDBOX/rp/rp.sh" "$PROF_DOCKER" "$VAR_WH" 0 '')"
if [[ "$got_b" == "RC=0"* ]]; then
    ok "1b. docker 通 → 0"
else
    bad "1b. docker 通竟失敗（got [$got_b]）"
fi

# 1a：docker 不通 → step7_5_capabilities 非 0，且訊息指名 worker-host 是
#     「確定不成立」（NOT established），不是「無法確認」。
#   後半段是 D8 的字面要求：「註冊就失敗，並指出是哪個能力，以及它是不成立
#   還是無法確認」。只有非 0 的話，1 與 2 分不出來——而那兩者的處置完全相反
#   （1 是確定壞掉、2 要保留舊值不要抖動）。
got="$(rp_step7 "$SANDBOX/rp/rp.sh" "$PROF_DOCKER" "$VAR_WH" 1 '')"
if [[ "$got" == RC=0* ]]; then
    bad "1a. docker 不通竟回報通過（got [$got]）"
elif [[ "$got" == RC=1* ]] && printf '%s' "$got" | grep -qF "capability 'worker-host': NOT established" \
    && ! printf '%s' "$got" | grep -qF 'could not be confirmed'; then
    ok "1a. docker 不通 → 非 0，且指名 worker-host 是「確定不成立」（不是「無法確認」）"
else
    bad "1a. docker 不通的結果不對：必須是 RC=1 且指名 worker-host NOT established（got [$got]）"
fi
# 1c：群組在、socket 不通 → 經 runner 仍然是 1（「在群組裡」不是證據）。
#   前提先把謊言擺出來：同一個夾具下 id -nG 確實說有 docker 群組，而且
#   /etc/group 的 docker 群組也有這個使用者（否則單位會走「群組變更沒生效」
#   那條分支回 2，這一條就量不到它要量的東西）。
if ! PATH="$SHIMS:$PATH" FAKE_GROUPS='staff docker everyone' id -nG 2>/dev/null | grep -qw docker; then
    bad "1c. 對照組沒成立——夾具無效（id -nG 沒說有 docker 群組）"
else
    fix_rc="$(DOCKER_RC=1 FAKE_DOCKER_GROUP_HAS_USER=1 runner_check "$FIX" worker-host '{"runtime":"docker"}'; echo "rc=$?")"
    if [[ "$fix_rc" == "rc=1" ]]; then
        ok "1c. 群組在（id -nG 有 docker、/etc/group 也有）但 socket 不通 → 經 runner 仍然是 1"
    else
        bad "1c. 群組在、socket 不通，經 runner 回 [${fix_rc}]——預期 1（「在群組裡」不算證據）"
    fi
fi
# 1d：runtime:podman → 不去碰 docker。探針是 docker 的呼叫紀錄本身
#     （舊的 1d 是覆寫 step7_5_docker_group 當 sentinel，而那個函式已經不在
#     能力路徑上了；現在量的是「docker 有沒有真的被呼叫」）。
#   為什麼需要 1b 當前提：非 0 本身證明不了「是 podman 造成的」——任何原因
#   的非 0 都長一樣（PROFILE 拼字錯、夾具缺檔…）。1b 是同一個夾具、同一個
#   runner、只把 runtime 換回 docker 的對照組：1b 綠而 1d 非 0，差異才歸得到
#   runtime 那一個參數上。
: > "$SANDBOX/docker.log"
got="$(rp_step7 "$SANDBOX/rp/rp.sh" \
        '{"worker-host":{"runtime":"podman"},"github":{"repos":{"FATESAIKOU/MyBrain":["read"]}},"wol":{"methods":["unicast"]}}' \
        "$VAR_WH" 1 '')"
# grep -c 在空檔會印 0 **而且回 1**，所以 `grep -c . f || echo 0` 會得到兩行的
    # "0\n0"——那不是數字，[[ ]] 的比較會整個壞掉。這裡先看檔案有沒有東西。
n_docker=0
if [[ -s "$SANDBOX/docker.log" ]]; then n_docker="$(grep -c . "$SANDBOX/docker.log")"; fi
if [[ "$got_b" != "RC=0"* ]]; then
    bad "1d. 前提不成立：1b（正向控制）不是綠的，1d 的非 0 分不出是 runtime 造成的還是別的（1b got [$got_b]）"
elif [[ "$n_docker" -eq 0 ]] && [[ "$got" == RC=1* ]]; then
    ok "1d. runtime:podman → 非 0，且 docker 完全沒被呼叫（紀錄 0 行）——不把 podman 當 docker"
else
    bad "1d. runtime:podman 的結果不對：必須非 0（1b 是綠的）＋docker 0 次呼叫（got [$got]，docker ${n_docker} 次）"
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

# ---- 假節點：run_on_node 送來的那一條命令字串，真的執行 ---------------------
# D3 之後 mlp 不再自己驗，而是把**整個單位**（tar）送到目標機器上跑它的 --check，
# 結果就是 run_on_node 的回傳碼。所以假 run_on_node 必須在沙箱裡真的執行那條
# 字串（一次 eval，不要再包一層 eval——多一層會把字串裡的引號吃掉）。
#
# 為什麼這是本節的關鍵：只印字串回 0 的話，單位的回傳碼從來沒有回來過，
# 而「畸形值 → GitHub API 零呼叫」這種斷言**永遠成立**（沒有東西會打 API）。
# 真的執行之後：
#   worker-host 的 docker／getent／id 走本檔的 SHIMS
#   gh 單位的 `gh api` 真的打到本檔的假 gh → 於是「API 呼叫次數」數得到
FAKE_NODE_DIR="$SANDBOX/node"; mkdir -p "$FAKE_NODE_DIR"
mkdir -p "$SANDBOX/vtmp"
seed_home    # gh_token（gh 單位的第一個判準）＋ 逐位元組相同的 pool-wol
# 假 gh 的 api 呼叫帳本：每次呼叫寫一行 `GH api …`（假 gh 每次都記 GH_LOG）。
GH_LOG="$SANDBOX/gh.log"
: > "$GH_LOG"
gh_api_calls() { grep -c '^GH api ' "$GH_LOG" 2>/dev/null || true; }

# verify_caps <node-json> <run_on_node-override>：印 RC、stdout、gh api 呼叫數。
# override 留空就是「真的執行那條命令字串」；只有 5d（hop 失敗）需要覆寫。
verify_caps() {
    local node_json="$1" override="$2" out rc calls
    out="$SANDBOX/vc.out"; : > "$out"; : > "$GH_LOG"
    rm -rf "$SANDBOX/vtmp"; mkdir -p "$SANDBOX/vtmp"
    NODE_JSON="$node_json" MLP_FILE="$REPO_ROOT/$MLP" SANDBOX="$SANDBOX" \
    override="$override" HOME="$HOME_DIR" GH_LOG="$GH_LOG" \
    TMPDIR="$SANDBOX/vtmp" DOCKER_RC="${DOCKER_RC:-0}" \
    FAKE_DOCKER_GROUP_HAS_USER="${FAKE_DOCKER_GROUP_HAS_USER:-}" \
    FAKE_GROUPS="${FAKE_GROUPS:-staff docker everyone}" \
    PATH="$SHIMS:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="$SANDBOX/vshim/pool-resolve"
        run_on_node() { printf "%s\n" "$2" >> "$SANDBOX/run_on_node.log";
                        ( cd "$SANDBOX/node" && eval "$2" ); }
        eval "$override"
        ( cmd_verify_capabilities t >"'"$out"'" 2>&1 ); rc=$?
        printf "%s" "$rc" > "'"$SANDBOX"'/vc.rc"
    ' 2>/dev/null
    rc="$(cat "$SANDBOX/vc.rc" 2>/dev/null)"
    calls="$(gh_api_calls)"
    printf 'RC=%s APICALLS=%s OUT=[%s]' "$rc" "$calls" "$(tr '\n' '|' < "$out")"
}
# verify_caps2 <mlp-path> <node-json> <override>：同 verify_caps，但可指定突變檔。
verify_caps2() {
    local mlp_path="$1" node_json="$2" override="$3" out rc calls
    out="$SANDBOX/vc2.out"; : > "$out"; : > "$GH_LOG"
    rm -rf "$SANDBOX/vtmp"; mkdir -p "$SANDBOX/vtmp"
    NODE_JSON="$node_json" MLP_FILE="$mlp_path" SANDBOX="$SANDBOX" \
    override="$override" HOME="$HOME_DIR" GH_LOG="$GH_LOG" \
    TMPDIR="$SANDBOX/vtmp" DOCKER_RC="${DOCKER_RC:-0}" \
    FAKE_DOCKER_GROUP_HAS_USER="${FAKE_DOCKER_GROUP_HAS_USER:-}" \
    FAKE_GROUPS="${FAKE_GROUPS:-staff docker everyone}" \
    PATH="$SHIMS:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="$SANDBOX/vshim/pool-resolve"
        run_on_node() { printf "%s\n" "$2" >> "$SANDBOX/run_on_node.log";
                        ( cd "$SANDBOX/node" && eval "$2" ); }
        eval "$override"
        ( cmd_verify_capabilities t >"'"$out"'" 2>&1 ); rc=$?
        printf "%s" "$rc" > "'"$SANDBOX"'/vc2.rc"
    ' 2>/dev/null
    rc="$(cat "$SANDBOX/vc2.rc" 2>/dev/null)"
    calls="$(gh_api_calls)"
    printf 'RC=%s APICALLS=%s OUT=[%s]' "$rc" "$calls" "$(tr '\n' '|' < "$out")"
}

# 5a：wol-sender（沒有單位實作）→ unverifiable＋exit 3。**零 API 呼叫**是它的一部分：
#     沒有單位就沒有東西可送，所以連節點都不該被碰到。
got="$(verify_caps '{"name":"t","capabilities":{"wol-sender":{}}}' '')"
if [[ "$got" == "RC=3 APICALLS=0"* ]] && printf '%s' "$got" | grep -qF 'unverifiable' \
&& ! printf '%s' "$got" | grep -qF 'ok  '; then
    ok "5a. wol-sender → unverifiable 且 exit 3（不是 pass，也沒折成 0），而且沒有送出任何東西"
else
    bad "5a. 沒定義驗證的 key 被當成 pass（got [$got]）"
fi
# 5b：github 要求 read 以外的權限 → gh 單位的 --check 回 2 → unverifiable＋exit 3。
#   **換掉的是被重構的對象**：形狀／權限判準搬進 gh 單位之後，單位的回傳碼是
#   唯一能看到的答案——節點上的輸出被 run_on_node 的 >/dev/null 丟掉，mlp 這邊
#   只剩 rc 與 detail。所以斷言改成量「rc=2 那一格」：detail 必須是
#   `could not be confirmed`（1 會印 not established、0 會印 established）。
#   命題沒變：**沒有辦法驗證的權限不得報 pass**。
got="$(verify_caps '{"name":"t","capabilities":{"github":{"repos":{"o/r":["write"]}}}}' '')"
if [[ "$got" == "RC=3 APICALLS="* ]] && printf '%s' "$got" | grep -qF 'unverifiable' \
&& printf '%s' "$got" | grep -qF 'could not be confirmed' \
&& ! printf '%s' "$got" | grep -qE '(^|[ |])ok([ |])'; then
    ok "5b. github 的 write → 單元回 2、報 unverifiable、exit 3（不是 pass）"
else
    bad "5b. write 被當成有驗證：預期 unverifiable＋could not be confirmed（got [$got]）"
fi
# 5c：未知 key → unverifiable＋exit 3。
got="$(verify_caps '{"name":"t","capabilities":{"mystery":{"x":1}}}' '')"
if [[ "$got" == "RC=3 APICALLS=0"* ]] && printf '%s' "$got" | grep -qF 'unverifiable'; then
    ok "5c. 未知 key → unverifiable 且 exit 3"
else
    bad "5c. 未知 key 靜靜通過（got [$got]）"
fi
# 5d：hop 失敗（真的 ssh 失敗）→ unverifiable，而且**不是** fail。
#   夾具改成 return 255：真的 ssh 的失敗碼就是 255，而 run_on_node 的回傳碼會
#   原樣穿回來。回 1 的話 mlp 會判成 fail（1 = 確定不成立），那是另一個意思——
#   節點根本沒送到，跟「能力不成立」無關。
got="$(verify_caps '{"name":"t","capabilities":{"worker-host":{"runtime":"docker"}}}' 'run_on_node() { return 255; }')"
if [[ "$got" == "RC=3 APICALLS="* ]] && printf '%s' "$got" | grep -qF 'unverifiable' \
&& printf '%s' "$got" | grep -qF 'check returned 255'; then
    ok "5d. hop 失敗（255）→ unverifiable 且 exit 3（不是 pass、也不是 fail）"
else
    bad "5d. 連不上卻報成別的結論（預期 unverifiable＋check returned 255；got [$got]）"
fi
# 5d2：**傳輸失敗（run_on_node 回 1、命令根本沒跑完）→ unverifiable，不能是 fail**
#   （review §3.2 的回歸）。mlp 的 run_on_node 前四個失敗點（hop 鏈解析、
#   pool-resolve 回的不是 JSON、hop 數不對…）**都回 1**，而單位的 `--check`
#   回 1 也叫 1——沒有 sentinel 的時候兩者分不開，於是「我們連不到它」被回報成
#   「這台機器沒有這個能力」。那是 CAPABILITY-DESIGN.md §2 講的那類錯誤：
#   把『讀不懂』說成『沒有』。
#   這裡的假 run_on_node **不執行**那條命令字串（= 命令沒跑完、沒有任何
#   sentinel 的輸出），只回 1。預期：unverifiable，且**不得**出現 not established。
got="$(verify_caps '{"name":"t","capabilities":{"worker-host":{"runtime":"docker"}}}' 'run_on_node() { return 1; }')"
if [[ "$got" == "RC=3 APICALLS="* ]] && printf '%s' "$got" | grep -qF 'unverifiable' \
&& ! printf '%s' "$got" | grep -qF 'not established'; then
    ok "5d2. 傳輸失敗（run_on_node 回 1、命令沒跑完、沒有 sentinel）→ unverifiable，不是 fail"
else
    bad "5d2. 傳輸失敗被回報成別的結論：預期 unverifiable 且不得出現 not established（got [$got]）"
fi
# 5e：正向控制——全部驗得過時 exit 0，避免「一律非 0」也算綠。
got="$(verify_caps '{"name":"t","capabilities":{"worker-host":{"runtime":"docker"}}}' '')"
if [[ "$got" == "RC=0 APICALLS=0"* ]] && printf '%s' "$got" | grep -qF 'ok'; then
    ok "5e. 正向控制：全部驗得過 → exit 0"
else
    bad "5e. 全 pass 竟非 0（got [$got]）——護欄會永遠紅"
fi
# 5f：github read → **真的**打 GitHub API，而且恰好一次。
#   這條是「零呼叫」那些斷言的正對照：計數器看得到呼叫，零才有意義。
got="$(verify_caps '{"name":"t","capabilities":{"github":{"repos":{"owner/repo":["read"]}}}}' '')"
if [[ "$got" == "RC=0 APICALLS=1"* ]] && grep -qF 'GH api --include repos/owner/repo' "$GH_LOG" 2>/dev/null; then
    ok "5f. github read → 真的打 gh api repos/owner/repo 恰好 1 次（不是看 token 檔）"
else
    bad "5f. github read 沒真的打 API（got [$got] log [$(grep -a '^GH api' "$GH_LOG" 2>/dev/null | head -c 120)])"
fi
# 5g–5k：五種畸形 github value → **不能報 pass，而且 GitHub API 零呼叫**。
#   換掉的是被重構的對象（形狀檢查搬進 gh 單位的 --check，畸形時回 1 且不打 API）。
#   命題沒變，而且更強了兩分：
#     (a) 「不能報 pass」從「報 fail」放寬成「狀態不是 pass」——因為單位的
#         1／2 分別對應 fail／unverifiable，兩者都滿足「沒報 pass」；
#     (b) 零呼叫的**計數對象換了**：舊版數 run_on_node 的呼叫（畸形時 mlp 根本
#         不會送出東西，所以那個數字只證明「沒送出」）；新版數**假 gh 的 api
#         呼叫**——單位的 --check 是在假節點上真的跑起來的，所以這個數字證明
#         「連 GitHub 都沒去碰」。5f 是它的正對照。
schema_case() {
    local label="$1" caps="$2" want_state="$3" got
    got="$(verify_caps2 "$REPO_ROOT/$MLP" "{\"name\":\"t\",\"capabilities\":${caps}}" '')"
    if [[ "$got" == "RC=1 APICALLS=0"* ]] && printf '%s' "$got" | grep -qF "$want_state"; then
        ok "${label}：${want_state}、GitHub API 零呼叫"
    else
        bad "${label}：預期 ${want_state}＋API 零呼叫（got [$got]）"
    fi
}
schema_case "5g. repos 是字串" '{"github":{"repos":"o/r"}}' 'FAIL'
schema_case "5h. repos 是陣列（非 object）" '{"github":{"repos":["o/r"]}}' 'FAIL'
schema_case "5i. repo 的權限值是字串" '{"github":{"repos":{"o/r":"read"}}}' 'FAIL'
schema_case "5j. 權限字不在 read/write/trigger-actions" '{"github":{"repos":{"o/r":["admin"]}}}' 'FAIL'
# 5k：value 不是 object 這一層形狀仍然是 mlp 自己擋的（key:object 契約），
#     所以它仍在送出之前就被拒，零呼叫同樣成立。
schema_case "5k. github 的 value 不是 object" '{"github":"read"}' 'not key:object'
# 5l. exit 三碼分流：0（全 ok）／1（任一 fail）／3（僅 unverifiable）。
#   fail 與 unverifiable 混合時 1（fail 優先）。
#   夾具要真的同時有 fail（畸形的 github）與 unverifiable（wol-sender），
#   否則驗到的是 pass＋unverifiable（那條本來就 3）。
mix_caps='{"github":{"repos":"o/r"},"wol-sender":{}}'
got="$(verify_caps2 "$REPO_ROOT/$MLP" '{"name":"t","capabilities":'"$mix_caps"'}' '')"
if [[ "$got" == "RC=1 APICALLS=0"* ]] && printf '%s' "$got" | grep -qF 'FAIL' \
&& printf '%s' "$got" | grep -qF 'unverifiable'; then
    ok "5l. fail＋unverifiable 混合 → exit 1（fail 優先，不被 unverifiable 蓋掉）"
else
    bad "5l. 混合碼不對（got [$got]）"
fi
got="$(verify_caps2 "$REPO_ROOT/$MLP" '{"name":"t","capabilities":{"mystery":{"x":1}}}' '')"
if [[ "$got" == "RC=3 APICALLS=0"* ]]; then
    ok "5m. 僅 unverifiable → exit 3（不是 0、也不是 1）"
else
    bad "5m. unverifiable-only 的碼不是 3（got [$got]）"
fi
# 5n. 根因（靜態）：**「pass」只能是某個觀察結果的分支**。
#   原始的命題：CAP_STATE 的初始值必須是 unverifiable，否則一條跑 0 圈的迴圈
#   會把「從未檢查」輸出成「true」（2026-09-25 qa 的根因）。
#   **錨點換掉了，命題沒換。** 舊錨點手列兩個 verifier 的初始值；D5 把判準搬進
#   單位、impl 又刪掉 `cap_verify_worker_host` 之後，cap_verify_node 裡**已經沒有
#   初始值**了——每一個分支都自己賦值（形狀不對 → fail、有單位 → case  rc、
#   沒有單位 → unverifiable）。舊錨點報的是「cap_verify_github missing」，
#   連「有沒有初始值」都沒問。
#   同一個命題在新的形狀下長這樣：**任何 `CAP_STATE="pass"` 都必須是某個 case
#   分支（`N) CAP_STATE="pass"; …`）**，也就是「先有觀察、才可能升成 pass」。
#   無條件的／初始的賦值（單獨一行）寫成 pass，就是那個 bug 回来了。
#   而且要真的撈到東西——一個 pass 都沒有時，這條斷言必須報「守衛本身失效」，
#   不能回報通過。
init_bad="$(python3 - "$REPO_ROOT/$MLP" <<'PYINIT'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
assigns = [(k + 1, l) for k, l in enumerate(lines)
           if re.search(r'^\s*(local\s+)?CAP_STATE="', l) or re.search(r'^\s*CAP_STATE=\"', l)]
bad = []
if not assigns:
    bad.append("no CAP_STATE assignment at all — the guard has nothing to look at")
case_arm = re.compile(r'^\s*\S+\)\s*CAP_STATE="pass"')
for k, l in assigns:
    if 'CAP_STATE="pass"' in l and not case_arm.search(l):
        bad.append("line %d assigns pass outside a case arm: %s" % (k, l.strip()[:60]))
print("; ".join(bad))
PYINIT
)"
init_count="$(python3 - "$REPO_ROOT/$MLP" <<'PYCNT'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
print(len([l for l in lines if "CAP_STATE=\"" in l]))
PYCNT
)"
if [[ -z "$init_bad" ]]; then
    ok "5n. mlp 裡的 ${init_count} 處 CAP_STATE 賦值：pass 只出現在 case 分支（先有觀察才可能升成 pass）"
else
    bad "5n. CAP_STATE 的初始值／無條件賦值不是 unverifiable（或守衛本身失效）：${init_bad}"
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

# 7. 能力檢查的結果被忽略掉 → 1a（docker 不通不得回報通過）必須轉紅。
#   **錨點換掉了，命題沒換。** 舊錨點是 RP 裡 `worker-host)` 這個寫死的 case
#   分支，D8 把它整段換成走 runner 的迴圈，於是 needle 命中數變 0。
#   新錨點＝同一個函式（step7_5_capabilities，2.2a 認得出來的那一個）本體裡
#   **呼叫 capability_check 的那一行**（非註解、剛好一行），把它換成 `rc=0`——
#   語意就是「檢查跑完了，但結果不看」。docker 不通時所有能力都會被判成 0。
#   形狀要跟著實作走：那一行現在是 `… >/dev/null 2>&1 || rc=$?`（把回傳碼收進
#   rc，順便擋掉 set -e），所以注入是「把收到 rc 的那一格換成 0」——檢查照跑、
#   結果照收，只是被丟掉。命中數必須剛好 1。
mktmpf o7 '            MLP_REPO_ROOT="$REPO_DIR" capability_check "$key" "$params" >/dev/null 2>&1 || rc=$?
'
mktmpf n7 '            MLP_REPO_ROOT="$REPO_DIR" capability_check "$key" "$params" >/dev/null 2>&1 || rc=0  # INJECTED
'
if ! mutate "$SANDBOX/rp/rp.sh" "$SANDBOX/nd-o7" "$SANDBOX/nd-n7" "$SANDBOX/rp/rp-inj7.sh" 2>"$SANDBOX/i7.err" \
|| ! bash -n "$SANDBOX/rp/rp-inj7.sh" 2>/dev/null; then
    inj_bad "7. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i7.err")"
else
    got="$(rp_step7 "$SANDBOX/rp/rp-inj7.sh" "$PROF_DOCKER" "$VAR_WH" 1 '')"
    if [[ "$got" == "RC=0"* ]]; then
        inj_ok "7. 忽略能力檢查的結果之後，docker 不通也回報通過（got [$got]）——1a 會紅"
    else
        inj_bad "7. 忽略結果之後仍然失敗（got [$got]）——注入沒生效"
    fi
fi
# 8. 驗證改成檢查 id -nG → 群組在、socket 不通時通過。
#   **錨點換掉了，命題沒換。** 舊錨點在 mlp 裡（`run_on_node … docker info`），
#   D3 把判準整個搬進 shared-configs/worker-host/install.sh，於是那裡 0 命中。
#   新錨點＝該單位 install.sh 裡的 `if docker info >/dev/null 2>&1; then`，
#   換成 `id -nG | grep -qw docker`——那個「看起來很合理、其實會在壞掉的時候
#   照過」的判準。
#   盯的斷言是 **1c**（群組在、socket 不通 → 經 runner 仍然是 1）：它問的是
#   同一個問題，只是從 register-provider 那一側改成直接問 runner。
mktmpf o8 'if docker info >/dev/null 2>&1; then
'
mktmpf n8 'if id -nG 2>/dev/null | grep -qw docker; then
'
if ! mutate "$REPO_ROOT/shared-configs/worker-host/install.sh" "$SANDBOX/nd-o8" "$SANDBOX/nd-n8" \
        "$SANDBOX/wh-inj8.sh" 2>"$SANDBOX/i8.err" \
|| ! bash -n "$SANDBOX/wh-inj8.sh" 2>/dev/null; then
    inj_bad "8. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i8.err")"
else
    fix8="$SANDBOX/fixrepo-inj8"
    rm -rf "$fix8"; mkdir -p "$fix8/scripts/lib" "$fix8/shared-configs/worker-host"
    cp "$SANDBOX/wh-inj8.sh" "$fix8/shared-configs/worker-host/install.sh"
    cp "$REPO_ROOT/shared-configs/worker-host/unit.json" "$fix8/shared-configs/worker-host/unit.json"
    cp "$REPO_ROOT/scripts/lib/capability.sh" "$fix8/scripts/lib/capability.sh"
    inj_rc="$(DOCKER_RC=1 FAKE_DOCKER_GROUP_HAS_USER=1 \
        runner_check "$fix8" worker-host '{"runtime":"docker"}'; echo "rc=$?")"
    if [[ "$inj_rc" == "rc=0" ]]; then
        inj_ok "8. 改用 id -nG 之後群組在就算通過（got rc=0）——1c 會紅"
    else
        inj_bad "8. 改用 id -nG 之後仍然不通過（got ${inj_rc}）——注入沒生效"
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
# 10. 不認得的 key 被刪掉 → 保留規則失效（3a 唯一的牙）。
#   **needle 換掉了，命題沒換。** 舊的第二枚 needle 是
#   `capabilities: ($existing.capabilities // {"worker-host": {"runtime": "docker"}})`
#   ——D8 拿掉了那個預設，現在是 `capabilities: $existing.capabilities`，命中數 0。
#   忠實的「刪掉未知 key」仍然是兩半都退化：運算子改成淺層覆蓋（`*` → `+`）
#   ＋ capabilities 只留空 object。兩枚 needle 命中數各剛好 1。
#   第二枚 needle 跟著實作走過一次：impl 把
#   `capabilities: $existing.capabilities` 改成
#   `capabilities: ($existing.capabilities // {})`（拿掉 worker-host 預設、
#   保留空 object 預設），於是舊 needle 又落空一次——這是本檔第三次因為
#   D8 的形狀變動而換錨點，命題（3a：未知 key 必須原樣保留）從未變過。
python3 - "$SANDBOX/rp/rp.sh" "$SANDBOX/rp/rp-inj10.sh" <<'PY10'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needles = [
    ("        '$existing * {\n", "        '$existing + {\n"),
    ('            capabilities: ($existing.capabilities // {})\n',
     '            capabilities: {}\n'),
]
for old, new in needles:
    assert src.count(old) == 1, "needle count != 1: %r" % old[:50]
    src = src.replace(old, new, 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY10
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
        inj_ok "10. 突變版刪掉未知 key（寫出 [$(jq -c '.capabilities' "$SANDBOX/set10.json" 2>/dev/null)]）——3a 有牙"
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

# 12. unverifiable 被當成 pass → 沒驗到卻回報通過（**字串與碼都要轉**）。
#   **錨點換掉了，命題沒換。** 舊的兩枚 needle 是 `CAP_STATE` 的初始值與
#   `*) mark=…; [[ "$rc" -eq 0 ]] && rc=3`：前者死在 D5＋impl 刪死碼
#   （cap_verify_node 現在沒有初始值），後者還在，但搬進了 cap_verify_one。
#   現在「字串」與「碼」是在**同一個 case 分支**裡決定的，所以兩半合成一枚：
#   把 `*)` 那一格從「印 unverifiable、rc 設 3」換成「印 ok、rc 設 0」。
#   這與舊的雙 needle 等價：舊的兩個突變合起來也是「unverifiable 變成 pass 且
#   exit 0」，而現在要證明的命題一字未變——**沒有驗到的東西不得被回報成通過**，
#   而且字面與退出碼必須一起轉（自動化只看退出碼）。
mktmpf o12 '            *)    mark="${C_YELLOW}unverifiable${C_RESET}"; [[ "$rc" -eq 0 ]] && rc=3 ;;
'
mktmpf n12 '            *)    mark="${C_GREEN}ok${C_RESET}"; rc=0 ;;   # INJECTED: unverifiable reported as pass
'
if ! mutate "$REPO_ROOT/$MLP" "$SANDBOX/nd-o12" "$SANDBOX/nd-n12" "$SANDBOX/mlp-inj12.sh" 2>"$SANDBOX/i12.err" \
|| ! bash -n "$SANDBOX/mlp-inj12.sh" 2>/dev/null; then
    inj_bad "12. 注入失敗（needle 落空或語法錯）——harness 問題: $(cat "$SANDBOX/i12.err")"
else
    inj_got="$(NODE_JSON='{"name":"t","capabilities":{"wol-sender":{}}}' MLP_FILE="$SANDBOX/mlp-inj12.sh" SANDBOX="$SANDBOX" HOME="$HOME_DIR" \
    PATH="$SHIMS:$PATH" TMPDIR="$SANDBOX/vtmp" FAKE_NODE_DIR="$FAKE_NODE_DIR" \
    RUN_ON_NODE_LOG="$SANDBOX/run_on_node.log" GH_LOG="$GH_LOG" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="$SANDBOX/vshim/pool-resolve"
        run_on_node() { printf "%s\n" "$2" >> "$RUN_ON_NODE_LOG";
                        ( cd "$FAKE_NODE_DIR" && eval "$2" ); }
        ( cmd_verify_capabilities t >"'"$SANDBOX"'/vc12.out" 2>&1 ); printf "%s" "$?"
    ' 2>/dev/null)"
    if [[ "$inj_got" == "0" ]] && ! grep -qF 'unverifiable' "$SANDBOX/vc12.out" 2>/dev/null; then
        inj_ok "12. unverifiable 被回報成 ok＋exit 0（字串與碼一起轉）——5a 會紅"
    elif [[ "$inj_got" == "3" ]] && grep -qF 'unverifiable' "$SANDBOX/vc12.out" 2>/dev/null; then
        inj_bad "12. 突變後仍 unverifiable＋3——注入沒生效"
    else
        inj_bad "12. 突變後 rc=${inj_got} out=[$(tr '\n' '|' < "$SANDBOX/vc12.out" 2>/dev/null | head -c 140)]——不是預期的假通過"
    fi
fi
# 14. 根因針：把「無條件的 unverifiable」改成「無條件的 pass」→ 5n 必須轉紅。
#   **錨點換掉了，命題沒換。** 舊針是改 `CAP_STATE` 的**初始值**；cap_verify_node
#   已經沒有初始值（每一個分支都自己賦值），所以改成做同一件事的另一個形狀：
#   把「沒有單位實作 → unverifiable」那一行變成「沒有單位實作 → pass」。
#   那正是 2026-09-25 qa 的根因形狀——**沒有觀察到任何東西卻回報 true**，
#   而 5n 的新判準（pass 只准出現在 case 分支）應該抓得到。
python3 - "$REPO_ROOT/$MLP" "$SANDBOX/mlp-inj14.sh" <<'INJ14'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
# 「else」分支裡單獨一行、而且是 CAP_STATE 的賦值（不是 case arm、不是 0) 那一種）
hits = [k for k, l in enumerate(lines)
        if re.match(r'^\s{8,}CAP_STATE="unverifiable"\s*$', l)]
assert hits, "no standalone CAP_STATE=unverifiable line"
k = hits[0]
lines[k] = lines[k].replace('CAP_STATE="unverifiable"', 'CAP_STATE="pass"')
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
INJ14
if [[ $? -ne 0 ]]; then
    inj_bad "14. 注入失敗（初始值 needle 落空或語法錯）——harness 問題"
elif ! bash -n "$SANDBOX/mlp-inj14.sh" 2>/dev/null; then
    inj_bad "14. 突變版語法錯誤——harness 問題"
else
    inj_init="$(python3 - "$SANDBOX/mlp-inj14.sh" <<'PY14CHK'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
bad = []
for k, l in enumerate(lines, 1):
    if "CAP_STATE=\"pass\"" in l and not re.match(r'^\s*\S+\)\s*CAP_STATE="pass"', l):
        bad.append("line %d assigns pass outside a case arm" % k)
print("; ".join(bad))
PY14CHK
)"
    if [[ -n "$inj_init" ]]; then
        inj_ok "14. 把無條件的 unverifiable 改成 pass 之後 5n 會紅（got [${inj_init}]）——根因被釘住"
    else
        inj_bad "14. 無條件的 pass 之後 5n 仍綠——注入沒生效"
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
