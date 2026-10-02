#!/usr/bin/env bash
# test-capability-consumers.sh — PR-B tasks 2.2／2.3／2.4：
# register-provider、mlp verify-capabilities、create-worker 三個消費端改用 runner。
#
# 草稿，放在 scratchpad；PR-A commit 之後由 PM 放進 scripts/tests/。
# 前提：PR-A 的 runner（scripts/lib/capability.sh）與三個單位已存在。
set -uo pipefail
REPO_ROOT="${MLP_CAPABILITY_TEST_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"
RUNNER="$REPO_ROOT/scripts/lib/capability.sh"
RP="$REPO_ROOT/ops-scripts/register-provider.sh"
MLP="$REPO_ROOT/ops-scripts/mlp"
CW="$REPO_ROOT/scripts/create-worker.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-capability-consumers.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"; mkdir -p "$SHIMS" "$SANDBOX/home"
FAKEROOT="$SANDBOX/fakeroot"; mkdir -p "$FAKEROOT/scripts/lib" "$FAKEROOT/shared-configs" "$FAKEROOT/profiles/worker/default"

pass=0; fail=0; injpass=0; injfail=0
ok()   { pass=$((pass+1));   printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1));   printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- 沙箱假 repo 根：runner + 假單位 -------------------------------------
[[ -r "$RUNNER" ]] && cp "$RUNNER" "$FAKEROOT/scripts/lib/capability.sh"

CAP_LOG="$SANDBOX/cap.log"
make_unit() {  # make_unit <名> <能力鍵>
    local d="$FAKEROOT/shared-configs/$1"
    mkdir -p "$d/files"
    printf '{"name":"%s","description":"fake","needs_key":false,"needs_root":false,"provides":[],"capability":"%s"}\n' "$1" "$2" > "$d/unit.json"
    cat > "$d/install.sh" <<'UNITINSTALL'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >> "${CAP_LOG:?}"
printf 'params=%s\n' "${MLP_CAPABILITY_PARAMS:-<unset>}" >> "${CAP_LOG:?}"
exit "${FAKE_CAP_RC_THIS:-0}"
UNITINSTALL
    chmod +x "$d/install.sh"
}
make_unit ux alpha
make_unit uy bravo
# charlie 刻意不做單位——2.3c 要驗證「沒有單位的鍵報 unverifiable」。

# 假 docker / id / getent：worker-host 單位的判準會用到
cat > "$SHIMS/docker" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "info" ]] && exit "${DOCKER_RC:-0}"
exit 0
SH
cat > "$SHIMS/sudo" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do case "$1" in -n) shift ;; -u) shift 2 ;; --) shift; break ;; *) break ;; esac; done
exec "$@"
SH
# `id -u` 要真的印一個數字。舊的假 id 什麼都不印，而 `[[ "" -eq 0 ]]` 在 bash 的
# 算術語意裡是 **0 -eq 0 → true**——於是整個沙箱一直被當成 root，測試量的是
# register-provider 的「sudo 那條路」，而這支測試想量的是 no-sudo 那條。
cat > "$SHIMS/id" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    -u)  printf '%s\n' "${FAKE_ID_U:-1000}"; exit 0 ;;
    -nG) printf '%s\n' "${FAKE_GROUPS:-staff}"; exit 0 ;;
    -un) printf '%s\n' "${FAKE_ID_U_NAME:-testuser}"; exit 0 ;;
