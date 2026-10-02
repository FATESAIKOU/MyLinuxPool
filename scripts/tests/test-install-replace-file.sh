#!/usr/bin/env bash
# test-install-replace-file.sh — D10：安裝時**換檔**取代原地覆寫。
#
# 為什麼要有這條（2026-10-02 fh-l 實例）：bash 是**邊執行邊讀腳本**的。
# pool-sync 收斂到新版時，`cp -f` 會改寫**正在執行**的那個檔案（同一個 inode），
# 還在跑的舊版 process 接下來讀到的就是新內容，於是錯位出錯
# （`line 410: syntax error`，那一輪 tick 失敗）。`mv` 換的是目錄項，舊版
# process 手上的 fd 仍然是原來那個 inode，所以完全不受影響。
#
# 三層斷言，由形狀到行為：
#   D10-1  換檔的**形狀**：重裝之後每個目標檔都是新的 inode。
#   D10-2  換檔的**行為**：一個正在執行的舊版 process，在自己被換掉之後，
#           仍然照原本的內容跑完、沒有 syntax error。這是 D10 真正要買的東西——
#           inode 換了只是它的**充分**條件，不是命題本身。
#   D10-3  換檔的**副作用**：權限還在、沒有殘留暫存檔。
#
# 兩件事讓這支測試有意義，缺了任一條它就只是「看起來有牙」：
#   1. D10-2 的探針是**真的在跑一��腳本**，不是模擬。舊版 process 是真的
#      睡著、真的被換掉、真的繼續讀自己的檔案。
#   2. D10-1 與 D10-2 各有一條注入，證明它們在 `cp -f` 的形狀下會紅。
#
# 手法：所有安裝都對著 mktemp 出來的假 HOME（`--home`），真機的
# `~/.mylinuxpool/bin` 不會被碰到。D10-2 需要一個「內容可以被換掉」的來源檔，
# 所以那一段用的是**沙箱裡的單位副本**（install.sh 原封不動，只換掉副本的
# `files/pool-sync`）——產品碼一個位元組都不改。
#
# 相容：bash 3.2（macOS）與 bash 5.2（ubuntu CI 都要跑）。不用 declare -A、
# 不用 ${var,,}、不用 mapfile。`stat` 的 inode 欄位兩邊語意不同（BSD `-f %i`、
# GNU `-c %i`），這裡兩種都試。
#
# Run: scripts/tests/test-install-replace-file.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." || exit 1

PR_UNIT="shared-configs/pool-runtime"
WOL_UNIT="shared-configs/wol"
PR_INSTALL="$PR_UNIT/install.sh"
WOL_INSTALL="$WOL_UNIT/install.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-install-replace.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

pass=0; fail=0; injpass=0; injfail=0
ok()   { pass=$((pass+1));   printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1));   printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

for f in "$PR_INSTALL" "$WOL_INSTALL" "$PR_UNIT/files/pool-sync" "$WOL_UNIT/files/pool-wol"; do
    if [[ ! -f "$f" ]]; then
        echo "test-install-replace-file: ${f} is missing; every case below will FAIL" >&2
        bad "前提：${f} 不存在"
    fi
done
if [[ ! -x "$PR_INSTALL" ]]; then
    echo "test-install-replace-file: ${PR_INSTALL} is not executable" >&2
    exit 1
fi

