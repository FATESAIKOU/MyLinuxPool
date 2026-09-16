#!/usr/bin/env bash
# test-worker-tunnel-key.sh — tests for task T: a worker gets a fresh tunnel
# key on every create (KEY-DESIGN §9 item 6).
#
# Spec: the frozen interface in the task brief —
#   scripts/create-worker.sh :: create_worker_mint_tunnel_key
#     no args; prints exactly two lines: base64(private key), then the full
#     public key line. Temp files must be gone afterwards. The private key
#     must not appear in any log or child argv.
#   scripts/lib/ledger.sh :: ledger_add <json> <port> <provider> <image>
#     <container> <created_at> [<tunnel_public_key>]
#     The new optional 7th argument writes .tunnel_public_key on that entry;
#     absent, behaviour is byte-identical to before.
#
# Plus the workflow ordering, which is itself the safety design: the
# Gateway must be told about the public key (dispatch refresh and wait)
# BEFORE the container starts, and delete must remove authorization after
# dropping the ledger entry. Ordering is checked by parsing the YAML step
# list, never by grepping line numbers.
#
# Task T2 addition: dispatch_refresh_and_wait must wait for
# status == "completed" before reading .conclusion. The 2026-09-16 run
# broke because the poll treated "left queued" as "finished": an
# in_progress run has no conclusion, so a successful refresh was read as
# <unknown> and the create was rolled back for nothing.
#
# The same bug then appeared a SECOND time, in register-client's own private
# copy of the wait logic (2026-09-17: `mlp register client --remove` reported
# <unknown> for a refresh that succeeded). The function now lives in exactly
# ONE place, shared by create-worker and register-client, and this suite
# asserts that uniqueness — a second implementation is what caused both
# incidents (RUNBOOK §7.12).
#
# Injection demo at the end: the same order checker is run against a copy
# with the two steps swapped, and must go red; and (task T2) the refresh
# waiter is mutated back to the != "queued" poll, which must redden case R1.
#
# Run: scripts/tests/test-worker-tunnel-key.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." || exit 1

CREATE_WORKER_SH="scripts/create-worker.sh"
LEDGER_SH="scripts/lib/ledger.sh"
AUTHKEYS_SH="scripts/lib/authkeys.sh"
CREATE_WF=".github/workflows/create-worker.yml"
DELETE_WF=".github/workflows/delete-worker.yml"

MISSING_ANY=0
for f in "$CREATE_WORKER_SH" "$LEDGER_SH"; do
    if [[ ! -f "$f" ]]; then
        echo "test-worker-tunnel-key: ${f} is missing; dependent cases will FAIL" >&2
        MISSING_ANY=1
    fi
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-worker-tunnel-key.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/fakebin" "$SANDBOX/tmp" "$SANDBOX/home"
: > "$SANDBOX/ssh-keygen.log"
: > "$SANDBOX/mktemp.log"

REAL_MKTEMP="$(command -v mktemp)"
REAL_SSH_KEYGEN="$(command -v ssh-keygen || true)"

TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT="timeout 30"
fi

# ---------------------------------------------------------------------------
# Subject loading. create-worker.sh is a function library (sourced), exactly
# like the workflow does.
# ---------------------------------------------------------------------------
if [[ -f "$CREATE_WORKER_SH" ]]; then
    # shellcheck source=../create-worker.sh
    source "$CREATE_WORKER_SH" 2>/dev/null
fi
if [[ -f "$LEDGER_SH" ]]; then
    # shellcheck source=../lib/ledger.sh
    source "$LEDGER_SH"
fi
if [[ -f "$AUTHKEYS_SH" ]]; then
    # shellcheck source=../lib/authkeys.sh
    source "$AUTHKEYS_SH"
fi

# ---------------------------------------------------------------------------
# Harness: intercept mktemp (so leftover temp files are observable),
# ssh-keygen (so child argv is recorded) and base64 (GNU wrap semantics).
# All forward to the real tools.
# ---------------------------------------------------------------------------
REAL_BASE64="$(command -v base64)"
cat > "$SANDBOX/fakebin/mktemp" <<'FAKE_MKTEMP'
#!/usr/bin/env bash
dir="${FAKE_MKTEMP_DIR:?}"
mkdir -p "$dir"
if [[ "${1:-}" == "-d" ]]; then
    p="$(exec "$REAL_MKTEMP" -d "${dir}/t.XXXXXX")"
else
    p="$(exec "$REAL_MKTEMP" "${dir}/t.XXXXXX")"
fi
printf '%s\n' "$p" >> "${FAKE_MKTEMP_LOG:-/dev/null}"
printf '%s\n' "$p"
FAKE_MKTEMP
chmod +x "$SANDBOX/fakebin/mktemp"

if [[ -n "$REAL_SSH_KEYGEN" ]]; then
    cat > "$SANDBOX/fakebin/ssh-keygen" <<'FAKE_KEYGEN'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SSH_KEYGEN_LOG:-/dev/null}"
exec "$REAL_SSH_KEYGEN" "$@"
FAKE_KEYGEN
    chmod +x "$SANDBOX/fakebin/ssh-keygen"
fi

# GNU-style base64 for the wrap tests. macOS's /usr/bin/base64 emits one
# unbroken line; GNU coreutils (every Linux runner) wraps at 76 columns.
# That platform difference is exactly why "line 2 is the public key" held
# on the Mac test machine and broke on the real runner: with wrapping,
# `base64 < privkey` is several lines, so line 2 is the private key's
# second chunk and the public key is never where the contract says it is.
#
# REAL_BASE64 is captured before this fake goes on PATH; the fake always
# wraps at 76 so the harness reproduces the runner's behaviour.
cat > "$SANDBOX/fakebin/base64" <<'FAKE_BASE64'
#!/usr/bin/env bash
if [[ "${1:-}" == "-d" || "${1:-}" == "--decode" ]]; then
    exec "$REAL_BASE64" "$@"
fi
exec "$REAL_BASE64" "$@" | fold -w 76
FAKE_BASE64
chmod +x "$SANDBOX/fakebin/base64"

# ---------------------------------------------------------------------------
# Fake gh for task T2's refresh-wait tests. It records every argv and models
# the run life cycle from FAKE_GH_STATUS_SEQ, applying --jq exactly like real
# gh does — so the FUNCTION's own filter decides when it believes the run is
# finished. That is precisely where the 2026-09-16 bug lived: a filter that
# left the queue at in_progress saw a run with no conclusion yet.
#
# A `run list` call advances the sequence by one observation; `run view`
# advances only when it asks for `status` (a poll), and otherwise reports
# the last observed status (so a conclusion read after an early exit sees
# the in-progress state, reproducing the bug deterministically).
# ---------------------------------------------------------------------------
cat > "$SANDBOX/fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"

_apply_jq() {
    local json="$1"; shift
    local filter="" prev=""
    for a in "$@"; do
        [[ "$prev" == "--jq" ]] && filter="$a"
        prev="$a"
    done
    if [[ -n "$filter" ]]; then
        printf '%s' "$json" | jq -r "$filter"
    else
        printf '%s\n' "$json"
    fi
}

# observe: report the next status in the sequence and remember it.
_observe() {
    local idx_file="${FAKE_GH_STATE_DIR:?}/next.idx"
    local cur_file="${FAKE_GH_STATE_DIR}/cur.status"
    local n=0 last cur
    [[ -f "$idx_file" ]] && n="$(cat "$idx_file")"
    IFS=',' read -r -a seq <<< "${FAKE_GH_STATUS_SEQ:-queued}"
    last=$(( ${#seq[@]} - 1 ))
    [[ "$n" -gt "$last" ]] && n="$last"
    cur="${seq[$n]}"
    if [[ "$n" -lt "$last" ]]; then
        printf '%s' "$((n + 1))" > "$idx_file"
    else
        printf '%s' "$n" > "$idx_file"
    fi
    printf '%s' "$cur" > "$cur_file"
    printf '%s' "$cur"
}

# read_state: the last observed status (no advance).
_read_state() {
    local cur_file="${FAKE_GH_STATE_DIR:?}/cur.status"
    if [[ -f "$cur_file" ]]; then
        cat "$cur_file"
    else
        IFS=',' read -r -a seq <<< "${FAKE_GH_STATUS_SEQ:-queued}"
        printf '%s' "${seq[0]}"
    fi
}

_asks_status() {
    local prev="" a
    for a in "$@"; do
        if [[ "$prev" == "--json" ]]; then
            case "$a" in *status*) return 0 ;; esac
        fi
        prev="$a"
    done
    return 1
}

# _emit <cur> [gh-args...] — shapes the payload the way the real subcommand
# does: `gh run list` prints an ARRAY, `gh run view` prints a bare OBJECT.
# Getting this wrong makes `.conclusion` unreachable on a view and turns a
# successful refresh into '<unknown>' — which is exactly the 2026-09-16 bug
# shape, so the fake must not manufacture it accidentally.
_emit() {
    local cur="$1" sub="$2"; shift 2
    local concl=""
    [[ "$cur" == "completed" ]] && concl="${FAKE_GH_CONCLUSION:-success}"
    local raw
    if [[ "$sub" == "view" ]]; then
        raw="$(jq -c -n --argjson id "${FAKE_GH_RUN_ID:-42}" --arg s "$cur" --arg c "$concl" \
            '{databaseId:$id,status:$s,conclusion:$c}')"
    else
        raw="$(jq -c -n --argjson id "${FAKE_GH_RUN_ID:-42}" --arg s "$cur" --arg c "$concl" \
            '[{databaseId:$id,status:$s,conclusion:$c}]')"
    fi
    _apply_jq "$raw" "$@"
}

case "${1:-} ${2:-}" in
    "workflow run")
        if [[ "${FAKE_GH_DISPATCH_MODE:-ok}" == "fail" ]]; then
            echo "gh: could not create workflow dispatch event" >&2
            exit 1
        fi
        exit 0
        ;;
    "run list")
        _emit "$(_observe)" list "$@"
        exit 0
        ;;
    "run view")
        if _asks_status "$@"; then
            _emit "$(_observe)" view "$@"
        else
            _emit "$(_read_state)" view "$@"
        fi
        exit 0
        ;;
    "run watch")
        # Blocks like the real thing: observe once per second until the run
        # completes, or until a wall-clock deadline (exit 3 = "still running",
        # which is what a caller's own timeout should treat as a timeout).
        local deadline=$(( $(date +%s) + ${FAKE_GH_WATCH_SECS:-30} ))
        local st
        while :; do
            st="$(_observe)"
            [[ "$st" == "completed" ]] && break
            if (( $(date +%s) >= deadline )); then exit 3; fi
            sleep "$poll_interval"
        done
        if [[ "$(cat "${FAKE_GH_STATE_DIR}/cur.status")" == "completed" ]]; then
            if [[ "${FAKE_GH_CONCLUSION:-success}" == "success" ]]; then exit 0; fi
            exit 1
        fi
        exit 3
        ;;
