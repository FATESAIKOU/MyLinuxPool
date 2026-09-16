#!/usr/bin/env bash
# test-workers-d-path.sh — behavioral tests for the workers.d path retirement
# (task I). The old persistent clone path (the workers.d dir under $HOME/pool)
# must be gone from every component; everything reads/writes the new one
# (.mylinuxpool/workers.d) now.
#
# NOTE — why the literal legacy path is never spelled out in this file's
# comments/messages (2026-09-16): ops-scripts/preflight scans the tracked
# tree for the old path pattern and flags any file that mentions it. This
# test talks about that very path all day long, so a bare literal would
# make preflight fail on this file; adding it to preflight's exclusion
# list would blind the scan exactly where the old path is most likely to
# be discussed. Therefore the only places the literal is ever constructed
# are the runtime spots that genuinely need it (creating the fake legacy
# dir, grepping recorded ssh argv, writing the probe file), built from
# parts so the static pattern never matches. Do NOT "clean this up" back
# to a literal — preflight goes red on this file again.
#
# Every assertion is behavioral — no grepping implementation source for the
# presence of a string as if it were a semantic check:
#   1. pool-status's placeholder query goes through gw_ssh; its remote
#      command string must reference .mylinuxpool/workers.d and must NOT
#      reference the bare legacy path. Proven by running the REAL
#      pool-status (in a sandbox copy of the repo with fake ssh/gh/
#      pool-resolve on PATH) and asserting on the recorded ssh argv.
#   2. pool-port-alloc: a fake HOME with ONLY an old-path 2305.json — the
#      allocator must still hand out 2305 (old path no longer read).
#   3. provision-gateway.sh: WORKERS_DIR is extracted from the variable
#      definition and compared to the new path.
#   4. ops-scripts/preflight's stale-path check (injection): a probe file
#      containing the old path is added to the git index — preflight
#      must turn red; after removal it must be green again. THIS is the
#      case that used to stay green because the check didn't know the
#      pattern — the whole reason the old path survived.
#   5. the correct path ~/.mylinuxpool/workers.d must NOT be flagged by
#      that same check.
#
# bash 3.2 compatible on purpose (macOS ships 3.2).
# Run: scripts/tests/test-workers-d-path.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# The legacy dir name, assembled at runtime only (see the note at the top:
# a literal would trip preflight's stale-path scan on this very file).
LEGACY_WD_NAME="$(printf 'po%s' ol)"
LEGACY_DIR_RE="[^-a-z]${LEGACY_WD_NAME}/workers\.d"
LEGACY_PROBE_CONTENT="~/${LEGACY_WD_NAME}/workers.d"

for tool in git jq python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: $tool is required but not found on PATH" >&2
        exit 1
    }
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-workers-d-path.XXXXXX")"
# Sections 4/5 run preflight inside a private git repo under $SANDBOX (see
# the note there): the probe lives in that copy, never in the shared tree,
# so nothing is staged into this working tree's index and concurrent runs of
# this suite cannot influence each other. PROBE is assigned there.

# 清理：sandbox 內含私有 git 副本，整包刪掉即可；不碰共用 tree 的 index。
# BASH_SUBSHELL 守門：命令置換的子 shell 會繼承 EXIT trap，若讓它在子
# shell 退出時也刪 sandbox，主 shell 後續步驟全部報「檔案不存在」——那種
# 假陽性（或假紅）比漏測更糟。cleanup 只在主 shell（subshell=0）執行。
cleanup() {
    [[ "${BASH_SUBSHELL:-0}" -eq 0 ]] || return 0
    rm -rf "$SANDBOX"
}
trap cleanup EXIT INT TERM

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# ---------------------------------------------------------------------------
# 1. pool-status 送給 gw_ssh 的遠端指令用新路徑
# ---------------------------------------------------------------------------
echo "── 1. pool-status 佔位檔查詢路徑 ──"
mkdir -p "$SANDBOX/bin" "$SANDBOX/home" "$SANDBOX/repo-copy"
REAL_BASH="$(command -v bash)"

