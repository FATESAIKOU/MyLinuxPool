#!/usr/bin/env bash
# test-tab-field-collapse.sh — gather 橫列空欄左移的人造故障護欄。
#
# 在防什麼：TAB 是 IFS 空白，所以 `IFS=$'\t' read` 會把連續空欄擠掉，
# 後面的欄位整排左移。worker 列的 provider 欄一空，port 就滑進 provider、
# user 滑進 port——ls 顯示錯欄、ssh-config 寫出 `Port worker`＋空 User，
# 照著連會連到不存在的東西。這三個渲染點（cmd_ls、cmd_ssh、emit_ssh_config）
# 曾經零測試覆蓋，修完不釘，下次改動靜默退回。
#
# 三條語意（壞掉的是 ledger 資料，不是缺席）：
#   空 provider 的列，port/user 完好仍可連——欄位不可左移，三處都要斷；
#   空 provider 顯示成 `?`，而且不是 `-`：`-` 是「沒有」（gateway 列本來
#   就用它），`?` 是「壞掉」，混在一起就看不出哪列有問題；
#   該列不可被跳過：藏起來等於第二份說謊的來源。
#
# 手法：全離線。gather_targets 在子行程載入真檔後用固定夾具覆寫
#   （生產端不在本次範圍；被測的是三處消費端的讀法），gw_probe_port
#   覆寫回 up；ssh / pool-resolve / gh / fzf 走 PATH stub
#   （fzf 讀 stdin 吐出 badw 那列，headless 可跑）。
#   夾具：badw（空 provider）＋ goodw（正常對照）＋ gateway（呼叫端自帶）。
#
# 注入（每條先證明會紅：突變版 bash -n 過＋needle 命中數剛好 1＋實際 got 值；
#   命中 0 或 2 都是 harness 問題，直接報紅不給過）。
#
# 相容：只用 bash 3.2 就有的語法；測試本體不用陣列。
#
# Run: scripts/tests/test-tab-field-collapse.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

MLP="ops-scripts/mlp"

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required but not found on PATH" >&2
    exit 1
fi
if ! command -v awk >/dev/null 2>&1; then
    echo "ERROR: awk is required but not found on PATH" >&2
    exit 1
fi
if [[ ! -f "$MLP" ]]; then
    echo "test-tab-field-collapse: ${MLP} is missing; every case below will FAIL" >&2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-tab-collapse.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/shims" "$SANDBOX/home"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- stubs：全部離線 -------------------------------------------------------
cat > "$SANDBOX/shims/ssh" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a" >> "${ARGV_LOG:-/dev/null}"; done
printf 'CALL-EOL\n' >> "${ARGV_LOG:-/dev/null}"
joined="$*"
case "$joined" in
  *"-M "*) exit "${FAKE_MASTER_RC:-0}" ;;
esac
exit 0
FAKE
cat > "$SANDBOX/shims/pool-resolve" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "gateway" ]]; then
  printf '{"ip":"9.9.9.9","user":"gw","port":22}\n'
  exit 0
fi
exit 1
FAKE
cat > "$SANDBOX/shims/gh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
# fzf：讀 stdin，吐出 badw 那列（真 fzf 會回傳選中的原始列）。
cat > "$SANDBOX/shims/fzf" <<'FAKE'
#!/usr/bin/env bash
while IFS= read -r line; do
  case "$line" in
    badw*) printf '%s\n' "$line"; exit 0 ;;
  esac
done
exit 1
FAKE
chmod +x "$SANDBOX/shims/ssh" "$SANDBOX/shims/pool-resolve" "$SANDBOX/shims/gh" "$SANDBOX/shims/fzf"

MLP_FILE="$REPO_ROOT/$MLP"

# ---- 生產端覆寫：夾具只有這兩行 ---------------------------------------------
# badw 的 provider 欄為空（壞 ledger 資料）；goodw 是正常對照。
cat > "$SANDBOX/overrides.sh" <<'OVERRIDES'
gather_targets() {
    printf 'badw\tworker\t\t2301\tworker\n'
    printf 'goodw\tworker\tprovA\t2302\tworker\n'
}
gw_probe_port() { printf 'up'; }
OVERRIDES

