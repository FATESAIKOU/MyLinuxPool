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
#
# Key policy: FILE_CRYPTO_KEY comes from the environment only (never written
# here). Without it, every assertion that can only hold once install.sh can
# decrypt is SKIPPED with a reason — never auto-passed, never a fake FAIL.
# Assertions that need no decryption (repo files present, an existing id_rsa
# surviving every install/--check invocation, the drift notice) always run.
#
# Run: scripts/tests/test-ssh-admin-install.sh
#      FILE_CRYPTO_KEY=$(cat crypto_key) scripts/tests/test-ssh-admin-install.sh
#
# Failure injection (REDESIGN.md §3.3, mandatory): the suite is built so an
# installer that produces id_rsa turns the "id_rsa was NOT created" checks
# red, and one that deletes a pre-existing id_rsa turns the survival checks
# red. Reproduce with the stubs:
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
need_key() { skip "$1 (FILE_CRYPTO_KEY unset; cannot decrypt, so this cannot be verified)"; }

OUT=""; RC=0

# run <command...> — capture stdout+stderr and exit code. When KEY_IN is
# set, the child's stdin is a pipe carrying exactly that string (the
# production stdin route, RUNBOOK.md §9); otherwise stdin is /dev/null so
# a no-key run fails fast instead of hanging on a tty/pipe.
# A temp file carries the output instead of command substitution: bash 3.2
# (macOS) does not populate PIPESTATUS inside $(...), so the child's exit
# code would be lost — with a file, $? after the pipeline is the pipe's
# last command (tee/cat), not the child.
run() {
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/test-ssh-admin.XXXXXX")"
    if [[ -n "${KEY_IN:-}" ]]; then
        printf '%s' "$KEY_IN" | "$@" > "$tmp" 2>&1
        RC=${PIPESTATUS[1]}
    else
        "$@" </dev/null > "$tmp" 2>&1
        RC=$?
    fi
    OUT="$(cat "$tmp")"
    rm -f "$tmp"
}

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

# A drift notice can be worded two ways: the literal word "drift", or a WARN
# that names id_rsa. The clean-home negative control below catches a check
# that prints something weaker (or always prints it).
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

KEY_SET=0
if [[ -n "${FILE_CRYPTO_KEY:-}" ]]; then
    KEY_SET=1
else
    echo "note: FILE_CRYPTO_KEY is unset — decryption-dependent assertions are SKIPPED with a reason;" >&2
    echo "note: the no-key assertions still run. The run exits 0 if nothing genuinely fails." >&2
fi

# install <home> [--check] — HOME is overridden for the child too.
# Without a key the installer is expected to refuse; that refusal is itself
# useful, because it must not delete or modify anything on its way out.
# The key is fed on the child's stdin (the current production path,
# RUNBOOK.md §9) — never --key, which is the retired argv route this
# project is eliminating.
install() {
    local home="$1" mode="${2:-}"
    local -a args=(--home "$home")
    [[ -n "$mode" ]] && args+=("$mode")
    KEY_IN=""
    [[ "$KEY_SET" -eq 1 ]] && KEY_IN="$FILE_CRYPTO_KEY"
    run env HOME="$home" bash "$INSTALL_SH" "${args[@]}"
    KEY_IN=""
}

CLEAN="$TMPROOT/clean"
PRE="$TMPROOT/pre-existing"

echo "repo ships the crypted files (kept, just not deployed):"
expect_exists "id_rsa.crypted is kept" "shared-configs/ssh-admin/files/id_rsa.crypted"
expect_exists "authorized_keys.crypted is present" "shared-configs/ssh-admin/files/authorized_keys.crypted"

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
    need_key "install exits 0"
    need_key "authorized_keys is created"
    need_key "id_rsa is NOT created"
    need_key "id_rsa.pub is NOT created"
fi

