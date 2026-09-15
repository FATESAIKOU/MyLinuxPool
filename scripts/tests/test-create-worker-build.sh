#!/usr/bin/env bash
# test-create-worker-build.sh — behavioral tests for the "Build worker image
# on provider" step of .github/workflows/create-worker.yml (task F).
#
# The step's command is a string inside the workflow YAML, not a callable
# function. It is extracted with a YAML parser (python3 + yaml — never
# grep), the workflow expressions (${{ github.sha }} etc.) are substituted
# with fixtures, and the resulting command is REALLY executed with bash -c
# in a sandbox HOME with fake git/docker on PATH that record every argv they
# receive.
#
# The fix under test: the build must not depend on a persistent
# ~/.mylinuxpool/repo anymore — it fetches the pinned commit SHA into a
# temp dir and builds from there. Until the workflow is actually rewritten,
# these assertions FAIL (the current tree still references
# ~/.mylinuxpool/repo in that step).
#
# Every assertion is behavioral and can genuinely fail:
#   1. command never references ~/.mylinuxpool/repo
#   2. fake git log: fetch with --depth, target = the pinned SHA (not a
#      branch name)
#   3. fake docker log: build context and -f Dockerfile are under the temp
#      dir, never under $HOME/.mylinuxpool
#   4. temp dir does not exist after the run
#   5. fake git failing (fetch failure) -> command exits non-zero AND temp
#      dir is still cleaned up
#   6. command carries the credential helper that reads
#      ~/.mylinuxpool/gh_token, and the token VALUE appears in no recorded
#      argv
#
# bash 3.2 compatible on purpose (macOS ships 3.2).
#
# Run: scripts/tests/test-create-worker-build.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

WORKFLOW=".github/workflows/create-worker.yml"
TOKEN="ghp_testtoken_f6ab12cd"
SHA="0123456789abcdef0123456789abcdef01234567"

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required (to parse the workflow YAML)" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-create-worker-build.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin" "$SANDBOX/home"

ARGV_LOG="$SANDBOX/argv.log"
FAKE_REPO="$SANDBOX/fake-repo"
mkdir -p "$FAKE_REPO/profiles/worker/default"
printf 'FROM scratch\n' > "$FAKE_REPO/profiles/worker/default/Dockerfile"
printf '{}' > "$FAKE_REPO/profiles/worker/default/profile.json"

# ---- fake tools: record argv, then behave ------------------------------
# The fake git models git's credential-scope semantics behaviorally:
#   - `-c key=value` applies ONLY to that one call (git's documented
#     behavior); a `config` subcommand that sets a gh_token-reading
#     helper is recorded into $FAKE_GIT_CONFIG (like writing .git/config);
#   - `fetch` verifies "credentials are in effect at THIS call": same-call
#     `-c credential...helper` OR a previously recorded `config`. The
#     verdict goes to $FAKE_CRED_STATE (available|missing) while fetch
#     itself still succeeds — this fake models credential *setup*, not
#     actual auth. A fetch with no credential setup in effect is exactly
#     the bug that used to green-light (a helper string elsewhere in the
#     script, -c'd onto init only, is NOT in effect at fetch time).
cat > "$SANDBOX/bin/git" <<'FAKE_GIT'
#!/usr/bin/env bash
printf 'git|%s\n' "$*" >> "$FAKE_ARGV_LOG"

subcmd=""
has_c_cred=0
i=1
while [[ $i -le $# ]]; do
    a="${!i}"
    if [[ -z "$subcmd" ]]; then
        case "$a" in
            -c)
                i=$((i + 1))
                v="${!i:-}"
                if [[ "$v" == credential*helper* ]] && [[ "$v" == *gh_token* ]]; then
                    has_c_cred=1
                fi
                ;;
            -C)
                i=$((i + 1))
                ;;
            *)
                subcmd="$a"
                ;;
        esac
    fi
    i=$((i + 1))
done

