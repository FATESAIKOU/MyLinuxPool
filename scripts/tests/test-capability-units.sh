#!/usr/bin/env bash
# test-capability-units.sh — PR-A（tasks 1.1–1.3）：能力＝shared-configs 單位
# 的契約、runner 與三個單位的 --check 判準。
#
# 每條斷言各自會紅，訊息說明缺什麼。runner 檔（scripts/lib/capability.sh）
# 還不存在，所以不能用「source 那一行」當紅燈——那只是 command not found。
# 因此這支檔在任何情況下都跑完，並且用 bad() 說出缺的是哪一件。
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

RUNNER="scripts/lib/capability.sh"
PREFLIGHT="ops-scripts/preflight"
UNITS_GLOB="shared-configs"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-capability-units.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"; mkdir -p "$SHIMS"

pass=0; fail=0; injpass=0; injfail=0
ok()   { pass=$((pass+1));   printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1));   printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# unit_caps <repo根>：每行 "<鍵>\t<單位>"，只列宣告了 capability 的單位。
unit_caps() {
    local root="$1"
    for uj in "$root"/shared-configs/*/unit.json; do
        [[ -f "$uj" ]] || continue
        local key
        key="$(jq -r '.capability // empty' "$uj" 2>/dev/null)"
        [[ -n "$key" ]] || continue
        printf '%s\t%s\n' "$key" "$(basename "$(dirname "$uj")")"
    done
}

# cap_count <repo根> <鍵>：有幾個單位實作這個鍵。
cap_count() { unit_caps "$1" | awk -F'\t' -v k="$2" '$1==k' | wc -l | tr -d ' '; }

# unit_keys <repo根>：所有單位的 capability 鍵（去重、換行）。
unit_keys() { unit_caps "$1" | cut -f1 | sort -u; }

# make_repo_copy <名字>：在沙箱做一份可跑的 repo 副本。preflight 用 git ls-files，
# 所以副本裡要有一個 index（git init ＋ git add，不 commit、不動真 repo 的 index）。
make_repo_copy() {
    local name="$1"
    local dst="$SANDBOX/repo-$name"
    rm -rf "$dst"; mkdir -p "$dst"
    for d in ops-scripts scripts shared-configs .github profiles docs openspec; do
        [[ -d "$REPO_ROOT/$d" ]] && cp -R "$REPO_ROOT/$d" "$dst/"
    done
    ( cd "$dst" && git init -q . && git add -A ) >/dev/null 2>&1
    printf '%s' "$dst"
}

# run_preflight <repo根>：印出輸出，rc 放進 PF_RC。
PF_RC=0
run_preflight() {
    local out rc=0
    out="$(cd "$1" && bash "$PREFLIGHT" 2>&1 </dev/null)" || rc=$?
    printf '%s' "$out"
    PF_RC="$rc"
}

# 假單位：unit.json + install.sh --check。install.sh 把 argv 與
# MLP_CAPABILITY_PARAMS 落盤，回傳 $FAKE_CAP_RC。
make_fake_unit() {
    local root="$1" name="$2" key="$3"
    local d="$root/shared-configs/$name"
    mkdir -p "$d/files"
    printf '{"name":"%s","description":"fake","needs_key":false,"needs_root":false,"provides":[],"capability":"%s"}\n' \
        "$name" "$key" > "$d/unit.json"
    cat > "$d/install.sh" <<'FAKEINSTALL'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >> "${CAP_LOG:-/dev/null}"
printf 'params=%s\n' "${MLP_CAPABILITY_PARAMS:-<unset>}" >> "${CAP_LOG:-/dev/null}"
exit "${FAKE_CAP_RC:-0}"
FAKEINSTALL
    chmod +x "$d/install.sh"
}

# 1.3 的單位判準要真的執行單位的 install.sh --check。
#   <repo根> <單位> <參數JSON> <期望碼> <額外環境…>
CAP_LOG=""
UNIT_RC=0; UNIT_OUT=""
run_unit_check() {
    local root="$1" unit="$2" params="$3"; shift 3
    local inst="$root/shared-configs/$unit/install.sh"
    CAP_LOG="$SANDBOX/cap-$unit.log"
    : > "$CAP_LOG"
    UNIT_RC=0
    UNIT_OUT="$(env MLP_CAPABILITY_PARAMS="$params" CAP_LOG="$CAP_LOG" HOME="$SANDBOX/home" \
        PATH="$SHIMS:$PATH" "$@" bash "$inst" --check 2>&1 </dev/null)" || UNIT_RC=$?
}

echo "=== 1.1 契約：每個帶 capability 的單位 ==="

# 1.1a 是這支檔的正對照：集合非空，其他契約斷言才有意義。
missing=""
for k in worker-host github wol; do
    n="$(cap_count "$REPO_ROOT" "$k")"
    [[ "$n" == "1" ]] || missing="${missing} ${k}(${n} 個單位)"
done
if [[ -z "$missing" ]]; then
    ok "1.1a. worker-host／github／wol 各由恰好一個單位實作"
else
    bad "1.1a. unit.json 沒有 capability 欄位（D1/D5）：${missing} —— 一個都沒宣告時，後面的契約斷言都是空的"
fi

# 1.1b／1.1f：D5 的表列出的三個單位都必須存在、都有 --check、--check 都讀參數。
for u in worker-host gh wol; do
    inst="$REPO_ROOT/shared-configs/$u/install.sh"
    if [[ ! -f "$inst" ]]; then
        bad "1.1b. shared-configs/${u}/install.sh 不存在——D5 的表要求這個單位"
        continue
    fi
    if ! grep -q -- '--check' "$inst"; then
        bad "1.1b. shared-configs/${u}/install.sh 沒有 --check"
        continue
    fi
    if ! grep -q 'MLP_CAPABILITY_PARAMS' "$inst"; then
        bad "1.1f. shared-configs/${u}/install.sh 的 --check 不讀 MLP_CAPABILITY_PARAMS（D2 的參數介面）"
        continue
    fi
    ok "1.1b. shared-configs/${u} 有 install.sh 與 --check，且讀 MLP_CAPABILITY_PARAMS"
done

# 1.1x：**每個 install.sh 都必須可執行**（2026-10-02，PM 加的）。
#   為什麼是一條斷言而不是文件裡一句話：pool-sync 的收斂迴圈是
#   `if [[ ! -x "$install" ]] → log WARN → continue`，register-provider 的 step 3
#   是 `[[ ! -x ]] → exit 1`。一個 644 的 install.sh 在**測試裡**完全正常
#   （`bash install.sh` 一樣跑得動，PR-A 的每一條判準都照樣量得到），線上卻是
#   「wol 永遠不被安裝 → 宣告裡的 wol 永遠不成立」。那正是 PR-A 上線時發生過的事。
#   兩個來源都要看：
#     磁碟上的 -x（工作樹現況，開發中與未 commit 的檔也在內）
#     git index 的 mode（100755）——那是別人 clone 到的樣子。
#   讀 index 用 `git ls-files -s`（唯讀；不動 index）。
not_exec=""
not_tracked=""
for inst in "$REPO_ROOT"/shared-configs/*/install.sh; do
    [[ -f "$inst" ]] || continue
    u_rel="${inst#"$REPO_ROOT"/}"
    [[ -x "$inst" ]] || not_exec="${not_exec} ${u_rel}(磁碟)"
    # `-c safe.directory=*`：容器／CI 上 repo 由別的使用者持有時，git 會整個拒絕
    # （dubious ownership），那時每一個檔都會看起來「不在 index 裡」——一個假的
    # 全軍覆沒，比沒有這條斷言更壞。
    mode="$(git -c safe.directory='*' -C "$REPO_ROOT" ls-files -s -- "$u_rel" 2>/dev/null | awk '{print $1}' | head -1)"
    if [[ -z "$mode" ]]; then
        not_tracked="${not_tracked} ${u_rel}"
    elif [[ "$mode" != "100755" ]]; then
        not_exec="${not_exec} ${u_rel}(index=${mode})"
    fi
done
if [[ -n "$not_exec" ]]; then
    bad "1.1x. 這些 install.sh 不可執行：${not_exec} —— pool-sync 會整個跳過該單位（線上症狀：宣告永遠不成立，測試裡看不出來）"
else
    ok "1.1x. 每個 shared-configs/*/install.sh 都可執行（磁碟 -x 與 git index 的 100755 都對）"
fi
if [[ -n "$not_tracked" ]]; then
    bad "1.1y. 這些 install.sh 不在 git index 裡（clone 不會帶過去）：${not_tracked}"
fi

# 1.1c：兩個單位實作同一個鍵 → preflight 必須擋。
#   副本注入 ＋ 未注入的同一份副本當對照，兩者輸出相減才不會把 preflight 的
#   其他雜訊當成證據。
C_BASE="$(make_repo_copy dupbase)"
run_preflight "$C_BASE" > "$SANDBOX/pf-base.txt"
# 副本必須是乾淨的，後面三條的紅才有意義（否則會把副本裡的無關問題
# 誤記成「缺少這條規則」）。
BASE_FAILS="$(grep -c 'FAIL' "$SANDBOX/pf-base.txt" 2>/dev/null || true)"
COPY_FAILS=0
# 有沒有被擋＝未注入的副本 0 條 FAIL，而注入的那一份比它多。刻意不比對訊息用字：
# 實作寫「有兩個單位實作」還是「duplicate capability」都不該讓測試紅。
pf_caught() {
    local tag="${1:-dup}"
    COPY_FAILS="$(grep -c 'FAIL' "$SANDBOX/pf-$tag.txt" 2>/dev/null || true)"
    [[ "$BASE_FAILS" -eq 0 && "$COPY_FAILS" -gt 0 ]]
}
if [[ "$BASE_FAILS" -ne 0 ]]; then
    bad "1.1c. 未注入的沙箱副本自己就有 ${BASE_FAILS} 條 FAIL——副本裡有與本條無關的問題，1.1c/1.1d/1.1e 的結果不可信"
fi
C_DUP="$(make_repo_copy dup)"
python3 - "$C_DUP" <<'PYDUP'
import json, sys
for u in ("pool-runtime", "rclone"):
    p = "shared-configs/%s/unit.json" % u
    d = json.load(open("%s/%s" % (sys.argv[1], p), encoding="utf-8"))
    d["capability"] = "wol"
    open("%s/%s" % (sys.argv[1], p), "w", encoding="utf-8").write(
        json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PYDUP
run_preflight "$C_DUP" > "$SANDBOX/pf-dup.txt"
if pf_caught; then
    ok "1.1c. 兩個單位搶同一個鍵時 preflight 擋下來"
else
    bad "1.1c. 副本裡 pool-runtime 與 rclone 都宣告 capability=wol，preflight 沒有擋（FAIL 條數 ${BASE_FAILS}→${COPY_FAILS}，rc=${PF_RC}）"
fi

# 1.1d：profile 宣告了沒有單位實作的鍵 → preflight 必須擋。
C_NOUNIT="$(make_repo_copy nounit)"
python3 - "$C_NOUNIT" <<'PYNOUNIT'
import json, sys
p = "profiles/provider/default/profile.json"
full = "%s/%s" % (sys.argv[1], p)
d = json.load(open(full, encoding="utf-8"))
d["capabilities"] = {"no-such-capability": {"x": 1}}
open(full, "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PYNOUNIT
run_preflight "$C_NOUNIT" > "$SANDBOX/pf-nounit.txt"
if pf_caught nounit; then
    ok "1.1d. profile 宣告了沒有單位實作的鍵時 preflight 擋下來"
else
    bad "1.1d. profile 宣告 capabilities.no-such-capability（沒有任何單位實作），preflight 沒有擋（FAIL 條數 ${BASE_FAILS}→${COPY_FAILS}，rc=${PF_RC}）"
fi

# 1.1e：值不是 object → preflight 必須擋。
C_BADVAL="$(make_repo_copy badval)"
python3 - "$C_BADVAL" <<'PYBADVAL'
import json, sys
p = "profiles/provider/default/profile.json"
full = "%s/%s" % (sys.argv[1], p)
d = json.load(open(full, encoding="utf-8"))
d["capabilities"] = {"worker-host": "docker"}
open(full, "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PYBADVAL
run_preflight "$C_BADVAL" > "$SANDBOX/pf-badval.txt"
if pf_caught badval; then
    ok "1.1e. profile 的能力值不是 object 時 preflight 擋下來"
else
    bad "1.1e. profile 的 capabilities.worker-host 是字串（契約是 key:object），preflight 沒有擋（FAIL 條數 ${BASE_FAILS}→${COPY_FAILS}，rc=${PF_RC}）"
fi

echo "=== 1.2 runner：scripts/lib/capability.sh ==="

RUNNER_OK=0
if [[ -r "$RUNNER" ]]; then
    # shellcheck source=../lib/capability.sh
    if source "$RUNNER" >/dev/null 2>&1; then RUNNER_OK=1; fi
fi

if [[ "$RUNNER_OK" -eq 0 ]]; then
    bad "1.2a. 缺 ${RUNNER}（D3 的共用 runner）——capability_plan／capability_check／capability_declaration 都沒有東西可叫"
    bad "1.2c. 無法驗證 capability_plan：${RUNNER} 不存在"
    bad "1.2d. 無法驗證 capability_check 傳參：${RUNNER} 不存在"
    bad "1.2e. 無法驗證 capability_declaration 的三態：${RUNNER} 不存在"
else
    miss=""
    for fn in capability_plan capability_check capability_declaration; do
        declare -F "$fn" >/dev/null 2>&1 || miss="${miss} ${fn}"
    done
    if [[ -z "$miss" ]]; then
        ok "1.2a. runner 提供 capability_plan／capability_check／capability_declaration"
    else
        bad "1.2a. ${RUNNER} 沒有定義：${miss}"
    fi
fi


# 1.2c–1.2e 需要一個假 repo 根：runner 在裡面、假單位也在裡面。
#   三種可能的根來源（BASH_SOURCE/../..、$PWD、$REPO_ROOT）同時滿足。
FAKEROOT="$SANDBOX/fakeroot"
mkdir -p "$FAKEROOT/scripts/lib" "$FAKEROOT/shared-configs"
[[ -r "$RUNNER" ]] && cp "$RUNNER" "$FAKEROOT/scripts/lib/capability.sh"
make_fake_unit "$FAKEROOT" fakecap-alpha alpha
make_fake_unit "$FAKEROOT" fakecap-beta beta
printf '{"capabilities":{"alpha":{"k":1},"beta":{}}}\n' > "$FAKEROOT/profile.json"

# 沙箱假 repo 根要靠 MLP_REPO_ROOT 傳進去：capability_repo_root 的第一順位就是它
# （第二順位是 REPO_ROOT，最後才是 BASH_SOURCE 相對位置）。
fakeroot_call() {  # fakeroot_call <bash程式碼片段>
    ( cd "$FAKEROOT" \
      && MLP_REPO_ROOT="$FAKEROOT" REPO_ROOT="$FAKEROOT" HOME="$SANDBOX/home" PATH="$SHIMS:$PATH" \
         CAP_LOG="$SANDBOX/fakecap.log" \
         bash -c "source scripts/lib/capability.sh >/dev/null 2>&1; $1" 2>&1 </dev/null )
}

# **capability_declaration 的契約：stdout 是值，stderr 是日誌**（每個鍵一行
# `capability <key>: rc=<n>`，呼叫端靠它分 WARN(1)／INFO(2)，D3／D4）。
# 所以讀它的值**只能**取 stdout：
#   fakeroot_out <片段>  → 只 stdout（丟掉 stderr）
#   fakeroot_err <片段>  → 只 stderr（丟掉 stdout）
# 為什麼要拆開：日誌行裡就有鍵名（`capability alpha: rc=1`），兩者合併時
# 「1 → 不納入 alpha」會因為日誌裡出現 alpha 而**假綠**。這不是本條的問題，
# 是契約改變之後測試端要跟著改的那一半。
fakeroot_out() {  # fakeroot_out <bash程式碼片段>
    ( cd "$FAKEROOT" \
      && MLP_REPO_ROOT="$FAKEROOT" REPO_ROOT="$FAKEROOT" HOME="$SANDBOX/home" PATH="$SHIMS:$PATH" \
         CAP_LOG="$SANDBOX/fakecap.log" \
         bash -c "source scripts/lib/capability.sh >/dev/null 2>&1; $1" 2>/dev/null </dev/null )
}
fakeroot_err() {  # fakeroot_err <bash程式碼片段>
    ( cd "$FAKEROOT" \
      && MLP_REPO_ROOT="$FAKEROOT" REPO_ROOT="$FAKEROOT" HOME="$SANDBOX/home" PATH="$SHIMS:$PATH" \
         CAP_LOG="$SANDBOX/fakecap.log" \
         bash -c "source scripts/lib/capability.sh >/dev/null 2>&1; $1" 2>&1 >/dev/null </dev/null )
}

if [[ "$RUNNER_OK" -eq 0 ]]; then
    :  # 1.2c–1.2e 已在上面各報一次，這裡不重複
elif [[ ! -r "$FAKEROOT/scripts/lib/capability.sh" ]]; then
    bad "1.2c. 沙箱副本裡沒有 runner，無法驗證 capability_plan"
else
    plan="$(fakeroot_call 'capability_plan profile.json')"
    if printf '%s' "$plan" | grep -q 'alpha' && printf '%s' "$plan" | grep -q 'beta'; then
        ok "1.2c. capability_plan 列出 profile 的每個能力"
    else
        bad "1.2c. capability_plan 沒有列出 alpha／beta（got [${plan}]）"
    fi

    # 現場查、不建快取：改了 unit.json 再問一次，答案要跟著變。
    printf '{"name":"fakecap-alpha","description":"fake","needs_key":false,"needs_root":false,"provides":[],"capability":"alpha-renamed"}\n' \
        > "$FAKEROOT/shared-configs/fakecap-alpha/unit.json"
    plan2="$(fakeroot_call 'capability_plan profile.json')"
    if printf '%s' "$plan2" | grep -q 'alpha-renamed'; then
        ok "1.2c. capability_plan 每次現場查 unit.json（改了會跟著變，沒有快取）"
    else
        bad "1.2c. 把 unit.json 的 capability 改成 alpha-renamed 後，capability_plan 沒反映（got [${plan2}]）"
    fi
    printf '{"name":"fakecap-alpha","description":"fake","needs_key":false,"needs_root":false,"provides":[],"capability":"alpha"}\n' \
        > "$FAKEROOT/shared-configs/fakecap-alpha/unit.json"

    # 1.2f：capability_plan 的 unit 欄。
    #   - profile 宣告了、也有單位 → unit 是那個單位的名字
    #   - 沒有單位 → unit 必須是 "-"（不是空字串：兩個 sentinel 不一致是坑）
    #   - 單位實作了但沒人宣告 → unit 也必須是那個單位的名字，不是空的
    #   解析用 awk -F'\t'：**不能**用 IFS=$'\t' read——tab 是 IFS 空白字元，
    #   連續分隔符會被折疊成一個，於是 `key\t\t{}\t2` 會把 `{}` 讀成 unit 名
    #   （review §6 B2 實測過）。這正是本條要擋的形狀。
    # ghost 刻意沒有任何單位實作——量「沒有單位時 unit 欄是 -、rc 是 2」那一格。
    printf '{"capabilities":{"alpha":{"k":1},"ghost":{"g":1}}}\n' > "$FAKEROOT/profile-b1.json"
    b1="$(fakeroot_call 'capability_plan profile-b1.json')"
    b1_unit_alpha="$(printf '%s\n' "$b1" | awk -F'\t' '$1=="alpha"{print $2; exit}')"
    b1_nofield="$(printf '%s\n' "$b1" | awk -F'\t' '$1=="alpha"{print ($2=="" ? "EMPTY" : $2); exit}')"
    if [[ -z "$b1_unit_alpha" ]]; then
        bad "1.2f. capability_plan 的 alpha 那一列 unit 欄是空的——應該是實作它的單位名"
    else
        ok "1.2f. capability_plan：宣告得到單位的鍵，unit 欄是那個單位（alpha→${b1_unit_alpha}）"
    fi
    b1_drift="$(printf '%s\n' "$b1" | awk -F'\t' '$1=="beta"{print $2; exit}')"
    if [[ -z "$b1_drift" ]]; then
        bad "1.2f. 單位實作了但 profile 沒宣告的那一列（beta），unit 欄是空的——capability_plan:82 把 repo 路徑當成鍵傳進去，就查不到單位"
    elif [[ "$b1_drift" == "-" ]]; then
        bad "1.2f. beta 的 unit 欄是 \"-\"，但 beta **有**單位（fakecap-beta）——漂移那一列要的是那個單位的名字"
    else
        ok "1.2f. 單位實作了但沒人宣告的鍵，unit 欄是那個單位（beta→${b1_drift}）"
    fi
    b1_ghost="$(printf '%s\n' "$b1" | awk -F'\t' '$1=="ghost"{print $2"\t"$4; exit}')"
    if [[ "$b1_ghost" == "$(printf -- '-\t2')" ]]; then
        ok "1.2f. 宣告了但沒有單位實作的鍵：unit 欄是 -、rc 是 2（不是空字串——兩個 sentinel 不一致是坑）"
    else
        bad "1.2f. ghost（沒有單位）的 unit/rc 是 [$(printf '%s' "$b1_ghost" | tr '\t' '/')]，預期 [-/2]"
    fi

    b1_missing="$(fakeroot_call 'capability_plan /dev/null' >/dev/null 2>&1; echo $?)"
    if [[ "$b1_missing" == "2" ]]; then
        ok "1.2f. profile 不存在時 capability_plan 回 2（不是靜靜回空）"
    else
        bad "1.2f. profile 不存在時回 ${b1_missing}，預期 2"
    fi

    # 1.2d：參數經 MLP_CAPABILITY_PARAMS 傳入，而且單位的回傳碼原樣回傳。
    : > "$SANDBOX/fakecap.log"
    fakeroot_call 'capability_check alpha "{\"k\":1}"' >/dev/null
    got_params="$(grep '^params=' "$SANDBOX/fakecap.log" 2>/dev/null | head -1)"
    if [[ "$got_params" == 'params={"k":1}' ]]; then
        ok "1.2d. capability_check 把參數原樣經 MLP_CAPABILITY_PARAMS 交給單位的 --check"
    else
        bad "1.2d. 假單位看到的 MLP_CAPABILITY_PARAMS 是 [${got_params}]，預期 {\"k\":1}（D2 的參數介面沒接上）"
    fi

    prop=""
    for want in 0 1 2; do
        : > "$SANDBOX/fakecap.log"
        rc="$(FAKE_CAP_RC="$want" fakeroot_call 'capability_check alpha "{}" >/dev/null 2>&1; echo $?' | tail -1)"
        [[ "$rc" == "$want" ]] || prop="${prop} ${want}→${rc}"
    done
    if [[ -z "$prop" ]]; then
        ok "1.2d. capability_check 原樣回傳單位的 0／1／2（D2 的三態）"
    else
        bad "1.2d. capability_check 沒有原樣回傳三態：${prop}"
    fi

    # 1.2e：0 納入、1 不納入、2 保留現有值。
    #   捕獲**只取 stdout**（見 fakeroot_out 的說明）：stderr 是日誌，而日誌行裡
    #   就有鍵名，合併的話「1 → 不納入 alpha」會因為 `capability alpha: rc=1`
    #   而假綠。順帶多加一個要求：stdout 必須是**可解析的 JSON object**——
    #   只有在日誌被隔離之後，這個要求才有意義（混入日誌就 parse 不了）。
    : > "$SANDBOX/fakecap.log"
    decl0="$(FAKE_CAP_RC=0 fakeroot_out 'capability_declaration profile.json "{}"')"
    decl1="$(FAKE_CAP_RC=1 fakeroot_out 'capability_declaration profile.json "{}"')"
    decl2="$(FAKE_CAP_RC=2 fakeroot_out 'capability_declaration profile.json "{\"beta\":{\"old\":true}}"')"
    e=""
    printf '%s' "$decl0" | jq -e 'type == "object"' >/dev/null 2>&1 || e="${e} rc=0 的 stdout 不是 JSON object"
    printf '%s' "$decl1" | jq -e 'type == "object"' >/dev/null 2>&1 || e="${e} rc=1 的 stdout 不是 JSON object"
    printf '%s' "$decl2" | jq -e 'type == "object"' >/dev/null 2>&1 || e="${e} rc=2 的 stdout 不是 JSON object"
    printf '%s' "$decl0" | jq -e '.alpha == {"k":1}' >/dev/null 2>&1 || e="${e} 0 時沒有納入 alpha 的參數"
    printf '%s' "$decl1" | jq -e 'has("alpha") | not' >/dev/null 2>&1 || e="${e} 1 時仍然納入 alpha"
    printf '%s' "$decl2" | jq -e '.beta == {"old":true}' >/dev/null 2>&1 || e="${e} 2 時沒有保留現有值"
    printf '%s' "$decl2" | jq -e 'has("alpha") | not' >/dev/null 2>&1 || e="${e} 2 時把沒有現有值的 alpha 也放進去了"
    if [[ -z "$e" ]]; then
        ok "1.2e. capability_declaration：0 納入、1 不納入、2 保留現有值（stdout 只有值）"
    else
        bad "1.2e. capability_declaration 三態錯誤：${e}"
    fi

    # 1.2f2：**stderr 每個鍵一行 rc**（這是契約的另一半，呼叫端靠它分
    #   WARN(1)／INFO(2)，pool-sync 與 register-provider 都不會為了拿狀態
    #   再呼叫一次 capability_plan——那會把每個單位的 --check 跑兩遍）。
    #   兩件事都要量得到：每個鍵**恰好一行**、rc 的值是該鍵自己的回傳碼。
    #   profile.json 宣告 alpha、beta；FAKE_CAP_RC 是所有假單位共用的開關。
    rcerr0="$(FAKE_CAP_RC=0 fakeroot_err 'capability_declaration profile.json "{}"')"
    rcerr2="$(FAKE_CAP_RC=2 fakeroot_err 'capability_declaration profile.json "{\"beta\":{\"old\":true}}"')"
    se=""
    for k in alpha beta; do
        [[ "$(printf '%s\n' "$rcerr0" | grep -c "^capability ${k}: rc=0$")" == "1" ]] \
            || se="${se} rc=0 時 ${k} 的日誌行不是恰好一行"
        [[ "$(printf '%s\n' "$rcerr2" | grep -c "^capability ${k}: rc=2$")" == "1" ]] \
            || se="${se} rc=2 時 ${k} 的日誌行不是恰好一行"
    done
    # 行的總數也要等於鍵數：多一行（例如把整份宣告也寫進 stderr）就是錯的。
    [[ "$(printf '%s\n' "$rcerr0" | grep -c '^capability ')" == "2" ]] \
        || se="${se} rc=0 的 stderr 有 $(printf '%s\n' "$rcerr0" | grep -c '^capability ') 行 capability（應該 2）"
    if [[ -z "$se" ]]; then
        ok "1.2f2. stderr：每個鍵恰好一行 capability <key>: rc=<n>（呼叫端靠它分 WARN／INFO）"
    else
        bad "1.2f2. stderr 的 rc 日誌不對：${se}"
    fi
fi

echo "=== 1.3 D5 判準：各單位 --check 的 0／1／2 ==="

# --- worker-host：docker info + /etc/group 對照 -----------------------------
mkdir -p "$SANDBOX/home/.mylinuxpool/bin"
cat > "$SHIMS/docker" <<'SHIMDOCKER'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${DOCKER_LOG:-/dev/null}"
if [[ "${1:-}" == "info" ]]; then exit "${DOCKER_RC:-0}"; fi
exit 0
SHIMDOCKER
cat > "$SHIMS/id" <<'SHIMID'
#!/usr/bin/env bash
if [[ "${1:-}" == "-nG" ]]; then printf '%s\n' "${FAKE_GROUPS:-staff}"; exit 0; fi
exit 0
SHIMID
# /etc/group 那一半只能用 getent 這類 PATH 上的指令假；直接讀檔就假不了。
cat > "$SHIMS/getent" <<'SHIMGETENT'
#!/usr/bin/env bash
if [[ "${1:-}" == "group" && "${2:-}" == "docker" ]]; then printf '%s\n' "${FAKE_GROUP_LINE:-}"; exit 0; fi
exit 2
SHIMGETENT
chmod +x "$SHIMS/docker" "$SHIMS/id" "$SHIMS/getent"

# 假 sudo：解析 `sudo -n -u <user> <cmd...>`，再用**同一個**（$SHIMS 優先的）PATH 跑 <cmd...>。
# 沒有它的話，worker-host 的 `sudo -n -u "$TARGET_USER" docker info` 會重置 PATH、
# 繞過 $SHIMS 的假 docker、直接問本機真的 docker——那會讓 1.3a 假綠、1.3b/1.3c 拿不到結果。
# FAKE_SUDO_UNAVAILABLE=1 模擬「這個 session 沒有 sudo」（回 1、不執行），那是 pool-sync 的情境。
cat > "$SHIMS/sudo" <<'SHIMSUDO'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${SUDO_LOG:-/dev/null}"
[[ "${FAKE_SUDO_UNAVAILABLE:-0}" == "1" ]] && exit 1
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) shift ;;
        -u) shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
exec "$@"
SHIMSUDO
chmod +x "$SHIMS/sudo"
SUDO_LOG=""

DOCKER_LOG="$SANDBOX/docker.log"
# 1.3a：docker info 成功 → 0
if [[ ! -f "$REPO_ROOT/shared-configs/worker-host/install.sh" ]]; then
    bad "1.3a. 缺 shared-configs/worker-host（D5 的新單位）：docker info 成功時應回 0"
else
    : > "$DOCKER_LOG"
    run_unit_check "$REPO_ROOT" worker-host '{"runtime":"docker"}' FAKE_GROUPS="staff docker" FAKE_GROUP_LINE="docker:x:999:fh-proxy" DOCKER_RC=0 DOCKER_LOG="$DOCKER_LOG"
    if [[ "$UNIT_RC" -eq 0 ]]; then
        ok "1.3a. worker-host：docker info 成功 → 0"
    else
        bad "1.3a. worker-host：docker info 成功卻回 ${UNIT_RC}（out=[${UNIT_OUT}]）"
    fi
    # 1.3k：這一輪的 docker 判斷確實問的是 $SHIMS 的假 docker。單元若用 sudo 呼叫
    #   （sudo 會重置 PATH）或寫絕對路徑，就會繞過假件去問本機真的 docker——
    #   那會讓 1.3a 變成假綠、1.3b/1.3c 拿不到結果。這一條就是防那個。
    if [[ -s "$DOCKER_LOG" ]]; then
        ok "1.3k. worker-host 的 docker 判斷走了假 docker，沒有被本機真的 docker 答掉"
    else
        bad "1.3k. 假 docker 的帳本是空的——單元沒問我們的 docker。sudo 會重置 PATH，繞過假件就會去問本機真的 docker"
    fi
fi

# 1.3c：docker info 失敗且使用者不在 /etc/group 的 docker 群組 → 1
if [[ ! -f "$REPO_ROOT/shared-configs/worker-host/install.sh" ]]; then
    bad "1.3c. 缺 shared-configs/worker-host：docker 掛掉且使用者不在 docker 群組時應回 1"
else
    run_unit_check "$REPO_ROOT" worker-host '{"runtime":"docker"}' FAKE_GROUPS="staff" FAKE_GROUP_LINE="docker:x:999:other" DOCKER_RC=1 DOCKER_LOG="$DOCKER_LOG"
    if [[ "$UNIT_RC" -eq 1 ]]; then
        ok "1.3c. worker-host：docker info 失敗 + 使用者不在 /etc/group 的 docker 群組 → 1"
    else
        bad "1.3c. worker-host：應該回 1，卻回 ${UNIT_RC}（out=[${UNIT_OUT}]）"
    fi
fi

# 1.3b：docker info 失敗、/etc/group 有這個使用者，但這個 process 沒有 docker gid → 2
if [[ ! -f "$REPO_ROOT/shared-configs/worker-host/install.sh" ]]; then
    bad "1.3b. 缺 shared-configs/worker-host：群組變更還沒生效時應回 2（D5 的「無法確認」）"
elif ! grep -qE 'getent' "$REPO_ROOT/shared-configs/worker-host/install.sh"; then
    bad "1.3b. 單位的 --check 沒有透過 getent 讀群組——「/etc/group 有、process 沒有」這格在測試裡假不了（harness 缺口，實作需要可注入的讀法）"
else
    run_unit_check "$REPO_ROOT" worker-host '{"runtime":"docker"}' FAKE_GROUPS="staff" \
        FAKE_GROUP_LINE="docker:x:999:$(whoami)" DOCKER_RC=1 DOCKER_LOG="$DOCKER_LOG"
    if [[ "$UNIT_RC" -eq 2 ]]; then
        ok "1.3b. worker-host：/etc/group 有、process 群組沒有 docker gid → 2"
    else
        bad "1.3b. worker-host：應該回 2（無法確認），卻回 ${UNIT_RC}（out=[${UNIT_OUT}]）"
    fi
fi

# 1.3d：runtime 不是 docker → 1，而且不該去跑 docker info
if [[ ! -f "$REPO_ROOT/shared-configs/worker-host/install.sh" ]]; then
    bad "1.3d. 缺 shared-configs/worker-host：runtime=podman 應回 1 且不跑 docker info"
else
    : > "$DOCKER_LOG"
    run_unit_check "$REPO_ROOT" worker-host '{"runtime":"podman"}' FAKE_GROUPS="staff docker" FAKE_GROUP_LINE="docker:x:999:fh-proxy" DOCKER_RC=0 DOCKER_LOG="$DOCKER_LOG"
    if [[ "$UNIT_RC" -ne 1 ]]; then
        bad "1.3d. worker-host：runtime=podman 應回 1，卻回 ${UNIT_RC}（out=[${UNIT_OUT}]）"
    elif [[ -s "$DOCKER_LOG" ]]; then
        bad "1.3d. worker-host：runtime=podman 卻有去跑 docker（[$(tr '\n' '|' < "$DOCKER_LOG")]）——應該直接回 1"
    else
        ok "1.3d. worker-host：runtime=podman → 1，且完全沒呼叫 docker"
    fi
fi

# --- gh：對每個 repo 打 API，0／1／2 ---------------------------------------
GH_LOG="$SANDBOX/gh.log"
# FAKE_GH_MAP   per-repo 模式：「repo-a=deny,repo-b=http5xx」，沒列的用 FAKE_GH_MODE。
#               多個 repo 的組合順序（D5：1 優先，不被後面的 2 蓋掉）要靠它。
# ratelimit     403 加上 "API rate limit exceeded"——GitHub 的 403 同時代表「無權」
#               與「被限流」，這兩件事的結論相反（無權→1、限流→2）。
# IGNORE_TOKEN  即使沒有 token 也回成功。用來量「沒有 token 回 1」：單元若沒有
#               提早回 1，就會真的去呼叫 API 並拿到成功，於是回 0 而不是 1。
cat > "$SHIMS/gh" <<'SHIMGH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "${GH_LOG:-/dev/null}"
repo=""
for a in "$@"; do case "$a" in repos/*) repo="${a#repos/}" ;; esac; done
repo_tail="${repo##*/}"
mode=""
IFS=',' read -r -a _pairs <<< "${FAKE_GH_MAP:-}"
for _p in "${_pairs[@]}"; do
    _k="${_p%%=*}"
    # key 可以是完整的 owner/repo，也可以只用 repo 名
    if [[ "$_k" == "$repo" || "$_k" == "$repo_tail" ]]; then mode="${_p#*=}"; fi
done
[[ -z "$mode" ]] && mode="${FAKE_GH_MODE:-ok}"
case "$mode" in
    ok)        printf '{"id":1,"name":"%s","full_name":"%s"}\n' "$repo" "$repo" ;;
    deny)      printf 'gh: HTTP 404: Not Found (repository)\n' >&2; exit 1 ;;
    denied403) printf 'gh: HTTP 403: Resource not accessible by integration\n' >&2; exit 1 ;;
    ratelimit) printf 'gh: HTTP 403: API rate limit exceeded\n' >&2; exit 1 ;;
    neterr)    printf 'error connecting to api.github.com\n' >&2; exit 1 ;;
    http5xx)   printf 'gh: HTTP 502\n' >&2; exit 1 ;;
    # review §4.4：`gh api --include … --jq …` 在 **HTTP 200** 時也可能非 0 退出
    # （--jq 的表達式取不到值、舊版 gh 拒絕 --include 卻仍印出標頭…）。
    # 單位的 case 有 `2*) one=0` 那一格，於是 code=200 → 判成「成立」→ 假 pass。
    ok200fail) printf 'HTTP/2.0 200\n'; printf '{"id":1,"name":"%s","full_name":"%s"}\n' "$repo" "$repo"; exit 1 ;;
    *)         printf '{"id":1,"name":"%s","full_name":"%s"}\n' "$repo" "$repo" ;;