# This section needs no key to be meaningful: whatever install does (with a
# key it must succeed; without one it must refuse), it must not remove or
# rewrite an id_rsa that was already there.
echo "install over a machine that already has id_rsa:"
mkdir -p "$PRE/.ssh"
# A REAL unrelated private key (not a text file): the drift check compares
# derived public halves, so a fake text file would never match and could
# not exercise either branch.
ssh-keygen -t ed25519 -N '' -C "machine-local@fwm" -f "$PRE/.ssh/id_rsa" -q >/dev/null 2>&1
before="$(cksum "$PRE/.ssh/id_rsa")"
install "$PRE"
if [[ "$KEY_SET" -eq 1 ]]; then
    expect_rc "install exits 0" 0
else
    skip "install exits 0 (FILE_CRYPTO_KEY unset)"
fi
expect_exists "install does not delete the existing id_rsa" "$PRE/.ssh/id_rsa"
after="$(cksum "$PRE/.ssh/id_rsa" 2>/dev/null)"
if [[ "$before" == "$after" ]]; then
    ok "existing id_rsa is left byte-for-byte untouched"
else
    bad "existing id_rsa changed (before [$before], after [${after:-<missing>}])"
fi

# --check with an UNRELATED id_rsa must be silent about it (task H: only
# the retired identity key — files/id_rsa.crypted — counts as drift; a
# machine's own key is its business). Exit code depends on the key.
echo "--check with an unrelated leftover id_rsa:"
install "$PRE" --check
expect_not_output_matches "unrelated id_rsa is NOT reported as drift" "$DRIFT_RE"
expect_exists "id_rsa survives --check (no cleanup deletion)" "$PRE/.ssh/id_rsa"
if [[ "$KEY_SET" -eq 1 ]]; then
    expect_rc "unrelated id_rsa is not a failure (exit 0)" 0
else
    skip "unrelated id_rsa is not a failure (exit 0) (FILE_CRYPTO_KEY unset)"
fi

# Negative control: a --check that always prints the drift notice must fail.
# Needs a fully installed clean home, which requires the key.
echo "--check on a clean home (negative control):"
if [[ "$KEY_SET" -eq 1 ]]; then
    install "$CLEAN" --check
    expect_not_output_matches "no drift notice on a clean home" "$DRIFT_RE"
    expect_rc "--check on a fully installed clean home exits 0" 0
else
    need_key "no drift notice on a clean home"
    need_key "--check on a fully installed clean home exits 0"
fi

# The RETIRED identity key (files/id_rsa.crypted) left on a machine IS
# drift attributable to this unit and must still WARN (task H). Needs the
# key to decrypt the retired private key.
echo "--check with the retired identity key:"
RET="$TMPROOT/retired"
if [[ "$KEY_SET" -eq 1 ]]; then
    mkdir -p "$RET/.ssh"
    if scripts/lib/crypto.sh decrypt "$FILE_CRYPTO_KEY" \
            < shared-configs/ssh-admin/files/id_rsa.crypted > "$RET/.ssh/id_rsa" 2>/dev/null; then
        chmod 600 "$RET/.ssh/id_rsa"
        # --check returns 1 when authorized_keys is missing — install it
        # first so the ONLY failure signal left is the drift warning.
        install "$RET"
        install "$RET" --check
        expect_output_matches "retired id_rsa is reported as drift (WARN)" "$DRIFT_RE"
        expect_rc "retired id_rsa drift is a warning, not a failure (exit 0)" 0
    else
        bad "retired id_rsa could not be decrypted — positive drift case cannot run"
    fi
else
    need_key "retired id_rsa is reported as drift (WARN)"
    need_key "retired id_rsa drift is a warning, not a failure (exit 0)"
fi

# ===========================================================================
# Task G: profile-declared ssh-admin, and the removal of register-provider's
# "extract the mylinuxpool-actions line" special case.
#
# Semantics below are checked with parsers (jq for JSON, a YAML parser for
# the workflow), never by grepping raw text — grep-found strings have
# produced four false positives in this project already.
# ===========================================================================

# --- 1) both provider profiles declare ssh-admin (jq, not grep) -----------
echo "provider profiles declare ssh-admin (jq array membership):"
for pf in profiles/provider/default/profile.json profiles/provider/no-sudo/profile.json; do
    if jq -e '.shared_config | index("ssh-admin") != null' "$pf" >/dev/null 2>&1; then
        ok "${pf} shared_config contains ssh-admin"
    else
        bad "${pf} shared_config does not contain ssh-admin (jq .shared_config)"
    fi
