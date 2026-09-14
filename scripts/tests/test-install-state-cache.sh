#!/usr/bin/env bash
# Tests for install_state_cache() in
# shared-configs/pool-runtime/files/pool-tunnel. The interface is frozen:
#   install_state_cache <state_json> <dest_path>
#   - valid JSON with .schema == 1 -> exit 0, target written atomically, mode 600
#   - anything else                -> exit non-zero, target NOT created,
#                                     pre-existing target NOT touched,
#                                     no temp files left behind
# Contract context: docs/STATE_CONTRACT.md §2 (the state.json payload).
#
# Loading strategy: pool-tunnel's `main "$@"` at the bottom runs a live,
# loop-forever CLI, so the whole file is never sourced. Everything except the
# main() body and its invocation is extracted into a temp lib (header globals
# and helpers like log() come along), then a per-call loader sources it with
# `sleep` neutered — so even a broken extraction cannot hang the suite — and
# stamps a done-marker; an aborted load reports as a FAIL, never as a pass.
#
# fetch_state_cache() is deliberately NOT tested: it needs a live ssh
# ControlMaster (task B2 scope). Only the pure install half is exercised.
#
# Failure injection (REDESIGN.md §3.3, mandatory): the rejection suite is run
# a second time against a stub install_state_cache that writes the target even
# on a bad schema and always exits 0. The verdict there is INVERTED and scored
# SEPARATELY: a check that FIRES on the broken stub is a detection (inj ok);
# a check that stays green while the stub violated its property is vacuous
# (inj MISS) and makes the whole script exit non-zero. A property the stub
# cannot violate (old file's presence/mode survive its plain overwrite) is
# reported inj n/a — an honest green, with the real preservation property
# covered by the byte-for-byte check. Injection verdicts never touch the main
# pass/fail counters, so a suite that catches everything exits 0.
#
# Run: scripts/tests/test-install-state-cache.sh
#      POOL_TUNNEL=/path/to/fake scripts/tests/test-install-state-cache.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

POOL_TUNNEL="${POOL_TUNNEL:-shared-configs/pool-runtime/files/pool-tunnel}"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi
if [[ ! -f "$POOL_TUNNEL" ]]; then
    echo "test-install-state-cache: ${POOL_TUNNEL} is missing; every case below will FAIL" >&2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-install-state-cache.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/home" "$SANDBOX/bin"

# If anything in the extracted lib ever reaches an external tool, it must fail
# fast — no network, no real machine, no hang.
for tool in gh ssh scp nc curl wget; do
    cat > "$SANDBOX/bin/$tool" <<'STUB'
#!/usr/bin/env bash
echo "test stub: refusing to run ($0)" >&2
exit 255
STUB
    chmod +x "$SANDBOX/bin/$tool"
done

# Extract everything from pool-tunnel except main()'s body and the final
# `main "$@"` invocation. Sourcing the result defines the header globals and
# helper functions but can never start the live CLI loop.
awk '
    $0 ~ /^main\(\)/ { inmain = 1; depth = 1; next }
    inmain { depth += gsub(/{/, "{") - gsub(/}/, "}"); if ($0 ~ /}/ && depth <= 0) inmain = 0; next }
    $0 ~ /^main "\$@"/ { next }
    { print }
' "$POOL_TUNNEL" > "$SANDBOX/pool-tunnel-lib.sh"

# Broken copy for the failure-injection pass: the exact bug the contract
# warns about — writes the target even when the schema is bad and always
# exits 0. It violates every rejection property the suite must enforce.
cp "$SANDBOX/pool-tunnel-lib.sh" "$SANDBOX/pool-tunnel-lib-broken.sh"
cat >> "$SANDBOX/pool-tunnel-lib-broken.sh" <<'BROKEN'
install_state_cache() {
    local json="$1" dest="$2"
    printf '%s\n' "$json" > "$dest" 2>/dev/null || true
    return 0
}
BROKEN