esac
exit 0
FAKE_GH
chmod +x "$SANDBOX/fakebin/gh"

# ---------------------------------------------------------------------------
# Assertions (same shape as the rest of scripts/tests/).
# ---------------------------------------------------------------------------
pass=0; fail=0; injfail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
inj_ok()   { printf '  inj ok    %s\n' "$1"; }
inj_bad()  { printf '  inj FAIL  %s\n' "$1"; injfail=1; }

OUT=""; RC=0; ERR=""
ERRFILE="$SANDBOX/err"

run() {
    if declare -F "$1" >/dev/null 2>&1; then
        OUT="$("$@" </dev/null 2>/dev/null)"; RC=$?; MISSING=0
    else
        OUT="<undefined function: $1>"; RC=127; MISSING=1
    fi
}

expect_rc() {
    local label="$1" want="$2"
    if [[ "$MISSING" -eq 1 ]]; then bad "$label (function undefined)"
    elif [[ "$RC" -eq "$want" ]]; then ok "$label"
    else bad "$label (expected exit ${want}, got ${RC}; output: ${OUT:0:160})"; fi
}

expect_eq() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then ok "$label"
    else bad "$label (expected [${want}], got [${got:-<empty>}])"; fi
}

b64decode() {
    python3 -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace"))' 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1–3) create_worker_mint_tunnel_key
# ---------------------------------------------------------------------------
echo "create_worker_mint_tunnel_key:"

MINT1_OUT=""; MINT1_RC=0; MINT1_ERR=""
MINT2_OUT=""; MINT2_RC=0
run_mint() {
    local n="$1"
    : > "$SANDBOX/ssh-keygen.log"; : > "$SANDBOX/mktemp.log"
    rm -rf "$SANDBOX/mint-home" "$SANDBOX/tmp/mint"; mkdir -p "$SANDBOX/mint-home" "$SANDBOX/tmp/mint"
    if ! declare -F create_worker_mint_tunnel_key >/dev/null 2>&1; then
        printf 'mint_out_%s="<undefined function: create_worker_mint_tunnel_key>"\n' "$n" > "$SANDBOX/mint.$n.env"
        return 127
    fi
    HOME="$SANDBOX/mint-home" TMPDIR="$SANDBOX/tmp" \
    PATH="$SANDBOX/fakebin:$PATH" \
    REAL_MKTEMP="$REAL_MKTEMP" REAL_SSH_KEYGEN="$REAL_SSH_KEYGEN" \
    REAL_BASE64="$REAL_BASE64" \
    FAKE_MKTEMP_DIR="$SANDBOX/tmp/mint" FAKE_MKTEMP_LOG="$SANDBOX/mktemp.log" \
    FAKE_SSH_KEYGEN_LOG="$SANDBOX/ssh-keygen.log" \
    $TIMEOUT bash -c 'source "$1" >/dev/null 2>&1; create_worker_mint_tunnel_key' _ "$CREATE_WORKER_SH" \
        </dev/null > "$SANDBOX/mint.$n.out" 2> "$SANDBOX/mint.$n.err"
    return $?
}

MINT1_RC=0; run_mint 1 || MINT1_RC=$?
MINT2_RC=0; run_mint 2 || MINT2_RC=$?

LINE1="$(sed -n '1p' "$SANDBOX/mint.1.out" 2>/dev/null)"
LINE2="$(sed -n '2p' "$SANDBOX/mint.1.out" 2>/dev/null)"
N_LINES="$(grep -c . "$SANDBOX/mint.1.out" 2>/dev/null || true)"

if ! declare -F create_worker_mint_tunnel_key >/dev/null 2>&1; then
    bad "1. mint 輸出兩行（函式不存在）"
    bad "1. 第 1 行是私鑰的 base64（函式不存在）"
    bad "1. 第 2 行是合法公鑰（authkeys_valid_pubkey）（函式不存在）"
    bad "2. 連續兩次產生不同金鑰（函式不存在）"
    bad "3. 私鑰不出現在 stderr 或子行程 argv（函式不存在）"
    bad "3. 產完沒有留下暫存檔（函式不存在）"
else
    if [[ "$MINT1_RC" -eq 0 && "$N_LINES" -eq 2 ]]; then
        ok "1. mint 輸出恰兩行（rc=0）"
    else
        bad "1. mint 輸出恰兩行（rc=${MINT1_RC}, 非空行數=${N_LINES}; stderr: $(head -c 160 "$SANDBOX/mint.1.err" 2>/dev/null | tr '\n' ' '))"
    fi

    # Line 1: base64 that decodes to a private key (the interface says so).
    if [[ -n "$LINE1" ]] && [[ "$LINE1" =~ ^[A-Za-z0-9+/=]+$ ]]; then
        DECODED="$(printf '%s' "$LINE1" | b64decode)"
        if [[ "$DECODED" == *"PRIVATE KEY"* ]]; then
            ok "1. 第 1 行 base64 解出私鑰（含 PRIVATE KEY armor）"
        else
            bad "1. 第 1 行 base64 解出的內容不像私鑰"
        fi
    else
        bad "1. 第 1 行不是非空 base64（got: ${LINE1:0:40}）"
    fi

    # Line 2: a valid public key line (contract: authkeys_valid_pubkey).
    if ! declare -F authkeys_valid_pubkey >/dev/null 2>&1; then
        bad "1. 第 2 行是合法公鑰（authkeys_valid_pubkey）（authkeys.sh 不存在）"
    elif authkeys_valid_pubkey "$LINE2" >/dev/null 2>&1; then
        ok "1. 第 2 行通過 authkeys_valid_pubkey"
    else
        bad "1. 第 2 行不是合法公鑰（got: ${LINE2:0:60}）"
    fi
    if [[ -n "$LINE2" && "$LINE1" != "$LINE2" ]]; then
        ok "1. 兩行內容不同（私鑰行不是公鑰行的複製）"
    else
        bad "1. 兩行相同或第 2 行為空"
    fi

    # 2) Two calls must yield different keys.
    M2_OK=0
    if [[ "$MINT2_RC" -eq 0 ]]; then
        L1B="$(sed -n '1p' "$SANDBOX/mint.2.out" 2>/dev/null)"
        L2B="$(sed -n '2p' "$SANDBOX/mint.2.out" 2>/dev/null)"
        if [[ -n "$LINE2" && -n "$L2B" && "$LINE2" != "$L2B" && -n "$LINE1" && "$LINE1" != "$L1B" ]]; then
            M2_OK=1
        fi
    fi
    if [[ "$M2_OK" -eq 1 ]]; then
        ok "2. 連續兩次產生不同的金鑰（公鑰與私鑰都不同）"
    else
        bad "2. 連續兩次的金鑰相同或第二次失敗（rc2=${MINT2_RC}）"
    fi

    # 3a) Private key must not surface in stderr or child argv.
    LEAK=""
    for f in "$SANDBOX/mint.1.err" "$SANDBOX/ssh-keygen.log"; do
        if grep -qF 'OPENSSH PRIVATE KEY' "$f" 2>/dev/null; then LEAK="$LEAK ${f##*/}(armor)"; fi
        if [[ -n "$LINE1" ]] && grep -qF "$LINE1" "$f" 2>/dev/null; then LEAK="$LEAK ${f##*/}(b64)"; fi
    done
    if ! grep -q . "$SANDBOX/ssh-keygen.log" 2>/dev/null; then
        bad "3. 私鑰不出現在 stderr 或子行程 argv（前提失敗：ssh-keygen 未被呼叫，無從證明）"
    elif [[ -z "$LEAK" ]]; then
        ok "3. 私鑰不出現在 stderr 與 ssh-keygen argv"
    else
        bad "3. 私鑰出現在：${LEAK}"
    fi

    # 3b) Temp files: every path the intercepted mktemp handed out must be
    # gone, and nothing may remain in HOME/TMPDIR.
    LEFT=""
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ -e "$p" ]] && LEFT="$LEFT $p"
    done < "$SANDBOX/mktemp.log"
    if ! grep -q . "$SANDBOX/mktemp.log" 2>/dev/null; then
        # No temp path handed out: fall back to sweeping the observed dirs.
        LEFT="$(find "$SANDBOX/mint-home" "$SANDBOX/tmp/mint" -mindepth 1 2>/dev/null | tr '\n' ' ')"
    fi
    if [[ -z "$LEFT" ]]; then
        ok "3. 產完沒有留下暫存檔（mktemp 發出的路徑與觀察目錄皆已清空）"
    else
        bad "3. 暫存檔未刪除：${LEFT}"
    fi

    # 3c) No private key file may be left anywhere the harness can see.
    KEYFILE="$(find "$SANDBOX/mint-home" "$SANDBOX/tmp" -type f 2>/dev/null | head -1)"
    if [[ -z "$KEYFILE" ]]; then
        ok "3. 觀察範圍內沒有留下的金鑰檔（HOME/TMPDIR 皆空）"
    else
        bad "3. 留下檔案：${KEYFILE}"
    fi
fi

