#!/usr/bin/env bash
# test-authkeys.sh — tests for scripts/lib/authkeys.sh (task L).
# Spec: CONTRACT.md ("CLIENT_* 與授權清單組裝"). The assertions below come
# from that contract, not from the implementation.
#
# Contract points that shape the design here:
#   - assemble must fail atomically: non-zero AND empty stdout (a half
#     list that exits non-zero is still a half list to a caller that does
#     not check the code — every negative case asserts BOTH).
#   - output must be byte-stable (install.sh --check compares bytes), so
#     the same content fed in a different order must produce identical
#     bytes.
#   - required_pubkey (the Actions key) must be in the result, hard stop.
#
# Failure injection (REDESIGN.md §3.3): every assertion below is paired
# with a mutant in the demo at the bottom of the task report — a validator
# that accepts everything reddens 3/4/5, a non-atomic assembler reddens
# 7/8/11, a no-dedupe assembler reddens 9, a no-sort assembler reddens 10,
# a passthrough var_name reddens 13/14. AUTHKEYS_LIB may point the suite at
# a mutant copy; by default it tests the real file.
#
# Run: scripts/tests/test-authkeys.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

AUTHKEYS_LIB="${AUTHKEYS_LIB:-scripts/lib/authkeys.sh}"
if [[ -f "$AUTHKEYS_LIB" ]]; then
    # shellcheck source=../lib/authkeys.sh
    source "$AUTHKEYS_LIB"
else
    echo "test-authkeys: ${AUTHKEYS_LIB} is missing; every case below will FAIL" >&2
fi

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

ERRFILE="$(mktemp "${TMPDIR:-/tmp}/test-authkeys.err.XXXXXX")"
trap 'rm -f "$ERRFILE"' EXIT INT TERM

OUT=""; ERR=""; RC=0; MISSING=0

# run <fn> [args...] — stdout, stderr and exit code captured separately.
# stdin is /dev/null so nothing can hang. An undefined function gets a
# non-empty sentinel so that "stdout is empty" cannot pass by accident,
# and MISSING=1 so that "non-zero exit" cannot pass vacuously either.
run() {
    if declare -F "$1" >/dev/null 2>&1; then
        OUT="$("$@" </dev/null 2>"$ERRFILE")"; RC=$?
        ERR="$(cat "$ERRFILE")"; MISSING=0
    else
        OUT="<undefined function: $1>"; ERR=""; RC=127; MISSING=1
    fi
}

# Key lines are fake, but failure messages still avoid echoing them whole:
# the contract's habit rule is not to print key material in errors.
B1='AAAAC3NzaC1lZDI1NTE5AAAAIA1b2c3d4e5f6g7h8i9j0kLMNOPqRSTuvWXyz'
B2='AAAAB3NzaC1yc2EAAAADAQABAAABgQC7xYz1234567890abcdefGHIJKLmnopQRSTuvWXYZ'
B3='AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBExampleBlob'
LINE1="ssh-ed25519 $B1 kou@mac"
LINE2="ssh-rsa $B2 actions@github"
LINE3="ecdsa-sha2-nistp256 $B3 laptop@home"

sanitize() { printf '%s' "$1" | sed -e "s|$B1|<BLOB1>|g" -e "s|$B2|<BLOB2>|g" -e "s|$B3|<BLOB3>|g"; }

expect_rc() {
    local label="$1" want="$2"
    if [[ "$MISSING" -eq 1 ]]; then bad "${label} (function could not be loaded)"
    elif [[ "$RC" -eq "$want" ]]; then ok "${label}"
    else bad "${label} (expected exit ${want}, got ${RC}; stderr: $(sanitize "${ERR:-<empty>}"))"; fi
}

# expect_fail_empty <label> — the atomic-failure assertion: non-zero AND no
# stdout. Both halves are required; checking only the exit code is what a
# partial-output implementation would slip past.
expect_fail_empty() {
    local label="$1"
    if [[ "$MISSING" -eq 1 ]]; then bad "${label} (function could not be loaded)"; return; fi
    if [[ "$RC" -eq 0 ]]; then bad "${label} (exit 0, should be non-zero)"; return; fi
    if [[ -n "$OUT" ]]; then
        bad "${label} (exit ${RC} but stdout was NOT empty: $(sanitize "$(printf '%s' "$OUT" | head -c 120)")…)"
        return
    fi
    ok "${label}"
}