# Loader: <lib> <fn> [args...]. Sources the extracted lib (its `set -u`
# stays active, as it is in pool-tunnel itself), calls the function, and
# records the function's exit code in $LOADER_DONE. If sourcing ever ran the
# CLI and it exited — or hung on sleep — the done-marker never appears and
# the case is reported as aborted instead of passing by accident.
cat > "$SANDBOX/load-and-call" <<'LOADER'
#!/usr/bin/env bash
set +e +u
sleep() { exit 3; }
lib="$1"; fn="$2"; shift 2
rm -f "$LOADER_DONE"
args=("$@")
source "$lib" >/dev/null 2>&1
if ! declare -F "$fn" >/dev/null 2>&1; then
    printf '<undefined function: %s>' "$fn"
    exit 127
fi
"$fn" "${args[@]}"
rc=$?
printf '%s' "$rc" > "$LOADER_DONE"
exit "$rc"
LOADER
chmod +x "$SANDBOX/load-and-call"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

OUT=""; ERR=""; RC=0; MISSING=0

# install_via <lib> <json> <dest> — run install_state_cache once in the
# stubbed environment with stdin closed. Populates OUT/ERR/RC; MISSING=1
# when the function could not be loaded or the loader aborted.
install_via() {
    local lib="$1" json="$2" dest="$3"
    rm -f "$SANDBOX/loader.done"
    OUT="$(HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
        LOADER_DONE="$SANDBOX/loader.done" \
        bash "$SANDBOX/load-and-call" "$lib" install_state_cache "$json" "$dest" \
        </dev/null 2>"$SANDBOX/loader.err")"
    ERR="$(cat "$SANDBOX/loader.err" 2>/dev/null)"
    if [[ -f "$SANDBOX/loader.done" ]]; then
        MISSING=0
        RC="$(cat "$SANDBOX/loader.done")"
    else
        MISSING=1
        RC=127
    fi
}

# expect_rc <label> <expected>
expect_rc() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function aborted or undefined — loader stderr: ${ERR:-<empty>})"
    elif [[ "$RC" -eq "$2" ]]; then ok "$1"
    else bad "$1 (expected exit $2, got $RC; stderr: ${ERR:-<empty>})"; fi
}

# expect_nonzero <label> — a rejected input must exit non-zero
expect_nonzero() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function aborted or undefined — loader stderr: ${ERR:-<empty>})"
    elif [[ "$RC" -ne 0 ]]; then ok "$1"
    else bad "$1 (exit 0, should have been rejected)"; fi
}

expect_exists() {
    if [[ "$MISSING" -eq 1 ]]; then bad "$1 (function aborted or undefined)"
    elif [[ -e "$2" ]]; then ok "$1"
    else bad "$1 (missing: $2)"; fi
}

expect_absent() {
    if [[ "$MISSING" -eq 1 ]]; then bad "$1 (function aborted or undefined)"
    elif [[ -e "$2" ]]; then bad "$1 (unexpectedly exists: $2)"
    else ok "$1"; fi
}

# mode_of <path> — mode as a 3-digit octal string, BSD and GNU stat both work
mode_of() {
    if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"
    else stat -c '%a' "$1" 2>/dev/null; fi
}

expect_mode() {
    local got
    if [[ "$MISSING" -eq 1 ]]; then bad "$1 (function aborted or undefined)"; return; fi
    got="$(mode_of "$2")"
    if [[ "$got" == "$3" ]]; then ok "$1"
    else bad "$1 (mode ${got:-<none>}, expected $3)"; fi
}

# expect_json_equal <label> <path> <expected-json> — whitespace-insensitive
expect_json_equal() {
    local got want
    if [[ "$MISSING" -eq 1 ]]; then bad "$1 (function aborted or undefined)"; return; fi
    want="$(jq -S -c . <<<"$3" 2>/dev/null)"
    got="$(jq -S -c . < "$2" 2>/dev/null)"
    if [[ -n "$want" && "$got" == "$want" ]]; then ok "$1"
    else bad "$1 (written content differs from input: got [${got:-<unparseable or missing>}])"; fi
}

