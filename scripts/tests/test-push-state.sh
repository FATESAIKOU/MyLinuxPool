#!/usr/bin/env bash
# test-push-state.sh — the properties of the state.json payload a correct
# .github/actions/push-state must assemble and push.
# Contract: docs/STATE_CONTRACT.md §2 (format and invariants) and §4 (write
# timing). Hermetic: no gh, no ssh, no network, no real machine.
#
# run.sh is not run as a black box (it needs GitHub and the Gateway). Its
# output properties are pinned using scripts/lib/state.sh as the baseline
# oracle. If run.sh exports a var-name -> node-name helper it is tested
# directly; if not, the underscore-key rejection in state_validate stands in
# for it.
#
# Every check here can fail (REDESIGN.md §3.3). The failure injection demo is
# part of the task report.
# Run: scripts/tests/test-push-state.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PUSH_STATE_RUN=".github/actions/push-state/run.sh"

if [[ -f scripts/lib/state.sh ]]; then
    # shellcheck source=../lib/state.sh
    source scripts/lib/state.sh
else
    echo "test-push-state: scripts/lib/state.sh is missing; every case below will FAIL" >&2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-push-state.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin" "$SANDBOX/home"

# If sourcing run.sh ever runs its CLI body, every external command must fail
# fast instead of hanging or reaching a real machine.
for tool in gh ssh scp nc curl wget; do
    cat > "$SANDBOX/bin/$tool" <<'STUB'
#!/usr/bin/env bash
echo "test stub: refusing to run ($0)" >&2
exit 255
STUB
    chmod +x "$SANDBOX/bin/$tool"
done

cat > "$SANDBOX/load-run-sh" <<'LOADER'
#!/usr/bin/env bash
# Usage: load-run-sh <run.sh> list
#        load-run-sh <run.sh> call <fn> [args...]
# Sources run.sh with `exit` and errexit neutered so an unguarded CLI body
# cannot run away with the test process. 'list' prints only the functions
# run.sh newly defines.
set +e +u
run_file="$1"; mode="$2"; shift 2
exit() { return 2; }
set() { builtin set +e +u; }
before="$(declare -F | sed 's/^declare -f //' | sort)"
source "$run_file" >/dev/null 2>&1
unset -f set exit 2>/dev/null || true
if [[ "$mode" == list ]]; then
    comm -13 <(printf '%s\n' "$before") \
             <(declare -F | sed 's/^declare -f //' | sort)
    exit 0
fi
fn="$1"; shift
if declare -F "$fn" >/dev/null 2>&1; then
    "$fn" "$@"
else
    printf '<not-defined: %s>' "$fn"
    exit 127
fi
LOADER
chmod +x "$SANDBOX/load-run-sh"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

OUT=""; ERR=""; RC=0; MISSING=0

# run <function> [args...] — capture stdout, stderr and exit code separately.
# stdin is always /dev/null so a case can never hang waiting for it.
run() {
    if declare -F "$1" >/dev/null 2>&1; then
        local errfile
        errfile="$(mktemp "${SANDBOX}/err.XXXXXX")"
        OUT="$("$@" </dev/null 2>"$errfile")"; RC=$?
        ERR="$(cat "$errfile")"; rm -f "$errfile"
        MISSING=0
    else
        OUT="<undefined function: $1>"; ERR=""; RC=127; MISSING=1
    fi
}

# call_loader <fn> [args...] — call a function exported by run.sh, in the
# stubbed environment. Sets LOADER_OUT / LOADER_RC.
LOADER_OUT=""; LOADER_RC=0
call_loader() {
    local fn="$1"; shift
    LOADER_OUT="$(HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
        timeout 10 bash "$SANDBOX/load-run-sh" "$PUSH_STATE_RUN" call "$fn" "$@" \
        </dev/null 2>/dev/null)"
    LOADER_RC=$?
}

expect_eq() {
    if [[ "$3" == "$2" ]]; then ok "$1"
    else bad "$1 (expected [$2], got [${3:-<empty>}])"; fi
}

expect_rc() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function undefined — is state.sh present?)"
    elif [[ "$RC" -eq "$2" ]]; then ok "$1"
    else bad "$1 (expected exit $2, got $RC; stderr: ${ERR:-<empty>})"; fi
}

