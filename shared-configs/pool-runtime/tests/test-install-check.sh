#!/usr/bin/env bash
# test-install-check.sh — content-comparison tests for
# shared-configs/pool-runtime/install.sh --check.
#
# Why this file exists: pool-sync's whole convergence model rests on
# install.sh --check comparing CONTENT, not existence. test-pool-sync.sh
# uses a fake install.sh, so that property had no coverage at all — an
# existence-only --check (the historical behaviour) would let stale or
# tampered ~/.mylinuxpool/bin pass as "up to date" and pool-sync would
# never repair it.
#
# Everything runs against a throwaway HOME under mktemp -d; the real home
# directory is never touched. Every check can fail, and the failure
# injection at the end proves it against the two historical failure modes:
# existence-only --check and always-pass --check.
# Run: shared-configs/pool-runtime/tests/test-install-check.sh
set -uo pipefail

UNIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
INSTALL_SH="${UNIT_ROOT}/install.sh"
FILES_DIR="${UNIT_ROOT}/files"

# The contract this test pins down: six binaries, three systemd units.
# Derived from install.sh, never restated: a second copy of this list is
# how a newly shipped file gets asserted against the old set and the gap
# goes unnoticed (tunnel-identity.sh, 2026-09-16).
BINARIES="$(sed -n 's/^BINARIES="\(.*\)"$/\1/p' "$INSTALL_SH" | head -1)"
LIBS="$(sed -n 's/^LIBS="\(.*\)"$/\1/p' "$INSTALL_SH" | head -1)"
[ -n "$BINARIES" ] || { echo "ERROR: could not read BINARIES from $INSTALL_SH" >&2; exit 1; }
[ -n "$LIBS" ] || { echo "ERROR: could not read LIBS from $INSTALL_SH" >&2; exit 1; }
UNITS="$(sed -n 's/^UNITS="\(.*\)"$/\1/p' "$INSTALL_SH" | head -1)"
[ -n "$UNITS" ] || { echo "ERROR: could not read UNITS from $INSTALL_SH" >&2; exit 1; }
# 預期數量由上面的清單算出來，不寫死：wol 單位從 pool-runtime 拆走之後
# bin/ 的檔案數本來就會少一支，寫死的數字會在設計變更時紅，卻與本檔要守的
# 「安裝內容與宣告一致」無關。
EXPECTED_FILES=$(( $(printf '%s\n' $BINARIES $LIBS | wc -l | tr -d ' ') ))
EXPECTED_UNITS=$(printf '%s\n' $UNITS | wc -l | tr -d ' ')

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-install-check.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT="timeout 30"
fi

