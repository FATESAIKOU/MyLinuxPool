#!/usr/bin/env bash
# test-pool-tunnel-static-port.sh — 靜態模式的 Gateway SSH 埠（D3，issue #6）。
#
# 在防什麼（真線會咬人的那一種）：
#   `pool-tunnel` 的靜態模式（POOL_GATEWAY_HOST/PORT/USER 三個全設）不呼叫
#   pool-resolve、不碰 GitHub——家人 VM 只能走這條（它沒有 provider 可發布
#   gateway.json，follow 模式對它不可用）。但靜態分支**不設** GW_SSH_PORT，
#   最後 `ssh -p "${GW_SSH_PORT:-22}"`（pool-tunnel:500）用預設 22——
#   而現行 Gateway 的 SSH 在 2100（NODE_GATEWAY.port；docs/ARCHITECTURE.md:41）。
#   靜態模式對現在的 Gateway 會連 22、永遠連不上，症狀是「一直重試」。
#
# 設計裁示（openspec/changes/archive/2026-10-01-family-repair-host/design.md D3）：
#   靜態模式加一個選填環境變數 POOL_GATEWAY_SSH_PORT；沒給 → 行為與現在
#   相同（22），所以 worker 的既有退路不受影響。
#
# 要驗的（行為面，不綁實作寫法、只綁 design 定的變數名）：
#   1. 靜態模式 + POOL_GATEWAY_SSH_PORT=2100 → 實際撥號的 ssh argv 帶 `-p 2100`
#      （對現碼紅：它只會帶 -p 22）
#   2. 靜態模式 + 未設該變數 → ssh argv 帶 `-p 22`（回歸保護，對現碼綠）
#   3. follow 模式的 ssh_port 不受影響（既有行為回歸，對現碼綠）
#   4. 實作使用 design D3 的變數名 POOL_GATEWAY_SSH_PORT（對現碼紅）
#   5. 正對照：假 ssh 真的被呼叫到、argv 真的被記下（量到 0 不算證據）
#   6. 注入：拿掉新變數的讀取 → 1 必須紅；把 `-p` 拿掉 → 1、2 必須紅
#   7. 無效值（abc、0、65536、前導零 08、20 位數）→ --once 非 0、零 ssh 呼叫、
#      log 含 "not a valid port"
#   8. 注入：拿掉驗證 → 7 的每個值都必須紅
#
# 驅動方式：pool-tunnel 是長跑迴圈，`--once` 讓它只做一次連線嘗試——假 ssh
#   立即失敗（背景撥號 exit 255），所以 start_master 失敗 → `--once` 直接
#   exit 1；撥號 argv 已落在 SSH_LOG。這不是等「連上」，是要看它「怎麼撥」。
#
# ---- 這支測試看不到什麼（誠實記在這裡）------------------------------------
# * 真連線：沒有真的對 Gateway 撥號；驗的是 argv 形狀，不是封包。
# * resolve 模式（有 token 的 provider 路徑）：那條讀 NODE_GATEWAY.port，
#   本檔不驅動（需要假 pool-resolve 與更長的資料流）；設計上不受 D3 影響。
# * 假 ssh 的 `-O check` 一律失敗，所以只會走到「一次嘗試即失敗」；
#   backoff 節奏（D7）不在本檔。
# * 注入 5（改名法）在實作落地前沒有 needle，會以「跳過」記，不是假綠——
#   現碼本來就沒有那個讀取，1 的紅已由 §1 直接量到。
#
# 全離線：ssh/sleep 走 PATH stub；不連網、不碰 Gateway；bash 3.2 相容。
# Run: scripts/tests/test-pool-tunnel-static-port.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

PTUNNEL="shared-configs/pool-runtime/files/pool-tunnel"

if [[ ! -f "$PTUNNEL" ]]; then
    echo "test-pool-tunnel-static-port: ${PTUNNEL} is missing; every case below will FAIL" >&2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-ptunnel-port.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
mkdir -p "$SHIMS" "$HOME_DIR/.ssh"
# 隧道金鑰檔：pool-tunnel 會 -i 它。沒有它時 bash 3.2 的空陣列展在 set -u
# 下會炸（identity_opts[@] unbound）——那是無關的既有平台怪癖，給一個 dummy
# 讓流程走到我們要看的 ssh 撥號行。
printf 'DUMMY\n' > "$HOME_DIR/.ssh/id_tunnel"
chmod 600 "$HOME_DIR/.ssh/id_tunnel"
# 注入副本需要與 tunnel-identity.sh 同目錄（SCRIPT_DIR 由 BASH_SOURCE 導出）。
cp "$REPO_ROOT/shared-configs/pool-runtime/files/tunnel-identity.sh" "$SANDBOX/tunnel-identity.sh"

