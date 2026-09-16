#!/usr/bin/env bash
# test-mlp-register.sh — `mlp register {client|provider}` must be a THIN
# forwarder to the existing ops-scripts, never a second implementation
# (RUNBOOK §7.12: one rule, one implementation — this repo has been bitten
# three times by a duplicated rule that only got migrated in one place).
#
# Harness: the repo is copied into a sandbox and the two registration
# scripts are replaced by fakes that record their argv and exit with a
# configurable code. mlp itself is copied byte-for-byte, so the path
# derivation under test is real (SCRIPT_DIR/.. from mlp's own location) —
# a hard-coded absolute path would keep pointing at the real scripts and
# the forwarded argv would never reach the fakes.
#
# Cases:
#   1. `mlp register` with no subcommand -> non-zero AND prints usage
#   2. `mlp register client ...`  -> forwarded argv is exactly the tail
#   3. `mlp register provider ...` -> same
#   4. the forwarded script's exit code is preserved (non-zero propagates)
#   5. `mlp --help` lists both subcommands AND says where each runs
#      (client: the machine you connect from; provider: the NEW machine,
#      not the Mac — the point people get wrong)
#   + injection: swallow the exit code in the forwarder -> case 4 must redden
#
# Run: scripts/tests/test-mlp-register.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

MLP="ops-scripts/mlp"
CLIENT_SCRIPT="ops-scripts/register-client"
PROVIDER_SCRIPT="ops-scripts/register-provider.sh"

MISSING=0
for f in "$MLP" "$CLIENT_SCRIPT" "$PROVIDER_SCRIPT"; do
    if [[ ! -f "$f" ]]; then
        echo "test-mlp-register: ${f} is missing; dependent cases will FAIL" >&2
        MISSING=1
    fi
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-mlp-register.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin" "$SANDBOX/home"

TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT="timeout 30"
fi

# ---- repo copy with fake registration scripts ---------------------------
TREE="$SANDBOX/repo"
if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude '.git' "$REPO_ROOT/" "$TREE/" 2>/dev/null
else
    cp -R "$REPO_ROOT/." "$TREE/"
    rm -rf "$TREE/.git"
fi

ARGV_FILE="$SANDBOX/argv.log"
EXIT_FILE="$SANDBOX/exit.code"
: > "$ARGV_FILE"
printf '0' > "$EXIT_FILE"

# fake_register <path> <label> — records argv (NUL-free, one per line) and
# exits with whatever $EXIT_FILE says, so case 4 can drive the code.
make_fake() {
    local path="$1" label="$2"
    cat > "$path" <<FAKE
#!/usr/bin/env bash
{
  printf 'label=%s\n' "${label}"
  printf 'argc=%s\n' "\$#"
  for a in "\$@"; do printf 'arg=%s\n' "\$a"; done
} >> "${ARGV_FILE}"
exit "\$(cat "${EXIT_FILE}" 2>/dev/null || echo 0)"
FAKE
    chmod +x "$path"
}

if [[ -d "$TREE/ops-scripts" ]]; then
    make_fake "$TREE/$CLIENT_SCRIPT" "register-client"
    make_fake "$TREE/$PROVIDER_SCRIPT" "register-provider"
fi

# mlp's check_deps requires fzf/jq/gh and an executable pool-resolve; fzf and
# gh are stubbed (jq is real and needed by mlp internals).
for tool in gh fzf; do
    cat > "$SANDBOX/bin/$tool" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$SANDBOX/bin/$tool"
done

