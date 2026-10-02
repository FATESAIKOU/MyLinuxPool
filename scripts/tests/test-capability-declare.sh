#!/usr/bin/env bash
# test-capability-declare.sh — PR-B tasks 2.1（pool-sync 的宣告路徑）＋ tasks 1.2b。
#
#
# 前提：PR-A 的 runner（scripts/lib/capability.sh）與三個單位已存在。
# 沙箱裡用 MLP_REPO_ROOT 指向工作樹就能先跑。
#
# 手法沿用 test-pool-sync.sh：假 git 把 FAKE_FIXTURE 當成「clone 出來的 repo」，
# 假 gh 記錄 argv 與寫入 payload。差別是這支的假單位 install.sh --check 會回
# 0／1／2（D2 的三態），由 FAKE_CAP_RC_<UNIT> 控制。
set -uo pipefail
REPO_ROOT="${MLP_CAPABILITY_TEST_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"
POOL_SYNC="$REPO_ROOT/shared-configs/pool-runtime/files/pool-sync"
RUNNER="$REPO_ROOT/scripts/lib/capability.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-capability-declare.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
FAKEBIN="$SANDBOX/fakebin"; FIXTURE="$SANDBOX/fixture"
mkdir -p "$FAKEBIN" "$FIXTURE" "$SANDBOX/home"

pass=0; fail=0; injpass=0; injfail=0
ok()   { pass=$((pass+1));   printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1));   printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

NODE_VALUE='{"name":"fh-test","role":"provider","registered_with":"register-provider.sh","gateway_port":2401,"hops":[{"via":"gateway"}],"power":{"launch":{"via":["relay"],"mac":"aa:bb:cc:dd:ee:ff"}},"capabilities":{"worker-host":{"runtime":"docker"}}}'

# ---- 假件 ---------------------------------------------------------------
# 假 git：任何呼叫都把 FAKE_FIXTURE 當成 clone 出來的 repo 複製到 dest。
cat > "$FAKEBIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
dest=""
for a in "$@"; do dest="$a"; done
case "$dest" in /*) ;; *) dest="${PWD}/${dest}" ;; esac
printf 'git %s\n' "$*" >> "${GIT_LOG:-/dev/null}"
mkdir -p "$dest"
cp -R "${FAKE_FIXTURE}/." "$dest/"
FAKE_GIT

# 假 gh：記錄每一行 argv（workflow run 的次數就從這裡數），讀寫 NODE_* var。
# 寫入會真的存進 VAR_STORE，之後的讀取看得見——「零寫入」才量得準。
#
# stdin 只讀一次：第一個 $(cat) 抽乾之後，後面每一個讀 var 的步驟都讀到空值。
cat > "$FAKEBIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "${GH_LOG:?}"
if [[ "${1:-}" == "variable" && "${2:-}" == "set" ]]; then
    name=""; prev=""
    for a in "$@"; do [[ "$prev" == "NAME" || "$prev" == "NAME=" ]] && name="$a"; prev="$a"; done
    [[ -z "$name" ]] && for a in "$@"; do case "$a" in NODE_*) name="$a" ;; esac; done
    body="$(cat)"
    printf 'PAYLOAD|%s|%s\n' "$name" "$body" >> "${GH_PAYLOAD_LOG:?}"
    printf '%s' "$body" > "${VAR_STORE:?}/${name}"
    exit 0
fi
name=""; filter=""; prev=""; list=0
for a in "$@"; do
    case "$a" in *variables?per_page*) list=1 ;; esac
    [[ "$prev" == "--jq" ]] && filter="$a"
    case "$a" in *actions/variables/*) name="${a##*/}"; name="${name%%\?*}" ;; esac
    prev="$a"
