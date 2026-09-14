#!/usr/bin/env bash
# test-pool-resolve.sh — hermetic tests for shared_config/pool-runtime's pool-resolve
# spec: docs/POOL_RUNTIME_SPEC.md §1
#
# Hermetic strategy: a fake `gh` is placed first on PATH. pool-resolve only
# ever calls `gh api repos/<repo>/actions/variables/<VAR> --jq .value`, so the
# fake serves the fixture file $FAKE_GH_DIR/<VAR>.json, or simulates 404 /
# auth failure. Every case gets its own HOME (cache lives in
# $HOME/.mylinuxpool/cache) so cases cannot contaminate each other.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POOL_RESOLVE="${REPO_ROOT}/shared_config/pool-runtime/files/pool-resolve"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi
if [[ ! -x "$POOL_RESOLVE" ]]; then
    echo "ERROR: ${POOL_RESOLVE} is not executable" >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-pool-resolve.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

FAKE_BIN="${TMP_ROOT}/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Minimal `gh` stand-in for pool-resolve tests.
[[ -n "${FAKE_GH_CALLS:-}" ]] && printf '1\n' >> "$FAKE_GH_CALLS"
url=""
for a in "$@"; do
    case "$a" in
        *actions/variables/*) url="$a" ;;
    esac
done
var="${url##*/}"
case "${FAKE_GH_MODE:-fixtures}" in
    fixtures)
        f="${FAKE_GH_DIR:-}/${var}.json"
        if [[ -f "$f" ]]; then
            cat "$f"
            exit 0
        fi
        echo "gh: HTTP 404: Not Found (variable ${var})" >&2
        exit 1
        ;;
    success)
        json="${FAKE_GH_JSON-}"
        [[ -n "$json" ]] || json='{}'
        printf '%s\n' "$json"
        exit 0
        ;;
    notfound)
        echo "gh: HTTP 404: Not Found (variable ${var})" >&2
        exit 1
        ;;
    authfail)
        echo "gh: authentication failed: could not resolve host api.github.com" >&2
        exit 1
        ;;
    *)
        echo "gh: unexpected fake mode '${FAKE_GH_MODE:-}'" >&2
        exit 99
        ;;
esac
FAKE_GH
chmod +x "${FAKE_BIN}/gh"
export PATH="${FAKE_BIN}:${PATH}"

PASS=0
TOTAL=0
FAILED=0

new_home() {
    local h="${TMP_ROOT}/home-$1"
    mkdir -p "${h}/.mylinuxpool/cache" "${h}/fixtures"
    printf '%s' "$h"
}

seed_fixture() {
    local home="$1" name="$2" json="$3"
    printf '%s' "$json" > "${home}/fixtures/NODE_${name}.json"
}

CASE_OUT="" CASE_ERR="" CASE_RC=0
run_pool() {
    local home="$1"; shift
    CASE_OUT="$(HOME="$home" "$POOL_RESOLVE" "$@" 2>"${home}/.stderr")"
    CASE_RC=$?
    CASE_ERR="$(tr '\n' ' ' < "${home}/.stderr" 2>/dev/null || true)"
}

note=""
reset_note() { note=""; }
expect_rc() { [[ "$CASE_RC" -eq "$1" ]] || note="${note}rc=${CASE_RC}（期望 $1）; "; }
expect_eq() { [[ "$1" == "$2" ]] || note="${note}$3=[$1]（期望 [$2]）; "; }
expect_grep() { printf '%s' "$1" | grep -q "$2" || note="${note}$3（找不到 '$2'）; "; }
expect_jq() { printf '%s' "$1" | jq empty >/dev/null 2>&1 || note="${note}$2; "; }

check() {
    local num="$1" desc="$2"
    TOTAL=$((TOTAL + 1))
    if [[ -z "$note" ]]; then
        PASS=$((PASS + 1))
        echo "PASS ${num} ${desc}"
    else
        FAILED=$((FAILED + 1))
        echo "FAIL ${num} ${desc}：${note}"
    fi
}

# ---------------------------------------------------------------------------
# Case 1: normal full JSON fetch -> exit 0, parseable JSON
# ---------------------------------------------------------------------------
H="$(new_home 1)"; export FAKE_GH_MODE=success; unset FAKE_GH_DIR FAKE_GH_CALLS
export FAKE_GH_JSON='{"ip":"10.0.0.1","port":22,"user":"alice","key_secret":"SECRET_A"}'
run_pool "$H" node1; reset_note
expect_rc 0
expect_jq "$CASE_OUT" "輸出不是合法 JSON"
expect_eq "$(printf '%s' "$CASE_OUT" | jq -r '.ip' 2>/dev/null)" "10.0.0.1" "ip"
check 1 "正常取完整 JSON"

