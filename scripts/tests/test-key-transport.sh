#!/usr/bin/env bash
# test-key-transport.sh — task K: FILE_CRYPTO_KEY must never reach any
# command line. Behavioral, not textual: fake ssh / install.sh / git / gh /
# sudo are placed first on PATH, and each fake records the FULL argv it was
# handed plus the exact bytes it read from stdin. Assertions read those
# recordings, never the source text.
#
# Why argv matters: ps lets every user on the box read another process's
# argv, and any error message that echoes the command leaks it a second time
# (RUNBOOK.md §9 — that rule cost two real leaks). stdin leaves nothing.
#
# ---- 2026-09-26：register 段的假 clone 完整性与「退出碼不可信」------------
#
# **qa 說「8 個 arm 全紅」是錯的，這裡實測 rc=0 / passed 23 / failed 0。**
# 為什麼沒紅，完整鏈如下（三段都是實測，不是推論）：
#
# 1. **fixture 確實不完整。** 假 clone 由 fake git 從 FAKE_REPO_TEMPLATE 複製
#    過來，實測內容只有 6 個檔：profile.json、三個單位的 install.sh、
#    refresh-authkeys.sh、lib/authkeys.sh。而 register-provider.sh 會 source
#    **四個**：authkeys / refresh-wait / refresh-authkeys / tunnel-key。
#    缺 tunnel-key.sh 與 refresh-wait.sh。
# 2. **那條路徑有被走到，而且真的死在裡面。** reg.out 最後一行就是
#      register-provider.sh: line 654: .../scripts/lib/tunnel-key.sh:
#      No such file or directory
#    step 6.5 之後（step 7/7.5/8/9/9.5）一行都沒有。`$REPO_DIR` 指的是假 clone，
#    不是真 repo——第 3 步的 fake git 印出來過。
# 3. **但行程仍然 exit 0。** 這是關鍵，也是 qa 與我第一輪都沒算到的：
#      bash 的 `set -e` 被「source 一個不存在的檔案」觸發時，**若設了 EXIT
#      trap，退出碼會變成 0，而且 trap 裡的 `$?` 也是 0**。最小重現（本機
#      bash 3.2.57）：
#          set -e; . /nonexistent/f.sh; echo after    → rc=1，after 不印
#          set -e; trap ':' EXIT; . /nonexistent/f.sh  → rc=0，after 不印
#      對照組（證明不是「任何 trap 都吃掉任何失敗」）：
#          trap + `false`        → rc=1
#          trap + `. ./e.sh`（該檔 exit 3）→ rc=3
#          trap + `x=$(exit 7)`  → rc=7
#          trap + 明寫 `exit 9`  → rc=9
#      只有「errexit + source 缺檔」這一個組合會被吃掉，而
#      register-provider.sh 第 21 行正好有 `trap 'rm -rf "$REPO_DIR"' EXIT`。
#
# 所以修的不是「補一個檔」——補完之後同一個陷阱會把**下一個**缺檔藏起來。
# 修的是兩件：
#
#   * **完整性判準改成推導。** 這支測試現在從 register-provider.sh 的文字
#     推出「它會從 clone source 哪些檔」，要求模板全部具備。repo 多一條
#     source，這裡就多一條要求——手列清單會漏，而且漏掉沒有徵兆。
#     為什麼會漏成這樣：register-provider.sh 自己只在 :829 為
#     refresh-authkeys.sh 與 lib/authkeys.sh 做了存在性檢查，而舊 fixture 正是
#     照著那一處手列的。**守衛的形狀被被測物的守衛形狀塑形了。**
#   * **「跑完」改用完成標記判定，不看退出碼。** rc 只能當必要條件。
#     `registration complete for node` 這行是退出碼造不出來的東西。
#
# 注入逐一挖掉推導清單裡的每一個檔，兩種失敗形狀都必須是紅：
#   * 有守衛的（authkeys / refresh-authkeys）→ 腳本自己 rc≠0。
#   * 沒有守衛的（refresh-wait / tunnel-key）→ **rc=0 但沒有完成標記**，
#     也就是 2026-09-26 真正發生過的那一幕。沒有完成標記這一條的話，這兩格
#     會是綠的。
#
# 順帶修掉一個被這個缺口藏起來的東西：step 6.5 還會呼叫
# dispatch_refresh_and_wait（scripts/lib/refresh-wait.sh），它輪詢
# `gh run list` 直到 completed。假 gh 以前對 workflow/run 一律「印 nothing、
# exit 0」，於是那個迴圈撐滿 300 秒才以「refresh failed」收場——把這支測試的
# 執行時間拉長五分鐘，而且失敗訊息與任何傳輸斷言無關。補上
# `workflow run` / `run list` / `run view` 三個應答之後，同一段從 300+ 秒
# 變成約 1 秒，而且 step 6.5 真的走完（這也是完成標記能出現的前提）。
#
# Three subjects:
#   1. scripts/rotate-gateway.sh  rotate_run_provision  (key over ssh stdin)
#   2. scripts/provision-gateway.sh (key piped to each unit's install.sh)
#   3. ops-scripts/register-provider.sh unit loop (same shape)
#
# provision-gateway.sh runs as root and hardcodes /home/fatesaikou and
# /etc/... paths, none of which can exist on the machine that runs this
# test. The harness therefore runs a copy with ONLY those path constants
# replaced, and verifies with diff that nothing else changed — if the copy
# deviates in any other line, the harness is declared untrusted and the
# dependent assertions FAIL rather than vouch for something they did not
# observe.
#
# Injection demo (paste in the task report), each in a throwaway copy of the
# tree: putting the key back into rotate's remote command must redden
# section 1; putting --key back into provision's unit calls must redden
# section 2; same for register-provider must redden section 3.
#
# Run: scripts/tests/test-key-transport.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