pass=0; fail=0; injfail=0
ok()      { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()     { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
inj_ok()  { printf '  inj ok    %s\n' "$1"; }
inj_bad() { printf '  inj FAIL  %s\n' "$1"; injfail=1; }

MLP_RC=0; MLP_OUT=""

# run_mlp <mlp-path> [args...] — HOME/PATH scrubbed, stdin closed so nothing
# can hang on a menu read.
run_mlp() {
    local mlp_path="$1"; shift
    : > "$ARGV_FILE"
    MLP_OUT="$(HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
        ARGV_FILE="$ARGV_FILE" EXIT_FILE="$EXIT_FILE" \
        $TIMEOUT bash "$mlp_path" "$@" </dev/null 2>&1)"
    MLP_RC=$?
}

# forwarded_args <label> — the args the fake with <label> received, one per
# line. Empty when that fake was never called.
forwarded_args() {
    awk -v want="label=$1" '
        $0 == want { found=1; next }
        found && /^label=/ { exit }
        found && /^arg=/ { print substr($0, 5) }
    ' "$ARGV_FILE"
}

forwarded_label() {
    awk '/^label=/{ print substr($0, 7); exit }' "$ARGV_FILE"
}

forwarded_argc() {
    awk '/^argc=/{ print substr($0, 6); exit }' "$ARGV_FILE"
}

# ===========================================================================
echo "1. mlp register（無子指令）→ 非 0 且印用法:"
run_mlp "$TREE/$MLP" register
if [[ "$MLP_RC" -ne 0 ]]; then
    ok "1a. exits non-zero (got ${MLP_RC})"
else
    bad "1a. exited 0 with no subcommand"
fi
if printf '%s' "$MLP_OUT" | grep -qiE 'usage.*register|register.*(client|provider)'; then
    ok "1b. prints usage naming the subcommands"
else
    bad "1b. output does not look like usage (got: $(printf '%s' "$MLP_OUT" | head -c 160 | tr '\n' ' '))"
fi
if [[ "$(forwarded_label)" == "" ]]; then
    ok "1c. forwarded nothing (no subcommand means no script runs)"
else
    bad "1c. a script was invoked anyway: $(forwarded_label)"
fi

# ===========================================================================
echo "2. mlp register client → 參數原樣轉發:"
run_mlp "$TREE/$MLP" register client --name x --no-refresh
if [[ "$MLP_RC" -eq 0 ]]; then
    ok "2a. exits 0"
else
    bad "2a. exits ${MLP_RC} (output: $(printf '%s' "$MLP_OUT" | head -c 160 | tr '\n' ' '))"
fi
if [[ "$(forwarded_label)" == "register-client" ]]; then
    ok "2b. forwarded to register-client (not register-provider)"
else
    bad "2b. forwarded to '$(forwarded_label)' — expected register-client"
fi
GOT="$(forwarded_args register-client)"
WANT=$'--name\nx\n--no-refresh'
if [[ "$GOT" == "$WANT" ]]; then
    ok "2c. argv is exactly --name x --no-refresh (argc=$(forwarded_argc))"
else
    bad "2c. argv differs: got [$(printf '%s' "$GOT" | tr '\n' ' ')] expected [--name x --no-refresh]"
fi

# ===========================================================================
echo "3. mlp register provider → 參數原樣轉發:"
run_mlp "$TREE/$MLP" register provider --name y --gateway-port 2299
if [[ "$MLP_RC" -eq 0 ]]; then
    ok "3a. exits 0"
else
    bad "3a. exits ${MLP_RC} (output: $(printf '%s' "$MLP_OUT" | head -c 160 | tr '\n' ' '))"
fi
if [[ "$(forwarded_label)" == "register-provider" ]]; then
    ok "3b. forwarded to register-provider (not register-client)"
else
    bad "3b. forwarded to '$(forwarded_label)' — expected register-provider"
fi
GOT="$(forwarded_args register-provider)"
WANT=$'--name\ny\n--gateway-port\n2299'
if [[ "$GOT" == "$WANT" ]]; then
    ok "3c. argv is exactly --name y --gateway-port 2299 (argc=$(forwarded_argc))"
else
    bad "3c. argv differs: got [$(printf '%s' "$GOT" | tr '\n' ' ')] expected [--name y --gateway-port 2299]"
fi

# An option-heavy invocation: forwarding must not try to interpret any of
# these itself (the brief calls out --name/--key/--remove/--no-sudo).
run_mlp "$TREE/$MLP" register client --name z --key /tmp/k --remove --no-sudo --no-refresh
GOT="$(forwarded_args register-client)"
WANT=$'--name\nz\n--key\n/tmp/k\n--remove\n--no-sudo\n--no-refresh'
if [[ "$GOT" == "$WANT" ]]; then
    ok "3d. an option-heavy tail is forwarded verbatim (--key/--remove/--no-sudo)"
else
    bad "3d. option-heavy argv differs: got [$(printf '%s' "$GOT" | tr '\n' ' ')]"
fi

# ===========================================================================
echo "4. 被轉發腳本的非 0 離開碼必須保留:"
printf '3' > "$EXIT_FILE"
run_mlp "$TREE/$MLP" register client --name x --no-refresh
if [[ "$MLP_RC" -eq 3 ]]; then
    ok "4a. propagates exit 3 unchanged"
else
    bad "4a. expected exit 3, got ${MLP_RC} — the forwarder swallowed or rewrote the code"
fi
if [[ "$(forwarded_label)" == "register-client" ]]; then
    ok "4b. the script really ran (exit code came from it)"
else
    bad "4b. the script never ran — 4a proves nothing"
fi
printf '7' > "$EXIT_FILE"
run_mlp "$TREE/$MLP" register provider --name y --gateway-port 2299
if [[ "$MLP_RC" -eq 7 ]]; then
    ok "4c. a different code (7) also propagates unchanged"
else
    bad "4c. expected exit 7, got ${MLP_RC}"
fi
printf '0' > "$EXIT_FILE"

# ===========================================================================
echo "5. mlp --help 列出兩個子指令並說明在哪裡跑:"
HELP="$(HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
    $TIMEOUT bash "$TREE/$MLP" --help </dev/null 2>&1)"
