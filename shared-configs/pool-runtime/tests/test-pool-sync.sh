#!/usr/bin/env bash
# test-pool-sync.sh — hermetic black-box tests for
# shared-configs/pool-runtime/files/pool-sync (task D).
#
# The subject is a provider-side convergence script: it re-reads the node's
# declared units and repairs drift in installed files, without ever writing
# new per-machine state (~/.mylinuxpool stays as it is).
#
# Everything external is intercepted with fakes on PATH (git / gh /
# systemctl) and a fake install.sh planted in the "cloned" repo, so this
# runs with no network and no real systemd. The subject does NOT exist yet;
# when it is missing every scenario must FAIL — skipping is not an option.
#
# One line per assertion: "ok" / "FAIL <說明>".
# Summary: "passed N / failed M"; exit non-zero when M > 0.
# Run: shared-configs/pool-runtime/tests/test-pool-sync.sh
set -uo pipefail

UNIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
POOL_SYNC="${UNIT_ROOT}/files/pool-sync"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-pool-sync.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

mkdir -p "$SANDBOX/fakebin" "$SANDBOX/home/.mylinuxpool" "$SANDBOX/tmpdir"
: > "$SANDBOX/check-rc"
: > "$SANDBOX/install-rc"
: > "$SANDBOX/install.log"
: > "$SANDBOX/systemctl.log"
: > "$SANDBOX/git.log"
: > "$SANDBOX/gh.log"
: > "$SANDBOX/gh-payload.log"
: > "$SANDBOX/ssh.log"
: > "$SANDBOX/out"
: > "$SANDBOX/err"
: > "$SANDBOX/combined"

# mktemp 的絕對路徑要在 fakebin 進 PATH 之前先記下來。
REAL_MKTEMP="$(command -v mktemp)"

TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT="timeout 30"
fi

# ---------------------------------------------------------------------------
# Fakes. Each one records what it was asked to do so assertions can inspect
# the calls (and so "nothing happened" cannot be mistaken for success).
# ---------------------------------------------------------------------------

# mktemp 假貨：被測物的暫存目錄一律建在 FAKE_MKTEMP_DIR 底下，這樣測試才
# 能證明 trap 真的清掉了它——macOS 的 mktemp 不理 TMPDIR，只檢查 TMPDIR
# 會讓「不清理」的實作照樣通過。
cat > "$SANDBOX/fakebin/mktemp" <<'FAKE_MKTEMP'
#!/usr/bin/env bash
dir="${FAKE_MKTEMP_DIR:?FAKE_MKTEMP_DIR not set}"
mkdir -p "$dir"
if [[ "${1:-}" == "-d" ]]; then
    exec "$REAL_MKTEMP" -d "${dir}/tmp.XXXXXX"
fi
exec "$REAL_MKTEMP" "${dir}/tmp.XXXXXX"
FAKE_MKTEMP
chmod +x "$SANDBOX/fakebin/mktemp"

cat > "$SANDBOX/fakebin/git" <<'FAKE_GIT'
#!/usr/bin/env bash
dest=""
for a in "$@"; do dest="$a"; done
case "$dest" in /*) ;; *) dest="${PWD}/${dest}" ;; esac
printf 'dest=%s cwd=%s args=%s\n' "$dest" "$PWD" "$*" >> "$FAKE_GIT_LOG"
if [[ "${FAKE_GIT_MODE:-ok}" == "fail" ]]; then
    echo "fatal: unable to access 'https://github.com/${FAKE_GIT_REPO:-x/y}.git/': Could not resolve host: github.com" >&2
    exit 128
fi
mkdir -p "$dest"
cp -R "${FAKE_FIXTURE}/." "$dest/"
FAKE_GIT
chmod +x "$SANDBOX/fakebin/git"

cat > "$SANDBOX/fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ "${FAKE_GH_MODE:-ok}" == "missing" ]]; then
    echo "gh: HTTP 404: Not Found (variable)" >&2
    exit 1
fi
# writefail (task Q §7): reads keep working, writes fail — the shape of a
# GitHub hiccup while the old shared tunnel key still holds the tunnel up.
if [[ "${FAKE_GH_MODE:-ok}" == "writefail" ]]; then
    case "${1:-} ${2:-}" in
        "variable set"|"variable delete"|"workflow run")
            echo "gh: simulated write failure" >&2
            exit 1 ;;
    esac
fi
# Capture the payload piped into `gh variable set` (task Q §3): the JSON
# pool-sync writes must still carry the node's other fields.
if [[ "${1:-}" == "variable" && "${2:-}" == "set" && -n "${FAKE_GH_PAYLOAD_LOG:-}" ]]; then
    printf 'PAYLOAD|%s\n' "$(cat)" >> "$FAKE_GH_PAYLOAD_LOG"
fi
is_list=0
for a in "$@"; do
    case "$a" in
        *actions/variables?per_page=100*|*variables?per_page=100*) is_list=1 ;;
    esac
done
if [[ "$is_list" -eq 1 ]]; then
    # 列舉請求：NODE_TESTNODE（既有）+ 所有 FAKE_CLIENT_VARS 的 CLIENT_*
    list="$(jq -c -n --arg n "NODE_TESTNODE" --arg v "${FAKE_GH_VALUE}" \
        '{variables:[{name:$n,value:$v}]}')"
    if [[ -n "${FAKE_CLIENT_VARS:-}" ]]; then
        list="$(printf '%s' "$list" | jq -c --argjson cv "${FAKE_CLIENT_VARS}" \
            '.variables += [ $cv | to_entries[] | {name:.key, value:(.value|tostring)} ]')"
    fi
    filter=""
    prev=""
    for a in "$@"; do
        [[ "$prev" == "--jq" ]] && filter="$a"
        prev="$a"
    done
    if [[ -n "$filter" ]]; then
        printf '%s' "$list" | jq -r "$filter"
    else
        printf '%s\n' "$list"
    fi
    exit 0
fi
name=""
filter=""
prev=""
for a in "$@"; do
    [[ "$prev" == "--jq" ]] && filter="$a"
    case "$a" in
        *actions/variables/*) name="${a##*/}"; name="${name%%\?*}" ;;
    esac
    case "$a" in
        NODE_*) name="$a" ;;
    esac
    prev="$a"
done
if [[ -n "$name" ]]; then
    if [[ "$name" == CLIENT_* && -n "${FAKE_CLIENT_VARS:-}" ]]; then
        # CLIENT_* 取值：FAKE_CLIENT_VARS 是 name→value 物件（KEY-DESIGN
        # §3.2 的 CLIENT_<NAME> 形狀），gh api 回 value 字串。
        obj="$(printf '%s' "$FAKE_CLIENT_VARS" | jq -c --arg n "$name" \
            '{"name":$n, "value": (.[$n] // empty | tostring)}')"
    else
        obj="$(jq -c -n --arg n "$name" --arg v "${FAKE_GH_VALUE}" '{name:$n,value:$v}')"
    fi
else
    obj="$(jq -c -n --arg n "NODE_TESTNODE" --arg v "${FAKE_GH_VALUE}" '{variables:[{name:$n,value:$v}]}')"
fi
if [[ -n "$filter" ]]; then
    printf '%s' "$obj" | jq -r "$filter"
else
    printf '%s\n' "$obj"
fi
FAKE_GH
chmod +x "$SANDBOX/fakebin/gh"

cat > "$SANDBOX/fakebin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
exit 0
FAKE_SYSTEMCTL
chmod +x "$SANDBOX/fakebin/systemctl"

# Fake install.sh planted into every fixture unit. --check's exit code comes
# from $FAKE_CHECK_RC ("<unit> <rc>" lines); the real install's from
# $FAKE_INSTALL_RC. Both invocations are logged.
cat > "$SANDBOX/fake-install.sh" <<'FAKE_INSTALL'
#!/usr/bin/env bash
unit="$(basename "$(dirname "$0")")"
printf '%s args=%s\n' "$unit" "$*" >> "$FAKE_INSTALL_LOG"
has_check=0
for a in "$@"; do [[ "$a" == "--check" ]] && has_check=1; done
rc_file="$FAKE_INSTALL_RC"
[[ "$has_check" -eq 1 ]] && rc_file="$FAKE_CHECK_RC"
while read -r u rc; do
    if [[ "$u" == "$unit" ]]; then exit "$rc"; fi
done < "$rc_file"
exit 0
FAKE_INSTALL
chmod +x "$SANDBOX/fake-install.sh"