esac
exit 0
SHIMGH
chmod +x "$SHIMS/gh"

# gh 單位的 --check 先找 token（TOKEN_FILE="${HOME_DIR}/.mylinuxpool/gh_token"），
# 沒有就回 2「無法確認」。放一個假的（不是任何真的憑證）。
mkdir -p "$SANDBOX/home/.mylinuxpool"
printf 'fake-token-for-tests\n' > "$SANDBOX/home/.mylinuxpool/gh_token"
GH_PARAMS='{"repos":{"owner/repo-a":["read"],"owner/repo-b":["read"]}}'

# 1.3e：每個 repo 都讀得到 → 0，而且真的每個 repo 都打了一次
: > "$GH_LOG"
run_unit_check "$REPO_ROOT" gh "$GH_PARAMS" FAKE_GH_MODE=ok GH_LOG="$GH_LOG"
n_ok="$(grep -c 'repo-a' "$GH_LOG" 2>/dev/null || true)"
n_ok2="$(grep -c 'repo-b' "$GH_LOG" 2>/dev/null || true)"
if [[ "$UNIT_RC" -eq 0 && "${n_ok:-0}" -ge 1 && "${n_ok2:-0}" -ge 1 ]]; then
    ok "1.3e. gh：參數裡每個 repo 都讀得到 → 0，且每個都真的打了 API"