# A recognizable fake value, never the real crypto_key: "is the key in this
# argv" is only a clean question if the value cannot occur by accident.
KEY='TESTKEY-deadbeef-0123456789'
TOKEN='ghp_testtoken_7f3a91c2'
REALPATH="$PATH"

for f in scripts/rotate-gateway.sh scripts/provision-gateway.sh ops-scripts/register-provider.sh; do
    [[ -f "$f" ]] || echo "test-key-transport: ${f} is missing; its section will FAIL" >&2
done
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-key-transport.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin" "$SANDBOX/expected" "$SANDBOX/stdin" "$SANDBOX/reg-tmp"
printf '%s' "$KEY" > "$SANDBOX/expected/key.txt"

ARGV_LOG="$SANDBOX/argv.log"
ALL_ARGV="$SANDBOX/all-argv.log"
STDIN_DIR="$SANDBOX/stdin"
: > "$ARGV_LOG"; : > "$ALL_ARGV"

pass=0; fail=0; injpass=0; injfail=0
SELF_LOG="$SANDBOX/test-output.log"; : > "$SELF_LOG"
emit() { printf '%s\n' "$1"; printf '%s\n' "$1" >> "$SELF_LOG"; }
ok()   { emit "  ok    $1"; pass=$((pass + 1)); }
bad()  { emit "  FAIL  $1"; fail=$((fail + 1)); }
# 注入的結果**另外計數**：一個「注入沒有被觸發」不該被算成斷言失敗（那是 harness
# 的問題），但也絕不能被當成通過。摘要與退出碼都把它們算進去（見檔尾）。
inj_ok()  { emit "  ok    (注入) $1"; injpass=$((injpass + 1)); }
inj_bad() { emit "  FAIL  (注入) $1"; injfail=$((injfail + 1)); }
# Anything that might echo recorded content into a failure message goes
# through this, so the test itself can never become the leak it hunts.
sanitize() { printf '%s' "$1" | sed "s/${KEY}/<REDACTED>/g"; }

# ---------------------------------------------------------------------------
# Fakes. Each records its full argv, and the ones that can receive the key
# on stdin also save those exact bytes for later comparison.
# ---------------------------------------------------------------------------
cat > "$SANDBOX/bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
printf 'ssh|%s\n' "$*" >> "${ARGV_LOG:?}"
n=0
if [[ -d "${STDIN_DIR:-}" ]]; then
    while [[ -e "${STDIN_DIR}/ssh.${n}.stdin" ]]; do n=$((n + 1)); done
    cat > "${STDIN_DIR}/ssh.${n}.stdin"
else
    cat >/dev/null
fi
echo "SSH-2.0-OpenSSH_9.6 testbanner"
exit 0
FAKE_SSH

cat > "$SANDBOX/bin/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
printf 'sudo|%s\n' "$*" >> "${ARGV_LOG:-/dev/null}"
if [[ -n "${STDIN_DIR:-}" && ! -t 0 ]]; then
    cat >/dev/null
fi
exit 0
FAKE_SUDO

# The unit installer stand-in: logs "<unit>|<call-index>|<argv>" and saves
# stdin as <unit>.<index>.stdin, so every recorded call can be paired with
# the exact bytes its installer read. --check calls still exit 0.
cat > "$SANDBOX/fake-install.sh" <<'FAKE_INSTALL'
#!/usr/bin/env bash
unit="$(basename "$(dirname "$0")")"
n=0
if [[ -d "${STDIN_DIR:-}" ]]; then
    while [[ -e "${STDIN_DIR}/${unit}.${n}.stdin" ]]; do n=$((n + 1)); done
fi
printf 'unit|%s|%s|%s\n' "$unit" "$n" "$*" >> "${ARGV_LOG:?}"
cat > "${STDIN_DIR:-/dev/null}/${unit}.${n}.stdin"
if [[ "$unit" == "pool-runtime" ]]; then
    mkdir -p "${HOME}/.mylinuxpool/bin"
    printf '#!/usr/bin/env bash\necho "{\\"ip\\":\\"127.0.0.1\\",\\"tunnel_user\\":\\"tester\\"}"\n' \
        > "${HOME}/.mylinuxpool/bin/pool-resolve"
    chmod +x "${HOME}/.mylinuxpool/bin/pool-resolve"
    # PR-B（D8）：能力步驟會驗 wol，而 wol 的判準是「已安裝的那一份與單位的
    # files/pool-wol **逐位元組相同**」。provider 的 profile 的 shared_config 裡
    # 有 wol，所以真機上 pool-sync 的收斂迴圈會把它裝好；這個假 clone 不跑收斂
    # 迴圈，所以由 pool-runtime 這個假單位代勞——**從同一個 clone 裡的** wol 單位
    # 複製（$0 的兩層上層），不是造一個假檔案。少了這一步，註冊會死在能力步驟，
    # 而這一節量的是 argv/stdin，症狀會離真正的原因很遠。
    wsrc="$(cd "$(dirname "$0")/.." && pwd)/wol/files/pool-wol"
    if [[ -f "$wsrc" ]]; then
        cp "$wsrc" "${HOME}/.mylinuxpool/bin/pool-wol"
        chmod +x "${HOME}/.mylinuxpool/bin/pool-wol"
    fi
