#!/usr/bin/env bash
# test-mlp-noninteractive.sh — 非互動防護：沒有鍵盤時，mlp 不得卡住，更不得做事。
#
# 在防什麼（真因比「卡住」嚴重）：
#   fzf 在非互動環境會從 /dev/tty 讀、永遠等不到——但 pick_power_target
#   遇到「恰一個候選」時根本不叫 fzf，直接回傳。全池只有 fh-l 宣告
#   power.launch，所以 `mlp wake </dev/null` 曾經真的送出 WoL 把機器叫醒、
#   還 exit 0：不是 hang，是**沒有人要求的副作用**。護欄因此不能只斷退出碼，
#   要用 stub 記帳數「pool-wol 被呼叫幾次」。
#   判定用 stdin 不是 stdout：stdout 接管線仍有人在看（mlp ls | grep），
#   stdin 接管線就沒人了。這條選擇要釘住，否則改成 stdout 會擋掉正常管線。
#
# 三類斷言：
#   1. 七條互動路徑（無子指令、wake、down、ssh、fwd rm、fwd add、worker new）
#      非互動 → exit 2、各自的提示、且 ssh／fzf／pool-resolve／gh 全零呼叫
#      （wake 另明列 pool-wol 為 0）。
#   2. 合理用法不被擋：真的造出「stdin 是 TTY、stdout 是管線」的情境
#      （python pty），mlp ls | tail、mlp state | grep 照常。
#   3. 受守衛的路徑在「stdin 是 TTY、stdout 是管線」時也不得被拒
#      （menu canary；stdout 判定會在這裡現形）＋ 靜態釘住判定是 -t 0。
#
# 全離線：pool-resolve / ssh / gh / fzf / sleep 全 PATH stub；jq 用真的。
# bash 3.2 相容（無陣列、無 ${var,,}、無 nameref）。
#
# Run: scripts/tests/test-mlp-noninteractive.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

MLP="ops-scripts/mlp"
SSH_LIB="scripts/lib/ssh.sh"
TUNNEL_ID="shared-configs/pool-runtime/files/tunnel-identity.sh"

for f in "$MLP" "$SSH_LIB" "$TUNNEL_ID"; do
    if [[ ! -f "$f" ]]; then
        echo "test-mlp-noninteractive: ${f} is missing; dependent cases will FAIL" >&2
    fi
done
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required (pty harness) but not found on PATH" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-mlp-noninteractive.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
REPO="$SANDBOX/repo"
mkdir -p "$SHIMS" "$HOME_DIR" "$REPO/ops-scripts" "$REPO/scripts/lib" \
         "$REPO/shared-configs/pool-runtime/files"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- 沙箱 repo：真 mlp＋真 ssh.sh＋解析 stub ---------------------------------
cp -p "$REPO_ROOT/$MLP" "$REPO/$MLP"
cp -p "$REPO_ROOT/$SSH_LIB" "$REPO/$SSH_LIB"
cp -p "$REPO_ROOT/$TUNNEL_ID" "$REPO/$TUNNEL_ID"
# 解析 stub：gateway／fh-l（單一候選，power.launch via 單一字串）；
# --expand-hops 對任何節點都回兩跳鏈（run_on_node 用）。
# 注意：gather_targets 只做大小寫轉換、不做底線轉連字號（與 power_targets
# 不同），所以 NODE_FH_L 查的是 fh_l——兩個拼法都要認。
cat > "$REPO/shared-configs/pool-runtime/files/pool-resolve" <<'FAKE'
#!/usr/bin/env bash
printf 'PR %s\n' "$*" >> "${PR_LOG:-/dev/null}"
if [[ "${2:-}" == "--expand-hops" ]]; then
    printf '[{"host":"9.9.9.9","port":22,"user":"gw"},{"host":"127.0.0.1","port":2300,"user":"worker"}]\n'
    exit 0
fi
case "${1:-}" in
    gateway) printf '{"ip":"9.9.9.9","user":"gw","port":22}\n'; exit 0 ;;
    fh-l|fh_l)
        printf '%s\n' '{"name":"fh-l","role":"provider","gateway_port":2323,"user":"worker","power":{"launch":{"method":"wol-unicast","via":"fh-proxy-asus","mac":"B4:2E:99:FB:63:5E","target_ip":"192.168.0.136"},"shutdown":{"method":"ssh","command":"sudo systemctl poweroff"}}}'
        exit 0 ;;