expect_out_eq() {
    local label="$1" want="$2"
    if [[ "$MISSING" -eq 1 ]]; then bad "${label} (function could not be loaded)"
    elif [[ "$OUT" == "$want" ]]; then ok "${label}"
    else bad "${label} (expected [$(sanitize "$want")], got [$(sanitize "${OUT:-<empty>}")])"; fi
}

expect_out_contains() {
    local label="$1" needle="$2"
    if [[ "$MISSING" -eq 1 ]]; then bad "${label} (function could not be loaded)"
    elif [[ "$OUT" == *"$needle"* ]]; then ok "${label}"
    else bad "${label} (output does not contain [$(sanitize "$needle")])"; fi
}

expect_lines() {
    local label="$1" want="$2" n
    if [[ "$MISSING" -eq 1 ]]; then bad "${label} (function could not be loaded)"; return; fi
    n="$(printf '%s\n' "$OUT" | grep -c . || true)"
    if [[ "$n" -eq "$want" ]]; then ok "${label}"
    else bad "${label} (expected ${want} line(s), got ${n}; output: $(sanitize "$(printf '%s' "$OUT" | head -c 160)")…)"; fi
}

# client_json <name> <public_key> — one CLIENT_* value object.
client_json() {
    jq -nc --arg n "$1" --arg k "$2" \
        '{name:$n, public_key:$k, added_at:"2026-09-16T12:00:00Z"}'
}