esac
exit 0
SH
cat > "$SHIMS/getent" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "group" && "${2:-}" == "docker" ]] && { printf '%s\n' "${FAKE_GROUP_LINE:-}"; exit 0; }
exit 2
SH
cat > "$SHIMS/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "${GH_LOG:-/dev/null}"
exit 0
SH
chmod +x "$SHIMS"/*

GH_LOG="$SANDBOX/gh.log"
mkdir -p "$SANDBOX/home/.mylinuxpool"
printf 'fake-token-not-real\n' > "$SANDBOX/home/.mylinuxpool/gh_token"

# 沙箱裡呼叫 runner／產品碼：MLP_REPO_ROOT 指到假 repo 根
#
# RP_NO_MAIN 是 register-provider.sh 剝掉最後一行 `main` 的副本。**必須剝**：
# 直接 source 整份檔案會把 main 也跑掉——於是「呼叫能力步驟」其實是跑了一次
# 完整的註冊（preflight、clone、sudoers、隧道金鑰、ssh…），量到的 rc 與輸出
# 混著十幾個步驟的東西。剝掉之後，量到的就只有能力步驟。
# 剝的正確性有保真檢查（下面）：副本必須與原檔只差一行。
RP_NO_MAIN="$SANDBOX/rp-nomain.sh"
if [[ -f "$RP" ]]; then
    sed -e '$d' "$RP" > "$RP_NO_MAIN"
    if diff <(sed -e '$d' "$RP") "$RP_NO_MAIN" >/dev/null 2>&1 \
        && tail -1 "$RP" | grep -qx 'main' \
        && ! tail -1 "$RP_NO_MAIN" | grep -qx 'main'; then
        ok "前提：RP 的副本剝掉了最後一行 main（與原檔只差一行——載入保真）"
    else
        bad "前提：剝不掉 RP 的 main（或原檔最後一行不是 main）——下面每一條都量不到東西"
    fi
else
    RP_NO_MAIN=""
fi

# 假節點：run_on_node 會把 mlp 送出來的那一條命令字串**真的執行**在這裡。
#   為什麼必須真的執行（impl 的第三輪補給的寫法）：cap_unit_check_on_node 送的是
#   `d=$(mktemp -d) && …base64… | tar -xz -C "$d" && MLP_CAPABILITY_PARAMS=… bash "$d/install.sh"
#   --check; rc=$?; …`，解開的就是真的 install.sh。只回 0 的話，2.3b 量到的
#   是「假件說什麼就是什麼」，而單位的回傳碼從來沒有真的回來過。
#   一次 eval 就好（不要再包一層 eval：那會把字串裡的引號吃掉）。
FAKE_NODE_DIR="$SANDBOX/node"; mkdir -p "$FAKE_NODE_DIR"
RUN_ON_NODE_LOG="$SANDBOX/run_on_node.log"
in_fakeroot() {  # in_fakeroot <bash片段>
    ( cd "$FAKEROOT" && MLP_REPO_ROOT="$FAKEROOT" HOME="$SANDBOX/home" PATH="$SHIMS:$PATH" \
        CAP_LOG="$CAP_LOG" GH_LOG="$GH_LOG" DOCKER_RC="${DOCKER_RC:-0}" \
        FAKE_CAP_RC_THIS="${FAKE_CAP_RC_THIS:-0}" \
        FAKE_NODE_DIR="$FAKE_NODE_DIR" RUN_ON_NODE_LOG="$RUN_ON_NODE_LOG" \
        bash -c "$1" 2>&1 </dev/null )
}

printf '{"capabilities":{"alpha":{"a":1},"bravo":{},"charlie":{}}}\n' > "$FAKEROOT/profile.json"
# register-provider 的能力步驟讀的是 **clone 裡的** profiles/provider/<PROFILE_NAME>/profile.json
# （不是 $FAKEROOT/profile.json——那一份是給 capability_plan／capability_declaration 用的）。
# 少了它，2.2b 量到的是「profile 找不到」而不是能力檢查的結果。
mkdir -p "$FAKEROOT/profiles/provider/no-sudo"
printf '{"role":"provider","shared_config":[],"capabilities":{"alpha":{"a":1}}}\n' \
    > "$FAKEROOT/profiles/provider/no-sudo/profile.json"

echo "=== 2.2 register-provider ==="

# 2.2x：能力檢查那一步必須呼叫 runner（形狀錨點：函式本體裡有 capability_check）
#
# 兩個刻意的限制（2026-10-02）：
#   1. **跳過註解行**。舊版 `awk '/capability_check/{print fn}'` 會被
#      `# step7_5_capabilities — …跑 runner 的 capability_check…` 這行註解帶走，
#      於是它報的「能力步驟」是 `step7_5_docker_group`——一個根本不做能力檢查的函式。
#      錨在註解上等於沒有錨。
#   2. **去掉括號**。舊版取 `$1`，得到的是 `step7_5_docker_group()`（含括號）；
#      呼叫端寫成 `step7_5_docker_group()` 讓 bash 在**解析**階段就報
#      `syntax error: unexpected end of file`——那一行紅燈量到的是這個形狀錯，
#      不是能力步驟的行為。（實作者的判斷是 register-provider.sh:220／:921 的
#      /dev/tcp 探測；實測下來與那兩處無關。）
RP_STEP=""
if [[ -f "$RP" ]]; then
    RP_STEP="$(awk '
        /^[[:space:]]*#/            { next }          # 註解不是程式碼
        /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { fn=$1; sub(/\(\).*$/, "", fn); next }
        /capability_check/           { if (fn != "") { print fn; exit } }
    ' "$RP")"
fi
if [[ -z "$RP_STEP" ]]; then
    bad "2.2a. register-provider.sh 裡找不到呼叫 capability_check 的步驟——PR-B 的 D8 還沒做"
    bad "2.2b. 同上，無法驗證『指名是哪個能力』"
    bad "2.2c. 同上，無法驗證『全部通過就寫入 runner 的宣告』"
    bad "2.2d. 同上，無法驗證『不再補 worker-host 預設』"
else
    ok "2.2a. register-provider 的能力步驟是 ${RP_STEP} （它呼叫 capability_check）"

    # 2.2b：結果 1 → 步驟非 0，而且指名是哪個能力
    #   前置變數照真檔：PROFILE_NAME、PROFILE_JSON、REPO_DIR 都指向假 fetched repo，
    #   否則這一步會在讀 profile 之前就結束（量到的不是能力檢查的結果）。
    rp_env() {  # rp_env <片段>：剝掉 main 的 RP + 能力步驟需要的前置
        # set -- 與 GH_POOL_TOKEN 必須在 source **之前**：register-provider.sh 的
        # 參數解析與 token 檢查寫在 main 之外（source 就會執行），沒有它們的話
        # source 會印 usage 並 exit 2——於是「量到的」是參數解析，能力步驟一行
        # 都還沒跑到（這正是 2.2b 之前 rc=2、輸出為空的原因）。
        # REPO_DIR 要在 source **之後**設：register-provider.sh 在 main 之外就有
        # `REPO_DIR=$(mktemp -d ...)`，source 會把它蓋掉，於是能力步驟讀的是一個
        # 空目錄（「capability.sh is missing」）。
        # 設完必須 **把 EXIT trap 拿掉**：register-provider.sh 的 trap 是
        # `rm -rf "$REPO_DIR"`，而且變數在 trap 執行時才展開——REPO_DIR 一旦被改成
        # 假 fetched repo，那個子殼層結束時就去刪整個假 repo（連同後面 2.3 要用的
        # 單位與 pool-resolve）。這是「沙箱自己把自己刪掉」，症狀是 2.3 全部空輸出。
        # REPO_DIR 必須指向假 fetched repo（能力步驟是從**它**裡讀 runner 與
        # profile 的），所以不能隨便換一個空目錄。但 register-provider.sh 在
        # `main` 之外就有 `trap 'rm -rf "$REPO_DIR"' EXIT`，而變數是在 trap 執行時
        # 才展開——所以設定完之後必須把 trap 拿掉，否則那個子殼層一結束就把整棵
        # 假 repo 刪掉（症狀：後面的注入拿不到 runner／profile／lib，2.4 的假
        # lib 也會被清空）。
        in_fakeroot "set -- --name t --gateway-port 2323; GH_POOL_TOKEN=dummy;
                     source '$RP_NO_MAIN' >/dev/null 2>&1 || true;
                     trap - EXIT INT TERM;
                     REPO_DIR='$FAKEROOT'; PROFILE_NAME='no-sudo';
                     PROFILE_JSON='$FAKEROOT/profiles/provider/no-sudo/profile.json'; $1"
    }
    # 情境要真的是「結果 1」：**這裡必須把假單位設成回 1**。
    # 舊版沒有設，于是量到的是「rc=0 的那一輪」，然後拿「步驟非 0」去斷言——
    # 之前它之所以有紅有綠，是因為步驟在更早的地方（PROFILE 未定義）就死了。
    # 一個前提不成立的斷言，紅與綠都沒有資訊。
    : > "$CAP_LOG"
    out="$(FAKE_CAP_RC_THIS=1 rp_env "MLP_CAPABILITY_PARAMS='' ; $RP_STEP" 2>&1 || true)"
    rc=0
    FAKE_CAP_RC_THIS=1 rp_env "$RP_STEP" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'alpha'; then
        ok "2.2b. 結果 1 → 註冊失敗（rc=${rc} ）且指名 alpha"
    else
        bad "2.2b. 結果 1 時應該非 0 且指名 alpha，實際 rc=${rc} out=[$(printf '%s' "$out" | tr '\n' '|' | head -c 120)]"
    fi
fi

# 2.2d：沒有 capabilities 時不得補 worker-host 預設（register-provider.sh:528 的行為）
if grep -q 'capabilities // {"worker-host"' "$RP" 2>/dev/null; then
    bad "2.2d. register-provider.sh 還在 capabilities 缺值時補 worker-host 預設——D8 說拿掉"
else
    ok "2.2d. register-provider.sh 不再補 worker-host 預設"
fi

echo "=== 2.3 mlp verify-capabilities ==="

# 2.3a：既有的三態與回傳碼不退化（0／1／3）
#   直接呼叫 cmd_verify_capabilities，節點 JSON 由 POOL_RESOLVE 提供。
cat > "$FAKEROOT/pool-resolve" <<'PR'
#!/usr/bin/env bash
cat <<'JSON'
{"name":"fh-test","role":"provider","capabilities":{"alpha":{"a":1},"bravo":{},"charlie":{}}}
JSON
PR
chmod +x "$FAKEROOT/pool-resolve"
verify_run() {  # verify_run <節點json檔>
    ( cd "$FAKEROOT" && MLP_REPO_ROOT="$FAKEROOT" HOME="$SANDBOX/home" PATH="$FAKEROOT:$SHIMS:$PATH" \
        CAP_LOG="$CAP_LOG" GH_LOG="$GH_LOG" FAKE_CAP_RC_THIS="${FAKE_CAP_RC_THIS:-0}" \
        POOL_RESOLVE="$FAKEROOT/pool-resolve" DOCKER_RC="${DOCKER_RC:-0}" \
        FAKE_NODE_DIR="$FAKE_NODE_DIR" RUN_ON_NODE_LOG="$RUN_ON_NODE_LOG" \
        bash -c "source '$MLP' >/dev/null 2>&1; POOL_RESOLVE='$FAKEROOT/pool-resolve';
                  # 假節點：把 mlp 送出來的那一條命令字串真的執行（理由見 FAKE_NODE_DIR 上面）。
                  run_on_node() { printf '%s\n' \"\$2\" >> \"\$RUN_ON_NODE_LOG\";
                                  ( cd \"\$FAKE_NODE_DIR\" && eval \"\$2\" ); }
                  cmd_verify_capabilities fh-test" 2>&1 </dev/null )
}
: > "$CAP_LOG"
V_ALL="$(FAKE_CAP_RC_THIS=0 verify_run)"; V_ALL_RC=$?
if printf '%s' "$V_ALL" | grep -q 'alpha' && printf '%s' "$V_ALL" | grep -q 'bravo'; then
    ok "2.3a. verify-capabilities 有列出宣告的能力（alpha／bravo）"
else
    bad "2.3a. verify-capabilities 沒有用 runner，輸出=[$(printf '%s' "$V_ALL" | tr '\n' '|' | head -c 140)]"
fi

# 2.3b：新鍵（有單位）→ pass，而且不需改 mlp
if printf '%s' "$V_ALL" | grep -E 'alpha' | grep -qE 'ok|pass'; then
    ok "2.3b. 有單位的鍵 alpha 報 pass"
else
    bad "2.3b. 有單位的鍵 alpha 沒報 pass（verify 仍然靠 mlp 裡寫死的 case）——[$(printf '%s' "$V_ALL" | grep alpha | tr '\n' '|')]"
fi

# 2.3c：沒有單位的鍵 → unverifiable
V_CHARLIE="$(printf '%s\n' "$V_ALL" | grep charlie)"
if printf '%s' "$V_CHARLIE" | grep -q 'unverifiable'; then
    ok "2.3c. 沒有單位的鍵 charlie 報 unverifiable"
else
    bad "2.3c. 沒有單位的鍵 charlie 應報 unverifiable，實際=[${V_CHARLIE}]"
fi

echo "=== 2.4 create-worker ==="

# 2.4c：**換掉被重構的對象**（review §4.5 + spec.md:75「worker 的能力 MUST NOT
#   另外驗證」）。原本這一條量的是「create-worker 呼叫 capability_plan」。
#   命題換成同一件事的正確形狀：
#     「照 profile **原樣**寫入，而且**不驗證**」。
#   為什麼必須換：capability_plan 會對 profile 裡的每個鍵真的跑該單位的
#   `--check`——在 Actions runner 上那會真的 `gh api repos/…`、真的 `docker info`，
#   結果被丟掉（jq 只取第 3 欄參數）。那不是「多跑一次」，那是每次建 worker
#   都白打一次網路呼叫，而 worker 的能力本來就不由 worker 自己驗證。
#   「零呼叫」在 2.4c2 量（假單位的呼叫帳本 + 假 gh 的 api 呼叫數）。
if grep -q 'capability_plan' "$CW" 2>/dev/null; then
    bad "2.4c. create-worker 還在呼叫 capability_plan——那會對每個鍵真的跑單位的 --check（建 worker 時白打 GitHub API），而 worker 的能力 MUST NOT 另外驗證（spec.md:75）"
else
    ok "2.4c. create-worker 不再走 capability_plan（照 profile 原樣寫入，不驗證）"
fi
if grep -qE "\.capabilities" "$CW" 2>/dev/null && ! grep -q 'capability_plan' "$CW" 2>/dev/null; then
    bad "2.4d. create-worker 還在用自己的 jq 讀 .capabilities"
else
    ok "2.4d. create-worker 沒有用自己的 jq 讀 capabilities"
fi

# 2.4a／2.4b：照 profile 寫入，沒有就寫 {}（實際呼叫 create_worker_ledger_add）
# lib/ 必須與 create-worker.sh 同一層：它用 ${SCRIPT_DIR}/lib/*.sh（:16-20, :85），
# 而 SCRIPT_DIR 是自己的目錄——不是 repo 的 scripts/。
mkdir -p "$SANDBOX/cw/lib"
cp "$CW" "$SANDBOX/cw/create-worker.sh"
# lib 清單**推導**，不手列：create-worker.sh 會 source 哪幾個 lib，只有它自己知道。
# 手列過一次（log/profile/ledger/refresh-wait），PR-B 讓它多 source 了
# lib/capability.sh，於是 2.4a/2.4b 一起變成「輸出為空」——症狀（沒有 ledger JSON）
# 離「缺一個 lib」很遠。改成從腳本文字推出來，並且缺檔要報錯。
CW_LIBS="$(grep -oE 'lib/[A-Za-z0-9_.-]+\.sh' "$CW" | sed 's|.*/||' | sort -u)"
if [[ -z "$CW_LIBS" ]]; then
    bad "2.4-pre. 推導不出 create-worker.sh 會 source 哪些 lib——2.4a/2.4b 的前提無法成立（harness 問題）"