else
    bad "1.3e. gh：應該回 0 且每個 repo 各打一次，卻回 ${UNIT_RC}（repo-a ${n_ok:-0} 次、repo-b ${n_ok2:-0} 次）——今天的 check_installed 只有 \`command -v gh\`，不看宣告的 repo"
fi

# 1.3f：拒絕存取 → 1
run_unit_check "$REPO_ROOT" gh "$GH_PARAMS" FAKE_GH_MODE=deny GH_LOG="$GH_LOG"
if [[ "$UNIT_RC" -eq 1 ]]; then
    ok "1.3f. gh：拒絕存取 → 1"
else
    bad "1.3f. gh：403 應回 1，卻回 ${UNIT_RC}（out=[${UNIT_OUT}]）——只看 \`command -v gh\` 就不會有 1"
fi

# 1.3g2：**gh 非 0 退出、但 HTTP 是 200 → 必須回 2**（review §4.4）
#   走到單位的 `case` 就代表有東西不對勁（gh 回 0 上面就 continue 了），
#   而「檢查沒有完成」與「檢查說不成立」是兩件事：後者回 1，前者只能回 2。
#   回 0 會讓一個沒跑完的檢查變成 `pass`——正是 CAPABILITY-DESIGN.md §2
#   說的「把『讀不懂』說成『沒有』」那類錯誤的反向版。
run_unit_check "$REPO_ROOT" gh "$GH_PARAMS" FAKE_GH_MODE=ok200fail GH_LOG="$GH_LOG"
if [[ "$UNIT_RC" -eq 2 ]]; then
    ok "1.3g2. gh：HTTP 200 但 gh 非 0 退出 → 2（無法確認），不是 0（假 pass）也不是 1"