echo "=== 0. 先決條件 ==="
missing=0
for fn in cmd_ls cmd_ssh emit_ssh_config fwd_split_row gather_targets; do
    if grep -qE "^${fn}\\(\\)" "$MLP"; then
        :
    else
        bad "0. ${fn} 不存在——實作還沒落地？"
        missing=1
    fi
done
if [[ "$missing" -eq 0 ]]; then
    ok "0. 三消費端與 split plumbing 都在"
fi

echo "=== 1. cmd_ls：空欄不左移，壞欄標問號 ==="
MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" OVR="$SANDBOX/overrides.sh" OUTF="$SANDBOX/ls-out" ERRF="$SANDBOX/ls-err" RCF="$SANDBOX/ls-rc" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; source "$OVR" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; ( cmd_ls >"$OUTF" 2>"$ERRF" ); rc=$?; printf "RC=%s" "$rc" > "$RCF"' 2>/dev/null
got="RC=$(cat "$SANDBOX/ls-rc" 2>/dev/null | sed 's/^RC=//')"
badw_line="$(awk '$1 == "badw"' "$SANDBOX/ls-out" 2>/dev/null)"
if [[ "$got" == "RC=0" ]] && [[ "$(printf '%s' "$badw_line" | awk '{print $3}')" == "?" ]] \
&& [[ "$(printf '%s' "$badw_line" | awk '{print $4}')" == "2301" ]] \
&& [[ "$(printf '%s' "$badw_line" | awk '{print $5}')" == "up" ]]; then
    ok "1a. badw 列欄位歸位（provider 是問號、port 2301、up）"
else
    bad "1a. 欄位左移或問號遺失（got [$got] line [$badw_line]）"
fi
if [[ -n "$badw_line" ]] && [[ "$(printf '%s' "$badw_line" | awk '{print $3}')" != "-" ]]; then
    ok "1b. 壞欄是問號不是橫線（橫線保留給真的沒有）"
else
    bad "1b. 壞資料長得像正常的沒有（line [$badw_line]）"
fi
if grep -q '^gateway ' "$SANDBOX/ls-out" 2>/dev/null \
&& awk '$1 == "gateway" {print $3}' "$SANDBOX/ls-out" 2>/dev/null | grep -qx -- '-'; then
    ok "1c. gateway 列照舊用橫線（問號沒有污染正常的沒有）"
else
    bad "1c. gateway 列不對"
fi
if awk '$1 == "goodw"' "$SANDBOX/ls-out" 2>/dev/null | grep -q 'provA.*2302'; then
    ok "1d. 正常列不受影響（對照組）"
else
    bad "1d. 正常列跑版"
fi

echo "=== 2. ssh-config：Port/User 完好，註解指名 ==="
MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" OVR="$SANDBOX/overrides.sh" OUTF="$SANDBOX/cfg-out" ERRF="$SANDBOX/cfg-err" RCF="$SANDBOX/cfg-rc" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; source "$OVR" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; ( cmd_ssh_config >"$OUTF" 2>"$ERRF" ); rc=$?; printf "RC=%s" "$rc" > "$RCF"' 2>/dev/null
got="RC=$(cat "$SANDBOX/cfg-rc" 2>/dev/null | sed 's/^RC=//')"
awk '/^Host badw /,/^$/ {print}' "$SANDBOX/cfg-out" 2>/dev/null > "$SANDBOX/cfg-badw"
if [[ "$got" == "RC=0" ]] && grep -qF '# worker on ?' "$SANDBOX/cfg-out" 2>/dev/null \
&& grep -qF 'Host badw worker-2301' "$SANDBOX/cfg-badw" 2>/dev/null \
&& grep -qF 'Port 2301' "$SANDBOX/cfg-badw" 2>/dev/null \
&& grep -qF 'User worker' "$SANDBOX/cfg-badw" 2>/dev/null; then
    ok "2a. badw 區塊完好（註解問號、Port 2301、User worker）"
else
    bad "2a. 區塊左移或問號遺失（got [$got]）"
fi
if ! grep -qF '# worker on -' "$SANDBOX/cfg-out" 2>/dev/null; then
    ok "2b. 沒有把壞欄寫成橫線"
else
    bad "2b. 壞資料長得像正常的沒有"
fi
if grep -qF '# worker on provA' "$SANDBOX/cfg-out" 2>/dev/null \
&& grep -qF 'Host goodw worker-2302' "$SANDBOX/cfg-out" 2>/dev/null; then
    ok "2c. 正常列不受影響（對照組）"