# ---------------------------------------------------------------------------
# Assertions.
# ---------------------------------------------------------------------------
pass=0; fail=0
ok_line()   { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
fail_line() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

SYNC_RC=0
RAN=0

# 負向斷言（「沒有做 X」）在沒有真的執行被測物時必然成立，那會是假通過。
# 因此所有負向／無從觀察的斷言都必須先過這關：RAN=1 代表被測物真的跑過。
need_ran() {
    if [[ "$RAN" -ne 1 ]]; then
        fail_line "$1（被測物沒有真的執行，無從證明）"
        return 1
    fi
    return 0
}

check_rc() {
    local want="$1" d="$2"
    if [[ "$RAN" -ne 1 ]]; then
        fail_line "${d}（被測物沒有真的執行，無從證明；expected exit ${want}）"
        return
    fi
    if [[ "$SYNC_RC" -eq "$want" ]]; then ok_line "$d"
    else fail_line "$d (exit=${SYNC_RC}，期望 ${want})"; fi
}

# grep_ok <file> <ERE> <說明>
grep_ok() {
    local f="$1" pat="$2" d="$3"
    if [[ "$RAN" -ne 1 ]]; then
        fail_line "${d}（被測物沒有真的執行，無從證明）"; return
    fi
    if grep -qE -- "$pat" "$f" 2>/dev/null; then ok_line "$d"
    else fail_line "$d (找不到 '$pat'；內容：$(head -c 200 "$f" 2>/dev/null | tr '\n' ' '))"; fi
}

# grep_no <file> <ERE> <說明> [前提指令]
# 負向斷言一律要求「前提成立」才可能通過，否則就是無從證明的假通過。
grep_no() {
    local f="$1" pat="$2" d="$3" pre="${4:-}"
    need_ran "$d" || return
    if [[ -n "$pre" ]] && ! eval "$pre"; then
        fail_line "${d}（前提不成立，無從證明：${pre}）"; return
    fi
    if grep -qE -- "$pat" "$f" 2>/dev/null; then
        fail_line "$d (不該出現 '$pat'：$(grep -E -- "$pat" "$f" | head -2 | tr '\n' ' '))"
    else
        ok_line "$d"
    fi
}

check_restart() {
    local d="$1"
    need_ran "$d" || return
    if tr '\n' ' ' < "$SANDBOX/systemctl.log" | grep -Eq 'restart.*pool-tunnel|pool-tunnel.*restart'; then
        ok_line "$d"
    else
        fail_line "$d (systemctl 呼叫：$(tr '\n' ' ' < "$SANDBOX/systemctl.log"))"
    fi
}

check_no_restart() {
    local d="$1" pre="${2:-}"
    need_ran "$d" || return
    if [[ -n "$pre" ]] && ! eval "$pre"; then
        fail_line "${d}（前提不成立，無從證明：${pre}）"; return
    fi
    if grep -q 'restart' "$SANDBOX/systemctl.log" 2>/dev/null; then
        fail_line "$d (不該重啟：$(tr '\n' ' ' < "$SANDBOX/systemctl.log"))"
    else
        ok_line "$d"
    fi
}

# ---------------------------------------------------------------------------
# Fixture HOME + fixture repo.
# ---------------------------------------------------------------------------
reset_home() {
    rm -rf "$SANDBOX/home"
    mkdir -p "$SANDBOX/home/.mylinuxpool"
    printf 'NODE_NAME=testnode\n' > "$SANDBOX/home/.mylinuxpool/config"
    printf 'ghp_FAKE_TOKEN_abc123\n' > "$SANDBOX/home/.mylinuxpool/gh_token"
}

units_json() {
    local out="[" sep="" u
    for u in $1; do out="${out}${sep}\"${u}\""; sep=","; done
    printf '%s]' "$out"
}

# build_fixture <default_units> <no-sudo_units> <needs_key_units> [needs_root_units]
# default/no-sudo 決定 profile 會宣告哪些 unit；needs_key_units 與
# needs_root_units 決定那些 unit 的 unit.json 要帶哪個旗標（可重疊）。
build_fixture() {
    local default_units="$1" nosudo_units="$2" needs_key_units="$3" needs_root_units="${4:-}" u nk nr
    rm -rf "$SANDBOX/fixture"
    mkdir -p "$SANDBOX/fixture/profiles/provider/default" \
             "$SANDBOX/fixture/profiles/provider/no-sudo" \
             "$SANDBOX/fixture/shared-configs"
    printf '{"name":"default","role":"provider","shared_config":%s}\n' \
        "$(units_json "$default_units")" > "$SANDBOX/fixture/profiles/provider/default/profile.json"
    printf '{"name":"no-sudo","role":"provider","shared_config":%s}\n' \
        "$(units_json "$nosudo_units")" > "$SANDBOX/fixture/profiles/provider/no-sudo/profile.json"
    for u in $default_units $nosudo_units $needs_key_units $needs_root_units; do
        mkdir -p "$SANDBOX/fixture/shared-configs/$u"
        nk=false; nr=false
        [[ " $needs_key_units " == *" $u "* ]] && nk=true
        [[ " $needs_root_units " == *" $u "* ]] && nr=true
        printf '{"name":"%s","needs_key":%s,"needs_root":%s}\n' "$u" "$nk" "$nr" \
            > "$SANDBOX/fixture/shared-configs/$u/unit.json"
        cp "$SANDBOX/fake-install.sh" "$SANDBOX/fixture/shared-configs/$u/install.sh"
        chmod +x "$SANDBOX/fixture/shared-configs/$u/install.sh"
    done
    # pool-sync 組 authorized_keys 時要 source 的 authkeys.sh：把 repo 現況
    # 放進 fixture 的 scripts/lib/（實作落地後才用得到）。
    if [[ -f scripts/lib/authkeys.sh ]]; then
        mkdir -p "$SANDBOX/fixture/scripts/lib"
        cp scripts/lib/authkeys.sh "$SANDBOX/fixture/scripts/lib/authkeys.sh"
    fi
    # refresh-authkeys.sh 也一樣：brief-O 要求 pool-sync source 它（含
    # refresh_collect_clients），fixture 缺它會讓 authorized_keys 收斂
    # 直接跳過（A1 起全紅）。
    if [[ -f scripts/refresh-authkeys.sh ]]; then
        mkdir -p "$SANDBOX/fixture/scripts"
        cp scripts/refresh-authkeys.sh "$SANDBOX/fixture/scripts/refresh-authkeys.sh"
    fi
}

GIT_MODE="ok"
GH_MODE="ok"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
FAKE_CLIENT_VARS=""

run_sync() {
    : > "$SANDBOX/install.log"; : > "$SANDBOX/systemctl.log"
    : > "$SANDBOX/git.log"; : > "$SANDBOX/gh.log"
    : > "$SANDBOX/gh-payload.log"; : > "$SANDBOX/ssh.log"
    rm -rf "$SANDBOX/tmpdir"; mkdir -p "$SANDBOX/tmpdir"
    SYNC_RC=0; RAN=0
    if [[ ! -x "$POOL_SYNC" ]]; then
        SYNC_RC=127
        printf 'pool-sync missing or not executable: %s\n' "$POOL_SYNC" > "$SANDBOX/err"
        : > "$SANDBOX/out"
    else
        RAN=1
        # POOL_SYNC_SUBJECT 注入點：測試可把被測物換成一個修改版（例如
        # 拿掉自鎖防線、或改成聯集語意的版本）——注入段落用。
        local subject="${POOL_SYNC_SUBJECT:-$POOL_SYNC}"
        HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmpdir" \
        PATH="$SANDBOX/fakebin:$PATH" \
        POOL_REPO="testowner/testrepo" POOL_BRANCH="master" \
        REAL_MKTEMP="$REAL_MKTEMP" FAKE_MKTEMP_DIR="$SANDBOX/tmpdir" \
        FAKE_FIXTURE="$SANDBOX/fixture" \
        FAKE_INSTALL_LOG="$SANDBOX/install.log" \
        FAKE_CHECK_RC="$SANDBOX/check-rc" \
        FAKE_INSTALL_RC="$SANDBOX/install-rc" \
        FAKE_GIT_LOG="$SANDBOX/git.log" \
        FAKE_GH_LOG="$SANDBOX/gh.log" \
        FAKE_GH_PAYLOAD_LOG="$SANDBOX/gh-payload.log" \
        FAKE_SYSTEMCTL_LOG="$SANDBOX/systemctl.log" \
        FAKE_GIT_MODE="$GIT_MODE" \
        FAKE_GH_MODE="$GH_MODE" \
        FAKE_GH_VALUE="$GH_VALUE" \
        FAKE_CLIENT_VARS="${FAKE_CLIENT_VARS:-}" \
        $TIMEOUT "$subject" > "$SANDBOX/out" 2> "$SANDBOX/err" </dev/null
        SYNC_RC=$?
    fi
    cat "$SANDBOX/out" "$SANDBOX/err" > "$SANDBOX/combined"
}

git_dest() {
    sed -n 's/^dest=\([^ ]*\).*/\1/p' "$SANDBOX/git.log" 2>/dev/null | tail -1
}

# 某 unit 被呼叫了幾次；with_check=yes 數帶 --check 的，no 數不帶的。
# install.log 每行格式：<unit> args=...
unit_calls() {
    local unit="$1" with_check="$2" n=0 line args
    while IFS= read -r line; do
        case "$line" in
            "$unit args="*) ;;
            *) continue ;;
        esac
        args="${line#*args=}"
        if [[ "$args" == *"--check"* ]]; then
            [[ "$with_check" == yes ]] && n=$((n + 1))
        else
            [[ "$with_check" == no ]] && n=$((n + 1))
        fi
    done < "$SANDBOX/install.log"
    printf '%s' "$n"
}

snapshot_state() {
    ( cd "$SANDBOX/home/.mylinuxpool" 2>/dev/null && find . -mindepth 1 | sort )
}

SNAP_BEFORE=""
check_no_new_state() {
    local d="$1" now
    need_ran "$d" || return
    if ! grep -q . "$SANDBOX/git.log" 2>/dev/null; then
        fail_line "${d}（run 沒有真的執行到 clone，無從證明）"; return
    fi
    now="$(snapshot_state)"
    if [[ "$now" == "$SNAP_BEFORE" ]]; then ok_line "$d"
    else
        fail_line "${d}（多了/變了：$(comm -13 <(printf '%s\n' "$SNAP_BEFORE") <(printf '%s\n' "$now") | tr '\n' ' '))"
    fi
}

# 暫存目錄清理：success / clone 失敗 / install 失敗 三條路徑共用。
check_cleanup() {
    local d="$1" dest
    need_ran "$d" || return
    dest="$(git_dest)"
    if [[ -z "$dest" ]]; then
        fail_line "${d}（fake git 沒被呼叫，無從驗證暫存目錄）"; return
    fi
    if [[ -e "$dest" ]]; then
        fail_line "${d}（暫存目錄還在：${dest}）"; return
    fi
    if [[ -n "$(ls -A "$SANDBOX/tmpdir" 2>/dev/null)" ]]; then
        fail_line "${d}（TMPDIR 有殘留：$(ls -A "$SANDBOX/tmpdir" | tr '\n' ' '))"; return
    fi
    ok_line "$d"
}

