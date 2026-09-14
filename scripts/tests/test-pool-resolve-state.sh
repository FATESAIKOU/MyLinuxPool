#!/usr/bin/env bash
# Tests for the state-lookup and cache-key functions in
# shared-configs/pool-runtime/files/pool-resolve.
# Contract: docs/STATE_CONTRACT.md §2 (state.json) and §3 (read order).
#
# Pure function tests: no network, no real gh/ssh. pool-resolve is sourced
# with its CLI body neutralised, then the two frozen functions are called
# directly. Every check is paired with a way to fail; a test that cannot fail
# is not a test (REDESIGN.md §3.3).
#
# Run: scripts/tests/test-pool-resolve-state.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

POOL_RESOLVE="shared-configs/pool-runtime/files/pool-resolve"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi
if [[ ! -f "$POOL_RESOLVE" ]]; then
    echo "test-pool-resolve-state: ${POOL_RESOLVE} not found; every case below will FAIL" >&2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-pool-resolve-state.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/home" "$SANDBOX/bin"

# Network tools are stubbed so that even if the CLI body runs while sourcing,
# it cannot reach the network or hang on a real ssh.
for tool in gh ssh scp nc curl wget; do
    cat > "$SANDBOX/bin/$tool" <<'STUB'
#!/usr/bin/env bash
echo "test stub: refusing to run ($0)" >&2
exit 255
STUB
    chmod +x "$SANDBOX/bin/$tool"
done

# Loader: source pool-resolve with `exit` neutered (so an unguarded CLI body
# cannot terminate us), then call the requested function.
# Args: <pool-resolve> <fn> [fn-args...]
cat > "$SANDBOX/load-and-call" <<'LOADER'
#!/usr/bin/env bash
set +e +u
resolve="$1"; fn="$2"; shift 2
args=("$@")
exit() { return 2; }
set --
source "$resolve" >/dev/null 2>&1
unset -f exit 2>/dev/null || true
set +e +u
if ! declare -F "$fn" >/dev/null 2>&1; then
    printf '<undefined function: %s>' "$fn"
    exit 127
fi
if [[ "${#args[@]}" -gt 0 ]]; then
    "$fn" "${args[@]}"
else
    "$fn"
fi
LOADER
chmod +x "$SANDBOX/load-and-call"

OUT=""; RC=0; MISSING=0; SAVED=""

# call_fn <fn> [args...] — capture stdout and exit code; a function that never
# loaded gets a visible sentinel so that "prints nothing" checks cannot pass by
# accident.
call_fn() {
    local fn="$1"; shift
    OUT="$(HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
        bash "$SANDBOX/load-and-call" "$POOL_RESOLVE" "$fn" "$@" </dev/null 2>/dev/null)"
    RC=$?
    case "$OUT" in
        '<undefined function: '*) MISSING=1 ;;
        *) MISSING=0 ;;
    esac
}

keep() { SAVED="$OUT"; }

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# expect_eq <label> <expected> <got>
expect_eq() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function could not be loaded from pool-resolve)"
    elif [[ "$3" == "$2" ]]; then ok "$1"
    else bad "$1 (expected [$2], got [${3:-<empty>}])"; fi
}

# expect_json_eq <label> <expected> <got> — key order and whitespace ignored
expect_json_eq() {
    local want got
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function could not be loaded from pool-resolve)"; return
    fi
    want="$(jq -S -c . <<<"$2" 2>/dev/null)"
    got="$(jq -S -c . <<<"$3" 2>/dev/null)"
    if [[ -n "$want" && -n "$got" && "$got" == "$want" ]]; then ok "$1"
    else bad "$1 (expected [$2], got [${3:-<empty>}])"; fi
}

# expect_rc <label> <expected>
expect_rc() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function could not be loaded from pool-resolve)"
    elif [[ "$RC" -eq "$2" ]]; then ok "$1"
    else bad "$1 (expected exit $2, got $RC)"; fi
}

# expect_nonzero <label> — a miss must exit non-zero, via a real function
expect_nonzero() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function could not be loaded from pool-resolve)"
    elif [[ "$RC" -ne 0 ]]; then ok "$1"
    else bad "$1 (exit 0, should be non-zero)"; fi
}