if [[ "$subcmd" == "config" ]]; then
    # `git config <key> <value>`: key and value are SEPARATE arguments, so
    # "a credential helper was set" means SOME argument matches
    # credential*helper* AND SOME (possibly other) argument mentions
    # gh_token. (The -c path above is a single `key=value` argument and is
    # handled separately — the two forms must both be recognised.)
    has_cred_key=0
    has_token_ref=0
    for (( j=1; j<=$#; j++ )); do
        a="${!j}"
        [[ "$a" == credential*helper* ]] && has_cred_key=1
        [[ "$a" == *gh_token* ]] && has_token_ref=1
    done
    if [[ "$has_cred_key" -eq 1 && "$has_token_ref" -eq 1 ]]; then
        printf 'helper-set\n' > "${FAKE_GIT_CONFIG:-/dev/null}"
    fi
fi

if [[ "$subcmd" == "fetch" ]]; then
    if [[ "$has_c_cred" -eq 1 ]] || [[ -s "${FAKE_GIT_CONFIG:-/dev/null}" ]]; then
        printf 'available\n' > "$FAKE_CRED_STATE"
    else
        printf 'missing\n' > "$FAKE_CRED_STATE"
    fi
fi

if [[ "${FAKE_GIT_FAIL:-}" == "1" ]]; then
    for a in "$@"; do
        if [[ "$a" == "fetch" ]]; then
            echo "fatal: couldn't find remote ref 0123456789abcdef" >&2
            exit 1
        fi
    done
fi

case "$subcmd" in
    init) exit 0 ;;
    remote) exit 0 ;;
    config) exit 0 ;;
    fetch) exit 0 ;;
    checkout) exit 0 ;;
esac
exit 0
FAKE_GIT
chmod +x "$SANDBOX/bin/git"

cat > "$SANDBOX/bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
printf 'docker|%s\n' "$*" >> "$FAKE_ARGV_LOG"
case "${1:-}" in
    build)
        : > "$FAKE_BUILD_OUT" || exit 1
        printf 'image-tag-placeholder\n' >> "$FAKE_BUILD_OUT"
        exit 0
        ;;
esac
exit 0
FAKE_DOCKER
chmod +x "$SANDBOX/bin/docker"

# ---- extract the step's command via YAML (never grep) -------------------
EXTRACT_ERR="$SANDBOX/extract.err"
if ! python3 - "$WORKFLOW" > "$SANDBOX/command.raw" 2> "$EXTRACT_ERR" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    doc = yaml.safe_load(f)

steps = doc["jobs"]["create"]["steps"]
cmd = None
for s in steps:
    if s.get("name") == "Build worker image on provider":
        cmd = s["with"]["command"]
        break
if cmd is None:
    sys.exit("step 'Build worker image on provider' not found in the workflow")
if not isinstance(cmd, str):
    sys.exit("step's command is not a string")
print(cmd)
PY
then
    echo "test-create-worker-build: could not extract the step command from ${WORKFLOW}:" >&2
    cat "$EXTRACT_ERR" >&2
    exit 1
fi
if [[ ! -s "$SANDBOX/command.raw" ]]; then
    echo "test-create-worker-build: extracted command is empty — is the workflow mid-edit?" >&2
    exit 1
fi

# Substitutions: ${{ github.sha }} -> the pinned SHA; ${{ env.GH_REPO }} ->
# fixture repo; ${{ inputs.provider }}/image/name -> fixtures;
# ${{ steps.identity.outputs.image_tag }} -> a fixed tag.
sed \
    -e 's/\${{ github\.sha }}/'"$SHA"'/g' \
    -e 's|\${{ env\.GH_REPO }}|testowner/testrepo|g' \
    -e 's/\${{ inputs\.provider }}/testnode/g' \
    -e 's/\${{ inputs\.image }}/default/g' \
    -e 's/\${{ inputs\.name }}/testnode-default/g' \
    -e 's/\${{ steps\.identity\.outputs\.image_tag }}/mlp-testnode-default-img/g' \
    "$SANDBOX/command.raw" > "$SANDBOX/command.sh"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# assert_no_arg <label> — the token VALUE must appear in no recorded argv
assert_no_token_arg() {
    if grep -qF "$TOKEN" "$ARGV_LOG" 2>/dev/null; then
        bad "token value appears in a recorded argv: $(grep -F "$TOKEN" "$ARGV_LOG" | head -1)"
    else
        ok "token value never appears in any recorded argv"
    fi
}

# --- assertion 1: no persistent-repo reference --------------------------
if grep -qF '~/.mylinuxpool/repo' "$SANDBOX/command.sh"; then
    bad "1. command still references ~/.mylinuxpool/repo"
else
    ok "1. command never references ~/.mylinuxpool/repo"
fi

# --- assertion 6a: credential helper present -----------------------------
if grep -qF 'credential.https://github.com.helper' "$SANDBOX/command.sh" \
   && grep -qF '$HOME/.mylinuxpool/gh_token' "$SANDBOX/command.sh"; then
    ok "6a. command carries the gh_token credential helper"
