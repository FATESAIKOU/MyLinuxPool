#!/usr/bin/env bash
# Tests for shared-configs/ssh-admin/install.sh — no network, no real HOME,
# no real ~/.ssh. Every run is confined to a mktemp directory and the child
# gets HOME pointed at it as well, so a buggy installer still cannot reach
# the real home.
#
# Spec: docs/REDESIGN.md N2 / A4 — the Gateway must not hold an unused
# id_rsa; this unit installs authorized_keys only; files/*.crypted stay in
# the repo but are no longer deployed; --check reports a leftover id_rsa as
# WARN drift; install.sh must never delete an existing id_rsa.
# Run: scripts/tests/test-ssh-admin-install.sh
#
# Failure injection (REDESIGN.md §3.3, mandatory): the suite is built so an
# installer that produces id_rsa turns the "id_rsa was NOT created" checks
# red. To reproduce, point INSTALL_SH at a stub that copies a fake key in
# (FILE_CRYPTO_KEY can be any value; the stub ignores it):
#   FILE_CRYPTO_KEY=demo INSTALL_SH=/tmp/id-rsa-producing-stub.sh \
#       scripts/tests/test-ssh-admin-install.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

INSTALL_SH="${INSTALL_SH:-shared-configs/ssh-admin/install.sh}"
if [[ ! -x "$INSTALL_SH" ]]; then
    echo "test-ssh-admin-install: $INSTALL_SH is missing or not executable; install-dependent cases will FAIL" >&2
fi

pass=0; fail=0; skipped=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
skip() { printf '  skip  %s\n' "$1"; skipped=$((skipped + 1)); }

OUT=""; RC=0

run() { OUT="$("$@" 2>&1)"; RC=$?; }

expect_rc() {
    if [[ "$RC" -eq "$2" ]]; then ok "$1"
    else bad "$1 (expected exit $2, got $RC; output: ${OUT:-<empty>})"; fi
}

expect_exists() {
    if [[ -e "$2" ]]; then ok "$1"; else bad "$1 (missing: $2)"; fi
}

expect_absent() {
    if [[ -e "$2" ]]; then bad "$1 (unexpectedly exists: $2)"; else ok "$1"; fi
}

# A drift notice can be worded two ways: either the literal word "drift",
# or a WARN that names id_rsa. Anything weaker (bare "drift", bare "WARN")
# is caught by the clean-home negative check below.
DRIFT_RE='drift|warn.*id_rsa|id_rsa.*warn'

expect_output_matches() {
    if grep -Eqi "$2" <<<"$OUT"; then ok "$1"
    else bad "$1 (no /$2/ in output: ${OUT:-<empty>})"; fi
}

expect_not_output_matches() {
    if grep -Eqi "$2" <<<"$OUT"; then bad "$1 (matched /$2/ in output: ${OUT:-<empty>})"
    else ok "$1"; fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}"/test-ssh-admin.XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

# The key comes from the environment only; no key value is written here.
# install.sh refuses to run without it (needs_key unit), so without it every
# install-dependent case is skipped with an explanation — never auto-passed.
KEY_SET=0
if [[ -n "${FILE_CRYPTO_KEY:-}" ]]; then
    KEY_SET=1
else
    echo "note: FILE_CRYPTO_KEY is unset — install.sh needs --key for its .crypted files," >&2
    echo "note: so every install-dependent case below is SKIPPED (the run still exits 0)" >&2
fi

# install <home> [--check] — HOME is overridden for the child too.
install() {
    local home="$1" mode="${2:-}"
    local -a args=(--home "$home")
    [[ -n "$mode" ]] && args+=("$mode")
    [[ "$KEY_SET" -eq 1 ]] && args=(--key "$FILE_CRYPTO_KEY" "${args[@]}")
    run env HOME="$home" bash "$INSTALL_SH" "${args[@]}"
}

