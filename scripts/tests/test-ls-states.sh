#!/usr/bin/env bash
# test-ls-states.sh — `mlp ls` 狀態細分的人造故障護欄：開著的機器不准被說成關著。
#
# 為什麼要有這支（2026-09-25 真事）：
#   fh-l 被 WoL 叫醒、機器在區網上活著，但開機半途卡死（sshd 與
#   pool-tunnel 都沒起來）。`mlp ls` 顯示 down——跟真的關機一模一樣。
#   是靠另一個團隊測喚醒才發現它掛在那裡。使用者看到 down 只會想「叫醒它」，
#   而叫醒一台已經開著的機器什麼也解決不了，還把唯一需要人去看的狀態藏起來。
#   所以：out-of-pool（黃）與 off（紅）不可互相退化；off 必須是問過代送者
#   （ping 不通）才說的；沒有可用代送者或 ping 本身失敗一律 unknown——
#   絕不可把「不知道」說成「關著」，那是這個 repo 反覆踩的謊的鏡像。
#
# 要釘的五件事：
#   1. 三態不可互相退化（實際字串＋顏色都要斷，不是只斷「有沒有紅」）。
#   2. off 必須有證據：ping 不通；其餘（rc 非 0/1、ssh 噪音、無 live sender、
#      位址壞掉）一律 unknown。
#   3. 成本：全 up 時零額外 ssh／零 ping（用帳本斷言呼叫次數）。
#   4. gw_probe_port 三態：ssh 自己失敗／沒跑到標記 → inconclusive；
#      nc 跑完沒 banner → down；兩者不可混。
#   5. 既有消費端不受影響：cmd_wake 只認 up、cmd_down 只認 down，
#      第三態（inconclusive）不可讓它們提前下結論（用 probe 次數斷言）。
#
# 手法：全離線。沙箱 repo 放真 mlp＋真 ssh.sh；pool-resolve／ssh／gh／fzf／
#   sleep 走 PATH stub（沙箱 repo 內的檔案）。顏色以 C_* 覆寫成可見標記
#   （<g>/<y>/<r>）——不靠 TTY，斷言才有牙齒。cmd_ls／消費端以 source 載入
#   直接呼叫，繞過 check_deps。
#
# 注入（每條先證明會紅：突變版 bash -n 過＋needle 命中數剛好 1＋實際 got 值）。
#
# 相容：bash 3.2（測試本體不用陣列、不用 ${var,,}）。
#
# Run: scripts/tests/test-ls-states.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

MLP="ops-scripts/mlp"
SSH_LIB="scripts/lib/ssh.sh"
TUNNEL_ID="shared-configs/pool-runtime/files/tunnel-identity.sh"

for f in "$MLP" "$SSH_LIB" "$TUNNEL_ID"; do
    if [[ ! -f "$f" ]]; then
        echo "test-ls-states: ${f} is missing; dependent cases will FAIL" >&2
    fi
done
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required (needle tooling) but not found on PATH" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-ls-states.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
REPO="$SANDBOX/repo"
NODES_DIR="$SANDBOX/nodes"
mkdir -p "$SHIMS" "$HOME_DIR" "$NODES_DIR" "$REPO/ops-scripts" "$REPO/scripts/lib" \
         "$REPO/shared-configs/pool-runtime/files"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- 沙箱 repo ---------------------------------------------------------------
cp -p "$REPO_ROOT/$MLP" "$REPO/$MLP"
cp -p "$REPO_ROOT/$SSH_LIB" "$REPO/$SSH_LIB"
cp -p "$REPO_ROOT/$TUNNEL_ID" "$REPO/$TUNNEL_ID"
cat > "$REPO/shared-configs/pool-runtime/files/pool-resolve" <<'FAKE'
#!/usr/bin/env bash
printf 'PR %s\n' "$*" >> "${PR_LOG:-/dev/null}"
if [[ "${2:-}" == "--expand-hops" ]]; then
    printf '[{"host":"9.9.9.9","port":22,"user":"gw"},{"host":"127.0.0.1","port":2300,"user":"worker"}]\n'
    exit 0
fi
if [[ "${1:-}" == "gateway" ]]; then
    printf '{"ip":"9.9.9.9","user":"gw","port":22}\n'
    exit 0