elif [[ "$UNIT_RC" -eq 0 ]]; then
    bad "1.3g2. gh 非 0 退出卻回 0 —— 檢查根本沒完成，這是**假 pass**（review §4.4）"
else
    bad "1.3g2. 預期 2，實際 ${UNIT_RC}（out=[${UNIT_OUT}]）"
fi

# 1.3g：網路錯誤或 5xx → 2
run_unit_check "$REPO_ROOT" gh "$GH_PARAMS" FAKE_GH_MODE=http5xx GH_LOG="$GH_LOG"
if [[ "$UNIT_RC" -eq 2 ]]; then
    ok "1.3g. gh：5xx → 2（D2 的「無法確認」）"
else
    bad "1.3g. gh：502 應回 2，卻回 ${UNIT_RC}（out=[${UNIT_OUT}]）——只看 \`command -v gh\` 就不會有 2"
fi

# --- wol：存在、可執行、支援 method，而且不送封包 --------------------------
# 假 pool-wol 把自己的 argv 落盤。真的 pool-wol 只有一種用法：
# `pool-wol <MAC> <target-ip>...`（沒有查詢模式），所以「支援某個 method」
# 一定不能靠真的送封包去試——那正是 1.3i 要盯的。
# 「有沒有真的把 pool-wol 執行掉」不能靠假 shim 記錄——因為判準要求安裝位置放的
# 就是本單位的 files/pool-wol（逐位元組相同），放假 shim 會讓內容不相等。
# 所以：安裝位置放**真的那一份**，執行紀錄改由假 python3 記（pool-wol 的 shebang
# 是 #!/usr/bin/env python3）。單元若真的執行 pool-wol，就會出現在帳本裡。
REAL_POOL_WOL="$REPO_ROOT/shared-configs/wol/files/pool-wol"
mkdir -p "$SANDBOX/home/.mylinuxpool/bin"
cp "$REAL_POOL_WOL" "$SANDBOX/home/.mylinuxpool/bin/pool-wol"
chmod +x "$SANDBOX/home/.mylinuxpool/bin/pool-wol"
REAL_PYTHON="$(command -v python3)"
cat > "$SHIMS/python3" <<'SHIMPY'
#!/usr/bin/env bash
printf 'python3 %s\n' "$*" >> "${WOL_LOG:-/dev/null}"
exec "$REAL_PYTHON" "$@"
SHIMPY
chmod +x "$SHIMS/python3"
WOL_LOG="$SANDBOX/wol.log"