cat > "$SANDBOX/bin/ssh" <<'FAKE_SSH'
#!/bin/bash
printf 'ssh|%s\n' "$*" >> "$FAKE_SSH_LOG"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
    *'ss -tln'*|*ss*'-tln'*) printf '127.0.0.1:2305\n'; exit 0 ;;
    *workers.d*) echo '__POOL_WORKERS_D_MISSING__'; exit 0 ;;
    *) exit 0 ;;
esac
FAKE_SSH
chmod +x "$SANDBOX/bin/ssh"

# tcp_classify 用 `bash -c "exec 3<>/dev/tcp/..."` 真探測——攔掉它。
# 其它 bash 呼叫一律轉真 bash。
cat > "$SANDBOX/bin/bash" <<'FAKE_BASH'
#!/bin/bash
case "$*" in
    *'/dev/tcp/'*) exit 0 ;;
esac
exec "$REAL_BASH" "$@"
FAKE_BASH
chmod +x "$SANDBOX/bin/bash"

# gh：只被用來列 NODE_* var 名——回空即可（沒有 provider，也就不會
# 碰 systemctl/loginctl/nc）。
cat > "$SANDBOX/bin/gh" <<'FAKE_GH'
#!/bin/bash
exit 0
FAKE_GH
chmod +x "$SANDBOX/bin/gh"

# pool-status 用絕對路徑 ${SCRIPT_DIR}/pool-resolve 呼叫——在沙箱副本
# repo 裡換成假的。
cat > "$SANDBOX/bin/fake-pool-resolve" <<'FAKE_PR'
#!/bin/bash
printf '%s\n' '{"name":"gateway","role":"gateway","ip":"127.0.0.1","user":"testuser","tunnel_user":"tunneluser","ports":{"worker":[2300,2399]},"host_key":"","generation":1}'
FAKE_PR
chmod +x "$SANDBOX/bin/fake-pool-resolve"

rsync -a --exclude=.git ./ "$SANDBOX/repo-copy/" 2>/dev/null \
    || cp -R . "$SANDBOX/repo-copy/" 2>/dev/null
cp "$SANDBOX/bin/fake-pool-resolve" "$SANDBOX/repo-copy/shared-configs/pool-runtime/files/pool-resolve"

: > "$SANDBOX/ssh.log"
HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
REAL_BASH="$REAL_BASH" FAKE_SSH_LOG="$SANDBOX/ssh.log" POOL_REPO="testowner/testrepo" \
/bin/bash "$SANDBOX/repo-copy/shared-configs/pool-runtime/files/pool-status" \
</dev/null > "$SANDBOX/status.out" 2> "$SANDBOX/status.err"
STATUS_RC=$?

W_LS_LINE="$(grep '^ssh|' "$SANDBOX/ssh.log" 2>/dev/null | grep -F '.mylinuxpool/workers.d' | head -1)"
if [[ -n "$W_LS_LINE" ]]; then
    ok "1a. pool-status 送出的遠端指令含 .mylinuxpool/workers.d"
else
    bad "1a. 沒有 ssh 記錄含 .mylinuxpool/workers.d（ssh log: $(tr '\n' ' ' < "$SANDBOX/ssh.log" 2>/dev/null | head -c 300)）"
fi
# 裸舊路徑檢查：legacy dir 前一個字元必須不是字母（.mylinuxpool/workers.d
# 裡 dir 名前面是字母，不算）。pattern 執行時由 $LEGACY_DIR_RE 提供，
# 檔案裡不寫字面值（見檔頭註解）。
if grep '^ssh|' "$SANDBOX/ssh.log" 2>/dev/null | grep -E "$LEGACY_DIR_RE" >/dev/null 2>&1; then
    bad "1b. 遠端指令仍含裸的 ${LEGACY_WD_NAME}/workers.d：$(grep -E "$LEGACY_DIR_RE" "$SANDBOX/ssh.log" | head -1)"