fi
name="${1:-}"
for cand in "$name" "$(printf '%s' "$name" | tr '-' '_')" "$(printf '%s' "$name" | tr '_' '-')"; do
    if [[ -n "${NODES_DIR:-}" && -f "$NODES_DIR/$cand.json" ]]; then
        cat "$NODES_DIR/$cand.json"
        exit 0
    fi
done
exit 1
FAKE
chmod +x "$REPO/shared-configs/pool-runtime/files/pool-resolve"

# 突變還原用的乾淨副本（任何注入提早失敗都不必搶救真檔）。
cp -p "$REPO/$MLP" "$SANDBOX/mlp-fixed-keep"

# ---- PATH stubs ---------------------------------------------------------------
# ssh：argv 記帳＋CALL-EOL。nc 探測依 FAKE_GW_MODE（單元用）或 PROBE_MAP
# （ls 夾具用，<port>:<state>）。ping 走 PING_RC／PING_NOISE。
cat > "$SHIMS/ssh" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a" >> "${SSH_LOG:-/dev/null}"; done
printf 'CALL-EOL\n' >> "${SSH_LOG:-/dev/null}"
joined="$*"
case "$joined" in
  *"nc 127.0.0.1 "*)
    if [[ -n "${FAKE_GW_MODE:-}" ]]; then
      case "$FAKE_GW_MODE" in
        ssh-fail)      exit 255 ;;
        partial)       printf 'SSH-'; exit 0 ;;
        no-banner)     printf 'NC_DONE'; exit 0 ;;
        banner)        printf 'SSH-2.0-OpenSSH_9.9NC_DONE'; exit 0 ;;
        *)             exit 255 ;;
      esac
    fi
    rest="${joined#*nc 127.0.0.1 }"
    port="${rest%% *}"
    st="$(awk -F: -v p="$port" '$1 == p {print $2}' "${PROBE_MAP:-/dev/null}" 2>/dev/null)"
    case "$st" in
      up)           printf 'SSH-2.0-OpenSSH_9.9NC_DONE'; exit 0 ;;
      inconclusive) exit 255 ;;
      *)            printf 'NC_DONE'; exit 0 ;;
    esac ;;
esac
case "$joined" in
  *"timeout 3 ping "*)
    if [[ "${PING_NOISE:-0}" == "1" ]]; then
      printf 'mlp: could not resolve hop chain for stub\n' >&2
    fi
    exit "${PING_RC:-0}" ;;
esac
case "$joined" in
  *"pool-port-alloc"*) printf '[]\n'; exit 0 ;;
esac
exit 0
FAKE
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
cat "${GH_VARS_FILE:-/dev/null}" 2>/dev/null
exit 0
FAKE
cat > "$SHIMS/fzf" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
cat > "$SHIMS/sleep" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$SHIMS/ssh" "$SHIMS/gh" "$SHIMS/fzf" "$SHIMS/sleep"

# ---- 節點夾具 ---------------------------------------------------------------
# fh-proxy-asus：健康的代送者（up）；fh-l：宣告 power.launch（有 target_ip
# 與 via），是 2026-09-25 那台的形狀；plainp：沒宣告，down 時無從問起。
cat > "$NODES_DIR/fh_proxy_asus.json" <<'JSON'
{"name":"fh-proxy-asus","role":"provider","gateway_port":2300,"user":"worker"}
JSON
cp -p "$NODES_DIR/fh_proxy_asus.json" "$NODES_DIR/fh-proxy-asus.json"
cat > "$NODES_DIR/fh_l.json" <<'JSON'
{"name":"fh-l","role":"provider","gateway_port":2323,"user":"worker","power":{"launch":{"method":"wol-unicast","via":["fh-proxy-asus"],"mac":"B4:2E:99:FB:63:5E","target_ip":"192.168.0.136"},"shutdown":{"method":"ssh","command":"sudo systemctl poweroff"}}}
JSON
cp -p "$NODES_DIR/fh_l.json" "$NODES_DIR/fh-l.json"
cat > "$NODES_DIR/plainp.json" <<'JSON'
{"name":"plainp","role":"provider","gateway_port":2305,"user":"worker"}
JSON
printf 'NODE_FH_PROXY_ASUS\nNODE_FH_L\nNODE_PLAINP\n' > "$SANDBOX/gh-vars"

SSH_LOG="$SANDBOX/ssh.log"; PR_LOG="$SANDBOX/pr.log"
export SSH_LOG PR_LOG NODES_DIR
export GH_VARS_FILE="$SANDBOX/gh-vars" PROBE_MAP="$SANDBOX/probe-map"

