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
# ---- 檔名清單是列出來的，不是抄出來的 --------------------------------
#
# 原版這裡寫死四個檔名。於是 ops-scripts/pool-residue.sh 加進來時這支測試
# 照樣全綠：它檢查的是名單上的那幾個，漏掉的檔案不會有任何徵兆。這是
# docs/TESTPLAN.md §1.7 的形狀（兩種狀態共用一個值），也是 preflight 檔頭
# 警告過的形狀。現在改成 `git ls-files --cached --others` 列舉。
#
# 為什麼是 `--cached --others` 而不是只有 `--cached`（= preflight 用的寫法）：
# 只列已追蹤檔的話，今天這個新檔（還沒 commit）依然不在清單裡，這條測試就
# 依然抓不到它——那正是我們要修的東西。`--others` 補上「未追蹤但沒被
# .gitignore 蓋掉」，`--exclude-standard` 讓 .gitignore 照常生效（這裡沒有
# 機密檔，但語意要對：git 願意管的檔案 = 這個目錄的完整內容）。
#
# 列舉為空時整支測試轉紅，理由同 preflight 的 ok_counted：零從來不是
# 「看過 N 個都沒錯」，它是「列舉沒給這個檢查任何東西看」，而那兩件事從
# 下游看起來一模一樣（glob 改壞、目錄搬了、不在 git 樹裡）。
#
# ---- 判準：needs_loc 與 no_loc --------------------------------------
#
# 列舉到的每一支必須剛好落在兩類之一：
#   A（needs_loc）靠「自己在哪」找 repo，所以必須帶那個解析區塊。判準是
#     檔案內容出現 SCRIPT_DIR 或 REPO_ROOT——解析區塊自己就設 SCRIPT_DIR，
#     所以 A 類一定會命中這個名字。
#   B（no_loc）兩個名字都不出現，也就是不靠自身位置解析任何路徑。
# 沒有第三類可躲：新檔要嘛引用 SCRIPT_DIR（→ A，必須有區塊），要嘛不引用
# （→ B，本來就不需要）。判準讀的是每支腳本的內容，不是任何人的名單。
#
# 現況 B 類只有 register-provider.sh：它在 mktemp 出來的臨時 clone 裡跑
# （REPO_DIR），路徑全部相對於那個 clone，符號連結解到哪裡都不影響它。
# 它是「不需要」而不是「漏了」——但那個判斷是這份判準替它做的，不是它自己
# 宣告的。要推翻的話改判準，不要加排除清單：排除清單就是本檔要消滅的東西。
#
# 已知極限（寫下來是因為它是這條判準的邊界，不是修好的部分）：判準只認
# SCRIPT_DIR / REPO_ROOT 這兩個變數名加上區塊本身。一支自己發明第三個名字
# 做自我定位的腳本會被判成 B 而被跳過。今天 ops-scripts/ 全部 6 支都查過、
# 沒有這種寫法，但那是現況，不是判準保證的。
#
# ---- probe_args / probe_want 仍然是手寫的，而且必須是 ----------------
#
# 第 2-4 條要「執行」腳本，而每支腳本用什麼參數能停在參數解析、停下來該看到
# 什麼字串，只有那支腳本自己知道——那兩個表沒有辦法從 repo 推導出來。為了
# 不讓它變成新的無聲破口，列舉到卻沒在 probe_want 註冊的腳本一律報錯（5b）：
# 沒有期望字串時 link_check 的 `grep -qF ""` 恆真，第 2-4 條會對一支從來
# 沒被執行過的腳本回報「通過」。這是同一個形狀的最後一份複本。
#
# pool-residue.sh 的 probe 必須用 `--help`：不帶參數會真的連上 Gateway 對
# 三台 provider 跑 `docker ps -a`。`--help` 在 source 完 mlp 之後就印 usage
# 並 exit 0，不碰網路。
#
# 第 2 條每支給一個自己的目錄（$SANDBOX/one/<name>/），不是全部丟在同一個：
# pool-residue.sh 靠 "${SCRIPT_DIR}/mlp" 找兄弟檔，一起 ln 進同一個目錄時它
# 會找到測試自己放的連結，解析區塊壞掉也照樣跑得起來。2026-09-26 實測過：
# 弄壞 pool-residue.sh 的區塊、其它四支照舊放在同一個目錄時，第 2 條是綠的。
# 這是「沒被人看過紅的斷言」才會發現的東西——第 1、5 條有抓到，第 2 條沒有。
#
# 別把「非零結束碼」當失敗訊號：各支的 probe 結束碼不統一（mlp 2、
# verify-profile 2、register-client 0、preflight 0、pool-residue.sh 0），
# pass 的判準只有「輸出裡有期望字串」與「不是死在 source 階段」。
#
# 斷言：0 列舉非空；1 A 類的解析區塊逐位元組一致（A 類為空也轉紅）；
#       2 單層連結；3 多層連結；4 相對連結；5 沒有裸的 dirname；
#       5b A 類每一支都有 probe 註冊；6 注入：換回裸 dirname -> 2 轉紅。
#
# 第 6 條刻意寫死 mlp：注入要的是一個「已知正常」的被對照物，不是被列舉的
# 對象。那個位置寫檔名是對的——漏掉一個檔名會少測一件事，寫錯一個字串會
# 讓注入找不到替身而自己報 harness 問題，兩種錯都會出現在輸出裡。
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
mkdir -p "$SANDBOX/linkdir" "$SANDBOX/sub" "$SANDBOX/one"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