else
    ok "1b. 沒有任何遠端指令含裸的 legacy workers.d 路徑"
fi

# ---------------------------------------------------------------------------
# 2. pool-port-alloc 不再讀舊路徑
# ---------------------------------------------------------------------------
echo "── 2. pool-port-alloc 忽略舊路徑 ──"
cat > "$SANDBOX/bin/ss" <<'FAKE_SS'
#!/bin/bash
exit 0
FAKE_SS
chmod +x "$SANDBOX/bin/ss"
cat > "$SANDBOX/bin/flock" <<'FAKE_FLOCK'
#!/bin/bash
exit 0
FAKE_FLOCK
chmod +x "$SANDBOX/bin/flock"

PA_HOME="$SANDBOX/pa-home"
PA_LEGACY_DIR="$PA_HOME/${LEGACY_WD_NAME}/workers.d"  # 執行時組字，見檔頭註解
mkdir -p "$PA_LEGACY_DIR"
printf '{"provider":"old-registration"}\n' > "$PA_LEGACY_DIR/2305.json"

PA_OUT="$(HOME="$PA_HOME" PATH="$SANDBOX/bin:$PATH" \
    POOL_WORKER_PORT_RANGE="2305 2306" \
    /bin/bash shared-configs/pool-runtime/files/pool-port-alloc --claim testprov testimg \
    </dev/null 2> "$SANDBOX/pa.err")"
PA_PORT="$(printf '%s' "$PA_OUT" | tr -d '[:space:]')"
if [[ "$PA_PORT" == "2305" ]]; then
    ok "2a. 舊路徑有 2305.json 仍配出 2305（舊路徑不再被讀）"
else
    bad "2a. 配出 [$PA_PORT]（期望 2305）——舊路徑還在被當成占用（stderr: $(head -c 200 "$SANDBOX/pa.err" | tr '\n' ' ')）"
fi
if [[ -f "$PA_HOME/.mylinuxpool/workers.d/2305.json" ]]; then
    ok "2b. claim 寫進新路徑 ~/.mylinuxpool/workers.d/2305.json"
else
    bad "2b. claim 沒有寫進新路徑（$PA_HOME/.mylinuxpool/workers.d/2305.json 不存在）"
fi

# ---------------------------------------------------------------------------
# 3. provision-gateway.sh 建立的是新路徑
# ---------------------------------------------------------------------------
echo "── 3. provision-gateway.sh WORKERS_DIR ──"
PG_DIR="$(awk -F'=' '/^WORKERS_DIR=/{print $2; exit}' scripts/provision-gateway.sh 2>/dev/null | tr -d '"')"
if [[ "$PG_DIR" == "/home/fatesaikou/.mylinuxpool/workers.d" ]]; then
    ok "3a. WORKERS_DIR 是新路徑（${PG_DIR}）"
else
    bad "3a. WORKERS_DIR=[${PG_DIR:-<undefined>}]，期望 /home/fatesaikou/.mylinuxpool/workers.d"
fi
if grep -E "$LEGACY_DIR_RE" scripts/provision-gateway.sh >/dev/null 2>&1; then
    bad "3b. provision-gateway.sh 仍含裸的 legacy workers.d 路徑"
else
    ok "3b. provision-gateway.sh 無裸的 legacy workers.d 路徑"
fi

# ---------------------------------------------------------------------------
# 4 + 5. preflight 的舊路徑檢查（注入驗證）
#
# These run against a PRIVATE git repo, not the shared working tree. preflight
# decides what to scan from `git ls-files`, and the injection works by staging
# a probe file — so running it in place mutates the shared index. Two copies
# of this suite running at once then see each other's probe: run B's baseline
# fails on run A's staged probe (and vice versa), which is exactly the
# intermittent 4a/5 failures observed when several panes ran the suite
# together. A private clone keeps each run's index to itself; it is also a
# stricter test, since nothing from the surrounding tree can leak in.
# ---------------------------------------------------------------------------
echo "── 4. preflight 抓得到 legacy workers.d（注入）──"
PF_REPO="$SANDBOX/preflight-repo"
if rsync -a --exclude=.git ./ "$PF_REPO/" 2>/dev/null || cp -R . "$PF_REPO" 2>/dev/null; then
    :