log_count() { grep -c "$2" "$1" 2>/dev/null || true; }

# ls_case <mlp-path> <tag>：source 真檔、強制顏色、跑 cmd_ls。
# 夾具（probe-map／PING_*）由呼叫端先備好。產出 $SANDBOX/<tag>.out/.err，
# 並把結果放 LS_RC/LS_SSH/LS_PING/LS_PR。
ls_run() {
    local mlp_path="$1" tag="$2"
    : > "$SSH_LOG"; : > "$PR_LOG"
    local rc=0
    MLP_FILE="$mlp_path" OUT="$SANDBOX/$tag.out" ERR="$SANDBOX/$tag.err" \
    PATH="$SHIMS:$PATH" HOME="$HOME_DIR" bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        C_GREEN="<g>"; C_YELLOW="<y>"; C_RED="<r>"; C_RESET="</>"; C_BOLD=""
        ( cmd_ls >"$OUT" 2>"$ERR" ) || exit $?
    ' 2>/dev/null || rc=$?
    LS_RC="$rc"
    LS_SSH="$(log_count "$SSH_LOG" 'CALL-EOL')"
    LS_PING="$(log_count "$SSH_LOG" 'timeout 3 ping')"
    LS_PR="$(log_count "$PR_LOG" 'PR ')"
}
row_of() { awk -v n="$2" '$1 == n {print}' "$1" 2>/dev/null; }

echo "=== 0. 先決條件 ==="
missing=0
for fn in lan_ping_probe node_lan_liveness print_state cmd_ls cmd_wake cmd_down; do
    if grep -qE "^${fn}\\(\\)" "$MLP"; then
        :
    else
        bad "0. ${fn} 不存在——實作還沒落地？"
        missing=1
    fi
done
if [[ "$missing" -eq 0 ]]; then
    ok "0. 新舊函式都在（lan_ping_probe／node_lan_liveness／print_state／消費端）"
fi

echo "=== 1. ls 三態不可互相退化（實際字串＋顏色） ==="
# S1：fh-l 埠 down、ping 有回應 → out-of-pool（黃）：開著的機器不准顯示 off/down。
printf '2300:up\n2323:down\n2305:down\n' > "$SANDBOX/probe-map"
PING_RC=0 ls_run "$REPO/$MLP" s1
fh_row="$(row_of "$SANDBOX/s1.out" fh-l)"
if [[ "$LS_RC" -eq 0 ]] && printf '%s' "$fh_row" | grep -qF '<y>out-of-pool' \
&& ! printf '%s' "$fh_row" | grep -qF '<r>off' \
&& ! printf '%s' "$fh_row" | grep -qF '<r>down' \
&& printf '%s' "$fh_row" | grep -q '2323'; then
    ok "1a. 活著但隧道不通 → out-of-pool（黃），不是 off／down（row [$fh_row]）"
else
    bad "1a. 三態退化（got [$fh_row]）"
fi
# S2：ping 不通（rc=1）→ off（紅），且與 out-of-pool 分得開。
PING_RC=1 ls_run "$REPO/$MLP" s2
fh_row="$(row_of "$SANDBOX/s2.out" fh-l)"
if printf '%s' "$fh_row" | grep -qF '<r>off' \
&& ! printf '%s' "$fh_row" | grep -qF '<y>out-of-pool' \
&& ! printf '%s' "$fh_row" | grep -qF '<r>down'; then
    ok "1b. ping 不通 → off（紅），不是 out-of-pool／down"
else
    bad "1b. off 與 out-of-pool 混了（got [$fh_row]）"
fi
# S6：埠探測 inconclusive（沒觀察到）→ 自己的字（黃），且不撥 ping、不多問。
printf '2300:up\n2323:inconclusive\n2305:down\n' > "$SANDBOX/probe-map"
PING_RC=0 ls_run "$REPO/$MLP" s6
fh_row="$(row_of "$SANDBOX/s6.out" fh-l)"
if printf '%s' "$fh_row" | grep -qF '<y>inconclusive' \
&& ! printf '%s' "$fh_row" | grep -qF '<r>down' \
&& ! printf '%s' "$fh_row" | grep -qF '<y>out-of-pool' \
&& [[ "$LS_PING" == "0" ]] \
&& ! grep -q '^PR fh-l$' "$PR_LOG" 2>/dev/null; then
    ok "1c. 沒觀察到 → inconclusive（黃），不猜 off／down、不撥 ping、不做後續解析"
