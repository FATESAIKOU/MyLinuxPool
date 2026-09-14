#!/usr/bin/env bash
# test-register-provider-tempclone.sh — behavioral tests for the temp-clone
# contract of ops-scripts/register-provider.sh (task E).
#
# The script installs things for real, so it is never run against the real
# machine: every run happens in a fake $HOME under a mktemp sandbox, with a
# fake PATH that intercepts git / gh / systemctl / curl / docker / dpkg /
# sudo / apt-get / loginctl / ssh. The intercepted tools record every argv
# they receive ($ARGV_LOG) and the fake git records where each clone went
# (git-clone|<dest> lines). All assertions are behavioral — filesystem state
# and argv records — never greps of the script's source text.
#
# The repo clone (the behavior under test) is driven by the fake gh/git:
# `gh repo clone` translates to the fake `git clone`, which materialises a
# fake repo tree at the destination so the rest of the script (profile.json,
# unit install.sh, crypto.sh, authorized_keys.crypted) can proceed and the
# run can complete. FAKE_CLONE_FAIL=1 makes the fake git create the
# destination and then exit 1, simulating a clone that dies halfway.
#
# Runs:
#   1. clean $HOME, happy path        -> repo dir gone, token kept, clone
#                                        temp gone
#   2. pre-existing .mylinuxpool/repo -> deleted by the run
#   3. clone fails mid-way            -> non-zero exit, temp still cleaned,
#                                        token kept
#   + token value absent from every recorded argv
#
# The implementation is still being changed to the temp-clone design; the
# current tree clones straight into ~/.mylinuxpool/repo and keeps it, so
# assertions 1/2/4/5c are expected to FAIL until that lands (task brief:
# "被測物尚未改好時預期會 FAIL"). Every assertion is written so it can
# genuinely fail.
#
# bash 3.2 compatible on purpose (macOS ships 3.2): no declare -A, no
# ${var,,}, no mapfile.
#
# Run: scripts/tests/test-register-provider-tempclone.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

SCRIPT="ops-scripts/register-provider.sh"
TOKEN="ghp_testtoken_7f3a91c2"
CRYPTO_KEY="demo-crypto-key"
REALPATH="$PATH"

if [[ ! -f "$SCRIPT" ]]; then
    echo "test-register-provider-tempclone: ${SCRIPT} is missing; every case below will FAIL" >&2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-register-provider.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin" "$SANDBOX/template/profiles/provider/no-sudo" \
         "$SANDBOX/template/shared-configs/pool-runtime" \
         "$SANDBOX/template/shared-configs/ssh-admin/files" \
         "$SANDBOX/template/scripts/lib"

ARGV_LOG="$SANDBOX/argv.log"
ALL_ARGV="$SANDBOX/all-argv.log"

# ---- fake tools: log argv, then behave --------------------------------
# log_stub <name> <body...> — every fake tool appends "<name>|<argv>" to
# $ARGV_LOG before running its body, so assertion 6 can scan all argv.
log_stub() {
    local name="$1"; shift
    {
        echo '#!/usr/bin/env bash'
        echo "echo \"$name|\$*\" >> \"\${ARGV_LOG:-/dev/null}\""
        printf '%s\n' "$@"
    } > "$SANDBOX/bin/$name"
    chmod +x "$SANDBOX/bin/$name"
}

# git: clone records the destination and materialises the fake repo tree;
# config/--get are the credential-helper calls from step 2.
log_stub git 'if [[ "${1:-}" == "clone" ]]; then
    dest=""
    for a in "$@"; do dest="$a"; done
    echo "git-clone|${dest}" >> "${ARGV_LOG:-/dev/null}"
    mkdir -p "$dest" 2>/dev/null || true
    cp -R "${FAKE_REPO_TEMPLATE:-/nonexistent}/." "$dest/" 2>/dev/null || true
    chmod -R u+w "$dest" 2>/dev/null || true
    [[ -n "${FAKE_CLONE_FAIL:-}" ]] && exit 1
    exit 0
fi
case "${1:-}" in
    config) exit 0 ;;
esac
exit 0'

# gh: repo clone -> fake git clone (so ALL clone destinations flow through
# the fake git's record); api -> {} for the NODE_<NAME> variable probe;
# variable set consumes stdin (the script pipes the merged JSON to it).
log_stub gh 'if [[ "${1:-}" == "repo" && "${2:-}" == "clone" ]]; then
    repo="$3"; dest="$4"
    shift 4
    branch="master"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branch) branch="$2"; shift 2 ;;
            --) shift ;;
            *) shift ;;
        esac
    done
    git clone --branch "$branch" "https://github.com/${repo}" "$dest"
    exit $?
fi
if [[ "${1:-}" == "api" ]]; then
    echo "{}"
    exit 0
fi
if [[ "${1:-}" == "variable" || "${1:-}" == "variables" ]]; then
    cat >/dev/null
    exit 0
fi
exit 0'

log_stub systemctl 'exit 0'
log_stub curl 'exit 0'
log_stub docker 'exit 0'
log_stub dpkg 'exit 0'
log_stub sudo 'exit 0'
log_stub apt-get 'exit 0'
log_stub loginctl 'exit 0'

# ssh: step 9 reads an SSH banner off stdout to consider the tunnel verified.
log_stub ssh 'echo "SSH-2.0-OpenSSH_9.6 testbanner"
exit 0'

# ---- fake repo tree the fake git materialises at the clone destination --
cat > "$SANDBOX/template/profiles/provider/no-sudo/profile.json" <<'EOF'
{"shared_config":["pool-runtime"],"sudoers_rules":[],"systemd_user_services":[],"linger":false}
EOF