# ---------------------------------------------------------------------------
# S0: subject must exist — absent means FAIL, never skip.
# ---------------------------------------------------------------------------
echo "── S0 被測物存在 ──"
if [[ -x "$POOL_SYNC" ]]; then
    ok_line "pool-sync 存在且可執行"
else
    fail_line "pool-sync 必須存在且可執行（${POOL_SYNC}）；不存在時不得 skip"
fi

# ---------------------------------------------------------------------------
# S1: config 缺失 → exit 1，訊息提到 config
# ---------------------------------------------------------------------------
echo "── S1 config 缺失 ──"
reset_home
rm -f "$SANDBOX/home/.mylinuxpool/config"
run_sync
check_rc 1 "config 缺失 → exit 1"
grep_ok "$SANDBOX/combined" 'config' "config 缺失 → 訊息提到 config"

# ---------------------------------------------------------------------------
# S2: gh_token 缺失 → exit 1
# ---------------------------------------------------------------------------
echo "── S2 gh_token 缺失 ──"
reset_home
rm -f "$SANDBOX/home/.mylinuxpool/gh_token"
run_sync
check_rc 1 "gh_token 缺失 → exit 1"
if [[ "$RAN" -ne 1 ]]; then
    fail_line "gh_token 缺失 → 有錯誤訊息（被測物沒有真的執行，無從證明）"
elif [[ -s "$SANDBOX/combined" ]]; then
    ok_line "gh_token 缺失 → 有錯誤訊息"
else
    fail_line "gh_token 缺失 → 有錯誤訊息（輸出為空）"
fi
grep_no "$SANDBOX/git.log" '.' "gh_token 缺失 → 根本沒嘗試 clone"

# ---------------------------------------------------------------------------
# S3: clone 失敗（GitHub 不可用）→ exit 0 + WARN（N6：不可變成 provider 故障）
# ---------------------------------------------------------------------------
echo "── S3 clone 失敗 ──"
reset_home
build_fixture "unit-a" "unit-b" ""
GIT_MODE="fail"
run_sync
check_rc 0 "clone 失敗 → exit 0"
grep_ok "$SANDBOX/err" 'WARN' "clone 失敗 → stderr 有 WARN"
check_no_restart "clone 失敗 → 沒有重啟" "grep -q . '$SANDBOX/git.log'"
grep_no "$SANDBOX/install.log" '.' "clone 失敗 → 沒有呼叫任何 install.sh" "grep -q . '$SANDBOX/git.log'"

# ---------------------------------------------------------------------------
# S4: 所有 --check 都回 0 → 不重啟（重啟會斷掉 worker 隧道）
# ---------------------------------------------------------------------------
echo "── S4 無漂移 ──"
reset_home
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"
run_sync
check_rc 0 "無漂移 → exit 0"
grep_ok "$SANDBOX/install.log" '^unit-a args=.*--check' "無漂移 → unit-a 有被 --check"
grep_ok "$SANDBOX/install.log" '^unit-b args=.*--check' "無漂移 → unit-b 有被 --check"
check_no_restart "所有 --check 回 0 → 不重啟" "grep -qE 'args=.*--check' '$SANDBOX/install.log'"
if [[ "$RAN" -ne 1 ]]; then
    fail_line "無漂移 → 沒有任何實際安裝（被測物沒有真的執行，無從證明）"
elif [[ "$(unit_calls unit-a no)" -eq 0 && "$(unit_calls unit-b no)" -eq 0 ]]; then
    ok_line "無漂移 → 沒有任何實際安裝"
else
    fail_line "無漂移 → 沒有任何實際安裝（unit-a=$(unit_calls unit-a no), unit-b=$(unit_calls unit-b no)）"
fi

# ---------------------------------------------------------------------------
# S5: 某 unit --check 非 0 → 實際 install + 重啟
# ---------------------------------------------------------------------------
echo "── S5 有漂移 ──"
reset_home
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"
printf 'unit-b 1\n' > "$SANDBOX/check-rc"
run_sync
check_rc 0 "漂移後修復 → exit 0"
if [[ "$(unit_calls unit-b no)" -ge 1 ]]; then
    ok_line "漂移 unit → 有實際 install（不帶 --check）"
else
    fail_line "漂移 unit → 有實際 install（不帶 --check）（unit-b 呼叫：$(grep '^unit-b ' "$SANDBOX/install.log" 2>/dev/null | tr '\n' ';'))"
fi
if [[ "$RAN" -ne 1 ]]; then
    fail_line "無漂移 unit → 不實際 install（被測物沒有真的執行，無從證明）"
elif [[ "$(unit_calls unit-a no)" -eq 0 ]]; then
    ok_line "無漂移 unit → 不實際 install"
else
    fail_line "無漂移 unit → 不實際 install（unit-a 被裝了 $(unit_calls unit-a no) 次）"
fi
check_restart "有實際安裝 → 有重啟 pool-tunnel"

# ---------------------------------------------------------------------------
# S6: needs_key unit → 完全不呼叫它的 install.sh，log 有說明
# ---------------------------------------------------------------------------
echo "── S6 needs_key 跳過 ──"
reset_home
build_fixture "unit-a unit-c" "unit-b" "unit-c"
GIT_MODE="ok"
: > "$SANDBOX/check-rc"
run_sync
check_rc 0 "needs_key → exit 0"
grep_ok "$SANDBOX/install.log" '^unit-a args=.*--check' "needs_key → 其他 unit 照常處理（前提）"
grep_no "$SANDBOX/install.log" '^unit-c' "needs_key unit → 完全不呼叫它的 install.sh（連 --check 都不）" "grep -q '^unit-a args=--check' '$SANDBOX/install.log'"
grep_ok "$SANDBOX/combined" 'unit-c' "needs_key → log 有提到該 unit"
grep_ok "$SANDBOX/combined" '[Ss]kip|FILE_CRYPTO_KEY|needs_key' "needs_key → log 說明跳過原因"
check_no_restart "needs_key 跳過不算變更 → 不重啟" "grep -q '^unit-a args=--check' '$SANDBOX/install.log'"

# ---------------------------------------------------------------------------
# S6b/S6c/S6d: 跳過條件 = needs_key==true「或」needs_root==true。
# pool-sync 由 systemd --user timer 啟動、沒有 root；gh 這個 unit 正是
# needs_key=false + needs_root=true，只跳 needs_key 會漏掉它。
# 兩種原因的訊息必須能區分（金鑰 vs root）。
# ---------------------------------------------------------------------------
echo "── S6b needs_root 跳過 / S6c needs_key 跳過（訊息可區分）/ S6d 兩者皆 false ──"
reset_home
build_fixture "unit-a unit-k unit-r unit-n" "unit-b" "unit-k" "unit-r"
GIT_MODE="ok"
printf 'unit-n 1\n' > "$SANDBOX/check-rc"
run_sync
check_rc 0 "needs_root/needs_key 跳過、正常 unit 收斂 → exit 0"

# S6d: 兩者皆 false 的 unit-n 有漂移 → --check 與實際安裝都要發生
if [[ "$(unit_calls unit-n yes)" -ge 1 && "$(unit_calls unit-n no)" -ge 1 ]]; then
    ok_line "兩者皆 false（有漂移）→ 有 --check 也有實際安裝"
else
    fail_line "兩者皆 false（有漂移）→ 應被 --check 與安裝（check=$(unit_calls unit-n yes), install=$(unit_calls unit-n no)）"
fi

# S6b: needs_root=true、needs_key=false → 完全不呼叫它的 install.sh
grep_no "$SANDBOX/install.log" '^unit-r' "needs_root unit → 完全不呼叫它的 install.sh（連 --check 都不）" "grep -q '^unit-n ' '$SANDBOX/install.log'"
root_msg="$(grep -F 'unit-r' "$SANDBOX/combined" 2>/dev/null || true)"
key_msg="$(grep -F 'unit-k' "$SANDBOX/combined" 2>/dev/null || true)"
if [[ -z "$root_msg" ]]; then
    fail_line "needs_root → log 有提到該 unit（找不到 unit-r 的任何訊息）"
elif printf '%s\n' "$root_msg" | grep -Eqi 'root'; then
    ok_line "needs_root → log 說明跳過原因是需要 root"
else
    fail_line "needs_root → log 應說明需要 root（unit-r 相關行：$(printf '%s' "$root_msg" | tr '\n' ' ')）"
fi

# S6c: needs_key=true、needs_root=false → 完全不呼叫它的 install.sh
grep_no "$SANDBOX/install.log" '^unit-k' "needs_key unit → 完全不呼叫它的 install.sh（連 --check 都不）" "grep -q '^unit-n ' '$SANDBOX/install.log'"
if [[ -z "$key_msg" ]]; then
    fail_line "needs_key → log 有提到該 unit（找不到 unit-k 的任何訊息）"
elif printf '%s\n' "$key_msg" | grep -Eq 'FILE_CRYPTO_KEY|[Kk]ey|金鑰'; then
    ok_line "needs_key → log 說明跳過原因是金鑰"
else
    fail_line "needs_key → log 應說明需要金鑰（unit-k 相關行：$(printf '%s' "$key_msg" | tr '\n' ' ')）"
fi

# 訊息可區分：root 的行不得提金鑰、key 的行不得提 root
if [[ -z "$root_msg" ]]; then
    fail_line "needs_root 的訊息可與 needs_key 區分（前提不成立：沒有 unit-r 訊息）"
elif printf '%s\n' "$root_msg" | grep -Eqi 'FILE_CRYPTO_KEY|key|金鑰'; then
    fail_line "needs_root 的訊息不該提金鑰，否則無法與 needs_key 區分（$(printf '%s' "$root_msg" | tr '\n' ' ')）"
else
    ok_line "needs_root 的訊息未提及金鑰（可與 needs_key 區分）"
