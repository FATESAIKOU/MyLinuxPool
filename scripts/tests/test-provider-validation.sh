#!/usr/bin/env bash
# test-provider-validation.sh — create-worker's provider input validation
# (docs/REDESIGN.md §3.35): "which providers exist" is owned by the NODE_*
# vars, not by a hard-coded choice list in the workflow.
#
# The check lives inline in .github/workflows/create-worker.yml's
# "Validate inputs" run block and is not exported as a callable function,
# so this test extracts that run block and executes it against a fake `gh`
# serving a fixture of NODE_* vars. No gh, no network, no real machine,
# no workflow dispatch. stdin is /dev/null everywhere.
#
# Every check can fail (REDESIGN.md §3.3). The always-pass failure injection
# at the end feeds the same case list a validator that exits 0 no matter
# what, and verifies each blocking case is caught. Demo results are counted
# separately and never added to the suite totals.
# Run: scripts/tests/test-provider-validation.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

WORKFLOW=".github/workflows/create-worker.yml"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-provider-validation.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin" "$SANDBOX/home"

# ---------------------------------------------------------------------------
# Extract the run block that validates PROVIDER_IN. Content-based selection,
# so a renamed step does not silently turn this test into a no-op.
# ---------------------------------------------------------------------------
VALIDATOR="$SANDBOX/provider-validation.sh"
: > "$VALIDATOR"
EXTRACTED=0
if [[ -f "$WORKFLOW" ]]; then
    awk '
        {
            line = $0
            if (collecting) {
                if (line ~ /^[[:space:]]*$/) { buf = buf "\n"; next }
                match(line, /^[[:space:]]*/); ind = RLENGTH
                if (ind > run_indent) {
                    if (base == 0) base = ind
                    buf = buf substr(line, base + 1) "\n"
                    next
                }
                collecting = 0
            }
            if (line ~ /^[[:space:]]*run:[[:space:]]*\|-?[[:space:]]*$/) {
                if (buf ~ /PROVIDER_IN/) { printf "%s", buf; exit }
                buf = ""; collecting = 1
                match(line, /^[[:space:]]*/); run_indent = RLENGTH; base = 0
            }
        }
        END { if (buf ~ /PROVIDER_IN/) printf "%s", buf }
    ' "$WORKFLOW" > "$VALIDATOR"
    if [[ -s "$VALIDATOR" ]] && grep -q 'PROVIDER_IN' "$VALIDATOR"; then
        EXTRACTED=1
    fi
fi
if [[ "$EXTRACTED" -ne 1 ]]; then
    echo "test-provider-validation: could not extract the PROVIDER_IN validation from ${WORKFLOW}; every case below will FAIL" >&2
    echo "test-provider-validation: (the step may have been renamed or the validation moved)" >&2
fi

# ---------------------------------------------------------------------------
# Fake gh: serves the NODE_* fixture and applies the --jq filter the same way
# real gh does, so the extracted script's own filter logic is what runs.
# ---------------------------------------------------------------------------
FAKE_GH_VARIABLES="$SANDBOX/variables.json"
cat > "$FAKE_GH_VARIABLES" <<'JSON'
{"variables":[
 {"name":"NODE_FH_L","value":"{\"name\":\"fh-l\",\"role\":\"provider\",\"capabilities\":{\"worker-host\":{\"runtime\":\"docker\"}}}"},
 {"name":"NODE_FH_PROXY","value":"{\"name\":\"fh-proxy\",\"role\":\"provider\",\"capabilities\":{\"worker-host\":{\"runtime\":\"docker\"}}}"},
 {"name":"NODE_GATEWAY","value":"{\"name\":\"gateway\",\"role\":\"gateway\"}"},
 {"name":"POOL_WORKERS","value":"[]"}
]}
JSON

cat > "$SANDBOX/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
if [[ "${FAKE_GH_MODE:-ok}" == "fail" ]]; then
    echo "gh: HTTP 503 Service Unavailable" >&2
    exit 1
