#!/usr/bin/env bash
# Tests for scripts/lib/state.sh — pure function tests, no network.
# Contract: docs/STATE_CONTRACT.md §2. The assertions below test the contract,
# not the implementation.
# Run: scripts/tests/test-state.sh
#
# Failure injection (REDESIGN.md §3.3, mandatory): the four violation cases
# below exist so that an always-accepting state_validate shows up as FAILs.
# To see that on demand, run this file against a stub state.sh whose
# state_validate is `return 0`; every "rejects ..." line must go red.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

if [[ -f scripts/lib/state.sh ]]; then
    # shellcheck source=../lib/state.sh
    source scripts/lib/state.sh
else
    echo "test-state: scripts/lib/state.sh is missing; every case below will FAIL" >&2
fi

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

OUT=""; ERR=""; RC=0; MISSING=0

# run <command...> — capture stdout, stderr and exit code, separately.
# An undefined function gets sentinels (MISSING=1, RC=127) so that
# "prints nothing" / "exits non-zero" assertions cannot pass by accident
# while state.sh is absent or incomplete.
run() {
    if declare -F "$1" >/dev/null 2>&1; then
        local tmpdir errfile
        tmpdir="${TMPDIR:-/tmp}"; tmpdir="${tmpdir%/}"
        errfile="$(mktemp "${tmpdir}/test-state.XXXXXX")"
        OUT="$("$@" 2>"$errfile")"; RC=$?
        ERR="$(cat "$errfile")"; rm -f "$errfile"
        MISSING=0
    else
        OUT="<undefined function: $1>"; ERR=""; RC=127; MISSING=1
    fi
}

# expect_eq <label> <expected> <got>
expect_eq() {
    if [[ "$3" == "$2" ]]; then ok "$1"
    else bad "$1 (expected [$2], got [${3:-<empty>}])"; fi
}

# expect_rc <label> <expected>
expect_rc() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function undefined — is state.sh present?)"
    elif [[ "$RC" -eq "$2" ]]; then
        ok "$1"
    else
        bad "$1 (expected exit $2, got $RC; stderr: ${ERR:-<empty>})"
    fi
}

# expect_reject <label> — a violation must exit non-zero AND say why on
# stderr. This is the assertion an always-accepting validate cannot satisfy,
# and it must not pass just because the function is undefined.
expect_reject() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function undefined — is state.sh present?)"
    elif [[ "$RC" -eq 0 ]]; then
        bad "$1 (exit 0, should have been rejected)"
    elif [[ -z "$ERR" ]]; then
        bad "$1 (exit $RC but nothing on stderr; contract says 'stderr 說明')"
    else
        ok "$1"
    fi
}

# expect_jq <label> <jq-expr> — expr must be true for the captured output
expect_jq() {
    if jq -e "$2" >/dev/null 2>&1 <<<"$OUT"; then ok "$1"
    else bad "$1 (jq [$2] was false on [${OUT:-<empty>}])"; fi
}

# expect_contains <label> <substring>
expect_contains() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function undefined — is state.sh present?)"
    elif [[ "$OUT" == *"$2"* ]]; then ok "$1"
    else bad "$1 (expected to contain [$2], got [${OUT:-<empty>}])"; fi
}

# expect_not_contains <label> <substring>
expect_not_contains() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function undefined — is state.sh present?)"
    elif [[ "$OUT" == *"$2"* ]]; then
        bad "$1 (contains [$2]: ${OUT:-<empty>})"
    else
        ok "$1"
    fi
}

# expect_no_secrets <label> — invariant 1: no key or token values, ever
expect_no_secrets() {
    if [[ "$MISSING" -eq 1 ]]; then
        bad "$1 (function undefined — is state.sh present?)"
        return
    fi
    local pat found=""
    for pat in 'BEGIN OPENSSH PRIVATE KEY' 'ghp_' 'ghu_'; do
        [[ "$OUT" == *"$pat"* ]] && found="$pat"
    done
    if [[ -z "$found" ]]; then ok "$1"
    else bad "$1 (found secret pattern [$found])"; fi
}

# VALID_STATE is written out by hand from the contract example, so the
# validate cases do not depend on state_build being correct.
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