pass=0; fail=0; injpass=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }
inj_skip() { printf '  --    (注入略) %s\n' "$1"; }

# 假 ssh：記 argv。`-O check` 一律失敗（沒有既存 ControlMaster），
# 真正的撥號（-M -S …）也失敗並帶可辨識 stderr——我們只讀 argv。
cat > "$SHIMS/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SSH_LOG:-/dev/null}"
case "$*" in
    *"-O check"*) exit 255 ;;
    *"-O exit"*)  exit 0 ;;
esac
echo "fake ssh: connection refused" >&2
exit 255
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIMS/sleep"
chmod +x "$SHIMS/ssh" "$SHIMS/sleep"

# run_ptunnel <lib-path> [額外環境賦值...]：跑 pool-tunnel --once 一次嘗試。
# 設定 PT_OUT（stdout+stderr）與 PT_RC；argv 落在 $SANDBOX/ssh.log。
run_ptunnel() {
    local lib="$1"; shift
    : > "$SANDBOX/ssh.log"
    PT_OUT="$(env -i PATH="$SHIMS:$PATH" HOME="$HOME_DIR" \
        SSH_LOG="$SANDBOX/ssh.log" \
        POOL_GATEWAY_PORT=2300 POOL_GATEWAY_HOST=203.0.113.9 POOL_GATEWAY_USER=sshproxy \
        "$@" \
        bash "$lib" --once 2>&1)"
    PT_RC=$?
}

dial_argv() {
    grep -e '-M -S' "$SANDBOX/ssh.log" 2>/dev/null | tail -n 1
}

echo "=== 0. 先決條件 ==="
if grep -q 'GW_SSH_PORT' "$PTUNNEL" && grep -q 'POOL_GATEWAY_HOST' "$PTUNNEL"; then
    ok "0. pool-tunnel 有 GW_SSH_PORT 與靜態模式分支"
else
    bad "0. pool-tunnel 形狀變了——本檔斷言的前提不成立"
fi

echo "=== 1. 靜態模式指定 SSH port（D3 核心；對現碼紅） ==="
run_ptunnel "$REPO_ROOT/$PTUNNEL" POOL_GATEWAY_SSH_PORT=2100
argv="$(dial_argv)"
if [[ -z "$argv" ]]; then
    # 正對照先行：假 ssh 沒被叫到時，「沒帶 -p 2100」不具資訊量。
    bad "1（正對照失敗）：假 ssh 沒有收到撥號呼叫——後面斷言不可信（rc=${PT_RC} out [$(printf '%s' "$PT_OUT" | tr '\n' '|' | head -c 200)]）"
else
    ok "1a. 正對照：假 ssh 收到撥號呼叫（rc=${PT_RC}，argv 已記錄）"
    if printf '%s' "$argv" | grep -q -e '-p 2100'; then
        ok "1b. 靜態模式帶 POOL_GATEWAY_SSH_PORT=2100 → ssh 帶 '-p 2100'"
    else
        bad "1b. 靜態模式帶 POOL_GATEWAY_SSH_PORT=2100 但 ssh 沒有 '-p 2100'（got argv [$argv]）——維修承載機會連 22、連不上現在的 Gateway"
    fi
    if printf '%s' "$argv" | grep -q -e '-p 22'; then
        bad "1c. argv 仍帶 '-p 22'——新變數沒有取代預設（got [$argv]）"
    else
        ok "1c. argv 沒有殘留 '-p 22'（新變數取代預設，不是並存）"
    fi
fi

echo "=== 2. 未指定時維持現行行為 22（回歸保護；對現碼綠） ==="
run_ptunnel "$REPO_ROOT/$PTUNNEL"
argv="$(dial_argv)"
if [[ -n "$argv" ]] && printf '%s' "$argv" | grep -q -e '-p 22'; then
    ok "2. 未設 POOL_GATEWAY_SSH_PORT → ssh 帶 '-p 22'（與現在相同）"
else
    bad "2. 未設新變數時行為變了（argv [$argv]）——既有呼叫端（worker 退路）會受影響"
