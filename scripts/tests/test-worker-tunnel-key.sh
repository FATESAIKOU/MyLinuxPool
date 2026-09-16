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
# Injection demo at the end: the same order checker is run against a copy
# with the two steps swapped, and must go red.
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
# Harness: intercept mktemp (so leftover temp files are observable) and
# ssh-keygen (so child argv is recorded). Both forward to the real tools.
# ---------------------------------------------------------------------------
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

echo
printf 'test-worker-tunnel-key: %d passed, %d failed\n' "$pass" "$fail"
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
