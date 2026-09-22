#!/usr/bin/env bash
# test-script-self-location.sh — ops-scripts 必須能透過符號連結執行。
#
# 這些是「人手動跑」的工具，自然會有人 ln -s 到 PATH 上的目錄。但 $0 與
# BASH_SOURCE 拿到的都是**連結本身**，不是目標檔，所以直接 dirname 會落在
# 連結所在的目錄，接著每一個相對於 repo 的路徑都錯。症狀完全看不出跟符號
# 連結有關：
#   /home/u/testSH/mlp: line 56: /home/u/scripts/lib/ssh.sh: No such file
#   mlp: pool-resolve not found at /home/u/shared-configs/...
#
# 解析區塊必須在每支腳本裡各有一份——它要在「腳本知道 repo 在哪」之前執行，
# 那時還沒有東西可以 source。這是少數合理的重複，代價是會各自漂移，所以
# 第 1 條逐位元組比對。
#
# 斷言：1 四份區塊一致；2 單層連結；3 多層連結；4 相對連結；
#       5 沒有裸的 dirname；6 注入：換回裸 dirname -> 2 轉紅。
#
# Run: scripts/tests/test-script-self-location.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO="$PWD"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-self-loc.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
# 連結目錄故意不叫 bin：preflight 的舊路徑掃描會找「bin 目錄底下的 mlp」
# 那個字串，測試檔裡只要出現它，preflight 就會對自己紅。加豁免會在最需要
# 檢查的地方把它弄瞎，所以改寫法（同 test-workers-d-path.sh 檔頭記的那次）。
# 這條註解本身也踩過一次——第一版把那個字串直接寫出來了。
mkdir -p "$SANDBOX/linkdir" "$SANDBOX/sub"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

block_of() { awk '/^# Resolve this script.s REAL location/,/^unset _mlp_self _mlp_dir$/' "$1"; }

# 每支用什麼參數能「走到參數解析就停」，以及成功時該出現的字串。
# 用 case 而不是 nameref：後者要 bash 4.3+，macOS 內建的是 3.2。
probe_args() {
    case "$1" in
        mlp)             printf '%s' "__no_such_cmd__" ;;
        register-client) printf '%s' "--help" ;;
        *)               printf '%s' "" ;;
    esac
}
probe_want() {
    case "$1" in
        mlp)             printf '%s' "unknown command" ;;
        register-client) printf '%s' "usage: register-client" ;;
        verify-profile)  printf '%s' "usage: verify-profile" ;;
        preflight)       printf '%s' "preflight:" ;;
    esac
}

echo "=== 1. 四份解析區塊必須一致 ==="
REF="$(block_of "${REPO}/ops-scripts/mlp" | shasum | awk '{print $1}')"
if [[ -z "$(block_of "${REPO}/ops-scripts/mlp")" ]]; then
    bad "1. 找不到解析區塊（形狀變了？）"
else
    drift=""
    for s in mlp register-client verify-profile preflight; do
        h="$(block_of "${REPO}/ops-scripts/$s" | shasum | awk '{print $1}')"
        [[ "$h" == "$REF" ]] || drift="${drift}${s} "
    done
    if [[ -z "$drift" ]]; then
        ok "1. 四支的解析區塊逐位元組相同"
    else
        bad "1. 解析區塊已漂移：${drift}"
    fi
fi

# link_check <連結路徑> <腳本名> <情境> -> 0 成功
link_check() {
    local link="$1" name="$2" ctx="$3" out a w
    a="$(probe_args "$name")"; w="$(probe_want "$name")"
    if [[ -n "$a" ]]; then out="$("$link" "$a" 2>&1)"; else out="$("$link" 2>&1)"; fi
    if grep -q "No such file" <<<"$out"; then
        bad "${ctx}：${name} 死在 source 階段（自身位置解錯）:"$'\n'"      $(head -1 <<<"$out")"
        return 1
    fi
    if grep -qF "$w" <<<"$out"; then return 0; fi
    bad "${ctx}：${name} 輸出裡找不到 '${w}':"$'\n'"      $(head -1 <<<"$out")"
    return 1
}

echo "=== 2-4. 透過符號連結執行 ==="
allok=1
for s in mlp register-client verify-profile preflight; do
    ln -s "${REPO}/ops-scripts/$s" "$SANDBOX/linkdir/$s"
    link_check "$SANDBOX/linkdir/$s" "$s" "2. 單層連結" || allok=0
done
[[ "$allok" -eq 1 ]] && ok "2. 四支透過單層符號連結都走到自己的參數解析"

ln -s "$SANDBOX/linkdir/mlp" "$SANDBOX/linkdir/mlp-chained"
link_check "$SANDBOX/linkdir/mlp-chained" mlp "3. 多層連結" \
    && ok "3. 連結指向連結也解得開"

( cd "$SANDBOX/sub" && ln -s ../linkdir/mlp mlp-rel )
link_check "$SANDBOX/sub/mlp-rel" mlp "4. 相對連結" \
    && ok "4. 相對路徑的連結也解得開"

echo "=== 5. 沒有人用裸的 dirname ==="
naked="$(grep -n 'dirname "\$0"\|dirname "\${BASH_SOURCE\[0\]}"' \
    "${REPO}/ops-scripts/mlp" "${REPO}/ops-scripts/register-client" \
    "${REPO}/ops-scripts/verify-profile" "${REPO}/ops-scripts/preflight" 2>/dev/null || true)"
if [[ -z "$naked" ]]; then
    ok "5. 沒有裸的 dirname（那些對連結會解錯）"
else
    bad "5. 還有裸的 dirname:"$'\n'"$naked"
fi

echo "=== 6. 注入 ==="
INJ="$SANDBOX/mlp-inj"
if python3 - "${REPO}/ops-scripts/mlp" "$INJ" <<'INJPY'
import sys, re
src = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'^# Resolve this script.s REAL location.*?^unset _mlp_self _mlp_dir$',
              src, re.S | re.M)
assert m, "resolver block not found"
open(sys.argv[2], 'w', encoding='utf-8').write(
    src.replace(m.group(0), 'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"', 1))
INJPY
then
    chmod +x "$INJ"
    ln -s "$INJ" "$SANDBOX/linkdir/mlp-inj-link"
    out="$("$SANDBOX/linkdir/mlp-inj-link" __no_such_cmd__ 2>&1)"
    if grep -q "No such file" <<<"$out"; then
        inj_ok "6. 換回裸的 dirname 後，透過連結執行會死在 source 階段——第 2 條擋得住"
    else
        inj_bad "6. 注入後仍正常，第 2 條驗不到東西: $(head -1 <<<"$out")"
    fi
else
    inj_bad "6. 注入腳本失敗（被測物形狀變了）——harness 問題"
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
