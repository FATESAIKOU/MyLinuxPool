#!/usr/bin/env bash
# Tests for the power-node discovery logic of ops-scripts/mlp (C2 contract).
# wake/down must discover which nodes declare power actions instead of
# hardcoding fh-l (docs/REDESIGN.md §3.35).
#
# Testable-interface report: the implementer did NOT extract a pure
# "filter nodes_json by .power.<kind>" function. The discovery lives in
# `power_targets <action>`, which itself calls `gh api` (to enumerate
# NODE_* var names) and `$POOL_RESOLVE <node>` (to fetch each node's
# JSON). So the node JSON is injected here by stubbing those two calls:
#   - gh stub reads $GH_VARS        (which NODE_* vars exist)
#   - pool-resolve stub reads $NODES_JSON  (name -> node JSON, injected)
# and the function under test is the real power_targets / the zero-candidate
# branch of pick_power_target (which owns the "explicit error, exit
# non-zero" property — power_targets itself exits 0 on an empty result).
# The multi-node fzf branch of pick_power_target is NOT tested (needs fzf).
#
# Loading strategy: mlp ends with `main "$@"` which would run the CLI.
# Everything except the main() body, the `main "$@"` line and the
# `source .../ssh.sh` line is extracted into a temp lib; a per-call loader
# sources it with `sleep` neutered, overrides POOL_RESOLVE to the stub
# (mlp sets it to the repo's real pool-resolve), calls the function in a
# subshell (so an internal `die` -> `exit` is captured, not fatal), and
# stamps a done-marker — aborted loads FAIL, never pass.
#
# Failure injection (REDESIGN.md §3.3, mandatory): every case is re-run
# against a stub power_targets that ALWAYS answers "gateway" and always
# exits 0 — wrong on every fixture by construction. The verdict there is
# INVERTED and scored SEPARATELY: a check that FIRES is a detection
# (inj ok); a check the stub slips past is vacuous (inj MISS) and makes
# the whole script exit non-zero. Injection verdicts never touch the main
# pass/fail counters.
#
# bash 3.2 compatible on purpose (mlp's own rule): no declare -A, no
# ${var,,}, no mapfile.
#
# Run: scripts/tests/test-mlp-discovery.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

MLP="ops-scripts/mlp"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi
if [[ ! -f "$MLP" ]]; then
    echo "test-mlp-discovery: ${MLP} is missing; every case below will FAIL" >&2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-mlp-discovery.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/home" "$SANDBOX/bin"

# If anything in the extracted lib ever reaches an external tool, it must
# fail fast — no network, no real machine, no hang, no fzf.
for tool in gh ssh scp nc curl wget fzf; do
    cat > "$SANDBOX/bin/$tool" <<'STUB'
#!/usr/bin/env bash
echo "test stub: refusing to run ($0)" >&2
exit 255
STUB
    chmod +x "$SANDBOX/bin/$tool"
done

# gh stub: power_targets calls `gh api ... --jq '.variables[].name'` to
# enumerate NODE_* vars. The injected GH_VARS file is the fixture.
cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
cat "${GH_VARS:-/dev/null}"
STUB
chmod +x "$SANDBOX/bin/gh"

# pool-resolve stub: power_targets calls `"$POOL_RESOLVE" <node>`. The
# injected NODES_JSON file maps node name -> node JSON.
cat > "$SANDBOX/bin/pool-resolve" <<'STUB'
#!/usr/bin/env bash
node="$1"
[[ -n "${NODES_JSON:-}" ]] || exit 1
jq -c --arg n "$node" '.[$n] // empty' "$NODES_JSON"
STUB
chmod +x "$SANDBOX/bin/pool-resolve"

# Extract everything from mlp except main()'s body, the final `main "$@"`
# and the `source .../ssh.sh` line. Sourcing the result can never start
# the live CLI.
awk '
    $0 ~ /^main\(\)/ { inmain = 1; depth = 1; next }
    inmain { depth += gsub(/{/, "{") - gsub(/}/, "}"); if ($0 ~ /}/ && depth <= 0) inmain = 0; next }
    $0 ~ /^main "\$@"/ { next }
    $0 ~ /^source / { next }
    { print }
' "$MLP" > "$SANDBOX/mlp-lib.sh"