fi
if [[ -z "$key_msg" ]]; then
    fail_line "needs_key 的訊息可與 needs_root 區分（前提不成立：沒有 unit-k 訊息）"
elif printf '%s\n' "$key_msg" | grep -Eqi 'root'; then
    fail_line "needs_key 的訊息不該提 root，否則無法與 needs_root 區分（$(printf '%s' "$key_msg" | tr '\n' ' ')）"
else
    ok_line "needs_key 的訊息未提及 root（可與 needs_root 區分）"
fi

# ---------------------------------------------------------------------------
# S7: registered_with == "--no-sudo" → 讀 no-sudo profile
# ---------------------------------------------------------------------------
echo "── S7 --no-sudo profile ──"
reset_home
build_fixture "unit-a" "unit-b" ""
GIT_MODE="ok"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"--no-sudo"}'
run_sync
check_rc 0 "--no-sudo → exit 0"
grep_ok "$SANDBOX/install.log" '^unit-b args=.*--check' "--no-sudo → 讀 no-sudo profile（unit-b）"
grep_no "$SANDBOX/install.log" '^unit-a' "--no-sudo → 不讀 default profile 的 unit-a" "grep -q '^unit-b args=' '$SANDBOX/install.log'"

# ---------------------------------------------------------------------------
# S8: var 取不到 → 退回 default profile，不中止
# ---------------------------------------------------------------------------
echo "── S8 var 取不到 ──"
reset_home
build_fixture "unit-a" "unit-b" ""
GIT_MODE="ok"
GH_MODE="missing"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"--no-sudo"}'
run_sync
check_rc 0 "var 取不到 → 不中止（exit 0）"
grep_ok "$SANDBOX/install.log" '^unit-a args=.*--check' "var 取不到 → 退回 default profile（unit-a）"
grep_no "$SANDBOX/install.log" '^unit-b' "var 取不到 → 沒有走 no-sudo profile" "grep -q '^unit-a args=' '$SANDBOX/install.log'"
grep_ok "$SANDBOX/combined" 'WARN' "var 取不到 → 有 WARN"

# ---------------------------------------------------------------------------
# S9 + S10: 暫存目錄清理（成功/clone 失敗/install 失敗）與零新增每機狀態
# ---------------------------------------------------------------------------
echo "── S9 成功路徑 ──"
reset_home
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"; : > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
SNAP_BEFORE="$(snapshot_state)"
run_sync
check_rc 0 "成功路徑 → exit 0"
grep_ok "$SANDBOX/git.log" 'depth' "成功路徑 → clone 帶 --depth"
grep_ok "$SANDBOX/git.log" 'branch' "成功路徑 → clone 指定 branch"
check_cleanup "成功路徑 → 暫存目錄有清掉"
check_no_new_state "成功路徑 → ~/.mylinuxpool 沒有多出任何新檔案"
grep_no "$SANDBOX/git.log" 'ghp_FAKE_TOKEN' "成功路徑 → token 不出現在 git 命令列"
grep_no "$SANDBOX/combined" 'ghp_FAKE_TOKEN' "成功路徑 → token 不出現在 log"

echo "── S9 clone 失敗路徑 ──"
reset_home
build_fixture "unit-a" "unit-b" ""
GIT_MODE="fail"; GH_MODE="ok"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
SNAP_BEFORE="$(snapshot_state)"
run_sync
check_cleanup "clone 失敗 → 暫存目錄有清掉"
check_no_new_state "clone 失敗 → ~/.mylinuxpool 沒有多出任何新檔案"

echo "── S9 install 失敗路徑 ──"
reset_home
build_fixture "unit-a" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
printf 'unit-a 1\n' > "$SANDBOX/check-rc"
printf 'unit-a 1\n' > "$SANDBOX/install-rc"
SNAP_BEFORE="$(snapshot_state)"
run_sync
check_rc 1 "install 失敗 → exit 1"
check_cleanup "install 失敗 → 暫存目錄有清掉"
check_no_new_state "install 失敗 → ~/.mylinuxpool 沒有多出任何新檔案"

# ---------------------------------------------------------------------------
# M1–M3: 遷移——成功 clone 後移除舊的常駐 repo clone（register-provider.sh
# 舊版留下的），clone 失敗時保留（安全順序：沒抓到新版就不砍舊的）。
# 注意：這些情境預先製造 $HOME/.mylinuxpool/repo，會讓「零新增每機狀態」
# 快照斷言失效（刪除也算變動），所以刻意用獨立 fixture、不跑
# check_no_new_state；S9 的情境仍由 reset_home 給出乾淨 home（從來沒有
# repo 目錄），那條斷言不受影響。
# ---------------------------------------------------------------------------
plant_stale_repo() {
    mkdir -p "$SANDBOX/home/.mylinuxpool/repo"
    printf 'STALE-MARKER\n' > "$SANDBOX/home/.mylinuxpool/repo/marker.txt"
}

echo "── M1 舊 repo clone 存在 → 成功 clone 後被移除 ──"
reset_home
plant_stale_repo
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
run_sync
check_rc 0 "遷移 → exit 0"
if [[ "$RAN" -ne 1 ]]; then
    fail_line "遷移 → 舊 repo clone 被移除（被測物沒有真的執行，無從證明）"
elif [[ ! -e "$SANDBOX/home/.mylinuxpool/repo" ]]; then
    ok_line "遷移 → 舊 repo clone 被移除"
else
    fail_line "遷移 → 舊 repo clone 還在（$SANDBOX/home/.mylinuxpool/repo）"
fi
if [[ "$RAN" -ne 1 ]]; then
    fail_line "遷移 → 標記檔一併消失（被測物沒有真的執行，無從證明）"
elif [[ ! -e "$SANDBOX/home/.mylinuxpool/repo/marker.txt" ]]; then
    ok_line "遷移 → 標記檔一併消失"
else
    fail_line "遷移 → 標記檔還在（marker.txt）"
fi

echo "── M2 clone 失敗 → 舊 repo clone 保留（安全順序）──"
reset_home
plant_stale_repo
build_fixture "unit-a" "unit-b" ""
GIT_MODE="fail"; GH_MODE="ok"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
run_sync
check_rc 0 "clone 失敗 → exit 0（N6：不變 provider 故障）"
if [[ "$RAN" -ne 1 ]]; then
    fail_line "clone 失敗 → 舊 repo clone 保留（被測物沒有真的執行，無從證明）"
elif [[ -e "$SANDBOX/home/.mylinuxpool/repo/marker.txt" ]]; then
    ok_line "clone 失敗 → 舊 repo clone 保留（含標記檔）"
else
    fail_line "clone 失敗 → 舊 repo clone 被砍了（沒抓到新版就砍舊的是安全順序漏洞）"
fi

echo "── M3 本來就沒有 repo → 不報錯、exit 0 ──"
reset_home
build_fixture "unit-a" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
run_sync
check_rc 0 "無舊 repo → exit 0"
grep_no "$SANDBOX/combined" 'ERROR' "無舊 repo → 沒有錯誤訊息"

# ---------------------------------------------------------------------------
# A1–A8: pool-sync 收斂本機 authorized_keys（KEY-DESIGN §3.4 / task O）。
# pool-sync 從 CLIENT_* var 組出登入清單、完全取代 ~/.ssh/authorized_keys
# （與 ssh-admin 的聯集語意刻意不同——撤銷要生效）。自鎖防線：清單必須
# 含 Actions 那把，否則不寫、原檔不變。gh 取不到 → 不寫、原檔不變、exit 0。
# 被測物尚未含此段時（impl 未落地）這些案例會 FAIL——不得 skip。
# ---------------------------------------------------------------------------
AUTHKEYS_FILE="$SANDBOX/home/.ssh/authorized_keys"
AUB_KEY_A="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREKEYA fatesaikou-mac"
AUB_KEY_B="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREKEYB other-user"
AUB_ACTIONS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREACTIONS actions"
AUB_STALE="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURESTALE stale-user"

# write_clients <key-a> <key-b> <actions> <...> — name → value 的
# FAKE_CLIENT_VARS（gh 假貨依此回 CLIENT_* 的值）。
write_clients() {
    FAKE_CLIENT_VARS="$(jq -c -n \
        --arg ka "$1" --arg kb "$2" --arg ac "$3" \
        '{CLIENT_FATESAIKOU_MAC:{name:"fatesaikou-mac",public_key:$ka,added_at:"2026-09-16T12:00:00Z"},
          CLIENT_OTHER_USER:{name:"other-user",public_key:$kb,added_at:"2026-09-16T12:00:00Z"},
          CLIENT_ACTIONS:{name:"actions",public_key:$ac,added_at:"2026-09-16T12:00:00Z"}}')"
}
write_no_clients() {
    FAKE_CLIENT_VARS='{}'
}

echo "── A1 兩個 CLIENT_* → authorized_keys 寫成那兩把 ──"
reset_home
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
run_sync
if [[ "$RAN" -ne 1 ]]; then
    fail_line "A1. authorized_keys 被寫成那兩把（被測物沒有真的執行，無從證明）"
elif [[ -f "$AUTHKEYS_FILE" ]] \
     && grep -qF "$AUB_KEY_A" "$AUTHKEYS_FILE" \
     && grep -qF "$AUB_KEY_B" "$AUTHKEYS_FILE"; then
    ok_line "A1. authorized_keys 含那兩把使用者公鑰"
else
    fail_line "A1. authorized_keys 缺公鑰（$(head -c 200 "$AUTHKEYS_FILE" 2>/dev/null | tr '\n' ' ')）"
fi

echo "── A2 完全取代：var 外的舊鑰被移除 ──"
reset_home
mkdir -p "$SANDBOX/home/.ssh"
printf '%s\n' "$AUB_STALE" > "$AUTHKEYS_FILE"
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
run_sync
if [[ "$RAN" -ne 1 ]]; then
    fail_line "A2. var 外的舊鑰被移除（被測物沒有真的執行，無從證明）"