else
    bad "1c. inconclusive 被說成別的（row [$fh_row] ping=$LS_PING pr [$(tr '\n' ' ' < "$PR_LOG" 2>/dev/null | head -c 120)]）"
fi
# 沒有宣告 power.launch 的 down 節點：不能 ping，維持 down——它是觀察，
# 不是猜測；「問不到」與「不用問」都不可假裝成 off。
plain_row="$(row_of "$SANDBOX/s2.out" plainp)"
if printf '%s' "$plain_row" | grep -qF '<r>down'; then
    ok "1d. 無 power.launch 的 down 節點維持 down（無從問起的事不假裝問過）"
else
    bad "1d. 沒宣告的節點狀態不對（got [$plain_row]）"
fi

echo "=== 2. off 必須是問過代送者才說的（其餘一律 unknown） ==="
# S3：ping rc=2（no route／權限）不是證據 → unknown，不是 off。
printf '2300:up\n2323:down\n2305:down\n' > "$SANDBOX/probe-map"
PING_RC=2 ls_run "$REPO/$MLP" s3
fh_row="$(row_of "$SANDBOX/s3.out" fh-l)"
if printf '%s' "$fh_row" | grep -qF '<y>unknown' \
&& ! printf '%s' "$fh_row" | grep -qF '<r>off'; then
    ok "2a. ping 非 0/1 → unknown（不知道不裝成關著）"
else
    bad "2a. 不知道被說成關著（got [$fh_row]）"
fi
# S4：ssh 噪音（run_on_node 失敗會印 stderr）＋rc=1 → 不是證據 → unknown。
PING_NOISE=1 PING_RC=1 ls_run "$REPO/$MLP" s4
fh_row="$(row_of "$SANDBOX/s4.out" fh-l)"
if printf '%s' "$fh_row" | grep -qF '<y>unknown' \
&& ! printf '%s' "$fh_row" | grep -qF '<r>off'; then
    ok "2b. ping 指令本身壞掉（有噪音）→ unknown"
else
    bad "2b. 基礎設施噪音被當成關機證據（got [$fh_row]）"
fi
PING_NOISE=0
# S5：唯一代送者自己 down → 沒有可用代送者 → unknown。
printf '2300:down\n2323:down\n2305:down\n' > "$SANDBOX/probe-map"
PING_RC=0 ls_run "$REPO/$MLP" s5
fh_row="$(row_of "$SANDBOX/s5.out" fh-l)"
if printf '%s' "$fh_row" | grep -qF '<y>unknown' \
&& [[ "$LS_PING" == "0" ]]; then
    ok "2c. 無 live 代送者 → unknown、不亂撥（ping=${LS_PING}）"
else
    bad "2c. 沒有可用代送者卻下結論（got [$fh_row] ping=${LS_PING}）"
fi
# 2d：位址壞掉（單元）→ unknown，不執行 ping。
got="$(MLP_FILE="$REPO/$MLP" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" SSH_LOG="$SSH_LOG" bash -c '
    source "$MLP_FILE" >/dev/null 2>&1
    : > "$SSH_LOG"
    rc=0; lan_ping_probe fh-proxy-asus "not an ip!" || rc=$?
    printf "RC=%s STATE=%s PING=%s" "$rc" "$NODE_LAN_STATE" "$(grep -c "timeout 3 ping" "$SSH_LOG")"
' 2>/dev/null)"
if [[ "$got" == "RC=2 STATE=unknown PING=0" ]]; then
    ok "2d. 壞位址 → unknown、零 ping（不亂發射）"
else
    bad "2d. 壞位址處理不對（got [$got]）"
fi

echo "=== 3. 成本：全 up 時零額外 ssh／零 ping（帳本） ==="
printf '2300:up\n2323:up\n2305:up\n' > "$SANDBOX/probe-map"
PING_RC=0 ls_run "$REPO/$MLP" s7
# 三節點全 up：master(1)＋探測(3)＋pool-port-alloc(1)＝5 次 ssh，零 ping，
# 零額外解析（只有 gateway 一次）。
if [[ "$LS_SSH" == "5" && "$LS_PING" == "0" && "$LS_PR" == "4" ]]; then
    ok "3a. 全 up：恰 5 次 ssh（master＋3 探測＋alloc）、0 ping、0 額外解析（4＝gateway＋3 節點）"