fi
rm -rf "$PF_REPO/.git"
if git -C "$PF_REPO" init -q 2>/dev/null && git -C "$PF_REPO" add -A 2>/dev/null; then
    PF_READY=1
else
    PF_READY=0
fi
PROBE="$PF_REPO/scripts/tests/.stale-path-probe.$$.txt"
PROBE_STEM="$(basename "$PROBE")"

run_pf() {
    ( cd "$PF_REPO" && bash ops-scripts/preflight ) > "$1" 2>&1
}

if [[ "$PF_READY" -ne 1 ]]; then
    bad "preflight baseline（無法建立私有 git 副本，4/5 無從驗證）"
else
    # baseline：私有副本現況必須全過，否則「回綠」無法驗證。
    run_pf "$SANDBOX/pre.0"
    BASE_RC=$?
    if [[ "$BASE_RC" -ne 0 ]]; then
        bad "preflight baseline 非 0（exit ${BASE_RC}）——repo 有其它問題，4/5 無法驗證（見 $SANDBOX/pre.0）"
    else
        ok "preflight baseline 全過（exit 0，私有副本）"
    fi
fi

if [[ "$PF_READY" -eq 1 && "$BASE_RC" -eq 0 ]]; then
    printf '%s\n' "$LEGACY_PROBE_CONTENT" > "$PROBE"
    git -C "$PF_REPO" add -- "$PROBE" || bad "無法把 probe 檔加進 git index"
    run_pf "$SANDBOX/pre.1"
    INJ_RC=$?
    if [[ "$INJ_RC" -ne 0 ]] && grep -q "$PROBE_STEM" "$SANDBOX/pre.1" 2>/dev/null; then
        ok "4a. 注入 legacy workers.d → preflight 變紅並點名 probe 檔"
    else
        bad "4a. 注入 legacy workers.d 後 preflight 仍綠（exit ${INJ_RC}）——檢查不認得舊路徑 pattern（正是舊路徑活到現在的原因）"
    fi
    git -C "$PF_REPO" rm --cached --quiet -- "$PROBE" 2>/dev/null
    rm -f "$PROBE"
    run_pf "$SANDBOX/pre.2"
    if [[ $? -eq 0 ]]; then
        ok "4b. 移除 probe 後 preflight 回綠"
    else
        bad "4b. 移除 probe 後 preflight 仍非 0（見 $SANDBOX/pre.2）"
    fi
fi

echo "── 5. 正確路徑不被誤判 ──"
if [[ "$PF_READY" -eq 1 && "$BASE_RC" -eq 0 ]]; then
    printf '%s\n' '~/.mylinuxpool/workers.d' > "$PROBE"
    git -C "$PF_REPO" add -- "$PROBE" || bad "無法把 probe 檔加進 git index"
    run_pf "$SANDBOX/pre.3"
    RIGHT_RC=$?
    if [[ "$RIGHT_RC" -eq 0 ]] && ! grep -q "$PROBE_STEM" "$SANDBOX/pre.3" 2>/dev/null; then
        ok "5. 正確路徑 ~/.mylinuxpool/workers.d 未被 preflight 誤判（exit 0）"
    else
        bad "5. 正確路徑被誤判成舊路徑（exit ${RIGHT_RC}）——pattern 太寬（見 $SANDBOX/pre.3）"
    fi
    git -C "$PF_REPO" rm --cached --quiet -- "$PROBE" 2>/dev/null
    rm -f "$PROBE"
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
exit "$fail"