elif [[ -f "$AUTHKEYS_FILE" ]] && ! grep -qF "$AUB_STALE" "$AUTHKEYS_FILE" \
     && grep -qF "$AUB_KEY_A" "$AUTHKEYS_FILE"; then
    ok_line "A2. 舊鑰（var 外）被移除——完全取代語意生效"
else
    fail_line "A2. 舊鑰仍在或新鑰沒寫（$(head -c 200 "$AUTHKEYS_FILE" 2>/dev/null | tr '\n' ' ')）"
fi

echo "── A3 內容已正確 → 不重寫 ──"
reset_home
mkdir -p "$SANDBOX/home/.ssh"
# 預寫的順序必須跟 authkeys_assemble 的契約輸出一致（依金鑰材料排序：
# FIXTUREACTIONS < FIXTUREKEYA < FIXTUREKEYB）——契約第 4 條，byte-stable。
printf '%s\n%s\n%s\n' "$AUB_ACTIONS" "$AUB_KEY_A" "$AUB_KEY_B" > "$AUTHKEYS_FILE"
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
MTIME_BEFORE="$(stat -f %m "$AUTHKEYS_FILE" 2>/dev/null || stat -c %Y "$AUTHKEYS_FILE" 2>/dev/null)"
sleep 1
run_sync
MTIME_AFTER="$(stat -f %m "$AUTHKEYS_FILE" 2>/dev/null || stat -c %Y "$AUTHKEYS_FILE" 2>/dev/null)"
if [[ "$RAN" -ne 1 ]]; then
    fail_line "A3. 內容正確 → 不重寫（被測物沒有真的執行，無從證明）"
elif [[ "$MTIME_BEFORE" == "$MTIME_AFTER" ]]; then
    ok_line "A3. 內容已正確 → 沒有重寫（mtime 不變）"
else
    fail_line "A3. 內容已正確卻重寫（mtime $MTIME_BEFORE → ${MTIME_AFTER}）——每輪都動檔案 = 永遠在漂移"
fi

echo "── A4 自鎖防線：無 Actions → 不寫、原檔不變 ──"
reset_home
mkdir -p "$SANDBOX/home/.ssh"
printf '%s\n' "$AUB_KEY_A" > "$AUTHKEYS_FILE"
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
# CLIENT_* 裡沒有 CLIENT_ACTIONS
FAKE_CLIENT_VARS="$(jq -c -n \
    --arg ka "$AUB_KEY_A" --arg kb "$AUB_KEY_B" \
    '{CLIENT_FATESAIKOU_MAC:{name:"fatesaikou-mac",public_key:$ka,added_at:"2026-09-16T12:00:00Z"},
      CLIENT_OTHER_USER:{name:"other-user",public_key:$kb,added_at:"2026-09-16T12:00:00Z"}}')"
run_sync
if [[ "$RAN" -ne 1 ]]; then
    fail_line "A4. 無 Actions → 不寫、原檔不變（被測物沒有真的執行，無從證明）"
else
    if [[ -f "$AUTHKEYS_FILE" ]] && grep -qF "$AUB_KEY_A" "$AUTHKEYS_FILE" \
       && ! grep -qF "$AUB_KEY_B" "$AUTHKEYS_FILE"; then
        ok_line "A4a. 無 Actions → 原檔維持不變（沒被清空、沒被寫）"
    else
        fail_line "A4a. 原檔被動了（$(head -c 200 "$AUTHKEYS_FILE" 2>/dev/null | tr '\n' ' ')）"
    fi
    if grep -q 'CLIENT_ACTIONS\|Actions' "$SANDBOX/combined" 2>/dev/null; then
        ok_line "A4b. 無 Actions → log 有說明（CLIENT_ACTIONS）"
    else
        fail_line "A4b. 無 Actions → log 沒有說明"
    fi
fi

echo "── A5 組出來是空的 → 不寫、原檔不變 ──"
reset_home
mkdir -p "$SANDBOX/home/.ssh"
printf '%s\n' "$AUB_KEY_A" > "$AUTHKEYS_FILE"
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
write_no_clients
run_sync
if [[ "$RAN" -ne 1 ]]; then
    fail_line "A5. 空清單 → 不寫、原檔不變（被測物沒有真的執行，無從證明）"
elif [[ -f "$AUTHKEYS_FILE" ]] && grep -qF "$AUB_KEY_A" "$AUTHKEYS_FILE"; then
    ok_line "A5. 組出空清單 → 不寫、原檔不變"
else
    fail_line "A5. 空清單卻動了原檔（$(head -c 200 "$AUTHKEYS_FILE" 2>/dev/null | tr '\n' ' ')）"
fi

echo "── A6 gh 取不到 → 不寫、原檔不變、exit 0 ──"
reset_home
mkdir -p "$SANDBOX/home/.ssh"
printf '%s\n' "$AUB_KEY_A" > "$AUTHKEYS_FILE"
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="missing"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
run_sync
check_rc 0 "gh 取不到 → exit 0（N6：不變 provider 故障）"
if [[ "$RAN" -ne 1 ]]; then
    fail_line "A6. gh 取不到 → 原檔不變（被測物沒有真的執行，無從證明）"
elif [[ -f "$AUTHKEYS_FILE" ]] && grep -qF "$AUB_KEY_A" "$AUTHKEYS_FILE" \
     && ! grep -qF "$AUB_KEY_B" "$AUTHKEYS_FILE"; then
    ok_line "A6. gh 取不到 → 原檔不變"
else
    fail_line "A6. gh 取不到卻動了原檔（$(head -c 200 "$AUTHKEYS_FILE" 2>/dev/null | tr '\n' ' ')）"
fi

echo "── A7 收斂失敗時，其他 unit 照常收斂 ──"
reset_home
mkdir -p "$SANDBOX/home/.ssh"
printf '%s\n' "$AUB_STALE" > "$AUTHKEYS_FILE"
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
printf 'unit-b 1\n' > "$SANDBOX/check-rc"
: > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
FAKE_CLIENT_VARS="$(jq -c -n --arg ka "$AUB_KEY_A" \
    '{CLIENT_FATESAIKOU_MAC:{name:"fatesaikou-mac",public_key:$ka,added_at:"2026-09-16T12:00:00Z"}}')"
run_sync
check_rc 0 "收斂失敗情境 → exit 0"
if [[ "$(unit_calls unit-b no)" -ge 1 ]]; then
    ok_line "A7. authorized_keys 收斂失敗時，其他 unit 仍照常收斂"
else
    fail_line "A7. 其他 unit 沒被收斂（unit-b 呼叫次數：$(unit_calls unit-b no)）"
fi

echo "── A8 寫入是原子的（暫存 + mv，非直接覆蓋）──"
reset_home
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
run_sync
if [[ "$RAN" -ne 1 ]]; then
    fail_line "A8. 寫入是原子的（被測物沒有真的執行，無從證明）"
elif grep -q 'authorized_keys' "$SANDBOX/combined" 2>/dev/null \
     && ! grep -qE '>\s*\$HOME/.ssh/authorized_keys|>\s*'"$AUTHKEYS_FILE" "$SANDBOX/combined" 2>/dev/null; then
    ok_line "A8. authorized_keys 收斂未見直接覆蓋目標的形狀（log 無 > 目標）"
else
    fail_line "A8. 看不到原子寫入的證據，或出現直接覆蓋（log: $(head -c 300 "$SANDBOX/combined" | tr '\n' ' ')）"
fi

# ---------------------------------------------------------------------------
# A9: 注入 — 把「完全取代」改回聯集 → A2 必須紅
# ---------------------------------------------------------------------------
echo "── A9 注入：完全取代改回聯集 ──"
reset_home
mkdir -p "$SANDBOX/home/.ssh"
printf '%s\n' "$AUB_STALE" > "$AUTHKEYS_FILE"
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
# 注入版：把 authorized_keys 寫入改成「不清空、只附加」的聯集版本（等價
# 於拿掉完全取代）。收斂邏輯在 fixture 的 refresh-authkeys.sh 裡（pool-sync
# 呼叫 refresh_sync_local_authorized_keys），所以注入目標是那個 fixture
# 副本——實作是原子寫入：`mv -f "$tmp" "$target"` 換成 `cat "$tmp" >>
# "$target"`，目標不被覆蓋、舊鑰留下。
python3 - "$SANDBOX/fixture/scripts/refresh-authkeys.sh" <<'PY'
import re
import sys
src = open(sys.argv[1], encoding="utf-8").read()
src = re.sub(r'mv -f "\$tmp" "\$target"',
             r'cat "$tmp" >> "$target"', src)
open(sys.argv[1], "w", encoding="utf-8").write(src)
PY
run_sync
if [[ "$RAN" -ne 1 ]]; then
    fail_line "A9. 注入版沒跑起來（注入 harness 問題）"
elif [[ -f "$AUTHKEYS_FILE" ]] && grep -qF "$AUB_STALE" "$AUTHKEYS_FILE"; then
    printf '  inj ok    %s\n' "注入後（聯集語意）舊鑰仍在——A2 條會紅（完全取代被拿掉）"
else
    fail_line "A9. 注入後舊鑰仍被移除——注入沒生效（harness 問題）"
fi

# ---------------------------------------------------------------------------
# A10: 注入 — 拿掉自鎖防線 → A4 必須紅
# ---------------------------------------------------------------------------
echo "── A10 注入：拿掉自鎖防線 ──"
reset_home
mkdir -p "$SANDBOX/home/.ssh"
printf '%s\n' "$AUB_KEY_A" > "$AUTHKEYS_FILE"
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
FAKE_CLIENT_VARS="$(jq -c -n \
    --arg ka "$AUB_KEY_A" --arg kb "$AUB_KEY_B" \
    '{CLIENT_FATESAIKOU_MAC:{name:"fatesaikou-mac",public_key:$ka,added_at:"2026-09-16T12:00:00Z"},
      CLIENT_OTHER_USER:{name:"other-user",public_key:$kb,added_at:"2026-09-16T12:00:00Z"}}')"
