#!/usr/bin/env bash
# test-delete-release-port.sh — delete-worker S6（Release the port）失敗的缺口守衛。
#
# 工單 impl-dw-release-port：qa 指 S6 失敗時佔位永久註銷那個埠，且全程無
# `if: failure()` 補救（OUT-qa-c3 §1 D2）。歷史 0 次發生（46 run、3 次失敗
# 都在寫入前）。使用者裁示只修這一個，其餘記為已知限制。
#
# ---- 釘的是什麼 ----------------------------------------------------------
#
# 修法是「失敗時把怎麼收講清楚」（job summary 寫出重跑指令與現況），不是自動
# 補救。理由寫在 delete-worker.yml 的 S6 註解裡，核心一句：只重試 release 會
# 清掉佔位卻留下帳本，而重跑的 Find 讀的是佔位——於是重跑再也找不到那個
# worker，可全癒的殘骸變成要手動開帳本。不自動比重試一半好。
#
# 所以這個守衛證明三件事（§1–§3），外加殘骸可見性的訊號來源（§4）：
#   §1  重跑可癒（D2）：全部用本 repo 自己的函式執行——find／release／
#       ledger_remove 都是真的跑，不是模型。
#   §2  D3/D4 重跑不可癒：同一個 find 函式在佔位已清的狀態下拒絕 port 與
#       name 兩種找法。這是對 OUT-qa-c3 §1「D2–D5 手動重跑一次可全癒」的
#       事實修正（只對 D2 成立），也是失敗說明步驟必須分岔寫的理由。
#   §3  失敗說明步驟的覆蓋：在 S6 失敗的情境下，有 failure() 步驟會跑、且
#       內容點名重跑指令與 release 分岔。注入：拿掉它→紅、改壞 guard→紅、
#       拿掉重跑字樣→紅。
#   §4  殘骸看得見的訊號來源：mlp ls（佔位→down）、pool-status §D（stale
#       佔位 WARN）、mlp state（帳本與快取都還列著→誤導性 consistent）。
#       只讀那三個檔案，不改（其中兩個有別人的未 commit 改動）。
#
# ---- 這個守衛看不到什麼（誠實記在這裡）------------------------------------
#
# * 真機行為：docker rm -f 不存在的容器回非零，是 docker 的語義＋yml 上
#   `continue-on-error: true` 的靜態事實（§1f），這裡沒有 docker 可跑。
# * Gateway 上的 flock：本機 macOS 沒有 flock，pool-port-alloc 會印
#   `flock: command not found` 但照常做完（無 set -e）。斷言只看 exit code
#   與檔案有無，不看 log 字樣。
# * 失敗的步驟假設「沒有寫成」（與 test-rollback-coverage.sh 同一模型）。
# * guard 求值只認 `failure()`／`success()`／`always()` 與
#   `steps.X.outputs.Y != ''`／`== '<字面>'` 的 `&&` 合取；其他形狀回報為
#   harness limitation，不猜（猜錯的方向一律是綠）。
# * 內容歸屬：§3 只認「會跑的 failure() 步驟合起來有沒有那三個詞」，分不出是
#   哪一步帶的——真說明已死＋別處補一句含魔法字串的 failure() 步驟可騙過全綠
#   （2026-09-26 驗收 I4 實測）。順序已另有 3e 釘住，語義級覆蓋未做。
#
# Run: scripts/tests/test-delete-release-port.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"
WF=".github/workflows/delete-worker.yml"

for tool in python3 jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: ${tool} not on PATH" >&2; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: python3 + pyyaml required" >&2; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-dw-release-port.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
FX="$SANDBOX/fx"
mkdir -p "$FX/.mylinuxpool/workers.d" "$SANDBOX/wf"