else
    cw_missing=""
    for lib in $CW_LIBS; do
        if [[ -f "$REPO_ROOT/scripts/lib/$lib" ]]; then
            cp "$REPO_ROOT/scripts/lib/$lib" "$SANDBOX/cw/lib/$lib"
        else
            cw_missing="${cw_missing} ${lib}"
        fi
    done
    if [[ -n "$cw_missing" ]]; then
        bad "2.4-pre. repo 裡缺${cw_missing}——create-worker.sh 會 source 它們（是 repo 的問題，不是夾具的）"
    else
        ok "2.4-pre. 假 lib 帶齊 create-worker.sh 會 source 的 $(printf '%s\n' $CW_LIBS | grep -c .) 個（推導，不手列）"
    fi
fi
# 真實簽章（create-worker.sh:124）：
#   create_worker_ledger_add <workers_json> <port> <provider> <image> <container>
#                            <created_at> <tunnel_public_key> <profile_json>
# ledger_add 是純函式：回新的 POOL_WORKERS JSON。
ledger_add_run() {  # ledger_add_run <profile路徑>
    local prof="$1"
    ( cd "$SANDBOX/cw" && HOME="$SANDBOX/home" PATH="$SHIMS:$PATH" \
        MLP_REPO_ROOT="$FAKEROOT" CAP_LOG="$CAP_LOG" GH_LOG="$GH_LOG" \
        bash -c "source ./create-worker.sh >/dev/null 2>&1 || true; \
                 create_worker_ledger_add '[]' 2301 prov img ctr \
                   2026-01-01T00:00:00Z 'ssh-ed25519 AAA' '$prof'" 2>/dev/null </dev/null )
}
# 2.4c2：建 worker 時**零次**單位的 --check、**零次** GitHub API。
#   數兩個地方：假單位把每次被執行寫進 CAP_LOG；假 gh 把每次被呼叫寫進 GH_LOG
#   （`gh <args>` 一行）。2.4a 是這裡的正對照——它證明那些帳本抓得到寫入，
#   所以「零」有意義（否則「零」可能只是探針壞掉）。
printf '{"capabilities":{"alpha":{"a":1},"bravo":{"b":2}}}\n' > "$SANDBOX/prof-verified.json"
: > "$CAP_LOG"; : > "$GH_LOG"
V_OUT="$(ledger_add_run "$SANDBOX/prof-verified.json")"
n_unit="$(grep -c . "$CAP_LOG" 2>/dev/null || true)"
n_gh_api="$(grep -c '^gh api' "$GH_LOG" 2>/dev/null || true)"
if [[ -n "$V_OUT" ]] && printf '%s' "$V_OUT" | jq -e '.[0].capabilities.alpha.a == 1' >/dev/null 2>&1; then
    if [[ "${n_unit:-0}" -eq 0 && "${n_gh_api:-0}" -eq 0 ]]; then
        ok "2.4c2. 建 worker 時單位的 --check 零次、GitHub API 零次，而 capabilities 仍然照 profile 寫進去"
    else
        bad "2.4c2. 建 worker 時跑了 ${n_unit} 次單位的 --check、${n_gh_api} 次 GitHub API——worker 的能力不該被驗證（spec.md:75）"
    fi