# 注入：把「CLIENT_ACTIONS 檢查失敗就中止」的 guard 中性化。guard 在
# fixture 的 refresh-authkeys.sh（refresh_sync_local_authorized_keys）——
# 自鎖防線有兩層：該函式的 CLIENT_ACTIONS 檢查（上面）與
# authkeys_assemble 的 required 檢查（CONTRACT §2 第 5 條）。guard 被
# 移除後 actions_pk 為空，空 required 會讓 assemble 自己拒絕——所以要
# 重現「防線全失」還得把 required 換成清單裡存在的任一把，否則注入版
# 仍不寫、A4 永遠紅不了。
python3 - "$SANDBOX/fixture/scripts/refresh-authkeys.sh" <<'PY'
import re
import sys
src = open(sys.argv[1], encoding="utf-8").read()
# 中性化：任何「若缺 CLIENT_ACTIONS 就 return 非 0」的形狀。guard 是
# `if [[ -z "$actions_pk" ]]; then ... return 1`（actions_pk 來自
# CLIENT_ACTIONS 查詢），用 re.S 讓 `.` 跨多行、[ \t]* 避免吞 body。
src = re.sub(r'if[^\n]*actions_pk[^\n]*;\s*then\s*\n((?:(?!\n[ \t]*fi).)*)\n[ \t]*fi',
             lambda m: 'if false; then\n%s\nfi' % m.group(1), src, flags=re.M | re.S)
src = re.sub(r'authkeys_assemble "\$clients" "\$actions_pk"',
             'authkeys_assemble "$clients" "$(printf \'%s\' "$clients" | jq -r \'.[0].public_key // empty\' 2>/dev/null || true)"',
             src)
open(sys.argv[1], "w", encoding="utf-8").write(src)
PY
run_sync
if [[ "$RAN" -ne 1 ]]; then
    fail_line "A10. 注入版沒跑起來（注入 harness 問題）"
elif [[ -f "$AUTHKEYS_FILE" ]] && grep -qF "$AUB_KEY_B" "$AUTHKEYS_FILE"; then
    printf '  inj ok    %s\n' "注入後（拿掉自鎖防線）無 Actions 仍寫入了 user B——A4 條會紅"
else
    fail_line "A10. 注入後仍沒寫入——注入沒生效（harness 問題）"
fi

# ===========================================================================
# Q1–Q7: provider 自產隧道金鑰（MIGRATION.md §3 / KEY-DESIGN §3.3、§9.4）。
# pool-sync 在每次收斂時確保 ~/.ssh/id_tunnel 存在（不存在才產）、把公鑰
# 併進自己的 NODE_<NAME> var（merge，絕不覆蓋其他欄位）、發布成功才派發
# refresh-authorized-keys.yml，而任何 GitHub 失敗都只 WARN、不讓整支失敗。
# ===========================================================================
TUNNEL_KEY_FILE="$SANDBOX/home/.ssh/id_tunnel"
TUNNEL_PUB_FILE="$SANDBOX/home/.ssh/id_tunnel.pub"

# 記下私鑰的內容指紋。用 sha256 而非 mtime：同一秒內重產會讓 mtime 看起來
# 沒變，那個假陰性會讓 Q2（不該重產）與 Q-Inj1（該重產）都誤判。
tunnel_fingerprint() {
    if [[ -f "$TUNNEL_KEY_FILE" ]]; then
        shasum -a 256 "$TUNNEL_KEY_FILE" 2>/dev/null | awk '{print $1}'
    fi
}
tunnel_key_perm() {
    if stat -f '%Lp' "$TUNNEL_KEY_FILE" >/dev/null 2>&1; then
        stat -f '%Lp' "$TUNNEL_KEY_FILE"
    else
        stat -c '%a' "$TUNNEL_KEY_FILE" 2>/dev/null
    fi
}

echo "── Q1 id_tunnel 不存在 → 產生一對、私鑰 600 ──"
reset_home
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
run_sync
check_rc 0 "Q1. 產金鑰的這輪仍 exit 0"
if [[ "$RAN" -ne 1 ]]; then
    fail_line "Q1. id_tunnel 被產生（被測物沒有真的執行，無從證明）"
elif [[ -f "$TUNNEL_KEY_FILE" && -f "$TUNNEL_PUB_FILE" ]]; then
    ok_line "Q1. id_tunnel 與 id_tunnel.pub 都被產生"
else
    fail_line "Q1. id_tunnel 未被產生（${TUNNEL_KEY_FILE}）"
fi
if [[ "$RAN" -eq 1 && -f "$TUNNEL_KEY_FILE" ]]; then
    perm="$(tunnel_key_perm)"
    if [[ "$perm" == "600" ]]; then
        ok_line "Q1. 私鑰權限是 600（實際 ${perm}）"
    else
        fail_line "Q1. 私鑰權限不是 600（實際 ${perm:-<無法取得>}）"
    fi
elif [[ "$RAN" -eq 1 ]]; then
    fail_line "Q1. 私鑰權限是 600（檔案不存在，無從檢查）"
fi

echo "── Q2 已存在 → 不重新產生（換鑰會讓機器失聯）──"
if [[ "$RAN" -ne 1 || ! -f "$TUNNEL_KEY_FILE" ]]; then
    fail_line "Q2. 既有金鑰不被重產（前提不成立：Q1 沒產出 id_tunnel）"
    fail_line "Q2. 公鑰內容不變（前提不成立）"
else
    FP_BEFORE="$(tunnel_fingerprint)"
    PUB_BEFORE="$(cat "$TUNNEL_PUB_FILE" 2>/dev/null)"
    run_sync
    check_rc 0 "Q2. 第二輪 exit 0"
    FP_AFTER="$(tunnel_fingerprint)"
    PUB_AFTER="$(cat "$TUNNEL_PUB_FILE" 2>/dev/null)"
    if [[ -n "$FP_BEFORE" && "$FP_BEFORE" == "$FP_AFTER" ]]; then
        ok_line "Q2. 既有私鑰未被重產（sha256 不變：${FP_BEFORE:0:16}…）"
    else
        fail_line "Q2. 既有私鑰被重產了（前 ${FP_BEFORE:-<無>}，後 ${FP_AFTER:-<無>}）——這會讓機器失聯"
    fi
    if [[ -n "$PUB_BEFORE" && "$PUB_BEFORE" == "$PUB_AFTER" ]]; then
        ok_line "Q2. 公鑰內容不變"
    else
        fail_line "Q2. 公鑰內容變了"
    fi
fi

echo "── Q3 發布 tunnel_public_key：合併而非覆蓋 ──"
reset_home
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
# 節點 var 帶 hops / power / capabilities——發布後必須全都還在。
Q_NODE_JSON='{"name":"testnode","role":"provider","registered_with":"register-provider.sh","gateway_port":2301,"hops":[{"via":"gateway"},{"host":"127.0.0.1","port":2301,"user":"u","key_secret":"SSH_KEY_ACTIONS"}],"power":{"launch":"wake","shutdown":"down"},"capabilities":["docker","worker-host"]}'
GH_VALUE="$Q_NODE_JSON"
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
run_sync
check_rc 0 "Q3. 發布這輪 exit 0"
if [[ "$RAN" -ne 1 ]]; then
    fail_line "Q3. 有送出 gh variable set（被測物沒有真的執行）"
    fail_line "Q3. 送出的 JSON 保留 hops（前提不成立）"
elif grep -q 'variable set NODE_TESTNODE' "$SANDBOX/gh.log" 2>/dev/null; then
    ok_line "Q3. 有送出 gh variable set NODE_TESTNODE"
    PAYLOAD="$(sed -n 's/^PAYLOAD|//p' "$SANDBOX/gh-payload.log" 2>/dev/null | tail -1)"
    if [[ -z "$PAYLOAD" ]]; then
        fail_line "Q3. 送出的 JSON 保留其他欄位（payload 未被記錄，無從證明）"
    elif ! jq -e . >/dev/null 2>&1 <<<"$PAYLOAD"; then
        fail_line "Q3. 送出的 JSON 是合法 JSON（payload: ${PAYLOAD:0:100}）"
    else
        ok_line "Q3. 送出的 JSON 是合法 JSON"
        pub_published="$(jq -r '.tunnel_public_key // empty' <<<"$PAYLOAD" 2>/dev/null)"
        pub_on_disk="$(cat "$TUNNEL_PUB_FILE" 2>/dev/null | tr -d '\r\n')"
        if [[ -n "$pub_published" && "$pub_published" == "$pub_on_disk" ]]; then
            ok_line "Q3. tunnel_public_key 等於本機 id_tunnel.pub"
        else
            fail_line "Q3. tunnel_public_key 不等於本機公鑰（published=[${pub_published:0:40}] disk=[${pub_on_disk:0:40}]）"
        fi
        missing_fields=""
        for fld in hops power capabilities role name gateway_port; do
            jq -e --arg f "$fld" 'has($f)' <<<"$PAYLOAD" >/dev/null 2>&1 || missing_fields="${missing_fields} ${fld}"
        done
        if [[ -z "$missing_fields" ]]; then
            ok_line "Q3. 原有欄位全部保留（hops / power / capabilities / role / name / gateway_port）"
        else
            fail_line "Q3. 發布覆蓋掉了原有欄位：${missing_fields}"
        fi
        if [[ "$(jq -c '.hops' <<<"$PAYLOAD" 2>/dev/null)" == "$(jq -c '.hops' <<<"$Q_NODE_JSON" 2>/dev/null)" ]]; then
            ok_line "Q3. hops 內容逐欄不變"
        else
            fail_line "Q3. hops 內容被改動"
        fi
    fi