done
if [[ "$list" -eq 1 ]]; then
    out=""
    for f in "${VAR_STORE:?}"/*; do
        [[ -f "$f" ]] || continue
        out="${out}$(jq -c -n --arg n "$(basename "$f")" --arg v "$(cat "$f")" '{variables:[{name:$n,value:$v}]}')"
    done
    all="$(printf '%s' "$out" | jq -sc '{variables: (map(.variables[]) )}')"
    if [[ -n "$filter" ]]; then printf '%s' "$all" | jq -r "$filter"; else printf '%s\n' "$all"; fi
    exit 0
fi
if [[ -n "$name" && -f "${VAR_STORE:?}/${name}" ]]; then
    # 信封 {name,value}：真實 gh 的單一 var 讀取就是這個形狀，--jq .value 才有作用。
    # 之前這裡直接吐裸值，於是呼叫端 `gh api … --jq .value` 拿到空字串。
    obj="$(jq -c -n --arg n "$name" --arg v "$(cat "${VAR_STORE}/${name}")" '{name:$n,value:$v}')"
    if [[ -n "$filter" ]]; then printf '%s' "$obj" | jq -r "$filter"; else printf '%s\n' "$obj"; fi
    exit 0
fi
printf 'gh: HTTP 404: Not Found (variable %s)\n' "$name" >&2
exit 1
FAKE_GH

# 假 systemctl / ssh / docker：pool-sync 會碰到它們，但本檔不驗證那些行為。
cat > "$FAKEBIN/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
exit 0
SH
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "${SSH_LOG:-/dev/null}"
exit 0
SH
cat > "$FAKEBIN/docker" <<'SH'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${DOCKER_LOG:-/dev/null}"
exit 0
SH
chmod +x "$FAKEBIN"/*

# 變數名由能力鍵推導；寫死成一個沒人設定的變數，2.1c／2.1d 量到的都是 rc 恆 0。
make_unit() {  # make_unit <目錄名> <能力鍵> [needs_root]
    local name="$1" key="$2" d="$FIXTURE/shared-configs/$1" rc_var
    rc_var="FAKE_CAP_RC_$(printf '%s' "$key" | tr 'a-z-' 'A-Z_')"
    mkdir -p "$d/files"
    printf '{"name":"%s","description":"fake %s","needs_key":false,"needs_root":%s,"provides":[],"capability":"%s"}\n' \
        "$name" "$name" "${3:-false}" "$key" > "$d/unit.json"
    cat > "$d/install.sh" <<UNITINSTALL
#!/usr/bin/env bash
printf 'argv=%s\n' "\$*" >> "\${UNIT_LOG:?}"
printf 'params=%s\n' "\${MLP_CAPABILITY_PARAMS:-<unset>}" >> "\${UNIT_LOG:?}"
# 安裝路徑必須回 0：收斂迴圈把 --check 非 0 當漂移，安裝也非 0 就整個 tick 死掉。
case " \$* " in
    *" --check "*) exit "\${${rc_var}:-0}" ;;
esac
printf 'install %s\n' "\$*" >> "\${INSTALL_LOG:-/dev/null}"
exit 0
UNITINSTALL
    chmod +x "$d/install.sh"
}

# ---- fixture：provider 的 profile 與兩個單位 -----------------------------
# wolk：needs_root=true 的單位（2.1g 要驗證它照樣被驗證、但不被安裝）
make_unit wolk wolk false true   # 鍵必須和 profile 宣告的一致，否則「宣告了卻沒單位實作」
make_unit plaincap plain-cap false false
mkdir -p "$FIXTURE/profiles/provider/default"
cat > "$FIXTURE/profiles/provider/default/profile.json" <<'PROF'
{
  "role": "provider",
  "shared_config": ["wolk", "plaincap"],
  "capabilities": {
    "wolk": {"methods": ["unicast"]},
    "plain-cap": {"level": 1}
  }
}
PROF

# pool-sync 是從**它自己 clone 出來的那份 repo** 取 scripts/lib（:366、:207、
# :295、:422）。缺檔時它**只記 WARN 就跳過那一段**——於是「沒有 dispatch」變成
# 假的（沒有東西會 dispatch）、「宣告沒寫」也分不清是產品沒做還是夾具缺檔。
# 這裡列的是 pool-sync 真的會去找的路徑（含 PR-B 新增的宣告路徑那一條），
# 而且**缺檔要報錯**：先前這裡是 `if [[ -f ]] then cp` 的靜靜跳過，於是
# scripts/refresh-authkeys.sh（在 scripts/，不在 scripts/lib/）與
# scripts/lib/capability.sh 兩個真正需要的檔都沒進 fixture，而測試只會報
# 「PR-B 還沒寫」。
#
# 路徑是照 repo 的真實位置寫的，不是照 pool-sync 裡的字串：把
# refresh-authkeys.sh 寫成 scripts/lib/refresh-authkeys.sh 的時候，
# 整段 authorized_keys 收斂靜靜跳過，這條測試照樣全綠。
CLONE_LIBS="scripts/lib/tunnel-key.sh scripts/lib/authkeys.sh scripts/lib/log.sh
scripts/lib/capability.sh scripts/refresh-authkeys.sh"
for f in $CLONE_LIBS; do
    mkdir -p "$FIXTURE/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$FIXTURE/$f"
done
mkdir -p "$FIXTURE/shared-configs/pool-runtime/files"
cp "$REPO_ROOT/shared-configs/pool-runtime/files/tunnel-identity.sh" \
   "$FIXTURE/shared-configs/pool-runtime/files/tunnel-identity.sh" 2>/dev/null || true

VAR_STORE="$SANDBOX/vars"; mkdir -p "$VAR_STORE"
UNIT_LOG="$SANDBOX/unit.log"; INSTALL_LOG="$SANDBOX/install.log"
GH_LOG="$SANDBOX/gh.log"; GH_PAYLOAD_LOG="$SANDBOX/gh-payload.log"
GIT_LOG="$SANDBOX/git.log"; SYSTEMCTL_LOG="$SANDBOX/systemctl.log"
SSH_LOG="$SANDBOX/ssh.log"; DOCKER_LOG="$SANDBOX/docker.log"

# ---- 跑一次 pool-sync ----------------------------------------------------
SYNC_RC=0; RAN=0; TICK_REACHED=0; PRE_CAPS='{}'; PRE_KEY='"<none>"'
# run_sync [節點名] [額外環境…]
run_sync() {
    local node="$1"; shift
    : > "$GH_LOG"; : > "$GH_PAYLOAD_LOG"; : > "$UNIT_LOG"
    : > "$INSTALL_LOG"; : > "$GIT_LOG"; : > "$SYSTEMCTL_LOG"; : > "$SSH_LOG"
    rm -rf "$SANDBOX/tmpdir"; mkdir -p "$SANDBOX/tmpdir"
    # pool-sync 開頭就要這兩個：沒有就 exit 1，後面所有量測都會是假綠。
    mkdir -p "$SANDBOX/home/.mylinuxpool"
    printf 'NODE_NAME=%s\n' "$node" > "$SANDBOX/home/.mylinuxpool/config"
    [[ -n "${KEEP_TOKEN:-}" ]] || printf 'ghp_FAKE_TOKEN_not_a_real_credential\n' > "$SANDBOX/home/.mylinuxpool/gh_token"
# SEED_VAR_JSON：沒有它，2.1b2／2.1d 種進去的值會被自己蓋掉。
    if [[ -n "${SEED_VAR_JSON:-}" ]]; then
        printf '%s' "$SEED_VAR_JSON" | jq -c --arg n "$node" '.name = $n' \
            > "$VAR_STORE/NODE_$(printf '%s' "$node" | tr 'a-z-' 'A-Z_')"
    else
        printf '%s' "$NODE_VALUE" | jq -c --arg n "$node" '.name = $n' \
            > "$VAR_STORE/NODE_$(printf '%s' "$node" | tr 'a-z-' 'A-Z_')"
    fi
    # SEED_KEY_PUB：把已落地的金鑰公鑰種進 var，金鑰路徑於是不寫、不 dispatch。
    if [[ -n "${SEED_KEY_PUB:-}" ]]; then
        jq -c --arg pk "$SEED_KEY_PUB" '.tunnel_public_key = $pk' \
            "$VAR_STORE/NODE_$(printf '%s' "$node" | tr 'a-z-' 'A-Z_')" \
            > "$VAR_STORE/NODE_$(printf '%s' "$node" | tr 'a-z-' 'A-Z_')".tmp \
            && mv "$VAR_STORE/NODE_$(printf '%s' "$node" | tr 'a-z-' 'A-Z_')".tmp \
                   "$VAR_STORE/NODE_$(printf '%s' "$node" | tr 'a-z-' 'A-Z_')"
    fi
    PRE_CAPS="$(jq -c '.capabilities // {}' \
        "$VAR_STORE/NODE_$(printf '%s' "$node" | tr 'a-z-' 'A-Z_')" 2>/dev/null || echo '{}')"
    PRE_KEY="$(jq -c '.tunnel_public_key // "<none>"' \
        "$VAR_STORE/NODE_$(printf '%s' "$node" | tr 'a-z-' 'A-Z_')" 2>/dev/null || echo '"<none>"')"
    SYNC_RC=0; RAN=0
    # POOL_SYNC_SUBJECT：注入用的突變版 pool-sync（INJ-C）。沒有這個參數時
    #   跑的是被測物本身——而 INJ-C 原本就是這樣：突變版寫出來了卻從來沒被
    #   執行過，那一條注入等於一直在量未突變的程式碼。
    local sync_bin="${POOL_SYNC_SUBJECT:-$POOL_SYNC}"
    if [[ ! -x "$sync_bin" ]]; then
        SYNC_RC=127; printf 'pool-sync missing\n' > "$SANDBOX/err"; : > "$SANDBOX/out"; return
    fi
    RAN=1
    env HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmpdir" PATH="$FAKEBIN:$PATH" \
        POOL_REPO="testowner/testrepo" POOL_BRANCH="master" \
        TUNNEL_KEY_REPO_DIR="$REPO_ROOT" \
        FAKE_FIXTURE="$FIXTURE" VAR_STORE="$VAR_STORE" \
        GH_LOG="$GH_LOG" GH_PAYLOAD_LOG="$GH_PAYLOAD_LOG" UNIT_LOG="$UNIT_LOG" \
        INSTALL_LOG="$INSTALL_LOG" GIT_LOG="$GIT_LOG" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        SSH_LOG="$SSH_LOG" DOCKER_LOG="$DOCKER_LOG" \
        POOL_SWEEP_MIN_AGE=900 "$@" \
        bash "$sync_bin" > "$SANDBOX/out" 2> "$SANDBOX/err" </dev/null
    SYNC_RC=$?
    cat "$SANDBOX/out" "$SANDBOX/err" > "$SANDBOX/combined"
    # PRB_DEBUG=1：把這一輪的每一筆寫入 payload 與每一次 workflow 呼叫列出來。
    # 2.1a／2.1h／INJ-C 三條互相矛盾時，靠這個判斷是 harness 還是產品的問題。
    if [[ -n "${PRB_DEBUG:-}" ]]; then
        printf '\n--- [debug] 這一輪的寫入（payload 帳本，%s 筆）---\n' "$(grep -c '^PAYLOAD|NODE_' "$GH_PAYLOAD_LOG" 2>/dev/null || echo 0)"
        grep -n '^PAYLOAD|NODE_' "$GH_PAYLOAD_LOG" 2>/dev/null | sed 's/^/  [debug] /' || printf '  [debug] （無）\n'
        printf -- '--- [debug] workflow run %s 次 ---\n' "$(grep -c 'workflow run' "$GH_LOG" 2>/dev/null || echo 0)"
        grep -n 'workflow run' "$GH_LOG" 2>/dev/null | sed 's/^/  [debug] /' || printf '  [debug] （無）\n'
        printf -- '--- [debug] 單位的 --check（帶參數的才是宣告路徑）---\n'
        cat "$UNIT_LOG" 2>/dev/null | sed 's/^/  [debug] /' || printf '  [debug] （無）\n'
        printf -- '--- [debug] var store 現況 ---\n'
        for f in "$VAR_STORE"/NODE_*; do printf '  [debug] %s = %s\n' "$(basename "$f")" "$(cat "$f")"; done
    fi
    TICK_REACHED=0
    grep -q "profile '" "$SANDBOX/combined" && TICK_REACHED=1
}

# ---- 觀察 helpers -------------------------------------------------------
decl_writes() { grep -c '^PAYLOAD|NODE_' "$GH_PAYLOAD_LOG" 2>/dev/null || true; }
# 宣告寫入＝「capabilities 變了而且沒動 tunnel_public_key」；兩個條件都要，否則金鑰那筆會被算成第 2 次。
decl_write_payloads() {   # decl_write_payloads <寫入前的 capabilities> <寫入前的 tunnel_public_key>
    local pre="$1" pre_key="$2" line caps key
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        caps="$(printf '%s' "${line#PAYLOAD|*|}" | jq -c '.capabilities // {}' 2>/dev/null)" || continue
        [[ "$caps" == "$pre" ]] && continue
        key="$(printf '%s' "${line#PAYLOAD|*|}" | jq -c '.tunnel_public_key // "<none>"' 2>/dev/null)"
        [[ "$key" != "$pre_key" ]] && continue
        printf '%s\n' "${line#PAYLOAD|*|}"
    done < <(grep '^PAYLOAD|NODE_' "$GH_PAYLOAD_LOG" 2>/dev/null)
}
decl_writes_that_change_caps() {
    decl_write_payloads "$1" "$PRE_KEY" | grep -c . || true
}
# 只看「這一筆有沒有動金鑰欄位」——**不過濾 capabilities 沒變的寫入**（review §5）。
# 為什麼需要它：2.1b2 要證的是 spec.md:38 的「宣告相同時 MUST NOT 寫入」，
# 而舊的探針把 capabilities 沒變的寫入丟掉——於是「寫了，但寫的是同一份」對它隱形。
# 實測過：把 pool-sync 的比較條件改成永遠不成立之後，舊的 2.1b2 照樣報 ok。
decl_writes_that_left_the_key_alone() {
    local line key n=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        key="$(printf '%s' "${line#PAYLOAD|*|}" | jq -c '.tunnel_public_key // "<none>"' 2>/dev/null)"
        [[ "$key" != "$PRE_KEY" ]] || n=$((n + 1))
    done < <(grep '^PAYLOAD|NODE_' "$GH_PAYLOAD_LOG" 2>/dev/null)
    printf '%s' "$n"
}
workflow_runs() { grep -c 'workflow run' "$GH_LOG" 2>/dev/null || true; }
wol_installs() { grep -c '^install ' "$INSTALL_LOG" 2>/dev/null || true; }
# 經 runner 的宣告路徑才會帶 MLP_CAPABILITY_PARAMS；收斂迴圈是直接叫 install.sh --check。
wol_checks_with_params() { grep -c '^params={' "$UNIT_LOG" 2>/dev/null || true; }
# 只看**帶參數**的那一行：log 裡第一行 `params=<unset>` 是收斂迴圈的呼叫
# （pool-sync:185 直接叫 install.sh --check，不經 runner）。取 head -1 會拿到
# 那一行，於是 2.1i 報「沒有收到參數」、2.1f 的訊息印 params=<unset>——
# 兩個都在講收斂迴圈，不是宣告路徑。
wol_params() { grep '^params={' "$UNIT_LOG" 2>/dev/null | head -1; }
# pool-sync 有沒有真的走到宣告那一段（PR-B 之前永遠是 0）。
decl_attempted() { grep -qiE 'capabilit' "$SANDBOX/combined" 2>/dev/null; }
stored_caps() {
    local f="$VAR_STORE/NODE_$1"
    [[ -f "$f" ]] && jq -c '.capabilities // "MISSING"' "$f" || printf 'NOFILE'
}

if [[ ! -r "$RUNNER" ]]; then
    bad "前提：缺 ${RUNNER}（PR-A 的 runner）——這支測試的 2.1 全部建立在它之上"
fi
if [[ ! -x "$POOL_SYNC" ]]; then
    bad "前提：shared-configs/pool-runtime/files/pool-sync 不可執行"
fi
# 夾具健全性：假的 fetched repo 必須真的帶齊 pool-sync 會去找的每一個檔。
# 缺一個，pool-sync 就只記一句 WARN 跳過那一段——於是 2.1i（params=<unset>）
# 與 2.1f（帶參數的 --check 0 次）報的是「夾具缺檔」，不是產品的問題。
# 這條把那個歧義釘死：夾具齊了之後，這些紅燈才可以被讀成產品的現況。
fixture_missing=""
for f in $CLONE_LIBS; do
    [[ -f "$FIXTURE/$f" ]] || fixture_missing="${fixture_missing} ${f}"
done
if [[ -n "$fixture_missing" ]]; then
    bad "前提：假的 fetched repo 缺${fixture_missing}——pool-sync 會靜靜跳過那一段（harness 問題）"
else
    ok "前提：假的 fetched repo 帶齊 pool-sync 會找的 $(printf '%s\n' $CLONE_LIBS | grep -c .) 個檔（含宣告路徑的 scripts/lib/capability.sh）"
fi

echo "=== 2.1 pool-sync 的宣告路徑 ==="

# 2.1a 同時是 2.1b 的正對照（同一個 fixture、同一個計數器）。
run_sync fh-test
A_WRITES="$(decl_writes_that_change_caps "$PRE_CAPS")"
A_CAPS="$(stored_caps FH_TEST)"
A_WF="$(workflow_runs)"
# 取**宣告那一筆**（不是最後一筆，也不是第一筆）：一個 tick 裡有兩個寫入者
# ——宣告路徑與隧道金鑰路徑——而只有前者動 capabilities。計數器的定義見
# decl_write_payloads。
A_PAYLOAD="$(decl_write_payloads "$PRE_CAPS" "$PRE_KEY" | head -1)"
if [[ "$A_WRITES" -eq 0 ]]; then
    bad "2.1a. 宣告與 var 不同（var 有 worker-host、profile 宣告 wolk＋plain-cap），pool-sync 一次都沒寫（rc=${SYNC_RC}）——PR-B 的宣告路徑還沒寫"
elif [[ "$A_WRITES" -ne 1 ]]; then
    bad "2.1a. 應該恰好寫 1 次，卻寫了 ${A_WRITES}次"
else
    ok "2.1a. 宣告與 var 不同 → 恰好寫入 1 次"
fi

# 這一輪金鑰路徑在磁碟上產了 id_tunnel；**公鑰從磁碟讀**（不是從 var store 讀），
# 照 test-pool-sync.sh 的 Q4：TUNNEL_PUB_FILE="$SANDBOX/home/.ssh/id_tunnel.pub"。
# 2.1h 要用它把金鑰路徑隔離開。
TUNNEL_PUB_FILE="$SANDBOX/home/.ssh/id_tunnel.pub"
KEY_PUB="$(cat "$TUNNEL_PUB_FILE" 2>/dev/null | tr -d '\r\n')"

# 只 merge capabilities：payload 裡其他欄位必須與原值 byte 相同。
if [[ -z "$A_PAYLOAD" ]]; then
    bad "2.1b. 沒有寫入 payload，無法驗證『只 merge capabilities』"
else
    # jq **不**加 -r 的話印出來的是帶引號的 "same"，跟 [[ == same ]] 永遠不相等——
    # 這一條從落地以來就一直是「壞的紅」：它回報 differs 的那幾次，實際上
    # 兩邊是相同的（payload 只動 capabilities 那一欄）。
    same_other="$(jq -nr --argjson orig "$NODE_VALUE" --argjson new "$A_PAYLOAD" \
        'if (($orig|del(.capabilities)) == ($new|del(.capabilities))) then "same" else "differs" end')"
    if [[ "$same_other" == "same" ]]; then
        ok "2.1b. 寫入的 payload 除了 capabilities 以外，其他欄位與原值完全相同（只 merge 這一欄）"
    else
        bad "2.1b. 寫入時動到了 capabilities 以外的欄位（${same_other}）"
    fi
fi

# 2.1b2：宣告已經一致 → 零寫入。正對照就是 2.1a 的 ≥1。
if [[ "$A_WRITES" -lt 1 ]]; then
    bad "2.1b2. 對照組失效：2.1a 沒有寫入過，所以「零寫入」不算證明"
else
    SEED_VAR_JSON="$A_PAYLOAD" run_sync fh-test
    # 探針是「有沒有動金鑰欄位」，不是「capabilities 有沒有變」——後者會把
    # 「寫了同一份」當成沒寫（review §5 的假綠）。
    B_WRITES="$(decl_writes_that_left_the_key_alone)"
    if [[ "$B_WRITES" -eq 0 ]]; then
        ok "2.1b2. 宣告已一致 → 零寫入（對照組 2.1a 寫了 ${A_WRITES}次，探針看得見寫入）"
    else
        bad "2.1b2. 宣告已一致卻又寫了 ${B_WRITES}次——每次 tick 都會動主本"
    fi
fi

# 2.1a-keyorder：寫回去的 payload **鍵序要跟原來一樣**（review §1.2）。
#   值一個都不變是 2.1b 在管的；這裡管的是**排列順序**——pool-sync 用 `jq -Sc`
#   會把整份 var 重新排序，於是 merge 之後 name／role／user 的位置全變了：
#   JSON 語意上無害，但與 pool-sync 自己另一處寫入（tunnel-key.sh 的
#   `jq -c '. + {tunnel_public_key: …}'`，**不排序**）風格不一致，而且人工
#   diff／git diff 會看到一大片鍵序 churn。
#   比較方式：兩個物件的 keys_unsorted 序列必須完全一樣。
key_order_now="$(printf '%s' "$A_PAYLOAD" | jq -r 'keys_unsorted | join(",")' 2>/dev/null)"
key_order_want="$(printf '%s' "$NODE_VALUE" | jq -r 'keys_unsorted | join(",")' 2>/dev/null)"
if [[ -z "$A_PAYLOAD" ]]; then
    bad "2.1a-keyorder. 沒有寫入 payload，無法驗證鍵序"
elif [[ "$key_order_now" == "$key_order_want" ]]; then
    ok "2.1a-keyorder. 寫回去的 var 鍵序與原來一致（沒有被重新排序）"
else
    bad "2.1a-keyorder. 寫回去之後鍵序被重排了（寫入=${key_order_now} / 原=${key_order_want}）——整份 var 會 churn"
fi

run_sync fh-test FAKE_CAP_RC_PLAIN_CAP=1
C_CAPS="$(stored_caps FH_TEST)"
if printf '%s' "$C_CAPS" | grep -q 'plain-cap'; then
    bad "2.1c. plain-cap 的 --check 回 1（確定不成立），宣告裡還在（${C_CAPS}）"
elif printf '%s' "$C_CAPS" | grep -q 'wolk'; then
    ok "2.1c. 結果 1 的能力從宣告裡拿掉（wolk 保留），宣告=[${C_CAPS}]"
else
    bad "2.1c. 結果 1 的能力拿掉了，但連 wolk 也不見（${C_CAPS}）——應該只拿掉那一個"
fi
if grep -qiE 'plain-cap' "$SANDBOX/combined" && grep -qiE 'WARN|警告|不成立' "$SANDBOX/combined"; then
    ok "2.1c. 結果 1 有記警告並指名 plain-cap"
else
    bad "2.1c. 沒有指名 plain-cap 的警告（combined 尾段：$(tail -3 "$SANDBOX/combined" | tr '\n' ' ' | head -c 160)）"
fi

# 2.1d：要量的是「保留原值」而不是「重新推導」，兩者分得開才有意義。
D_SEED="$(printf '%s' "$NODE_VALUE" | jq -c '.capabilities = {"plain-cap":{"level":7}}')"
SEED_VAR_JSON="$D_SEED" run_sync fh-test FAKE_CAP_RC_PLAIN_CAP=2
D_CAPS="$(stored_caps FH_TEST)"
D_LEVEL="$(printf '%s' "$D_CAPS" | jq -r '.["plain-cap"].level // "none"' 2>/dev/null || echo parse-failed)"
if [[ "$D_LEVEL" == "7" ]]; then
    ok "2.1d. 結果 2（無法確認）→ 保留原值 {\"level\":7}，沒有被 profile 的參數覆蓋"
elif [[ "$D_LEVEL" == "1" ]]; then
    bad "2.1d. 結果 2 卻把宣告覆蓋成 profile 的參數（level=1）——2 的語意是保留原值"
else
    bad "2.1d. 結果 2 之後 plain-cap 變成 [${D_CAPS}]（level=${D_LEVEL}）——應該原樣保留 level 7"
fi

run_sync fh-test FAKE_CAP_RC_PLAIN_CAP=0
E_CAPS="$(stored_caps FH_TEST)"
if printf '%s' "$E_CAPS" | grep -q 'plain-cap'; then
    ok "2.1e. 能力恢復後重新出現在宣告裡（[${E_CAPS}]）"
else
    bad "2.1e. 恢復後宣告裡沒有 plain-cap（[${E_CAPS}]）"
fi

#   「有帶參數的 --check」才是宣告路徑的證據——收斂迴圈本來就會直接叫 --check，
#   那不算數（它本來就跳過 needs_root）。
run_sync fh-test
F_CHECKS="$(wol_checks_with_params)"
F_INSTALLS="$(wol_installs)"
F_PARAMS="$(wol_params)"
if [[ "$F_CHECKS" -ge 1 ]]; then
    ok "2.1f. needs_root 的 wolk 照樣被宣告路徑驗證（${F_CHECKS}次帶參數的 --check，${F_PARAMS}）"
else
    bad "2.1f. needs_root 的 wolk 沒有被宣告路徑驗證（帶參數的 --check 0 次；最多只有收斂迴圈那種不帶參數的）"
fi
if [[ "$TICK_REACHED" -ne 1 ]]; then
    bad "2.1f. pool-sync 沒跑完一次 tick（rc=${SYNC_RC}），install 0 次不算證明——harness 問題"
elif [[ "$F_INSTALLS" -eq 0 ]]; then
    ok "2.1f. needs_root 的 wolk 沒有被安裝（install 0 次）"
else
    bad "2.1f. needs_root 的 wolk 被安裝了 ${F_INSTALLS}次——pool-sync 沒有 root"
fi

#   前提是「pool-sync 真的有宣告那一段」——PR-B 之前它會假綠（沒有宣告步驟，
#   tick 當然不會因此失敗）。
run_sync fh-test GH_MODE=missing
if ! decl_attempted; then
    bad "2.1g. 前提不成立：pool-sync 沒有宣告那一段（log 裡沒提到 capability），所以「tick 沒被拖垮」不算證明"
elif [[ "$SYNC_RC" -eq 0 ]]; then
    ok "2.1g. 宣告步驟失敗（var 讀不到）時 tick 仍然回 0"
else
    bad "2.1g. 宣告步驟失敗讓整個 tick 回 ${SYNC_RC}——一格壞掉不該拖垮收斂"
fi

#   兩件事缺一不可：
#   (1) 前提——這一輪**真的寫入了帶 capabilities 的 payload**。沒有寫入時，
#       「0 次 workflow run」只是因為什麼都沒發生，不是因為宣告不 dispatch。
#   (2) 隔離——金鑰路徑**不能**在這一輪也寫：它本來就該 dispatch，混進來就
#       分不清是誰觸發的。所以把已落地的金鑰公鑰種進 var，讓金鑰路徑看到已一致就不寫。
H_KEY_SEEDED=0
if [[ -n "${KEY_PUB:-}" ]]; then
    SEED_KEY_PUB="$KEY_PUB" run_sync fh-test
    H_KEY_SEEDED=1
else
    run_sync fh-test
fi
H_WF="$(workflow_runs)"
H_DECL="$(decl_writes_that_change_caps "$PRE_CAPS")"
if [[ "$TICK_REACHED" -ne 1 ]]; then
    bad "2.1h. pool-sync 沒跑完一次 tick（rc=${SYNC_RC}）——harness 問題"
elif [[ "$H_KEY_SEEDED" -ne 1 ]]; then
    bad "2.1h. 拿不到已落地的金鑰公鑰，無法把金鑰路徑隔離開——這一輪的 dispatch 無法歸因（harness 問題）"
elif [[ "$H_DECL" -lt 1 ]]; then
    bad "2.1h. 這一輪沒有寫入任何帶 capabilities 的 payload（${H_DECL} 筆）——workflow run ${H_WF} 次不算證明"
elif [[ "$H_WF" -eq 0 ]]; then
    ok "2.1h. 寫入宣告（${H_DECL} 筆）時 gh workflow run 0 次，且金鑰路徑已隔離——宣告不是事件，不該 dispatch refresh"
else
    bad "2.1h. 寫入宣告時觸發了 ${H_WF} 次 workflow run（金鑰路徑已隔離）——那會把 refresh 的頻率拉回 #7 那個樣子"
fi

#   沒有這一格，2.1h 的「0 次」可能只是探針壞掉。
run_sync fh-test
PC_WF="$(workflow_runs)"
if [[ "$PC_WF" -ge 1 ]]; then
    ok "2.1h-pc. 正對照：金鑰路徑真的寫入那一輪，探針看到 ${PC_WF} 次 workflow run——2.1h 的 0 次有意義"
else
    bad "2.1h-pc. 金鑰路徑寫入了，探針卻數到 0 次 workflow run——探針壞掉，2.1h 的 0 次不算證明"
fi

if [[ "$F_PARAMS" == params=*'{'* ]]; then
    ok "2.1i. 單位的 --check 真的收到 MLP_CAPABILITY_PARAMS（${F_PARAMS}）"
else
    bad "2.1i. 單位的 --check 沒有收到參數（got [${F_PARAMS}]）——pool-sync 沒有把 profile 的參數接給 runner"
fi

echo "=== 1.2b（自 PR-A 移回來，PR-B 才是它的時候） ==="

# 1.2b：消費端不得再寫死能力鍵。掃的是 case 分支裡的字面值。
hard=""
for f in ops-scripts/mlp ops-scripts/register-provider.sh \
         shared-configs/pool-runtime/files/pool-sync scripts/create-worker.sh; do
    [[ -f "$f" ]] || continue
    n="$(grep -cE '^\s*(worker-host|github|wol)\)' "$f" 2>/dev/null || true)"
    [[ "$n" == "0" ]] || hard="${hard} ${f}(${n})"
done
if [[ -z "$hard" ]]; then
    ok "1.2b. 消費端沒有寫死能力鍵（新增能力不必改它們）"
else
    bad "1.2b. 這些檔案還有寫死能力鍵的 case 分支：${hard}"
fi


echo "=== 注入 ==="

# INJ-A：needle 由 make_unit 現算，不要手寫一份會漂的字串。
#   needle 由 make_unit 產生（rc 變數名是照能力鍵推導的），所以這裡現算，
#   不要手寫一份會跟 make_unit 漂移的字串。
INJA_RC_LINE="$(printf 'exit "${FAKE_CAP_RC_PLAIN_CAP:-0}"')"
python3 - "$FIXTURE/shared-configs/plaincap/install.sh" "$SANDBOX/injA-install.sh" "$INJA_RC_LINE" <<'INJA'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
old = sys.argv[3]
assert s.count(old) == 1, "rc line count=%d" % s.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(old, "exit 0", 1))
INJA
if [[ $? -ne 0 ]]; then
    inj_bad "INJ-A. 突變腳本失敗（假單位的回碼那一行形狀變了）——harness 問題"
elif ! bash -n "$SANDBOX/injA-install.sh" 2>/dev/null; then
    inj_bad "INJ-A. 突變版語法錯誤——harness 問題"
else
    cp "$FIXTURE/shared-configs/plaincap/install.sh" "$SANDBOX/install.sh.orig"
    cp "$SANDBOX/injA-install.sh" "$FIXTURE/shared-configs/plaincap/install.sh"
    chmod +x "$FIXTURE/shared-configs/plaincap/install.sh"
    SEED_VAR_JSON="$D_SEED" run_sync fh-test FAKE_CAP_RC_PLAIN_CAP=2
    INJA_CAPS="$(stored_caps FH_TEST)"
    cp "$SANDBOX/install.sh.orig" "$FIXTURE/shared-configs/plaincap/install.sh"
    chmod +x "$FIXTURE/shared-configs/plaincap/install.sh"
    if printf '%s' "$INJA_CAPS" | jq -e '.["plain-cap"].level == 1' >/dev/null 2>&1; then
        inj_ok "INJ-A. 假單位一律回 0 之後 2.1d 的「保留原值」被推翻（level 變成 1）——2.1d 有在看單位的回碼"
    else
        inj_bad "INJ-A. 假單位改成永遠回 0，2.1d 仍保留 level 7（${INJA_CAPS}）——2.1d 不是在看單位的回碼"
    fi
fi

# INJ-B：探針自測——連寫入都記不到時，「零寫入」不算證明。
#   **這一條以前從來沒有真的注入過**（突變版寫出來了卻沒有裝到 $FAKEBIN/gh 上），
#   所以它的訊息是過度宣稱。現在真的換上去、真的跑、量的是 **2.1b2 用的那一個**
#   探針（decl_writes_that_left_the_key_alone），跑完換回來。
python3 - "$FAKEBIN/gh" "$SANDBOX/injB-gh" <<'INJB'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
old = "printf 'PAYLOAD|%s|%s\\n'"
assert s.count(old) == 1, "payload needle count=%d" % s.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(old, "printf 'PAYLOAD-MUTED|%s|%s\\n'", 1))
INJB
if [[ $? -ne 0 ]]; then
    inj_bad "INJ-B. 突變腳本失敗（假 gh 的 payload 記錄那一行形狀變了）——harness 問題"
elif ! bash -n "$SANDBOX/injB-gh" 2>/dev/null; then
    inj_bad "INJ-B. 突變版語法錯誤——harness 問題"
else
    # 兩個計數都要量，且是**同一個情境**的兩次跑：先未突變（必須看得到寫入），
    # 再突變（必須看不到）。只量突變那一次是證明不了探針的——它壞掉與否兩次都一樣。
    cp "$FAKEBIN/gh" "$SANDBOX/gh.orig"
    SEED_JSON_INJB="$(printf '%s' "$NODE_VALUE" | jq -c '.capabilities = {}')"
    SEED_VAR_JSON="$SEED_JSON_INJB" run_sync fh-test
    INJB_RAW="$(decl_writes)"
    INJB_OK="$(decl_writes_that_left_the_key_alone)"
    cp "$SANDBOX/injB-gh" "$FAKEBIN/gh"; chmod +x "$FAKEBIN/gh"
    SEED_VAR_JSON="$SEED_JSON_INJB" run_sync fh-test
    INJB_MUT="$(decl_writes)"
    INJB_MUT_KEY="$(decl_writes_that_left_the_key_alone)"
    cp "$SANDBOX/gh.orig" "$FAKEBIN/gh"; chmod +x "$FAKEBIN/gh"
    if [[ "$INJB_RAW" -ge 1 && "$INJB_OK" -ge 1 && "$INJB_MUT" -eq 0 && "$INJB_MUT_KEY" -eq 0 ]]; then
        inj_ok "INJ-B. 同一個情境兩次跑：假 gh 記 payload 時兩個計數器數到 ${INJB_RAW}／${INJB_OK}，不記時歸零（${INJB_MUT}／${INJB_MUT_KEY}）——2.1b2 的『零寫入』有意義"
    else
        inj_bad "INJ-B. 探針自測不成立（未突變 ${INJB_RAW}／${INJB_OK}、突變 ${INJB_MUT}／${INJB_MUT_KEY}）——2.1b2 的『零』可能只是探針壞掉"
    fi
fi

# INJ-C：錨在宣告路徑載入 runner 的那一行（單行、命中數 1、刪掉不破語法）。
python3 - "$POOL_SYNC" "$SANDBOX/injC-sync.sh" <<'INJC'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
needle = '        source "$cap_runner"'
hits = [k for k, l in enumerate(lines) if l == needle]
assert len(hits) == 1, 'source "$cap_runner" count=%d' % len(hits)
del lines[hits[0]]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
INJC
if [[ $? -ne 0 ]]; then
    inj_bad "INJ-C. pool-sync 裡找不到宣告路徑載入 runner 的那一行——形狀變了（harness 問題）"
elif ! bash -n "$SANDBOX/injC-sync.sh" 2>/dev/null; then
    inj_bad "INJ-C. 突變版語法錯誤——harness 問題"
else
    POOL_SYNC_SUBJECT="$SANDBOX/injC-sync.sh" \
        SEED_VAR_JSON="$(printf '%s' "$NODE_VALUE" | jq -c '.capabilities = {}')" \
        run_sync fh-test
    INJC_WRITES="$(decl_writes_that_change_caps "$PRE_CAPS")"
    if [[ "$INJC_WRITES" -eq 0 ]]; then
        inj_ok "INJ-C. 拿掉宣告路徑對 runner 的載入之後 pool-sync 不再寫宣告（0 次）——2.1a 有牙"
    else
        inj_bad "INJ-C. 拿掉宣告路徑對 runner 的載入之後仍然寫了 ${INJC_WRITES}次——宣告不是由它算出來的"
    fi
fi

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' "$pass" "$fail" "$injpass" "$injfail"
[[ "$fail" -eq 0 && "$injfail" -eq 0 ]]