# NODES_IN deliberately uses the var spelling (fh_proxy) for one node:
# state_build is the layer that reads GitHub vars, so the underscore-to-
# hyphen conversion (§2, invariant 2) is its job.
NODES_IN='{"gateway":{"name":"gateway","role":"gateway","ip":"172.104.114.31","key_secret":"SSH_KEY_ACTIONS"},"fh_proxy":{"name":"fh-proxy","role":"provider","key_secret":"SSH_KEY_PROXY"},"fh-l":{"name":"fh-l","role":"provider"}}'
WORKERS_IN='[{"port":2300,"provider":"fh-l","image":"default","container":"mlp-fh-l-default-34822789603","created_at":"2026-09-14T08:26:00Z"},{"port":2301,"provider":"fh-proxy","image":"base","container":"mlp-fh-proxy-base-456","created_at":"2026-09-14T09:00:00Z"}]'

echo "state_next_serial:"
run state_next_serial ""
expect_eq "empty input -> 1" "1" "$OUT"

run state_next_serial '{"schema":1,"serial":11}'
expect_eq "existing serial 11 -> 12" "12" "$OUT"

run state_next_serial "$VALID_STATE"
expect_eq "serial 12 inside a full state -> 13" "13" "$OUT"

run state_next_serial 'not-json{'
expect_eq "invalid JSON -> 1 (regenerate from scratch)" "1" "$OUT"

echo "state_build:"
run state_build 12 "rotate-gateway#34836287173" "$NODES_IN" "$WORKERS_IN"
expect_rc "build exits 0" 0
expect_jq "output is parseable JSON" '.'
expect_jq "schema is 1" '.schema == 1'
expect_jq "serial is the one passed in" '.serial == 12'
expect_jq "source is the one passed in" '.source == "rotate-gateway#34836287173"'
expect_jq "written_at is RFC3339 UTC" '((.written_at | fromdateiso8601) as $t | $t > 0)'
expect_jq "nodes keys are hyphenated" '.nodes | has("fh-proxy") and has("fh-l") and has("gateway")'
expect_jq "nodes has no underscore keys" '[.nodes | keys[] | select(test("_"))] | length == 0'
expect_jq "node payload passes through untouched" '.nodes.gateway.ip == "172.104.114.31" and .nodes["fh-proxy"].role == "provider"'
expect_eq "workers pass through untouched" "$(jq -S -c . <<<"$WORKERS_IN")" "$(jq -S -c '.workers' <<<"$OUT" 2>/dev/null)"
expect_no_secrets "build output carries no secret values"

run state_build 1 "create-worker#1" '{"gateway":{"role":"gateway"}}' '[]'
expect_rc "build with empty ledger exits 0" 0
expect_jq "empty ledger is [] in the output" '.workers == []'

echo "state_validate:"
run state_validate "$VALID_STATE"
expect_rc "valid state is accepted" 0

run state_build 7 "delete-worker#1" "$NODES_IN" '[]'
run state_validate "$OUT"
expect_rc "state_build output passes state_validate" 0

# One violation per case. Each is something an always-accepting validate
# would wave through, so each has to go red on such a stub.
run state_validate "$(jq -c '.schema = 2' <<<"$VALID_STATE")"
expect_reject "rejects schema 2"

run state_validate "$(jq -c '.nodes.fh_proxy = .nodes["fh-proxy"] | del(.nodes["fh-proxy"])' <<<"$VALID_STATE")"
expect_reject "rejects underscore node key fh_proxy"

run state_validate "$(jq -c '.nodes.gateway.host_key = "-----BEGIN OPENSSH PRIVATE KEY-----\nMIIEfake"' <<<"$VALID_STATE")"
expect_reject "rejects an embedded private key"

run state_validate "$(jq -c '.nodes.gateway.gh_token = "ghp_0123456789abcdefghijklmnopqrstuvwxyz"' <<<"$VALID_STATE")"
expect_reject "rejects a ghp_ token"

run state_validate "$(jq -c '.nodes["fh-l"].gh_token = "ghu_0123456789abcdefghijklmnopqrstuvwxyz"' <<<"$VALID_STATE")"
expect_reject "rejects a ghu_ token"

run state_validate 'not-json{'
expect_reject "rejects invalid JSON"

echo "state_install_cmd:"
run state_install_cmd "/tmp/state.json.new"
expect_rc "install_cmd exits 0" 0
expect_contains "caller-supplied path is honored, not rewritten" '/tmp/state.json.new'
expect_not_contains "install command does not mention \$HOME" '$HOME'
# A command that writes into the reader's home directory can look fine to
# every other check here, so the ~ case must be tested too.
expect_not_contains "install command does not mention ~" '~'

run state_install_cmd
expect_rc "install_cmd with no arg exits 0" 0
expect_contains "no-arg default targets /var/lib/mylinuxpool" '/var/lib/mylinuxpool/state.json'

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-state: ${pass} passed"
else
    echo "test-state: ${fail} FAILED, ${pass} passed"
fi
exit "$fail"