# 1.3h：存在、可執行、與本單位的 files/pool-wol 相同、支援 unicast → 0
if [[ ! -f "$REPO_ROOT/shared-configs/wol/install.sh" ]]; then
    bad "1.3h. 缺 shared-configs/wol（D7 從 pool-runtime 拆出的新單位）：應回 0"
else
    : > "$WOL_LOG"
    run_unit_check "$REPO_ROOT" wol '{"methods":["unicast"]}' WOL_LOG="$WOL_LOG" REAL_PYTHON="$REAL_PYTHON"
    if [[ "$UNIT_RC" -eq 0 ]]; then
        ok "1.3h. wol：pool-wol 存在、可執行、支援 unicast → 0"
    else
        bad "1.3h. wol：應回 0，卻回 ${UNIT_RC}（out=[${UNIT_OUT}]）"
    fi
fi

# 1.3h2：安裝的不是這一版 → 1（不是 2）。照 design D5：裝的是別版就是「這版的
#   能力沒有成立」，是確定不成立，屬於 CAP_RC_NO；回 2 會讓宣告停在舊值。
if [[ ! -f "$REPO_ROOT/shared-configs/wol/install.sh" ]]; then
    bad "1.3h2. 缺 shared-configs/wol：內容不同時應回 1"
else
    printf '#!/usr/bin/env bash\n# another version\n' > "$SANDBOX/home/.mylinuxpool/bin/pool-wol"
    chmod +x "$SANDBOX/home/.mylinuxpool/bin/pool-wol"
    run_unit_check "$REPO_ROOT" wol '{"methods":["unicast"]}' WOL_LOG="$WOL_LOG" REAL_PYTHON="$REAL_PYTHON"
    if [[ "$UNIT_RC" -eq 1 ]]; then
        ok "1.3h2. wol：已安裝的不是這一版 → 1（D5：確定不成立，不是無法確認）"
    else
        bad "1.3h2. wol：內容不同應回 1（D5 的 CAP_RC_NO），卻回 ${UNIT_RC}（out=[${UNIT_OUT}]）"
    fi
    cp "$REAL_POOL_WOL" "$SANDBOX/home/.mylinuxpool/bin/pool-wol"
    chmod +x "$SANDBOX/home/.mylinuxpool/bin/pool-wol"