# expect_dir_clean <label> <dir> [allowed filenames...] — no stray temp files
expect_dir_clean() {
    local label="$1" dir="$2"; shift 2
    local extra="" f n okname
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        okname=0
        for n in "$@"; do [[ "$f" == "$n" ]] && okname=1; done
        (( okname )) || extra="${extra} $f"
    done < <(ls -A "$dir" 2>/dev/null)
    if [[ -z "$extra" ]]; then ok "$label"
    else bad "$label (stray files left behind:$extra)"; fi
}

# Fixture: the contract example (STATE_CONTRACT.md §2), written out by hand.
VALID_STATE='{
  "schema": 1,
  "serial": 12,
  "written_at": "2026-09-14T09:02:19Z",
  "source": "rotate-gateway#34836287173",
  "nodes": {
    "gateway": {"name": "gateway", "role": "gateway", "ip": "172.104.114.31",
                "user": "fatesaikou", "tunnel_user": "sshproxy",
                "key_secret": "SSH_KEY_ACTIONS",
                "host_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexamplekey",
                "generation": 8},
    "fh-l": {"name": "fh-l", "role": "provider"},
    "fh-proxy": {"name": "fh-proxy", "role": "provider"}
  },
  "workers": [{"port": 2300, "provider": "fh-l", "image": "default",
               "container": "mlp-fh-l-default-34822789603",
               "created_at": "2026-09-14T08:26:00Z"}]
}'
MINIMAL='{"schema":1}'
SCHEMA2="$(jq -c '.schema = 2' <<<"$VALID_STATE")"
SCHEMA99="$(jq -c '.schema = 99' <<<"$VALID_STATE")"
NO_SCHEMA='{"serial":1}'
NOT_JSON='not-json{'
EMPTY=''

# Valid inputs: exit 0, file created with the input intact, mode 600, no litter.
run_valid_checks() {  # <lib> <prefix>
    local lib="$1" pre="$2" cdir dest

    cdir="$SANDBOX/v-valid"; rm -rf "$cdir"; mkdir -p "$cdir"; dest="$cdir/state.json"
    install_via "$lib" "$VALID_STATE" "$dest"
    expect_rc "$pre full valid state exits 0" 0
    expect_exists "$pre target file is created" "$dest"
    expect_json_equal "$pre written content is the input, intact" "$dest" "$VALID_STATE"
    expect_mode "$pre mode is 600" "$dest" 600
    expect_dir_clean "$pre no temp files left" "$cdir" state.json

    cdir="$SANDBOX/v-minimal"; rm -rf "$cdir"; mkdir -p "$cdir"; dest="$cdir/state.json"
    install_via "$lib" "$MINIMAL" "$dest"
    expect_rc "$pre minimal {\"schema\":1} exits 0" 0
    expect_exists "$pre minimal target created" "$dest"
    expect_json_equal "$pre minimal content intact" "$dest" "$MINIMAL"
    expect_dir_clean "$pre minimal: no temp files" "$cdir" state.json

    cdir="$SANDBOX/v-replace"; rm -rf "$cdir"; mkdir -p "$cdir"; dest="$cdir/state.json"
    printf 'OLD STALE CONTENT\n' > "$dest"; chmod 600 "$dest"
    install_via "$lib" "$VALID_STATE" "$dest"
    expect_rc "$pre replacing an existing file exits 0" 0
    expect_json_equal "$pre existing file is replaced with the new state" "$dest" "$VALID_STATE"
    expect_mode "$pre replaced file is still mode 600" "$dest" 600
    expect_dir_clean "$pre replace: no temp files" "$cdir" state.json
}

# A rejected input must exit non-zero AND leave the target completely
# untouched — including when a file with old content was already there.
reject_case() {  # <lib> <prefix> <label> <json>
    local lib="$1" pre="$2" label="$3" json="$4" cdir dest
    cdir="$SANDBOX/r-${label//[^a-z0-9]/-}"; rm -rf "$cdir"; mkdir -p "$cdir"; dest="$cdir/state.json"
    install_via "$lib" "$json" "$dest"
    expect_nonzero "$pre $label exits non-zero"
    expect_absent "$pre $label: target NOT created" "$dest"
    expect_dir_clean "$pre $label: no temp files" "$cdir"
}