cat > "$SANDBOX/template/shared-configs/pool-runtime/install.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$HOME/.mylinuxpool/bin"
cat > "$HOME/.mylinuxpool/bin/pool-resolve" <<'INNER'
#!/usr/bin/env bash
echo '{"ip":"127.0.0.1","tunnel_user":"tester"}'
INNER
chmod +x "$HOME/.mylinuxpool/bin/pool-resolve"
exit 0
EOF
chmod +x "$SANDBOX/template/shared-configs/pool-runtime/install.sh"

cat > "$SANDBOX/template/shared-configs/ssh-admin/files/authorized_keys.crypted" <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKETESTING mylinuxpool-actions
EOF

cat > "$SANDBOX/template/scripts/lib/crypto.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "decrypt" ]]; then cat; fi
exit 0
EOF
chmod +x "$SANDBOX/template/scripts/lib/crypto.sh"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# run_register <work-home> <out-log> [fail] — one full run of the real
# script in a clean, stubbed environment; stdin closed so nothing hangs.
run_register() {
    local work="$1" out="$2"
    local -a envargs
    envargs=(HOME="$work" PATH="$SANDBOX/bin:$REALPATH" \
             FILE_CRYPTO_KEY="$CRYPTO_KEY" GH_POOL_TOKEN="$TOKEN" \
             USER="testuser" ARGV_LOG="$ARGV_LOG" \
             FAKE_REPO_TEMPLATE="$SANDBOX/template")
    if [[ "${3:-}" == "fail" ]]; then
        envargs+=(FAKE_CLONE_FAIL=1)
    fi
    env -i "${envargs[@]}" /bin/bash "$SCRIPT" \
        --name testnode --gateway-port 2301 --no-sudo \
        </dev/null >"$out" 2>&1
    return $?
}

# check_clone_dests_gone <label> <argv-log> — every destination the fake
# git recorded for a clone must no longer exist.
check_clone_dests_gone() {
    local label="$1" log="$2" left="" d
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        [[ -e "$d" ]] && left="${left} ${d}"
    done < <(grep '^git-clone|' "$log" 2>/dev/null | sed 's/^git-clone|//')
    if [[ -z "$(grep '^git-clone|' "$log" 2>/dev/null)" ]]; then
        bad "$label (no clone destination was recorded — harness broken)"
    elif [[ -z "$left" ]]; then
        ok "$label"
    else
        bad "$label (still exist:$left)"
    fi
}

echo "run 1: clean HOME, happy path"
A_HOME="$SANDBOX/a"; mkdir -p "$A_HOME"
: > "$ARGV_LOG"
run_register "$A_HOME" "$SANDBOX/run-a.log"
rc=$?
cat "$ARGV_LOG" >> "$ALL_ARGV"
if [[ $rc -eq 0 ]]; then
    ok "run 1 completes (exit 0)"
else
    bad "run 1 exits $rc (see $SANDBOX/run-a.log)"
fi

if [[ ! -e "$A_HOME/.mylinuxpool/repo" ]]; then
    ok "1. \$HOME/.mylinuxpool/repo does not exist after the run"
else
    bad "1. \$HOME/.mylinuxpool/repo still exists after the run"
fi

if [[ -f "$A_HOME/.mylinuxpool/gh_token" ]] \
   && [[ "$(cat "$A_HOME/.mylinuxpool/gh_token")" == "$TOKEN" ]]; then
    ok "3. gh_token still exists with the original value"
else
    bad "3. gh_token missing or changed after the run (exists=$([[ -e "$A_HOME/.mylinuxpool/gh_token" ]] && echo yes || echo no))"
fi
check_clone_dests_gone "4. clone temp dir does not exist after the run" "$ARGV_LOG"

echo "run 2: pre-existing \$HOME/.mylinuxpool/repo with a marker file"
B_HOME="$SANDBOX/b"; mkdir -p "$B_HOME/.mylinuxpool/repo"
printf 'MARKER-LEFTOVER\n' > "$B_HOME/.mylinuxpool/repo/marker.txt"
: > "$ARGV_LOG"
run_register "$B_HOME" "$SANDBOX/run-b.log"
rc=$?
cat "$ARGV_LOG" >> "$ALL_ARGV"
echo "  (run 2 exit=$rc)"
if [[ ! -e "$B_HOME/.mylinuxpool/repo/marker.txt" ]]; then
    ok "2. pre-existing repo dir is deleted by the run (marker file gone)"
else
    bad "2. pre-existing repo dir survives the run (marker.txt still present)"
fi

echo "run 3: clone fails mid-way"
C_HOME="$SANDBOX/c"; mkdir -p "$C_HOME"
: > "$ARGV_LOG"
run_register "$C_HOME" "$SANDBOX/run-c.log" fail
rc=$?
cat "$ARGV_LOG" >> "$ALL_ARGV"
if [[ $rc -ne 0 ]]; then
    ok "5a. script exits non-zero when the clone fails (got $rc)"
else
    bad "5a. script exited 0 despite a failed clone"
fi
if [[ -f "$C_HOME/.mylinuxpool/gh_token" ]] \
   && [[ "$(cat "$C_HOME/.mylinuxpool/gh_token")" == "$TOKEN" ]]; then
    ok "5b. gh_token survives a failed run"
else
    bad "5b. gh_token missing or changed after the failed run"
fi
check_clone_dests_gone "5c. clone temp dir is cleaned up even when the clone fails" "$ARGV_LOG"

echo "argv leak check:"
if grep -qF "$TOKEN" "$ALL_ARGV" 2>/dev/null; then
    bad "6. gh_token value appeared in a recorded command line: $(grep -F "$TOKEN" "$ALL_ARGV" | head -n 1)"
else
    ok "6. gh_token value never appears in any recorded argv"
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
exit "$fail"