# expect_reject <label> — must exit non-zero AND explain itself on stderr.
expect_reject() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function undefined — is state.sh present?)"
    elif [[ "$RC" -eq 0 ]]; then
        bad "$1 (exit 0, should have been rejected)"
    elif [[ -z "$ERR" ]]; then
        bad "$1 (exit $RC but nothing on stderr; a rejected push must say why)"
    else
        ok "$1"
    fi
}

expect_jq() {
    if jq -e "$2" >/dev/null 2>&1 <<<"$OUT"; then ok "$1"
    else bad "$1 (jq [$2] was false on [${OUT:-<empty>}])"; fi
}

# expect_no_secrets <label> — contract §2 invariant 1
expect_no_secrets() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function undefined — is state.sh present?)"
        return
    fi
    local pat found=""
    for pat in 'BEGIN OPENSSH PRIVATE KEY' 'BEGIN RSA PRIVATE KEY' 'ghp_' 'ghu_'; do
        [[ "$OUT" == *"$pat"* ]] && found="$pat"
    done
    if [[ -z "$found" ]]; then ok "$1"
    else bad "$1 (found secret pattern [$found])"; fi
}

# A contract-shaped existing state (serial 7) with the var spelling of one
# node, plus a worker ledger seen with POOL_WORKERS present.
EXISTING_STATE='{"schema":1,"serial":7,"written_at":"2026-09-14T08:00:00Z","source":"create-worker#1","nodes":{"gateway":{"name":"gateway","role":"gateway","ip":"172.104.114.31","key_secret":"SSH_KEY_ACTIONS"}},"workers":[]}'

NODES_FROM_VARS='{"gateway":{"name":"gateway","role":"gateway","ip":"172.104.114.31","user":"fatesaikou","tunnel_user":"sshproxy","key_secret":"SSH_KEY_ACTIONS","generation":8},"fh_proxy":{"name":"fh-proxy","role":"provider","ip":"10.0.0.3","key_secret":"SSH_KEY_ACTIONS"},"fh_l":{"name":"fh-l","role":"provider","ip":"10.0.0.2","key_secret":"SSH_KEY_ACTIONS"}}'

WORKERS_IN='[{"port":2300,"provider":"fh-l","image":"default","container":"mlp-fh-l-default-34822789603","created_at":"2026-09-14T08:26:00Z"}]'

echo "state_next_serial:"
run state_next_serial "$EXISTING_STATE"
expect_rc "existing serial 7 exits 0" 0
expect_eq "existing serial 7 -> 8" "8" "$OUT"
serial="$OUT"

run state_next_serial '{"serial":0}'
expect_eq "serial 0 -> 1" "1" "$OUT"

run state_next_serial '{"serial":41}'
expect_eq "serial 41 -> 42" "42" "$OUT"

run state_next_serial '{"schema":1}'
expect_eq "missing serial -> 1 (regenerate)" "1" "$OUT"

run state_next_serial 'not-json{'
expect_eq "invalid JSON -> 1 (regenerate)" "1" "$OUT"

echo "worker ledger when POOL_WORKERS is absent:"
# A correct assembly normalises a missing var to an empty array. This is the
# payload it must then hand to state_build.
run state_build "$serial" "create-worker#1" "$NODES_FROM_VARS" '[]'
BUILT="$OUT"
expect_rc "build with absent ledger exits 0" 0
expect_jq "absent ledger becomes []" '.workers == []'
expect_jq "workers is an array, not null or a string" '(.workers | type) == "array"'

run state_build "$serial" "create-worker#1" "$NODES_FROM_VARS" 'null'
expect_jq "a null ledger is coerced to [], never written as null" '.workers == []'

# The raw empty string is the trap: state_build rejects it, so a run.sh that
# forwards the missing var verbatim fails loudly instead of writing workers:"".
run state_build "$serial" "create-worker#1" "$NODES_FROM_VARS" ''
expect_reject "raw empty-string ledger is rejected before push"

echo "node key from the GitHub var spelling:"
OUT="$BUILT"
expect_jq "fh_proxy becomes key fh-proxy" '.nodes | has("fh-proxy")'
expect_jq "fh_l becomes key fh-l" '.nodes | has("fh-l")'
expect_jq "gateway stays gateway" '.nodes | has("gateway")'
expect_jq "no underscore keys survive" '[.nodes | keys[] | select(test("_"))] | length == 0'
expect_jq "node payload passes through untouched" '.nodes["fh-proxy"].ip == "10.0.0.3"'