esac
exit 1
FAKE
chmod +x "$REPO/shared-configs/pool-runtime/files/pool-resolve"
# 突變還原用的乾淨副本：先備好，任何注入提早失敗都不影響後續。
cp -p "$REPO/$MLP" "$SANDBOX/mlp-fixed-keep"

# ---- PATH stubs --------------------------------------------------------------
# ssh：argv 一行一個＋CALL-EOL；nc 探測回 banner（讓 wake 路徑不真的等），
# pool-port-alloc 回空帳，state.json 回一致的空帳。
cat > "$SHIMS/ssh" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a" >> "${SSH_LOG:-/dev/null}"; done
printf 'CALL-EOL\n' >> "${SSH_LOG:-/dev/null}"
joined="$*"
case "$joined" in
  *"nc 127.0.0.1"*) printf 'SSH-2.0-OpenSSH_9.9\n'; exit 0 ;;
esac
case "$joined" in
  *pool-port-alloc*) printf '[]\n'; exit 0 ;;
esac
case "$joined" in
  *"cat /var/lib/mylinuxpool/state.json"*) printf '{"serial":"1","nodes":{"fh-l":{}},"workers":[]}\n'; exit 0 ;;
esac
exit 0
FAKE
# fzf：記帳；不讀 stdin（真 fzf 被叫到就會卡，這裡直接拒答）。
cat > "$SHIMS/fzf" <<'FAKE'
#!/usr/bin/env bash
printf 'FZF\n' >> "${FZF_LOG:-/dev/null}"
exit 1
FAKE
# gh：記帳；回固定 NODE_* 名單。
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'GH\n' >> "${GH_LOG:-/dev/null}"
cat "${GH_VARS_FILE:-/dev/null}" 2>/dev/null
exit 0
FAKE
# sleep：記帳不真等——若有路徑不該等卻在等，這裡會留下痕跡。
cat > "$SHIMS/sleep" <<'FAKE'
#!/usr/bin/env bash
printf 'SLEEP %s\n' "$*" >> "${SLEEP_LOG:-/dev/null}"
exit 0
FAKE
chmod +x "$SHIMS/ssh" "$SHIMS/fzf" "$SHIMS/gh" "$SHIMS/sleep"

GH_VARS_FILE="$SANDBOX/gh-vars"; printf 'NODE_FH_L\n' > "$GH_VARS_FILE"
SSH_LOG="$SANDBOX/ssh.log"; FZF_LOG="$SANDBOX/fzf.log"
GH_LOG="$SANDBOX/gh.log"; PR_LOG="$SANDBOX/pr.log"
SLEEP_LOG="$SANDBOX/sleep.log"
export SSH_LOG FZF_LOG GH_LOG PR_LOG SLEEP_LOG GH_VARS_FILE

reset_logs() { : > "$SSH_LOG"; : > "$FZF_LOG"; : > "$GH_LOG"; : > "$PR_LOG"; : > "$SLEEP_LOG"; }
count_log() { grep -c "$2" "$1" 2>/dev/null || true; }

# run_mlp <tag> [args...]：stdin=/dev/null，stdout/stderr 落檔，量測記帳。
# 結果放 MLP_RC / MLP_SSH / MLP_FZF / MLP_GH / MLP_PR / MLP_WOL。
run_mlp() {
    local tag="$1"; shift
    local rc=0
    reset_logs
    ( cd "$REPO" && PATH="$SHIMS:$PATH" HOME="$HOME_DIR" bash "$REPO/$MLP" "$@" ) \
        </dev/null >"$SANDBOX/$tag.out" 2>"$SANDBOX/$tag.err" || rc=$?
    MLP_RC="$rc"
    MLP_SSH="$(count_log "$SSH_LOG" 'CALL-EOL')"
    MLP_FZF="$(count_log "$FZF_LOG" 'FZF')"
    MLP_GH="$(count_log "$GH_LOG" 'GH')"
    MLP_PR="$(count_log "$PR_LOG" 'PR ')"
    MLP_WOL="$(count_log "$SSH_LOG" 'pool-wol')"
}