done

# --- 2) all three roles source fatesaikou's authorized_keys ---------------
echo "three roles, one authorization source:"
if jq -e '.shared_config | index("ssh-admin") != null' profiles/gateway/default/profile.json >/dev/null 2>&1; then
    ok "gateway profile declares ssh-admin"
else
    bad "gateway profile does not declare ssh-admin"
fi
for pf in profiles/provider/default/profile.json profiles/provider/no-sudo/profile.json; do
    if jq -e '.shared_config | index("ssh-admin") != null' "$pf" >/dev/null 2>&1; then
        ok "provider (${pf%%/profile.json}) declares ssh-admin"
    else
        bad "provider (${pf%%/profile.json}) does not declare ssh-admin"
    fi
done

WORKER_AK_REF='shared-configs/ssh-admin/files/authorized_keys.crypted'
WORKER_AK_FOUND=no
WORKER_YAML_ERR=""
if python3 -c 'import yaml' >/dev/null 2>&1; then
    WORKER_AK_OUT="$(python3 - "$WORKER_AK_REF" <<'PY' 2>&1
import sys
import yaml
target = sys.argv[1]
try:
    doc = yaml.safe_load(open(".github/workflows/create-worker.yml"))
except Exception as exc:
    print("YAML-ERROR: %s" % exc)
    sys.exit(3)
found = []
def walk(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "run" and isinstance(v, str) and target in v:
                found.append(v)
            walk(v)
    elif isinstance(node, list):
        for item in node:
            walk(item)
walk(doc)
print("FOUND" if found else "NOTFOUND")
sys.exit(0 if found else 1)
PY
)"
else
    WORKER_AK_OUT="$(ruby -ryaml -e '
begin
  doc = YAML.load_file(".github/workflows/create-worker.yml")
rescue => e
  puts "YAML-ERROR: #{e}"
  exit 3
end
target = ARGV[0]
found = []
walk = lambda do |o|
  case o
  when Hash then o.each { |k, v| found << v if k == "run" && v.is_a?(String) && v.include?(target); walk.call(v) }
  when Array then o.each { |i| walk.call(i) }
  end
end
walk.call(doc)
puts found.empty? ? "NOTFOUND" : "FOUND"
exit(found.empty? ? 1 : 0)
' "$WORKER_AK_REF" 2>&1)"
fi
WORKER_AK_LAST="$(printf '%s\n' "$WORKER_AK_OUT" | tr -d '\r' | tail -1)"
if [[ "$WORKER_AK_LAST" == "FOUND" ]]; then
    WORKER_AK_FOUND=yes
fi
if [[ "$WORKER_AK_FOUND" == yes ]]; then
    ok "create-worker.yml (worker role) references ${WORKER_AK_REF} (YAML-parsed run blocks)"
elif [[ "$WORKER_AK_OUT" == YAML-ERROR* ]]; then
    bad "cannot parse create-worker.yml to verify the worker's authorized_keys source (${WORKER_AK_OUT})"
elif [[ -z "$WORKER_AK_OUT" ]]; then
    bad "no YAML parser available (python3+pyyaml or ruby) to verify the worker's authorized_keys source"
else
    bad "create-worker.yml does not reference ${WORKER_AK_REF} in any run block"
fi
expect_exists "the referenced ssh-admin bundle exists" "$WORKER_AK_REF"