# inode_of <file> → 印 inode，印不出數字就印空字串。
#
# 兩種 stat 語意（BSD `-f %i`／GNU `-c %i`）**都要驗證輸出是不是數字**：
# GNU coreutils 的 `stat -f` 是「顯示檔案系統狀態」，它會忽略檔名參數、把 `%i`
# 當檔案系統的格式字串，然後**回 0**並印一整頁 FS 資訊。第一版就是這樣：
# 容器（bash 5.2）上每一個「inode」都是那頁垃圾，於是每次比較都不相等，
# D10-1a 報成「原地覆寫」——一個假的全軍覆沒。
inode_of() {
    local f="$1" v
    if v="$(stat -c %i "$f" 2>/dev/null)" && [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%s' "$v"; return 0
    fi
    if v="$(stat -f %i "$f" 2>/dev/null)" && [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%s' "$v"; return 0
    fi
    printf ''
}
# run_install <install.sh> <home> [額外參數…]：真的執行那個 install.sh
run_install() {
    local inst="$1" home="$2"; shift 2
    "$inst" --home "$home" --user "$(whoami)" "$@" </dev/null 2>&1
}
# run_install_sh <install.sh> <home>：用 bash 執行（副本有時不是 +x）
run_install_sh() {
    local inst="$1" home="$2"; shift 2
    bash "$inst" --home "$home" --user "$(whoami)" "$@" </dev/null 2>&1
}

# 副本：把整個單位複製到沙箱，之後只換副本的 files/ 某一支。
# install.sh 自己用 BASH_SOURCE 推 SCRIPT_DIR，所以整棵樹一起複製才會讓它
# 讀到副本的 files/（只複製 install.sh 的話 FILES_DIR 會指回 repo 的真檔）。
sandbox_unit() {  # sandbox_unit <unit-dir> <dest>
    local src="$1" dest="$2"
    rm -rf "$dest"
    mkdir -p "$dest"
    cp "$src/install.sh" "$dest/install.sh"
    chmod +x "$dest/install.sh"
    mkdir -p "$dest/files"
    cp "$src/files/"* "$dest/files/" 2>/dev/null || true
}

echo "=== D10-1 安裝時換檔：重裝之後每個目標檔都是新的 inode ==="

# --- pool-runtime ---
PR_HOME="$SANDBOX/pr-home"
if out="$(run_install "$PR_INSTALL" "$PR_HOME")" && [[ -d "$PR_HOME/.mylinuxpool/bin" ]]; then
    # 第一次安裝之後的 inode
    declare_pr_inodes() {
        local d="$1"
        for f in "$d"/*; do
            [[ -f "$f" ]] || continue
            printf '%s\t%s\n' "${f##*/}" "$(inode_of "$f")"
        done
    }
    PR_BIN_DIR="$PR_HOME/.mylinuxpool/bin"
    PR_UNIT_DIR="$PR_HOME/.config/systemd/user"
    before_bin="$(declare_pr_inodes "$PR_BIN_DIR")"
    before_unit="$(declare_pr_inodes "$PR_UNIT_DIR")"
    n_before="$(printf '%s\n' "$before_bin" | grep -c .)"
    if [[ "$n_before" -lt 1 ]]; then
        bad "D10-1a. 前提失敗：第一次安裝之後 ${PR_BIN_DIR} 底下沒有檔案（安裝輸出：${out}）"
    else
        # 第二次安裝（內容一模一樣——重點是「再裝一次」這個動作本身）
        run_install "$PR_INSTALL" "$PR_HOME" >/dev/null
        after_bin="$(declare_pr_inodes "$PR_BIN_DIR")"
        after_unit="$(declare_pr_inodes "$PR_UNIT_DIR")"
        # 記下來的每一個 inode 都必須是數字；不是的話是 harness 壞了（見 inode_of），
        # 不能拿來判「有沒有換檔」。
        bad_ino=""
        while IFS=$'\t' read -r nm iv; do
            [[ -n "$nm" ]] || continue
            [[ "$iv" =~ ^[0-9]+$ ]] || bad_ino="${bad_ino} ${nm}=[${iv}]"
        done <<< "$(printf '%s\n' "$before_bin" "$before_unit")"
        if [[ -n "$bad_ino" ]]; then
            bad "D10-1a. 取不到可用的 inode（harness 問題，兩種 stat 語意都試過了）：${bad_ino}"
            same=""
        else
        same=""
        while IFS=$'\t' read -r name ino; do
            [[ -n "$name" ]] || continue
            now="$(printf '%s\n' "$after_bin" | awk -F'\t' -v n="$name" '$1==n{print $2; exit}')"
            if [[ -z "$now" ]]; then
                same="${same} ${name}(不見了)"
            elif [[ "$now" == "$ino" ]]; then
                same="${same} ${name}"
            fi
        done <<< "$before_bin"
        while IFS=$'\t' read -r name ino; do
            [[ -n "$name" ]] || continue
            now="$(printf '%s\n' "$after_unit" | awk -F'\t' -v n="$name" '$1==n{print $2; exit}')"
            if [[ -z "$now" ]]; then
                same="${same} unit:${name}(不見了)"
            elif [[ "$now" == "$ino" ]]; then
                same="${same} unit:${name}"
            fi
        done <<< "$before_unit"
        fi
        if [[ -n "$bad_ino" ]]; then
            :   # 上面已經報過 harness 問題；這裡不再對「原地覆寫」下結論
        elif [[ -z "$same" ]]; then
            ok "D10-1a. pool-runtime 重裝之後 bin/ 與 systemd unit 的每個檔都是新的 inode（${n_before} 支 bin）"
        else
            bad "D10-1a. 這些檔重裝之後 inode 沒變（原地覆寫）：${same} —— 正在執行的舊版 process 會讀到新內容"
        fi
    fi
else
    bad "D10-1a. 前提失敗：pool-runtime 第一次安裝失敗（${out}）"
fi

# --- wol ---
WOL_HOME="$SANDBOX/wol-home"
if out="$(run_install_sh "$WOL_INSTALL" "$WOL_HOME")" && [[ -f "$WOL_HOME/.mylinuxpool/bin/pool-wol" ]]; then
    wol_bin="$WOL_HOME/.mylinuxpool/bin/pool-wol"
    ino1="$(inode_of "$wol_bin")"
    run_install_sh "$WOL_INSTALL" "$WOL_HOME" >/dev/null
    ino2="$(inode_of "$wol_bin")"
    if [[ -z "$ino1" || -z "$ino2" ]]; then
        bad "D10-1b. 前提失敗：取不到 pool-wol 的 inode（stat 兩種語意都試過了）"
    elif [[ "$ino1" == "$ino2" ]]; then
        bad "D10-1b. wol 重裝之後 pool-wol 的 inode 沒變（${ino1}）—— 原地覆寫"
    else
        ok "D10-1b. wol 重裝之後 pool-wol 是新的 inode（${ino1} → ${ino2}）"
    fi
else
    bad "D10-1b. 前提失敗：wol 第一次安裝失敗（${out}）"
fi

echo "=== D10-2 行為面：正在執行的舊版 process 不受換檔影響 ==="
# 一支「先印一行、睡幾秒、再印自己後面那幾行」的腳本。bash 是邊執行邊讀的，
# 所以 sleep 醒來之後讀到的位元組取決於**那個 inode 此刻的內容**：
#   原地覆寫（cp -f）→ 讀到新版 → 這裡是語法錯誤 → syntax error、非 0
#   換檔（mv）      → 讀到舊版 → 照原本的內容跑完 → rc=0
#
# 兩版的**前綴長度必須一樣長**，否則舊 process 的讀取位移會落在新版尾端之外，
# 那就量不到「讀到新內容」這件事了（新版要留成明顯不同的語法錯誤）。
PROBE_OLD='#!/usr/bin/env bash
echo OLD-HEAD
sleep 3
echo OLD-TAIL
'
PROBE_NEW='#!/usr/bin/env bash
echo NEW-HEAD
sleep 3
)); then echo ")); fi" # INJECTED SYNTAX ERROR
'
# 前綴（到 sleep 那行為止）要等長
old_head="$(printf '%s\n' "$PROBE_OLD" | sed -n '1,3p')"
new_head="$(printf '%s\n' "$PROBE_NEW" | sed -n '1,3p')"
if [[ "${#old_head}" -ne "${#new_head}" ]]; then
    bad "D10-2. 前提失敗：兩版的前綴不等長（${#old_head} vs ${#new_head}）—— 量不到東西（測試自己的問題）"
