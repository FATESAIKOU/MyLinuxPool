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

pass=0; fail=0
SELF_LOG="$SANDBOX/test-output.log"; : > "$SELF_LOG"
emit() { printf '%s\n' "$1"; printf '%s\n' "$1" >> "$SELF_LOG"; }
ok()   { emit "  ok    $1"; pass=$((pass + 1)); }
bad()  { emit "  FAIL  $1"; fail=$((fail + 1)); }
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
    printf '%s\n' '{"total_count":2,"variables":[
      {"name":"CLIENT_FATESAIKOU_MAC","value":"{\"name\":\"fatesaikou-mac\",\"public_key\":\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKTTRANSPORTMAC mac@test\",\"added_at\":\"2026-09-16T12:00:00Z\"}"},
      {"name":"CLIENT_ACTIONS","value":"{\"name\":\"actions\",\"public_key\":\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKTTRANSPORTACT actions@test\",\"added_at\":\"2026-09-16T12:00:00Z\"}"}
    ]}'
    exit 0
fi
if [[ "${1:-}" == "variable" ]]; then cat >/dev/null; exit 0; fi
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

for t in sshd systemctl fail2ban-client chown apt-get dpkg loginctl docker flock ss nc curl; do
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
            *REPO_DIR*|*WORKERS_DIR*|*SSHD_CONF*|*FAIL2BAN_CONF*|*home=*|*--check\ --home*) ;;
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
printf '%s\n' '{"shared_config":["pool-runtime","unit-alpha","unit-beta"],"sudoers_rules":[],"systemd_user_services":[],"linger":false}' \
    > "$TPL/profiles/provider/no-sudo/profile.json"
for u in pool-runtime unit-alpha unit-beta; do
    mkdir -p "$TPL/shared-configs/$u"
    cp "$SANDBOX/fake-install.sh" "$TPL/shared-configs/$u/install.sh"
    chmod +x "$TPL/shared-configs/$u/install.sh"
done
# Registration now assembles authorized_keys from CLIENT_* via the shared
# scripts, so the fake clone must carry them or the run aborts before the
# install loop this section measures (task U follow-up).
if [[ -f scripts/refresh-authkeys.sh && -f scripts/lib/authkeys.sh ]]; then
    cp scripts/refresh-authkeys.sh "$TPL/scripts/refresh-authkeys.sh"
    cp scripts/lib/authkeys.sh "$TPL/scripts/lib/authkeys.sh"
fi

REG_TRUSTED=0
if [[ -f "$REG_SRC" ]]; then REG_TRUSTED=1; fi

if [[ "$REG_TRUSTED" -eq 1 ]]; then
    reset_capture
    env -i \
        PATH="$SANDBOX/bin:$REALPATH" \
        HOME="$SANDBOX/reg-home" \
        TMPDIR="$SANDBOX/reg-tmp" \
        USER="testuser" \
        FILE_CRYPTO_KEY="$KEY" \
        GH_POOL_TOKEN="$TOKEN" \
        ARGV_LOG="$ARGV_LOG" STDIN_DIR="$STDIN_DIR" \
        FAKE_REPO_TEMPLATE="$TPL" \
        /bin/bash "$REG_SRC" --name testnode --gateway-port 2301 --no-sudo \
        </dev/null > "$SANDBOX/reg.out" 2>&1
    reg_rc=$?
    cat "$ARGV_LOG" >> "$ALL_ARGV"

    if [[ "$reg_rc" -eq 0 ]]; then
        ok "register-provider.sh runs to completion under the stubs (exit 0)"
    else
        bad "register-provider.sh exited ${reg_rc}: $(sanitize "$(tail -3 "$SANDBOX/reg.out" | tr '\n' ' ')")"
    fi
    check_unit_transport "register loop" "$ARGV_LOG" none
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
emit "passed ${pass} / failed ${fail}"
if [[ "$fail" -eq 0 ]]; then exit 0; fi
exit 1