else
    bad "6a. command has no credential helper reading \$HOME/.mylinuxpool/gh_token"
fi

# --- happy-path run --------------------------------------------------------
: > "$ARGV_LOG"
FAKE_BUILD_OUT="$SANDBOX/build.out"
FAKE_GIT_CONFIG="$SANDBOX/git-config"
FAKE_CRED_STATE="$SANDBOX/cred-state"
rm -f "$FAKE_GIT_CONFIG" "$FAKE_CRED_STATE"
HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
FAKE_ARGV_LOG="$ARGV_LOG" FAKE_BUILD_OUT="$FAKE_BUILD_OUT" \
FAKE_GIT_CONFIG="$FAKE_GIT_CONFIG" FAKE_CRED_STATE="$FAKE_CRED_STATE" \
/bin/bash "$SANDBOX/command.sh" </dev/null > "$SANDBOX/happy.out" 2> "$SANDBOX/happy.err"
HAPPY_RC=$?

if [[ "$HAPPY_RC" -eq 0 ]]; then
    ok "happy path: command exits 0"
else
    bad "happy path: command exits $HAPPY_RC (stderr: $(head -c 300 "$SANDBOX/happy.err" | tr '\n' ' '))"
fi

# --- assertion 2: fetch --depth 1, target = pinned SHA ---------------------
FETCH_LINE="$(grep '^git|.* fetch ' "$ARGV_LOG" 2>/dev/null | head -1)"
if [[ -z "$FETCH_LINE" ]]; then
    bad "2. no git fetch call was recorded (fake git never ran?)"
else
    if grep -q 'fetch' <<<"$FETCH_LINE" && grep -q -- '--depth' <<<"$FETCH_LINE"; then
        ok "2a. git fetch was recorded with --depth"
    else
        bad "2a. git fetch recorded without --depth: $FETCH_LINE"
    fi
    if grep -qF "$SHA" <<<"$FETCH_LINE"; then
        ok "2b. fetch targets the pinned SHA (not a branch name)"
    else
        bad "2b. fetch does not reference the pinned SHA $SHA: $FETCH_LINE"
    fi
fi

# --- assertion 3: build context + Dockerfile under temp dir ---------------
BUILD_LINE="$(grep '^docker|build ' "$ARGV_LOG" 2>/dev/null | head -1)"
if [[ -z "$BUILD_LINE" ]]; then
    bad "3. no docker build call was recorded (fake docker never ran?)"
else
    TMP_CTX=""
    if grep -q '^docker|build ' "$ARGV_LOG"; then
        TMP_CTX="$(printf '%s' "$BUILD_LINE" | grep -oE '[^ ]*/profiles/worker' | head -1 | sed 's#/profiles/worker##')"
    fi
    if [[ -n "$TMP_CTX" ]] && grep -qF "$TMP_CTX" <<<"$BUILD_LINE" \
       && ! grep -qF "$SANDBOX/home/.mylinuxpool" <<<"$BUILD_LINE"; then
        ok "3a. build context path is under the temp dir, not \$HOME/.mylinuxpool"
    else
        bad "3a. build context is NOT under the temp dir: $BUILD_LINE"
    fi
    if [[ -n "$TMP_CTX" ]] && grep -qF "$TMP_CTX/profiles/worker/default/Dockerfile" <<<"$BUILD_LINE"; then
        ok "3b. -f Dockerfile path is under the temp dir"
    else
        bad "3b. -f Dockerfile path not under the temp dir: $BUILD_LINE"
    fi
fi

# --- assertion 4: temp dir cleaned up on success --------------------------
if [[ -n "${TMP_CTX:-}" ]]; then
    if [[ -e "$TMP_CTX" ]]; then
        bad "4. temp dir still exists after the run: $TMP_CTX"
    else
        ok "4. temp dir does not exist after the run"
    fi
else
    bad "4. temp dir unknown — cannot verify cleanup"
fi

# --- assertion 6b: credentials in effect AT THE FETCH CALL ---------------
# Behavioral, not textual: git's -c applies to one call only, so a helper
# -c'd onto `git init` but absent at `git fetch` leaves fetch without
# credentials — the exact defect this suite used to green-light. Both
# legit fixes (same-call -c on fetch, or git config written before fetch)
# satisfy the fake git's "available" state.
if [[ "$(cat "$FAKE_CRED_STATE" 2>/dev/null)" == "available" ]]; then
    ok "6b. credentials (gh_token helper) are in effect at the fetch call"