fi

echo "=== 3. follow 模式的 ssh_port 不受影響（既有行為回歸；對現碼綠） ==="
# gateway.json 帶 ssh_port=2100；follow 模式（POOL_GATEWAY_FILE 可讀）用它。
# 這一條不設新變數，證明 D3 沒動到 follow 路徑。
GWJSON="$SANDBOX/gateway.json"
printf '{"ip":"203.0.113.9","tunnel_user":"sshproxy","ssh_port":2100,"generation":"17","host_key":"k"}\n' > "$GWJSON"
: > "$SANDBOX/ssh.log"
PT_OUT="$(env -i PATH="$SHIMS:$PATH" HOME="$HOME_DIR" SSH_LOG="$SANDBOX/ssh.log" \
    POOL_GATEWAY_FILE="$GWJSON" POOL_GATEWAY_PORT=2300 \
    bash "$REPO_ROOT/$PTUNNEL" --once 2>&1)"
argv="$(dial_argv)"
if printf '%s' "$argv" | grep -q -e '-p 2100'; then
    ok "3. follow 模式（未設新變數）仍用 gateway.json 的 ssh_port 2100"
else
    bad "3. follow 模式的埠讀取被改壞了（argv [$argv]）"
fi

echo "=== 4. 實作名稱與 design D3 的契約（對現碼紅） ==="
# design 定的名稱就是 POOL_GATEWAY_SSH_PORT；若實作自創拼法，開機資料／
# 文件／維修承載機會各寫各的，而每一端都不會錯——只是彼此不通。
if grep -q 'POOL_GATEWAY_SSH_PORT' "$PTUNNEL"; then
    ok "4. pool-tunnel 使用 POOL_GATEWAY_SSH_PORT（design D3 的名稱）"
else
    bad "4. pool-tunnel 未使用 POOL_GATEWAY_SSH_PORT——與 design D3 的契約不一致"
fi

echo "=== 5. 注入：新變數被無效化 → 1b 必須紅（實作落地後才有效） ==="
if ! grep -q 'POOL_GATEWAY_SSH_PORT' "$REPO_ROOT/$PTUNNEL"; then
    inj_skip "5. 實作尚無 POOL_GATEWAY_SSH_PORT 讀取（現碼即舊形狀，§1 的紅即這條的證據）"
else
    inj="$SANDBOX/ptunnel-inj1.sh"
    python3 - "$REPO_ROOT/$PTUNNEL" "$inj" <<'INJ'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
assert "POOL_GATEWAY_SSH_PORT" in src
# 把變數名改掉（不是刪行）：實作不管用幾處、怎麼寫都失效，且不改結構。
src = src.replace("POOL_GATEWAY_SSH_PORT", "POOL_GATEWAY_SSH_PORT_NEUTERED")
open(sys.argv[2], "w", encoding="utf-8").write(src)
INJ
    if [[ $? -ne 0 ]] || ! bash -n "$inj" 2>/dev/null; then
        inj_bad "5. 注入腳本失敗——harness 問題"
    else
        run_ptunnel "$inj" POOL_GATEWAY_SSH_PORT=2100
        argv="$(dial_argv)"
        if [[ -n "$argv" ]] && ! printf '%s' "$argv" | grep -q -e '-p 2100'; then
            inj_ok "5. 變數名被改掉後 ssh 不再帶 -p 2100（argv 的埠 [$(printf '%s' "$argv" | grep -o -e '-p [0-9][0-9]*' | head -n 1)]）——1b 會紅"
        else
            inj_bad "5. 變數失效後 1b 仍綠——斷言沒在量新變數（argv [$argv]）"
        fi
    fi
fi

echo "=== 6. 注入：把 -p 整個拿掉 → 1b 與 2 都必須紅 ==="
inj2="$SANDBOX/ptunnel-inj2.sh"
python3 - "$REPO_ROOT/$PTUNNEL" "$inj2" <<'INJ2'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
tok = '-p "${GW_SSH_PORT:-22}"'
if tok in src:
    src = src.replace(tok, "", 1)
else:
    m = re.search(r'^[ \t]*-p[ \t]+\S.*$', src, re.M)
    assert m, "dial -p needle not found"
    src = src[:m.start()] + src[m.end():]