# ---------------------------------------------------------------------------
# Case 2: --field .ip -> raw value, no quotes
# ---------------------------------------------------------------------------
H="$(new_home 2)"; export FAKE_GH_MODE=success
export FAKE_GH_JSON='{"ip":"10.0.0.1","port":22,"user":"alice","key_secret":"SECRET_A"}'
run_pool "$H" node1 --field .ip; reset_note
expect_rc 0
expect_eq "$CASE_OUT" "10.0.0.1" "輸出"
check 2 "--field .ip 取單一欄位（純值無引號）"

# ---------------------------------------------------------------------------
# Case 3: var missing (404) -> exit 3
# ---------------------------------------------------------------------------
H="$(new_home 3)"; export FAKE_GH_MODE=notfound; unset FAKE_GH_DIR FAKE_GH_CALLS
run_pool "$H" missing; reset_note
expect_rc 3
check 3 "var 不存在（404）→ 退出碼 3"

# ---------------------------------------------------------------------------
# Case 4: auth/network failure, no cache -> exit 4
# ---------------------------------------------------------------------------
H="$(new_home 4)"; export FAKE_GH_MODE=authfail
run_pool "$H" node1; reset_note
expect_rc 4
check 4 "gh 認證/網路失敗且無快取 → 退出碼 4"

# ---------------------------------------------------------------------------
# Case 5: gh failure WITH cache -> exit 0, stale cache, WARN on stderr
# ---------------------------------------------------------------------------
H="$(new_home 5)"
export FAKE_GH_MODE=success
export FAKE_GH_JSON='{"ip":"10.0.0.1","port":22,"user":"alice","key_secret":"SECRET_A"}'
run_pool "$H" node1                       # warm the cache
export FAKE_GH_MODE=authfail
run_pool "$H" node1 --refresh             # live read fails -> stale cache
reset_note
expect_rc 0
expect_eq "$(printf '%s' "$CASE_OUT" | jq -r '.ip' 2>/dev/null)" "10.0.0.1" "快取 ip"
expect_grep "$CASE_ERR" "WARN" "stderr 缺 WARN"
check 5 "gh 失敗但有快取 → 用過期快取且 WARN"

# ---------------------------------------------------------------------------
# Case 6: second call within TTL does not call gh
# ---------------------------------------------------------------------------
H="$(new_home 6)"
export FAKE_GH_MODE=success
export FAKE_GH_JSON='{"ip":"10.0.0.1","port":22,"user":"alice","key_secret":"SECRET_A"}'
export FAKE_GH_CALLS="${TMP_ROOT}/calls-6"; : > "$FAKE_GH_CALLS"
run_pool "$H" node1                       # first call -> 1 gh call
run_pool "$H" node1                       # second call -> cache hit
reset_note
expect_rc 0
expect_eq "$(wc -l < "$FAKE_GH_CALLS" | tr -d ' ')" "1" "gh 呼叫次數"
check 6 "快取 TTL 內第二次呼叫不再呼叫 gh"

# ---------------------------------------------------------------------------
# Case 7: --refresh calls gh even with a fresh cache
# ---------------------------------------------------------------------------
H="$(new_home 7)"
export FAKE_GH_MODE=success
export FAKE_GH_JSON='{"ip":"10.0.0.1","port":22,"user":"alice","key_secret":"SECRET_A"}'
export FAKE_GH_CALLS="${TMP_ROOT}/calls-7"; : > "$FAKE_GH_CALLS"
run_pool "$H" node1                       # first call -> 1 gh call
run_pool "$H" node1 --refresh             # forced  -> 2 gh calls
reset_note
expect_rc 0
expect_eq "$(wc -l < "$FAKE_GH_CALLS" | tr -d ' ')" "2" "gh 呼叫次數"
check 7 "--refresh 即使快取新鮮仍呼叫 gh"

# ---------------------------------------------------------------------------
# Case 8: --expand-hops recursion through {via:X} where X has its own hops
# ---------------------------------------------------------------------------
H="$(new_home 8)"; export FAKE_GH_MODE=fixtures; export FAKE_GH_DIR="${H}/fixtures"
unset FAKE_GH_CALLS
seed_fixture "$H" B '{"ip":"10.0.0.3","port":2200,"user":"bob","key_secret":"SECRET_B","hops":[{"host":"jump1","port":22,"user":"u1","key_secret":"S1"}]}'
seed_fixture "$H" A '{"ip":"10.0.0.2","port":22,"user":"ann","key_secret":"SECRET_A","hops":[{"via":"b"},{"host":"direct","port":23,"user":"u2","key_secret":"S2"}]}'
run_pool "$H" a --expand-hops; reset_note
expect_rc 0
expect_eq "$(printf '%s' "$CASE_OUT" | jq 'length' 2>/dev/null)" "2" "hop 數"
expect_eq "$(printf '%s' "$CASE_OUT" | jq -r '.[0].host' 2>/dev/null)" "jump1" "hop[0].host（遞迴展開）"
expect_eq "$(printf '%s' "$CASE_OUT" | jq -r '.[1].host' 2>/dev/null)" "direct" "hop[1].host（原樣保留）"
check 8 "--expand-hops：{via:X} 且 X 有 hops → 遞迴展開"