else
    ok "D10-2-pre. 兩版前綴等長（${#old_head} bytes），舊 process 的讀取位移會落在新版內容裡"
fi

# run_replace_probe <install-sh> <home> <probe-dest-in-files>
#   1) 把「舊版」放進沙箱單位的 files/pool-sync，安裝出去
#   2) 啟動**裝好的那一支**（它就是正在執行的舊版 pool-sync）
#   3) 睡一下，等它進入 sleep
#   4) 把 sources 換成「新版」（語法錯誤版），再跑一次 install.sh —— 覆寫發生
#   5) 等舊 process 結束，看它的輸出與退出碼
#   印：<舊 process 的 rc>|<它的輸出>
run_replace_probe() {  # <install.sh> <home> <files/ 裡那一支> <沙箱單位目錄> [已安裝的檔名]
    local install_sh="$1" home="$2" src_file="$3" sandbox_unit_dir="$4"
    local bin_name="${5:-pool-sync}"
    local bin="$home/.mylinuxpool/bin/$bin_name" out rc

    printf '%s' "$PROBE_OLD" > "$sandbox_unit_dir/files/$(basename "$src_file")"
    run_install_sh "$install_sh" "$home" >/dev/null 2>&1
    if [[ ! -x "$bin" ]]; then
        printf 'NOBINSTALL'; return
    fi
    : > "$SANDBOX/probe.out"
    ( bash "$bin" >"$SANDBOX/probe.out" 2>&1; printf '%s' "$?" > "$SANDBOX/probe.rc" ) &
    local pid=$!
    sleep 1                      # 讓它跑過 echo、進入 sleep
    printf '%s' "$PROBE_NEW" > "$sandbox_unit_dir/files/$(basename "$src_file")"
    run_install_sh "$install_sh" "$home" >/dev/null 2>&1
    wait "$pid" 2>/dev/null
    rc="$(cat "$SANDBOX/probe.rc" 2>/dev/null)"
    out="$(tr '\n' '|' < "$SANDBOX/probe.out" 2>/dev/null)"
    printf '%s|%s' "$rc" "$out"
}