run_rejection_checks() {  # <lib> <prefix>
    local lib="$1" pre="$2" cdir dest before after
    reject_case "$lib" "$pre" "schema 2" "$SCHEMA2"
    reject_case "$lib" "$pre" "schema 99" "$SCHEMA99"
    reject_case "$lib" "$pre" "missing schema" "$NO_SCHEMA"
    reject_case "$lib" "$pre" "not JSON" "$NOT_JSON"
    reject_case "$lib" "$pre" "empty string" "$EMPTY"

    cdir="$SANDBOX/r-atomic"; rm -rf "$cdir"; mkdir -p "$cdir"; dest="$cdir/state.json"
    printf 'OLD CONTENT, MUST SURVIVE\n' > "$dest"; chmod 600 "$dest"
    before="$(cksum "$dest")"
    install_via "$lib" "$SCHEMA2" "$dest"
    expect_nonzero "$pre atomicity: rejected write exits non-zero"
    expect_exists "$pre atomicity: old file still there" "$dest"
    after="$(cksum "$dest" 2>/dev/null)"
    if [[ "$before" == "$after" ]]; then
        ok "$pre atomicity: old content byte-for-byte untouched"
    else
        bad "$pre atomicity: old content changed (before [$before], after [${after:-<missing>}])"
    fi
    expect_mode "$pre atomicity: old mode still 600" "$dest" 600
    expect_dir_clean "$pre atomicity: no temp files" "$cdir" state.json
}

echo "install_state_cache (valid inputs):"
run_valid_checks "$SANDBOX/pool-tunnel-lib.sh" "valid"

echo "install_state_cache (rejections, target must not be touched):"
run_rejection_checks "$SANDBOX/pool-tunnel-lib.sh" "reject"

# Failure injection (REDESIGN.md §3.3, mandatory). The rejection properties
# are re-checked against a stub that writes the target even on a bad schema
# and always exits 0 — guaranteed to violate every rejection property:
#   - exits non-zero      (stub exits 0)
#   - target NOT created  (stub creates it)
#   - no temp files       (stub leaves the target in an otherwise empty dir)
#   - content untouched   (stub clobbers the old content)
# The two properties the stub cannot violate — the old file still EXISTS and
# still has mode 600 (its plain printf leaves both intact) — are honest
# greens and reported inj n/a; the real preservation property is enforced by
# the byte-for-byte check just above.
#
# Verdict, INVERTED and scored SEPARATELY from the main pass/fail counters:
#   inj ok    = the check fired on the broken stub — a detection. Counted in
#               inject_ok only; NEVER into pass/fail.
#   inj MISS  = the check stayed green while the stub violated its property —
#               the check is vacuous. Counted in inject_miss, and the whole
#               script exits non-zero.
#   inj n/a   = property not violated by this stub (honest green).
# An aborted loader is a harness failure, not a detection: it is a MISS so
# the injection pass cannot "succeed" because the stub never ran.
echo "failure injection (REDESIGN.md §3.3):"
echo "  rejection suite against a stub that writes even on a bad schema:"
echo "  'inj ok' = caught; 'inj MISS' = stayed green while the stub violated it (vacuous); 'inj n/a' = not violated by the stub"
inject_ok=0; inject_na=0; inject_miss=0
inj_ok()   { printf '  inj ok    %s\n' "$1"; inject_ok=$((inject_ok + 1)); }
inj_na()   { printf '  inj n/a   %s\n' "$1"; inject_na=$((inject_na + 1)); }
inj_miss() { printf '  inj MISS  %s\n' "$1"; inject_miss=$((inject_miss + 1)); }

# The stub never exits non-zero, so the real expect_nonzero fires whenever
# it ran at all; a missing loader means the stub never ran — not a catch.
expect_inj_nonzero() {
    if [[ "$MISSING" -eq 1 ]]; then inj_miss "$1 (loader aborted — stub never ran)"
    elif [[ "$RC" -eq 0 ]]; then inj_ok "$1 (stub exited 0, check demanded non-zero)"
    else inj_miss "$1 (stub exited $RC — injection not set up)"; fi
}