# Fallback the task allows when run.sh exposes no helper: the hyphenated-key
# rule is enforced by state_validate rejecting the var spelling.
run state_validate "$(jq -c '.nodes.fh_proxy = .nodes["fh-proxy"] | del(.nodes["fh-proxy"])' <<<"$BUILT")"
expect_reject "state_validate rejects an underscore node key (fh_proxy)"

echo "run.sh var-name helper (if exported):"
HAVE_CONVERTER=0
if [[ -f "$PUSH_STATE_RUN" ]]; then
    FUNCS="$(HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
        timeout 10 bash "$SANDBOX/load-run-sh" "$PUSH_STATE_RUN" list </dev/null 2>/dev/null || true)"
    # Prefer likely converter names; if none match, still probe exported
    # functions so an unusually named helper is not silently skipped. The cap
    # bounds the probe cost when run.sh defines many functions.
    CANDIDATES="$(grep -Ei 'node.*(key|name)|(key|name).*node|var.*node|node.*var|var.*(key|name)' <<<"$FUNCS" || true)"
    if [[ -z "$CANDIDATES" ]]; then
        CANDIDATES="$(head -12 <<<"$FUNCS")"
    fi
    if [[ -n "$CANDIDATES" ]]; then
        HAVE_CONVERTER=1
        convert_ok=0; convert_names=""
        while IFS= read -r fn; do
            [[ -n "$fn" ]] || continue
            convert_names="${convert_names}${convert_names:+, }${fn}"
            # NODE_FH_PROXY is the contract's example. A helper that takes the
            # bare spelling (FH_PROXY / fh_proxy) still proves the normalisation.
            for input in NODE_FH_PROXY FH_PROXY fh_proxy; do
                call_loader "$fn" "$input"
                if [[ "$LOADER_RC" -eq 0 && "$LOADER_OUT" == "fh-proxy" ]]; then
                    convert_ok=1
                    break 2
                fi
            done
        done <<<"$CANDIDATES"
        if [[ "$convert_ok" -eq 1 ]]; then
            ok "run.sh helper maps the fh-proxy var name to node key fh-proxy"
        else
            bad "run.sh exports [$convert_names] but none turns the fh-proxy var name into node key fh-proxy"
        fi
    fi
fi
if [[ "$HAVE_CONVERTER" -eq 0 ]]; then
    echo "  note  ${PUSH_STATE_RUN} is absent or exports no var->node helper;"
    echo "  note  the underscore-key rejection above stands in for it"
fi

echo "a correct assembly passes state_validate:"
run state_validate "$BUILT"
expect_rc "golden-path state is accepted" 0
OUT="$BUILT"
expect_jq "schema is 1" '.schema == 1'
expect_jq "serial is the strictly-incremented 8" '.serial == 8'
expect_jq "written_at is RFC3339 UTC" '((.written_at | fromdateiso8601) as $t | $t > 0)'
expect_jq "source is preserved" '.source == "create-worker#1"'
expect_no_secrets "assembled state carries key_secret names, never values"

run state_build "$serial" "create-worker#1" "$NODES_FROM_VARS" "$WORKERS_IN"
BUILT_LEDGER="$OUT"
run state_validate "$BUILT_LEDGER"
expect_rc "a state with a non-empty ledger is accepted too" 0
OUT="$BUILT_LEDGER"
expect_jq "non-empty ledger passes through" '(.workers | length) == 1 and .workers[0].port == 2300'

echo "secret patterns are rejected before push:"
run state_validate "$(jq -c '.nodes.gateway.host_key = "-----BEGIN OPENSSH PRIVATE KEY-----\nMIIEfake"' <<<"$BUILT")"
expect_reject "rejects an embedded OPENSSH private key"

run state_validate "$(jq -c '.nodes.gateway.key = "-----BEGIN RSA PRIVATE KEY-----\nMIIEfake"' <<<"$BUILT")"
expect_reject "rejects an embedded RSA private key"

run state_validate "$(jq -c '.nodes["fh-proxy"].gh_token = "ghp_0123456789abcdefghijklmnopqrstuvwxyz"' <<<"$BUILT")"
expect_reject "rejects a ghp_ token value"

run state_validate "$(jq -c '.nodes["fh-l"].gh_token = "ghu_0123456789abcdefghijklmnopqrstuvwxyz"' <<<"$BUILT")"
expect_reject "rejects a ghu_ token value"

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-push-state: ${pass} passed"
else
    echo "test-push-state: ${fail} FAILED, ${pass} passed"
fi
exit "$fail"
