#!/usr/bin/env bash
# test-register-provider-tempclone.sh — behavioral tests for the temp-clone
# contract of ops-scripts/register-provider.sh (task E), plus the
# registration-time authorized_keys step that replaced the ssh-admin unit
# (task U follow-up).
#
# The script installs things for real, so it is never run against the real
# machine: every run happens in a fake $HOME under a mktemp sandbox, with a
# fake PATH that intercepts git / gh / systemctl / curl / docker / dpkg /
# sudo / apt-get / loginctl / ssh. The intercepted tools record every argv
# they receive ($ARGV_LOG) and the fake git records where each clone went
# (git-clone|<dest> lines). Assertions are behavioral — filesystem state and
# argv records — except the two structural ones noted below, which ask
# questions a behavioral test cannot answer.
#
# The repo clone (the behavior under test) is driven by the fake gh/git:
# `gh repo clone` translates to the fake `git clone`, which materialises a
# fake repo tree at the destination so the rest of the script (profile.json,
# unit install.sh, crypto.sh, scripts/refresh-authkeys.sh,
# scripts/lib/authkeys.sh) can proceed and the run can complete.
# FAKE_CLONE_FAIL=1 makes the fake git create the destination and then exit
# 1, simulating a clone that dies halfway.
#
# Runs:
#   1. clean $HOME, happy path        -> repo dir gone, token kept, clone
#                                        temp gone
#   2. pre-existing .mylinuxpool/repo -> deleted by the run
#   3. clone fails mid-way            -> non-zero exit, temp still cleaned,
#                                        token kept
#   + token value absent from every recorded argv
#
# Task U added: deleting the ssh-admin unit removed the only thing that used
# to write a provider's authorized_keys, so registration must now assemble it
# from CLIENT_* (KEY-DESIGN §3.4). Cases 7-11 cover that:
#   7.  happy path writes $HOME/.ssh/authorized_keys containing every CLIENT_*
#   8.  that step runs BEFORE the tunnel verification (step 9)
#   9.  no CLIENT_* at all -> abort, no authorized_keys written
#   10. missing CLIENT_ACTIONS -> abort, no Actions-less list left behind
#   11. register-provider and pool-sync use the SAME shared functions —
#       a second implementation is what caused the RUNBOOK §7.12 outage
#   + injection: remove the abort guard -> case 9/10 must redden
#
# Cases 8 and 11 are structural (they parse the script's function layout)
# because no behavioral observation can distinguish "calls the shared
# function" from "a byte-identical private reimplementation", and ordering
# inside a successful run is only visible in the source. Everything else
# stays behavioral.
#
# bash 3.2 compatible on purpose (macOS ships 3.2): no declare -A, no
# ${var,,}, no mapfile.
#
# Run: scripts/tests/test-register-provider-tempclone.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

SCRIPT="ops-scripts/register-provider.sh"
SHARED_COLLECT_FILE="scripts/refresh-authkeys.sh"
SHARED_AUTHKEYS_FILE="scripts/lib/authkeys.sh"
POOL_SYNC="shared-configs/pool-runtime/files/pool-sync"
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
         "$SANDBOX/template/scripts/lib"

ARGV_LOG="$SANDBOX/argv.log"
ALL_ARGV="$SANDBOX/all-argv.log"

# ---- CLIENT_* fixtures --------------------------------------------------
# Two identities, as the brief asks: the operator's own key and the Actions
# key that authkeys_assemble REQUIRES (without it the assembled list would
# lock Actions out, so the whole batch must abort).
CLIENT_MAC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURECLIENTMAC fatesaikou-mac"
CLIENT_ACTIONS_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREACTIONS actions"