else
    bad "3a. 全 up 仍多花成本（ssh=${LS_SSH} ping=${LS_PING} pr=${LS_PR}）"
fi
# 對照：有 down 節點時只多一個 ping（證明成本是「只對 down 才問」的）。
printf '2300:up\n2323:down\n2305:down\n' > "$SANDBOX/probe-map"
PING_RC=0 ls_run "$REPO/$MLP" s1b
if [[ "$LS_PING" == "1" ]] && grep -q '^PR fh-l$' "$PR_LOG" 2>/dev/null; then
    ok "3b. 有 down 才問（1 ping、且確實對 fh-l 做了後續解析）"
else
    bad "3b. down 時的帳本不對（ping=$LS_PING pr [$(tr '\n' ' ' < "$PR_LOG" 2>/dev/null | head -c 120)]）"
fi

echo "=== 4. gw_probe_port 三態（單元） ==="
# gw_case <tag> <FAKE_GW_MODE> <want>：ssh 失敗／沒跑到標記→inconclusive；
# nc 跑完沒 banner→down；banner→up。
gw_case() {
    local tag="$1" mode="$2" want="$3" got
    got="$(MLP_FILE="$REPO/$MLP" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" FAKE_GW_MODE="$mode" bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        CTL=/tmp/stub-ctl
        printf "%s" "$(gw_probe_port 2323)"
    ' 2>/dev/null)"
    if [[ "$got" == "$want" ]]; then
        ok "4. $tag → $want"
    else
        bad "4. $tag → got [$got] want [$want]"
    fi
}
gw_case "ssh 自己失敗（master 抖動）" ssh-fail inconclusive
gw_case "輸出缺 NC_DONE 標記（遠端命令沒跑完）" partial inconclusive
gw_case "nc 跑完、沒有 banner" no-banner down
gw_case "nc 跑完、有 banner" banner up

echo "=== 5. 既有消費端不受影響（第三態不可提前下結論） ==="
# 5a：cmd_wake 只認 up——inconclusive 不叫成功，且繼續輪詢到預算用完
#     （單一代送者＝末台吃剩餘 300 秒 ÷ 5 秒＝60 次探測）。
printf '2300:up\n2323:inconclusive\n2305:down\n' > "$SANDBOX/probe-map"
: > "$SSH_LOG"; : > "$PR_LOG"
wake_rc=0
MLP_FILE="$REPO/$MLP" OUT="$SANDBOX/wake.out" ERR="$SANDBOX/wake.err" \
PATH="$SHIMS:$PATH" HOME="$HOME_DIR" bash -c '
    source "$MLP_FILE" >/dev/null 2>&1
    ( cmd_wake fh-l >"$OUT" 2>"$ERR" ) || exit $?
' 2>/dev/null || wake_rc=$?
wake_nc="$(log_count "$SSH_LOG" 'nc 127.0.0.1 2323')"
if [[ "$wake_rc" -ne 0 ]] && ! grep -qF 'is up' "$SANDBOX/wake.out" 2>/dev/null \
&& [[ "$wake_nc" == "60" ]]; then
    ok "5a. cmd_wake：inconclusive 不叫成功，且輪詢滿 60 次（不提前放棄）"
else
    bad "5a. cmd_wake 對 inconclusive 的行為不對（rc=$wake_rc nc=$wake_nc out [$(tr '\n' ' ' < "$SANDBOX/wake.out" 2>/dev/null | head -c 140)]）"
fi
# 5b：cmd_down 只認 down——inconclusive 不叫關機，且輪詢滿 120 秒 ÷ 5＝24 次。
: > "$SSH_LOG"; : > "$PR_LOG"
down_rc=0
MLP_FILE="$REPO/$MLP" OUT="$SANDBOX/down.out" ERR="$SANDBOX/down.err" \
PATH="$SHIMS:$PATH" HOME="$HOME_DIR" bash -c '
    source "$MLP_FILE" >/dev/null 2>&1
    ( cmd_down fh-l >"$OUT" 2>"$ERR" ) <<< "yes" || exit $?
' 2>/dev/null || down_rc=$?
down_nc="$(log_count "$SSH_LOG" 'nc 127.0.0.1 2323')"
if [[ "$down_rc" -ne 0 ]] && ! grep -qF 'is down' "$SANDBOX/down.out" 2>/dev/null \
&& [[ "$down_nc" == "24" ]]; then
    ok "5b. cmd_down：inconclusive 不叫關機，且輪詢滿 24 次（不提前結論）"