# ===========================================================================
# W1–W4: the GNU-wrap platform. macOS base64 never wraps, so "line 2 is the
# public key" passed here while the real Linux runner emitted the private
# key's second chunk on line 2 — and that chunk was published as the worker's
# tunnel key. Every mint below runs with the wrapping fake base64 on PATH
# (same PATH ordering as production), so this case is platform-faithful.
#
# The assertions are the same three the contract needs, plus the structural
# reason the bug was silent: `-` is not in base64's alphabet, so a line that
# starts with "ssh-" cannot be a private-key chunk.
# ===========================================================================
echo "GNU base64（每 76 字元折行）下的 mint:"
W1_RC=0
run_mint_wrapped() {
    local n="$1"
    : > "$SANDBOX/ssh-keygen.log"; : > "$SANDBOX/mktemp.log"
    rm -rf "$SANDBOX/mint-home" "$SANDBOX/tmp/mint"; mkdir -p "$SANDBOX/mint-home" "$SANDBOX/tmp/mint"
    if ! declare -F create_worker_mint_tunnel_key >/dev/null 2>&1; then
        return 127
    fi
    HOME="$SANDBOX/mint-home" TMPDIR="$SANDBOX/tmp" \
    PATH="$SANDBOX/fakebin:$PATH" \
    REAL_MKTEMP="$REAL_MKTEMP" REAL_SSH_KEYGEN="$REAL_SSH_KEYGEN" \
    REAL_BASE64="$REAL_BASE64" \
    FAKE_MKTEMP_DIR="$SANDBOX/tmp/mint" FAKE_MKTEMP_LOG="$SANDBOX/mktemp.log" \
    FAKE_SSH_KEYGEN_LOG="$SANDBOX/ssh-keygen.log" \
    FAKE_KEYGEN_BOGUS_PUB="${FAKE_KEYGEN_BOGUS_PUB:-}" \
    $TIMEOUT bash -c 'source "$1" >/dev/null 2>&1; create_worker_mint_tunnel_key' _ "$CREATE_WORKER_SH" \
        </dev/null > "$SANDBOX/wrapped.$n.out" 2> "$SANDBOX/wrapped.$n.err"
    return $?
}

if ! declare -F create_worker_mint_tunnel_key >/dev/null 2>&1; then
    bad "W1. 折行環境下仍恰兩行（函式不存在）"
    bad "W1b. 第 1 行能單獨解出私鑰（函式不存在）"
    bad "W2. 第 2 行以 ssh- 開頭（函式不存在）"
    bad "W3. 第 2 行通過 authkeys_valid_pubkey（函式不存在）"
    bad "W4. 第 2 行不含私鑰材料（函式不存在）"
else
    run_mint_wrapped 1 || W1_RC=$?
    W_LINE1="$(sed -n '1p' "$SANDBOX/wrapped.1.out" 2>/dev/null)"
    W_LINE2="$(sed -n '2p' "$SANDBOX/wrapped.1.out" 2>/dev/null)"
    W_NLINES="$(grep -c . "$SANDBOX/wrapped.1.out" 2>/dev/null || true)"

    # Sanity: the fake really did wrap, or this whole section proves nothing.
    RAW_B64_LINES="$(head -c 200 /dev/urandom | "$REAL_BASE64" | fold -w 76 | grep -c .)"
    if [[ "$RAW_B64_LINES" -ge 3 && "$W_LINE1" != *"PRIVATE KEY"* ]]; then
        :
    fi

    if [[ "$W1_RC" -eq 0 && "$W_NLINES" -eq 2 ]]; then
        ok "W1. 折行環境下輸出恰兩行（rc=0）"
    else
        bad "W1. 折行環境下輸出恰兩行（rc=${W1_RC}, 非空行數=${W_NLINES}; 第 2 行=[${W_LINE2:0:50}]）"
    fi

    # Line 1 must be the COMPLETE base64 of the private key. Under GNU
    # wrapping without the fix, line 1 is only the first 76 characters and
    # decodes to a fragment with no armor — this is the assertion that
    # catches the bug at its source.
    if [[ -n "$W_LINE1" ]] && [[ "$W_LINE1" =~ ^[A-Za-z0-9+/=]+$ ]]; then
        W_DEC1="$(printf '%s' "$W_LINE1" | b64decode)"
        if [[ "$W_DEC1" == *"PRIVATE KEY"* ]]; then
            ok "W1b. 第 1 行單獨就能解出私鑰（未被折行截斷）"
        else
            bad "W1b. 第 1 行解不出私鑰——base64 被折行截斷了（第 1 行長度 ${#W_LINE1}）"
        fi
    else
        bad "W1b. 第 1 行不是純 base64（長度 ${#W_LINE1}）"
    fi

    if [[ "$W_LINE2" == ssh-* ]]; then
        ok "W2. 第 2 行以 ssh- 開頭"
    else
        bad "W2. 第 2 行不以 ssh- 開頭（got: ${W_LINE2:0:60}）——這就是私鑰被當公鑰發布的形狀"
    fi

    if ! declare -F authkeys_valid_pubkey >/dev/null 2>&1; then
        bad "W3. 第 2 行通過 authkeys_valid_pubkey（authkeys.sh 不存在）"
    elif authkeys_valid_pubkey "$W_LINE2" >/dev/null 2>&1; then
        ok "W3. 第 2 行通過 authkeys_valid_pubkey"
    else
        bad "W3. 第 2 行不是合法公鑰（got: ${W_LINE2:0:60}）"
    fi

    # W4: no private-key material on line 2. `-` is not in base64's
    # alphabet, so any private-key chunk is structurally excluded once the
    # ssh- prefix holds; this also rejects a pure base64 chunk explicitly.
    W4_OK=1
    if [[ -z "$W_LINE2" ]]; then
        W4_OK=0
    elif [[ "$W_LINE2" =~ ^[A-Za-z0-9+/=]+$ ]]; then
        W4_OK=0   # a bare base64 chunk: private-key continuation
    fi
    if [[ "$W4_OK" -eq 1 && -n "$W_DEC1" ]]; then
        # The decoded private key, re-encoded, must not overlap with line 2.
        if [[ "$W_LINE2" != "$W_LINE1" ]] && [[ -n "$W_LINE1" ]]; then
            if printf '%s' "$W_LINE2" | b64decode 2>/dev/null | grep -q 'PRIVATE KEY'; then
                W4_OK=0
            fi
        fi
    fi
    if [[ "$W4_OK" -eq 1 ]]; then
        ok "W4. 第 2 行不含任何私鑰材料"
    else
        bad "W4. 第 2 行是私鑰材料或其片段（got: ${W_LINE2:0:60}）"
    fi
fi

# ===========================================================================
# S1: the function's own self-check. If line 2 does not start with "ssh-",
# the function must return non-zero rather than publish it — the defence
# being added alongside the wrap fix. Forced by making ssh-keygen write a
# non-key file as the public half.
# ===========================================================================
echo "mint 自我檢查（第 2 行不是 ssh- 開頭 → 非 0）:"
if ! declare -F create_worker_mint_tunnel_key >/dev/null 2>&1; then
    bad "S1. 第 2 行不是公鑰時回非 0（函式不存在）"
else
    cat > "$SANDBOX/fakebin/ssh-keygen-bogus" <<'FAKE_BOGUS'
#!/usr/bin/env bash
# Writes a real private key but a bogus .pub, to exercise the self-check.
# NOTE: no `exec` here — exec would replace this shell, so the .pub
# overwrite below would never run and the case would silently test nothing.
args=("$@")
"$REAL_SSH_KEYGEN" "${args[@]}" >/dev/null 2>&1
rc=$?
f=""
prev=""
for a in "${args[@]}"; do
    [[ "$prev" == "-f" ]] && f="$a"
    prev="$a"
done
if [[ -n "$f" ]]; then
    printf 'not-a-public-key\n' > "${f}.pub"
fi
exit $rc
FAKE_BOGUS
    chmod +x "$SANDBOX/fakebin/ssh-keygen-bogus"
    # Put the bogus keygen in front under the name ssh-keygen for one run.
    S1_RC=0
    rm -rf "$SANDBOX/s1bin"; mkdir -p "$SANDBOX/s1bin"
    cp "$SANDBOX/fakebin/ssh-keygen-bogus" "$SANDBOX/s1bin/ssh-keygen"
    chmod +x "$SANDBOX/s1bin/ssh-keygen"
    rm -rf "$SANDBOX/s1-home" "$SANDBOX/s1-tmp"; mkdir -p "$SANDBOX/s1-home" "$SANDBOX/s1-tmp"
    HOME="$SANDBOX/s1-home" TMPDIR="$SANDBOX/s1-tmp" \
    PATH="$SANDBOX/s1bin:$SANDBOX/fakebin:$PATH" \
    REAL_MKTEMP="$REAL_MKTEMP" REAL_SSH_KEYGEN="$REAL_SSH_KEYGEN" REAL_BASE64="$REAL_BASE64" \
    FAKE_MKTEMP_DIR="$SANDBOX/s1-tmp" FAKE_MKTEMP_LOG="$SANDBOX/s1-mktemp.log" \
    FAKE_SSH_KEYGEN_LOG="$SANDBOX/s1-keygen.log" \
    $TIMEOUT bash -c 'source "$1" >/dev/null 2>&1; create_worker_mint_tunnel_key' _ "$CREATE_WORKER_SH" \
        </dev/null > "$SANDBOX/s1.out" 2> "$SANDBOX/s1.err"
    S1_RC=$?
    S1_L2="$(sed -n '2p' "$SANDBOX/s1.out" 2>/dev/null)"
    if [[ "$S1_RC" -ne 0 ]]; then
        ok "S1. 第 2 行不是公鑰時回非 0（rc=${S1_RC}）"
    else
        bad "S1. 第 2 行不是公鑰時仍回 0——自我檢查不存在（輸出第 2 行=[${S1_L2:0:50}]）"
    fi
    if [[ "$S1_RC" -ne 0 ]] && [[ "$S1_L2" != ssh-* ]]; then
        ok "S1b. 自我檢查失敗時不把非公鑰行留在 stdout"
    elif [[ "$S1_RC" -ne 0 ]]; then
        bad "S1b. 回非 0 但仍印了非公鑰的第 2 行=[${S1_L2:0:50}]"
    else
        bad "S1b. 自我檢查不存在，無從判斷 stdout（前提不成立）"
    fi