# --- 3) install deploys the FULL declared list, not one extracted line -----
# register-provider no longer pulls a single mylinuxpool-actions line out of
# the bundle; the ssh-admin unit (now profile-declared) installs all of it.
# A regression to the old behaviour would drop every other declared key.
echo "ssh-admin install deploys the full declared list:"
FULL="$TMPROOT/full-list"
if [[ "$KEY_SET" -eq 1 ]]; then
    mkdir -p "$FULL"
    install "$FULL"
    expect_rc "install exits 0" 0

    declared_blobs="$(scripts/lib/crypto.sh decrypt "$FILE_CRYPTO_KEY" \
        < shared-configs/ssh-admin/files/authorized_keys.crypted 2>/dev/null \
        | awk '$2 != "" { print $2 }' | sort -u)"
    n_declared="$(printf '%s\n' "$declared_blobs" | grep -c . || true)"
    installed_blobs="$(awk '$2 != "" { print $2 }' "$FULL/.ssh/authorized_keys" 2>/dev/null | sort -u)"
    n_installed="$(printf '%s\n' "$installed_blobs" | grep -c . || true)"
    n_missing="$(comm -23 <(printf '%s\n' "$declared_blobs") <(printf '%s\n' "$installed_blobs") | grep -c . || true)"

    # Precondition: with a single-key bundle, "all keys" and "one line" are
    # indistinguishable, so the check below would be vacuous.
    if [[ "$n_declared" -ge 2 ]]; then
        ok "declared bundle holds ${n_declared} keys (one-line extraction would be detectable)"
    else
        bad "declared bundle holds only ${n_declared} key(s); the full-list check cannot distinguish anything"
    fi
    if [[ "$n_missing" -eq 0 ]]; then
        ok "every declared key is present in the installed authorized_keys"
    else
        bad "installed authorized_keys is missing ${n_missing} of ${n_declared} declared key(s) — looks like the old one-line extraction"
    fi
    if [[ "$n_installed" -eq "$n_declared" ]]; then
        ok "installed set equals the declared set (${n_installed} keys)"
    else
        bad "installed has ${n_installed} key(s), declared has ${n_declared}"
    fi
else
    need_key "install exits 0"
    need_key "declared bundle holds >=2 keys (one-line extraction would be detectable)"
    need_key "every declared key is present in the installed authorized_keys"
    need_key "installed set equals the declared set"
fi

# --- 4) register-provider step numbering: 1..N contiguous, one M -----------
echo "register-provider step numbering is contiguous:"
STEP_PAIRS="$(grep -oE 'step [0-9]+/[0-9]+' ops-scripts/register-provider.sh 2>/dev/null | sed 's/^step //')"
if [[ -z "$STEP_PAIRS" ]]; then
    bad "no 'step N/M' messages found in register-provider.sh"
else
    STEP_COUNT="$(printf '%s\n' "$STEP_PAIRS" | grep -c . || true)"
    expected=1; contiguous=1; denoms=""
    while IFS='/' read -r num den; do
        [[ -n "$num" && -n "$den" ]] || continue
        [[ "$num" -eq "$expected" ]] || contiguous=0
        expected=$((expected + 1))
        denoms="${denoms}${den}"$'\n'
    done <<< "$STEP_PAIRS"
    uniq_denoms="$(printf '%s' "$denoms" | sort -u | grep -c . || true)"
    first_den="$(printf '%s' "$denoms" | grep . | head -1)"
    if [[ "$contiguous" -eq 1 ]]; then
        ok "steps 1..${STEP_COUNT} are contiguous (no gap from removing a step)"
    else
        bad "step numbers are not contiguous (found: $(printf '%s' "$STEP_PAIRS" | tr '\n' ' '))"
    fi
    if [[ "$uniq_denoms" -eq 1 ]]; then
        ok "every step shares one denominator M=${first_den}"
    else
        bad "mixed step denominators: $(printf '%s' "$denoms" | grep . | sort -u | tr '\n' ' ')"
    fi
    if [[ "$STEP_COUNT" -eq "${first_den:-0}" ]]; then
        ok "denominator M=${first_den} matches the ${STEP_COUNT} real steps"
    else
        bad "denominator M=${first_den} does not match the ${STEP_COUNT} real steps"
    fi
fi

# --- 5) union semantics: install never revokes an undeclared key -----------
echo "install never revokes an undeclared key (union without --prune):"
UNION="$TMPROOT/union"
mkdir -p "$UNION/.ssh"
UNION_BLOB='AAAAC3NzaC1lZDI1NTE5AAAAIUNDECLAREDkeyOnlyInThisTest'
printf 'ssh-ed25519 %s undeclared@test\n' "$UNION_BLOB" > "$UNION/.ssh/authorized_keys"
if [[ "$KEY_SET" -eq 1 ]]; then
    install "$UNION"
    expect_rc "install exits 0" 0
    if awk -v b="$UNION_BLOB" '$2 == b' "$UNION/.ssh/authorized_keys" 2>/dev/null | grep -q .; then
        ok "the undeclared key is still present after install (union kept it)"
    else
        bad "the undeclared key was removed by a plain install (must require --prune)"
    fi