else
    bad "2c. 正常列跑版"
fi

echo "=== 3. ssh 挑選：撥號拿到對的埠與使用者 ==="
MLP_FILE="$MLP_FILE" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" OVR="$SANDBOX/overrides.sh" ARGV_LOG="$SANDBOX/ssh-argv.log" OUTF="$SANDBOX/ssh-out" ERRF="$SANDBOX/ssh-err" RCF="$SANDBOX/ssh-rc" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
  bash -c 'source "$MLP_FILE" >/dev/null 2>&1; source "$OVR" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; : > "$ARGV_LOG"; ( cmd_ssh </dev/null >"$OUTF" 2>"$ERRF" ); rc=$?; printf "RC=%s" "$rc" > "$RCF"' 2>/dev/null
got="RC=$(cat "$SANDBOX/ssh-rc" 2>/dev/null | sed 's/^RC=//')"
if [[ "$got" == "RC=0" ]] && grep -qx '2301' "$SANDBOX/ssh-argv.log" 2>/dev/null \
&& grep -qF 'worker@127.0.0.1' "$SANDBOX/ssh-argv.log" 2>/dev/null; then
    ok "3a. 撥號帶著 2301 與 worker 身分（該列沒被跳過、沒錯位）"
else
    bad "3a. 撥號參數不對（got [$got]）"
fi

echo "=== 4-6. 注入：拿掉修正，斷言必須轉紅 ==="
# 4. 任一處退回 IFS 讀（挑 ssh-config：`Port worker` 最好認）。
#   突變只動 gather 迴圈（echo 空行＋worker 分支為錨），render 不動。
INJ1="$SANDBOX/mutant-ifsread.sh"
python3 - "$MLP_FILE" "$INJ1" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    while IFS= read -r r; do\n'
       '        fwd_split_row "$r"\n'
       '        name="$FWD_C1"; type="$FWD_C2"; provider="$FWD_C3"; port="$FWD_C4"; user="$FWD_C5"\n'
       '        [[ -n "$name" ]] || continue\n'
       '        [[ -n "$provider" ]] || provider="?"\n'
       '        echo ""\n')
new = ('    while IFS=$\'\\t\' read -r name type provider port user; do\n'
       '        [[ -n "$name" ]] || continue\n'
       '        echo ""\n')
assert src.count(old) == 1, "ifsread needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "4. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ1" 2>/dev/null; then
    inj_bad "4. 注入版語法錯誤——harness 問題"
else
    MLP_FILE="$INJ1" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" OVR="$SANDBOX/overrides.sh" OUTF="$SANDBOX/cfg-inj" RCF="$SANDBOX/cfg-inj-rc" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; source "$OVR" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; ( cmd_ssh_config >"$OUTF" 2>/dev/null ); rc=$?; printf "RC=%s" "$rc" > "$RCF"' 2>/dev/null
    awk '/^Host badw /,/^$/ {print}' "$SANDBOX/cfg-inj" 2>/dev/null > "$SANDBOX/cfg-inj-badw"
    if grep -qF 'Port 2301' "$SANDBOX/cfg-inj-badw" 2>/dev/null \
    && grep -qF 'User worker' "$SANDBOX/cfg-inj-badw" 2>/dev/null; then
        inj_bad "4. 退回 IFS 讀後 2a 仍綠——欄位沒被量到"
    else
        if grep -qF 'Port worker' "$SANDBOX/cfg-inj-badw" 2>/dev/null; then
            inj_ok "4. 退回 IFS 讀後 Port 滑成 worker（got [$(grep -F 'Port ' "$SANDBOX/cfg-inj-badw" | head -1)]）——2a 會紅"
        else
            inj_bad "4. 行為變了但不是預期的左移（out [$(tr '\n' ' ' < "$SANDBOX/cfg-inj-badw" | head -c 160)]）——harness 問題"
        fi
    fi