# 2a：pool-runtime（用沙箱副本當來源，install.sh 原封不動）
PR_SB_UNIT="$SANDBOX/pr-unit"
sandbox_unit "$PR_UNIT" "$PR_SB_UNIT"
got="$(run_replace_probe "$PR_SB_UNIT/install.sh" "$SANDBOX/pr-home2" "$PR_UNIT/files/pool-sync" "$PR_SB_UNIT")"
if [[ "$got" == NOBINSTALL* ]]; then
    bad "D10-2a. 前提失敗：沙箱副本的第一次安裝沒有產出 bin/pool-sync（${got}）"
elif [[ "$got" == 0\|*OLD-TAIL* ]] && ! printf '%s' "$got" | grep -qE 'syntax error|NEW-HEAD'; then
    ok "D10-2a. pool-sync 被換掉之後，正在執行的舊版照原本的內容跑完（rc=0、印出 OLD-TAIL、沒有 syntax error）"
else
    bad "D10-2a. 舊版 process 被換檔影響到了（got [$got]）—— rc 應該 0 且印 OLD-TAIL；syntax error 表示安裝時是原地覆寫"
fi

# 2b：wol 的 pool-wol（同一個形狀；pool-wol 不是被 source 的，但「正在執行中的
#     檔案被覆寫」是同一件事，所以同一個探針直接套在 wol 單位上）
if [[ -f "$WOL_UNIT/files/pool-wol" ]]; then
    WOL_SB_UNIT="$SANDBOX/wol-unit"
    sandbox_unit "$WOL_UNIT" "$WOL_SB_UNIT"
    got="$(run_replace_probe "$WOL_SB_UNIT/install.sh" "$SANDBOX/wol-home2" "$WOL_UNIT/files/pool-wol" "$WOL_SB_UNIT" pool-wol)"
    if [[ "$got" == NOBINSTALL* ]]; then
        bad "D10-2b. 前提失敗：沙箱副本的第一次安裝沒有產出 bin/pool-wol（${got}）"
    elif [[ "$got" == 0\|*OLD-TAIL* ]] && ! printf '%s' "$got" | grep -qE 'syntax error|NEW-HEAD'; then
        ok "D10-2b. pool-wol 被換掉之後，正在執行的舊版照原本的內容跑完（rc=0、印出 OLD-TAIL）"
    else
        bad "D10-2b. 舊版 process 被換檔影響到了（got [$got]）"
    fi