else
    bad "2.4c2. 前提失敗：這一轮連 capabilities 都沒寫進去（out=[${V_OUT}]）——後面兩條的「零」沒有意義"
fi
printf '{"capabilities":{"alpha":{"a":1}}}\n' > "$SANDBOX/prof-with.json"
printf '{}\n' > "$SANDBOX/prof-without.json"
L_WITH="$(ledger_add_run "$SANDBOX/prof-with.json" | jq -c '.[0].capabilities' 2>/dev/null || echo NOFILE)"
if [[ "$L_WITH" == *alpha* ]]; then
    ok "2.4a. create-worker 把 profile 的 capabilities 寫進 ledger（${L_WITH} ）"
else
    bad "2.4a. ledger 那一筆沒有 profile 的 capabilities（got [${L_WITH}]）"
fi
L_WITHOUT="$(ledger_add_run "$SANDBOX/prof-without.json" | jq -c '.[0].capabilities' 2>/dev/null || echo NOFILE)"
if [[ "$L_WITHOUT" == "{}" ]]; then
    ok "2.4b. profile 沒有 capabilities 時寫 {} 而不是 null"
elif [[ "$L_WITHOUT" == "null" ]]; then
    bad "2.4b. profile 沒有 capabilities 時寫了 null——契約是 {}（{} 是「沒有參數」，null 是「不知道」）"