NODE_GATEWAY='{"name":"gateway","role":"gateway","ip":"172.104.114.31","user":"fatesaikou","tunnel_user":"sshproxy","key_secret":"SSH_KEY_ACTIONS","host_key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY","generation":8}'
NODE_FH_L='{"name":"fh-l","role":"provider","ip":"10.0.0.2","user":"fatesaikou","key_secret":"SSH_KEY_ACTIONS","hops":[{"host":"gateway","port":22,"user":"fatesaikou","key_secret":"SSH_KEY_ACTIONS"}]}'
NODE_FH_PROXY='{"name":"fh-proxy","role":"provider","ip":"10.0.0.3","user":"fatesaikou","key_secret":"SSH_KEY_ACTIONS"}'
STATE_JSON="{\"schema\":1,\"serial\":12,\"written_at\":\"2026-09-14T09:02:19Z\",\"source\":\"rotate-gateway#34836287173\",\"nodes\":{\"gateway\":${NODE_GATEWAY},\"fh-l\":${NODE_FH_L},\"fh-proxy\":${NODE_FH_PROXY}},\"workers\":[{\"port\":2300,\"provider\":\"fh-l\",\"image\":\"default\",\"container\":\"mlp-fh-l-default-34822789603\",\"created_at\":\"2026-09-14T08:26:00Z\"}]}"

echo "state_file_lookup:"
call_fn state_file_lookup "$STATE_JSON" fh-l
expect_rc "hit (fh-l) exits 0" 0
expect_json_eq "hit (fh-l) returns the node object verbatim" "$NODE_FH_L" "$OUT"

call_fn state_file_lookup "$STATE_JSON" gateway
expect_rc "hit (gateway) exits 0" 0
expect_json_eq "hit (gateway) returns the gateway node" "$NODE_GATEWAY" "$OUT"

call_fn state_file_lookup "$STATE_JSON" fh-proxy
expect_rc "hit (fh-proxy) exits 0" 0
expect_json_eq "hit (fh-proxy) returns the node object" "$NODE_FH_PROXY" "$OUT"

# D2: the same machine has two spellings; layer 1 must resolve both to the
# one hyphenated key the contract requires in .nodes.
call_fn state_file_lookup "$STATE_JSON" fh_l
expect_rc "hit via underscore spelling exits 0" 0
expect_json_eq "underscore spelling finds the hyphenated node" "$NODE_FH_L" "$OUT"

call_fn state_file_lookup "$STATE_JSON" FH-L
expect_json_eq "uppercase spelling finds the same node" "$NODE_FH_L" "$OUT"

call_fn state_file_lookup "$STATE_JSON" no-such-node
expect_eq "miss prints nothing" "" "$OUT"
expect_nonzero "miss exits non-zero"

call_fn state_file_lookup "" fh-l
expect_eq "empty-string state prints nothing" "" "$OUT"
expect_nonzero "empty-string state exits non-zero"

call_fn state_file_lookup 'not-json{' fh-l
expect_eq "invalid-JSON state prints nothing" "" "$OUT"
expect_nonzero "invalid-JSON state exits non-zero"

call_fn state_file_lookup '{"schema":1,"serial":1}' fh-l
expect_eq "state without .nodes prints nothing" "" "$OUT"
expect_nonzero "state without .nodes exits non-zero"

call_fn state_file_lookup '{"schema":1,"serial":1,"nodes":{}}' fh-l
expect_eq "empty .nodes prints nothing" "" "$OUT"
expect_nonzero "empty .nodes exits non-zero"

echo "cache_key_for:"
call_fn cache_key_for gateway
expect_rc "already-canonical name exits 0" 0
expect_eq "already-canonical name is unchanged" "gateway" "$OUT"

call_fn cache_key_for fh-l
expect_eq "hyphenated name is unchanged" "fh-l" "$OUT"

call_fn cache_key_for fh_proxy
expect_rc "underscored name exits 0" 0
expect_eq "underscore becomes hyphen" "fh-proxy" "$OUT"
keep

call_fn cache_key_for fh-proxy
expect_eq "cache_key_for fh-proxy == cache_key_for fh_proxy (one key, not two files)" "$SAVED" "$OUT"

call_fn cache_key_for FH-PROXY
expect_rc "uppercase name exits 0" 0
expect_eq "uppercase becomes lowercase" "fh-proxy" "$OUT"

call_fn cache_key_for FH_PROXY
expect_eq "uppercase plus underscore normalise together" "fh-proxy" "$OUT"

call_fn cache_key_for FH_Proxy
expect_eq "mixed case and underscore normalise together" "fh-proxy" "$OUT"

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-pool-resolve-state: ${pass} passed"
else
    echo "test-pool-resolve-state: ${fail} FAILED, ${pass} passed"
fi
exit "$fail"