else
    fail_line "Q3. 沒有送出 gh variable set NODE_TESTNODE（gh.log: $(tail -3 "$SANDBOX/gh.log" | tr '\n' ' '))"
    fail_line "Q3. 送出的 JSON 保留其他欄位（前提不成立）"
fi

echo "── Q4 已發布且相同 → 不送出寫入 ──"
Q4_PUB="$(cat "$TUNNEL_PUB_FILE" 2>/dev/null | tr -d '\r\n')"
if [[ -z "$Q4_PUB" ]]; then
    fail_line "Q4. 已相同時不送出寫入（前提不成立：磁碟上沒有 id_tunnel.pub）"
else
    GH_VALUE="$(jq -c -n --argjson base "$Q_NODE_JSON" --arg pk "$Q4_PUB" '$base + {tunnel_public_key:$pk}')"
    : > "$SANDBOX/gh-payload.log"
    run_sync
    check_rc 0 "Q4. 已相同這輪 exit 0"
    if [[ "$RAN" -ne 1 ]]; then
        fail_line "Q4. 已相同時不送出 gh variable set（被測物沒有真的執行）"
    elif grep -q 'variable set NODE_TESTNODE' "$SANDBOX/gh.log" 2>/dev/null; then
        fail_line "Q4. 已相同時仍送出了 gh variable set（$(grep 'variable set' "$SANDBOX/gh.log" | head -1)）"
    else
        ok_line "Q4. 已相同時不送出 gh variable set"
    fi
fi

echo "── Q5 私鑰不出現在 argv / stdin / log ──"
# 用整個 run 的紀錄檢查：argv（gh/git/systemctl 的 log）、payload、輸出。
if [[ "$RAN" -ne 1 ]]; then
    fail_line "Q5. 私鑰不出現在 argv / stdin / log（被測物沒有真的執行）"
elif [[ ! -f "$TUNNEL_KEY_FILE" ]]; then
    fail_line "Q5. 私鑰不出現在 argv / stdin / log（前提不成立：沒有 id_tunnel）"
else
    LEAK=""
    if grep -qF 'OPENSSH PRIVATE KEY' "$SANDBOX/gh.log" "$SANDBOX/git.log" \
            "$SANDBOX/systemctl.log" "$SANDBOX/combined" "$SANDBOX/gh-payload.log" 2>/dev/null; then
        LEAK="argv/stdin/log 的 armor 標頭"
    elif grep -qF -- "$(cat "$TUNNEL_KEY_FILE")" "$SANDBOX/gh.log" "$SANDBOX/gh-payload.log" \
            "$SANDBOX/combined" 2>/dev/null; then
        LEAK="私鑰內文"
    fi
    if [[ -z "$LEAK" ]]; then
        ok_line "Q5. 私鑰（armor 標頭與內文）不在任何 gh argv、stdin payload 或 log"
    else
        fail_line "Q5. 私鑰出現在${LEAK}"
    fi
fi

echo "── Q6 發布成功 → 派發 refresh-authorized-keys.yml ──"
reset_home
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE="$Q_NODE_JSON"
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
run_sync
check_rc 0 "Q6. 發布成功這輪 exit 0"
if [[ "$RAN" -ne 1 ]]; then
    fail_line "Q6. 派發 refresh-authorized-keys.yml（被測物沒有真的執行）"
elif grep -q 'refresh-authorized-keys' "$SANDBOX/gh.log" 2>/dev/null; then
    ok_line "Q6. 發布成功後派發了 refresh-authorized-keys.yml"
else
    fail_line "Q6. 沒有派發 refresh-authorized-keys.yml（gh.log: $(tail -3 "$SANDBOX/gh.log" | tr '\n' ' '))"
fi

echo "── Q7 gh 寫入失敗 → pool-sync 仍 exit 0，其他收斂照常 ──"
reset_home
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="writefail"
# 只讓 gh 寫入失敗；unit 的 --check 有漂移、安裝本身成功（install-rc 空），
# 否則 exit 1 會來自安裝失敗而不是我們要驗的 gh 失敗。
printf 'unit-a 1\n' > "$SANDBOX/check-rc"
: > "$SANDBOX/install-rc"
GH_VALUE="$Q_NODE_JSON"
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
run_sync
check_rc 0 "Q7. gh 寫入失敗時 pool-sync 仍 exit 0（舊鑰仍撐著隧道）"
if [[ "$RAN" -ne 1 ]]; then
    fail_line "Q7. 其他收斂照常（被測物沒有真的執行）"
else
    if [[ "$(unit_calls unit-a no)" -ge 1 ]]; then
        ok_line "Q7. gh 寫入失敗不影響 unit 收斂（unit-a 仍被安裝）"
    else
        fail_line "Q7. gh 寫入失敗時其他 unit 沒有照常收斂（unit-a 安裝次數：$(unit_calls unit-a no)）"
    fi
    if grep -q 'WARN' "$SANDBOX/combined" 2>/dev/null; then
        ok_line "Q7. gh 寫入失敗只記 WARN（不中止）"
    else
        fail_line "Q7. gh 寫入失敗沒有留下 WARN（combined: $(tail -3 "$SANDBOX/combined" | tr '\n' ' ')）"
    fi
fi

# ---------------------------------------------------------------------------
# Q8–Q10: pool-tunnel 的隧道身分（task U 之後：只有 id_tunnel）。
# MIGRATION.md 的遷移期安全網是「兩把都提供、id_tunnel 在前、id_pool 退
# 路」；KEY-DESIGN §8 拿掉共用鑰之後，id_pool 退路也一併移除——留著它會
# 讓一台機器在 id_tunnel 壞掉時悄悄用退役的共用身分連上。下面用假 ssh
# 直接觀察命令列。
# ---------------------------------------------------------------------------
POOL_TUNNEL_SH="${UNIT_ROOT}/files/pool-tunnel"
FAKE_SSH_BIN="$SANDBOX/fakebin/ssh"
if [[ -f "$FAKE_SSH_BIN" ]]; then
    mv "$FAKE_SSH_BIN" "$SANDBOX/fakebin/ssh.real-for-pool-sync"
fi
cat > "$FAKE_SSH_BIN" <<'FAKE_TUNNEL_SSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SSH_LOG:?}"
# ControlMaster 就緒探測（ssh -S <ctl> -O check）與其他 -O 操作：
# 回報成功，讓 start_master 直接完成、--once 立刻退出。
case "$*" in
    *"-O check"*|*"-O exit"*) exit 0 ;;
esac
# 主命令（-N -R ...）背景執行後被 kill：撐住直到被砍，避免被誤判為
# 「ControlMaster exited during setup」。
sleep 30
exit 0
FAKE_TUNNEL_SSH
chmod +x "$FAKE_SSH_BIN"

# run_tunnel <home> — pool-tunnel --once，static 模式（不需要 pool-resolve
# / GitHub），只為取得它組的 ssh 命令列。
run_tunnel() {
    local home="$1"
    : > "$SANDBOX/ssh.log"
    TUNNEL_RC=0
    if [[ ! -f "$POOL_TUNNEL_SH" ]]; then
        TUNNEL_RC=127
        return
    fi
    HOME="$home" PATH="$SANDBOX/fakebin:$PATH" \
    FAKE_SSH_LOG="$SANDBOX/ssh.log" \
    POOL_GATEWAY_PORT=2301 POOL_GATEWAY_HOST="203.0.113.9" POOL_GATEWAY_USER="sshproxy" \
    $TIMEOUT bash "$POOL_TUNNEL_SH" --name testnode --once </dev/null \
        > "$SANDBOX/tunnel.out" 2>&1
    TUNNEL_RC=$?
}
TUNNEL_RC=0

ssh_identity_args() {
    # 只取 -i 後面的路徑，依出現順序。
    grep -oE '\-i [^ ]+' "$SANDBOX/ssh.log" 2>/dev/null | sed 's/^-i //' | head -4
}

echo "── Q8 只有 id_tunnel → 只帶那一把（遷移已完成，不再有 id_pool 退路）──"
QT="$SANDBOX/home-tunnel"
mkdir -p "$QT/.ssh" "$QT/.mylinuxpool"
printf 'NODE_NAME=testnode\n' > "$QT/.mylinuxpool/config"
printf 'ghp_FAKE_TOKEN_abc123\n' > "$QT/.mylinuxpool/gh_token"
ssh-keygen -t ed25519 -N '' -C 'tunnel-key-q8' -f "$QT/.ssh/id_tunnel" -q </dev/null >/dev/null 2>&1
run_tunnel "$QT"
if [[ ! -f "$POOL_TUNNEL_SH" ]]; then
    fail_line "Q8. 只帶 id_tunnel（${POOL_TUNNEL_SH} 不存在）"
elif [[ ! -s "$SANDBOX/ssh.log" ]]; then
    fail_line "Q8. 只帶 id_tunnel（假 ssh 未被呼叫；tunnel rc=${TUNNEL_RC}: $(tail -2 "$SANDBOX/tunnel.out" | tr '\n' ' ')）"
else
    IDS="$(ssh_identity_args | tr '\n' ' ')"
    if [[ "$IDS" == *"/.ssh/id_tunnel"* && "$IDS" != *"id_pool"* ]]; then
        ok_line "Q8. 命令列只帶 -i id_tunnel（${IDS}）"
    else
        fail_line "Q8. 命令列的 -i 不是只有 id_tunnel（實際：${IDS:-<無>}）"
    fi
    if grep -q 'IdentitiesOnly=yes' "$SANDBOX/ssh.log" 2>/dev/null; then
        ok_line "Q8. 有帶 IdentitiesOnly=yes（ssh 只試這一把）"
    else
        fail_line "Q8. 少了 IdentitiesOnly=yes"
    fi