fi

# 1.3i：整個檢查過程不得以送封包的方式呼叫 pool-wol。
#   真的 pool-wol 的第一個引數是 MAC、送出封包；所以只要 argv 的第一個引數
#   長得像 MAC，就是送封包。這個判斷不需要知道實作怎麼問「支不支援 unicast」。
if [[ ! -f "$REPO_ROOT/shared-configs/wol/install.sh" ]]; then
    bad "1.3i. 缺 shared-configs/wol：無法驗證「檢查時不送封包」"
else
    # pool-wol 的 shebang 是 #!/usr/bin/env python3，所以「被執行過」會在假 python3
    # 的帳本裡留下一筆帶 pool-wol 的 argv。真的 pool-wol 只有一種用法：
    # `pool-wol <MAC> <target-ip>...`（:33 的 usage），第一個引數是 MAC 就是送封包。
    if [[ ! -f "$WOL_LOG" ]] || ! grep -qE 'pool-wol .*([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' "$WOL_LOG"; then
        ok "1.3i. wol 的 --check 沒有真的執行 pool-wol（python3 帳本裡沒有帶 MAC 的呼叫）"
    else
        bad "1.3i. wol 的 --check 真的執行了 pool-wol 而且帶著 MAC——那就是送封包（[$(tr '\n' '|' < "$WOL_LOG")]）"
    fi
fi

# 1.3j：沒有 token → 1（D5：沒有 token 回 1）。
#   假件刻意讓「沒有 token 的 API 呼叫」也回成功，所以單元若沒有提早回 1，
#   就會真的去呼叫、拿到成功、回 0。
GH_TOK="$SANDBOX/home/.mylinuxpool/gh_token"
mv "$GH_TOK" "$SANDBOX/gh_token.saved" 2>/dev/null || true
run_unit_check "$REPO_ROOT" gh "$GH_PARAMS" FAKE_GH_IGNORE_TOKEN=1 GH_LOG="$GH_LOG"
if [[ "$UNIT_RC" -eq 1 ]]; then
    ok "1.3j. gh：沒有 token → 1（D5 明文）"
else
    bad "1.3j. gh：沒有 token 應回 1，卻回 ${UNIT_RC}（out=[$(printf '%s' "$UNIT_OUT" | tr '\n' '|' | head -c 100)]）——單元沒有提早回 1，而是真的去呼叫 API"
fi
mv "$SANDBOX/gh_token.saved" "$GH_TOK" 2>/dev/null || true

# 1.3k：rate limit（403 加上 API rate limit exceeded）→ 2，不是 1。
#   GitHub 的 403 同時代表「無權」與「被限流」，結論相反，所以不能只看 403。
run_unit_check "$REPO_ROOT" gh "$GH_PARAMS" FAKE_GH_MODE=ratelimit GH_LOG="$GH_LOG"
if [[ "$UNIT_RC" -eq 2 ]]; then
    ok "1.3k. gh：rate limit（403 + API rate limit exceeded）→ 2（D5：限流是無法確認，宣告要保留）"
else
    bad "1.3k. gh：rate limit 應回 2，卻回 ${UNIT_RC}——403 被當成「無權」了，限流會把能力從宣告裡刪掉"
fi

# 1.3l／1.3m：兩個 repo 時「1 優先」，順序不影響結論。
#   兩種順序各一格：today 的 rc 是迴圈裡逐次覆寫的，誰在最後誰贏。
GH_PARAMS2='{"repos":{"owner/r1-a":["read"],"owner/r1-b":["read"]}}'
for order in "deny,http5xx" "http5xx,deny"; do
    first="${order%%,*}"; second="${order#*,}"
    : > "$GH_LOG"
    run_unit_check "$REPO_ROOT" gh "$GH_PARAMS2" \
        "FAKE_GH_MAP=r1-a=$first,r1-b=$second" GH_LOG="$GH_LOG"
    if [[ "$UNIT_RC" -eq 1 ]]; then
        ok "1.3l/m. gh：兩個 repo（${order}）→ 1（D5：1 優先，不被後面的 2 蓋掉）"
    else
        bad "1.3l/m. gh：兩個 repo（${order}）應回 1，卻回 ${UNIT_RC}——回碼由「最後一次失敗」決定，順序會改變結論"
    fi
done

echo "=== D7：pool-wol 搬移（位元組相同、pool-runtime 不再裝） ==="

WOL_NEW="shared-configs/wol/files/pool-wol"
# sha256 of pool-runtime/files/pool-wol at 902ee23; CI checks out depth 1, so no git show.
WOL_OLD_SHA256="50087dfefb700e3ae571948bfc315b32005c804d45194fff675518800e6214c9"
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
if [[ ! -f "$REPO_ROOT/$WOL_NEW" ]]; then
    bad "D7a. $WOL_NEW 不存在——pool-wol 還在 pool-runtime 底下，沒有搬過去"
else
    if [[ "$(sha256_of "$REPO_ROOT/$WOL_NEW")" == "$WOL_OLD_SHA256" ]]; then
        ok "D7a. $WOL_NEW 與搬移前的 pool-wol 逐位元組相同"
    else
        bad "D7a. $WOL_NEW 的內容與搬移前的 pool-wol 不同——舊版 pool-runtime 的 --check 是 cmp -s，會把它蓋回去"
    fi
fi

if grep -q 'pool-wol' "$REPO_ROOT/shared-configs/pool-runtime/install.sh" 2>/dev/null; then
    bad "D7b. pool-runtime/install.sh 還在安裝 pool-wol——兩個單位會互相覆蓋"