open(sys.argv[2], "w", encoding="utf-8").write(src)
INJ2
if [[ $? -ne 0 ]] || ! bash -n "$inj2" 2>/dev/null; then
    inj_bad "6. 注入腳本失敗（needle 落空或語法錯）——harness 問題"
else
    run_ptunnel "$inj2" POOL_GATEWAY_SSH_PORT=2100
    argv="$(dial_argv)"
    if [[ -n "$argv" ]] && ! printf '%s' "$argv" | grep -q -e '-p '; then
        inj_ok "6. 完全拿掉 -p 後 1b/2 會紅（argv 無任何 -p；got [$(printf '%s' "$argv" | head -c 120)]）"
    else
        inj_bad "6. 拿掉 -p 後仍帶 -p——注入沒生效（argv [$argv]）"
    fi
fi

echo "=== 7. 無效的 POOL_GATEWAY_SSH_PORT → 拒絕、零撥號、說明原因 ==="
# 驗證器要對每一種字串給對的答案：非數字、0、超出範圍、前導零（bash 會當
# 八進位而噴錯）、超過 bash 算術範圍的長數字（會溢位）都必須被拒。
# 零撥號的正對照：§1 已證明同一個假 ssh 收得到撥號（1a），§8 注入後也會收到。
INVALID_PORTS="abc 0 65536 08 18446744073709551617"
for v in $INVALID_PORTS; do
    run_ptunnel "$REPO_ROOT/$PTUNNEL" POOL_GATEWAY_SSH_PORT="$v"
    dials="$(grep -c . "$SANDBOX/ssh.log" 2>/dev/null)"
    if [[ "$PT_RC" -ne 0 ]]; then
        ok "7. '${v}' → --once 非 0 結束（rc=${PT_RC}）"
    else
        bad "7. '${v}' → --once rc=0——無效值被接受"
    fi
    if [[ "${dials:-0}" -eq 0 ]]; then
        ok "7. '${v}' → 零次 ssh 呼叫"
    else
        bad "7. '${v}' → 仍有 ${dials} 次 ssh 呼叫（got [$(tr '\n' '|' < "$SANDBOX/ssh.log" | head -c 160)]）"
    fi
    if printf '%s' "$PT_OUT" | grep -q 'not a valid port'; then
        ok "7. '${v}' → log 說明 'not a valid port'"
    else
        bad "7. '${v}' → log 沒有 'not a valid port'（out [$(printf '%s' "$PT_OUT" | tr '\n' '|' | head -c 200)]）"
    fi
done

echo "=== 8. 注入：拿掉驗證 → §7 每個值都必須紅 ==="
inj3="$SANDBOX/ptunnel-inj3.sh"
python3 - "$REPO_ROOT/$PTUNNEL" "$inj3" <<'INJ3'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# 把「檢查 POOL_GATEWAY_SSH_PORT 形狀／範圍」那一行 if 的條件換成 false：
# 驗證整段失效，其餘結構（賦值給 GW_SSH_PORT）不動。
pat = re.compile(r'^([ \t]*)if .*POOL_GATEWAY_SSH_PORT.*=~.*; then[ \t]*$', re.M)
src, n = pat.subn(r'\1if false; then', src, count=1)
assert n == 1, "validation needle not found"
open(sys.argv[2], "w", encoding="utf-8").write(src)
INJ3
if [[ $? -ne 0 ]] || ! bash -n "$inj3" 2>/dev/null; then
    inj_bad "8. 注入腳本失敗（needle 落空或語法錯）——harness 問題"
else
    for v in $INVALID_PORTS; do
        run_ptunnel "$inj3" POOL_GATEWAY_SSH_PORT="$v"
        dials="$(grep -c . "$SANDBOX/ssh.log" 2>/dev/null)"
        if [[ "${dials:-0}" -gt 0 ]] && ! printf '%s' "$PT_OUT" | grep -q 'not a valid port'; then
            inj_ok "8. 驗證拿掉後 '${v}' 被撥號（${dials} 次 ssh 呼叫、無 'not a valid port'）——§7 會紅"
        else
            inj_bad "8. 驗證拿掉後 '${v}' 仍零撥號或仍有訊息——§7 沒在量驗證器（dials=${dials:-0}）"
        fi
    done
fi

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' \
    "$pass" "$fail" "$injpass" "$injfail"
[[ "$fail" -ne 0 ]] && exit 1
[[ "$injfail" -ne 0 ]] && exit 2
exit 0