else
    bad "D10-2b. 前提失敗：shared-configs/wol/files/pool-wol 不存在"
fi

echo "=== D10-3 換檔的副作用：權限還在、沒有殘留暫存檔 ==="
# bin/ 與 unit 目錄的檔案集合必須**剛好**是宣告的那些。
# D10 用 `mktemp "${dst}.XXXXXX.new"` 當暫存檔：換檔成功時它必須被 mv 掉，
# 失敗時必須被 rm -f 掉。任何一個留下來，下一次 pool-sync 的 --check 與
# 「bin/ 底下有什麼」的假設就會對不上，而且那是使用者看得見的垃圾檔。
check_no_leftovers() {  # check_no_leftovers <label> <dir> <預期檔案…>
    local label="$1" dir="$2"; shift 2
    local want have extra missing
    want="$(printf '%s\n' "$@" | LC_ALL=C sort)"
    have="$(cd "$dir" 2>/dev/null && ls -A 2>/dev/null | LC_ALL=C sort)"
    if [[ -z "$have" ]]; then
        bad "${label}: ${dir} 不存在或讀不到（harness 問題）"; return
    fi
    extra="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have") | tr '\n' ' ')"
    missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have") | tr '\n' ' ')"
    if [[ -n "$extra" ]]; then
        bad "${label}: ${dir} 底下多出${extra}——換檔的暫存檔沒被清掉"
    elif [[ -n "$missing" ]]; then
        bad "${label}: ${dir} 底下少了${missing}——安裝沒有把檔案放齊"
    else
        ok "${label}: ${dir} 的內容剛好是宣告的那些（沒有暫存檔殘留）"
    fi
}
PR_BINARIES="$(sed -n 's/^BINARIES="\(.*\)"$/\1/p' "$PR_INSTALL" | head -1)"
PR_LIBS="$(sed -n 's/^LIBS="\(.*\)"$/\1/p' "$PR_INSTALL" | head -1)"
PR_UNITS="$(sed -n 's/^UNITS="\(.*\)"$/\1/p' "$PR_INSTALL" | head -1)"
if [[ -d "$PR_BIN_DIR" && -d "$PR_UNIT_DIR" ]]; then
    check_no_leftovers "D10-3a" "$PR_BIN_DIR" $PR_BINARIES $PR_LIBS
    check_no_leftovers "D10-3b" "$PR_UNIT_DIR" $PR_UNITS
    # 迴圈變數刻意不叫 f：上面 declare_pr_inodes 沒有把 f 宣告為 local，
    # 共用同一個名字會讓兩段的「看見的東西」互相污染（第一版就因此報了四支
    # 假紅：實際上那些檔都是 755）。
    notx=""
    for one in $PR_BINARIES; do
        one_path="$PR_BIN_DIR/$one"
        if [[ ! -f "$one_path" ]]; then
            notx="${notx} ${one}(不見)"
        elif [[ ! -x "$one_path" ]]; then
            notx="${notx} ${one}"
        fi
    done
    if [[ -n "$notx" ]]; then
        bad "D10-3c. 這些檔安裝完之後不可執行：${notx}"
    else
        ok "D10-3c. bin/ 底下宣告的那幾支安裝完都還可執行（${PR_BINARIES}）"
    fi
    # tunnel-identity.sh 是被 source 的，**不該**有執行位（preflight 的分界）
    if [[ -x "$PR_BIN_DIR/tunnel-identity.sh" ]]; then
        bad "D10-3d. tunnel-identity.sh 有執行位——它是 source 進去的，preflight 只要求「沒有東西 source 它」才必須 +x"
    else
        ok "D10-3d. tunnel-identity.sh 沒有執行位（source 進去的檔不該有）"
    fi
    if [[ -x "$WOL_HOME/.mylinuxpool/bin/pool-wol" ]]; then
        ok "D10-3e. pool-wol 安裝完還可執行"
    else
        bad "D10-3e. pool-wol 安裝完不可執行（或不存在）"
    fi