fi
filter=""; var_name=""
for a in "$@"; do
    # Extract the jq filter after --jq
    if [[ "${prev:-}" == "--jq" ]]; then
        filter="$a"
    fi
    # Extract variable name from paths like "repos/owner/repo/actions/variables/NODE_FH_L"
    if [[ "$a" == */actions/variables/* && "$a" != "--"* ]]; then
        var_name="${a##*/variables/}"
    fi
    prev="$a"
done

# If querying a specific variable, extract it from the full list
if [[ -n "$var_name" ]]; then
    data="$(jq --arg name "$var_name" '.variables[] | select(.name == $name) | {name: .name, value: .value}' "$FAKE_GH_VARIABLES" 2>/dev/null)"
    if [[ -n "$filter" ]]; then
        jq -r "$filter" <<<"$data"
    else
        jq '.' <<<"$data"
    fi
elif [[ -n "$filter" ]]; then
    jq -r "$filter" "$FAKE_GH_VARIABLES"
else
    cat "$FAKE_GH_VARIABLES"
fi
FAKE_GH
chmod +x "$SANDBOX/bin/gh"

# Every other external command must fail fast, not reach anything real.
for tool in ssh scp nc curl wget; do
    cat > "$SANDBOX/bin/$tool" <<'STUB'
#!/usr/bin/env bash
echo "test stub: refusing to run ($0)" >&2
exit 255
STUB
    chmod +x "$SANDBOX/bin/$tool"
done

TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT="timeout 15"
else
    echo "  note  timeout(1) not found; relying on </dev/null alone to avoid hangs"
fi

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

VOUT=""; VRC=0

# run_validator <provider_input> <fake_gh_mode>
run_validator() {
    local input="$1" ghmode="$2"
    if [[ "$EXTRACTED" -ne 1 ]]; then
        VOUT=""; VRC=127
        return
    fi
    VOUT="$(cd "$REPO_ROOT" && PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX/home" \
        PROVIDER_IN="$input" GH_REPO="owner/repo" \
        IMAGE_IN="default" NAME_IN="demo" \
        FAKE_GH_MODE="$ghmode" FAKE_GH_VARIABLES="$FAKE_GH_VARIABLES" \
        $TIMEOUT bash "$VALIDATOR" </dev/null 2>&1)"
    VRC=$?
}

# ---------------------------------------------------------------------------
# The frozen contract's cases. require = substrings the blocking message must
# contain ("Available" names) when the contract demands them.
# ---------------------------------------------------------------------------
CASE_LABELS=(
    "valid provider fh-l passes"
    "valid provider fh-proxy passes"
    "underscore spelling fh_proxy is the same provider"
    "uppercase FH-L is the same provider"
    "mixed case FH-Proxy is the same provider"
    "unknown name fh-z is blocked and lists the options"
    "node exists but role!=provider (gateway) is blocked"
    "empty input is blocked"
    "listing unavailable (gh fails) is blocked, not waved through"
)
CASE_INPUTS=( "fh-l" "fh-proxy" "fh_proxy" "FH-L" "FH-Proxy" "fh-z" "gateway" "" "fh-l" )
CASE_EXPECT=( pass pass pass pass pass block block block block )
CASE_REQUIRE=( "" "" "" "" "" "fh-l fh-proxy" "" "" "" )
CASE_GHMODE=( ok ok ok ok ok ok ok ok fail )

if [[ "$EXTRACTED" -eq 1 ]]; then
    ok "validation extracted from ${WORKFLOW}"
else
    bad "validation extracted from ${WORKFLOW} (nothing to run — all cases fail)"
fi