else
    ok "D7b. pool-runtime/install.sh 不再安裝 pool-wol"
fi

# provider 的 profile 要列 wol，Gateway 的不要。
for pf in profiles/provider/default/profile.json profiles/provider/no-sudo/profile.json; do
    if [[ ! -f "$REPO_ROOT/$pf" ]]; then
        bad "D7c. $pf 不存在"
    elif jq -e '.shared_config | index("wol") != null' "$REPO_ROOT/$pf" >/dev/null 2>&1; then
        ok "D7c. $pf 列了 wol 單位（pool-sync 才不會有安裝空窗）"
    else
        bad "D7c. $pf 的 shared_config 沒有列 wol——搬走之後 pool-sync 不會裝它"
    fi
done
GW_PROFILE="$REPO_ROOT/profiles/gateway/default/profile.json"
if [[ ! -f "$GW_PROFILE" ]]; then
    bad "D7d. $GW_PROFILE 不存在——沒有它就沒有東西可斷"
elif jq -e '.shared_config | index("wol") != null' "$GW_PROFILE" >/dev/null 2>&1; then
    bad "D7d. Gateway 的 profile 列了 wol——它碰不到家裡的區網（D5 明文不列）"
else
    ok "D7d. Gateway 的 profile 沒有列 wol"
fi

echo "=== 注入 ==="

# INJ-G2：把 gh 單位的 `2*)` 那一格改回 `one=0` → 1.3g2 必須轉紅。
#   1.3g2 在產品碼修好之後是綠的；沒有這條注入就沒有辦法證明它是因為
#   「`2*)` 那一格被改成 2」才綠的，而不是因為假 gh 壞掉所以單元根本沒跑到迴圈。
# run_unit_check 走的是 <root>/shared-configs/<unit>/install.sh，所以突變檔要放
# 在那個形狀裡（第一版直接放 <root>/install.sh → rc=127 → 注入看起來沒生效）。
GH_MUT="$SANDBOX/gh-inj-root"
mkdir -p "$GH_MUT/shared-configs/gh/files"
cp "$REPO_ROOT/shared-configs/gh/install.sh" "$GH_MUT/shared-configs/gh/install.sh"
python3 - "$REPO_ROOT/shared-configs/gh/install.sh" "$GH_MUT/shared-configs/gh/install.sh" <<'INJG2'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "    2*)          one=2 ;;"
assert src.count(old) == 1, "needle `2*) one=2` count=%d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, "    2*)          one=0 ;;", 1))
INJG2
if [[ $? -ne 0 ]]; then
    inj_bad "INJ-G2. 突變腳本失敗（gh 單位的 `2*)` 那一格形狀變了）——harness 問題"
elif ! bash -n "$GH_MUT/shared-configs/gh/install.sh" 2>/dev/null; then
    inj_bad "INJ-G2. 突變版語法錯誤——harness 問題"
else
    run_unit_check "$GH_MUT" gh "$GH_PARAMS" FAKE_GH_MODE=ok200fail GH_LOG="$GH_LOG"
    if [[ "$UNIT_RC" -eq 0 ]]; then
        inj_ok "INJ-G2. 把 `2*)` 改回 one=0 之後 HTTP 200＋gh 非 0 就變成 0 ——1.3g2 有牙"
    else
        inj_bad "INJ-G2. 改回 one=0 之後仍然回 ${UNIT_RC}——1.3g2 不是在看那一格（harness 或注入沒生效）"
    fi
fi


# INJ-1：假 docker 改成成功 → 1.3c（應該是 1）必須轉紅。
#   證明 1.3c 真的在看 docker 的結果，不是無論如何都回 1。
if [[ ! -f "$REPO_ROOT/shared-configs/worker-host/install.sh" ]]; then
    inj_bad "INJ-1. 缺 shared-configs/worker-host，沒有東西可注入"
else
    DOCKER_LOG="$SANDBOX/inj1-docker.log"; : > "$DOCKER_LOG"
    run_unit_check "$REPO_ROOT" worker-host '{"runtime":"docker"}' FAKE_GROUPS="staff" FAKE_GROUP_LINE="docker:x:999:other" DOCKER_RC=1 DOCKER_LOG="$DOCKER_LOG"
    down="$UNIT_RC"
    run_unit_check "$REPO_ROOT" worker-host '{"runtime":"docker"}' FAKE_GROUPS="staff" FAKE_GROUP_LINE="docker:x:999:other" DOCKER_RC=0 DOCKER_LOG="$DOCKER_LOG"
    up="$UNIT_RC"
    if [[ "$down" != "$up" ]]; then
        inj_ok "INJ-1. 假 docker 從失敗改成成功之後回碼從 ${down} 變成 ${up}——1.3c 有在看 docker 的結果"
    else
        inj_bad "INJ-1. docker 失敗與成功都回 ${down}——1.3c 不是在看 docker 的結果"
    fi
fi

# INJ-2：假 gh 改成全部可讀 → 1.3f（應該是 1）必須轉紅。
if true; then
    run_unit_check "$REPO_ROOT" gh "$GH_PARAMS" FAKE_GH_MODE=deny GH_LOG="$GH_LOG"; denied="$UNIT_RC"
    run_unit_check "$REPO_ROOT" gh "$GH_PARAMS" FAKE_GH_MODE=ok GH_LOG="$GH_LOG"; allowed="$UNIT_RC"
    if [[ "$denied" != "$allowed" ]]; then
        inj_ok "INJ-2. 假 gh 從 403 改成全部可讀之後回碼從 ${denied} 變成 ${allowed}——1.3f／1.3e 有在讀 API 結果"
    else
        inj_bad "INJ-2. 403 與可讀都回 ${denied}——1.3f／1.3e 不是在讀 API 結果"
    fi
fi

# INJ-3：1.3i 的判準抓不抓得到「真的送了封包」？
#   單元正常情況下不會去執行 pool-wol（所以不能靠改 fixture 讓它執行），因此這一條
#   測的是**判準本身**：帳本裡放一筆帶 MAC 的 pool-wol 呼叫，那個樣式必須抓到。
if grep -qE 'pool-wol .*([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' /dev/null 2>/dev/null; then
    inj_bad "INJ-3. 不可能發生的分支被執行了——注入腳本本身有問題"
else
    printf 'python3 %s/pool-wol aa:bb:cc:dd:ee:ff 192.168.1.255\n' \
        "$SANDBOX/home/.mylinuxpool/bin" > "$SANDBOX/wol-inj3.log"
    if grep -qE 'pool-wol .*([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' "$SANDBOX/wol-inj3.log"; then
        inj_ok "INJ-3. 帳本裡出現帶 MAC 的 pool-wol 呼叫時，1.3i 的判準抓得到——那個判準有牙"
    else
        inj_bad "INJ-3. 帶 MAC 的 pool-wol 呼叫沒被 1.3i 的判準抓到——那個判準抓不到實際情況"
    fi
fi

# INJ-4：假單位的 --check 無視 MLP_CAPABILITY_PARAMS → 1.2d 必須轉紅。
if [[ "$RUNNER_OK" -ne 1 ]]; then
    inj_bad "INJ-4. 缺 runner，capability_check 沒有把參數傳給單位的路徑可注入"
else
    make_fake_unit "$FAKEROOT" fakecap-noparams noparams
    printf '#!/usr/bin/env bash\nprintf "argv=%%s\\n" "$*" >> "${CAP_LOG:-/dev/null}"\nprintf "params=<ignored>\\n" >> "${CAP_LOG:-/dev/null}"\nexit "${FAKE_CAP_RC:-0}"\n' \
        > "$FAKEROOT/shared-configs/fakecap-noparams/install.sh"
    chmod +x "$FAKEROOT/shared-configs/fakecap-noparams/install.sh"
    : > "$SANDBOX/fakecap.log"
    fakeroot_call 'capability_check noparams "{\"z\":9}"' >/dev/null
    if grep -q 'params=<ignored>' "$SANDBOX/fakecap.log" 2>/dev/null; then
        inj_ok "INJ-4. 假單位無視 MLP_CAPABILITY_PARAMS 時 1.2d 的判準抓得到——參數確實有被傳下去"
    else
        inj_bad "INJ-4. 參數沒有被傳到單位，或 1.2d 的判準抓不到"
    fi
fi

