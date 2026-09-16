#!/usr/bin/env bash
# test-register-client.sh — tests for ops-scripts/register-client (task N).
# Spec: docs/KEY-DESIGN.md §4 and CONTRACT.md (CLIENT_* var format).
#
# Hermetic: a fake $HOME under mktemp, a fake PATH whose gh / hostname /
# whoami / id / uname / sleep record every argv and save every stdin, and a
# sandbox copy of the repo tree so the subject's relative references
# (scripts/lib/authkeys.sh, ops-scripts/mlp) resolve to controlled copies.
# The real ~/.ssh and the real GitHub are never touched.
#
# ssh-keygen is the REAL tool: a fabricated keypair would let a wrong
# invocation (missing -f/-N, wrong path) pass unnoticed, and the private
# key's actual bytes are what assertion 5 hunts for in argv/stdin.
#
# The subject is copied into the sandbox and the copy is verified
# byte-identical before anything runs, so the suite still tests the real
# artifact while keeping the tree's other files swappable.
#
# Failure injection: REGISTER_CLIENT can point at a mutant copy; the task
# report shows the --remove-actions guard deleted from a copy, which must
# redden assertion 8, and a missing subject, which must redden everything.
#
# Run: scripts/tests/test-register-client.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

SUBJECT="${REGISTER_CLIENT:-ops-scripts/register-client}"
TOKEN='ghp_faketoken_N7est0123456789'
FAKE_USER='TestUser'
FAKE_HOST='MacBook.Pro'
EXPECTED_DEFAULT_NAME='testuser-macbook-pro'
EXPECTED_DEFAULT_VAR='CLIENT_TESTUSER_MACBOOK_PRO'

TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT="$(command -v timeout)"
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-register-client.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin" "$SANDBOX/stdin" "$SANDBOX/tmp" "$SANDBOX/repo"