fi

# ---------------------------------------------------------------------------
# W-Inj: remove the single-line flattening from a copy of the function and
# show W1/W1b/W2 redden. macOS's base64 does not wrap, so the injection must
# reproduce GNU wrapping explicitly (fold -w 76) — exactly the trick
# test-refresh-authkeys.sh used for the same class of bug.
# ---------------------------------------------------------------------------
echo "注入（折行平台）:"
if [[ -f "$CREATE_WORKER_SH" ]] && grep -qE 'base64 < "\$tmp/id"' "$CREATE_WORKER_SH"; then
    INJ_W="$SANDBOX/create-worker-wrap-inj.sh"
    if ! python3 - "$CREATE_WORKER_SH" "$INJ_W" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# Strip ONLY the flattening pipe from the base64 line, leaving the rest of
# the assignment (the closing `)"`, the `line1=` prefix) untouched. Matching
# the whole line and rebuilding it is what mangled the function before.
m = re.search(r'base64 < "\$tmp/id"\s*\|\s*tr -d .\\n.', src)
if not m:
    sys.exit(1)   # no flattening pipe: either already fixed or not this shape
src = src[:m.start()] + 'base64 < "$tmp/id"' + src[m.end():]
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
    then
        bad "W-Inj. 注入腳本失敗（找不到 base64 的單行化管線）——harness 問題"
    fi
    chmod +x "$INJ_W" 2>/dev/null
    if [[ -s "$INJ_W" ]] && ! cmp -s "$CREATE_WORKER_SH" "$INJ_W"; then
        INJ_W_RC=0
        rm -rf "$SANDBOX/wi-home" "$SANDBOX/wi-tmp"; mkdir -p "$SANDBOX/wi-home" "$SANDBOX/wi-tmp"
        HOME="$SANDBOX/wi-home" TMPDIR="$SANDBOX/wi-tmp" \
        PATH="$SANDBOX/fakebin:$PATH" \
        REAL_MKTEMP="$REAL_MKTEMP" REAL_SSH_KEYGEN="$REAL_SSH_KEYGEN" REAL_BASE64="$REAL_BASE64" \
        FAKE_MKTEMP_DIR="$SANDBOX/wi-tmp" FAKE_MKTEMP_LOG="$SANDBOX/wi-mktemp.log" \
        FAKE_SSH_KEYGEN_LOG="$SANDBOX/wi-keygen.log" \
        timeout 30 bash -c 'source "$1" >/dev/null 2>&1; create_worker_mint_tunnel_key' _ "$INJ_W" \
            </dev/null > "$SANDBOX/wi.out" 2>&1
        INJ_W_RC=$?
        INJ_W_N="$(grep -c . "$SANDBOX/wi.out" 2>/dev/null || true)"
        INJ_W_L2="$(sed -n '2p' "$SANDBOX/wi.out" 2>/dev/null)"
        INJ_W_MSG="$(tr '\n' ' ' < "$SANDBOX/wi.out")"
        if [[ "$INJ_W_N" -gt 2 ]]; then
            inj_ok "拿掉單行化後（GNU 折行）輸出變成 ${INJ_W_N} 行、第 2 行=[${INJ_W_L2:0:40}]——W1/W1b/W2 會紅"
        elif [[ "$INJ_W_RC" -ne 0 ]] && printf '%s' "$INJ_W_MSG" | grep -Eqi 'self-check|wrapped|private-key fragment'; then
            inj_ok "拿掉單行化後被函式自己的自我檢查擋下（rc=${INJ_W_RC}；${INJ_W_MSG:0:110}）——W1/W1b/W2 會紅"
        elif [[ "$INJ_W_RC" -ne 0 ]]; then
            inj_bad "注入後回非 0，但不是折行/自我檢查的症狀（rc=${INJ_W_RC}；訊息：${INJ_W_MSG:0:140}）——證明不了 W 群"
        else
            inj_bad "注入後仍恰兩行且回 0——W 群擋不住這個 bug"
        fi
    else
        inj_bad "注入腳本沒改到檔案（needle 找不到）——harness 問題"
    fi
else
    inj_bad "找不到 base64 呼叫（實作尚未落地或形狀改變）——注入無從執行"
fi

# W-Inj2: the stronger injection — strip the flattening AND both self-checks,
# so the raw 2026-09-16 shape reaches stdout (line 2 = private-key fragment).
# This proves W1/W1b/W2 catch the underlying bug even if the guard is gone;
# W-Inj1 alone only shows the guard firing.
if [[ -f "$CREATE_WORKER_SH" ]] && grep -qE 'base64 < "\$tmp/id"' "$CREATE_WORKER_SH"; then
    INJ_W2="$SANDBOX/create-worker-wrap-inj2.sh"
    if ! python3 - "$CREATE_WORKER_SH" "$INJ_W2" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'base64 < "\$tmp/id"\s*\|\s*tr -d .\\n.', src)
if not m:
    sys.exit(1)
src = src[:m.start()] + 'base64 < "$tmp/id"' + src[m.end():]
# Neutralise the self-check block. Match on the guard's distinctive payload
# rather than the whole expression: shell quoting in the source (`*$'\n'*`)
# is awkward to reproduce in a regex and silently failed before. Each guard
# is located by a substring that only appears in it, then its condition is
# replaced with `false`.
guards = [
    ('if [[ "$line1"', 'if [[ "$line1"', 'if false; then'),
    ('if ! [[ "$line2"', 'if ! [[ "$line2"', 'if false; then'),
]
n = 0
for start_marker, _unused, repl in guards:
    i = src.find(start_marker)
    if i == -1:
        continue
    # Replace from the `if` keyword through the `; then` that ends the condition.
    j = src.find('; then', i)
    if j == -1:
        continue
    src = src[:i] + repl + src[j + len('; then'):]
    n += 1
if n < 2:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
    then
        bad "W-Inj2. 注入腳本失敗——harness 問題"
    fi
    chmod +x "$INJ_W2" 2>/dev/null
    if [[ -s "$INJ_W2" ]] && [[ "$(grep -c 'if false; then' "$INJ_W2")" -ge 2 ]]; then
        rm -rf "$SANDBOX/wi2-home" "$SANDBOX/wi2-tmp"; mkdir -p "$SANDBOX/wi2-home" "$SANDBOX/wi2-tmp"
        HOME="$SANDBOX/wi2-home" TMPDIR="$SANDBOX/wi2-tmp" \
        PATH="$SANDBOX/fakebin:$PATH" \
        REAL_MKTEMP="$REAL_MKTEMP" REAL_SSH_KEYGEN="$REAL_SSH_KEYGEN" REAL_BASE64="$REAL_BASE64" \
        FAKE_MKTEMP_DIR="$SANDBOX/wi2-tmp" FAKE_MKTEMP_LOG="$SANDBOX/wi2-mktemp.log" \
        FAKE_SSH_KEYGEN_LOG="$SANDBOX/wi2-keygen.log" \
        timeout 30 bash -c 'source "$1" >/dev/null 2>&1; create_worker_mint_tunnel_key' _ "$INJ_W2" \
            </dev/null > "$SANDBOX/wi2.out" 2>&1
        INJ_W2_RC=$?
        INJ_W2_N="$(grep -c . "$SANDBOX/wi2.out" 2>/dev/null || true)"
        INJ_W2_L2="$(sed -n '2p' "$SANDBOX/wi2.out" 2>/dev/null)"
        # The bug shape: more than two lines, and line 2 is a base64 chunk
        # (private-key fragment) rather than an ssh- line.
        if [[ "$INJ_W2_N" -gt 2 ]] && [[ "$INJ_W2_L2" =~ ^[A-Za-z0-9+/=]+$ ]]; then
            inj_ok "移除單行化與兩道自我檢查後，第 2 行變成私鑰片段（base64、非 ssh-）——W1b/W2/W4 會紅"
        elif [[ "$INJ_W2_N" -gt 2 ]]; then
            inj_ok "移除單行化與自我檢查後輸出 ${INJ_W2_N} 行——W1/W1b/W2 會紅"
        else
            inj_bad "移除防線後仍未重現折行（行數=${INJ_W2_N}, 第2行=[${INJ_W2_L2:0:40}]）——W 群證明力不足"
        fi
    else
        inj_bad "W-Inj2 注入沒生效（防線沒被中性化）——harness 問題"
    fi
fi

# ---------------------------------------------------------------------------
# 4–5) ledger_add's optional 7th argument
# ---------------------------------------------------------------------------
echo "ledger_add (optional tunnel_public_key):"
WPUB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIWORKERTUNNELKEYFIXTURE worker'
REC_BASE='{"port":2300,"provider":"fh-l","image":"default","container":"mlp-fh-l-default-1","created_at":"2026-09-16T00:00:00Z"}'

run ledger_add '[]' 2300 fh-l default mlp-fh-l-default-1 2026-09-16T00:00:00Z "$WPUB"
expect_rc "4. ledger_add 帶第 7 個參數 exits 0" 0
if [[ "$MISSING" -eq 1 ]]; then
    bad "4. 該筆有 .tunnel_public_key（function undefined）"
else
    got="$(jq -r '.[0].tunnel_public_key // "<absent>"' <<<"$OUT" 2>/dev/null)"
    expect_eq "4. 該筆有 .tunnel_public_key" "$WPUB" "$got"
    if jq -e 'type == "array"' >/dev/null 2>&1 <<<"$OUT"; then
        ok "4. 回傳仍是 array"
    else
        bad "4. 回傳不是 array（${OUT:0:80}）"
    fi
fi