pass=0; fail=0; injpass=0; injfail=0
ok()      { pass=$((pass+1));      printf '  ok    %s\n' "$1"; }
bad()     { fail=$((fail+1));      printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- 夾具：S6 失敗當下的池側狀態 ------------------------------------------
# victim：port 2305，container mlp-fh-l-default-999（bare 拼法 fh-l-…），
# 容器已刪（S5 做完），佔位／帳本／快取／key 都還在（S6 之後全跳過）。
VIC_PORT="2305"
VIC_CONT="mlp-fh-l-default-999"
VIC_BARE="fh-l-default-999"
VIC_PUBKEY="ssh-ed25519 AAAAvictim2305 fh-l-default-999"
KEEP_PORT="2300"

seed_d2() {
    rm -rf "$FX"; mkdir -p "$FX/.mylinuxpool/workers.d"
    cat > "$FX/vars.json" <<'V'
[{"name":"CLIENT_ACTIONS","value":"{\"name\":\"actions\",\"public_key\":\"ssh-ed25519 AAAAactions\"}"},
 {"name":"NODE_FH_L","value":"{\"name\":\"fh-l\",\"role\":\"provider\",\"tunnel_public_key\":\"ssh-ed25519 AAAAfakel\"}"},
 {"name":"NODE_FH_PROXY","value":"{\"name\":\"fh-proxy\",\"role\":\"provider\",\"tunnel_public_key\":\"ssh-ed25519 AAAAfakeproxy\"}"}]
V
    # 帳本：keeper ＋ victim（還沒被刪）
    cat > "$FX/ledger.json" <<'J'
[{"port":2300,"provider":"fh-proxy","image":"default","container":"mlp-fh-proxy-default-1","created_at":"2026-09-20T16:06:21Z","tunnel_public_key":"ssh-ed25519 AAAAkeeper2300 fh-proxy-default-1"},
 {"port":2305,"provider":"fh-l","image":"default","container":"mlp-fh-l-default-999","created_at":"2026-09-26T09:00:00Z","tunnel_public_key":"ssh-ed25519 AAAAvictim2305 fh-l-default-999"}]
J
    # 佔位：含 container（create 的 Record 步驟寫的形狀），容器本身已不在
    jq -n --arg c "$VIC_CONT" \
        '{provider:"fh-l",image:"default",port:2305,created_at:"2026-09-26T09:00:00Z",container:$c}' \
        > "$FX/.mylinuxpool/workers.d/2305.json"
    printf 'mlp-fh-proxy-default-1\n' > "$FX/containers"
    printf '2300\n' > "$FX/listeners"
    # 快取與 key 用 repo 自己的函式從「還髒的帳本」建——量的是實作。
    # 傳內容不是路徑（傳路徑會安靜失敗留下空檔，見 rollback 守衛檔頭 §1.7）。
    ( cd "$REPO_ROOT" && bash -c 'source scripts/lib/state.sh
        state_build "$1" "$2" "$3" "$4"' \
        _ 9 "delete-worker#0" "$(cat "$FX/vars.json")" "$(cat "$FX/ledger.json")" \
    ) > "$FX/state.json" 2>"$SANDBOX/state-build.err" || {
        printf '!!! harness 壞掉：state_build 跑不起來：%s\n' "$(head -1 "$SANDBOX/state-build.err")" >&2
        return 1
    }
    ( cd "$REPO_ROOT" && bash -c 'source scripts/refresh-authkeys.sh 2>/dev/null
        source scripts/rotate-gateway.sh 2>/dev/null
        rotate_assemble_sshproxy_keys "$(refresh_collect_tunnel_keys "$1" "$2")"' \
        _ "$(cat "$FX/vars.json")" "$(cat "$FX/ledger.json")" \
    ) > "$FX/authkeys" 2>"$SANDBOX/authkeys-build.err" || {
        printf '!!! harness 壞掉：authkeys 組裝跑不起來：%s\n' "$(head -1 "$SANDBOX/authkeys-build.err")" >&2
        return 1
    }
}

# D3 形狀：佔位已放（S6 成功）、帳本還在（S7 失敗）——重跑的 Find 該卡住。
seed_d3() {
    seed_d2 || return 1
    rm -f "$FX/.mylinuxpool/workers.d/2305.json"
}

claims_of_fx() {
    HOME="$FX" "$REPO_ROOT/shared-configs/pool-runtime/files/pool-port-alloc" --list 2>/dev/null
}

echo "=== 0. 先決條件 ==="
[[ -f "$REPO_ROOT/$WF" ]] && ok "0a. ${WF} 存在" || bad "0a. ${WF} 不存在"
if ( cd "$REPO_ROOT" && bash -c 'source scripts/delete-worker.sh; source scripts/lib/ledger.sh
        source scripts/lib/state.sh; source scripts/refresh-authkeys.sh 2>/dev/null
        source scripts/rotate-gateway.sh 2>/dev/null
        declare -F delete_worker_find_claim ledger_remove state_build state_next_serial \
                     refresh_collect_tunnel_keys rotate_assemble_sshproxy_keys >/dev/null' ) 2>/dev/null
then ok "0b. 模擬要呼叫的 repo 函式都讀得到（量的是實作，不是測試的模型）"
else bad "0b. repo 函式讀不到——後面的模擬全部不可信"; fi
if python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert len(d["jobs"])==1' "$REPO_ROOT/$WF" 2>/dev/null
then ok "0c. workflow 解析得了（單 job）"
else bad "0c. workflow 解析不了"; fi

echo
echo "=== 1. 重跑可癒（D2，全部真跑） ==="
if seed_d2; then ok "1a. S6 失敗夾具建成（容器已無，佔位／帳本在）"; else bad "1a. 夾具建不起來"; fi
# 正對照：快取與 key 現在必須宣告 victim，否則後面的「重跑清乾淨」是空斷言。
if jq -e --argjson p "$VIC_PORT" 'any(.workers[]?; .port == $p)' "$FX/state.json" >/dev/null 2>&1
then ok "1b. 正對照：重跑前快取確實宣告 port ${VIC_PORT}（不是量到空）"
else bad "1b. 正對照失敗：快取裡找不到 victim——後面的全癒不可信"; fi
if grep -qF "$VIC_BARE" "$FX/authkeys" 2>/dev/null
then ok "1c. 正對照：重跑前 authorized_keys 確實含 victim 的 key"
else bad "1c. 正對照失敗：authkeys 裡找不到 victim 的 key"; fi

D2CLAIMS="$(claims_of_fx)"
# 先收進變數再比對：`f | grep -q` 配上 pipefail 時，grep 先行關管會讓
# 印三行的函式吃 SIGPIPE 而誤紅（2026-09-26 實測）。不用管線量。
found_port="$(cd "$REPO_ROOT" && source scripts/delete-worker.sh &&
    delete_worker_find_claim "$D2CLAIMS" "$VIC_PORT" "" 2>/dev/null)"
found_rc=$?
if [[ "${found_rc}" -eq 0 && "${found_port}" == *"port=${VIC_PORT}"* ]]
then ok "1d. 重跑的 Find 用 port 找得到（佔位還在）"
else bad "1d. 重跑的 Find 用 port 找不到——重跑會卡住"; fi
if ( cd "$REPO_ROOT" && source scripts/delete-worker.sh &&
     delete_worker_find_claim "$D2CLAIMS" "" "$VIC_CONT" >/dev/null &&
     delete_worker_find_claim "$D2CLAIMS" "" "$VIC_BARE" >/dev/null )
then ok "1e. 重跑的 Find 用兩種 name 拼法都找得到（mlp 顯示什麼 spelling 都能貼）"
else bad "1e. 重跑的 Find 用 name 找不到"; fi

# release 冪等：真跑兩次都要 exit 0（第二次是 WARN＋0，不是卡住）。
HOME="$FX" "$REPO_ROOT/shared-configs/pool-runtime/files/pool-port-alloc" --release "$VIC_PORT" >/dev/null 2>&1
rc1=$?
HOME="$FX" "$REPO_ROOT/shared-configs/pool-runtime/files/pool-port-alloc" --release "$VIC_PORT" >/dev/null 2>&1
rc2=$?
if [[ "$rc1" -eq 0 && "$rc2" -eq 0 && ! -f "$FX/.mylinuxpool/workers.d/${VIC_PORT}.json" ]]
then ok "1f. --release 真跑兩次都 exit 0（佔位已清；第二次是空轉不是卡住）"
else bad "1f. --release 冪等不成立（rc=${rc1}/${rc2}）"; fi

# ledger_remove 冪等：真跑，exit 0 且第二次是 no-op。
if ( cd "$REPO_ROOT" && source scripts/lib/ledger.sh &&
     once="$(ledger_remove "$(cat "$FX/ledger.json")" "$VIC_PORT")" && r1=$? &&
     twice="$(ledger_remove "$once" "$VIC_PORT")" && r2=$? &&
     [[ "$r1" -eq 0 && "$r2" -eq 0 && "$once" == "$twice" ]] &&
     ! printf '%s' "$twice" | grep -q "$VIC_PORT" )
then ok "1g. ledger_remove 真跑：exit 0 且重複刪是 no-op"
else bad "1g. ledger_remove 不冪等"; fi

# S5 吸收：靜態事實——yml 上 rm 步驟帶 continue-on-error，warning 分岔看 outcome。
if python3 -c 'import yaml,sys
d = yaml.safe_load(open(sys.argv[1]))
ss = d["jobs"]["delete"]["steps"]
rm = [s for s in ss if s.get("id") == "rm_container"]
warn = [s for s in ss if "rm_container" in (s.get("if") or "") and "outcome" in (s.get("if") or "")]
assert len(rm) == 1 and rm[0].get("continue-on-error") is True and len(warn) >= 1
' "$REPO_ROOT/$WF" 2>/dev/null
then ok "1h. S5 帶 continue-on-error:true，重跑時對已無容器吸收（warning 分岔看 outcome）"
else bad "1h. S5 的吸收結構不在了"; fi

# 整條重跑一次跑到乾淨：release → 刪帳本 → 從乾淨帳本重建快取＋key。
jq -n --arg c "$VIC_CONT" \
    '{provider:"fh-l",image:"default",port:2305,created_at:"2026-09-26T09:00:00Z",container:$c}' \
    > "$FX/.mylinuxpool/workers.d/2305.json"
HOME="$FX" "$REPO_ROOT/shared-configs/pool-runtime/files/pool-port-alloc" --release "$VIC_PORT" >/dev/null 2>&1
( cd "$REPO_ROOT" && source scripts/lib/ledger.sh &&
  ledger_remove "$(cat "$FX/ledger.json")" "$VIC_PORT" > "$FX/ledger.json.new" ) 2>/dev/null \
  && mv "$FX/ledger.json.new" "$FX/ledger.json"
serial="$(cd "$REPO_ROOT" && bash -c 'source scripts/lib/state.sh
    state_next_serial "$(cat "$1")"' _ "$FX/state.json" 2>/dev/null)"
( cd "$REPO_ROOT" && bash -c 'source scripts/lib/state.sh
    state_build "$1" "$2" "$3" "$4"' \
    _ "${serial:-10}" "delete-worker#1" "$(cat "$FX/vars.json")" "$(cat "$FX/ledger.json")" \
) > "$FX/state.json" 2>/dev/null
( cd "$REPO_ROOT" && bash -c 'source scripts/refresh-authkeys.sh 2>/dev/null
    source scripts/rotate-gateway.sh 2>/dev/null
    rotate_assemble_sshproxy_keys "$(refresh_collect_tunnel_keys "$1" "$2")"' \
    _ "$(cat "$FX/vars.json")" "$(cat "$FX/ledger.json")" \
) > "$FX/authkeys" 2>/dev/null
residue=""
[[ -f "$FX/.mylinuxpool/workers.d/${VIC_PORT}.json" ]] && residue="${residue}placeholder "
printf '%s' "$(cat "$FX/ledger.json")" | grep -q "$VIC_PORT" && residue="${residue}ledger "
jq -e --argjson p "$VIC_PORT" --arg c "$VIC_CONT" \
    'any(.workers[]?; .port == $p or .container == $c)' "$FX/state.json" >/dev/null 2>&1 \
    && residue="${residue}state-cache "
grep -qF "$VIC_CONT" "$FX/authkeys" 2>/dev/null && residue="${residue}authorized-keys(cont) "
grep -qF "$VIC_BARE" "$FX/authkeys" 2>/dev/null && residue="${residue}authorized-keys(bare) "
grep -qxF "$VIC_CONT" "$FX/containers" 2>/dev/null && residue="${residue}container "
if [[ -z "$residue" ]]
then ok "1i. 重跑整條鏈之後五視角全乾淨（container／placeholder／ledger／state-cache／authorized-keys 兩種拼法）"
else bad "1i. 重跑後還有殘留：${residue}"; fi

echo
echo "=== 2. D3/D4 重跑不可癒（對 qa 判準的事實修正） ==="
seed_d3 || bad "2x. D3 夾具建不起來"
D3CLAIMS="$(claims_of_fx)"
# 正對照先行：同一個函式、同一個 victim，在佔位還在時必須找得到（§1d 重演）。
# 若這裡紅，§2 的「找不到」是 harness 壞掉，不是狀態使然。
if ( cd "$REPO_ROOT" && source scripts/delete-worker.sh &&
     delete_worker_find_claim "$D2CLAIMS" "$VIC_PORT" "" >/dev/null )
then ok "2a. 正對照：同一函式對 D2  claims 找得到——探針是活的"
else bad "2a. 正對照失敗：函式連 D2 都找不到，§2 不可信"; fi
if ( cd "$REPO_ROOT" && source scripts/delete-worker.sh &&
     ! delete_worker_find_claim "$D3CLAIMS" "$VIC_PORT" "" >/dev/null 2>&1 )
then ok "2b. D3 形狀（佔位已放、帳本還在）：用 port 重跑死在 Find（exit 非零）"
else bad "2b. D3 用 port 居然找得到——修正不成立"; fi
if ( cd "$REPO_ROOT" && source scripts/delete-worker.sh &&
     ! delete_worker_find_claim "$D3CLAIMS" "" "$VIC_CONT" >/dev/null 2>&1 )
then ok "2c. D3 形狀：用 name 重跑一樣死在 Find——D3/D4 重跑不可癒"
else bad "2c. D3 用 name 居然找得到——修正不成立"; fi

echo
echo "=== 3. 失敗說明步驟的覆蓋（修法本身） ==="
cat > "$SANDBOX/cover.py" <<'PY'
import re, sys, yaml

SCEN = {"port": "2305", "container": "mlp-fh-l-default-999",
        "provider": "fh-l", "stdout": "x", "ip": "x"}
CMP = re.compile(r"steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)\s*(!=|==)\s*'([^']*)'")

def guard_runs(guard):
    """S6 失敗情境下這個 failure() 守衛會不會跑。看不懂回 None（不猜）。"""
    g = (guard or "").strip()
    if g == "":
        return False
    has_fail, has_always, has_success = ("failure()" in g, "always()" in g, "success()" in g)
    if "||" in g:
        return None
    base = True if (has_fail or has_always) else (False if has_success else None)
    if base is None:
        return None
    for m in CMP.finditer(g):
        oname, op, lit = m.group(2), m.group(3), m.group(4)
        if oname not in SCEN:
            return None
        val = SCEN[oname]
        if op == "!=":
            if lit != "":
                return None
            if not val:
                return False
        else:
            if val != lit:
                return False
    rest = CMP.sub("", g)
    if re.search(r"steps\.", rest):
        return None
    return base

def load_steps(wf):
    doc = yaml.safe_load(open(wf, encoding="utf-8"))
    jobs = doc.get("jobs") or {}
    if len(jobs) != 1:
        return None
    return list(jobs.values())[0].get("steps") or []

def check(wf):
    steps = load_steps(wf)
    if steps is None:
        print("harness: workflow 不是單 job")
        return 2
    running_blobs = []
    unknown = []
    for s in steps:
        g = s.get("if") or ""
        # 只看失敗路徑：成功路徑的守衛（含 steps.X.outcome 這種要看執行
        # 結果才知道的）在靜態情境裡本來就求不出來，拿它們判未知會把每個
        # 有 outcome 分岔的 workflow 都報成 harness 壞掉。覆蓋問題只問
        # 「S6 情境下說明會不會跑」，與成功路徑無關。
        if "failure()" not in g and "always()" not in g:
            continue
        r = guard_runs(g)
        if r is None:
            unknown.append(s.get("name"))
        elif r:
            running_blobs.append(yaml.safe_dump(s, allow_unicode=True))
    if unknown:
        print("harness: 看不懂的 guard：%s" % ("／".join(unknown)))
        return 2
    blob = "\n".join(running_blobs)
    need = {"port-ref": "steps.find.outputs.port",
            "rerun": "mlp worker rm",
            "release-branch": "steps.release.outcome"}
    missing = sorted(k for k, t in need.items() if t not in blob)
    if missing:
        print("S6 情境下會跑的 failure() 步驟缺：%s" % ("、".join(missing)))
        return 1
    s6 = [s for s in steps if s.get("id") == "release"]
    if not s6:
        print("S6 沒有 id: release（失敗分岔無錨點）")
        return 1
    print("S6 情境下有 failure() 說明會跑，且點名 port／重跑／release 分岔")
    return 0

def check_order(wf):
    # 缺口 A 的釘子（2026-09-26 驗收 I2）：只看存在／guard／字串不看位置，
    # 說明步驟被挪到 Release 之前會全綠——但 failure() 步驟只有排在失敗點
    # 之後才會跑，錯位等於沒寫。只認 id 與 guard，不認說明文字的一個字。
    steps = load_steps(wf)
    if steps is None:
        print("harness: workflow 不是單 job")
        return 2
    rel = [n for n, s in enumerate(steps) if s.get("id") == "release"]
    if not rel:
        print("S6 沒有 id: release（順序無從判定）")
        return 1
    early = []
    for n, s in enumerate(steps):
        g = s.get("if") or ""
        if "failure()" not in g and "always()" not in g:
            continue
        if guard_runs(g) and n < rel[0]:
            early.append(s.get("name") or ("第 %d 步" % (n + 1)))
    if early:
        print("S6 情境下會跑、卻排在 id: release 之前的 failure() 步驟：%s（S6 失敗時它已被 skip，等於沒寫）" % ("／".join(early)))
        return 1
    print("S6 情境下會跑的 failure() 步驟都在 id: release 之後")
    return 0

def rewrite(src, dst, mode):
    lines = open(src, encoding="utf-8").read().split("\n")
    idxs = [i for i, l in enumerate(lines) if l.startswith("      - name:")]
    head, blocks = lines[:idxs[0]], []
    for n, i in enumerate(idxs):
        end = idxs[n + 1] if n + 1 < len(idxs) else len(lines)
        blocks.append("\n".join(lines[i:end]))
    if mode == "strip":
        blocks = [b for b in blocks if "failure()" not in b and "always()" not in b]
    elif mode == "deadif":
        blocks = [re.sub(r"if: failure\(\)",
                          "if: failure() && steps.find.outputs.port == 'never'", b, count=1)
                  if "if: failure()" in b else b for b in blocks]
    elif mode == "half":
        blocks = [b.replace("mlp worker rm", "mlp worker") for b in blocks]
    else:
        raise SystemExit("unknown mode " + mode)
    open(dst, "w", encoding="utf-8").write("\n".join(head + blocks))
    yaml.safe_load(open(dst, encoding="utf-8"))

if __name__ == "__main__":
    if sys.argv[1] == "check":
        sys.exit(check(sys.argv[2]))
    if sys.argv[1] == "order":
        sys.exit(check_order(sys.argv[2]))
    rewrite(sys.argv[2], sys.argv[3], sys.argv[1])
PY

if python3 "$SANDBOX/cover.py" check "$REPO_ROOT/$WF" > "$SANDBOX/cover-base.out" 2>&1
then ok "3a. 基底：$(cat "$SANDBOX/cover-base.out")"
else bad "3a. 基底覆蓋不成立：$(cat "$SANDBOX/cover-base.out")"; fi

if python3 "$SANDBOX/cover.py" order "$REPO_ROOT/$WF" > "$SANDBOX/cover-order.out" 2>&1
then ok "3e. 順序：S6 情境下會跑的 failure() 步驟都在 id: release 之後（錯位等於沒寫）"
else bad "3e. 順序不成立：$(cat "$SANDBOX/cover-order.out")"; fi

if python3 "$SANDBOX/cover.py" strip "$REPO_ROOT/$WF" "$SANDBOX/wf/strip.yml" 2>/dev/null \
   && ! python3 "$SANDBOX/cover.py" check "$SANDBOX/wf/strip.yml" >/dev/null 2>&1
then inj_ok "3b. 拿掉 failure() 說明 → 覆蓋紅（修法被拔掉看得見）"
else inj_bad "3b. 拿掉說明居然還是綠——守衛釘的不是修法"; fi

if python3 "$SANDBOX/cover.py" deadif "$REPO_ROOT/$WF" "$SANDBOX/wf/deadif.yml" 2>/dev/null \
   && ! python3 "$SANDBOX/cover.py" check "$SANDBOX/wf/deadif.yml" >/dev/null 2>&1
then inj_ok "3c. 說明的 guard 永遠不成立 → 紅（壞掉的說明不算數）"
else inj_bad "3c. 壞 guard 居然還是綠——守衛只看存在不看會不會跑"; fi

if python3 "$SANDBOX/cover.py" half "$REPO_ROOT/$WF" "$SANDBOX/wf/half.yml" 2>/dev/null \
   && ! python3 "$SANDBOX/cover.py" check "$SANDBOX/wf/half.yml" >/dev/null 2>&1
then inj_ok "3d. 說明裡沒有重跑指令 → 紅（有步驟但沒講怎麼收不算數）"
else inj_bad "3d. 沒講重跑居然還是綠——守衛沒看內容"; fi

echo
echo "=== 4. 殘骸可見性的訊號來源（只讀，不改） ==="
# mlp ls 的 worker 列來自佔位（gather_targets 讀 pool-port-alloc --list），
# 不是帳本——所以 S6 殘骸在 ls 裡是一列 down，不是消失。
if [[ "$(grep -c "pool-port-alloc --list" "$REPO_ROOT/ops-scripts/mlp")" -ge 1 ]] \
   && grep -n "pool-port-alloc --list" "$REPO_ROOT/ops-scripts/mlp" | grep -q "gather_targets\|workers_json"
then ok "4a. mlp 的 worker 列來自 Gateway 佔位（--list）——S6 殘骸在 ls 顯示為 down，不會隱形"
else bad "4a. mlp 的 worker 資料源變了——Q1 答案不可信"; fi
if grep -q "有佔位檔但無 listener" "$REPO_ROOT/shared-configs/pool-runtime/files/pool-status"
then ok "4b. pool-status §D 對「有佔位無 listener」報 WARN（點名埠號）"
else bad "4b. pool-status 的 stale 佔位訊號不在了"; fi
if grep -q "actions/variables/POOL_WORKERS" "$REPO_ROOT/ops-scripts/mlp" \
   && grep -q "cat /var/lib/mylinuxpool/state.json" "$REPO_ROOT/ops-scripts/mlp"
then ok "4c. mlp state 的 master 讀帳本、gateway 讀快取——兩邊都還列著，consistent 是誤導性的（已如實記入報告）"
else bad "4c. mlp state 的資料源變了——Q1 答案不可信"; fi

echo
echo "=== 5. 結論 ==="
if [[ "$fail" -ne 0 ]]; then
    printf '結論：紅。delete-worker S6 缺口的修法或其前提不成立（細節在 §1／§2／§3）。\n'
elif [[ "$injfail" -ne 0 ]]; then
    printf '結論：綠（不變量全過），但有 %s 條注入防線失敗——這個綠的可信度要打折。\n' "$injfail"
else
    printf '結論：綠。S6 失敗重跑可癒（真跑）、D3/D4 重跑不可癒（真跑）、失敗說明覆蓋成立。\n'
fi
echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' \
    "$pass" "$fail" "$injpass" "$injfail"
[[ "$fail" -ne 0 ]] && exit 1
[[ "$injfail" -ne 0 ]] && exit 2
exit 0