else
    bad "5b. cmd_down 對 inconclusive 的行為不對（rc=$down_rc nc=$down_nc out [$(tr '\n' ' ' < "$SANDBOX/down.out" 2>/dev/null | head -c 140)]）"
fi

echo "=== 6-9. 注入：拿掉修正，斷言必須轉紅 ==="
# inject <n> <tag>：把 needle 換成 replacement，寫到沙箱 ops-scripts/ 下
# （SCRIPT_DIR 對，REPO_ROOT 才對），bash -n 過，needle 命中數必須 1。
make_mutant() {
    local n="$1" old_file="$2" new_file="$3"
    python3 - "$REPO/$MLP" "$old_file" "$new_file" "$REPO/ops-scripts/mlp-mutant-$n" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = open(sys.argv[2], encoding="utf-8").read()
new = open(sys.argv[3], encoding="utf-8").read()
assert src.count(old) == 1, "needle count != 1: %d" % src.count(old)
open(sys.argv[4], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
}
mktmpf() { printf '%s' "$2" > "$SANDBOX/nd-$1"; }

# 6. out-of-pool 併回 down → 開著的機器被說成關著。
mktmpf i1old '                    alive) state="out-of-pool" ;;
'
mktmpf i1new '                    alive) state="down" ;;
'
INJ1="$REPO/ops-scripts/mlp-mutant-1"
if ! make_mutant 1 "$SANDBOX/nd-i1old" "$SANDBOX/nd-i1new" 2>"$SANDBOX/i1-mk.err"; then
    inj_bad "6. 注入腳本失敗（needle 落空）——harness 問題"
elif ! bash -n "$INJ1" 2>/dev/null; then
    inj_bad "6. 注入版語法錯誤——harness 問題"
else
    printf '2300:up\n2323:down\n2305:down\n' > "$SANDBOX/probe-map"
    PING_RC=0 ls_run "$INJ1" i1
    fh_row="$(row_of "$SANDBOX/i1.out" fh-l)"
    if printf '%s' "$fh_row" | grep -qF '<y>out-of-pool'; then
        inj_bad "6. 併回 down 後 1a 仍綠——out-of-pool 沒被量到"
    else
        if printf '%s' "$fh_row" | grep -qF '<r>down'; then
            inj_ok "6. 併回 down 後開著的機器顯示 down（got [$fh_row]）——1a 會紅"
        else
            inj_bad "6. 行為變了但不是預期的 down（got [$fh_row]）——harness 問題"
        fi
    fi
fi
# 7. ping 失敗（rc 非 0/1）當成 off → 不知道被說成關著。
mktmpf i2old '        *)     NODE_LAN_STATE="unknown"; return 2 ;;
'
mktmpf i2new '        *)     NODE_LAN_STATE="off"; return 1 ;;
'
INJ2="$REPO/ops-scripts/mlp-mutant-2"
if ! make_mutant 2 "$SANDBOX/nd-i2old" "$SANDBOX/nd-i2new" 2>"$SANDBOX/i2-mk.err"; then
    inj_bad "7. 注入腳本失敗（needle 落空）——harness 問題"
elif ! bash -n "$INJ2" 2>/dev/null; then
    inj_bad "7. 注入版語法錯誤——harness 問題"
else
    printf '2300:up\n2323:down\n2305:down\n' > "$SANDBOX/probe-map"
    PING_RC=2 ls_run "$INJ2" i2
    fh_row="$(row_of "$SANDBOX/i2.out" fh-l)"
    if printf '%s' "$fh_row" | grep -qF '<y>unknown'; then
        inj_bad "7. rc=2 當 off 後 2a 仍綠——不知道的界線沒被量到"
    else
        if printf '%s' "$fh_row" | grep -qF '<r>off'; then
            inj_ok "7. rc=2 被當 off（got [$fh_row]）——2a 會紅"
        else
            inj_bad "7. 行為變了但不是預期的 off（got [$fh_row]）——harness 問題"
        fi
    fi
fi
# 8. 拿掉「只對 down 且宣告 power.launch」的條件 → 全 up 時也去 ping。
mktmpf i3old '        if [[ "$state" == "down" && "$type" == "provider" ]]; then
'
mktmpf i3new '        if [[ "$type" == "provider" ]]; then
'
INJ3="$REPO/ops-scripts/mlp-mutant-3"
if ! make_mutant 3 "$SANDBOX/nd-i3old" "$SANDBOX/nd-i3new" 2>"$SANDBOX/i3-mk.err"; then
    inj_bad "8. 注入腳本失敗（needle 落空）——harness 問題"
elif ! bash -n "$INJ3" 2>/dev/null; then
    inj_bad "8. 注入版語法錯誤——harness 問題"
else
    printf '2300:up\n2323:up\n2305:up\n' > "$SANDBOX/probe-map"
    PING_RC=0 ls_run "$INJ3" i3
    if [[ "$LS_PING" == "0" && "$LS_SSH" == "5" && "$LS_PR" == "1" ]]; then
        inj_bad "8. 拿掉條件後 3a 仍綠——成本沒被量到"
    else
        if [[ "$LS_PING" == "1" ]]; then
            inj_ok "8. 全 up 也去 ping（got ssh=$LS_SSH ping=$LS_PING pr=${LS_PR}）——3a 會紅"
        else
            inj_bad "8. 行為變了但帳本不是預期（ssh=$LS_SSH ping=$LS_PING pr=${LS_PR}）——harness 問題"
        fi
    fi
fi
# 9. gw_probe_port 的 ssh 失敗當成 down → 沒觀察到被說成觀察到沒在聽。
mktmpf i4old '    if [[ $rc -ne 0 || "$out" != *"NC_DONE"* ]]; then
        printf '"'"'inconclusive'"'"'
        return
    fi
'
mktmpf i4new '    if [[ $rc -ne 0 || "$out" != *"NC_DONE"* ]]; then
        printf '"'"'down'"'"'
        return
    fi
'
INJ4="$REPO/ops-scripts/mlp-mutant-4"
if ! make_mutant 4 "$SANDBOX/nd-i4old" "$SANDBOX/nd-i4new" 2>"$SANDBOX/i4-mk.err"; then
    inj_bad "9. 注入腳本失敗（needle 落空）——harness 問題"
elif ! bash -n "$INJ4" 2>/dev/null; then
    inj_bad "9. 注入版語法錯誤——harness 問題"
else
    got="$(MLP_FILE="$INJ4" PATH="$SHIMS:$PATH" HOME="$HOME_DIR" FAKE_GW_MODE=ssh-fail bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        CTL=/tmp/stub-ctl
        printf "%s" "$(gw_probe_port 2323)"
    ' 2>/dev/null)"
    if [[ "$got" == "inconclusive" ]]; then
        inj_bad "9. ssh 失敗改報 down 後 4 仍綠——三態沒被量到"
    else
        if [[ "$got" == "down" ]]; then
            inj_ok "9. ssh 失敗被當成 down（got [$got]）——4 會紅"
        else
            inj_bad "9. 行為變了但不是預期的 down（got [$got]）——harness 問題"
        fi
    fi
fi

# 這條不驗行為，驗的是「來源」：哨兵字串本身是跨 repo 的契約。
# 上面那些 fixture 也寫死 NC_DONE，所以改名確實會讓它們變紅——但紅的訊息會是
# 「banner 沒認出來」，看到的人最自然的動作是把 fixture 一起改掉，然後綠燈恢復，
# 而 MyAiEntry 那邊靜靜地壞掉。所以這裡要一條**訊息會講話**的斷言：改名的人
# 必須先讀完這段話，才改得動它。
echo "── 6. 哨兵字串是跨 repo 契約（改名前必讀） ──"
if grep -q 'printf %s NC_DONE' "$MLP" && grep -q '"\$out" != \*"NC_DONE"\*' "$MLP"; then
    ok "6. gw_probe_port 仍用 NC_DONE，且仍同時檢查 rc 與標記"
else
    bad "6. 哨兵或其檢查被改了。這不是本地細節：MyAiEntry 的 poolReachability 照同一個形狀重寫了這支探測，改掉哨兵名、拿掉它、或只檢查 rc，都會把他們的三態退回兩態——而他們的兩態會把「沒觀察到」報成「不可達」，後果是一條指令沒跑完就讓整池機器被標成全滅、喚醒那邊白燒 300 秒。兩邊沒有任何 build 會發現。要改就先通知他們（ops-scripts/mlp 的 gw_probe_port 註解有寫）"
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