echo "=== 0. 先決條件 ==="
if grep -qE '^interactive_only\(\)' "$MLP" \
&& grep -qE '^cmd_wake\(\)' "$MLP" && grep -qE '^cmd_down\(\)' "$MLP"; then
    ok "0. interactive_only 與被守衛的入口都在"
else
    bad "0. interactive_only 不存在——實作還沒落地？"
fi

echo "=== 1. 非互動（stdin=/dev/null）：七條路徑 exit 2 且零副作用 ==="
# ni_case <tag> <needle> [args...]
ni_case() {
    local tag="$1" needle="$2"; shift 2
    run_mlp "$tag" "$@"
    if [[ "$MLP_RC" -ne 2 ]]; then
        bad "$tag 非互動：rc=${MLP_RC}（want 2）"
    elif ! grep -qF "$needle" "$SANDBOX/$tag.err" 2>/dev/null; then
        bad "$tag 非互動：沒印提示 [$needle]（err1=[$(head -1 "$SANDBOX/$tag.err" 2>/dev/null)]）"
    elif [[ "$MLP_SSH" != "0" || "$MLP_FZF" != "0" || "$MLP_GH" != "0" || "$MLP_PR" != "0" ]]; then
        bad "$tag 非互動：有副作用（ssh=$MLP_SSH fzf=$MLP_FZF gh=$MLP_GH resolve=${MLP_PR}）"
    else
        ok "$tag 非互動：rc=2、提示正確、零副作用（ssh/fzf/gh/resolve 皆 0）"
    fi
}
ni_case menu "usage: mlp [command]"
ni_case wake "usage: mlp wake" wake
ni_case down "usage: mlp down" down
ni_case ssh "usage: mlp ssh" ssh
ni_case fwdrm "usage: mlp fwd rm" fwd rm
ni_case fwdadd "usage: mlp fwd add" fwd add
ni_case wnew "needs an interactive terminal" worker new

# wake 的關鍵：分辨「印了 usage」與「送出了 WoL」——記帳要真的 0。
run_mlp wake2 wake
if [[ "$MLP_RC" -eq 2 && "$MLP_WOL" == "0" ]]; then
    ok "1w. wake 非互動：pool-wol 零呼叫（沒有沒人要求的喚醒）"
else
    bad "1w. wake 非互動：rc=$MLP_RC pool-wol=${MLP_WOL}（疑似真的送出）"
fi