# clients <name> <key> [<name> <key> ...] — CLIENT_* values as a JSON array.
clients() {
    local out="[" sep="" e
    while [[ $# -ge 2 ]]; do
        e="$(client_json "$1" "$2")"; shift 2
        out="${out}${sep}${e}"; sep=","
    done
    printf '%s]' "$out"
}

echo "── authkeys_valid_pubkey ──"
run authkeys_valid_pubkey "ssh-ed25519 $B1 kou@mac"
expect_rc "1. ed25519 accepted" 0
run authkeys_valid_pubkey "ssh-rsa $B2 actions@github"
expect_rc "1. ssh-rsa accepted" 0
run authkeys_valid_pubkey "ecdsa-sha2-nistp256 $B3 laptop@home"
expect_rc "1. ecdsa-sha2-* accepted" 0

run authkeys_valid_pubkey "ssh-ed25519 $B1"
expect_rc "2. no comment is still valid" 0

run authkeys_valid_pubkey "ssh-dss $B1 kou@old"
expect_rc "3. ssh-dss rejected (type not in the allowed set)" 1
run authkeys_valid_pubkey "totally-bogus $B1 kou@x"
expect_rc "3. arbitrary type string rejected" 1

run authkeys_valid_pubkey "ssh-ed25519"
expect_rc "4. missing base64 field rejected" 1
run authkeys_valid_pubkey "ssh-ed25519 "
expect_rc "4. empty base64 field rejected" 1

# Two complete, individually-valid lines. The first line ends with a comment,
# so a naive "split on spaces" implementation would happily validate it and
# ignore the second: only an explicit multi-line check rejects this.
run authkeys_valid_pubkey "$(printf 'ssh-ed25519 %s kou@mac\nssh-rsa %s actions@github' "$B1" "$B2")"
expect_rc "5. multi-line input rejected" 1

echo "── authkeys_assemble ──"
ARR_TWO="$(clients "fatesaikou-mac" "ssh-ed25519 $B1 kou@mac" "github-actions" "ssh-rsa $B2 actions@github")"
run authkeys_assemble "$ARR_TWO" "ssh-rsa $B2"
expect_rc "6. normal two entries: exit 0" 0
expect_lines "6. normal two entries: two lines" 2
expect_out_contains "6. output contains the ed25519 line" "ssh-ed25519 $B1 kou@mac"
expect_out_contains "6. output contains the required (Actions) line" "ssh-rsa $B2 actions@github"

run authkeys_assemble '{}' "ssh-rsa $B2"
expect_fail_empty "7. object instead of array → non-zero and empty stdout"
run authkeys_assemble '"x"' "ssh-rsa $B2"
expect_fail_empty "7. JSON string instead of array → non-zero and empty stdout"
run authkeys_assemble 'null' "ssh-rsa $B2"
expect_fail_empty "7. null instead of array → non-zero and empty stdout"
run authkeys_assemble '{"message":"Not Found","documentation_url":"https://docs.github.com/rest"} ' "ssh-rsa $B2"
expect_fail_empty "7. gh-api 404 body → non-zero and empty stdout"

ARR_BADTYPE="$(clients "fatesaikou-mac" "ssh-ed25519 $B1 kou@mac" "broken" "ssh-dss $B3 broken@x")"
run authkeys_assemble "$ARR_BADTYPE" "ssh-ed25519 $B1"
expect_fail_empty "8. one bad public_key → whole batch fails, stdout empty (not a partial list)"
ARR_NOPUB="$(jq -nc --arg a "$(client_json fatesaikou-mac "ssh-ed25519 $B1")" --argjson n '{"name":"nokey","added_at":"2026-09-16T12:00:00Z"}' \
    '[$a] + [$n]')"
run authkeys_assemble "$ARR_NOPUB" "ssh-ed25519 $B1"
expect_fail_empty "8. an entry without public_key → non-zero and empty stdout"

ARR_DUP="$(clients "fatesaikou-mac" "ssh-ed25519 $B1 kou@mac" "fatesaikou-laptop" "ssh-ed25519 $B1 kou@laptop")"
run authkeys_assemble "$ARR_DUP" "ssh-ed25519 $B1"
expect_rc "9. duplicate material with different comments: exit 0" 0
expect_lines "9. duplicate material collapses to one line" 1
expect_out_eq "9. the first occurrence's line is the one kept" "ssh-ed25519 $B1 kou@mac"

ARR_ORD1="$(clients "fatesaikou-mac" "ssh-ed25519 $B1 kou@mac" "github-actions" "ssh-rsa $B2 actions@github")"
ARR_ORD2="$(clients "github-actions" "ssh-rsa $B2 actions@github" "fatesaikou-mac" "ssh-ed25519 $B1 kou@mac")"
run authkeys_assemble "$ARR_ORD1" "ssh-rsa $B2"; OUT_A="$OUT"; RC_A="$RC"
run authkeys_assemble "$ARR_ORD2" "ssh-rsa $B2"; OUT_B="$OUT"; RC_B="$RC"
if [[ "$MISSING" -eq 1 ]]; then
    bad "10. stable ordering: functions could not be loaded"
elif [[ "$RC_A" -ne 0 || "$RC_B" -ne 0 ]]; then
    bad "10. stable ordering: a valid assembly failed (rc ${RC_A}/${RC_B})"
elif [[ -z "$OUT_A" ]]; then
    bad "10. stable ordering: output was empty"
elif [[ "$OUT_A" == "$OUT_B" ]]; then
    ok "10. same content in a different order → byte-identical output"
else
    bad "10. stable ordering broken: output differs by input order ([$(sanitize "$OUT_A" | tr '\n' '|')] vs [$(sanitize "$OUT_B" | tr '\n' '|')])"
fi

ARR_ONE="$(clients "fatesaikou-mac" "ssh-ed25519 $B1 kou@mac")"
run authkeys_assemble "$ARR_ONE" "ssh-rsa $B2"
expect_fail_empty "11. required_pubkey absent → non-zero and empty stdout (lockout guard)"

run authkeys_assemble '[]' "ssh-rsa $B2"
expect_fail_empty "12. empty array → non-zero and empty stdout"

echo "── authkeys_var_name ──"
run authkeys_var_name "fatesaikou-mac"
expect_rc "13. valid name: exit 0" 0
expect_out_eq "13. fatesaikou-mac → CLIENT_FATESAIKOU_MAC" "CLIENT_FATESAIKOU_MAC"

run authkeys_var_name "has space"
expect_rc "14. name with a space rejected" 1
run authkeys_var_name "a/b"
expect_rc "14. name with a slash rejected" 1
run authkeys_var_name "a.b"
expect_rc "14. name with a dot rejected" 1

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -eq 0 ]]; then exit 0; fi
exit 1