echo "repo still ships the crypted files (kept, just not deployed):"
expect_exists "id_rsa.crypted is kept" "shared-configs/ssh-admin/files/id_rsa.crypted"
expect_exists "id_rsa.pub.crypted is kept" "shared-configs/ssh-admin/files/id_rsa.pub.crypted"
expect_exists "authorized_keys.crypted is present" "shared-configs/ssh-admin/files/authorized_keys.crypted"

CLEAN="$TMPROOT/clean"
PRE="$TMPROOT/pre-existing"

echo "install into a clean fake HOME:"
if [[ "$KEY_SET" -eq 1 ]]; then
    mkdir -p "$CLEAN"
    install "$CLEAN"
    expect_rc "install exits 0" 0
    expect_exists "authorized_keys is created" "$CLEAN/.ssh/authorized_keys"
    # The point of A4: this unit no longer ships an identity key.
    expect_absent "id_rsa is NOT created" "$CLEAN/.ssh/id_rsa"
    expect_absent "id_rsa.pub is NOT created" "$CLEAN/.ssh/id_rsa.pub"
else
    skip "install exits 0 (FILE_CRYPTO_KEY unset)"
    skip "authorized_keys is created (FILE_CRYPTO_KEY unset)"
    skip "id_rsa is NOT created (FILE_CRYPTO_KEY unset)"
    skip "id_rsa.pub is NOT created (FILE_CRYPTO_KEY unset)"
fi

echo "install over a machine that already has id_rsa:"
if [[ "$KEY_SET" -eq 1 ]]; then
    mkdir -p "$PRE/.ssh"
    printf 'fake pre-existing key, must survive the install\n' > "$PRE/.ssh/id_rsa"
    before="$(cksum "$PRE/.ssh/id_rsa")"
    install "$PRE"
    expect_rc "install exits 0" 0
    expect_exists "install does not delete the existing id_rsa" "$PRE/.ssh/id_rsa"
    after="$(cksum "$PRE/.ssh/id_rsa" 2>/dev/null)"
    if [[ "$before" == "$after" ]]; then
        ok "existing id_rsa is left byte-for-byte untouched"
    else
        bad "existing id_rsa changed (before [$before], after [${after:-<missing>}])"
    fi
else
    skip "install exits 0 (FILE_CRYPTO_KEY unset)"
    skip "install does not delete the existing id_rsa (FILE_CRYPTO_KEY unset)"
    skip "existing id_rsa is left byte-for-byte untouched (FILE_CRYPTO_KEY unset)"
fi

echo "--check with a leftover id_rsa:"
if [[ "$KEY_SET" -eq 1 ]]; then
    install "$PRE" --check
    expect_output_matches "--check reports the leftover id_rsa as drift (WARN)" "$DRIFT_RE"
    expect_exists "id_rsa survives --check (no cleanup deletion)" "$PRE/.ssh/id_rsa"
    # "WARN, not a failure": drift alone must not make --check reject.
    expect_rc "--check drift is a warning, not a failure (exit 0)" 0

    # Negative control: a --check that always prints the drift notice fails.
    install "$CLEAN" --check
    expect_not_output_matches "no drift notice on a clean home" "$DRIFT_RE"
    expect_rc "--check on a fully installed clean home exits 0" 0
else
    skip "--check reports the leftover id_rsa as drift (FILE_CRYPTO_KEY unset)"
    skip "id_rsa survives --check (FILE_CRYPTO_KEY unset)"
    skip "--check drift is a warning, not a failure (FILE_CRYPTO_KEY unset)"
    skip "no drift notice on a clean home (FILE_CRYPTO_KEY unset)"
    skip "--check on a fully installed clean home exits 0 (FILE_CRYPTO_KEY unset)"
fi

echo
if [[ "$fail" -eq 0 ]]; then
    if [[ "$skipped" -gt 0 ]]; then
        echo "test-ssh-admin-install: ${pass} passed, ${skipped} SKIPPED (FILE_CRYPTO_KEY unset)"
    else
        echo "test-ssh-admin-install: ${pass} passed"
    fi
else
    echo "test-ssh-admin-install: ${fail} FAILED, ${pass} passed, ${skipped} skipped"
fi
exit "$fail"