else
    bad "6b. fetch call has NO credential setup in effect (helper -c'd onto init only? missing on fetch?) — state: $(cat "$FAKE_CRED_STATE" 2>/dev/null || echo '<no fetch ran>')"
fi
assert_no_token_arg

# --- assertion 5: fetch failure -> non-zero + cleanup ----------------------
: > "$ARGV_LOG"
FAIL_TMP_DEST=""
rm -f "$FAKE_GIT_CONFIG" "$FAKE_CRED_STATE"
HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
FAKE_ARGV_LOG="$ARGV_LOG" FAKE_BUILD_OUT="$FAKE_BUILD_OUT" \
FAKE_GIT_CONFIG="$FAKE_GIT_CONFIG" FAKE_CRED_STATE="$FAKE_CRED_STATE" \
FAKE_GIT_FAIL=1 \
/bin/bash "$SANDBOX/command.sh" </dev/null > "$SANDBOX/fail.out" 2> "$SANDBOX/fail.err"
FAIL_RC=$?

if [[ "$FAIL_RC" -ne 0 ]]; then
    ok "5a. fetch failure -> command exits non-zero (got $FAIL_RC)"
else
    bad "5a. command exited 0 despite fetch failure (set -e broken?)"
fi
FAIL_FETCH="$(grep '^git|.* fetch ' "$ARGV_LOG" 2>/dev/null | head -1)"
FAIL_TMP=""
if [[ -n "$FAIL_FETCH" ]]; then
    FAIL_TMP="$(printf '%s' "$FAIL_FETCH" | grep -oE '[^ ]*/tmp\.[^ ]*' | head -1)"
fi
if [[ -n "$FAIL_TMP" ]]; then
    if [[ -e "$FAIL_TMP" ]]; then
        bad "5b. temp dir survives a failed run: $FAIL_TMP"
    else
        ok "5b. temp dir cleaned up even when fetch fails"
    fi
else
    bad "5b. could not locate the temp dir from the failed run's argv — harness gap"
fi
assert_no_token_arg

# --- injection: credential helper -c'd onto init ONLY (the defect) --------
# A command whose fetch runs with no credential setup in effect must turn
# 6b red — proving 6b is behavioral, not a string grep. The injected
# command takes the CURRENT correct shape and rewrites it into the defect
# shape: drop the `git config credential...helper <body>` line (no
# persistent config), and put the helper on `git init` as `-c`, which
# applies to that one call only (git's documented behavior) — so at fetch
# time there is no credential setup in effect. The 6b verdict on this
# injected variant is reported separately ("inj ok" = 6b turned red =
# detection); a green 6b here would be a vacuous check and fails the
# whole script.
echo "injection: credential helper -c'd onto init ONLY (fetch without credentials):"
: > "$ARGV_LOG"
rm -f "$FAKE_GIT_CONFIG" "$FAKE_CRED_STATE"
python3 - "$SANDBOX/command.sh" "$SANDBOX/command-inj.sh" <<'PY'
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
out = []
for ln in open(src, encoding="utf-8").read().splitlines():
    if re.match(r"^git .* config credential", ln):
        continue
    if re.match(r"^git .* init$", ln):
        ln = "git -c credential.https://github.com.helper='!f() { echo password=$(cat $HOME/.mylinuxpool/gh_token 2>/dev/null); }; f' " + ln
    out.append(ln)
open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
FAKE_ARGV_LOG="$ARGV_LOG" FAKE_BUILD_OUT="$FAKE_BUILD_OUT" \
FAKE_GIT_CONFIG="$FAKE_GIT_CONFIG" FAKE_CRED_STATE="$FAKE_CRED_STATE" \
/bin/bash "$SANDBOX/command-inj.sh" </dev/null > "$SANDBOX/inj.out" 2> "$SANDBOX/inj.err"
INJ_CRED="$(cat "$FAKE_CRED_STATE" 2>/dev/null)"
if [[ "$INJ_CRED" == "available" ]]; then
    bad "injection: 6b stayed GREEN on fetch-without-credentials — 6b is vacuous (harness broken)"
else
    printf '  inj ok    %s\n' "injection: 6b turns red on fetch-without-credentials (state: ${INJ_CRED:-<no fetch ran>}) — detection works"
fi
assert_no_token_arg

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
exit "$fail"