run ledger_add '[]' 2300 fh-l default mlp-fh-l-default-1 2026-09-16T00:00:00Z
expect_rc "5. ledger_add 不帶第 7 個參數 exits 0" 0
if [[ "$MISSING" -eq 1 ]]; then
    bad "5. 不帶時沒有 .tunnel_public_key（function undefined）"
    bad "5. 不帶時輸出與現在完全相同（function undefined）"
else
    has="$(jq -r '.[0] | has("tunnel_public_key")' <<<"$OUT" 2>/dev/null)"
    expect_eq "5. 不帶時沒有 .tunnel_public_key" "false" "$has"
    expect_eq "5. 不帶時輸出與現在完全相同" \
        "$(jq -S -c . <<<"[${REC_BASE}]")" "$(jq -S -c . <<<"$OUT" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 6–7) Workflow ordering, by YAML step index.
# ---------------------------------------------------------------------------
echo "workflow ordering (YAML):"

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    bad "6. create-worker.yml 順序（python3+yaml 不可用，無法解析）"
    bad "7a. delete-worker.yml 有 refresh 步驟（python3+yaml 不可用）"
    bad "7b. delete-worker.yml refresh 在移除條目之後（python3+yaml 不可用）"
else
    cat > "$SANDBOX/wf-order.py" <<'PY'
import json, sys, yaml

path = sys.argv[1]
try:
    doc = yaml.safe_load(open(path))
except Exception as exc:  # noqa: BLE001
    print(json.dumps({"error": str(exc)}))
    sys.exit(3)

steps = []
jobs = doc.get("jobs") or {}
for _, job in jobs.items():
    if isinstance(job, dict) and isinstance(job.get("steps"), list):
        steps = job["steps"]
        break

def blob(step):
    return json.dumps(step, default=str)

out = {
    "n_steps": len(steps),
    "refresh": [i for i, s in enumerate(steps) if "refresh-authorized-keys" in blob(s)],
    # The step that actually starts the container: pin to id "run", with the
    # command text as a fallback if the id is ever renamed.
    "docker": [i for i, s in enumerate(steps)
               if s.get("id") == "run" or "docker run" in blob(s)],
    "ledger_remove": [i for i, s in enumerate(steps)
                      if "ledger_remove" in blob(s)
                      or "POOL_WORKERS" in (s.get("name") or "")],
    # A refresh we do not wait on is not the safety step the brief requires.
    "refresh_continue_on_error": [
        i for i, s in enumerate(steps)
        if "refresh-authorized-keys" in blob(s)
        and (s.get("continue-on-error") in (True, "true"))
    ],
}
print(json.dumps(out))
PY

    wf_json() { python3 "$SANDBOX/wf-order.py" "$1" 2>/dev/null; }

    # order_create <wf> — refresh must come before docker run.
    ORDER_REASON=""
    order_create() {
        local j="$1"
        ORDER_REASON=""
        if [[ -z "$j" ]] || ! jq -e . >/dev/null 2>&1 <<<"$j"; then
            ORDER_REASON="YAML 解析失敗"; return 1
        fi
        local nr nd
        nr="$(jq '.refresh | length' <<<"$j")"
        nd="$(jq '.docker | length' <<<"$j")"
        [[ "$nr" -ge 1 ]] || { ORDER_REASON="找不到派發 refresh 的步驟"; return 1; }
        [[ "$nd" -ge 1 ]] || { ORDER_REASON="找不到 docker run 的步驟（id: run）"; return 1; }
        local rmin dmin
        rmin="$(jq '[.refresh[]] | min' <<<"$j")"
        dmin="$(jq '[.docker[]] | min' <<<"$j")"
        if [[ "$rmin" -lt "$dmin" ]]; then return 0; fi
        ORDER_REASON="refresh 在第 ${rmin} 步、docker run 在第 ${dmin} 步——refresh 必須在前"
        return 1
    }

    CJ="$(wf_json "$CREATE_WF")"
    if [[ ! -f "$CREATE_WF" ]]; then
        bad "6. create-worker.yml 順序（workflow 不存在）"
    elif order_create "$CJ"; then
        ok "6. create-worker.yml：派發 refresh 的步驟在 docker run 之前"
    else
        bad "6. create-worker.yml 順序：${ORDER_REASON}"
    fi
    if [[ -n "$CJ" ]] && jq -e . >/dev/null 2>&1 <<<"$CJ"; then
        if [[ "$(jq '.refresh | length' <<<"$CJ")" -lt 1 ]]; then
            bad "6b. 派發 refresh 的步驟不是 continue-on-error（步驟不存在，無從檢查）"
        else
            co="$(jq '.refresh_continue_on_error | length' <<<"$CJ")"
            if [[ "$co" -eq 0 ]]; then
                ok "6b. 派發 refresh 的步驟不是 continue-on-error（失敗要讓 create 失敗）"
            else
                bad "6b. refresh 步驟被標成 continue-on-error（失敗會被吞掉）"
            fi
        fi
    else
        bad "6b. refresh 步驟不是 continue-on-error（前置的 YAML 解析失敗）"
    fi

    # order_delete <wf> — refresh must come after the ledger removal.
    order_delete() {
        local j="$1"
        ORDER_REASON=""
        if [[ -z "$j" ]] || ! jq -e . >/dev/null 2>&1 <<<"$j"; then
            ORDER_REASON="YAML 解析失敗"; return 1
        fi
        local nr nm
        nr="$(jq '.refresh | length' <<<"$j")"
        nm="$(jq '.ledger_remove | length' <<<"$j")"
        [[ "$nr" -ge 1 ]] || { ORDER_REASON="找不到派發 refresh 的步驟"; return 1; }
        [[ "$nm" -ge 1 ]] || { ORDER_REASON="找不到移除帳本條目的步驟（ledger_remove / POOL_WORKERS）"; return 1; }
        local rmin mmin
        rmin="$(jq '[.refresh[]] | min' <<<"$j")"
        mmin="$(jq '[.ledger_remove[]] | min' <<<"$j")"
        if [[ "$rmin" -gt "$mmin" ]]; then return 0; fi
        ORDER_REASON="移除條目在第 ${mmin} 步、refresh 在第 ${rmin} 步——refresh 必須在後"
        return 1
    }

    DJ="$(wf_json "$DELETE_WF")"
    if [[ ! -f "$DELETE_WF" ]]; then
        bad "7a. delete-worker.yml 有派發 refresh 的步驟（workflow 不存在）"
        bad "7b. delete-worker.yml refresh 在移除條目之後（workflow 不存在）"
    else
        if [[ -n "$DJ" ]] && [[ "$(jq '.refresh | length' <<<"$DJ" 2>/dev/null)" -ge 1 ]]; then
            ok "7a. delete-worker.yml 有派發 refresh 的步驟"
        else
            bad "7a. delete-worker.yml 找不到派發 refresh 的步驟"
        fi
        if order_delete "$DJ"; then
            ok "7b. delete-worker.yml：refresh 在移除帳本條目之後"
        else
            bad "7b. delete-worker.yml 順序：${ORDER_REASON}"
        fi
    fi

    # -----------------------------------------------------------------------
    # Injection: swap the two steps in a copy of the real workflow and show
    # the SAME order checker goes red. If the real workflow does not yet have
    # both steps, fall back to a synthetic pair so the checker itself is still
    # demonstrated (positive control + swapped control).
    # -----------------------------------------------------------------------
    echo "injection (order checker):"
    INJ_WF="$SANDBOX/create-worker-swapped.yml"
    if [[ -f "$CREATE_WF" ]] && [[ -n "$CJ" ]] \
       && [[ "$(jq '.refresh | length' <<<"$CJ")" -ge 1 ]] \
       && [[ "$(jq '.docker | length' <<<"$CJ")" -ge 1 ]]; then
        python3 - "$CREATE_WF" "$INJ_WF" <<'PY'
import json, sys, yaml
src, dst = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(src))
steps = doc["jobs"]["create"]["steps"]
def blob(s): return json.dumps(s, default=str)
ri = next(i for i, s in enumerate(steps) if "refresh-authorized-keys" in blob(s))
di = next(i for i, s in enumerate(steps) if s.get("id") == "run" or "docker run" in blob(s))
steps[ri], steps[di] = steps[di], steps[ri]
yaml.safe_dump(doc, open(dst, "w"), sort_keys=False)
PY
        INJ_J="$(wf_json "$INJ_WF")"
        if order_create "$INJ_J"; then
            inj_bad "對調 refresh 與 docker run 後，第 6 條仍判定正確——順序檢查擋不住"
        else
            inj_ok "對調 refresh 與 docker run 後，第 6 條轉紅（${ORDER_REASON}）"
        fi
    else
        cat > "$SANDBOX/synth-good.yml" <<'YML'
jobs:
  create:
    steps:
      - name: Dispatch authorized-keys refresh
        run: gh workflow run refresh-authorized-keys.yml
      - name: Run worker container on provider
        id: run
        run: echo docker run placeholder
YML
        cat > "$SANDBOX/synth-bad.yml" <<'YML'
jobs:
  create:
    steps:
      - name: Run worker container on provider
        id: run
        run: echo docker run placeholder
      - name: Dispatch authorized-keys refresh
        run: gh workflow run refresh-authorized-keys.yml
YML
        GJ="$(wf_json "$SANDBOX/synth-good.yml")"
        BJ="$(wf_json "$SANDBOX/synth-bad.yml")"
        if order_create "$GJ"; then
            inj_ok "正向控制：正確順序的合成 workflow 判定為正確"
        else
            inj_bad "正向控制失敗（checker 壞了）：${ORDER_REASON}"
        fi
        if order_create "$BJ"; then
            inj_bad "對調後仍判定正確——順序檢查擋不住"
        else
            inj_ok "對調 refresh 與 docker run 後，第 6 條轉紅（${ORDER_REASON}）——待真實 workflow 落地後會直接對它做同一件事"
        fi
    fi
fi