fi
exit 0
FAKE_INSTALL
chmod +x "$SANDBOX/fake-install.sh"

cat > "$SANDBOX/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf 'gh|%s\n' "$*" >> "${ARGV_LOG:-/dev/null}"
if [[ "${1:-}" == "repo" && "${2:-}" == "clone" ]]; then
    repo="$3"; dest="$4"; shift 4
    branch="master"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branch) branch="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    git clone --branch "$branch" "https://github.com/${repo}" "$dest"
    exit $?
fi
# api: serve a valid variables payload WITH the CLIENT_* entries
# registration needs. Registration sources the shared scripts and assembles
# authorized_keys from CLIENT_* before finishing; a body without them makes
# it abort at that step (task U follow-up), which would hide the install
# loop this section measures. The keys are fake but well-formed, and this
# suite is about argv/stdin transport, not key assembly.
if [[ "${1:-}" == "api" ]]; then
    # gh 能力（PR-B）：判準會對 profile 裡的每個 repo 打一次
    # `gh api --include repos/<repo> --jq .full_name`，讀得到 = exit 0。
    case "$*" in
      repos/*) printf '%s\n' "${GH_REPO_FULL_NAME:-FATESAIKOU/MyBrain}"; exit 0 ;;
    esac
    printf '%s\n' '{"total_count":2,"variables":[
      {"name":"CLIENT_FATESAIKOU_MAC","value":"{\"name\":\"fatesaikou-mac\",\"public_key\":\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKTTRANSPORTMAC mac@test\",\"added_at\":\"2026-09-16T12:00:00Z\"}"},
      {"name":"CLIENT_ACTIONS","value":"{\"name\":\"actions\",\"public_key\":\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKTTRANSPORTACT actions@test\",\"added_at\":\"2026-09-16T12:00:00Z\"}"}
    ]}'
    exit 0
fi
if [[ "${1:-}" == "variable" ]]; then cat >/dev/null; exit 0; fi
# workflow run / run list / run view — register-provider.sh 的 step 6.5 會
# dispatch_refresh_and_wait（scripts/lib/refresh-wait.sh），它用 nonce 認領
# 自己的 run（displayTitle 比對），等到 completed 才讀 conclusion。
# 假 gh 以前對這三個都是「印 nothing、exit 0」：dispatch 被接受，但 run 永遠
# 不會出現，於是那個迴圈撐到 300 秒逾時。症狀是這一段每次慢 5 分鐘，然後以
# 「refresh failed」收場——而不是任何一條與傳輸有關的斷言。
# 這裡把三個都答成「成功」，讓 step 6.5 真的走完；`--jq` 是真的 gh 做的，
# 假 gh 直接印 post-jq 的結果——也就是 waiter 當前查詢的形狀
# ("<id> <status> <conclusion>"，舊碼是兩欄的 "<id> <status>")。
if [[ "${1:-}" == "workflow" ]]; then exit 0; fi
if [[ "${1:-}" == "run" ]]; then
    case "${2:-}" in
        list)  printf '4242 completed success\n'; exit 0 ;;
        view)  printf 'success\n'; exit 0 ;;
    esac
    exit 0
fi
exit 0
FAKE_GH

cat > "$SANDBOX/bin/git" <<'FAKE_GIT'
#!/usr/bin/env bash
printf 'git|%s\n' "$*" >> "${ARGV_LOG:-/dev/null}"
if [[ "${1:-}" == "clone" ]]; then
    dest=""
    for a in "$@"; do dest="$a"; done
    mkdir -p "$dest"
    cp -R "${FAKE_REPO_TEMPLATE:?}/." "$dest/"
    chmod -R u+w "$dest" 2>/dev/null || true
    exit 0
fi
exit 0
FAKE_GIT

# provision-gateway.sh is written for a root Linux box: it checks id -u and
# calls sshd/systemctl/chown/fail2ban-client. All of them are stubbed here
# so the run reaches step 3 (the unit install loop under test).
cat > "$SANDBOX/bin/id" <<'FAKE_ID'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then echo 0; exit 0; fi
exec /usr/bin/id "$@" 2>/dev/null || exit 0
FAKE_ID

# `ss` is special: provisioning verifies each requested port is really
# listening before it accepts the new socket config. A stub that printed
# nothing would make that check fail and roll back, which is not what this
# suite is about (test-gateway-ssh-port.sh covers the check itself).
cat > "$SANDBOX/bin/ss" <<'FAKE_SS'
#!/usr/bin/env bash
printf 'ss|%s\n' "$*" >> "${ARGV_LOG:-/dev/null}"
printf 'LISTEN 0 4096 0.0.0.0:ssh 0.0.0.0:*\n'
exit 0
FAKE_SS

for t in sshd systemctl fail2ban-client chown apt-get dpkg loginctl docker flock nc curl; do
    cat > "$SANDBOX/bin/$t" <<FAKE_TOOL
#!/usr/bin/env bash
printf '$t|%s\n' "\$*" >> "\${ARGV_LOG:-/dev/null}"
exit 0
FAKE_TOOL
done
chmod +x "$SANDBOX/bin/"*
chmod +x "$STDIN_DIR" 2>/dev/null || true

reset_capture() {
    : > "$ARGV_LOG"
    rm -rf "$STDIN_DIR"; mkdir -p "$STDIN_DIR"
}

# ---------------------------------------------------------------------------
# Shared assertion helpers for the two unit-install loops.
# ---------------------------------------------------------------------------
# check_unit_transport <label> <log-file> <expect-stdin> — every recorded
# install call must (a) carry no --key and no key value on argv, and (b) when
# expect-stdin=key, have received the exact key on stdin. A multi-unit loop
# that reads stdin inside the loop gets the key only for the first unit — the
# stdin half is what catches that.
#
# expect-stdin=none is the provider-registration contract after KEY-DESIGN
# §8: every unit a provider installs is needs_key=false, so registration
# pipes nothing at all. Asserting a key there would demand a key nobody
# consumes (and re-introduce the very coupling §8 removed).
check_unit_transport() {
    local label="$1" log="$2" expect_stdin="${3:-key}"
    local tag unit idx args f got
    local n_calls=0 n_real=0 n_bad_argv=0 n_bad_stdin=0 n_empty=0 n_with_key=0

    # First pass: what did the calls actually receive?
    local any_stdin=0
    while IFS='|' read -r tag unit idx args; do
        [[ "$tag" == "unit" ]] || continue
        case "$args" in *--check*) continue ;; esac
        f="${STDIN_DIR}/${unit}.${idx}.stdin"
        [[ -s "$f" ]] && any_stdin=1
    done < "$log"

    if [[ ! -s "$log" ]]; then
        bad "${label}: no install calls were recorded at all"
        return
    fi
    while IFS='|' read -r tag unit idx args; do
        [[ "$tag" == "unit" ]] || continue
        n_calls=$((n_calls + 1))
        case "$args" in
            *--key*) n_bad_argv=$((n_bad_argv + 1)) ;;
        esac
        case "$args" in
            *"$KEY"*) n_bad_argv=$((n_bad_argv + 1)) ;;
        esac
        case "$args" in
            *--check*) continue ;;
        esac
        n_real=$((n_real + 1))
        f="${STDIN_DIR}/${unit}.${idx}.stdin"
        got="$(cat "$f" 2>/dev/null)"
        if [[ -z "$got" ]]; then
            n_empty=$((n_empty + 1))
        elif [[ "$got" != "$KEY" ]]; then
            n_bad_stdin=$((n_bad_stdin + 1))
        fi
    done < "$log"

    if [[ "$n_calls" -ge 1 ]]; then
        ok "${label}: recorded ${n_calls} install call(s)"
    else
        bad "${label}: recorded 0 install calls"
        return
    fi
    if [[ "$n_real" -ge 2 ]]; then
        ok "${label}: ${n_real} non-check install calls (multi-unit loop actually exercised)"
    else
        bad "${label}: only ${n_real} non-check install call(s) — a multi-unit stdin starvation bug could not show"
    fi
    if [[ "$n_bad_argv" -eq 0 ]]; then
        ok "${label}: no --key and no key value on any recorded argv"
    else
        bad "${label}: ${n_bad_argv} install call(s) had --key or the key value on argv"
    fi
    if [[ "$expect_stdin" == "none" ]]; then
        if [[ "$any_stdin" -eq 0 ]]; then
            ok "${label}: no key was piped at all (every unit needs_key=false since KEY-DESIGN §8)"
        else
            bad "${label}: a key was piped to an install call, but no provider unit consumes one"
        fi
    else
        if [[ "$n_empty" -eq 0 ]]; then
            ok "${label}: no install call was handed an empty key"
        else
            bad "${label}: ${n_empty} install call(s) received an EMPTY key on stdin (stdin was consumed earlier)"
        fi
        if [[ "$n_bad_stdin" -eq 0 ]]; then
            ok "${label}: every non-check install call received exactly the key on stdin"
        else
            bad "${label}: ${n_bad_stdin} install call(s) received something other than the key"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 1) rotate_run_provision
# ---------------------------------------------------------------------------
emit "── 1) rotate_run_provision ──"
ROTATE_SH="scripts/rotate-gateway.sh"
if [[ -f "$ROTATE_SH" ]]; then
    # shellcheck source=../rotate-gateway.sh
    source "$ROTATE_SH"
fi

if declare -F rotate_run_provision >/dev/null 2>&1; then
    reset_capture
    (
        export PATH="$SANDBOX/bin:$REALPATH" ARGV_LOG STDIN_DIR
        rotate_run_provision testuser 203.0.113.9 "10.1.1.1 10.1.1.2" "$KEY"
    ) > "$SANDBOX/rotate.out" 2>&1
    rot_rc=$?
    cat "$ARGV_LOG" >> "$ALL_ARGV"

    if [[ "$rot_rc" -eq 0 ]]; then
        ok "rotate_run_provision returns 0 (the call actually ran)"
    else
        bad "rotate_run_provision exited ${rot_rc}: $(sanitize "$(tail -2 "$SANDBOX/rotate.out" | tr '\n' ' ')")"
    fi
    if grep -q '^ssh|' "$ARGV_LOG" 2>/dev/null; then
        ok "the fake ssh was invoked and its argv recorded"
        if grep -qF "$KEY" "$ARGV_LOG" 2>/dev/null; then
            bad "the key value appears in the recorded ssh argv: $(sanitize "$(grep -F "$KEY" "$ARGV_LOG" | head -1)")"
        else
            ok "the key value is absent from the recorded ssh argv"
        fi
        if grep -qF 'POOL_TRUSTED_IPS' "$ARGV_LOG" 2>/dev/null; then
            ok "POOL_TRUSTED_IPS still travels in the ssh command (not a secret, must not be dropped)"
        else
            bad "POOL_TRUSTED_IPS is missing from the ssh command"
        fi
        rot_stdin="$(ls "$STDIN_DIR"/ssh.*.stdin 2>/dev/null | head -1)"
        if [[ -z "$rot_stdin" ]]; then
            bad "the fake ssh received no stdin at all (the key must travel on stdin)"
        else
            got="$(cat "$rot_stdin")"
            if [[ "$got" == "$KEY" ]]; then
                ok "the fake ssh received exactly the key on stdin"
            else
                bad "ssh stdin was not the key (${#got} byte(s) received)"
            fi
        fi
    else
        bad "the fake ssh was never invoked — nothing about transport was observed"
    fi
else
    bad "rotate_run_provision is not defined (${ROTATE_SH} missing or no such function)"
fi

# ---------------------------------------------------------------------------
# 2) provision-gateway.sh — step 3's unit install loop
# ---------------------------------------------------------------------------
emit "── 2) provision-gateway.sh unit install loop ──"
PROV_SRC="scripts/provision-gateway.sh"
PROV_COPY="$SANDBOX/provision.sandboxed.sh"
PROV_TRUSTED=0
if [[ -f "$PROV_SRC" ]]; then
    sed \
        -e 's|^REPO_DIR="/home/fatesaikou/.mylinuxpool/repo"$|REPO_DIR="${SANDBOX_REPO:?}"|' \
        -e 's|^WORKERS_DIR="/home/fatesaikou/.mylinuxpool/workers.d"$|WORKERS_DIR="${SANDBOX_WORKERS:?}"|' \
        -e 's|^SSHD_CONF="/etc/ssh/sshd_config.d/10-mylinuxpool.conf"$|SSHD_CONF="${SANDBOX_SSHD_CONF:?}"|' \
        -e 's|^FAIL2BAN_CONF="/etc/fail2ban/jail.d/mylinuxpool-ignore.conf"$|FAIL2BAN_CONF="${SANDBOX_FAIL2BAN_CONF:?}"|' \
        -e 's|^SSH_SOCKET_CONF="/etc/systemd/system/ssh.socket.d/10-mylinuxpool.conf"$|SSH_SOCKET_CONF="${SANDBOX_SSH_SOCKET_CONF:?}"|' \
        -e 's|home="/home/fatesaikou"|home="${SANDBOX_HOME_A:?}"|' \
        -e 's|home="/home/sshproxy"|home="${SANDBOX_HOME_B:?}"|' \
        -e 's|--check --home /home/fatesaikou --user fatesaikou|--check --home "${SANDBOX_HOME_A:?}" --user fatesaikou|' \
        "$PROV_SRC" > "$PROV_COPY"

    diff_out="$(diff "$PROV_SRC" "$PROV_COPY" 2>/dev/null || true)"
    n_changed="$(printf '%s\n' "$diff_out" | grep -cE '^[<>]' || true)"
    untrusted=""
    while IFS= read -r dl; do
        [[ -n "$dl" ]] || continue
        case "$dl" in
            *REPO_DIR*|*WORKERS_DIR*|*SSHD_CONF*|*SSH_SOCKET_CONF*|*FAIL2BAN_CONF*|*home=*|*--check\ --home*) ;;
            *) untrusted="${untrusted}${dl} " ;;
        esac
    done < <(printf '%s\n' "$diff_out" | grep -E '^[<>]' || true)

    if [[ "$n_changed" -eq 0 ]]; then
        bad "sandbox copy of provision-gateway.sh applied no path substitutions (harness broken)"
    elif [[ -n "$untrusted" ]]; then
        bad "sandbox copy differs beyond path constants — nothing below can be trusted: $(sanitize "$untrusted")"
    else
        PROV_TRUSTED=1
        ok "sandbox copy differs from the subject only in the root/hardcoded path constants (${n_changed} diff lines)"
    fi
else
    bad "${PROV_SRC} is missing"
fi

PROV_REPO="$SANDBOX/prov-repo"
mkdir -p "$PROV_REPO/shared-configs"
for u in pool-runtime ssh-admin rclone standalonescripts dotfiles gh ssh-tunnel-server; do
    mkdir -p "$PROV_REPO/shared-configs/$u"
    cp "$SANDBOX/fake-install.sh" "$PROV_REPO/shared-configs/$u/install.sh"
    chmod +x "$PROV_REPO/shared-configs/$u/install.sh"
done

if [[ "$PROV_TRUSTED" -eq 1 ]]; then
    reset_capture
    printf '%s' "$KEY" | env -i \
        PATH="$SANDBOX/bin:$REALPATH" \
        HOME="$SANDBOX/prov-home" \
        TMPDIR="$SANDBOX/prov-tmp" \
        POOL_TRUSTED_IPS="10.1.1.1 10.1.1.2" \
        SANDBOX_REPO="$PROV_REPO" \
        SANDBOX_WORKERS="$SANDBOX/prov-workers" \
        SANDBOX_SSHD_CONF="$SANDBOX/prov-sshd.conf" \
        SANDBOX_FAIL2BAN_CONF="$SANDBOX/prov-fail2ban.conf" \
        SANDBOX_SSH_SOCKET_CONF="$SANDBOX/prov-ssh-socket.conf" \
        SANDBOX_HOME_A="$SANDBOX/prov-home-a" \
        SANDBOX_HOME_B="$SANDBOX/prov-home-b" \
        ARGV_LOG="$ARGV_LOG" STDIN_DIR="$STDIN_DIR" \
        /bin/bash "$PROV_COPY" > "$SANDBOX/prov.out" 2>&1
    prov_rc=$?
    cat "$ARGV_LOG" >> "$ALL_ARGV"
    mkdir -p "$SANDBOX/prov-tmp"

    if [[ "$prov_rc" -eq 0 ]]; then
        ok "provision-gateway.sh runs to completion under the stubs (exit 0)"
    else
        bad "provision-gateway.sh exited ${prov_rc}: $(sanitize "$(tail -3 "$SANDBOX/prov.out" | tr '\n' ' ')")"
    fi
    check_unit_transport "provision loop" "$ARGV_LOG" key
else
    bad "provision loop: harness copy untrusted; transport not verified"
    bad "provision loop: multi-unit loop not exercised"
    bad "provision loop: argv cleanliness not verified"
    bad "provision loop: stdin delivery not verified"
fi

# ---------------------------------------------------------------------------
# 3) register-provider.sh — its unit install loop
# ---------------------------------------------------------------------------
emit "── 3) register-provider.sh unit install loop ──"
REG_SRC="ops-scripts/register-provider.sh"
TPL="$SANDBOX/register-template"
mkdir -p "$TPL/profiles/provider/no-sudo" "$TPL/shared-configs" "$TPL/scripts/lib"
# profile 的 capabilities 用 repo 裡那一份 provider profile 的（形狀不自己編）。
# step7_5_capabilities 是照 clone 裡的 profile 逐鍵去問 runner 的；沒有
# capabilities 時那一段沒有東西可驗，註冊會在 7.5 就 exit 1——而症狀是
# 「register-provider 沒跑到最後」，離真正的原因很遠。
jq -c '{shared_config:["pool-runtime","unit-alpha","unit-beta"],sudoers_rules:[],systemd_user_services:[],linger:false}
       + {capabilities: (.capabilities // {})} ' \
    < profiles/provider/no-sudo/profile.json > "$TPL/profiles/provider/no-sudo/profile.json"
# 三個真單位（PR-A 的產物）。能力步驟現場查 unit.json 再跑該單位的 --check；
# 沒有這三個目錄，每個鍵都會被算成「沒有單位實作」（rc=2）→ 註冊失敗。
for u in worker-host gh wol; do
    mkdir -p "$TPL/shared-configs/$u/files"
    cp "shared-configs/$u/unit.json"  "$TPL/shared-configs/$u/unit.json"
    cp "shared-configs/$u/install.sh" "$TPL/shared-configs/$u/install.sh"
    chmod +x "$TPL/shared-configs/$u/install.sh"
    [[ -f "shared-configs/$u/files/pool-wol" ]] \
        && cp "shared-configs/$u/files/pool-wol" "$TPL/shared-configs/$u/files/pool-wol"
done
for u in pool-runtime unit-alpha unit-beta; do
    mkdir -p "$TPL/shared-configs/$u"
    cp "$SANDBOX/fake-install.sh" "$TPL/shared-configs/$u/install.sh"
    chmod +x "$TPL/shared-configs/$u/install.sh"
done
# 假 clone 必須帶齊 register-provider.sh **自己會從 clone 裡 source 的每一個檔案**。
#
# 為什麼推導而不手列（2026-09-26）：舊版手列 refresh-authkeys.sh 與
# lib/authkeys.sh，而 register-provider.sh 實際上 source 四個
# （authkeys / refresh-wait / tunnel-key / refresh-authkeys）。漏掉的那兩個
# 確實讓這一次執行死在 step 6.5——而**這條測試當時回報 rc=0、23/0 全綠**。
# 為什麼會綠見下面「退出碼不可信」那段。手列清單的問題不是漏了兩個檔，而是
# 漏掉沒有徵兆：repo 多一條 source 就多一個缺口，而測試不會講。
# 現在這份清單是從 register-provider.sh 的文字推導出來的，它多一條 source，
# 這裡就多一條要求。
clone_required_files() {   # 從腳本本身推導，不手列
    grep -oE '\$\{REPO_DIR\}/[A-Za-z0-9_./-]+\.sh' "$1" \
        | sed 's|^\${REPO_DIR}/||' | sort -u
}
REQUIRED_CLONE_FILES="$(clone_required_files "$REG_SRC")"
if [[ -z "$REQUIRED_CLONE_FILES" ]]; then
    bad "register 段：推導不出 register-provider.sh 從 clone source 了哪些檔案（守衛本身失效）"
    REQUIRED_CLONE_FILES=""
fi
for rel in $REQUIRED_CLONE_FILES; do
    if [[ ! -f "$rel" ]]; then
        bad "register 段：register-provider.sh 會 source '${rel}'，但 repo 裡沒有這個檔——這是 repo 的問題，不是夾具的"
        continue
    fi
    mkdir -p "$TPL/$(dirname "$rel")"
    cp "$rel" "$TPL/$rel"
done
# 完整性判準抽成函式，這樣注入時可以對「被挖掉一個檔的模板」再跑一次——
# 沒有這個彈性就無法證明這條判準會紅（而一條不會紅的判準等於沒有）。
# 判準不是手列：推導出的每一個路徑都必須真的在模板裡。這也抓到「推導漏掉」的
# 情形——日後有人用字串拼接組出 source 路徑，grep 抓不到，這裡抓得到。
clone_missing() {   # clone_missing <template-dir>：印出缺的路徑（空 = 齊全）
    local tpl="$1" rel out=""
    for rel in $REQUIRED_CLONE_FILES; do
        [[ -f "$tpl/$rel" ]] || out="${out}${rel} "
    done
    printf '%s' "$out"
}
missing_in_template="$(clone_missing "$TPL")"
if [[ -n "$missing_in_template" ]]; then
    bad "register 段：假 clone 缺 ${missing_in_template}——register-provider.sh 會 source 它們（用推導清單，不要手列）"
else
    ok "register 段：假 clone 帶齊 register-provider.sh 會 source 的全部 $(printf '%s\n' $REQUIRED_CLONE_FILES | grep -c .) 個檔（推導，不手列）"
fi

# 把 register 那一段抽成函式：正常跑一次，注入再跑一次（對挖掉檔的模板）。
# 兩次都真的執行 register-provider.sh，所以注入測的是行為，不是字串。
run_register() {   # run_register <template> <outfile> → 全域 reg_rc / reg_done
    local tpl="$1" outf="$2" rc=0 done_flag=0
    reset_capture
    env -i \
        PATH="$SANDBOX/bin:$REALPATH" \
        HOME="$SANDBOX/reg-home" \
        TMPDIR="$SANDBOX/reg-tmp" \
        USER="testuser" \
        FILE_CRYPTO_KEY="$KEY" \
        GH_POOL_TOKEN="$TOKEN" \
        ARGV_LOG="$ARGV_LOG" STDIN_DIR="$STDIN_DIR" \
        FAKE_REPO_TEMPLATE="$tpl" \
        /bin/bash "$REG_SRC" --name testnode --gateway-port 2301 --no-sudo \
        </dev/null > "$outf" 2>&1 || rc=$?
    cat "$ARGV_LOG" >> "$ALL_ARGV"
    grep -q 'registration complete for node' "$outf" 2>/dev/null && done_flag=1
    REGRC="$rc"; REGDONE="$done_flag"
}

REG_TRUSTED=0
if [[ -f "$REG_SRC" ]]; then REG_TRUSTED=1; fi

if [[ "$REG_TRUSTED" -eq 1 ]]; then
    run_register "$TPL" "$SANDBOX/reg.out"
    reg_rc="$REGRC"; reg_done="$REGDONE"

    # **退出碼在這裡不可信，必須看有沒有走到最後。**
    #
    # 2026-09-26 實測：register-provider.sh 的 EXIT trap 會把 `set -e` 的中止
    # 變成 exit 0。最小重現（本機 bash 3.2.57）：
    #     set -e; . /nonexistent/f.sh; echo after   → rc=1、after 不印
    #     set -e; trap ':' EXIT; . /nonexistent/f.sh → rc=0、after 不印
    # 而 trap 裡的 $? 是 0，不是 1。所以「source 一個不存在的檔案」這一個
    # 特定的中止路徑，會被任何 EXIT trap 吃掉——而 register-provider.sh 有
    # `trap 'rm -rf "$REPO_DIR"' EXIT INT TERM`（第 21 行）。
    #
    # 這一條正是它發生過的地方：假 clone 缺 scripts/lib/tunnel-key.sh，
    # 腳本死在 step 6.5，reg.out 最後一行是
    #   register-provider.sh: line 654: .../scripts/lib/tunnel-key.sh: No such file
    # 而 reg_rc=0，於是這條斷言回報「runs to completion (exit 0)」。
    # 結論：**rc 只能當必要條件，不能當充分條件。** 真正判斷「跑完」的是
    # 最後那行完成標記——一個退出碼造不出來的東西。
    if [[ "$reg_rc" -eq 0 && "$reg_done" -eq 1 ]]; then
        ok "register-provider.sh 跑到最後（exit 0 且有完成標記）"
    elif [[ "$reg_rc" -eq 0 && "$reg_done" -eq 0 ]]; then
        bad "register-provider.sh exit 0 但**沒有**跑到最後——退出碼被 EXIT trap 吃掉了（set -e 的中止對『source 缺檔』會被 trap 轉成 0）。停在：$(sanitize "$(tail -2 "$SANDBOX/reg.out" | tr '\n' ' ')")"
    else
        bad "register-provider.sh exited ${reg_rc}（完成標記 reg_done=${reg_done}）: $(sanitize "$(tail -3 "$SANDBOX/reg.out" | tr '\n' ' ')")"
    fi
    check_unit_transport "register loop" "$ARGV_LOG" none

    # 注入：逐一挖掉 register-provider.sh 會 source 的**每一個**檔案。
    #
    # 為什麼逐一而不是挑一個：挖掉不同的檔會走進兩種不同的失敗形狀，而形狀本身
    # 就是這個注入要釘的東西。
    #   * 有守衛的（register-provider.sh:829 會先檢查 refresh-authkeys.sh 與
    #     lib/authkeys.sh 在不在）→ 腳本自己大聲失敗，rc≠0。
    #   * 沒有守衛的（tunnel-key.sh、refresh-wait.sh 是直接 `.` 進去的）→
    #     `set -e` 中止，然後**被 EXIT trap 轉成 rc=0**，只有完成標記抓得到。
    # 2026-09-26 真正發生的是第二種，而當時這支測試回報「runs to completion
    # (exit 0) 全綠」。兩種形狀都必須是「不是靜靜地通過」，所以判準是
    # **逐檔都不得回報成功**：rc≠0 或沒有完成標記。將來有人再加一條沒有守衛的
    # source，這個注入會立刻蓋到那一份名單上。
    INJ_TPL="$SANDBOX/register-template-gutted"
    inj_ok_n=0; inj_bad_n=0; inj_detail=""
    for INJ_REL in $REQUIRED_CLONE_FILES; do
        rm -rf "$INJ_TPL"; cp -R "$TPL" "$INJ_TPL"
        rm -f "$INJ_TPL/$INJ_REL"
        gutted_missing="$(clone_missing "$INJ_TPL")"
        run_register "$INJ_TPL" "$SANDBOX/reg-gutted.out"
        gutted_rc="$REGRC"; gutted_done="$REGDONE"
        [[ "$gutted_missing" == *"$INJ_REL"* ]] || inj_detail="${inj_detail} 完整性判準對 ${INJ_REL} 沒反應;"
        if [[ "$gutted_rc" -eq 0 && "$gutted_done" -eq 1 ]]; then
            inj_bad_n=$((inj_bad_n + 1))
            inj_detail="${inj_detail} 挖掉 ${INJ_REL} 竟然回報成功（rc=0 且有完成標記）;"
        else
            inj_ok_n=$((inj_ok_n + 1))
            # masked 形狀另外點名出來：那個是 rc 單獨看不見的
            if [[ "$gutted_rc" -eq 0 && "$gutted_done" -eq 0 ]]; then
                inj_detail="${inj_detail} ${INJ_REL}=rc0+無完成標記(masked);"
            else
                inj_detail="${inj_detail} ${INJ_REL}=rc${gutted_rc}; "
            fi
        fi
    done
    if [[ "$inj_ok_n" -eq 0 ]]; then
        inj_bad "注入：逐一挖掉 ${#REQUIRED_CLONE_FILES} 個 source 目標，沒有一個讓這支測試變紅——完整性判準與完成標記都失效了"
    elif [[ "$inj_bad_n" -ne 0 ]]; then
        inj_bad "注入：${inj_bad_n}/${#REQUIRED_CLONE_FILES} 個挖掉之後仍然回報成功：${inj_detail}"
    else
        inj_ok "注入：逐一挖掉全部 ${inj_ok_n} 個 source 目標，每一個都讓這支測試紅（${inj_detail}）"
    fi
else
    bad "${REG_SRC} is missing"
    bad "register loop: multi-unit loop not exercised"
    bad "register loop: argv cleanliness not verified"
    bad "register loop: stdin delivery not verified"
fi

# ---------------------------------------------------------------------------
# 4) reverse insurance: the test itself must not leak, and nothing may have
#    written the key anywhere except the two places designed to hold it.
# ---------------------------------------------------------------------------
emit "── 4) reverse insurance (no leak through argv, output, or disk) ──"
if grep -qF "$KEY" "$ALL_ARGV" 2>/dev/null; then
    bad "the key value appears in a recorded argv: $(sanitize "$(grep -F "$KEY" "$ALL_ARGV" | head -1)")"
else
    ok "the key value never appears in any recorded argv"
fi

for out in rotate.out prov.out reg.out; do
    if [[ -f "$SANDBOX/$out" ]] && grep -qF "$KEY" "$SANDBOX/$out" 2>/dev/null; then
        bad "the key value leaked into ${out} (a subject's own output): $(sanitize "$(grep -F "$KEY" "$SANDBOX/$out" | head -1)")"
    else
        ok "the key value is absent from ${out}"
    fi
done

leaked_paths="$(grep -rlF "$KEY" "$SANDBOX" 2>/dev/null \
    | grep -v "^${SANDBOX}/expected/" \
    | grep -v "^${STDIN_DIR}/" || true)"
if [[ -z "$leaked_paths" ]]; then
    ok "the key value exists on disk only in the harness's own expected/ and stdin/ files"
else
    bad "the key value was written somewhere it should not be: $(printf '%s' "$leaked_paths" | tr '\n' ' ')"
fi

if grep -qF "$KEY" "$SELF_LOG" 2>/dev/null; then
    bad "the test's own output leaked the key value"
else
    ok "the test's own output never contains the key value"
fi

emit ""
emit "passed ${pass} / failed ${fail} / injection-pass ${injpass} / injection-fail ${injfail}"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
