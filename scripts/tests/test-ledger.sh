#!/usr/bin/env bash
# Tests for scripts/lib/ledger.sh — pure function tests, no network.
# Contract: docs/STATE_CONTRACT.md §1. The assertions below test the contract,
# not the implementation.
# Run: scripts/tests/test-ledger.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

if [[ -f scripts/lib/ledger.sh ]]; then
    # shellcheck source=../lib/ledger.sh
    source scripts/lib/ledger.sh
else
    echo "test-ledger: scripts/lib/ledger.sh is missing; every case below will FAIL" >&2
fi

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

OUT=""; RC=0; MISSING=0

# run <command...> — capture stdout and exit code, drop stderr.
# An undefined function gets a visible sentinel so that "prints nothing"
# assertions cannot pass by accident when ledger.sh is missing.
run() {
    if declare -F "$1" >/dev/null 2>&1; then
        OUT="$("$@" 2>/dev/null)"; RC=$?; MISSING=0
    else
        OUT="<undefined function: $1>"; RC=127; MISSING=1
    fi
}

# expect_eq <label> <expected> <got>
expect_eq() {
    if [[ "$3" == "$2" ]]; then ok "$1"
    else bad "$1 (expected [$2], got [${3:-<empty>}])"; fi
}

# expect_json_eq <label> <expected> <got> — key order and whitespace ignored
expect_json_eq() {
    local want got
    want="$(jq -S -c . <<<"$2" 2>/dev/null)"
    got="$(jq -S -c . <<<"$3" 2>/dev/null)"
    if [[ -n "$want" && -n "$got" && "$got" == "$want" ]]; then ok "$1"
    else bad "$1 (expected [$2], got [${3:-<empty>}])"; fi
}

# expect_jq <label> <jq-expr> — expr must be true for the captured output
expect_jq() {
    if jq -e "$2" >/dev/null 2>&1 <<<"$OUT"; then ok "$1"
    else bad "$1 (jq [$2] was false on [${OUT:-<empty>}])"; fi
}

# expect_rc <label> <expected>
expect_rc() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function undefined — is ledger.sh present?)"
    elif [[ "$RC" -eq "$2" ]]; then
        ok "$1"
    else
        bad "$1 (expected exit $2, got $RC)"
    fi
}

# expect_nonzero <label> — a rejection must exit non-zero, via a real function
expect_nonzero() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function undefined — is ledger.sh present?)"
    elif [[ "$RC" -ne 0 ]]; then
        ok "$1"
    else
        bad "$1 (exit 0, should be non-zero)"
    fi
}

REC_2300='{"port":2300,"provider":"fh-l","image":"default","container":"mlp-fh-l-default-123","created_at":"2026-09-14T08:26:00Z"}'
REC_2301='{"port":2301,"provider":"fh-proxy","image":"base","container":"mlp-fh-proxy-base-456","created_at":"2026-09-14T09:00:00Z"}'
REC_2300_REPLACED='{"port":2300,"provider":"fh-l","image":"base","container":"mlp-fh-l-base-999","created_at":"2026-09-14T10:00:00Z"}'
REC_2302='{"port":2302,"provider":"fh-l","image":"default","container":"mlp-fh-l-default-777","created_at":"2026-09-14T11:00:00Z"}'
REC_2303='{"port":2303,"provider":"fh-l","image":"default","container":"mlp-fh-l-default-888","created_at":"2026-09-14T11:00:00Z"}'
FIXTURE="[$REC_2300,$REC_2301]"
UNSORTED="[$REC_2301,$REC_2300]"

echo "ledger_add:"
run ledger_add '[]' 2301 fh-proxy base mlp-fh-proxy-base-456 2026-09-14T09:00:00Z
expect_rc "add to empty ledger exits 0" 0
expect_json_eq "add to empty ledger stores the record" "$REC_2301" "$OUT"
first_add="$OUT"

run ledger_add "$first_add" 2300 fh-l default mlp-fh-l-default-123 2026-09-14T08:26:00Z
expect_rc "adding a lower port exits 0" 0
expect_jq "ports come back ascending" '[.[].port] == [2300, 2301]'
expect_json_eq "both records present, unchanged" "$FIXTURE" "$OUT"
two_adds="$OUT"

