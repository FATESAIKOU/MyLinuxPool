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
# ---- 2026-09-26：pty 夾具與「2a/2b 到底在驗什麼」------------------------
#
# **qa 的結論在這台機器上重現不出來，但指出的漏洞是真的。** qa 說
# `pty-run.py` 在 Popen 之後立刻 `os.close(master)` 會讓 slave 掉掉 tty 特性，
# 並附上 IN-NOTTY 的對照。實測（macOS 26.6.2 / bash 3.2.57，各 40 次）：
# 關 master 與保留 master **都是 40/40 IN-TTY**，而 `tty` 報 `/dev/ttys023`。
# 所以「關 master 就掉 tty」在這裡是假的——但它仍是一個該修的隱憂，理由不是
# qa 說的那個：
#
#   * 關掉 master 之後，子行程的 fd0 指向一個**對端已不存在**的 pty。之後任何
#     對 fd0 的讀取立刻拿到 EOF/EIO，而 `isatty()` 在關閉 master 之後的行為
#     是**平台相關**的。也就是說舊版把這三條斷言的成立與否押在一個未記載的
#     平台行為上——正是這個 repo 修過多次的「測試環境比生產寬容」。
#   * 若被測物真的讀 stdin（現在的內層腳本不讀），舊版會讀到 EOF 而**看起來
#     像非互動**，於是斷言會以一個**假的理由**變紅。
# 修法：master 留到子行程結束才關，並用一個執行緒把 master 讀空（否則「沒人在
# 讀的 pty 寫滿緩衝區」會變成新的死鎖）。
#
# **2a/2b 與 2c 驗的不是同一件事**（這是量出來的，不是推論的）。反轉
# `interactive_only()` 的判斷之後：
#   * 2c（跑無子指令的 `mlp`）→ 變紅，因為那條路徑真的過守衛。
#   * 2a（`mlp ls`）、2b（`mlp state`）→ **不會變**，因為這兩條命令本來就沒有
#     被 interactive_only 守衛（唯讀清單／比對命令不需要鍵盤）。它們量的是
#     「tty stdin ＋ 管線 stdout 這個環境不會擋住正常輸出」，是**環境 canary**。
#   * §1 也抓不到反轉：stdin=/dev/null 時 `! -t 0` 為假 → 照樣拒絕 → exit 2。
# 所以 2c 是這個檔案裡**唯一**能分辨「守衛讀了 tty」與「守衛反了」的斷言。
# 這一點連同「2a/2b 不受影響」都釘在注入 7 裡，將來有人把它們說成守衛覆蓋時
# 會先被擋下。
#
# 2z 是新增的夾具自我驗證：把「stdin 真的是 tty」從 2a/2b/2c 的附帶條件提成
# 獨立一條。為什麼要提：若真正壞掉的是 pty 夾具（沒給 tty），2a/2b/2c 會用
# 「mlp 誤擋」這個**假的理由**紅，而真正的故障沒有任何地方會講出來。
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
#
# fh-proxy-asus 是 fh-l 的**代送方**。D6 之後（PR-C）它還必須能被解析、而且
# **宣告 `wol`**，否則 `mlp wake` 會把它略過（宣告讀不到 → 不當成有資格），
# 一個封包都不送。少了它，注入 4（拿掉 wake 守衛 → 應該真的送出 WoL）會得到
# `wol=0`，而紅的原因看起來像「守衛拿掉也沒用」——其實是「沒人合格」。
# 這裡補的是**現實的形狀**，命題不變：守衛拿掉之後真的要送得出 WoL。
cat > "$REPO/shared-configs/pool-runtime/files/pool-resolve" <<'FAKE'
#!/usr/bin/env bash
printf 'PR %s\n' "$*" >> "${PR_LOG:-/dev/null}"
if [[ "${2:-}" == "--expand-hops" ]]; then
    printf '[{"host":"9.9.9.9","port":22,"user":"gw"},{"host":"127.0.0.1","port":2300,"user":"worker"}]\n'
    exit 0