# Broken copy for the failure-injection pass: always answers "gateway",
# whatever the vars/nodes say; always exits 0. Wrong on every fixture.
cp "$SANDBOX/mlp-lib.sh" "$SANDBOX/mlp-lib-broken.sh"
cat >> "$SANDBOX/mlp-lib-broken.sh" <<'BROKEN'
power_targets() {
    printf 'gateway\n'
    return 0
}
BROKEN

# Loader: <lib> <fn> [args...]. Sources the extracted lib (its `set -u`
# stays active, as in mlp itself), overrides POOL_RESOLVE to the stub,
# calls the function inside a subshell so a `die`->`exit` is captured,
# and stamps the exit code in $LOADER_DONE. If sourcing ran the CLI — or
# the call aborted — the done-marker never appears and the case FAILs
# instead of passing by accident.
cat > "$SANDBOX/load-and-call" <<'LOADER'
#!/usr/bin/env bash
set +e +u
sleep() { exit 3; }
lib="$1"; fn="$2"; shift 2
rm -f "$LOADER_DONE"
args=("$@")
source "$lib" >/dev/null 2>&1
POOL_RESOLVE="${POOL_RESOLVE_STUB:-true}"
if ! declare -F "$fn" >/dev/null 2>&1; then
    printf '<undefined function: %s>' "$fn"
    exit 127
fi
# bash 3.2 + set -u: expanding an EMPTY "${args[@]}" errors as "unbound
# variable", so branch on $# instead and keep -u alive for the call itself
# (that is what makes an mlp-side unbound-variable bug still surface).
if [[ "$#" -gt 0 ]]; then
    ( "$fn" "${args[@]}" )
else
    ( "$fn" )
fi
rc=$?
printf '%s' "$rc" > "$LOADER_DONE"
exit "$rc"
LOADER
chmod +x "$SANDBOX/load-and-call"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

OUT=""; ERR=""; RC=0; MISSING=0
GH_VARS="$SANDBOX/gh_vars"
NODES_JSON="$SANDBOX/nodes.json"

# set_nodes <gh-vars-lines...> <nodes-json> — write the fixture files
set_nodes() {
    local nodes="$1"; shift
    : > "$GH_VARS"
    for v in "$@"; do printf 'NODE_%s\n' "$v" >> "$GH_VARS"; done
    printf '%s\n' "$nodes" > "$NODES_JSON"
}

# call_fn <lib> <fn> [args...] — run once in the stubbed environment with
# stdin closed. Populates OUT/ERR/RC; MISSING=1 on abort/undefined.
call_fn() {
    local lib="$1" fn="$2"; shift 2
    local errfile
    errfile="$(mktemp "${SANDBOX}/err.XXXXXX")"
    rm -f "$SANDBOX/loader.done"
    OUT="$(HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
        LOADER_DONE="$SANDBOX/loader.done" \
        POOL_RESOLVE_STUB="$SANDBOX/bin/pool-resolve" \
        GH_VARS="$GH_VARS" NODES_JSON="$NODES_JSON" \
        bash "$SANDBOX/load-and-call" "$lib" "$fn" "$@" \
        </dev/null 2>"$errfile")"
    ERR="$(cat "$errfile")"; rm -f "$errfile"
    if [[ -f "$SANDBOX/loader.done" ]]; then
        MISSING=0
        RC="$(cat "$SANDBOX/loader.done")"
    else
        MISSING=1
        RC=127
    fi
}

# CASE_OK — single source of truth for "the contract was satisfied";
# both the main suite and the injection pass evaluate through it.
#   expected == "NONE"  : zero candidates — non-zero exit, a stderr
#                         reason, nothing on stdout (pick_power_target's
#                         die branch; power_targets itself exits 0 with
#                         no output, so NONE cases call pick_power_target)
#   otherwise           : exit 0 and exactly those names on stdout
CASE_OK=0
evaluate_case() {  # <lib> <fn> <expected|NONE> [fn-args...]
    local lib="$1" fn="$2" expected="$3"; shift 3
    local got want
    call_fn "$lib" "$fn" "$@"
    CASE_OK=0
    [[ "$MISSING" -eq 1 ]] && return
    if [[ "$expected" == "NONE" ]]; then
        [[ "$RC" -ne 0 && -n "$ERR" && -z "$OUT" ]] && CASE_OK=1
    else
        got="$(printf '%s\n' "$OUT" | sort)"
        want="$(printf '%s\n' "$expected" | sort)"
        [[ "$RC" -eq 0 && "$got" == "$want" ]] && CASE_OK=1
    fi
}