if printf '%s' "$HELP" | grep -q 'register client'; then
    ok "5a. --help lists 'register client'"
else
    bad "5a. --help does not list 'register client'"
fi
if printf '%s' "$HELP" | grep -q 'register provider'; then
    ok "5b. --help lists 'register provider'"
else
    bad "5b. --help does not list 'register provider'"
fi
# The wording that matters: client runs where you connect FROM; provider runs
# on the NEW machine, not the Mac. Assertions are phrase-tolerant but must
# find both ideas somewhere in the help text.
if printf '%s' "$HELP" | grep -qiE 'connect from|where you (are|connect)|this machine'; then
    ok "5c. --help says the client one runs on the machine you connect from"
else
    bad "5c. --help does not explain where 'register client' runs (got: $(printf '%s' "$HELP" | tr '\n' ' ' | head -c 300))"
fi
if printf '%s' "$HELP" | grep -qiE 'new machine|on that machine|the machine being added' \
   && printf '%s' "$HELP" | grep -qiE 'not (on )?(the |here on the )?Mac|not here'; then
    ok "5d. --help says the provider one runs on the NEW machine, not the Mac"
else
    bad "5d. --help does not clearly place 'register provider' on the new machine and off the Mac (got: $(printf '%s' "$HELP" | tr '\n' ' ' | head -c 300))"
fi

# ===========================================================================
echo "6. 注入：轉發吞掉離開碼 → 第 4 條必須紅:"
# The mutant must live NEXT TO the sandbox's fake scripts: mlp derives the
# forwarder paths from its own location (SCRIPT_DIR), so writing it anywhere
# else makes it target the real ops-scripts and the injection proves nothing.
INJ_MLP="$TREE/ops-scripts/mlp-swallow"
if [[ ! -f "$TREE/$MLP" ]]; then
    inj_bad "6. ${MLP} 不存在，無從注入"
else
    # Replace the forwarding invocation so the script's exit code is
    # discarded (`|| true`). The tail must stay identical so the argv cases
    # would still pass — that is what isolates "swallowed code" as the fault.
    if python3 - "$TREE/$MLP" "$INJ_MLP" <<'PY'
import re
import sys
src = open(sys.argv[1], encoding="utf-8").read()
# The forwarder's last statement is `"$script" "$@"`. Any variant of that
# (different quoting/spacing) is matched, then given `|| true`.
pat = re.compile(r'^([ \t]*)("\$script"|"\$\{script\}"|"\$script"\s+"\$@")[^\n]*$', re.M)
out, n = pat.subn(lambda m: m.group(1) + m.group(2) + ' "$@" || true', src)
if n == 0:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
    then
        chmod +x "$INJ_MLP"
        if ! bash -n "$INJ_MLP" 2>/dev/null; then
            inj_bad "6. 注入版語法錯誤（harness 問題）"
        else
            # Case 4's scenario against the mutant.
            printf '3' > "$EXIT_FILE"
            run_mlp "$INJ_MLP" register client --name x --no-refresh
            printf '0' > "$EXIT_FILE"
            if [[ "$MLP_RC" -eq 0 ]]; then
                inj_ok "6. 注入後離開碼被吞掉（回 0）——第 4 條會紅"
            elif [[ "$MLP_RC" -eq 3 ]]; then
                inj_bad "6. 注入後仍保留 3——注入沒生效（harness 問題）"
            else
                inj_bad "6. 注入後回 ${MLP_RC}（非預期的 0 或 3）——harness 問題"
            fi
        fi
    else
        inj_bad "6. 找不到轉發呼叫可注入（needle 落空）——harness 問題"
    fi
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