else
    bad "D10-3. 前提失敗：${PR_BIN_DIR}／${PR_UNIT_DIR} 不存在（前面的安裝失敗了）"
fi

echo "=== 注入：證明 D10-1／D10-2 在原地覆寫的形狀下會紅 ==="

# INJ-R1：把 install_file 換回 `cp -f` → D10-1a 與 D10-2a 必須轉紅。
#   這是 D10 的命題在**實作側**的對照：換檔的形狀一消失，兩條斷言就抓得到。
#   形狀錨點：install.sh 裡 install_file 的本體（`install_file() {` … `^}`），
#   整個換成 cp 版本。命中數必須剛好 1，突變版必須 bash -n 過。
if [[ ! -f "$PR_INSTALL" ]]; then
    inj_bad "INJ-R1. ${PR_INSTALL} 不存在，無法注入"
else
    INJ1_DIR="$SANDBOX/inj1-unit"
    sandbox_unit "$PR_UNIT" "$INJ1_DIR"
    python3 - "$PR_INSTALL" "$INJ1_DIR/install.sh" <<'INJR1'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^install_file\(\) \{.*?^\}', src, re.M | re.S)
assert m, "install_file() not found"
body = ('install_file() {\n'
         '    # INJECTED: 回到原地覆寫（D10 之前的形狀）。\n'
         '    # 簽章是 install_file <source> <target> <mode>：$2 是目標、$3 是 mode\n'
         '    # （第一版把這兩個寫反了，結果 cp 拿到 mode 當目標 → 安裝失敗 →\n'
         '    #  「突變版的 inode 有變（空 → 空）」——注入自己壞掉的樣子。）\n'
         '    cp -f "$1" "$2"\n'
         '    chmod "$3" "$2"\n'
         '}')
out = src[:m.start()] + body + src[m.end():]
open(sys.argv[2], "w", encoding="utf-8").write(out)
INJR1
    if [[ $? -ne 0 ]]; then
        inj_bad "INJ-R1. 突變腳本失敗（install_file 的形狀變了）——harness 問題"
    elif ! bash -n "$INJ1_DIR/install.sh" 2>/dev/null; then
        inj_bad "INJ-R1. 突變版語法錯誤——harness 問題"
    else
        H1="$SANDBOX/inj1-home"
        run_install_sh "$INJ1_DIR/install.sh" "$H1" >/dev/null 2>&1
        b1="$(inode_of "$H1/.mylinuxpool/bin/pool-sync")"
        run_install_sh "$INJ1_DIR/install.sh" "$H1" >/dev/null 2>&1
        a1="$(inode_of "$H1/.mylinuxpool/bin/pool-sync")"
        if [[ -n "$b1" && "$b1" == "$a1" ]]; then
            p2="$(run_replace_probe "$INJ1_DIR/install.sh" "$SANDBOX/inj1-home2" "$PR_UNIT/files/pool-sync" "$INJ1_DIR")"
            if [[ "$p2" == *'syntax error'* || "$p2" == 0\| ]]; then
                inj_ok "INJ-R1. 回到 cp -f 之後 D10-1a 的 inode 不變、D10-2a 的舊版 process 讀到新內容（${p2}）——兩條都會紅"
            else
                inj_bad "INJ-R1. 回到 cp -f 之後行為斷言仍綠（${p2}）——D10-2a 不是在看這件事"
            fi
        else
            inj_bad "INJ-R1. 突變版的 inode 竟然有變（${b1} → ${a1}）——注入沒生效"
        fi
    fi