fi
case "${1:-}" in
    gateway) printf '{"ip":"9.9.9.9","user":"gw","port":22}\n'; exit 0 ;;
    fh-proxy-asus|fh_proxy_asus)
        printf '%s\n' '{"name":"fh-proxy-asus","role":"provider","gateway_port":2300,"user":"worker","capabilities":{"worker-host":{"runtime":"docker"},"wol":{"methods":["unicast"]}}}'
        exit 0 ;;
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
# 用真的 pty 當 stdin，把子行程的 stdout／stderr 導到管線。
#
# **master 必須開到子行程結束。** 舊版在 Popen 之後立刻 `os.close(master)`。
# 那不會讓子行程的 fd0 變成非 tty（實測：本機 macOS 26.6 / bash 3.2.57，
# 關與不關都是 40/40 IN-TTY），但它會留下一個**對端已經不存在的 pty**：任何
# 對 fd0 的讀取立刻拿到 EOF/EIO，而 isatty() 在關閉 master 後的行為是
# **平台相關**的（Linux 的 slave 保持 tty、讀取 EIO；macOS 上本實測保持 tty）。
# 換句話說舊版把這個斷言的成立與否押在一個未記載的平台行為上——這正是本 repo
# 修過多次的那種形狀（「測試環境比生產寬容」）。
#
# master 留著還有一個實務理由：若子行程（或被測物）真的讀 stdin，舊版會讀到
# EOF 而看起來像「非互動」，於是斷言會以一個**假的理由**變紅。
# 留著 master 之後要擔心的是相反方向——沒有人在讀的 pty 寫滿緩衝區會死鎖。
# 內層腳本不寫 tty（stdout/stderr 都是管線），但這不是應該靠假設的性質，
# 所以用一個執行緒把 master 讀空。
import os, pty, subprocess, sys, threading