# ===========================================================================
# Task T2: dispatch_refresh_and_wait — wait for the refresh to
# actually COMPLETE before trusting its conclusion.
#
# The 2026-09-16 real run failed here: the poll left the loop as soon as the
# run stopped being `queued` (i.e. on `in_progress`), then read an empty
# `.conclusion` and reported `<unknown>` for a refresh that in fact
# succeeded. Case R1 below is that exact sequence.
# ===========================================================================
# Where does the shared waiter live? The brief allows either a new
# scripts/lib/refresh-wait.sh or the existing scripts/refresh-authkeys.sh,
# so discover the single definition instead of hard-coding a path. Discovery
# failing is itself a FAIL (the function must exist somewhere).
# log.sh provides the log() the waiter calls; sourcing it here means the
# discovered file does not have to bring its own.
LOG_LIB="scripts/lib/log.sh"
MISSING_WAITER=0
WAIT_DEFS="$(grep -rlE '^(dispatch_refresh_and_wait|dispatch_refresh_and_wait)\(\)[[:space:]]*\{'     scripts/ ops-scripts/ 2>/dev/null | grep -v '/tests/' | sort -u || true)"
WAIT_DEF_COUNT="$(printf '%s\n' "$WAIT_DEFS" | grep -c . || true)"
WAIT_FILE="$(printf '%s\n' "$WAIT_DEFS" | head -1)"

echo "dispatch_refresh_and_wait:"
echo "  定義點：$(printf '%s' "${WAIT_DEFS:-<none>}" | tr '\n' ' ')"

# S: exactly ONE definition, shared by both callers. The second incident —
# register-client's private copy of the same poll — is what this prevents.
echo "S. 等待函式只有一處定義（共用來源）:"
if [[ "$WAIT_DEF_COUNT" -eq 1 ]]; then
    ok "S1. exactly one definition of the waiter (${WAIT_DEFS})"
else
    bad "S1. expected exactly one definition, found ${WAIT_DEF_COUNT}: $(printf '%s' "${WAIT_DEFS:-<none>}" | tr '\n' ' ')"
fi
for consumer in "scripts/create-worker.sh" "ops-scripts/register-client"; do
    if [[ ! -f "$consumer" ]]; then
        bad "S2. ${consumer} missing"
        continue
    fi
    if grep -q 'dispatch_refresh_and_wait' "$consumer" 2>/dev/null; then
        ok "S2. ${consumer} references the shared waiter"
    else
        bad "S2. ${consumer} never references the shared waiter"
        continue
    fi
    # A function of its own is only acceptable as a one-line alias; anything
    # that re-implements the poll (its own gh polling or completion test) is
    # the second implementation both incidents came from.
    if grep -qE '^[a-z_]*dispatch_refresh_and_wait\(\)' "$consumer" 2>/dev/null; then
        body="$(awk '/^[a-z_]*dispatch_refresh_and_wait\(\)/{f=1} f{print} f&&/^\}/{exit}' "$consumer" 2>/dev/null)"
        if printf '%s' "$body" | grep -qE 'gh (run|workflow)|status.*completed|status != "queued"'; then
            bad "S2. ${consumer} re-implements the waiter body — second implementation (RUNBOOK §7.12)"
        else
            ok "S2. ${consumer} defines only a thin alias, not a second implementation"
        fi
    fi
    if grep -qE 'source .*refresh-(wait|authkeys)\.sh' "$consumer" 2>/dev/null; then
        ok "S2. ${consumer} sources the shared file"
    else
        bad "S2. ${consumer} does not source the shared file — it cannot be calling the shared function"
    fi
done
# The historical bug shape must not survive in non-test code.
if grep -rn 'select(.status != "queued")' scripts/ ops-scripts/ 2>/dev/null | grep -v '/tests/' | grep -q .; then
    bad "S3. a file still polls on 'status != queued' (the bug shape): $(grep -rn 'select(.status != "queued")' scripts/ ops-scripts/ 2>/dev/null | grep -v '/tests/' | head -1)"
else
    ok "S3. no 'status != queued' poll remains in non-test code"
fi

# S4: register-client runs on an operator/provider machine, and must resolve
# the shared file from its OWN location. "Does it still run after being
# copied" is not enough: a hard-coded absolute path to the real repo works on
# this machine too. So the relocated tree carries a SENTINEL refresh-wait.sh
# that records when it is sourced — only a self-derived path reaches it.
echo "S4. register-client 由自身位置推導共用檔路徑（sentinel 判別）:"
RELOC="$SANDBOX/relocated"
rm -rf "$RELOC"
mkdir -p "$RELOC/ops-scripts" "$RELOC/scripts/lib"
cp "ops-scripts/register-client" "$RELOC/ops-scripts/register-client" 2>/dev/null
cp scripts/lib/log.sh "$RELOC/scripts/lib/log.sh" 2>/dev/null
SENTINEL="$SANDBOX/sentinel.hit"
: > "$SENTINEL"
cat > "$RELOC/scripts/lib/refresh-wait.sh" <<SENTINEL_SH
# Test sentinel standing in for the real shared file: records that THIS copy
# was sourced, then provides a harmless stub.
printf '%s' "hit" >> "${SENTINEL}"
dispatch_refresh_and_wait() { return 0; }
SENTINEL_SH
chmod +x "$RELOC/ops-scripts/register-client"

if [[ ! -f "$RELOC/ops-scripts/register-client" ]]; then
    bad "S4. 無法建立搬移後的副本（harness 問題）"
else
    # --help stops before any network use; the source line runs regardless.
    SENTINEL="$SENTINEL" HOME="$SANDBOX/home" PATH="$SANDBOX/fakebin:$PATH" \
        $TIMEOUT bash "$RELOC/ops-scripts/register-client" --help \
        </dev/null >"$SANDBOX/s4.out" 2>&1
    if [[ -s "$SENTINEL" ]]; then
        ok "S4. 搬移後 source 到的是自身旁邊的共用檔（路徑由 SCRIPT_DIR 推導）"
    else
        bad "S4. 搬移後沒 source 到自身旁邊的共用檔——路徑不是由自身位置推導（$(head -c 160 "$SANDBOX/s4.out")）"
    fi
fi

# S5: the extraction must not silently break a caller's dispatch. The shared
# waiter reads GH_REPO; register-client defines REPO (POOL_REPO). If the two
# never meet, register-client reaches the waiter and the waiter immediately
# errors "GH_REPO is not set" WITHOUT ever calling `gh workflow run` — so no
# refresh happens at all, and the caller's WARN makes it look intended.
# Behavioral check: run register-client with a fake gh and require that a
# `workflow run` reached gh.
echo "S5. register-client 真的派發 refresh（共用函式拿得到 repo）:"
if [[ ! -f "ops-scripts/register-client" ]]; then
    bad "S5. register-client 不存在"
else
    S5BIN="$SANDBOX/s5bin"
    rm -rf "$S5BIN"; mkdir -p "$S5BIN" "$SANDBOX/s5-home" "$SANDBOX/s5-stdin" "$SANDBOX/s5-tmp"
    : > "$SANDBOX/s5-argv.log"
    # Fake gh: records calls; answers the var write and (if reached) the
    # run list/view the waiter uses. --jq is applied like real gh.
    cat > "$S5BIN/gh" <<'S5GH'
#!/usr/bin/env bash
printf 'gh|%s\n' "$*" >> "${S5_ARGV_LOG:?}"
if [[ ! -t 0 ]]; then cat >/dev/null; fi
_f=""; _p=""
for _a in "$@"; do [[ "$_p" == "--jq" ]] && _f="$_a"; _p="$_a"; done
case "${1:-}" in
    api) printf '%s\n' '{}' ;;
    variable) : ;;
    workflow) : ;;
    run)
        _j='{"databaseId":1,"status":"completed","conclusion":"success"}'
        if [[ "${2:-}" == "list" ]]; then _j="[$_j]"; fi
        if [[ -n "$_f" ]]; then printf '%s' "$_j" | jq -r "$_f"; else printf '%s\n' "$_j"; fi ;;
esac
exit 0
S5GH
    chmod +x "$S5BIN/gh"
    for tool in whoami hostname uname id sleep; do
        printf '#!/usr/bin/env bash\ncase "${1:-}" in -n|-un) printf "TestHost";; *) printf "501";; esac\n' > "$S5BIN/$tool"
        chmod +x "$S5BIN/$tool"
    done
    S5_TREE="$SANDBOX/s5-repo"
    rm -rf "$S5_TREE"
    mkdir -p "$S5_TREE"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude '.git' ./ "$S5_TREE/" 2>/dev/null
    else
        cp -R . "$S5_TREE/" 2>/dev/null
    fi
    HOME="$SANDBOX/s5-home" TMPDIR="$SANDBOX/s5-tmp" \
    PATH="$S5BIN:$PATH" USER=TestUser GH_TOKEN=fake \
    S5_ARGV_LOG="$SANDBOX/s5-argv.log" STDIN_DIR="$SANDBOX/s5-stdin" \
    $TIMEOUT bash "$S5_TREE/ops-scripts/register-client" --name s5client \
        </dev/null >"$SANDBOX/s5.out" 2>&1
    if grep -q 'workflow run' "$SANDBOX/s5-argv.log" 2>/dev/null; then
        ok "S5. register-client 的呼叫真的觸發了 gh workflow run"
    else
        s5_reason="$(grep -E 'ERROR|WARN' "$SANDBOX/s5.out" 2>/dev/null | head -1)"
        bad "S5. register-client 沒有觸發任何 workflow run——共用函式拿不到 repo（${s5_reason:0:140}）"
    fi
fi


GHFAKE_LOG="$SANDBOX/gh.log"
: > "$GHFAKE_LOG"

T2_STATE="$SANDBOX/gh-state"