echo "=== 2. 合理用法：stdin 是 TTY、stdout 是管線 ==="
# python pty 當 stdin；子行程的 stdout 走管線（tail/grep），證明 -t 0 判準
# 不會擋掉正常管線用法。inner script 自報 IN-TTY 讓夾具可自證。
cat > "$SANDBOX/pty-run.py" <<'PY'
#!/usr/bin/env python3
import os, pty, subprocess, sys
master, slave = pty.openpty()
proc = subprocess.Popen(['bash', sys.argv[1]], stdin=slave,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
os.close(slave)
os.close(master)
out, err = proc.communicate()
sys.stdout.write(out.decode('utf-8', 'replace'))
sys.stdout.write('--STDERR--\n')
sys.stdout.write(err.decode('utf-8', 'replace'))
sys.stdout.write('--PTY-RC--%d\n' % proc.returncode)
PY
pty_out=""
pty_run() { pty_out="$(python3 "$SANDBOX/pty-run.py" "$1" 2>&1)"; }

cat > "$SANDBOX/inner-ls.sh" <<EOF
test -t 0 && echo IN-TTY || echo IN-NOTTY
cd $REPO
PATH="$SHIMS:\$PATH" HOME=$HOME_DIR bash $REPO/$MLP ls 2>$SANDBOX/pty-ls.err | tail -2
printf 'MLPRC=%s\n' "\${PIPESTATUS[0]}"
EOF
pty_run "$SANDBOX/inner-ls.sh"
if printf '%s' "$pty_out" | grep -q 'IN-TTY' \
&& printf '%s' "$pty_out" | grep -q 'MLPRC=0' \
&& printf '%s' "$pty_out" | grep -q 'gateway' \
&& printf '%s' "$pty_out" | grep -q 'fh-l'; then
    ok "2a. mlp ls | tail：stdin 是 TTY、stdout 是管線 → 正常（含資料列）"
else
    bad "2a. mlp ls | tail 被誤擋或輸出缺列（pty_out [$(printf '%s' "$pty_out" | tr '\n' ' ' | head -c 220)]）"
fi

cat > "$SANDBOX/inner-state.sh" <<EOF
test -t 0 && echo IN-TTY || echo IN-NOTTY
cd $REPO
PATH="$SHIMS:\$PATH" HOME=$HOME_DIR bash $REPO/$MLP state 2>$SANDBOX/pty-state.err | grep consistent
printf 'MLPRC=%s\n' "\${PIPESTATUS[0]}"
EOF
pty_run "$SANDBOX/inner-state.sh"
if printf '%s' "$pty_out" | grep -q 'IN-TTY' \
&& printf '%s' "$pty_out" | grep -q 'MLPRC=0' \
&& printf '%s' "$pty_out" | grep -q 'consistent'; then
    ok "2b. mlp state | grep：stdin 是 TTY、stdout 是管線 → 正常"
else
    bad "2b. mlp state | grep 被誤擋（pty_out [$(printf '%s' "$pty_out" | tr '\n' ' ' | head -c 220)]）"
fi

# 受守衛的路徑在同樣「stdin TTY、stdout 管線」時也不得被拒——
# 這正是 stdout 判定會現形的地方（menu 會被誤擋）。
cat > "$SANDBOX/inner-menu.sh" <<EOF
test -t 0 && echo IN-TTY || echo IN-NOTTY
cd $REPO
PATH="$SHIMS:\$PATH" HOME=$HOME_DIR bash $REPO/$MLP 2>$SANDBOX/pty-menu.err | tail -1
printf 'MLPRC=%s\n' "\${PIPESTATUS[0]}"
EOF
pty_run "$SANDBOX/inner-menu.sh"
if printf '%s' "$pty_out" | grep -q 'IN-TTY' \
&& printf '%s' "$pty_out" | grep -q 'MLPRC=0'; then
    ok "2c. 受守衛的 menu：stdin TTY＋stdout 管線 → 放行（人類還在）"
else
    bad "2c. 受守衛的路徑被 stdout 管線誤擋（pty_out [$(printf '%s' "$pty_out" | tr '\n' ' ' | head -c 220)]）"
fi

echo "=== 3. 判定是 stdin 不是 stdout（靜態釘） ==="
io_body="$(awk '/^interactive_only\(\)/{infn=1; next} infn && $0 == "}" {infn=0; next} infn {print}' "$MLP")"
if printf '%s' "$io_body" | grep -qF '[[ -t 0 ]]' \
&& ! printf '%s' "$io_body" | grep -qF '[[ -t 1 ]]'; then
    ok "3. interactive_only 用 [[ -t 0 ]]（stdout 管線不會被當非互動）"
else
    bad "3. 判定不是 stdin（body [$(printf '%s' "$io_body" | tr '\n' ' ')）"
fi

echo "=== 4-6. 注入：拿掉修正，斷言必須轉紅 ==="
# 4. 拿掉 wake 守衛 → 非互動下真的送出 WoL（不是只有退出碼變）。
INJ1="$SANDBOX/mutant-noguard.sh"
python3 - "$REPO/$MLP" "$INJ1" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    if [[ -z "$node" ]]; then\n'
       '        # Omitting the name opens the picker — or, with exactly one\n'
       '        # candidate, pick_power_target returns it without fzf. That made\n'
       '        # `mlp wake </dev/null` wake the sole node FOR REAL and exit 0:\n'
       '        # not a hang but a side effect nobody asked for (2026-09-25).\n'
       '        # Refuse before resolve_gateway: no network, no side effect,\n'
       '        # immediately.\n'
       '        interactive_only || {\n'
       '            echo "usage: mlp wake [<node-name>]  (node must declare .power.launch; fzf pick when omitted)" >&2\n'
       '            exit 2\n'
       '        }\n'
       '    fi\n')