pass=0; fail=0
ok_line()   { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
fail_line() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

INSTALL_RC=0; INSTALL_OUT=""
run_install() {
    local home="$1"; shift
    if [[ ! -x "$INSTALL_SH" ]]; then
        INSTALL_RC=127
        INSTALL_OUT="install.sh missing or not executable: ${INSTALL_SH}"
        return
    fi
    INSTALL_OUT="$($TIMEOUT "$INSTALL_SH" --home "$home" --user "$(whoami)" "$@" </dev/null 2>&1)"
    INSTALL_RC=$?
}

expect_install_ok() {
    local home="$1" label="$2"
    run_install "$home"
    if [[ "$INSTALL_RC" -eq 0 ]]; then ok_line "$label"
    else fail_line "$label (rc=${INSTALL_RC}; ${INSTALL_OUT})"; fi
}

expect_check_zero() {
    local home="$1" label="$2"
    run_install "$home" --check
    if [[ "$INSTALL_RC" -eq 0 ]]; then ok_line "$label"
    else fail_line "$label (--check rc=${INSTALL_RC}，應該 0; ${INSTALL_OUT})"; fi
}

expect_check_nonzero() {
    local home="$1" label="$2"
    run_install "$home" --check
    if [[ "$INSTALL_RC" -eq 0 ]]; then
        fail_line "$label (--check 回 0，應該非 0)"
    elif [[ "$INSTALL_RC" -eq 126 || "$INSTALL_RC" -eq 127 ]]; then
        fail_line "$label (無法執行 install.sh，rc=${INSTALL_RC}; ${INSTALL_OUT})"
    else
        ok_line "$label"
    fi
}

# 安裝成功是 3/4/5 的前提；失敗時只印一個 FAIL 並跳過該案，避免
# 「因為檔案根本不存在所以 --check 非 0」的假通過。
fresh_installed_home() {
    local home="$1"
    rm -rf "$home"
    run_install "$home"
    if [[ "$INSTALL_RC" -ne 0 ]]; then
        fail_line "前提失敗：完整安裝 ${home} 回 rc=${INSTALL_RC}（${INSTALL_OUT}）"
        return 1
    fi
    return 0
}

# tamper_one_byte <file> — 覆寫第一個位元組並確認內容真的變了。
# 沒變（或檔案不存在）就回非 0，讓呼叫端據實 FAIL 而不是假通過。
tamper_one_byte() {
    local f="$1" before after
    before="$(cksum "$f" 2>/dev/null)"
    printf 'X' | dd of="$f" bs=1 count=1 conv=notrunc >/dev/null 2>&1 || return 1
    after="$(cksum "$f" 2>/dev/null)"
    [[ -n "$before" && -n "$after" && "$before" != "$after" ]]
}

# ---------------------------------------------------------------------------
echo "── 前置：來源檔齊全 ──"
missing=""
for f in $BINARIES $UNITS; do
    [[ -f "${FILES_DIR}/${f}" ]] || missing="${missing} ${f}"
done
if [[ -z "$missing" ]]; then
    ok_line "files/ 內有 ${EXPECTED_FILES} 支 bin + ${EXPECTED_UNITS} 個 unit 來源檔（數量由 install.sh 的清單算出）"
else
    fail_line "files/ 缺少來源檔：${missing}"
fi

# ---------------------------------------------------------------------------
echo "── 1) 全新 HOME：--check 必須非 0 ──"
H1="$SANDBOX/home-1"
rm -rf "$H1"
expect_check_nonzero "$H1" "全新 HOME（未安裝）→ --check 非 0"

# ---------------------------------------------------------------------------
echo "── 2) 完整安裝後：--check 必須 0 ──"
H2="$SANDBOX/home-2"
rm -rf "$H2"
expect_install_ok "$H2" "完整安裝（不帶 --check）→ rc 0"
expect_check_zero "$H2" "安裝後 → --check 回 0"

# ---------------------------------------------------------------------------
echo "── 3) bin/pool-status 內容改一個字元：--check 必須非 0 ──"
H3="$SANDBOX/home-3"
if fresh_installed_home "$H3"; then
    if tamper_one_byte "$H3/.mylinuxpool/bin/pool-status"; then
        expect_check_nonzero "$H3" "bin/pool-status 內容被改（檔案仍在）→ --check 非 0"
    else
        fail_line "bin/pool-status 不存在或無法破壞，無從驗證內容比對"
    fi
fi

# ---------------------------------------------------------------------------
echo "── 4) 刪掉 bin/pool-sync：--check 必須非 0 ──"
H4="$SANDBOX/home-4"
if fresh_installed_home "$H4"; then
    rm -f "$H4/.mylinuxpool/bin/pool-sync"
    expect_check_nonzero "$H4" "bin/pool-sync 被刪 → --check 非 0"
fi

# ---------------------------------------------------------------------------
echo "── 5) pool-sync.timer 內容被改：--check 必須非 0 ──"
H5="$SANDBOX/home-5"
if fresh_installed_home "$H5"; then
    if tamper_one_byte "$H5/.config/systemd/user/pool-sync.timer"; then
        expect_check_nonzero "$H5" "pool-sync.timer 內容被改（檔案仍在）→ --check 非 0"
    else
        fail_line "pool-sync.timer 不存在或無法破壞，無從驗證內容比對"
    fi
fi

# ---------------------------------------------------------------------------
# --check must notice a MISSING sourced library, not just missing binaries:
# pool-sync decides whether to reinstall from --check's exit code, so a
# library it ignores is a library that never gets repaired — and without
# tunnel-identity.sh every pool-* script dies at source time.
echo "── 5b) --check 抓得到被刪掉的函式庫 ──"
H5B="$SANDBOX/home-5b"
if fresh_installed_home "$H5B"; then
    for f in $LIBS; do
        rm -f "$H5B/.mylinuxpool/bin/$f"
    done
    expect_check_nonzero "$H5B" "刪掉函式庫後 --check 非 0（否則 pool-sync 永遠不會修復它）"
fi

echo "── 6) 安裝內容：7 支 bin + 3 個 unit ──"
H6="$SANDBOX/home-6"
rm -rf "$H6"
if fresh_installed_home "$H6"; then
    n=0
    for f in $BINARIES; do
        if [[ -x "$H6/.mylinuxpool/bin/$f" ]]; then
            ok_line "bin/${f} 存在且可執行"
            n=$((n + 1))
        else
            fail_line "bin/${f} 不存在或不可執行"
        fi
    done
    for f in $LIBS; do
        if [[ -f "$H6/.mylinuxpool/bin/$f" ]]; then
            ok_line "bin/${f} 已安裝（被 source，刻意不帶執行位元）"
        else
            fail_line "bin/${f} 未安裝——source 它的 pool-tunnel/pool-status/pool-sync 會啟動失敗"
        fi
    done
    inst_count="$(ls -A "$H6/.mylinuxpool/bin" 2>/dev/null | wc -l | tr -d ' ')"
    # tunnel-identity.sh is the one definition of the tunnel key path, and
    # pool-tunnel / pool-status / pool-sync source it. If install.sh stops
    # shipping it, every one of them dies at source time and the machine
    # loses its tunnel — name it explicitly rather than trusting the count.
    if [[ -f "$H6/.mylinuxpool/bin/tunnel-identity.sh" ]]; then
        ok_line "bin/tunnel-identity.sh 已安裝（pool-tunnel 等會 source 它）"
    else
        fail_line "bin/tunnel-identity.sh 未安裝——pool-tunnel/pool-status/pool-sync 會 source 失敗，機器失去隧道"
    fi
    if [[ "$inst_count" -eq "$EXPECTED_FILES" ]]; then
        ok_line "bin/ 恰好 ${EXPECTED_FILES} 支檔案（與 install.sh 宣告的清單一致）"
    else
        fail_line "bin/ 應該恰好 ${EXPECTED_FILES} 支，實際 ${inst_count} 支"
    fi

    m=0
    for f in $UNITS; do
        if [[ -f "$H6/.config/systemd/user/$f" ]]; then
            ok_line "systemd user unit ${f} 存在"
            m=$((m + 1))
        else
            fail_line "systemd user unit ${f} 不存在"
        fi
    done
    unit_count="$(ls -A "$H6/.config/systemd/user" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$unit_count" -eq "$EXPECTED_UNITS" ]]; then
        ok_line "unit 目錄恰好 ${EXPECTED_UNITS} 個檔案（與 install.sh 宣告的清單一致）"
    else
        fail_line "unit 目錄應該恰好 ${EXPECTED_UNITS} 個，實際 ${unit_count} 個"
    fi