else
    need_key "install exits 0"
    need_key "the undeclared key is still present after install (union kept it)"
fi

# ===========================================================================
# Task H: --check tightened.
#   - extra (undeclared) keys are drift → exit non-zero, and the message names
#     the offending key (comment or fingerprint)
#   - the id_rsa drift notice fires ONLY for the retired key (the one in
#     files/id_rsa.crypted), not for any id_rsa — the old check warned on any
#     id_rsa at all, which was a false positive for an unrelated identity
#   - a WARN never changes the exit code
#
# All homes are branches of one freshly installed "good" home, so every case
# differs from the exact-match baseline by exactly the mutation under test.
# ===========================================================================
echo "── H: --check 收緊 ──"

expect_rc_nonzero() {
    if [[ "$RC" -ne 0 ]]; then ok "$1"
    else bad "$1 (exit 0, should be non-zero; output: ${OUT:-<empty>})"; fi
}

# need_good_home <label> — used when the baseline could not be prepared.
# Never a pass: the root cause already produced a FAIL, this only stops the
# dependent assertions from masquerading as verified.
need_good_home() {
    skip "$1 (good home not prepared — see the FAIL above)"
}

H_GOOD="$TMPROOT/h-good"
H_READY=0

echo "H1: authorized_keys exactly equals the declared list:"
if [[ "$KEY_SET" -eq 1 ]]; then
    mkdir -p "$H_GOOD"
    install "$H_GOOD"
    expect_rc "install into a fresh home exits 0" 0
    if [[ "$RC" -eq 0 ]]; then H_READY=1; fi

    h_declared="$(scripts/lib/crypto.sh decrypt "$FILE_CRYPTO_KEY" \
        < shared-configs/ssh-admin/files/authorized_keys.crypted 2>/dev/null \
        | awk '$2 != "" { print $2 }' | sort -u)"
    h_declared_n="$(printf '%s\n' "$h_declared" | grep -c . || true)"
    h_installed="$(awk '$2 != "" { print $2 }' "$H_GOOD/.ssh/authorized_keys" 2>/dev/null | sort -u)"
    if [[ "$h_declared_n" -ge 1 && "$h_installed" == "$h_declared" ]]; then
        ok "premise: installed set is byte-for-byte the declared set (${h_declared_n} keys)"
    else
        bad "premise failed: installed set differs from the declared set; exact-match checks cannot run"
    fi
    install "$H_GOOD" --check
    expect_rc "exact match → --check exits 0" 0
    expect_not_output_matches "exact match → no WARN at all" 'WARN'
else
    need_key "install into a fresh home exits 0"
    need_key "premise: installed set is byte-for-byte the declared set"
    need_key "exact match → --check exits 0"
    need_key "exact match → no WARN at all"
fi

echo "H2: one declared key missing → still non-zero:"
if [[ "$KEY_SET" -eq 1 ]]; then
    if [[ "$H_READY" -ne 1 ]]; then
        need_good_home "premise: exactly one declared key was removed"
        need_good_home "missing a declared key → --check non-zero"
    else
        H_MISSING="$TMPROOT/h-missing"
        rm -rf "$H_MISSING"; cp -R "$H_GOOD" "$H_MISSING"
        h_first_declared="$(printf '%s\n' "$h_declared" | head -1)"
        awk -v b="$h_first_declared" '!($2 == b)' "$H_MISSING/.ssh/authorized_keys" \
            > "$H_MISSING/.ssh/ak.tmp" && mv "$H_MISSING/.ssh/ak.tmp" "$H_MISSING/.ssh/authorized_keys"
        h_now_n="$(awk '$2 != "" { print $2 }' "$H_MISSING/.ssh/authorized_keys" 2>/dev/null | sort -u | grep -c . || true)"
        if [[ "$h_now_n" -eq "$((h_declared_n - 1))" ]]; then
            ok "premise: exactly one declared key was removed (${h_declared_n} → ${h_now_n})"
        else
            bad "premise failed: removal left ${h_now_n} key(s), expected $((h_declared_n - 1))"
        fi
        install "$H_MISSING" --check
        expect_rc_nonzero "missing a declared key → --check non-zero"
    fi