# The stub always writes the target, so the real expect_absent fires.
expect_inj_absent() {
    if [[ -e "$2" ]]; then inj_ok "$1 (stub created it, check demanded absence)"
    else inj_miss "$1 (stub never created it — injection not set up)"; fi
}

# The stub leaves the target behind, so the real expect_dir_clean fires
# (with no allowed names, a non-empty dir is flagged).
expect_inj_dir_empty() {
    local dir="$2" entries="" f
    while IFS= read -r f; do [[ -n "$f" ]] && entries="${entries} $f"; done < <(ls -A "$dir" 2>/dev/null)
    if [[ -n "$entries" ]]; then inj_ok "$1 (stub left:$entries, check demanded an empty dir)"
    else inj_miss "$1 (stub left nothing — injection not set up)"; fi
}

# The stub replaces the old content, so the byte-for-byte check fires.
expect_inj_content_untouched() {
    local dest="$2"
    if [[ "$(cksum "$dest" 2>/dev/null)" == "$3" ]]; then
        inj_miss "$1 (old content survived the stub — injection not set up)"
    else
        inj_ok "$1 (stub clobbered old content, check demanded byte-identical)"
    fi
}

inject_case() {  # <label> <json> — stub writes, so every rejection must fire
    local label="$1" json="$2" cdir dest
    cdir="$SANDBOX/i-${label//[^a-z0-9]/-}"; rm -rf "$cdir"; mkdir -p "$cdir"; dest="$cdir/state.json"
    install_via "$SANDBOX/pool-tunnel-lib-broken.sh" "$json" "$dest"
    expect_inj_nonzero "$label exits non-zero"
    expect_inj_absent "$label: target must not be created" "$dest"
    expect_inj_dir_empty "$label: no temp files" "$cdir"
}

run_injection_checks() {
    local cdir dest before
    inject_case "schema 2" "$SCHEMA2"
    inject_case "schema 99" "$SCHEMA99"
    inject_case "missing schema" "$NO_SCHEMA"
    inject_case "not JSON" "$NOT_JSON"
    inject_case "empty string" "$EMPTY"

    cdir="$SANDBOX/i-atomic"; rm -rf "$cdir"; mkdir -p "$cdir"; dest="$cdir/state.json"
    printf 'OLD CONTENT, MUST SURVIVE\n' > "$dest"; chmod 600 "$dest"
    before="$(cksum "$dest")"
    install_via "$SANDBOX/pool-tunnel-lib-broken.sh" "$SCHEMA2" "$dest"
    expect_inj_nonzero "atomicity: rejected write exits non-zero"
    if [[ -e "$dest" ]]; then
        inj_na "atomicity: old file still there (presence survives the stub's overwrite — covered by the byte-for-byte check below)"
    else
        inj_miss "atomicity: old file vanished — injection not set up"
    fi
    expect_inj_content_untouched "atomicity: old content byte-for-byte untouched" "$dest" "$before"
    if [[ "$(mode_of "$dest")" == "600" ]]; then
        inj_na "atomicity: old mode still 600 (printf preserves it — property not violated by the stub)"
    else
        inj_ok "atomicity: stub changed the mode, check demanded 600"
    fi
    expect_inj_dir_empty "atomicity: no temp files" "$cdir"
}

run_injection_checks

if [[ "$inject_miss" -eq 0 ]]; then
    ok "failure injection: all ${inject_ok} rejectable checks fired on the broken stub"
else
    bad "failure injection: ${inject_miss} check(s) stayed green on the broken stub — rejection suite is vacuous (${inject_ok} fired)"
fi

echo
if [[ "$fail" -eq 0 && "$inject_miss" -eq 0 ]]; then
    echo "test-install-state-cache: ${pass} passed (failure injection: ${inject_ok}/${inject_ok} detected, ${inject_na} n/a)"
else
    echo "test-install-state-cache: ${fail} FAILED, ${pass} passed (failure injection: ${inject_miss} NOT detected)"
fi
exit "$fail"