else
    fail_line "安裝失敗，無法驗證 6+3 的安裝內容"
fi

# ---------------------------------------------------------------------------
# 失敗注入（示範，不計入上面的總分）：把 --check 換成歷史上的兩種壞法，
# 證明上面的斷言真的抓得到。
# ---------------------------------------------------------------------------
echo
echo "── 失敗注入（示範，不計入總分）──"
DEMO_TOTAL=0; DEMO_CAUGHT=0; DEMO_BROKEN=0

demo_record() {
    DEMO_TOTAL=$((DEMO_TOTAL + 1))
    if [[ "$1" -eq 1 ]]; then
        DEMO_CAUGHT=$((DEMO_CAUGHT + 1))
        printf '  [demo] caught  %s\n' "$2"
    else
        printf '  [demo] MISSED  %s（這個壞法不會被上面的斷言抓到）\n' "$2"
    fi
}

MUTANT_DIR=""
make_mutant() {
    # $1 = 變體名, $2 = sed 表達式
    MUTANT_DIR="$SANDBOX/mutant-$1"
    rm -rf "$MUTANT_DIR"
    mkdir -p "$MUTANT_DIR/files"
    cp "$FILES_DIR"/* "$MUTANT_DIR/files/" 2>/dev/null
    sed "$2" "$INSTALL_SH" > "$MUTANT_DIR/install.sh"
    chmod +x "$MUTANT_DIR/install.sh"
    cmp -s "$MUTANT_DIR/install.sh" "$INSTALL_SH" && return 1
    return 0
}

MUTANT_RC=0; MUTANT_OUT=""
run_mutant_install() {
    local home="$1"; shift
    MUTANT_OUT="$($TIMEOUT "$MUTANT_DIR/install.sh" --home "$home" --user "$(whoami)" "$@" </dev/null 2>&1)"
    MUTANT_RC=$?
}

# 變體 A：存在性檢查（歷史行為）。內容被改也回 0。
if make_mutant existence-only 's|cmp -s "$installed" "$source"|return 0|' \
   && ! grep -q 'cmp -s' "$MUTANT_DIR/install.sh"; then
    # A1：改掉 bin/pool-status 一個字元
    HD="$SANDBOX/demo-a1"; rm -rf "$HD"
    run_mutant_install "$HD"
    if [[ "$MUTANT_RC" -ne 0 ]]; then
        printf '  [demo] 無法安裝變體 A（rc=%s）\n' "$MUTANT_RC"
        demo_record 0 "存在性 --check + 被改的 bin/pool-status"
    elif tamper_one_byte "$HD/.mylinuxpool/bin/pool-status"; then
        run_mutant_install "$HD" --check
        [[ "$MUTANT_RC" -eq 0 ]] && demo_record 1 "存在性 --check + 被改的 bin/pool-status" \
                                 || demo_record 0 "存在性 --check + 被改的 bin/pool-status"
    else
        demo_record 0 "存在性 --check + 被改的 bin/pool-status（無法破壞檔案）"
    fi
    # A2：改掉 pool-sync.timer
    HD="$SANDBOX/demo-a2"; rm -rf "$HD"
    run_mutant_install "$HD"
    if [[ "$MUTANT_RC" -ne 0 ]]; then
        demo_record 0 "存在性 --check + 被改的 pool-sync.timer"
    elif tamper_one_byte "$HD/.config/systemd/user/pool-sync.timer"; then
        run_mutant_install "$HD" --check
        [[ "$MUTANT_RC" -eq 0 ]] && demo_record 1 "存在性 --check + 被改的 pool-sync.timer" \
                                 || demo_record 0 "存在性 --check + 被改的 pool-sync.timer"
    else
        demo_record 0 "存在性 --check + 被改的 pool-sync.timer（無法破壞檔案）"
    fi
else
    printf '  [demo] 無法產生變體 A（sed 沒改到檔案）\n'
    demo_record 0 "存在性 --check + 被改的 bin/pool-status"
    demo_record 0 "存在性 --check + 被改的 pool-sync.timer"
fi

# 變體 B：永遠回 0。全新 HOME 也會說「已安裝」。
if make_mutant always-pass 's|^check_installed() {|check_installed() { return 0;|' \
   && grep -q 'check_installed() { return 0;' "$MUTANT_DIR/install.sh"; then
    HD="$SANDBOX/demo-b"; rm -rf "$HD"
    run_mutant_install "$HD" --check
    [[ "$MUTANT_RC" -eq 0 ]] && demo_record 1 "永遠通過的 --check + 全新 HOME" \
                             || demo_record 0 "永遠通過的 --check + 全新 HOME"
else
    printf '  [demo] 無法產生變體 B（sed 沒改到檔案）\n'
    demo_record 0 "永遠通過的 --check + 全新 HOME"
fi

if [[ "$DEMO_TOTAL" -gt 0 && "$DEMO_CAUGHT" -eq "$DEMO_TOTAL" ]]; then
    printf '[demo] %s/%s：內容比對的斷言抓得到存在性檢查與永遠通過的 --check\n' \
        "$DEMO_CAUGHT" "$DEMO_TOTAL"
else
    printf '[demo] DEMO FAILED: caught %s/%s\n' "$DEMO_CAUGHT" "$DEMO_TOTAL"
    DEMO_BROKEN=1
fi

echo
demo_status="ok"
if [[ "$DEMO_BROKEN" -ne 0 ]]; then demo_status="FAILED"; fi
printf 'passed %d / failed %d / demo %s\n' "$pass" "$fail" "$demo_status"
if [[ "$fail" -ne 0 ]]; then exit 1; fi
if [[ "$DEMO_BROKEN" -ne 0 ]]; then exit 2; fi
exit 0