else
    need_key "premise: exactly one declared key was removed"
    need_key "missing a declared key → --check non-zero"
fi

echo "H3: an undeclared key present → non-zero, and the message names it:"
if [[ "$KEY_SET" -eq 1 ]]; then
    if [[ "$H_READY" -ne 1 ]]; then
        need_good_home "premise: an undeclared key was appended"
        need_good_home "undeclared key → --check non-zero (tightened behaviour)"
        need_good_home "undeclared key → the message names its comment or fingerprint"
    else
        H_EXTRA="$TMPROOT/h-extra"
        rm -rf "$H_EXTRA"; mkdir -p "$H_EXTRA/.ssh"
        cp "$H_GOOD/.ssh/authorized_keys" "$H_EXTRA/.ssh/authorized_keys"
        EXTRA_COMMENT='h-extra-undeclared@test'
        EXTRA_FP=""
        if command -v ssh-keygen >/dev/null 2>&1; then
            if ssh-keygen -q -t ed25519 -N '' -C "$EXTRA_COMMENT" \
                    -f "$TMPROOT/h-extrakey" </dev/null >/dev/null 2>&1; then
                EXTRA_FP="$(ssh-keygen -lf "$TMPROOT/h-extrakey.pub" 2>/dev/null | awk '{print $2}')"
                cat "$TMPROOT/h-extrakey.pub" >> "$H_EXTRA/.ssh/authorized_keys"
            fi
        fi
        if [[ -z "$EXTRA_FP" ]]; then
            printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHextraKeyForTestingOnly %s\n' \
                "$EXTRA_COMMENT" >> "$H_EXTRA/.ssh/authorized_keys"
        fi
        h_extra_n="$(awk '$2 != "" { print $2 }' "$H_EXTRA/.ssh/authorized_keys" 2>/dev/null | sort -u | grep -c . || true)"
        if [[ "$h_extra_n" -eq "$((h_declared_n + 1))" ]]; then
            ok "premise: authorized_keys holds declared + 1 undeclared key (${h_extra_n})"
        else
            bad "premise failed: expected $((h_declared_n + 1)) keys, found ${h_extra_n}"
        fi
        install "$H_EXTRA" --check
        expect_rc_nonzero "undeclared key → --check non-zero (tightened behaviour)"
        if grep -qF "$EXTRA_COMMENT" <<<"$OUT"; then
            ok "undeclared key → the message names its comment"
        elif [[ -n "$EXTRA_FP" ]] && grep -qF "$EXTRA_FP" <<<"$OUT"; then
            ok "undeclared key → the message names its fingerprint (${EXTRA_FP})"
        else
            bad "undeclared key → the message names neither its comment (${EXTRA_COMMENT}) nor its fingerprint (${EXTRA_FP:-<n/a>})"
        fi
    fi
else
    need_key "premise: an undeclared key was appended"
    need_key "undeclared key → --check non-zero (tightened behaviour)"
    need_key "undeclared key → the message names its comment or fingerprint"
fi

echo "H4: id_rsa is the RETIRED key → WARN that names id_rsa:"
H_RETIRED="$TMPROOT/h-retired"
H_RETIRED_OK=0
if [[ "$KEY_SET" -eq 1 && "$H_READY" -eq 1 ]]; then
    rm -rf "$H_RETIRED"; mkdir -p "$H_RETIRED/.ssh"
    cp "$H_GOOD/.ssh/authorized_keys" "$H_RETIRED/.ssh/authorized_keys"
    if scripts/lib/crypto.sh decrypt "$FILE_CRYPTO_KEY" \
            < shared-configs/ssh-admin/files/id_rsa.crypted > "$H_RETIRED/.ssh/id_rsa" 2>/dev/null; then
        chmod 600 "$H_RETIRED/.ssh/id_rsa"
        H_RETIRED_OK=1
        ok "premise: the retired id_rsa.crypted decrypted into the fake home"
        install "$H_RETIRED" --check
        expect_output_matches "retired id_rsa → WARN is printed" 'WARN'
        expect_output_matches "retired id_rsa → the WARN names id_rsa" 'id_rsa'
        expect_rc "retired id_rsa does not change the exit code → 0" 0
    else
        bad "premise failed: id_rsa.crypted would not decrypt with the provided key"
        skip "retired id_rsa → WARN is printed (retired key could not be prepared)"
        skip "retired id_rsa → the WARN names id_rsa (retired key could not be prepared)"
        skip "retired id_rsa does not change the exit code → 0 (retired key could not be prepared)"
    fi
