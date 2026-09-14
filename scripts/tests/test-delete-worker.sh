#!/usr/bin/env bash
# Tests for scripts/delete-worker.sh — pure function tests, no network.
# Run: scripts/tests/test-delete-worker.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# shellcheck source=../delete-worker.sh
source scripts/delete-worker.sh

CLAIMS='[{"port":2300,"provider":"fh-l","container":"mlp-fh-l-base-34797544790"},
         {"port":2301,"provider":"fh-proxy","container":"mlp-fh-proxy-default-34806917738"}]'

pass=0; fail=0

# expect_port <label> <expected-port|""> <port_in> <name_in>
expect_port() {
    local got
    got="$(delete_worker_find_claim "$CLAIMS" "$3" "$4" 2>/dev/null | sed -n 's/^port=//p')"
    if [[ "$got" == "$2" ]]; then
        printf '  ok    %s\n' "$1"; pass=$((pass + 1))
    else
        printf '  FAIL  %s (expected %s, got %s)\n' "$1" "${2:-<none>}" "${got:-<none>}"
        fail=$((fail + 1))
    fi
}

# expect_field <label> <field> <expected> <port_in> <name_in>
expect_field() {
    local got
    got="$(delete_worker_find_claim "$CLAIMS" "$4" "$5" 2>/dev/null | sed -n "s/^$2=//p")"
    if [[ "$got" == "$3" ]]; then
        printf '  ok    %s\n' "$1"; pass=$((pass + 1))
    else
        printf '  FAIL  %s (expected %s, got %s)\n' "$1" "$3" "${got:-<none>}"
        fail=$((fail + 1))
    fi
}

# expect_reject <label> <port_in> <name_in>
expect_reject() {
    if delete_worker_validate_inputs "$2" "$3" >/dev/null 2>&1; then
        printf '  FAIL  %s (accepted, should have been rejected)\n' "$1"; fail=$((fail + 1))
    else
        printf '  ok    %s\n' "$1"; pass=$((pass + 1))
    fi
}

echo "find_claim:"
expect_port  "by port"                                2300 2300 ""
expect_port  "bare name (what create-worker reports)" 2301 ""   "fh-proxy-default-34806917738"
# The regression this file exists for: `mlp ls` and docker show the
# container name, so that spelling has to resolve too.
expect_port  "container name (what mlp ls shows)"     2301 ""   "mlp-fh-proxy-default-34806917738"
expect_port  "unknown name resolves to nothing"       ""   ""   "no-such-worker"
expect_port  "unknown port resolves to nothing"       ""   9999 ""
expect_field "provider comes back with the port" provider fh-l 2300 ""

echo "validate_inputs:"
expect_reject "neither port nor name"  ""      ""
expect_reject "non-numeric port"       "22a"   ""
expect_reject "name with a slash"      ""      "a/b"

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-delete-worker: ${pass} passed"
else
    echo "test-delete-worker: ${fail} FAILED, ${pass} passed"
fi
exit "$fail"