# ---- fixtures: node objects (ARCHITECTURE.md shape, hand-written) -------
J_FH_L='{"name":"fh-l","role":"provider","power":{"launch":{"method":"wol-unicast","via":"fh-proxy","mac":"B4:2E:99:FB:63:5E","target_ip":"192.168.0.136"},"shutdown":{"method":"ssh","command":"sudo systemctl poweroff"}}}'
J_FH_L_LONLY='{"name":"fh-l","role":"provider","power":{"launch":{"method":"wol-unicast"}}}'
J_FH_L_SONLY='{"name":"fh-l","role":"provider","power":{"shutdown":{"method":"ssh","command":"sudo systemctl poweroff"}}}'
J_FH_PXY='{"name":"fh-proxy","role":"provider","power":{"launch":{"method":"wol-unicast","via":"fh-l"}}}'
J_FH_PXY_NOPWR='{"name":"fh-proxy","role":"provider"}'
J_NULLP='{"name":"nullp","power":null}'
J_NOPWR='{"name":"nodep"}'
J_EMPTY='{}'

echo "power_targets / pick_power_target (main suite, real mlp lib):"
run_main_case() {  # <label> <fn> <expected|NONE> [fn-args...]
    local label="$1" fn="$2" expected="$3"; shift 3
    evaluate_case "$SANDBOX/mlp-lib.sh" "$fn" "$expected" "$@"
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$label (function not found in mlp — implementation not landed yet?)"
    elif [[ "$CASE_OK" -eq 1 ]]; then
        ok "$label"
    else
        bad "$label (rc=$RC, out=[${OUT:-<empty>}], err=[${ERR:-<empty>}])"
    fi
}

set_nodes "{\"fh-l\":$J_FH_L,\"fh-proxy\":$J_FH_PXY_NOPWR}" fh-l fh-proxy
run_main_case "three nodes, only one declares power.launch -> that one is picked" power_targets "fh-l" launch

set_nodes "{\"fh-proxy\":$J_FH_PXY_NOPWR}" fh-proxy
run_main_case "no node declares power.launch -> explicit error, non-zero exit" pick_power_target "NONE" launch

set_nodes "{\"fh-l\":$J_FH_L,\"fh-proxy\":$J_FH_PXY}" fh-l fh-proxy
run_main_case "two nodes declare power.launch -> BOTH returned (fzf belongs to pick_power_target)" power_targets $'fh-l\nfh-proxy' launch

set_nodes "{\"fh-l\":$J_FH_L,\"fh-proxy\":$J_FH_PXY}" fh-l fh-proxy
run_main_case "down: a launch-only node is NOT a shutdown candidate" power_targets "fh-l" shutdown

set_nodes "{\"fh-l\":$J_FH_L_SONLY}" fh-l
run_main_case "wake: a shutdown-only node is NOT a launch candidate (error, non-zero)" pick_power_target "NONE" launch
run_main_case "down: a shutdown-only node IS found" power_targets "fh-l" shutdown

set_nodes "{\"nullp\":$J_NULLP,\"fh-l\":$J_FH_L}" nullp fh-l
run_main_case "power:null node does not crash discovery" power_targets "fh-l" launch

set_nodes "{}"
run_main_case "no nodes at all -> explicit error, non-zero exit" pick_power_target "NONE" launch

# ---- smoke: cmd_wake / cmd_down entry points (2026-09-15 regression) ------
# `mlp wake` / `mlp down` with no argument used to die with
# "unbound variable" because a leftover `="$1"` was still on the local
# declaration while the very next line overwrote $node from
# pick_power_target. The pure-function cases above cannot see that — these
# call the real entry points. Verdict: exit non-zero is FINE (they are
# supposed to stop in this fixture), but the output must not contain
# "unbound variable" — that is the regression.
J_GW='{"name":"gateway","role":"gateway","ip":"1.2.3.4","user":"gw","host_key":"ssh-ed25519 AAAAtest"}'

echo "smoke: cmd_wake / cmd_down entry points with no args (regression):"
run_smoke() {  # <label> <fn> [args...]
    local label="$1" fn="$2"; shift 2
    call_fn "$SANDBOX/mlp-lib.sh" "$fn" "$@"
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$label (function not found — implementation not landed yet?)"
    elif [[ "$RC" -eq 0 ]]; then
        bad "$label (exited 0 — should have stopped in this fixture)"
    elif printf '%s' "$ERR" | grep -q 'unbound variable'; then
        bad "$label (UNBOUND VARIABLE: ${ERR})"
    else
        ok "$label (exit $RC, no unbound variable)"
    fi
}