assert src.count(old) == 1, "wake-guard needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, '', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "4. 注入腳本失敗（needle 落空）——harness 問題"
elif ! bash -n "$INJ1" 2>/dev/null; then
    inj_bad "4. 注入版語法錯誤——harness 問題"
else
    cp -p "$REPO/$MLP" "$SANDBOX/mlp-fixed-keep"
    cp -p "$INJ1" "$REPO/$MLP"
    run_mlp inj1 wake
    cp -p "$SANDBOX/mlp-fixed-keep" "$REPO/$MLP"
    if [[ "$MLP_RC" -eq 2 && "$MLP_WOL" == "0" ]]; then
        inj_bad "4. 拿掉 wake 守衛後 1w 仍綠——WoL 沒被量到"
    else
        if [[ "$MLP_WOL" -ge 1 ]]; then
            inj_ok "4. 拿掉守衛後真的送出 WoL（got rc=$MLP_RC wol=${MLP_WOL}）——1w 會紅"
        else
            inj_bad "4. 行為變了但沒送 WoL（got rc=$MLP_RC wol=${MLP_WOL}）——harness 問題"
        fi
    fi
fi
# 5. 判定從 stdin 改成 stdout → stdout 是管線的受守衛路徑被誤擋。
INJ2="$SANDBOX/mutant-stdout.sh"
python3 - "$REPO/$MLP" "$INJ2" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '    [[ -t 0 ]]\n'
assert src.count(old) == 1, "t0 needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, '    [[ -t 1 ]]\n', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "5. 注入腳本失敗（needle 落空）——harness 問題"
elif ! bash -n "$INJ2" 2>/dev/null; then
    inj_bad "5. 注入版語法錯誤——harness 問題"
else
    cp -p "$INJ2" "$REPO/$MLP"
    io_body="$(awk '/^interactive_only\(\)/{infn=1; next} infn && $0 == "}" {infn=0; next} infn {print}' "$REPO/$MLP")"
    pty_run "$SANDBOX/inner-menu.sh"
    cp -p "$SANDBOX/mlp-fixed-keep" "$REPO/$MLP"
    static_red=0; pty_red=0
    printf '%s' "$io_body" | grep -qF '[[ -t 1 ]]' && static_red=1
    printf '%s' "$pty_out" | grep -q 'MLPRC=0' || pty_red=1
    if [[ "$static_red" -eq 0 && "$pty_red" -eq 0 ]]; then
        inj_bad "5. 改成 stdout 判定後 2c/3 仍綠——判定來源沒被量到"
    else
        inj_ok "5. 改成 stdout 判定後受守衛路徑被管線誤擋（static_red=$static_red pty_rc=$([ "$pty_red" -eq 1 ] && printf '非0' || printf 0)）——2c/3 會紅"
    fi
fi
# 6. 任一子指令守衛拿掉（挑 worker new）→ 該路徑回到副作用。
INJ3="$SANDBOX/mutant-wnew.sh"
python3 - "$REPO/$MLP" "$INJ3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    interactive_only || {\n'
       '        echo "mlp worker new needs an interactive terminal to pick provider and image (stdin is not a TTY)" >&2\n'
       '        exit 2\n'
       '    }\n')
assert src.count(old) == 1, "wnew-guard needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, '', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "6. 注入腳本失敗（needle 落空）——harness 問題"
elif ! bash -n "$INJ3" 2>/dev/null; then
    inj_bad "6. 注入版語法錯誤——harness 問題"
else
    cp -p "$INJ3" "$REPO/$MLP"
    run_mlp inj3 worker new
    cp -p "$SANDBOX/mlp-fixed-keep" "$REPO/$MLP"
    if [[ "$MLP_RC" -eq 2 && "$MLP_SSH" == "0" && "$MLP_FZF" == "0" ]]; then
        inj_bad "6. 拿掉 worker new 守衛後仍 rc=2 且零呼叫——沒被量到"
    else
        inj_ok "6. 拿掉守衛後回到副作用路徑（got rc=$MLP_RC ssh=$MLP_SSH fzf=${MLP_FZF}）——該路徑斷言會紅"
    fi
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