fi
# 5. 空 provider 顯示成橫線 → 壞資料長得像正常的沒有。
#   三處各錨定（後續行皆不同），一次全翻，命中數各剛好 1。
INJ2="$SANDBOX/mutant-dash.sh"
python3 - "$MLP_FILE" "$INJ2" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needles = [
    ('        [[ -n "$provider" ]] || provider="?"\n'
     '        state="$(gw_probe_port "$port")"\n'
     '        rows+=(',
     '        [[ -n "$provider" ]] || provider="-"\n'
     '        state="$(gw_probe_port "$port")"\n'
     '        rows+=('),
    ('                [[ -n "$provider" ]] || provider="?"\n'
     '                state="$(gw_probe_port "$port")"\n'
     "                printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n'",
     '                [[ -n "$provider" ]] || provider="-"\n'
     '                state="$(gw_probe_port "$port")"\n'
     "                printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n'"),
    ('        [[ -n "$provider" ]] || provider="?"\n'
     '        echo ""\n',
     '        [[ -n "$provider" ]] || provider="-"\n'
     '        echo ""\n'),
]
for old, new in needles:
    assert src.count(old) == 1, "dash needle count != 1: %r" % old[:60]
    src = src.replace(old, new, 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -ne 0 ]]; then
    inj_bad "5. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ2" 2>/dev/null; then
    inj_bad "5. 注入版語法錯誤——harness 問題"
else
    MLP_FILE="$INJ2" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" OVR="$SANDBOX/overrides.sh" OUT1="$SANDBOX/ls-inj" OUT2="$SANDBOX/cfg-inj2" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; source "$OVR" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; ( cmd_ls >"$OUT1" 2>/dev/null ); ( cmd_ssh_config >"$OUT2" 2>/dev/null )' 2>/dev/null
    badw_line="$(awk '$1 == "badw"' "$SANDBOX/ls-inj" 2>/dev/null)"
    if [[ "$(printf '%s' "$badw_line" | awk '{print $3}')" == "?" ]] \
    && grep -qF '# worker on ?' "$SANDBOX/cfg-inj2" 2>/dev/null; then
        inj_bad "5. 改橫線後 1a/2a 仍綠——問號沒被量到"
    else
        if [[ "$(printf '%s' "$badw_line" | awk '{print $3}')" == "-" ]] \
        && grep -qF '# worker on -' "$SANDBOX/cfg-inj2" 2>/dev/null; then
            inj_ok "5. 改橫線後壞欄混入正常的沒有（got ls [$badw_line]）——1b/2b 會紅"
        else
            inj_bad "5. 行為變了但不是預期的橫線（line [$badw_line]）——harness 問題"
        fi
    fi
fi
# 6. 空 provider 的列被跳過 → 壞資料從觀測面消失。
#   突變 ls 迴圈的問號行為空欄跳過（後續 rows+= 為錨）。
INJ3="$SANDBOX/mutant-skip.sh"
python3 - "$MLP_FILE" "$INJ3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('        [[ -n "$provider" ]] || provider="?"\n'
       '        state="$(gw_probe_port "$port")"\n'
       '        rows+=(')
new = ('        [[ -n "$provider" ]] || continue\n'
       '        state="$(gw_probe_port "$port")"\n'
       '        rows+=(')
assert src.count(old) == 1, "skip needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "6. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ3" 2>/dev/null; then
    inj_bad "6. 注入版語法錯誤——harness 問題"
else
    MLP_FILE="$INJ3" POOL_OVERRIDE="$SANDBOX/shims/pool-resolve" OVR="$SANDBOX/overrides.sh" OUT1="$SANDBOX/ls-inj3" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
      bash -c 'source "$MLP_FILE" >/dev/null 2>&1; source "$OVR" >/dev/null 2>&1; POOL_RESOLVE="$POOL_OVERRIDE"; ( cmd_ls >"$OUT1" 2>/dev/null )' 2>/dev/null
    if awk '$1 == "badw"' "$SANDBOX/ls-inj3" 2>/dev/null | grep -q .; then
        inj_bad "6. 跳過空欄列後 1a 仍有 badw——存在性沒被量到"
    else
        if awk '$1 == "goodw"' "$SANDBOX/ls-inj3" 2>/dev/null | grep -q .; then
            inj_ok "6. 跳過空欄列後 badw 消失、goodw 仍在（got [$(tr '\n' ' ' < "$SANDBOX/ls-inj3" | head -c 160)]）——存在性斷言會紅"
        else
            inj_bad "6. 連正常列都不見了——harness 問題"
        fi
    fi
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