else
    bad "2.4b. ledger 那一筆的 capabilities 是 [${L_WITHOUT}]，預期 {}"
fi

echo "=== 注入 ==="

# INJ-D：把「能力檢查非 0 就失敗」放成無條件成功 → 2.2b 必須轉紅。
#   形狀錨點：RP 裡呼叫 capability_check 的那一步中，判斷回碼的那一行。
if [[ -z "$RP_STEP" ]]; then
    inj_bad "INJ-D. register-provider 的能力步驟還不存在，沒有可注入的判斷"
else
    RP_INJ="$SANDBOX/rp-inj.sh"
    # 突變的對象是 **剝掉 main 的那份副本**，不是原檔。
    # 原檔的最後一行是 `main`，source 它等於跑一次完整的註冊（preflight、clone、
    # sudoers、隧道金鑰、ssh…），於是突變版在「能力步驟」之前就死掉——
    # 量到的是整個註冊的失敗，不是被注入的那個判斷（症狀：rc=1 而且**一行輸出
    # 都沒有**，因為那些步驟的輸出全被 `>/dev/null 2>&1` 吃掉）。
    python3 - "$RP_NO_MAIN" "$RP_INJ" "$RP_STEP" <<'INJD'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
step = sys.argv[3]
# 錨點＝impl 的 step7_5_capabilities（能力檢查住的地方），不是 step7_5_docker_group。
start = next(k for k, l in enumerate(lines) if l.startswith(step + "() {"))
end = next(k for k in range(start + 1, len(lines)) if lines[k] == "}")
# 兩條分支都要蓋：root 那條是 `sudo … bash capability.sh --check … || rc=$?`，
# no-sudo 那條是 `… capability_check … || rc=$?`。只改一條的話，注入會因為
# 沙箱走的是另一條而「沒生效」——而且那種失敗看起來像注入壞了。
hits = [k for k in range(start, end)
        if re.search(r"^[^#]*\|\|\s*rc=\$\?", lines[k])]