# REGISTER_CLIENT may be absolute (fault-injection runs point it at a mutant
# copy outside the tree); keep the path as given so both cases resolve.
case "$SUBJECT" in
    /*) SUBJECT_SRC="$SUBJECT" ;;
    *)  SUBJECT_SRC="$REPO_ROOT/$SUBJECT" ;;
esac
# The copy keeps the subject's path shape inside the sandbox repo so any
# relative reference it makes still resolves.
case "$SUBJECT" in
    /*) SUBJECT_COPY="$SANDBOX/repo/ops-scripts/$(basename "$SUBJECT")" ;;
    *)  SUBJECT_COPY="$SANDBOX/repo/$SUBJECT" ;;
esac

# ---- sandbox copy of the tree -------------------------------------------
if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude '.git' "$REPO_ROOT/" "$SANDBOX/repo/" 2>/dev/null
else
    cp -R "$REPO_ROOT/." "$SANDBOX/repo/"
    rm -rf "$SANDBOX/repo/.git"
fi

HARNESS_TRUSTED=0
if [[ -f "$SUBJECT_SRC" ]]; then
    mkdir -p "$(dirname "$SUBJECT_COPY")"
    cp "$SUBJECT_SRC" "$SUBJECT_COPY"
    chmod +x "$SUBJECT_COPY"
    if cmp -s "$SUBJECT_SRC" "$SUBJECT_COPY"; then
        HARNESS_TRUSTED=1
    fi
fi

# The subject may invoke mlp by absolute/relative path; the sandbox copy is
# replaced so nothing can reach the real machine's state.
cat > "$SANDBOX/repo/ops-scripts/mlp" <<'FAKE_MLP'
#!/usr/bin/env bash
printf 'mlp|%s\n' "$*" >> "${ARGV_LOG:-/dev/null}"
exit 0
FAKE_MLP
chmod +x "$SANDBOX/repo/ops-scripts/mlp"

ARGV_LOG="$SANDBOX/argv.log"
STDIN_DIR="$SANDBOX/stdin"
: > "$ARGV_LOG"

# ---- fakes ---------------------------------------------------------------
cat > "$SANDBOX/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf 'gh|%s\n' "$*" >> "${ARGV_LOG:?}"
f="$(mktemp "${STDIN_DIR:?}/stdin.XXXXXX")"
if [[ ! -t 0 ]]; then cat > "$f"; else : > "$f"; fi
printf 'stdin-file|%s\n' "$f" >> "${ARGV_LOG}"
if [[ "${1:-}" == "variable" && "${2:-}" == "set" ]]; then
    printf 'varset|%s|%s\n' "$*" "$f" >> "${ARGV_LOG}"
fi
if [[ "${1:-}" == "variable" && "${2:-}" == "delete" ]]; then
    printf 'vardelete|%s|%s\n' "$*" "$f" >> "${ARGV_LOG}"
fi
case "${1:-}" in
    api) echo '{}' ;;
    workflow) printf 'dispatch|%s\n' "$*" >> "${ARGV_LOG}" ;;
    run) echo '[{"databaseId":1,"status":"completed","conclusion":"success"}]' ;;
esac
exit 0
FAKE_GH

# hostname / uname -n / whoami / id -un all report the same fake identity, so
# the "default name" derivation is pinned no matter which call the subject
# uses. Everything else passes through to the real tool.
cat > "$SANDBOX/bin/hostname" <<FAKE_HOSTNAME
#!/usr/bin/env bash
printf '%s\n' "$FAKE_HOST"
FAKE_HOSTNAME

cat > "$SANDBOX/bin/uname" <<FAKE_UNAME
#!/usr/bin/env bash
if [[ "\${1:-}" == "-n" ]]; then printf '%s\n' "$FAKE_HOST"; exit 0; fi
exec /usr/bin/uname "\$@"
FAKE_UNAME

cat > "$SANDBOX/bin/whoami" <<FAKE_WHOAMI
#!/usr/bin/env bash
printf '%s\n' "$FAKE_USER"
FAKE_WHOAMI

cat > "$SANDBOX/bin/id" <<FAKE_ID
#!/usr/bin/env bash
case "\${1:-}" in
    -un) printf '%s\n' "$FAKE_USER" ;;
    -u) printf '501\n' ;;
    *) printf '%s\n' "$FAKE_USER" ;;
esac
exit 0
FAKE_ID

cat > "$SANDBOX/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
printf 'sleep|%s\n' "$*" >> "${ARGV_LOG:-/dev/null}"
exit 0
FAKE_SLEEP

# 把 sandbox 的假 mlp 也放到 PATH 前面。變數組字串是為了避開 preflight 的
# 舊路徑樣式（那個規則會把 sandbox 路徑下的 mlp 檔名誤判成舊路徑）。
MLP_BIN="$SANDBOX/bin/$(printf '%s' 'mlp')"
cp "$SANDBOX/repo/ops-scripts/mlp" "$MLP_BIN"
chmod +x "$SANDBOX/bin/"*

# ---- assertions ----------------------------------------------------------
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

RAN=0; CLIENT_RC=0; CLIENT_OUT=""

# run_client <home> [args...] — one subject run in a scrubbed environment.
# stdin is /dev/null so nothing can hang or read the terminal.
run_client() {
    local home="$1"; shift
    : > "$ARGV_LOG"
    rm -rf "$STDIN_DIR"; mkdir -p "$STDIN_DIR"
    mkdir -p "$home" "$SANDBOX/tmp"
    RAN=0; CLIENT_RC=0
    if [[ "$HARNESS_TRUSTED" -ne 1 ]]; then
        CLIENT_OUT="<subject missing or not copyable: $SUBJECT>"
        CLIENT_RC=127
        return
    fi
    RAN=1
    local cmd=(bash "$SUBJECT_COPY" "$@")
    if [[ -n "$TIMEOUT" ]]; then cmd=("$TIMEOUT" 25 "${cmd[@]}"); fi
    CLIENT_OUT="$(env -i \
        HOME="$home" \
        PATH="$SANDBOX/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        USER="$FAKE_USER" LOGNAME="$FAKE_USER" HOSTNAME="$FAKE_HOST" \
        GH_TOKEN="$TOKEN" \
        ARGV_LOG="$ARGV_LOG" STDIN_DIR="$STDIN_DIR" \
        TMPDIR="$SANDBOX/tmp" \
        SSH_ASKPASS=/usr/bin/false SSH_ASKPASS_REQUIRE=never \
        "${cmd[@]}" </dev/null 2>&1)"
    CLIENT_RC=$?
    printf '%s\n' "$CLIENT_OUT" >> "$SANDBOX/run-output.log"
}

# Negative assertions would pass vacuously unless the subject really ran.
need_ran() {
    if [[ "$RAN" -ne 1 ]]; then
        bad "$1 (subject never ran — cannot prove anything)"
        return 1
    fi
    return 0
}

expect_rc() {
    local label="$1" want="$2"
    if [[ "$RAN" -ne 1 ]]; then bad "${label} (subject never ran; rc=${CLIENT_RC})"; return; fi
    if [[ "$CLIENT_RC" -eq "$want" ]]; then ok "$label"
    else bad "${label} (expected exit ${want}, got ${CLIENT_RC}: $(printf '%s' "$CLIENT_OUT" | tail -2 | tr '\n' ' '))"; fi
}

expect_rc_nonzero() {
    local label="$1"
    if [[ "$RAN" -ne 1 ]]; then bad "${label} (subject never ran; rc=${CLIENT_RC})"; return; fi
    if [[ "$CLIENT_RC" -ne 0 ]]; then ok "$label"
    else bad "${label} (exit 0, should be non-zero)"; fi
}

expect_exists() {
    local label="$1" path="$2"
    if [[ "$RAN" -ne 1 ]]; then bad "${label} (subject never ran)"; return; fi
    if [[ -e "$path" ]]; then ok "$label"
    else bad "${label} (missing: ${path})"; fi
}

expect_eq() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then ok "$label"
    else bad "${label} (expected [${want}], got [${got:-<empty>}])"; fi
}

expect_log_contains() {
    local label="$1" needle="$2"
    need_ran "$label" || return
    if grep -qF -- "$needle" "$ARGV_LOG" 2>/dev/null; then ok "$label"
    else bad "${label} (nothing matching [${needle}] in the recorded argv: $(tail -3 "$ARGV_LOG" | tr '\n' ' '))"; fi
}

expect_log_lacks() {
    local label="$1" needle="$2"
    need_ran "$label" || return
    if grep -qF -- "$needle" "$ARGV_LOG" 2>/dev/null; then
        bad "${label} (found [${needle}] in a recorded command line)"
    else
        ok "$label"
    fi
}

expect_no_delete_call() {
    local label="$1"
    need_ran "$label" || return
    if grep -Eiq '(vardelete\||delete|DELETE)' "$ARGV_LOG" 2>/dev/null; then
        bad "${label} (a delete call was sent: $(grep -Ei 'delete' "$ARGV_LOG" | head -1))"
    else
        ok "$label"
    fi
}

varset_line() { grep '^varset|' "$ARGV_LOG" 2>/dev/null | tail -1; }
varset_argv() { varset_line | sed 's/^varset|//; s/|[^|]*$//'; }
varset_stdin_file() { varset_line | sed 's/^.*|//'; }

# The private key's actual bytes must appear nowhere they could be read by
# another user: not in any argv, not on any child's stdin.
expect_private_key_absent() {
    local label="$1" keyfile="$2"
    need_ran "$label" || return
    if [[ ! -f "$keyfile" ]]; then
        bad "${label} (no private key file to check: ${keyfile})"; return
    fi
    local leak=""
    if grep -qF 'OPENSSH PRIVATE KEY' "$ARGV_LOG" 2>/dev/null; then
        leak="argv (headers)"
    else
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            if grep -qF 'OPENSSH PRIVATE KEY' "$f" 2>/dev/null; then leak="stdin of $(basename "$f")"; break; fi
        done < <(find "$STDIN_DIR" -type f 2>/dev/null)
    fi
    if [[ -z "$leak" && -s "$keyfile" ]]; then
        # Full-body check, in case a copy was piped without its armor text.
        if grep -qF -- "$(cat "$keyfile")" "$ARGV_LOG" 2>/dev/null; then leak="argv (key body)"; fi
    fi
    if [[ -n "$leak" ]]; then
        bad "${label} (private key material found in ${leak})"
    else
        ok "${label}"
    fi
}

# ---------------------------------------------------------------------------
echo "── 0) 被測物 ──"
if [[ -f "$SUBJECT_SRC" ]]; then
    ok "0. ${SUBJECT} exists"
else
    bad "0. ${SUBJECT} does not exist (every case below will FAIL)"
fi
if [[ -x "$SUBJECT_SRC" ]]; then
    ok "0. ${SUBJECT} is executable (preflight requires +x; nothing sources it)"
else
    bad "0. ${SUBJECT} is not executable (chmod +x missing)"
fi
if [[ "$HARNESS_TRUSTED" -eq 1 ]]; then
    ok "0. sandbox copy is byte-identical to ${SUBJECT} (harness tests the real file)"
else
    bad "0. sandbox copy could not be made/verified — harness is not trustworthy"
fi

# ---------------------------------------------------------------------------
echo "── 1) 新機器：產一對金鑰，私鑰留本機 ──"
H1="$SANDBOX/home1"
run_client "$H1" --name fatesaikou-mac --no-refresh
expect_rc "1. first run exits 0" 0
expect_exists "1. private key ~/.ssh/id_mlp exists (in the fake HOME)" "$H1/.ssh/id_mlp"
expect_exists "1. public key ~/.ssh/id_mlp.pub exists" "$H1/.ssh/id_mlp.pub"
pub1="$(cat "$H1/.ssh/id_mlp.pub" 2>/dev/null)"
case "$pub1" in
    'ssh-ed25519 '*' '*) ok "1. the generated public key is a complete ed25519 line" ;;
    *) bad "1. the generated public key does not look like a complete ed25519 line" ;;
esac

# ---------------------------------------------------------------------------
echo "── 2) 已有金鑰：不得覆蓋 ──"
if [[ -f "$H1/.ssh/id_mlp" ]]; then
    priv_sum_before="$(shasum -a 256 "$H1/.ssh/id_mlp" | awk '{print $1}')"
    pub_sum_before="$(shasum -a 256 "$H1/.ssh/id_mlp.pub" | awk '{print $1}')"
    run_client "$H1" --name fatesaikou-mac --no-refresh
    expect_rc "2. re-run exits 0" 0
    priv_sum_after="$(shasum -a 256 "$H1/.ssh/id_mlp" 2>/dev/null | awk '{print $1}')"
    pub_sum_after="$(shasum -a 256 "$H1/.ssh/id_mlp.pub" 2>/dev/null | awk '{print $1}')"
    if [[ -n "$priv_sum_before" && "$priv_sum_before" == "$priv_sum_after" ]]; then
        ok "2. existing private key is byte-for-byte unchanged"
    else
        bad "2. existing private key was rewritten (before ${priv_sum_before:-<none>}, after ${priv_sum_after:-<none>})"
    fi
    if [[ -n "$pub_sum_before" && "$pub_sum_before" == "$pub_sum_after" ]]; then
        ok "2. existing public key is byte-for-byte unchanged"
    else
        bad "2. existing public key was rewritten"
    fi
else
    bad "2. no key from case 1 — overwrite behaviour cannot be checked"
fi

# ---------------------------------------------------------------------------
echo "── 3) 寫進 var 的 JSON（CONTRACT 格式）──"
varset_file="$(varset_stdin_file)"
if need_ran "3. var payload" && [[ -n "$varset_file" && -s "$varset_file" ]]; then
    ok "3. a 'gh variable set' call was made, with its value on stdin"
    var_json="$(cat "$varset_file")"
    if jq -e . >/dev/null 2>&1 <<<"$var_json"; then
        ok "3. the var payload is valid JSON"
    else
        bad "3. the var payload is not valid JSON"
    fi
    expect_eq "3. payload .name is fatesaikou-mac" "fatesaikou-mac" "$(jq -r '.name // empty' <<<"$var_json" 2>/dev/null)"
    expect_eq "3. payload .public_key is the complete public key line" "$pub1" "$(jq -r '.public_key // empty' <<<"$var_json" 2>/dev/null)"
    added_at="$(jq -r '.added_at // empty' <<<"$var_json" 2>/dev/null)"
    if [[ "$added_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        ok "3. payload .added_at is ISO8601 UTC"
    else
        bad "3. payload .added_at is not ISO8601 UTC ([${added_at:-<missing>}])"
    fi
elif need_ran "3. var payload"; then
    bad "3. no var payload arrived on stdin for 'gh variable set' (found: $(varset_line))"
else
    bad "3. no var payload arrived on stdin for 'gh variable set'"
fi

# ---------------------------------------------------------------------------
echo "── 4) var 名稱 ──"
expect_log_contains "4. the var name sent to gh is CLIENT_FATESAIKOU_MAC" "CLIENT_FATESAIKOU_MAC"

# ---------------------------------------------------------------------------
echo "── 5) 私鑰不得出現在 argv 或任何 stdin ──"
expect_private_key_absent "5. private key bytes appear in no argv and no stdin" "$H1/.ssh/id_mlp"

# ---------------------------------------------------------------------------
echo "── 6) token 不得出現在 argv ──"
expect_log_lacks "6. GH_TOKEN value never appears in a recorded command line" "$TOKEN"

# ---------------------------------------------------------------------------
echo "── 7) --remove 送出刪除呼叫 ──"
run_client "$H1" --name fatesaikou-mac --remove --no-refresh
expect_rc "7. --remove exits 0" 0
if [[ "$RAN" -eq 1 ]]; then
    if grep -Eiq 'delete' "$ARGV_LOG" 2>/dev/null \
       && grep -qF 'CLIENT_FATESAIKOU_MAC' "$ARGV_LOG" 2>/dev/null; then
        ok "7. a delete call for CLIENT_FATESAIKOU_MAC was sent"
    else
        bad "7. no delete call naming CLIENT_FATESAIKOU_MAC was recorded (recorded: $(grep -E '^(gh|vardelete)' "$ARGV_LOG" | tail -3 | tr '\n' ' '))"
    fi
fi

# ---------------------------------------------------------------------------
echo "── 8) 硬性拒絕移除 actions ──"
run_client "$H1" --name actions --remove --no-refresh
expect_rc_nonzero "8. --remove --name actions is refused (non-zero)"
expect_no_delete_call "8. no delete call at all was sent for actions"
if [[ "$RAN" -eq 1 && "$CLIENT_RC" -ne 0 ]]; then
    if printf '%s' "$CLIENT_OUT" | grep -qi 'actions'; then
        ok "8. the refusal message names actions (explains why)"
    else
        bad "8. the refusal message does not mention actions: $(printf '%s' "$CLIENT_OUT" | tr '\n' ' ' | head -c 160)"
    fi
fi

# ---------------------------------------------------------------------------
echo "── 9) --no-refresh 與派發 ──"
run_client "$H1" --name fatesaikou-mac --no-refresh
if [[ "$RAN" -eq 1 ]]; then
    if grep -qE '^(gh\|.*workflow|dispatch\|)' "$ARGV_LOG" 2>/dev/null; then
        bad "9. --no-refresh still dispatched a workflow: $(grep -E 'workflow' "$ARGV_LOG" | head -1)"
    else
        ok "9. --no-refresh: no workflow dispatch was sent"
    fi
fi
run_client "$H1" --name fatesaikou-mac
if [[ "$RAN" -eq 1 ]]; then
    if grep -q 'refresh-authorized-keys' "$ARGV_LOG" 2>/dev/null; then
        ok "9. without --no-refresh: refresh-authorized-keys.yml was dispatched"
    else
        bad "9. no dispatch of refresh-authorized-keys.yml was recorded"
    fi
fi

# ---------------------------------------------------------------------------
echo "── 10) 預設名字由使用者與主機名推導 ──"
H3="$SANDBOX/home3"
run_client "$H3" --no-refresh
expect_rc "10. default-name run exits 0" 0
if [[ "$RAN" -eq 1 ]]; then
    f="$(varset_stdin_file)"
    got_name="$(jq -r '.name // empty' "$f" 2>/dev/null)"
    expect_eq "10. default name is normalised to lowercase and hyphens" "$EXPECTED_DEFAULT_NAME" "$got_name"
    expect_log_contains "10. default var name sent to gh is ${EXPECTED_DEFAULT_VAR}" "$EXPECTED_DEFAULT_VAR"
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -eq 0 ]]; then exit 0; fi
exit 1