fi

echo "── Q9 即使 id_pool 還在磁碟上，也不得被使用（退役身分）──"
QT2="$SANDBOX/home-tunnel-pool"
mkdir -p "$QT2/.ssh" "$QT2/.mylinuxpool"
printf 'NODE_NAME=testnode\n' > "$QT2/.mylinuxpool/config"
printf 'ghp_FAKE_TOKEN_abc123\n' > "$QT2/.mylinuxpool/gh_token"
# 刻意同時放兩把：遷移期會帶兩把；退役後留著的 id_pool 必須被忽略，
# 否則一台有殘留共用鑰的機器會悄悄用舊身分連上。
ssh-keygen -t ed25519 -N '' -C 'tunnel-both-q9' -f "$QT2/.ssh/id_tunnel" -q </dev/null >/dev/null 2>&1
ssh-keygen -t ed25519 -N '' -C 'pool-leftover-q9' -f "$QT2/.ssh/id_pool" -q </dev/null >/dev/null 2>&1
run_tunnel "$QT2"
if [[ ! -f "$POOL_TUNNEL_SH" ]]; then
    fail_line "Q9. id_pool 在磁碟上也不被使用（被測物不存在）"
elif [[ "$TUNNEL_RC" -ne 0 ]]; then
    fail_line "Q9. 有 id_tunnel 時不可失敗（rc=${TUNNEL_RC}: $(tail -2 "$SANDBOX/tunnel.out" | tr '\n' ' ')）"
else
    ok_line "Q9. 兩把都在磁碟上時 pool-tunnel 仍成功（rc=0）"
    IDS="$(ssh_identity_args | tr '\n' ' ')"
    if [[ "$IDS" == *"/.ssh/id_tunnel"* && "$IDS" != *"id_pool"* ]]; then
        ok_line "Q9. 命令列只帶 -i id_tunnel，殘留的 id_pool 被忽略（${IDS}）"
    else
        fail_line "Q9. 命令列仍帶了 id_pool（實際：${IDS:-<無>}）——退役的共用身分不得再被使用"
    fi
fi

echo "── Q10 完全沒有 id_tunnel → 失敗（不得退回 id_pool）──"
QT3="$SANDBOX/home-tunnel-new"
mkdir -p "$QT3/.ssh" "$QT3/.mylinuxpool"
printf 'NODE_NAME=testnode\n' > "$QT3/.mylinuxpool/config"
printf 'ghp_FAKE_TOKEN_abc123\n' > "$QT3/.mylinuxpool/gh_token"
ssh-keygen -t ed25519 -N '' -C 'pool-only-q10' -f "$QT3/.ssh/id_pool" -q </dev/null >/dev/null 2>&1
run_tunnel "$QT3"
if [[ ! -f "$POOL_TUNNEL_SH" ]]; then
    fail_line "Q10. 沒有 id_tunnel 時失敗（被測物不存在）"
elif [[ "$TUNNEL_RC" -eq 0 ]]; then
    # 只有 id_pool 卻成功＝還留著舊退路，這正是 task U 要拿掉的。
    IDS="$(ssh_identity_args | tr '\n' ' ')"
    fail_line "Q10. 只有 id_pool 竟仍成功（${IDS:-<無>}）——id_pool 退路未移除"
else
    ok_line "Q10. 沒有 id_tunnel 時失敗（rc=${TUNNEL_RC}），未退回 id_pool"
    IDS="$(ssh_identity_args | tr '\n' ' ')"
    if [[ "$IDS" != *"id_pool"* ]]; then
        ok_line "Q10. 命令列未帶 id_pool（${IDS:-<無>}）"
    else
        fail_line "Q10. 命令列仍帶了 id_pool（實際：${IDS}）"
    fi
fi

# 還原假 ssh（pool-sync 段落不用它，但保持環境一致）
rm -f "$FAKE_SSH_BIN"
if [[ -f "$SANDBOX/fakebin/ssh.real-for-pool-sync" ]]; then
    mv "$SANDBOX/fakebin/ssh.real-for-pool-sync" "$FAKE_SSH_BIN"
fi

# ---------------------------------------------------------------------------
# Q-Inj: 注入 — 每次都重產金鑰 → Q2 必須紅（brief 指定）
# ---------------------------------------------------------------------------
echo "── Q-Inj1 注入：ensure_tunnel_key 每次都重產 ──"
reset_home
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE="$Q_NODE_JSON"
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
# 先正常跑一次把 id_tunnel 產出來
run_sync
if [[ "$RAN" -ne 1 || ! -f "$TUNNEL_KEY_FILE" ]]; then
    fail_line "Q-Inj1. 前提：第一輪應產出 id_tunnel（目前沒有）"
else
    INJQ_SYNC="$SANDBOX/pool-sync-qinj1.sh"
    if ! python3 - "$POOL_SYNC" "$INJQ_SYNC" <<'PY'
import sys, re
src = open(sys.argv[1], encoding="utf-8").read()
old = 'if [[ ! -f "$tunnel_key" ]]; then'
assert old in src, "ensure_tunnel_key guard not found"
# 每次都重產：把存在檢查拿掉，並且強制覆寫
src = src.replace(old, 'if true; then\n            rm -f "$tunnel_key" "$tunnel_key.pub"', 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
    then
        fail_line "Q-Inj1. 注入腳本失敗（被測物形狀變了，needle 找不到）——harness 問題"
    fi
    chmod +x "$INJQ_SYNC" 2>/dev/null
    if [[ ! -x "$INJQ_SYNC" ]]; then
        fail_line "Q-Inj1. 注入版無法執行——注入沒生效（harness 問題）"
    else
    FP_BEFORE="$(tunnel_fingerprint)"
    POOL_SYNC_SUBJECT="$INJQ_SYNC"
    run_sync
    POOL_SYNC_SUBJECT=""
    FP_AFTER="$(tunnel_fingerprint)"
    # 這正是 Q2 的斷言（同一份資料、同一個比較）：現在對注入版直接斷言，
    # 而不是只印一行「會紅」。失敗了就代表測試真的抓得到。
    if [[ -z "$FP_BEFORE" || -z "$FP_AFTER" ]]; then
        fail_line "Q-Inj1. 指紋取得失敗（harness 問題：before=${FP_BEFORE:-<無>} after=${FP_AFTER:-<無>}）"
    elif [[ "$FP_BEFORE" == "$FP_AFTER" ]]; then
        fail_line "Q-Inj1. 注入後私鑰未被重產——注入沒生效（harness 問題）"
    elif [[ "$RAN" -ne 1 || "$SYNC_RC" -ne 0 ]]; then
        fail_line "Q-Inj1. 注入版沒跑起來（harness 問題：rc=${SYNC_RC}）"
    else
        ok_line "Q-Inj1. 注入「每次都重產」後，Q2 的『既有私鑰未重產』斷言會紅（${FP_BEFORE:0:12}… → ${FP_AFTER:0:12}…）"
    fi
    fi
fi

# ---------------------------------------------------------------------------
# Q-Inj2: 注入 — var 寫入改成整個覆蓋 → Q3 必須紅（brief 指定）
# ---------------------------------------------------------------------------
echo "── Q-Inj2 注入：發布改成整個覆蓋（不 merge）──"
INJQ2_SYNC="$SANDBOX/pool-sync-qinj2.sh"
if ! python3 - "$POOL_SYNC" "$INJQ2_SYNC" <<'PY'
import sys, re
src = open(sys.argv[1], encoding="utf-8").read()
old = "merged=\"$(printf '%s' \"$current\" | jq -c --arg pk \"$pub_key\" '. + {tunnel_public_key: $pk}')\" || {"
assert old in src, "merge expression not found"
new = "merged=\"$(jq -c -n --arg pk \"$pub_key\" '{tunnel_public_key: $pk}')\" || {"
src = src.replace(old, new, 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
then
    fail_line "Q-Inj2. 注入腳本失敗（被測物形狀變了，needle 找不到）——harness 問題"
fi
chmod +x "$INJQ2_SYNC" 2>/dev/null
reset_home
build_fixture "unit-a unit-b" "unit-b" ""
GIT_MODE="ok"; GH_MODE="ok"
: > "$SANDBOX/check-rc"; : > "$SANDBOX/install-rc"
GH_VALUE="$Q_NODE_JSON"
write_clients "$AUB_KEY_A" "$AUB_KEY_B" "$AUB_ACTIONS"
POOL_SYNC_SUBJECT="$INJQ2_SYNC"
run_sync
POOL_SYNC_SUBJECT=""
if [[ "$RAN" -ne 1 ]]; then
    fail_line "Q-Inj2. 注入版沒跑起來（harness 問題）"
else
    PAYLOAD="$(sed -n 's/^PAYLOAD|//p' "$SANDBOX/gh-payload.log" 2>/dev/null | tail -1)"
    # Q3 的斷言是「原有欄位全部保留」；對注入版直接斷言同一件事，
    # 紅了就代表 Q3 真的擋得住「整個覆蓋」的實作。
    if [[ -z "$PAYLOAD" ]]; then
        fail_line "Q-Inj2. payload 未被記錄（harness 問題）"
    else
        missing_fields=""
        for fld in hops power capabilities role name gateway_port; do
            jq -e --arg f "$fld" 'has($f)' <<<"$PAYLOAD" >/dev/null 2>&1 || missing_fields="${missing_fields} ${fld}"
        done
        if [[ -n "$missing_fields" ]]; then
            ok_line "Q-Inj2. 注入「整個覆蓋」後，Q3 的『原有欄位保留』斷言會紅（失去：${missing_fields}）"
        else
            fail_line "Q-Inj2. 注入後原有欄位仍在——注入沒生效（harness 問題）"
        fi
    fi
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -eq 0 ]]; then exit 0; fi
exit 1