# ===========================================================================
# INJ-F～I：把 review 抓到的那四個洞**逐一放回去**，證明新加的斷言抓得到。
#   review §4「弄壞 #3 沒有牙」就是因為沒有任何斷言讀 capability_plan 的 unit 欄。
#   下面每一條都用形狀錨點（那一行的程式碼），不是註解。
# ===========================================================================

# INJ-F：把 capability_unit_for 的呼叫改回兩個引數（review §6 B1 的原狀）。
if [[ ! -r "$FAKEROOT/scripts/lib/capability.sh" ]]; then
    inj_bad "INJ-F. 沙箱裡沒有 runner，無法注入"
else
    cp "$FAKEROOT/scripts/lib/capability.sh" "$SANDBOX/injF-capability.sh"
    python3 - "$SANDBOX/injF-capability.sh" <<'INJF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = 'unit="$(capability_unit_for "$ukey")" || unit="-"'
assert s.count(old) == 1, "drift-row needle count=%d" % s.count(old)
open(p, "w", encoding="utf-8").write(
    s.replace(old, 'unit="$(capability_unit_for "$root" "$ukey")"', 1))
INJF
    if [[ $? -ne 0 ]]; then
        inj_bad "INJ-F. 突變腳本失敗（capability_plan 漂移那一列的形狀變了）——harness 問題"
    elif ! bash -n "$SANDBOX/injF-capability.sh" 2>/dev/null; then
        inj_bad "INJ-F. 突變版語法錯誤——harness 問題"
    else
        cp "$SANDBOX/injF-capability.sh" "$FAKEROOT/scripts/lib/capability.sh"
        f_out="$(fakeroot_call 'capability_plan profile-b1.json')"
        f_unit="$(printf '%s\n' "$f_out" | awk -F'\t' '$1=="beta"{print $2; exit}')"
        # 把 runner 還原
        cp "$RUNNER" "$FAKEROOT/scripts/lib/capability.sh"
        if [[ -z "$f_unit" ]]; then
            inj_ok "INJ-F. 把兩個引數的呼叫放回去之後，beta 那一列的 unit 欄變成空——1.2f 抓得到 review §6 B1"
        else
            inj_bad "INJ-F. 放回兩個引數的呼叫之後 beta 的 unit 欄仍是 [${f_unit}]——1.2f 抓不到那個 bug"
        fi
    fi
fi

# gh 的三條注入需要一個「mutant 單位」目錄：unit.json 照抄，install.sh 放突變版。
gh_mut_dir() {  # gh_mut_dir <install.sh 路徑> → 印出可供 run_unit_check 用的 root
    local d="$SANDBOX/ghmut/shared-configs/gh"
    rm -rf "$SANDBOX/ghmut"; mkdir -p "$d"
    cp "$REPO_ROOT/shared-configs/gh/unit.json" "$d/unit.json"
    cp "$1" "$d/install.sh"; chmod +x "$d/install.sh"
    printf '%s' "$SANDBOX/ghmut"
}
GH_MUT_TOKEN_SET=1
gh_run_mut() {  # gh_run_mut <root> <參數> [額外環境…]
    local root="$1" params="$2"; shift 2
    : > "$GH_LOG"
    CAP_LOG="$SANDBOX/cap-ghmut.log"; : > "$CAP_LOG"
    local rc=0 out
    out="$(env MLP_CAPABILITY_PARAMS="$params" CAP_LOG="$CAP_LOG" HOME="$SANDBOX/home" \
        PATH="$SHIMS:$PATH" GH_LOG="$GH_LOG" "$@" \
        bash "$root/shared-configs/gh/install.sh" --check 2>&1 </dev/null)" || rc=$?
    printf '%s' "$rc"
}

# INJ-G：拿掉「沒有憑證就回 1」的提早 return（review §2.3 的原狀）。
python3 - "$REPO_ROOT/shared-configs/gh/install.sh" "$SANDBOX/injG-gh.sh" <<'INJG'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
hits = [k for k, l in enumerate(lines) if 'log INFO "github: 沒有憑證' in l]
assert len(hits) == 1, "no-token log line count=%d" % len(hits)
start = hits[0] - 1
while start >= 0 and lines[start].strip() != "if [ -z \"$token\" ]; then":
    start -= 1
assert start >= 0, "no-token guard not found"
end = next(k for k in range(start, len(lines)) if lines[k].strip() == "fi")
del lines[start:end + 1]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
INJG
if [[ $? -ne 0 ]]; then
    inj_bad "INJ-G. 突變腳本失敗（沒有憑證的那個提早 return 形狀變了）——harness 問題"
elif ! bash -n "$SANDBOX/injG-gh.sh" 2>/dev/null; then
    inj_bad "INJ-G. 突變版語法錯誤——harness 問題"
else
    g_root="$(gh_mut_dir "$SANDBOX/injG-gh.sh")"
    GH_TOK="$SANDBOX/home/.mylinuxpool/gh_token"
    mv "$GH_TOK" "$SANDBOX/gh_token.saved2" 2>/dev/null || true
    g_rc="$(gh_run_mut "$g_root" "$GH_PARAMS" FAKE_GH_IGNORE_TOKEN=1)"
    mv "$SANDBOX/gh_token.saved2" "$GH_TOK" 2>/dev/null || true
    if [[ "$g_rc" != "1" ]]; then
        inj_ok "INJ-G. 拿掉「沒有憑證就回 1」之後回 ${g_rc}——1.3j 抓得到（沒有憑證會真的去呼叫 API）"
    else
        inj_bad "INJ-G. 拿掉提早 return 之後仍然回 1——1.3j 抓不到那個洞"
    fi
fi

# INJ-H：拿掉 rate limit 的那一行（403 會被當成無權 → 1）。
python3 - "$REPO_ROOT/shared-configs/gh/install.sh" "$SANDBOX/injH-gh.sh" <<'INJH'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
hits = [k for k, l in enumerate(lines) if re.search(r'\*"rate limit"\*.*one=2', l)]
assert len(hits) == 1, "rate-limit line count=%d" % len(hits)
del lines[hits[0]]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
INJH
if [[ $? -ne 0 ]]; then
    inj_bad "INJ-H. 突變腳本失敗（rate limit 那一行的形狀變了）——harness 問題"
elif ! bash -n "$SANDBOX/injH-gh.sh" 2>/dev/null; then
    inj_bad "INJ-H. 突變版語法錯誤——harness 問題"
else
    h_root="$(gh_mut_dir "$SANDBOX/injH-gh.sh")"
    h_rc="$(gh_run_mut "$h_root" "$GH_PARAMS" FAKE_GH_MODE=ratelimit)"
    if [[ "$h_rc" != "2" ]]; then
        inj_ok "INJ-H. 拿掉 rate limit 的分支之後回 ${h_rc}（不是 2）——1.3k 抓得到限流被當成無權"
    else
        inj_bad "INJ-H. 拿掉 rate limit 分支之後仍然回 2——1.3k 抓不到那個洞"
    fi
fi

# INJ-I：把「1 一旦出現就不被 2 蓋掉」改回「最後一次贏」。
python3 - "$REPO_ROOT/shared-configs/gh/install.sh" "$SANDBOX/injI-gh.sh" <<'INJI'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
hits = [k for k, l in enumerate(lines) if re.search(r'^\s*\[ "\$one" -eq 1 \] && rc=1', l)]
assert len(hits) == 1, "1-wins line count=%d" % len(hits)
lines[hits[0]] = re.sub(r'^\s*', '        ', lines[hits[0]])
lines[hits[0]] = '        rc="$one"'
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
INJI
if [[ $? -ne 0 ]]; then
    inj_bad "INJ-I. 突變腳本失敗（「1 優先」那一行的形狀變了）——harness 問題"
elif ! bash -n "$SANDBOX/injI-gh.sh" 2>/dev/null; then
    inj_bad "INJ-I. 突變版語法錯誤——harness 問題"
else
    i_root="$(gh_mut_dir "$SANDBOX/injI-gh.sh")"
    i_rc="$(gh_run_mut "$i_root" "$GH_PARAMS2" "FAKE_GH_MAP=r1-a=deny,r1-b=http5xx")"
    if [[ "$i_rc" != "1" ]]; then
        inj_ok "INJ-I. 改回「最後一次贏」之後 deny→http5xx 回 ${i_rc}（不是 1）——1.3l 抓得到順序敏感"
    else
        inj_bad "INJ-I. 改回「最後一次贏」之後仍然回 1——1.3l 抓不到順序敏感"
    fi
fi

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' "$pass" "$fail" "$injpass" "$injfail"
[[ "$fail" -eq 0 && "$injfail" -eq 0 ]]