else
    need_key "premise: the retired id_rsa.crypted decrypted into the fake home"
    need_key "retired id_rsa → WARN is printed"
    need_key "retired id_rsa → the WARN names id_rsa"
    need_key "retired id_rsa does not change the exit code → 0"
fi

echo "H5: id_rsa is SOME OTHER key → no WARN (the false positive that was fixed):"
H_OTHER="$TMPROOT/h-other"
if [[ "$KEY_SET" -eq 1 && "$H_READY" -eq 1 ]] && command -v ssh-keygen >/dev/null 2>&1; then
    rm -rf "$H_OTHER"; mkdir -p "$H_OTHER/.ssh"
    cp "$H_GOOD/.ssh/authorized_keys" "$H_OTHER/.ssh/authorized_keys"
    if ssh-keygen -q -t ed25519 -N '' -C 'h-other-identity@test' \
            -f "$TMPROOT/h-otherkey" </dev/null >/dev/null 2>&1; then
        cp "$TMPROOT/h-otherkey" "$H_OTHER/.ssh/id_rsa"
        chmod 600 "$H_OTHER/.ssh/id_rsa"
        retired_pub=""
        if [[ "$H_RETIRED_OK" -eq 1 ]]; then
            retired_pub="$(ssh-keygen -y -f "$H_RETIRED/.ssh/id_rsa" 2>/dev/null | awk '{print $2}')"
        fi
        other_pub="$(ssh-keygen -y -f "$H_OTHER/.ssh/id_rsa" 2>/dev/null | awk '{print $2}')"
        if [[ -z "$other_pub" ]]; then
            bad "premise failed: could not derive the public half of the generated key"
        elif [[ -z "$retired_pub" ]]; then
            skip "premise: the generated key differs from the retired one (retired key unavailable)"
        elif [[ "$other_pub" == "$retired_pub" ]]; then
            bad "premise failed: the generated key equals the retired key"
        else
            ok "premise: the generated key differs from the retired one"
        fi
        install "$H_OTHER" --check
        expect_not_output_matches "other id_rsa → NO WARN (false positive fixed)" 'WARN'
        expect_rc "other id_rsa does not change the exit code → 0" 0
    else
        skip "premise: the generated key differs from the retired one (ssh-keygen failed)"
        skip "other id_rsa → NO WARN (false positive fixed) (ssh-keygen failed)"
        skip "other id_rsa does not change the exit code → 0 (ssh-keygen failed)"
    fi
else
    need_key "premise: the generated key differs from the retired one"
    need_key "other id_rsa → NO WARN (false positive fixed)"
    need_key "other id_rsa does not change the exit code → 0"
fi

echo "H6: no id_rsa at all → no WARN:"
if [[ "$KEY_SET" -eq 1 && "$H_READY" -eq 1 ]]; then
    if [[ ! -e "$H_GOOD/.ssh/id_rsa" ]]; then
        ok "premise: the good home has no id_rsa"
        install "$H_GOOD" --check
        expect_not_output_matches "no id_rsa → NO WARN" 'WARN'
        expect_rc "no id_rsa does not change the exit code → 0" 0
    else
        bad "premise failed: the good home unexpectedly has an id_rsa"
        skip "no id_rsa → NO WARN (premise failed)"
        skip "no id_rsa does not change the exit code → 0 (premise failed)"
    fi
else
    need_key "premise: the good home has no id_rsa"
    need_key "no id_rsa → NO WARN"
    need_key "no id_rsa does not change the exit code → 0"
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
printf 'passed %d / failed %d\n' "$pass" "$fail"
exit "$fail"