# ---------------------------------------------------------------------------
# Case 9: base case — X has no hops; hop is synthesized, user from .user
# ---------------------------------------------------------------------------
H="$(new_home 9)"; export FAKE_GH_MODE=fixtures; export FAKE_GH_DIR="${H}/fixtures"
seed_fixture "$H" GW '{"ip":"10.0.0.9","user":"mgmt","tunnel_user":"tunnel","key_secret":"SECRET_GW"}'
seed_fixture "$H" A '{"ip":"10.0.0.2","user":"ann","key_secret":"SECRET_A","hops":[{"via":"gw"}]}'
run_pool "$H" a --expand-hops; reset_note
expect_rc 0
expect_eq "$(printf '%s' "$CASE_OUT" | jq 'length' 2>/dev/null)" "1" "hop 數"
expect_eq "$(printf '%s' "$CASE_OUT" | jq -r '.[0].host' 2>/dev/null)" "10.0.0.9" "host"
expect_eq "$(printf '%s' "$CASE_OUT" | jq -r '.[0].port' 2>/dev/null)" "22" "port（預設 22）"
expect_eq "$(printf '%s' "$CASE_OUT" | jq -r '.[0].user' 2>/dev/null)" "mgmt" "user（不可用 tunnel_user）"
expect_eq "$(printf '%s' "$CASE_OUT" | jq -r '.[0].key_secret' 2>/dev/null)" "SECRET_GW" "key_secret"
check 9 "--expand-hops base case：X 無 hops → 合成終端 hop（user 為 .user）"

# ---------------------------------------------------------------------------
# Case 10: requested node itself has no hops -> single synthesized hop
# ---------------------------------------------------------------------------
H="$(new_home 10)"; export FAKE_GH_MODE=fixtures; export FAKE_GH_DIR="${H}/fixtures"
seed_fixture "$H" GW '{"ip":"10.0.0.9","port":2222,"user":"mgmt","tunnel_user":"tunnel","key_secret":"SECRET_GW"}'
run_pool "$H" gw --expand-hops; reset_note
expect_rc 0
expect_eq "$(printf '%s' "$CASE_OUT" | jq 'length' 2>/dev/null)" "1" "hop 數"
expect_eq "$(printf '%s' "$CASE_OUT" | jq -r '.[0].host' 2>/dev/null)" "10.0.0.9" "host"
expect_eq "$(printf '%s' "$CASE_OUT" | jq -r '.[0].port' 2>/dev/null)" "2222" "port"
expect_eq "$(printf '%s' "$CASE_OUT" | jq -r '.[0].user' 2>/dev/null)" "mgmt" "user"
check 10 "--expand-hops：節點自身無 hops → 只含一段合成 hop"

# ---------------------------------------------------------------------------
# Case 11: circular via (A -> B -> A) -> exit 5
# ---------------------------------------------------------------------------
H="$(new_home 11)"; export FAKE_GH_MODE=fixtures; export FAKE_GH_DIR="${H}/fixtures"
seed_fixture "$H" A '{"ip":"10.0.0.2","user":"ann","key_secret":"S","hops":[{"via":"b"}]}'
seed_fixture "$H" B '{"ip":"10.0.0.3","user":"bob","key_secret":"S","hops":[{"via":"a"}]}'
run_pool "$H" a --expand-hops; reset_note
expect_rc 5
check 11 "環狀 via（A→B→A）→ 退出碼 5"

# ---------------------------------------------------------------------------
# Case 12: nesting deeper than 5 -> exit 5
# ---------------------------------------------------------------------------
H="$(new_home 12)"; export FAKE_GH_MODE=fixtures; export FAKE_GH_DIR="${H}/fixtures"
for i in 1 2 3 4 5 6 7 8; do
    if [[ $i -lt 8 ]]; then
        j=$((i + 1))
        seed_fixture "$H" "N${i}" "{\"ip\":\"10.0.0.${i}\",\"user\":\"u\",\"key_secret\":\"S\",\"hops\":[{\"via\":\"n${j}\"}]}"
    else
        seed_fixture "$H" "N${i}" "{\"ip\":\"10.0.0.${i}\",\"user\":\"u\",\"key_secret\":\"S\"}"
    fi
done
run_pool "$H" n1 --expand-hops; reset_note
expect_rc 5
check 12 "深度超過 5 層 → 退出碼 5"

# ---------------------------------------------------------------------------
# Case 13: usage error (no args) -> exit 2
# ---------------------------------------------------------------------------
H="$(new_home 13)"; export FAKE_GH_MODE=success
run_pool "$H"; reset_note
expect_rc 2
expect_grep "$CASE_ERR" "usage" "stderr 缺 usage 訊息"
check 13 "用法錯誤（無參數）→ 退出碼 2"

echo "${PASS}/${TOTAL}"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