# client_vars_json <mac-key> <actions-key> — the shape `gh api
# .../actions/variables` returns: an object whose .variables[].value is a
# JSON STRING. An empty <actions-key> omits CLIENT_ACTIONS entirely.
client_vars_json() {
    local mac="$1" actions="$2"
    jq -c -n --arg m "$mac" --arg a "$actions" '
        [
          {name:"CLIENT_FATESAIKOU_MAC",
           value: ({name:"fatesaikou-mac", public_key:$m,
                    added_at:"2026-09-16T12:00:00Z"} | tojson)}
        ]
        + (if $a == "" then []
           else [{name:"CLIENT_ACTIONS",
                  value: ({name:"actions", public_key:$a,
                           added_at:"2026-09-16T12:00:00Z"} | tojson)}]
           end)
        | {total_count: length, variables: .}'
}

CLIENT_VARS_DEFAULT="$(client_vars_json "$CLIENT_MAC_KEY" "$CLIENT_ACTIONS_KEY")"
CLIENT_VARS_NO_ACTIONS="$(client_vars_json "$CLIENT_MAC_KEY" "")"
CLIENT_VARS_EMPTY='{"total_count":0,"variables":[]}'
FAKE_VARS_JSON="$CLIENT_VARS_DEFAULT"

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
# the fake git's record); api -> FAKE_VARS_JSON with --jq applied the way
# real gh does (so the caller's own filter is what runs); variable set
# consumes stdin (the script pipes the merged JSON to it).
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
    if [[ -z "${FAKE_VARS_JSON:-}" ]]; then
        echo "gh: HTTP 404: Not Found (variables)" >&2
        exit 1
    fi
    # Apply --jq exactly like gh does, so the caller s filter decides the
    # output shape. For a single-variable URL the real API returns
    # {name,value}; serve that so `.value` works as in production.
    url=""
    for a in "$@"; do
        case "$a" in *actions/variables/*) url="$a" ;; esac
    done
    single=""
    if [[ -n "$url" ]]; then
        single="${url##*/}"; single="${single%%\?*}"
    fi
    if [[ -n "$single" && -n "${FAKE_VAR_WRITES:-}" && -f "${FAKE_VAR_WRITES}/${single}.json" ]]; then
        body="$(jq -c -n --arg n "$single" --rawfile v "${FAKE_VAR_WRITES}/${single}.json" \
                  "{name: \$n, value: \$v}")"
    elif [[ -n "$single" ]]; then
        body="$(printf "%s" "$FAKE_VARS_JSON" | jq -c --arg n "$single" \
            "(.variables // []) | map(select(.name == \$n)) | if length > 0 then .[0] else null end" 2>/dev/null)"
        [[ "$body" == "null" || -z "$body" ]] && { echo "gh: HTTP 404: Not Found (${single})" >&2; exit 1; }
    else
        body="$FAKE_VARS_JSON"
    fi
    filter=""; prev=""
    for a in "$@"; do
        [[ "$prev" == "--jq" ]] && filter="$a"
        prev="$a"
    done
    if [[ -n "$filter" ]]; then
        printf "%s" "$body" | jq -r "$filter"
    else
        printf "%s\n" "$body"
    fi
    exit 0
fi
if [[ "${1:-}" == "variable" || "${1:-}" == "variables" ]]; then
    # Remember the write: step 5 creates NODE_<NAME> and step 6.5 reads it
    # straight back to merge tunnel_public_key in. A stub that discarded
    # writes made that real ordering look broken.
    if [[ "${2:-}" == "set" && -n "${3:-}" && -n "${FAKE_VAR_WRITES:-}" ]]; then
        mkdir -p "$FAKE_VAR_WRITES"
        cat > "${FAKE_VAR_WRITES}/${3}.json"
    else
        cat >/dev/null
    fi
    exit 0
fi
# step 6.5 dispatches refresh-authorized-keys.yml and WAITS for it. Serve an
# already-completed successful run so the wait returns at once -- the wait
# logic itself is covered by test-worker-tunnel-key.sh; what matters here is
# that registration gets past it. --jq is applied the same way the api branch
# does it, so the caller s own filter is what runs.
# Title contract (2026-09-26 nonce attribution): the waiter matches
# displayTitle against the nonce it dispatched with, so the listed run must
# carry the recorded dispatch argv. Without it the wait spins to its timeout
# and registration aborts -- for fake reasons, not subject reasons.
if [[ "${1:-}" == "workflow" && "${2:-}" == "run" ]]; then
    printf '%s' "$*" > "${HOME:?}/.gh-dispatch.args"
    exit 0
fi
if [[ "${1:-}" == "run" ]]; then
    filter=""; prev=""
    for a in "$@"; do
        [[ "$prev" == "--jq" ]] && filter="$a"
        prev="$a"
    done
    if [[ "${2:-}" == "list" ]]; then
        _t=""
        [[ -f "${HOME:?}/.gh-dispatch.args" ]] \
            && _t="refresh-authorized-keys: $(cat "${HOME}/.gh-dispatch.args")"
        body="$(jq -c -n --arg t "$_t" \
            "[{\"databaseId\":1,\"status\":\"completed\",\"conclusion\":\"success\",\"displayTitle\":\$t}]")"
    else
        body="{\"conclusion\":\"success\"}"
    fi
    if [[ -n "$filter" ]]; then
        printf "%s" "$body" | jq -r "$filter"
    else
        printf "%s\n" "$body"
    fi
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

# The registration-time authorization step assembles authorized_keys from
# CLIENT_* using the SHARED functions. The clone template must therefore
# carry the real scripts/, or the step has nothing to source — this is what
# the implementation reads from the fresh clone, exactly as pool-sync does.
if [[ -f "$SHARED_COLLECT_FILE" && -f "$SHARED_AUTHKEYS_FILE" ]]; then
    cp "$SHARED_COLLECT_FILE" "$SANDBOX/template/scripts/refresh-authkeys.sh"
    cp "$SHARED_AUTHKEYS_FILE" "$SANDBOX/template/scripts/lib/authkeys.sh"
fi
# Same reason for step 6.5: minting and publishing this machine's tunnel
# identity is a SHARED implementation (scripts/lib/tunnel-key.sh) read from
# the fresh clone, and waiting for the Gateway refresh is another
# (scripts/lib/refresh-wait.sh). Without them in the template that step dies
# and every later step -- including the authorized_keys convergence these
# cases assert on -- never runs.
for f in scripts/lib/tunnel-key.sh scripts/lib/refresh-wait.sh; do
    [[ -f "$f" ]] && cp "$f" "$SANDBOX/template/$f"
done
# tunnel-identity.sh defines TUNNEL_KEY. tunnel-key.sh prefers the installed
# copy and falls back to the clone's -- which is this case exactly: a machine
# being registered for the first time has nothing installed yet.
if [[ -f "shared-configs/pool-runtime/files/tunnel-identity.sh" ]]; then
    mkdir -p "$SANDBOX/template/shared-configs/pool-runtime/files"
    cp "shared-configs/pool-runtime/files/tunnel-identity.sh" \
       "$SANDBOX/template/shared-configs/pool-runtime/files/tunnel-identity.sh"
fi

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# run_register <work-home> <out-log> [fail] [vars-json] — one full run of the
# real script in a clean, stubbed environment; stdin closed so nothing hangs.
# vars-json defaults to the two-CLIENT happy-path fixture.
run_register() {
    local work="$1" out="$2"
    local -a envargs
    envargs=(HOME="$work" PATH="$SANDBOX/bin:$REALPATH" \
             FILE_CRYPTO_KEY="$CRYPTO_KEY" GH_POOL_TOKEN="$TOKEN" \
             USER="testuser" ARGV_LOG="$ARGV_LOG" \
             FAKE_REPO_TEMPLATE="$SANDBOX/template" \
             FAKE_VAR_WRITES="${work}/var-writes" \
             FAKE_VARS_JSON="${4:-$FAKE_VARS_JSON}")
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

# ===========================================================================
# 7-10: registration-time authorized_keys (task U follow-up).
# Deleting the ssh-admin unit removed the only writer of a provider's
# authorized_keys, so a brand-new provider would have been unreachable by
# Actions and step 9's tunnel check would fail. Registration now assembles
# the file from CLIENT_* instead.
# ===========================================================================
AUTHKEYS_PATH="$A_HOME/.ssh/authorized_keys"

echo "7. registration writes authorized_keys from CLIENT_*:"
if [[ ! -f "$AUTHKEYS_PATH" ]]; then
    bad "7a. \$HOME/.ssh/authorized_keys was not written by the happy-path run"
    bad "7b. authorized_keys contains the fatesaikou-mac CLIENT_* key"
    bad "7c. authorized_keys contains the CLIENT_ACTIONS key"
else
    ok "7a. \$HOME/.ssh/authorized_keys was written by the happy-path run"
    if grep -qF "$CLIENT_MAC_KEY" "$AUTHKEYS_PATH" 2>/dev/null; then
        ok "7b. authorized_keys contains the fatesaikou-mac CLIENT_* key"
    else
        bad "7b. authorized_keys is missing the fatesaikou-mac CLIENT_* key (content: $(head -c 200 "$AUTHKEYS_PATH" | tr '\n' ' '))"
    fi
    if grep -qF "$CLIENT_ACTIONS_KEY" "$AUTHKEYS_PATH" 2>/dev/null; then
        ok "7c. authorized_keys contains the CLIENT_ACTIONS key"
    else
        bad "7c. authorized_keys is missing the CLIENT_ACTIONS key"
    fi
    # Nothing else may be in there: the file is assembled from CLIENT_* and
    # must not still carry a static/crypted bundle's contents.
    n_lines="$(grep -c . "$AUTHKEYS_PATH" 2>/dev/null || true)"
    if [[ "$n_lines" -eq 2 ]]; then
        ok "7d. exactly the two CLIENT_* keys are present"
    else
        bad "7d. expected 2 key lines, got ${n_lines} (content: $(head -c 200 "$AUTHKEYS_PATH" | tr '\n' ' '))"
    fi
fi

echo "8. that step runs BEFORE the tunnel verification:"
# Structural by necessity: both steps live inside one successful run, and
# the tunnel check is the last thing that happens — the only way to observe
# "keys written before verification" from outside would be a race. Parse the
# function order in main() and require the authorization step to appear
# before step8_verify.
#
# The Python lives in its own file rather than a heredoc inside $(...):
# bash 3.2 (macOS) mis-parses a here-document nested in a command
# substitution, and the failure surfaces as a bogus "unexpected EOF" much
# later in the file.
ORDER_PY="$SANDBOX/step-order.py"
cat > "$ORDER_PY" <<'PY'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read()

# The function whose body writes an authorized_keys file.
fns = re.findall(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', src, re.M)
writer = None
for fn in fns:
    m = re.search(r'^%s\(\)\s*\{' % re.escape(fn), src, re.M)
    if not m:
        continue
    start = m.end()
    nxt = src.find("\n}", start)
    body = src[start:nxt if nxt != -1 else len(src)]
    if "authorized_keys" in body and ("mv " in body or ">" in body or "install " in body):
        writer = fn
        break
if writer is None:
    print("")
    sys.exit(0)

mm = re.search(r'^main\(\)\s*\{', src, re.M)
if not mm:
    print("")
    sys.exit(0)
mb = src[mm.end():src.find("\n}", mm.end())]
order = re.findall(r'^\s*([a-z_][a-z0-9_]*)', mb, re.M)
try:
    wi = order.index(writer)
except ValueError:
    wi = -1
verify = [i for i, f in enumerate(order) if f == "step8_verify" or "verify" in f]
vi = verify[0] if verify else -1
print("%s|%d|%d" % (writer, wi, vi))
PY

if [[ ! -f "$SCRIPT" ]]; then
    bad "8. authorization step precedes step 9 verification (${SCRIPT} missing)"
else
    AUTH_FN="$(python3 "$ORDER_PY" "$SCRIPT" 2>/dev/null)"
    writer_fn="${AUTH_FN%%|*}"
    rest="${AUTH_FN#*|}"
    writer_idx="${rest%%|*}"
    verify_idx="${rest##*|}"
    if [[ -z "$AUTH_FN" || -z "$writer_fn" ]]; then
        bad "8. could not identify the authorized_keys-writing step in ${SCRIPT} (not implemented yet?)"
    elif [[ "$writer_idx" -lt 0 ]]; then
        bad "8. ${writer_fn} exists but is never called from main()"
    elif [[ "$verify_idx" -lt 0 ]]; then
        bad "8. could not find the tunnel-verification step in main()"
    elif [[ "$writer_idx" -lt "$verify_idx" ]]; then
        ok "8. ${writer_fn} (call #$((writer_idx + 1))) runs before verification (call #$((verify_idx + 1)))"
    else
        bad "8. the authorization step runs AFTER the tunnel verification (${writer_idx} >= ${verify_idx}) — a fresh provider would fail its own health check"
    fi
fi

echo "9. no CLIENT_* at all -> abort, and no empty/partial list left behind:"
D_HOME="$SANDBOX/d"; mkdir -p "$D_HOME"
: > "$ARGV_LOG"
run_register "$D_HOME" "$SANDBOX/run-d.log" "" "$CLIENT_VARS_EMPTY"
rc=$?
cat "$ARGV_LOG" >> "$ALL_ARGV"
if [[ $rc -ne 0 ]]; then
    ok "9a. registration aborts when no CLIENT_* public keys can be assembled (exit $rc)"
else
    bad "9a. registration returned 0 with no CLIENT_* keys — it would have written a list nobody can use"
fi
if [[ -e "$D_HOME/.ssh/authorized_keys" ]]; then
    bad "9b. authorized_keys was written anyway (content: $(head -c 200 "$D_HOME/.ssh/authorized_keys" | tr '\n' ' '))"
else
    ok "9b. no authorized_keys was left behind"
fi

echo "10. CLIENT_ACTIONS missing -> abort, no Actions-less list:"
E_HOME="$SANDBOX/e"; mkdir -p "$E_HOME"
: > "$ARGV_LOG"
run_register "$E_HOME" "$SANDBOX/run-e.log" "" "$CLIENT_VARS_NO_ACTIONS"
rc=$?
cat "$ARGV_LOG" >> "$ALL_ARGV"
if [[ $rc -ne 0 ]]; then
    ok "10a. registration aborts when CLIENT_ACTIONS is absent (exit $rc)"
else
    bad "10a. registration returned 0 without CLIENT_ACTIONS — Actions would be locked out of the new provider"
fi
# The specific failure this guards: writing the list anyway, minus Actions.
if [[ -e "$E_HOME/.ssh/authorized_keys" ]]; then
    bad "10b. an authorized_keys was written without CLIENT_ACTIONS (content: $(head -c 200 "$E_HOME/.ssh/authorized_keys" | tr '\n' ' ')) — that is the self-lockout the guard exists to prevent"
elif [[ -e "$E_HOME/.ssh/authorized_keys" ]] && ! grep -qF "$CLIENT_ACTIONS_KEY" "$E_HOME/.ssh/authorized_keys" 2>/dev/null; then
    bad "10b. an authorized_keys exists and lacks CLIENT_ACTIONS"
else
    ok "10b. no Actions-less authorized_keys was left behind"
fi

# ===========================================================================
# 11. shared implementation: register-provider and pool-sync must call the
# SAME functions. A second, private reimplementation is precisely what
# caused the RUNBOOK §7.12 outage: two code paths, one of them missing a
# guard. Behavioral testing cannot tell "calls the shared function" apart
# from "a byte-identical private copy", so this case asks the structural
# question directly.
# ===========================================================================
echo "11. register-provider and pool-sync use the shared implementation:"
SHARED_MISSING=0
for f in "$SHARED_COLLECT_FILE" "$SHARED_AUTHKEYS_FILE"; do
    [[ -f "$f" ]] || { bad "11. shared file ${f} is missing"; SHARED_MISSING=1; }
done
if [[ "$SHARED_MISSING" -eq 0 ]]; then
    # The shared entry point is refresh_sync_local_authorized_keys: it is
    # the one function that both callers invoke, and it in turn calls
    # refresh_collect_clients + authkeys_assemble. Asserting the whole
    # chain catches both failure modes — a caller growing its own copy of
    # the wrapper, and the wrapper growing a private copy of the pieces.
    SHARED_FNS="refresh_sync_local_authorized_keys refresh_collect_clients authkeys_assemble"
    for fn in $SHARED_FNS; do
        defs="$(grep -rlE "^${fn}\(\)[[:space:]]*\{" "$SHARED_COLLECT_FILE" "$SHARED_AUTHKEYS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$defs" -eq 1 ]]; then
            ok "11. ${fn} is defined exactly once, in the shared files"
        else
            bad "11. ${fn} has ${defs} definition(s) across the shared files — expected exactly one"
        fi
        # Neither caller may define its own copy.
        for caller in "$SCRIPT" "$POOL_SYNC"; do
            if [[ -f "$caller" ]] && grep -qE "^${fn}\(\)[[:space:]]*\{" "$caller" 2>/dev/null; then
                bad "11. ${caller} defines its own ${fn} — second implementation (RUNBOOK §7.12)"
            fi
        done
    done

    # Both callers must invoke the same shared entry point, and must source
    # the file that defines it.
    check_caller() {
        local label="$1" file="$2"
        if [[ ! -f "$file" ]]; then
            bad "11. ${label}: ${file} missing"
            return
        fi
        if grep -q 'refresh_sync_local_authorized_keys' "$file" 2>/dev/null; then
            ok "11. ${label} calls the shared refresh_sync_local_authorized_keys"
        else
            bad "11. ${label} never calls refresh_sync_local_authorized_keys — it must not grow its own assembly path"
        fi
        if grep -qE 'source .*(refresh-authkeys\.sh|authkeys\.sh)' "$file" 2>/dev/null; then
            ok "11. ${label} sources the shared script(s)"
        else
            bad "11. ${label} does not source the shared script(s) — it cannot be calling the shared functions"
        fi
    }
    check_caller "register-provider" "$SCRIPT"
    check_caller "pool-sync" "$POOL_SYNC"

    # The wrapper itself must delegate to both shared helpers, not inline
    # its own validation/assembly.
    WRAP_BODY="$(awk '/^refresh_sync_local_authorized_keys\(\)/,/^}/' "$SHARED_COLLECT_FILE" 2>/dev/null)"
    for helper in refresh_collect_clients authkeys_assemble; do
        if printf '%s' "$WRAP_BODY" | grep -q "$helper"; then
            ok "11. the shared wrapper delegates to ${helper}"
        else
            bad "11. the shared wrapper does not call ${helper} — its guards live somewhere else now"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Injection: remove the abort guard around the authorization assembly and
# show cases 9/10 redden. The mutation forces the assembled list through
# even when assembly failed, exactly the "write whatever we got" shape the
# guard exists to prevent.
# ---------------------------------------------------------------------------
echo "injection (authorization guard):"
# The guard lives in the SHARED wrapper's callers: register-provider treats
# a non-zero return from refresh_sync_local_authorized_keys as fatal. Remove
# that `|| { ...; exit 1; }` and the run must proceed without a login list —
# making cases 9/10 red.
if [[ ! -f "$SCRIPT" ]]; then
    bad "injection: ${SCRIPT} missing"
else
    INJ_REG="$SANDBOX/register-inj.sh"
    # Drop the fatal guard around the shared call by brace-matching, not by
    # a greedy regex: `.*?` with re.S swallowed the guard body and left a
    # dangling `}` (syntax error), which made the injection "fail" for a
    # harness reason instead of the guard's absence.
    if python3 - "$SCRIPT" "$INJ_REG" <<'PYEOF'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read()


def drop_guard(text, marker):
    i = text.find(marker)
    if i == -1:
        return text, 0
    j = text.find("||", i)
    if j == -1:
        return text, 0
    # The guard is exactly `|| {`: require the brace to be the first
    # non-whitespace character after `||`. Searching for any later `{` would
    # latch onto an unrelated block (e.g. when a previous run already
    # removed this guard, leaving `|| true`), brace-match from there and
    # mangle the file.
    k = j + 2
    while k < len(text) and text[k] in " \t\n":
        k += 1
    if k >= len(text) or text[k] != "{":
        return text, 0
    depth = 0
    m = k
    while m < len(text):
        if text[m] == "{":
            depth += 1
        elif text[m] == "}":
            depth -= 1
            if depth == 0:
                break
        m += 1
    if depth != 0:
        return text, 0
    return text[:j] + "|| true" + text[m + 1:], 1


src, n1 = drop_guard(src, 'refresh_sync_local_authorized_keys "$vars_json"')
# The same contract has two earlier aborts (missing scripts, unreadable
# variables); neutralise both so the mutant can proceed to the write.
src, n2 = re.subn(
    r'log ERROR "cannot read GitHub variables[^\n]*\n([ \t]*)exit 1',
    r'log WARN "cannot read GitHub variables (injected)"\n\1:',
    src)
src, n3 = re.subn(
    r'log ERROR "scripts/refresh-authkeys\.sh or scripts/lib/authkeys\.sh missing[^\n]*\n([ \t]*)exit 1',
    r'log WARN "shared scripts missing (injected)"\n\1:',
    src)
if n1 + n2 + n3 == 0:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PYEOF
    then
        chmod +x "$INJ_REG" 2>/dev/null
        if [[ ! -s "$INJ_REG" ]]; then
            bad "injection: mutator produced nothing (harness problem)"
        elif ! bash -n "$INJ_REG" 2>/dev/null; then
            bad "injection: mutated script has a syntax error (harness problem)"
        else
            # Case 9's scenario against the mutant: no CLIENT_* at all.
            I_HOME="$SANDBOX/inj9"; mkdir -p "$I_HOME"
            : > "$ARGV_LOG"
            env -i HOME="$I_HOME" PATH="$SANDBOX/bin:$REALPATH" \
                 FILE_CRYPTO_KEY="$CRYPTO_KEY" GH_POOL_TOKEN="$TOKEN" \
                 USER="testuser" ARGV_LOG="$ARGV_LOG" \
                 FAKE_REPO_TEMPLATE="$SANDBOX/template" \
                 FAKE_VAR_WRITES="$I_HOME/var-writes" \
                 FAKE_VARS_JSON="$CLIENT_VARS_EMPTY" \
                 /bin/bash "$INJ_REG" --name testnode --gateway-port 2301 --no-sudo \
                 </dev/null >"$SANDBOX/inj9.log" 2>&1
            i9rc=$?
            if [[ $i9rc -eq 0 ]]; then
                printf '  inj ok    %s\n' "移除防線後，無 CLIENT_* 仍回 0——第 9a 條會紅"
            elif [[ -e "$I_HOME/.ssh/authorized_keys" ]]; then
                printf '  inj ok    %s\n' "移除防線後仍非 0，但留下了 authorized_keys——第 9b 條會紅"
            else
                bad "injection: 移除防線後行為不變（rc=${i9rc}，無檔案）——注入沒生效"
            fi
        fi
    else
        bad "injection: 找不到可中性化的防線（實作尚未落地？）——harness 問題"
    fi
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
exit "$fail"