fi

# INJ-R2：讓 install_file 失敗時**不留**暫存檔的保證破掉 → D10-3 必須轉紅。
#   突變：把失敗分支的 `rm -f "$tmp"` 拿掉，於是安裝失敗後 tmp 會留在 bin/ 裡。
#   D10-3a 是「內容剛好是宣告的那些」，多一個檔就紅。
if [[ ! -f "$PR_INSTALL" ]]; then
    inj_bad "INJ-R2. ${PR_INSTALL} 不存在，無法注入"
else
    INJ2_DIR="$SANDBOX/inj2-unit"
    sandbox_unit "$PR_UNIT" "$INJ2_DIR"
    python3 - "$PR_INSTALL" "$INJ2_DIR/install.sh" <<'INJR2'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '    if ! cp "$src" "$tmp" || ! chmod "$mode" "$tmp"; then\n        rm -f "$tmp"\n        return 1\n    fi\n'
new = '    if ! cp "$src" "$tmp" || ! chmod "$mode" "$tmp"; then\n        # INJECTED: 不清暫存檔\n        return 1\n    fi\n'
if src.count(old) != 1:
    # 形狀沒變過（還是 cp -f 的舊版）時，改成在 cp 之前先造一個暫存檔並放棄
    old2 = 'install_file() {\n'
    assert src.count(old2) == 1, "install_file() shape changed"
    sys.exit(3)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
INJR2
    case $? in
      0) : ;;
      3) inj_bad "INJ-R2. install_file 的失敗分支形狀變了（或者 install_file 還沒落地）——harness 問題" ;;
      *) inj_bad "INJ-R2. 突變腳本失敗——harness 問題" ;;
    esac
    if [[ -f "$INJ2_DIR/install.sh" ]] && grep -q 'INJECTED: 不清暫存檔' "$INJ2_DIR/install.sh" 2>/dev/null; then
        if ! bash -n "$INJ2_DIR/install.sh" 2>/dev/null; then
            inj_bad "INJ-R2. 突變版語法錯誤——harness 問題"
        else
            H2="$SANDBOX/inj2-home"
            # 讓安裝失敗：把來源檔拿掉一個（install_file 會 cp 失敗 → 走失敗分支）
            rm -f "$INJ2_DIR/files/pool-status"
            run_install_sh "$INJ2_DIR/install.sh" "$H2" >/dev/null 2>&1
            # 暫存檔名是 mktemp "${dir}/.${檔名}.XXXXXX"——XXXXXX 會被取代掉，
            # 所以不能比對那個字串；要比對「除了宣告的那些之外還有沒有別的檔」。
            leftover="$(comm -13 <(printf '%s\n' $PR_BINARIES $PR_LIBS | LC_ALL=C sort) \
                              <(cd "$H2/.mylinuxpool/bin" 2>/dev/null && ls -A | LC_ALL=C sort) | tr '\n' ' ')"
            if [[ -n "$leftover" ]]; then
                inj_ok "INJ-R2. 失敗時不清暫存檔之後 bin/ 底下留下了${leftover}——D10-3a 會紅"
            else
                inj_bad "INJ-R2. 突變後沒有殘留暫存檔（bin/ 只有宣告的那些）——注入沒生效"
            fi
        fi
    fi
fi

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' "$pass" "$fail" "$injpass" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0