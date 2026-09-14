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
    obj="$(jq -c -n --arg n "$name" --arg v "${FAKE_GH_VALUE}" '{name:$n,value:$v}')"
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
}

GIT_MODE="ok"
GH_MODE="ok"
GH_VALUE='{"name":"testnode","role":"provider","registered_with":"register-provider.sh"}'

run_sync() {
    : > "$SANDBOX/install.log"; : > "$SANDBOX/systemctl.log"
    : > "$SANDBOX/git.log"; : > "$SANDBOX/gh.log"
    rm -rf "$SANDBOX/tmpdir"; mkdir -p "$SANDBOX/tmpdir"
    SYNC_RC=0; RAN=0
    if [[ ! -x "$POOL_SYNC" ]]; then
        SYNC_RC=127
        printf 'pool-sync missing or not executable: %s\n' "$POOL_SYNC" > "$SANDBOX/err"
        : > "$SANDBOX/out"
    else
        RAN=1
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
        FAKE_SYSTEMCTL_LOG="$SANDBOX/systemctl.log" \
        FAKE_GIT_MODE="$GIT_MODE" \
        FAKE_GH_MODE="$GH_MODE" \
        FAKE_GH_VALUE="$GH_VALUE" \
        $TIMEOUT "$POOL_SYNC" > "$SANDBOX/out" 2> "$SANDBOX/err" </dev/null
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

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -eq 0 ]]; then exit 0; fi
exit 1