block_of() { awk '/^# Resolve this script.s REAL location/,/^unset _mlp_self _mlp_dir$/' "$1"; }

# ---- 列舉（見檔頭：為什麼是 --cached --others）------------------------
OPS_SCRIPTS=()
while IFS= read -r f; do
    [ -n "$f" ] && OPS_SCRIPTS+=("${f##*/}")
done < <(git ls-files --cached --others --exclude-standard -- ops-scripts/ | LC_ALL=C sort)

NEEDS_LOC=()
NO_LOC=()
if [[ "${#OPS_SCRIPTS[@]}" -gt 0 ]]; then
    for s in "${OPS_SCRIPTS[@]}"; do
        if grep -qE 'SCRIPT_DIR|REPO_ROOT' "${REPO}/ops-scripts/$s" 2>/dev/null; then
            NEEDS_LOC+=("$s")
        else
            NO_LOC+=("$s")
        fi
    done
fi

echo "=== 0. 列舉 ==="
if [[ "${#OPS_SCRIPTS[@]}" -eq 0 ]]; then
    bad "0. 列舉到 0 支 ops-script——這不是通過，是清單沒給這支測試任何東西看（不在 git 樹裡？ops-scripts/ 被搬走了？）。下面每一條都是在 0 支上跑出來的綠"
elif [[ "${#NEEDS_LOC[@]}" -eq 0 ]]; then
    bad "0. 列舉到 ${#OPS_SCRIPTS[@]} 支，但沒有一支需要自我定位——判準壞了（grep 的樣式被改壞？），第 1/2-4/5 條會在空集合上回報通過"
else
    nolist=""
    [[ "${#NO_LOC[@]}" -gt 0 ]] && nolist="、不需要 ${#NO_LOC[@]}（${NO_LOC[*]}）"
    ok "0. 列舉到 ${#OPS_SCRIPTS[@]} 支（需要定位 ${#NEEDS_LOC[@]}${nolist}）"
fi

# 每支用什麼參數能「走到參數解析就停」，以及成功時該出現的字串。
# 用 case 而不是 nameref：後者要 bash 4.3+，macOS 內建的是 3.2。
probe_args() {
    case "$1" in
        mlp)             printf '%s' "__no_such_cmd__" ;;
        register-client) printf '%s' "--help" ;;
        pool-residue.sh) printf '%s' "--help" ;;
        *)               printf '%s' "" ;;
    esac
}
probe_want() {
    case "$1" in
        mlp)             printf '%s' "unknown command" ;;
        register-client) printf '%s' "usage: register-client" ;;
        pool-residue.sh) printf '%s' "usage: pool-residue" ;;
        register-repair-host) printf '%s' "usage: register-repair-host" ;;
        package-repair-host) printf '%s' "usage: package-repair-host" ;;
        verify-profile)  printf '%s' "usage: verify-profile" ;;
        preflight)       printf '%s' "preflight:" ;;
    esac
}

echo "=== 1. 需要自我定位的每一支，解析區塊都必須一致 ==="
REF="$(block_of "${REPO}/ops-scripts/mlp" | shasum | awk '{print $1}')"
if [[ -z "$(block_of "${REPO}/ops-scripts/mlp")" ]]; then
    bad "1. 找不到解析區塊（形狀變了？）"
elif [[ "${#NEEDS_LOC[@]}" -eq 0 ]]; then
    bad "1. 沒有任何一支被判定需要解析區塊——比對 0 個東西然後回報沒漂移，那不是通過"