# run_refresh_wait <status_seq> <conclusion> <dispatch_mode> <watch_secs> [timeout_arg] [poll_interval]
# Returns the function's exit code; combined stdout+stderr lands in
# T2_OUT/T2_ERR so "timeout" vs "failure" wording can be told apart.
#
# poll_interval is exported as POOL_REFRESH_POLL_INTERVAL: production
# defaults to 5s, which would make the R1 state sequence take ~10s and the
# outer timeout (30s) the thing that ends the run. Fast cases pass 0 (the
# implementation's `sleep 0` is a no-op); R3, which must genuinely time out,
# passes 1 and a 1-second function timeout instead.
T2_RC=0; T2_OUT=""; T2_ERR=""
run_refresh_wait() {
    local seq="$1" concl="$2" dispatch="$3" watch="$4" timeout_arg="${5:-}" poll="${6:-1}"
    : > "$GHFAKE_LOG"
    rm -rf "$T2_STATE"; mkdir -p "$T2_STATE"
    printf '0' > "$T2_STATE/next.idx"
    T2_RC=0; T2_OUT=""; T2_ERR=""
    local wait_file="${WAIT_FILE:-${WAIT_DEFS%%$'\n'*}}"
    if [[ -z "$wait_file" || ! -f "$wait_file" ]]; then
        T2_RC=127
        T2_ERR="<no file defining dispatch_refresh_and_wait found>"
        MISSING_WAITER=1
        return 127
    fi
    MISSING_WAITER=0
    local -a args=()
    [[ -n "$timeout_arg" ]] && args=("$timeout_arg")
    HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmp" \
    PATH="$SANDBOX/fakebin:$PATH" \
    GH_REPO="testowner/testrepo" \
    POOL_REFRESH_POLL_INTERVAL="$poll" \
    FAKE_GH_LOG="$GHFAKE_LOG" FAKE_GH_STATE_DIR="$T2_STATE" \
    FAKE_GH_STATUS_SEQ="$seq" FAKE_GH_CONCLUSION="$concl" \
    FAKE_GH_DISPATCH_MODE="$dispatch" FAKE_GH_WATCH_SECS="$watch" \
    FAKE_GH_RUN_ID=35047640983 \
    $TIMEOUT bash -c '
        source "$1" >/dev/null 2>&1 || true
        source "$2" >/dev/null 2>&1
        if ! declare -F dispatch_refresh_and_wait >/dev/null 2>&1; then
            printf "%s" "<undefined function: dispatch_refresh_and_wait>" >&2
            exit 127
        fi
        dispatch_refresh_and_wait ${3:+"$3"}
    ' _ "$LOG_LIB" "$wait_file" "${timeout_arg:-}" \
        </dev/null > "$SANDBOX/t2.out" 2> "$SANDBOX/t2.err"
    T2_RC=$?
    if [[ "$T2_RC" -eq 127 && "$(cat "$SANDBOX/t2.err" 2>/dev/null)" == *"undefined function"* ]]; then
        MISSING_WAITER=1
    fi
    T2_OUT="$(cat "$SANDBOX/t2.out")"
    T2_ERR="$(cat "$SANDBOX/t2.err")"
    return "$T2_RC"
}

t2_report() {
    local label="$1" want_desc="$2" rc="$3" msg="$4"
    ok "$label"
}

t2_fail() {
    printf '  FAIL  %s (%s)\n' "$1" "$2"
    fail=$((fail + 1))
}

# R1: queued -> in_progress -> completed/success must return 0. The
# in_progress observation must NOT be treated as "finished".
run_refresh_wait "queued,in_progress,completed" success ok 30 30 0 || true
if [[ "${MISSING_WAITER:-1}" -eq 1 ]]; then
    t2_fail "R1. queued→in_progress→completed/success 回 0" "函式不存在"
else
    if [[ "$T2_RC" -eq 0 ]]; then
        ok "R1. queued→in_progress→completed/success 回 0（in_progress 未被誤判為完成）"
    else
        t2_fail "R1. queued→in_progress→completed/success 回 0" \
            "rc=${T2_RC}; $(printf '%s %s' "$T2_OUT" "$T2_ERR" | tr '\n' ' ' | head -c 200)"
    fi
fi

# R1b: an early exit on in_progress leaves no conclusion — the fake reports
# the empty value the real gh reported, so this also documents the bug shape.
run_refresh_wait "in_progress,completed" success ok 30 30 0 || true
if [[ "${MISSING_WAITER:-1}" -eq 1 ]]; then
    t2_fail "R1b. 首見即 in_progress 仍等到 completed" "函式不存在"
elif [[ "$T2_RC" -eq 0 ]]; then
    ok "R1b. 首見即 in_progress 仍等到 completed（回 0）"
else
    t2_fail "R1b. 首見即 in_progress 仍等到 completed" "rc=${T2_RC}; $(printf '%s %s' "$T2_OUT" "$T2_ERR" | tr '\n' ' ' | head -c 200)"
fi

# R2: completed/failure → non-zero.
run_refresh_wait "queued,completed" failure ok 30 30 0 || true
if [[ "${MISSING_WAITER:-1}" -eq 1 ]]; then
    t2_fail "R2. completed/failure 回非 0" "函式不存在"
elif [[ "$T2_RC" -ne 0 ]]; then
    ok "R2. completed/failure 回非 0"
else
    t2_fail "R2. completed/failure 回非 0" "rc=0"
fi

# R3: never completes → non-zero, and the message says TIMEOUT (not failure).
# This case must genuinely time out: poll interval stays 1 (not 0, so the
# deadline is actually respected between polls) and the function's own
# timeout is 1 second with a status sequence that never reaches completed.
run_refresh_wait "queued,in_progress,in_progress,in_progress" success ok 30 1 1 || true
T2_MSG="$(printf '%s %s' "$T2_OUT" "$T2_ERR" | tr '\n' ' ')"
if [[ "${MISSING_WAITER:-1}" -eq 1 ]]; then
    t2_fail "R3. 逾時回非 0" "函式不存在"
    t2_fail "R3. 逾時訊息看得出是逾時" "函式不存在"
else
    if [[ "$T2_RC" -ne 0 ]]; then
        ok "R3. 逾時回非 0（rc=${T2_RC}）"
    else
        t2_fail "R3. 逾時回非 0" "rc=0"
    fi
    if printf '%s' "$T2_MSG" | grep -Eqi 'timeout|timed out|逾時'; then
        ok "R3. 逾時訊息看得出是逾時（$(printf '%s' "$T2_MSG" | tr '\n' ' ' | head -c 120)）"
    else
        t2_fail "R3. 逾時訊息看得出是逾時" "訊息：[$(printf '%s' "$T2_MSG" | head -c 160)]"
    fi
    # Distinguishability: the timeout message must not be the failure wording.
    if printf '%s' "$T2_MSG" | grep -Eqi "conclusion"; then
        # Reporting a conclusion at all when none was ever produced means the
        # timeout path was conflated with the failure path.
        t2_fail "R3. 逾時與失敗訊息可區分" "逾時卻報了 conclusion：[$(printf '%s' "$T2_MSG" | head -c 160)]"
    else
        ok "R3. 逾時與失敗訊息可區分（逾時路徑未報 conclusion）"
    fi
    # The timeout must have actually been reached, not merely some non-zero
    # exit: R3's message has to name the timeout window.
    if printf '%s' "$T2_MSG" | grep -Eq '1s|1 s|1 seconds?'; then
        ok "R3. 訊息指出逾時的門檻（1s），可與其他失敗區分"
    else
        t2_fail "R3. 訊息指出逾時的門檻（1s）" "訊息：[$(printf '%s' "$T2_MSG" | head -c 160)]"
    fi
fi

# R4: dispatch itself fails → non-zero, and no waiting happens (no run
# list/view/watch call may follow).
: > "$GHFAKE_LOG"; run_refresh_wait "queued,completed" success fail 30 30 0 || true
if [[ "${MISSING_WAITER:-1}" -eq 1 ]]; then
    t2_fail "R4. 派發失敗回非 0" "函式不存在"
    t2_fail "R4. 派發失敗不進入等待" "函式不存在"
else
    if [[ "$T2_RC" -ne 0 ]]; then
        ok "R4. 派發失敗回非 0"
    else
        t2_fail "R4. 派發失敗回非 0" "rc=0"
    fi
    if grep -q 'workflow run' "$GHFAKE_LOG" 2>/dev/null; then
        ok "R4. 有嘗試派發（前提成立）"
        if grep -Eq 'run (list|view|watch)' "$GHFAKE_LOG" 2>/dev/null; then
            t2_fail "R4. 派發失敗不進入等待" \
                "派發失敗後仍有等待呼叫：$(grep -E 'run (list|view|watch)' "$GHFAKE_LOG" | head -1)"
        else
            ok "R4. 派發失敗不進入等待（沒有 run list/view/watch）"
        fi
    else
        t2_fail "R4. 有嘗試派發（前提成立）" "gh 未收到 workflow run：[$(head -2 "$GHFAKE_LOG" | tr '\n' ' ')]"
    fi
fi

# R5: the workflow step must call the function now, not carry its own poll.
# This is the point of the extraction: YAML-embedded logic is what broke.
if [[ -f "$CREATE_WF" ]] && python3 -c 'import yaml' >/dev/null 2>&1; then
    wf_call="$(python3 - "$CREATE_WF" <<'PY' 2>/dev/null
import json, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["create"]["steps"]
for i, s in enumerate(steps):
    blob = json.dumps(s, default=str)
    if "refresh-authorized-keys" in blob:
        body = s.get("run", "") or ""
        has_call = "dispatch_refresh_and_wait" in body
        has_own_poll = "run list" in body or "run view" in body
        print(json.dumps({"index": i, "has_call": has_call, "has_own_poll": has_own_poll}))
        break
PY
)"
    if [[ -z "$wf_call" ]]; then
        t2_fail "R5. workflow 那步改呼叫 dispatch_refresh_and_wait" "找不到 refresh 步驟"
    elif jq -e '.has_call == true' >/dev/null 2>&1 <<<"$wf_call"; then
        ok "R5. workflow 那步有呼叫 dispatch_refresh_and_wait"
        if jq -e '.has_own_poll == false' >/dev/null 2>&1 <<<"$wf_call"; then
            ok "R5b. workflow 不再自己輪詢（沒有 run list/view）"
        else
            t2_fail "R5b. workflow 不再自己輪詢" "步驟內仍有 run list/view"
        fi
    else
        t2_fail "R5. workflow 那步改呼叫 dispatch_refresh_and_wait" \
            "步驟 $(jq -r '.index' <<<"$wf_call") 沒有呼叫它"
    fi