set_nodes "{\"gateway\":$J_GW,\"fh-proxy\":$J_FH_PXY_NOPWR}" fh-proxy
run_smoke "mlp wake (no args): no power.launch node -> clean stop" cmd_wake

set_nodes "{\"gateway\":$J_GW,\"fh-proxy\":$J_FH_PXY_NOPWR}" fh-proxy
run_smoke "mlp down (no args): no power.shutdown node -> clean stop" cmd_down

set_nodes "{\"gateway\":$J_GW,\"fh-proxy\":$J_FH_PXY_NOPWR}" fh-proxy
run_smoke "mlp wake fh-proxy (named, no power.launch) -> clean stop" cmd_wake fh-proxy

set_nodes "{\"gateway\":$J_GW,\"fh-l\":$J_FH_L,\"fh-proxy\":$J_FH_PXY_NOPWR}" fh-l fh-proxy
run_smoke "mlp down fh-l (named, launch+shutdown but no gateway_port) -> clean stop at validation" cmd_down fh-l

# ---- failure injection (REDESIGN.md §3.3, mandatory) ---------------------
# The same cases, evaluated against a power_targets stub that always
# answers "gateway" and always exits 0. That stub is wrong on every
# fixture by construction, so:
#   inj ok    = the check FIRED on the stub — a detection (separate counter)
#   inj MISS  = the stub slipped past the check — vacuous; script exits 1
echo "failure injection (always-gateway stub, verdict inverted):"
inject_ok=0; inject_miss=0
inj_ok()   { printf '  inj ok    %s\n' "$1"; inject_ok=$((inject_ok + 1)); }
inj_miss() { printf '  inj MISS  %s\n' "$1"; inject_miss=$((inject_miss + 1)); }

run_inj_case() {  # <label> <fn> <expected|NONE> [fn-args...]
    local label="$1" fn="$2" expected="$3"; shift 3
    evaluate_case "$SANDBOX/mlp-lib-broken.sh" "$fn" "$expected" "$@"
    if [[ "$MISSING" -eq 1 ]]; then
        inj_miss "$label (stub never ran — injection harness broken)"
    elif [[ "$CASE_OK" -eq 1 ]]; then
        inj_miss "$label (stub satisfied the contract — this check did NOT catch the always-gateway bug)"
    else
        inj_ok "$label (stub answered gateway, check fired)"
    fi
}

set_nodes "{\"fh-l\":$J_FH_L,\"fh-proxy\":$J_FH_PXY_NOPWR}" fh-l fh-proxy
run_inj_case "one-of-three: stub answered gateway, check demanded fh-l" power_targets "fh-l" launch

set_nodes "{\"fh-proxy\":$J_FH_PXY_NOPWR}" fh-proxy
run_inj_case "none: stub exited 0, check demanded non-zero" pick_power_target "NONE" launch

set_nodes "{\"fh-l\":$J_FH_L,\"fh-proxy\":$J_FH_PXY}" fh-l fh-proxy
run_inj_case "two: stub returned one node, check demanded both" power_targets $'fh-l\nfh-proxy' launch
run_inj_case "down: stub returned fh-l, check demanded fh-l only" power_targets "fh-l" shutdown

set_nodes "{\"fh-l\":$J_FH_L_SONLY}" fh-l
run_inj_case "wake: stub returned a node, check demanded failure" pick_power_target "NONE" launch

set_nodes "{\"nullp\":$J_NULLP,\"fh-l\":$J_FH_L}" nullp fh-l
run_inj_case "null-power: stub returned gateway, check demanded fh-l" power_targets "fh-l" launch

set_nodes "{}"
run_inj_case "empty: stub exited 0, check demanded non-zero" pick_power_target "NONE" launch

if [[ "$inject_miss" -eq 0 ]]; then
    ok "failure injection: all ${inject_ok} checks fired on the always-gateway stub"
else
    bad "failure injection: ${inject_miss} check(s) did NOT catch the always-gateway stub — suite is vacuous (${inject_ok} fired)"
fi

echo
if [[ "$fail" -eq 0 && "$inject_miss" -eq 0 ]]; then
    echo "test-mlp-discovery: ${pass} passed (failure injection: ${inject_ok}/${inject_ok} detected)"
else
    echo "test-mlp-discovery: ${fail} FAILED, ${pass} passed (failure injection: ${inject_miss} NOT detected)"
fi
exit "$fail"