else
    drift=""
    for s in "${NEEDS_LOC[@]}"; do
        h="$(block_of "${REPO}/ops-scripts/$s" | shasum | awk '{print $1}')"
        [[ "$h" == "$REF" ]] || drift="${drift}${s} "
    done
    if [[ -z "$drift" ]]; then
        ok "1. ${#NEEDS_LOC[@]} 支的解析區塊逐位元組相同（${NEEDS_LOC[*]}）"
    else
        bad "1. 解析區塊已漂移：${drift}"
    fi
fi

# link_check <連結路徑> <腳本名> <情境> -> 0 成功
link_check() {
    local link="$1" name="$2" ctx="$3" out a w
    a="$(probe_args "$name")"; w="$(probe_want "$name")"
    # 沒有期望字串時 `grep -qF ""` 恆真，那不是「通過」而是「沒測」——
    # 這支腳本從來沒被執行過也會拿到綠。所以在這裡擋掉，不靠呼叫端記得擋。
    if [[ -z "$w" ]]; then
        bad "${ctx}：${name} 沒有註冊期望輸出（probe_want 少了這一筆）——不拿空字串去比對"
        return 1
    fi
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
if [[ "${#NEEDS_LOC[@]}" -eq 0 ]]; then
    bad "2-4. 沒有任何一支被判定需要自我定位，等於一個連結都沒測"
    allok=0
else
    for s in "${NEEDS_LOC[@]}"; do
        # 一支一個目錄，不是全部丟進同一個。pool-residue.sh 會 source
        # "${SCRIPT_DIR}/mlp"——把五支一起 ln 進同一個目錄，它就會找到測試自己
        # 放的同名連結，於是解析區塊壞掉也照樣跑得起來（2026-09-26 實測：
        # 弄壞 pool-residue.sh 的區塊後第 2 條仍然是綠的）。被測物旁邊不該有
        # 測試自己放的東西。
        mkdir -p "$SANDBOX/one/$s"
        ln -s "${REPO}/ops-scripts/$s" "$SANDBOX/one/$s/$s"
        link_check "$SANDBOX/one/$s/$s" "$s" "2. 單層連結" || allok=0
    done
    [[ "$allok" -eq 1 ]] && ok "2. ${#NEEDS_LOC[@]} 支透過單層符號連結都走到自己的參數解析"
fi

ln -s "$SANDBOX/one/mlp/mlp" "$SANDBOX/linkdir/mlp-chained"
link_check "$SANDBOX/linkdir/mlp-chained" mlp "3. 多層連結" \
    && ok "3. 連結指向連結也解得開"

( cd "$SANDBOX/sub" && ln -s ../one/mlp/mlp mlp-rel )
link_check "$SANDBOX/sub/mlp-rel" mlp "4. 相對連結" \
    && ok "4. 相對路徑的連結也解得開"

echo "=== 5. 沒有人用裸的 dirname ==="
if [[ "${#NEEDS_LOC[@]}" -eq 0 ]]; then
    bad "5. 沒有任何一支被判定需要自我定位，等於沒有掃過任何檔案"
else
    scan=()
    for s in "${NEEDS_LOC[@]}"; do scan+=("${REPO}/ops-scripts/$s"); done
    naked="$(grep -n 'dirname "\$0"\|dirname "\${BASH_SOURCE\[0\]}"' \
        "${scan[@]}" 2>/dev/null || true)"
    if [[ -z "$naked" ]]; then
        ok "5. ${#scan[@]} 支裡沒有裸的 dirname（那些對連結會解錯）"
    else
        bad "5. 還有裸的 dirname:"$'\n'"$naked"
    fi
fi

echo "=== 5b. A 類每一支都註冊了 probe ==="
# 第 2-4 條會執行它們，所以「怎麼讓它停在參數解析」必須有人知道。缺一筆
# 就是第 2-4 條對一支沒被執行過的腳本回報通過。link_check 自己也擋，但擋在
# 這裡才能指出「缺哪一支」——link_check 只能說「這一支沒註冊」。
if [[ "${#NEEDS_LOC[@]}" -eq 0 ]]; then
    bad "5b. 沒有任何一支被判定需要自我定位，等於沒有東西可檢查"
else
    noprobe=()
    for s in "${NEEDS_LOC[@]}"; do
        [[ -n "$(probe_want "$s")" ]] || noprobe+=("$s")
    done
    if [[ "${#noprobe[@]}" -eq 0 ]]; then
        ok "5b. ${#NEEDS_LOC[@]} 支都有註冊期望輸出"
    else
        bad "5b. 沒有註冊期望輸出的：${noprobe[*]}——第 2-4 條對它們會是空比對（不擋的話是假綠）"
    fi
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
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