assert hits, "no `|| rc=$?` inside %s" % step
# 把「收到回傳碼」的那一格換成 0 —— 語意是「檢查照跑、結果照收，只是被丟掉」。
# 形狀要跟著實作走：那一行現在是 `… >/dev/null 2>&1 || rc=$?`（把回傳碼收進 rc，
# 順便擋掉 set -e）。舊的突變是在行尾 append `|| true`，那在這個形狀下**沒有用**
# ——`rc=$?` 已經把 1 收進去了，`|| true` 只是讓整行回 0，rc 仍然是 1，於是
# 「注入沒生效」是誤判。
for k in hits:
    lines[k] = lines[k].replace("rc=$?", "rc=0  # INJECTED: result ignored", 1)
assert len(hits) >= 1
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
INJD
    if [[ $? -ne 0 ]]; then
        inj_bad "INJ-D. 突變腳本失敗（${RP_STEP} 裡的 capability_check 形狀變了）——harness 問題"
    elif ! bash -n "$RP_INJ" 2>/dev/null; then
        inj_bad "INJ-D. 突變版語法錯誤——harness 問題"
    elif ! printf '%s' "${out:-}" | grep -q "capability '"; then
        # 前提：未突變的步驟要真的跑到「印每個能力的結果」那幾行。跑不到的話，
        # 突變版與原版的 rc 必然一樣——那時「注入沒生效」是誤判（真正的原因在
        # 別處，例如步驟在讀 profile 之前就結束了）。
        # 比對的是 log 的形狀（capability '<鍵>': …），不是單純的 capability：
        # 沙箱路徑本身就叫 test-capability-consumers.XXXX，一個寬鬆的
        # grep -q capability 會被路徑騙到（前提因此看起來成立）。
        inj_bad "INJ-D. 前提不成立：未突變的 ${RP_STEP} 連『capability \'<鍵>\': …』都還沒印（rc=${rc:-?}）——這條注入要等它跑到結果判定那幾行"
    else
        : > "$CAP_LOG"
        rc=0
        ( cd "$FAKEROOT" && MLP_REPO_ROOT="$FAKEROOT" HOME="$SANDBOX/home" PATH="$SHIMS:$PATH" \
            CAP_LOG="$CAP_LOG" FAKE_CAP_RC_THIS=1 \
            FAKE_NODE_DIR="$FAKE_NODE_DIR" RUN_ON_NODE_LOG="$RUN_ON_NODE_LOG" \
            bash -c "set -- --name t --gateway-port 2323; GH_POOL_TOKEN=dummy;
                     source '$RP_INJ' >/dev/null 2>&1 || true; trap - EXIT INT TERM;
                     REPO_DIR='$FAKEROOT'; PROFILE_NAME='no-sudo';
                     PROFILE_JSON='$FAKEROOT/profiles/provider/no-sudo/profile.json'; $RP_STEP" \
            >/dev/null 2>&1 </dev/null ) || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            inj_ok "INJ-D. 把結果忽略掉之後步驟回 0（能力失敗卻不失敗）——2.2b 有牙"
        else
            inj_bad "INJ-D. 忽略結果之後仍然回 ${rc} ——2.2b 抓不到『失敗被吞掉』"
        fi
    fi
fi

# INJ-E：把假單位改成永遠回 0 → 2.3c（沒有單位的鍵報 unverifiable）必須仍成立，
#   而 2.3b 的 pass 必須仍成立。證明那兩格的差異不是被 fixture 決定。
if [[ ! -r "$RUNNER" ]]; then
    inj_bad "INJ-E. 缺 runner，無法驗證"
else
    a="$(FAKE_CAP_RC_THIS=0 verify_run)"
    b="$(FAKE_CAP_RC_THIS=1 verify_run)"
    pa="$(printf '%s\n' "$a" | grep alpha | grep -cE 'ok|pass')"
    pc="$(printf '%s\n' "$b" | grep charlie | grep -c 'unverifiable')"
    if [[ "${pa:-0}" -ge 1 && "${pc:-0}" -ge 1 ]]; then
        inj_ok "INJ-E. 假單位的回碼在 0／1 之間翻動時，alpha 仍 pass、charlie 仍 unverifiable——那兩格不是被 fixture 決定"
    else
        inj_bad "INJ-E. 翻了假單位的回碼之後 alpha-pass=${pa:-0} charlie-unverifiable=${pc:-0}——2.3b/2.3c 有問題"
    fi
fi

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' "$pass" "$fail" "$injpass" "$injfail"
[[ "$fail" -eq 0 && "$injfail" -eq 0 ]]