master, slave = pty.openpty()
proc = subprocess.Popen(['bash', sys.argv[1]], stdin=slave,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
# 父行程自己那份 slave 可以關：子行程已經有自己的 fd 0 副本。
os.close(slave)
drained = []
def drain():
    try:
        while True:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            drained.append(chunk)
    except OSError:
        pass
t = threading.Thread(target=drain)
t.daemon = True
t.start()
out, err = proc.communicate()
t.join(timeout=5)
os.close(master)          # 最後才關，而且只在子行程結束後
sys.stdout.write(out.decode('utf-8', 'replace'))
sys.stdout.write('--STDERR--\n')
sys.stdout.write(err.decode('utf-8', 'replace'))
sys.stdout.write('--PTY-RC--%d\n' % proc.returncode)
sys.stdout.write('--TTY-BYTES--%d\n' % sum(len(c) for c in drained))
PY
pty_out=""
TTY_CANARY=0
pty_run() { pty_out="$(python3 "$SANDBOX/pty-run.py" "$1" 2>&1)"; }

cat > "$SANDBOX/inner-ls.sh" <<EOF
test -t 0 && echo IN-TTY || echo IN-NOTTY
cd $REPO
PATH="$SHIMS:\$PATH" HOME=$HOME_DIR bash $REPO/$MLP ls 2>$SANDBOX/pty-ls.err | tail -2
printf 'MLPRC=%s\n' "\${PIPESTATUS[0]}"
EOF
# 夾具自我驗證（2z）：這一段是「stdin 真的是 tty」這件事**唯一的**證據。
# 為什麼要獨立成條：2a/2b/2c 都把 IN-TTY 當附帶條件，而它們失敗時的訊息讀起來
# 是「mlp 被誤擋」。若真正壞掉的是 pty 夾具（沒有真的 tty），那三條會用一個
# **假的理由**紅——「mlp 擋掉了這條命令」——而真正的故障（夾具沒給 tty）不會
# 被任何地方講出來。獨立的 2z 讓兩件事分開。
cat > "$SANDBOX/inner-canary.sh" <<EOF
test -t 0 && echo IN-TTY || echo IN-NOTTY
printf 'TTYNAME=%s\n' "\$(tty 2>/dev/null || echo none)"
EOF
pty_run "$SANDBOX/inner-canary.sh"
if printf '%s' "$pty_out" | grep -qx 'IN-TTY' \
&& printf '%s' "$pty_out" | grep -q '^TTYNAME=/dev/' \
&& ! printf '%s' "$pty_out" | grep -q 'IN-NOTTY'; then
    ok "2z. pty 夾具自我驗證：子行程的 fd0 真的是 tty（$(printf '%s' "$pty_out" | sed -n 's/^TTYNAME=//p' | head -1)）"
    TTY_CANARY=1
else
    bad "2z. pty 夾具沒給出 tty——後面 2a/2b/2c 的失敗會被誤讀成「mlp 誤擋」（got [$(printf '%s' "$pty_out" | tr '\n' ' ' | head -c 160)]）"
    TTY_CANARY=0
fi

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

# 7. **把判斷反過來**（`[[ ! -t 0 ]]`）→ 受守衛的那一條（2c）必須轉紅。
#
#    這一條是「2c 真的在驗 tty」的證明。為什麼需要它：2c 斷的是「stdin 是 tty
#    時不該被擋」，而**正確的守衛與一個永遠放行的守衛在那個情境裡給出同一個
#    結果**——只靠正向情境分辨不出「守衛有在讀 tty」與「守衛根本沒讀」。反過來
#    之後兩者第一次產生可觀察差異。
#
#    量測結果是 **1/3，不是 3/3**，而那個 1 就是 2c。原因是機械的：
#      * 2a 跑 `mlp ls`、2b 跑 `mlp state`——**這兩條命令本來就沒有被
#        interactive_only 守衛**（它們是唯讀的清單／比對命令）。所以守衛怎麼
#        改，它們的 rc 都不變。它們量的是「tty stdin ＋ 管線 stdout 這個環境
#        不會擋住正常輸出」，是**環境canary**，不是守衛斷言。
#      * 2c 跑的是無子指令的 `mlp`，那條路徑才真的過 interactive_only。
#    §1（非互動）也抓不到反轉：stdin=/dev/null 時 `! -t 0` 為假 → 照樣拒絕 →
#    exit 2 → §1 全綠。**所以 2c 是這個檔案裡唯一能分辨「守衛讀了 tty」與
#    「守衛反了」的斷言。**
#    這一條順帶把「2a/2b 不受影響」釘成事實：將來有人把它們說成守衛覆蓋，
#    這一條會先把那個說法擋下來（2a/2b 若跟著紅，就表示它們的範圍變了）。
INJ4="$SANDBOX/mutant-inverted.sh"
python3 - "$REPO/$MLP" "$INJ4" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '    [[ -t 0 ]]\n'
assert src.count(old) == 1, "t0 needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, '    [[ ! -t 0 ]]\n', 1))
PYEOF
if [[ $? -ne 0 ]]; then
    inj_bad "7. 注入腳本失敗（needle 落空）——harness 問題"
elif ! bash -n "$INJ4" 2>/dev/null; then
    inj_bad "7. 注入版語法錯誤——harness 問題"
else
    cp -p "$INJ4" "$REPO/$MLP"
    pty_run "$SANDBOX/inner-menu.sh"
    guarded_rc="$pty_out"
    pty_run "$SANDBOX/inner-ls.sh"
    unguarded_ls="$pty_out"
    pty_run "$SANDBOX/inner-state.sh"
    unguarded_state="$pty_out"
    cp -p "$SANDBOX/mlp-fixed-keep" "$REPO/$MLP"
    g_red=0; u_ls_red=0; u_st_red=0
    printf '%s' "$guarded_rc"     | grep -q 'MLPRC=0' || g_red=1
    printf '%s' "$unguarded_ls"  | grep -q 'MLPRC=0' || u_ls_red=1
    printf '%s' "$unguarded_state" | grep -q 'MLPRC=0' || u_st_red=1
    if [[ "$g_red" -eq 1 && "$u_ls_red" -eq 0 && "$u_st_red" -eq 0 ]]; then
        inj_ok "7. 反轉 [[ -t 0 ]] → 2c（受守衛）紅、2a/2b（未受守衛的 ls/state）不紅——2c 確實在讀 tty，而且只有它能讀"
    else
        inj_bad "7. 反轉後 guarded_red=${g_red} 2a_red=${u_ls_red} 2b_red=${u_st_red}（期望 1/0/0）——2c 的覆蓋或本檔對 2a/2b 的理解有問題"
    fi
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