else
    t2_fail "R5. workflow 那步改呼叫 dispatch_refresh_and_wait" "workflow 不存在或 YAML 不可用"
    t2_fail "R5b. workflow 不再自己輪詢" "workflow 不存在或 YAML 不可用"
fi

# ---------------------------------------------------------------------------
# T2 injection: rewrite the waiter's completion condition back to the buggy
# `!= "queued"` shape and show R1 reddens. The mutation is text-level on a
# copy, so it exercises whatever the implementer actually wrote.
# ---------------------------------------------------------------------------
echo "injection (refresh waiter):"
# Mutate the SHARED file's completion condition back to the historical
# `status != "queued"` shape and show R1 reddens. Two mutation styles so the
# injection does not depend on how the implementer spelled the comparison.
T2_INJ="$SANDBOX/refresh-wait-inj.sh"
INJ_SRC_FILE=""
if [[ -n "${WAIT_DEFS:-}" ]]; then
    INJ_SRC_FILE="$(printf '%s\n' "$WAIT_DEFS" | head -1)"
fi
T2_INJ_OK=0
if [[ -n "$INJ_SRC_FILE" && -f "$INJ_SRC_FILE" ]]; then
    python3 - "$INJ_SRC_FILE" "$T2_INJ" <<'PY'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^[a-z_]*dispatch_refresh_and_wait\s*\(\)\s*\{', src, re.M)
if not m:
    sys.exit(1)

rest = src[m.end():]
endm = re.search(r'\n\}', rest)
body = rest[:endm.start()] if endm else rest

# Style 1: the condition compares against "completed" -> flip it so the
# loop leaves as soon as the run is not queued (the historical bug).
mutated = re.sub(r'"completed"', '"in_progress"', body)
mutated = re.sub(r"'completed'", "'in_progress'", mutated)

# Style 2: no "completed" literal — force the buggy filter explicitly by
# breaking out on anything that is not queued.
if mutated == body:
    mutated = re.sub(
        r'if \[\[ "\$status" == "[^"]*" \]\]; then(\s*\n\s*break)',
        'if [[ "$status" != "queued" ]]; then\1',
        mutated, count=1)

out = src[:m.end()] + mutated + rest[endm.start():] if endm else src[:m.end()] + mutated
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
    if [[ -s "$T2_INJ" ]] && ! cmp -s "$INJ_SRC_FILE" "$T2_INJ" && bash -n "$T2_INJ" 2>/dev/null; then
        T2_INJ_OK=1
    fi
fi

if [[ "$T2_INJ_OK" -eq 1 ]]; then
    # Same scenario as R1, against the mutated copy. The fast poll interval
    # is essential here: without it the mutant would simply time out at the
    # outer 30s bound for the same timing reason R1's first run did, and the
    # injection would prove nothing about the completion condition.
    : > "$GHFAKE_LOG"
    rm -rf "$T2_STATE"; mkdir -p "$T2_STATE"; printf '0' > "$T2_STATE/next.idx"
    HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmp" PATH="$SANDBOX/fakebin:$PATH" \
    GH_REPO="testowner/testrepo" \
    POOL_REFRESH_POLL_INTERVAL=0 \
    FAKE_GH_LOG="$GHFAKE_LOG" FAKE_GH_STATE_DIR="$T2_STATE" \
    FAKE_GH_STATUS_SEQ="queued,in_progress,completed" FAKE_GH_CONCLUSION=success \
    FAKE_GH_DISPATCH_MODE=ok FAKE_GH_WATCH_SECS=30 FAKE_GH_RUN_ID=35047640983 \
    timeout 30 bash -c '
        source "$1" >/dev/null 2>&1
        source "$2" >/dev/null 2>&1
        dispatch_refresh_and_wait 10
    ' _ "$LOG_LIB" "$T2_INJ" </dev/null > "$SANDBOX/inj.out" 2>&1
    INJ_RC=$?
    INJ_MSG="$(tr '\n' ' ' < "$SANDBOX/inj.out")"
    # The mutant must fail for the RIGHT reason: an early exit on in_progress
    # leaves no conclusion, so it reports the empty/'<unknown>' value — the
    # exact 2026-09-16 symptom. Exiting non-zero for some unrelated reason
    # (missing GH_REPO, outer timeout) would not demonstrate anything.
    if [[ "$INJ_RC" -eq 124 ]]; then
        inj_bad "注入後外層 timeout（124）——注入情境的輪詢沒跑起來，無從證明"
    elif [[ "$INJ_RC" -eq 0 ]]; then
        inj_bad "注入後 R1 情境仍回 0——R1 擋不住這個 bug"
    elif printf '%s' "$INJ_MSG" | grep -Eq "conclusion|<unknown>"; then
        inj_ok "把等待條件改回「離開 queued 就算完成」後，R1 的相同情境回非 0 且報出 <unknown>（rc=${INJ_RC}；${INJ_MSG:0:120}）——R1 條擋得住這個 bug"
    else
        inj_bad "注入後回非 0，但不是結論誤判的症狀（訊息：${INJ_MSG:0:140}）——證明不了 R1"
    fi
else
    # Positive control while the real function does not exist yet: drive the
    # same scenario through a reference implementation (correct) and through
    # the historical buggy shape, proving R1's check discriminates.
    cat > "$SANDBOX/ref-correct.sh" <<'REF'
dispatch_refresh_and_wait() {
    local timeout_secs="${1:-5}"
    local poll_interval="${POOL_REFRESH_POLL_INTERVAL:-1}"
    gh workflow run refresh-authorized-keys.yml --repo r >/dev/null 2>&1 || return 1
    local deadline=$(( $(date +%s) + timeout_secs )) run_id="" status=""
    while :; do
        run_id="$(gh run list --workflow=refresh-authorized-keys.yml --repo r --limit 1 --json databaseId,status --jq '.[0] | select(.status == "completed") | .databaseId' 2>/dev/null || true)"
        [[ -n "$run_id" ]] && break
        status="$(gh run list --workflow=refresh-authorized-keys.yml --repo r --limit 1 --json status --jq '.[0].status' 2>/dev/null || true)"
        if (( $(date +%s) >= deadline )); then
            if [[ "$status" == "completed" ]]; then
                :
            else
                printf 'timeout: refresh run did not complete in %ss\n' "$timeout_secs" >&2
                return 1
            fi
        fi
        sleep "$poll_interval"
    done
    local c
    c="$(gh run view "$run_id" --repo r --json conclusion --jq '.conclusion' 2>/dev/null || true)"
    [[ "$c" == "success" ]] || { printf 'failure: conclusion=%s\n' "${c:-<unknown>}" >&2; return 1; }
    return 0
}
REF
    cat > "$SANDBOX/ref-buggy.sh" <<'REF'
dispatch_refresh_and_wait() {
    local timeout_secs="${1:-5}"
    local poll_interval="${POOL_REFRESH_POLL_INTERVAL:-1}"
    gh workflow run refresh-authorized-keys.yml --repo r >/dev/null 2>&1 || return 1
    local deadline=$(( $(date +%s) + timeout_secs )) run_id=""
    while :; do
        run_id="$(gh run list --workflow=refresh-authorized-keys.yml --repo r --limit 1 --json databaseId,status --jq '.[0] | select(.status != "queued") | .databaseId' 2>/dev/null || true)"
        [[ -n "$run_id" ]] && break
        if (( $(date +%s) >= deadline )); then
            printf 'timeout: refresh run did not complete in %ss\n' "$timeout_secs" >&2
            return 1
        fi
        sleep 1
    done
    local c
    c="$(gh run view "$run_id" --repo r --json conclusion --jq '.conclusion' 2>/dev/null || true)"
    [[ "$c" == "success" ]] || { printf 'failure: conclusion=%s\n' "${c:-<unknown>}" >&2; return 1; }
    return 0
}
REF
    t2_probe() {
        local impl="$1"
        : > "$GHFAKE_LOG"
        rm -rf "$T2_STATE"; mkdir -p "$T2_STATE"; printf '0' > "$T2_STATE/next.idx"
        HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmp" PATH="$SANDBOX/fakebin:$PATH" \
        POOL_REFRESH_POLL_INTERVAL=0 \
        FAKE_GH_LOG="$GHFAKE_LOG" FAKE_GH_STATE_DIR="$T2_STATE" \
        FAKE_GH_STATUS_SEQ="queued,in_progress,completed" FAKE_GH_CONCLUSION=success \
        FAKE_GH_WATCH_SECS=30 FAKE_GH_RUN_ID=35047640983 \
        timeout 30 bash -c 'source "$1" >/dev/null 2>&1; dispatch_refresh_and_wait 3' \
            _ "$impl" </dev/null > "$SANDBOX/probe.out" 2>&1
        return $?
    }
    if t2_probe "$SANDBOX/ref-correct.sh"; then
        inj_ok "正向控制：正確的等待（等到 completed）在 R1 情境回 0"
    else
        inj_bad "正向控制失敗（checker/harness 壞了）：$(tr '\n' ' ' < "$SANDBOX/probe.out" | head -c 160)"
    fi
    if t2_probe "$SANDBOX/ref-buggy.sh"; then
        inj_bad "歷史 bug 形狀（!= queued）在 R1 情境竟回 0——R1 擋不住"
    else
        inj_ok "歷史 bug 形狀（!= queued）在 R1 情境回非 0（$(tr '\n' ' ' < "$SANDBOX/probe.out" | head -c 100)）——R1 判別得出來"
    fi
fi

echo
printf 'test-worker-tunnel-key: %d passed, %d failed\n' "$pass" "$fail"
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0