run_suite() {
    local mode="$1" i blocked require req
    for ((i = 0; i < ${#CASE_LABELS[@]}; i++)); do
        run_validator "${CASE_INPUTS[$i]}" "${CASE_GHMODE[$i]}"
        if [[ "$EXTRACTED" -ne 1 ]]; then
            [[ "$mode" == real ]] && bad "${CASE_LABELS[$i]} (validator not extracted)"
            continue
        fi
        if [[ "${CASE_EXPECT[$i]}" == pass ]]; then
            [[ "$mode" == real ]] || continue
            if [[ "$VRC" -eq 0 ]]; then
                if [[ "$VOUT" == *"::error::"* ]]; then
                    bad "${CASE_LABELS[$i]} (exit 0 but it still printed an error)"
                else
                    ok "${CASE_LABELS[$i]}"
                fi
            else
                bad "${CASE_LABELS[$i]} (expected exit 0, got ${VRC}; output: ${VOUT:-<empty>})"
            fi
            continue
        fi
        # blocking case: the assertion passes only if the run was blocked,
        # said something, and mentioned every required name.
        blocked=1
        [[ "$VRC" -ne 0 ]] || blocked=0
        [[ -n "$VOUT" ]] || blocked=0
        for req in ${CASE_REQUIRE[$i]}; do
            [[ "$VOUT" == *"$req"* ]] || blocked=0
        done
        if [[ "$mode" == real ]]; then
            if [[ "$blocked" -eq 1 ]]; then
                ok "${CASE_LABELS[$i]}"
            else
                bad "${CASE_LABELS[$i]} (exit ${VRC}; output: ${VOUT:-<empty>})"
            fi
        else
            DEMO_TOTAL=$((DEMO_TOTAL + 1))
            if [[ "$blocked" -eq 0 ]]; then
                DEMO_CAUGHT=$((DEMO_CAUGHT + 1))
                printf '  [demo] caught  %s\n' "${CASE_LABELS[$i]}"
            else
                printf '  [demo] MISSED  %s (an always-pass validator slipped through)\n' "${CASE_LABELS[$i]}"
            fi
        fi
    done
}

run_suite real

# ---------------------------------------------------------------------------
# Failure injection, counted separately: an always-pass validator must be
# caught by every blocking case above. DEMO_OK requires DEMO_CAUGHT==DEMO_TOTAL.
# ---------------------------------------------------------------------------
DEMO_TOTAL=0; DEMO_CAUGHT=0; DEMO_BROKEN=0
echo
echo "failure injection (separate from the totals above):"
DEMO_VALIDATOR="$SANDBOX/always-pass.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DEMO_VALIDATOR"
chmod +x "$DEMO_VALIDATOR"

# swap the validator for the demo, then restore
REAL_VALIDATOR="$VALIDATOR"
VALIDATOR="$DEMO_VALIDATOR"
EXTRACTED_SAVE="$EXTRACTED"
EXTRACTED=1
run_suite demo
VALIDATOR="$REAL_VALIDATOR"
EXTRACTED="$EXTRACTED_SAVE"

if [[ "$DEMO_TOTAL" -gt 0 && "$DEMO_CAUGHT" -eq "$DEMO_TOTAL" ]]; then
    printf '[demo] always-pass validator was caught by %s/%s blocking checks — the suite is not a rubber stamp\n' \
        "$DEMO_CAUGHT" "$DEMO_TOTAL"
else
    printf '[demo] DEMO FAILED: caught %s/%s blocking checks with an always-pass validator\n' \
        "$DEMO_CAUGHT" "$DEMO_TOTAL"
    DEMO_BROKEN=1
fi

echo
demo_status="ok"
if [[ "$DEMO_BROKEN" -ne 0 ]]; then demo_status="FAILED"; fi
if [[ "$fail" -eq 0 && "$DEMO_BROKEN" -eq 0 ]]; then
    echo "test-provider-validation: ${pass} passed (demo ${demo_status})"
else
    echo "test-provider-validation: ${fail} FAILED, ${pass} passed (demo ${demo_status})"
fi

if [[ "$fail" -ne 0 ]]; then
    exit "$fail"
fi
if [[ "$DEMO_BROKEN" -ne 0 ]]; then
    exit 2
fi
exit 0