run ledger_add "$two_adds" 2300 fh-l base mlp-fh-l-base-999 2026-09-14T10:00:00Z
expect_rc "adding over an existing port exits 0" 0
expect_jq "same port replaces instead of duplicating" '([.[].port] | length) == 2 and ([.[].port] | unique | length) == 2'
expect_json_eq "replaced record carries the new call's fields, other record untouched" "[$REC_2300_REPLACED,$REC_2301]" "$OUT"

echo "ledger_remove:"
run ledger_remove "$FIXTURE" 2300
expect_rc "remove an existing port exits 0" 0
expect_json_eq "remaining record is untouched" "[$REC_2301]" "$OUT"

run ledger_remove "$FIXTURE" 9999
expect_rc "remove a missing port exits 0" 0
expect_json_eq "remove a missing port prints the ledger unchanged" "$FIXTURE" "$OUT"

run ledger_remove '[]' 2300
expect_rc "remove from [] exits 0" 0
expect_json_eq "remove from [] prints []" '[]' "$OUT"

run ledger_remove '' 2300
expect_rc "remove from empty string exits 0" 0
expect_json_eq "empty string behaves as []" '[]' "$OUT"

echo "ledger_find:"
run ledger_find "$FIXTURE" 2300
expect_rc "find by port exits 0" 0
expect_json_eq "find by port returns the whole record" "$REC_2300" "$OUT"

run ledger_find "$FIXTURE" mlp-fh-l-default-123
expect_rc "find by full container name exits 0" 0
expect_json_eq "full container name resolves" "$REC_2300" "$OUT"

run ledger_find "$FIXTURE" fh-l-default-123
expect_rc "find by bare container name exits 0" 0
expect_json_eq "bare container name resolves to the same record" "$REC_2300" "$OUT"

run ledger_find "$FIXTURE" fh-proxy-base-456
expect_json_eq "bare name of the second record resolves to it, not to the first entry" "$REC_2301" "$OUT"

run ledger_find "$FIXTURE" no-such-worker
expect_eq "unknown name prints nothing" "" "$OUT"
expect_nonzero "unknown name exits non-zero"

run ledger_find "$FIXTURE" 9999
expect_eq "unknown port prints nothing" "" "$OUT"
expect_nonzero "unknown port exits non-zero"

run ledger_find '[]' 2300
expect_eq "find in [] prints nothing" "" "$OUT"
expect_nonzero "find in [] exits non-zero"

run ledger_find '' 2300
expect_eq "find in empty string prints nothing" "" "$OUT"
expect_nonzero "find in empty string exits non-zero"

run ledger_find 'not-json{' 2300
expect_eq "find in invalid JSON prints nothing" "" "$OUT"
expect_nonzero "find in invalid JSON exits non-zero"

echo "ledger_ports:"
run ledger_ports "$FIXTURE"
expect_rc "ledger_ports exits 0" 0
expect_eq "one port per line, ascending" $'2300\n2301' "$OUT"

run ledger_ports "$UNSORTED"
expect_rc "out-of-order input exits 0" 0
expect_eq "out-of-order input still prints ascending" $'2300\n2301' "$OUT"

run ledger_ports '[]'
expect_rc "ledger_ports [] exits 0" 0
expect_eq "ledger_ports [] prints nothing" "" "$OUT"

run ledger_ports ''
expect_rc "ledger_ports empty string exits 0" 0
expect_eq "ledger_ports empty string prints nothing" "" "$OUT"

run ledger_ports 'not-json{'
expect_rc "ledger_ports invalid JSON exits 0" 0
expect_eq "ledger_ports invalid JSON prints nothing" "" "$OUT"

echo "empty / invalid input:"
run ledger_add '' 2302 fh-l default mlp-fh-l-default-777 2026-09-14T11:00:00Z
expect_rc "add to empty string exits 0" 0
expect_json_eq "empty string is treated as [] before adding" "$REC_2302" "$OUT"

run ledger_add 'not-json{' 2303 fh-l default mlp-fh-l-default-888 2026-09-14T11:00:00Z
expect_rc "add to invalid JSON exits 0" 0
expect_json_eq "invalid JSON is treated as [] before adding" "$REC_2303" "$OUT"

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-ledger: ${pass} passed"
else
    echo "test-ledger: ${fail} FAILED, ${pass} passed"
fi
exit "$fail"
