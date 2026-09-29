#!/usr/bin/env bash
# test-callsite-lists.sh — 檔頭列出的「呼叫端清單」必須與掃描出來的實際呼叫端一致。
#
# 2026-09-26（qa 找到）：`scripts/lib/refresh-wait.sh` 的檔頭說「Consumers source
# this file and call dispatch_refresh_and_wait:」然後列兩個，而實際上
# `ops-scripts/register-provider.sh:664` 也呼叫它——**第三個**。而既有的測試是
# 照著檔頭寫的，所以那些測試永遠不會發現第三個呼叫端。
#
# 值得記下來的形狀：**文件錯了，測試從文件抄，於是測試的覆蓋範圍符合文件而不是
# 符合現實**；而文件與測試互相印證，看起來一致。抓那個缺口的唯一辦法是讓「實際
# 呼叫端」變成掃出來的機械事實，而把「檔頭宣稱」也變成解析出來的機械事實——
# 兩邊都不能靠人比對。
#
# 判準在 helpers/callsite-audit.py 的檔頭（含掃描範圍與已知的解析極限）。這一支
# 只負責：跑它、斷言它紅得**指名**，並且用注入證明紅與綠都不是偶然。
#
# ---- 通用性：這條判準今天覆蓋得多少（2026-09-26 量測）----------------------
#
# 掃描器是通用的：給一個函式名，它掃全樹的程式檔（.sh／無副檔名的 ops 腳本／
# *.yml），覆蓋直接呼叫、**間接呼叫**（呼叫被包在另一個函式裡）與 workflow 的
# `run:` 區塊——三種形狀各有注入釘著（§2 的 2d／2e）。
#
# ** Declare 端不是通用的，而且這不是掃描器的問題。** 全repo 掃過之後：
#
#   * 檔頭用**可解析的結構化清單**宣告呼叫端的地方：**1 處**
#     （scripts/lib/refresh-wait.sh）。
#   * 檔頭提到 consumer/caller 但寫成散文、機器讀不出來的：**16 個檔案**
#     （§3 會把名單印出來）。其中真正在列舉消費端的是 ssh.sh（"sourced by
#     ops-scripts/mlp … and .github/actions/pool-ssh/run.sh"）；
#     tunnel-key.sh（"Both callers now use these functions"，實際確實兩個）、
#     crypto.sh、gh/install.sh… 是散文提及，不是清單。
#
# 所以「通用版做不做得到」的答案是：**掃描端做得到，宣告端只有在有一致的格式時
# 才做得到，而那個格式今天存在一次。** 要擴大覆蓋只有兩條路，而且**格式該長什麼
# 樣是使用者的決定**，所以這個工具不去改那些檔頭（那會變成一個大改動）：
#   (a) 把那些檔頭改成 DECL_FORMAT（helper 檔頭定義的那一種），守衛立刻覆蓋；
#   (b) 承認它們不在這個判準的範圍內——但那要有個明確的決定，而不是讓 16 個
#       檔案看起來「被涵蓋了」。
# §3 的輸出把這 16 個檔案逐一印出來，就是為了讓 (a)/(b) 的決定有依據。
#
# 順帶一件量到的事：`scripts/lib/ssh.sh` 的散文列舉（2 個）比實際引用它的檔案
# （7 個非測試檔案）少。它不是這個判準的範圍（散文），但它是同一類缺陷的第一個
# 候選。
#
# ---- 這條守衛自己踩過的兩個坑（都記在這裡，因為形狀會復發）----------------
#
# 1. **解析器的續行處理。** 宣告清單的說明可以換行：
#       #   - scripts/create-worker.sh (workflows … call it via
#       #     create_worker_build_run_cmd's caller)
#     第一版在遇到非 `- ` 的行就 break，於是清單在第一項之後結束，declared 只收
#     到 1 項，而差額被報成「實際有、文件沒列」——**一個壞的解析器會長得像一個真
#     實的不一致**。修法：續行要跳過；而**清單被截斷時必須報 DECLARATION-
#     TRUNCATED**，不能把解析器的副作用說成一個發現（2f 釘著這條）。
# 2. **縮排量錯地方。** `indent_of` 原本量行首，而註解行的行首永遠是 `#`，所以
#     每個縮排都是 0、續行判定永遠不成立——症狀與上一條一模一樣。註解行的縮排要
#     量「`#` 後面那一段」。**兩個不同的 bug 產生同一個症狀**，而那個症狀看起來像
#      一個真實的資料不一致：這是為什麼「解析器壞掉」必須與「資料不一致」能被
#      分開說。
#
# 2026-09-26 曾經少列第三項（ops-scripts/register-provider.sh），那時 §1 是紅的；
# 缺陷已修（檔頭補上那一行），所以 §1 現在是綠的，正對照搬到 §2 的 2a（從檔頭拿掉
# 那行 → 必須紅且指名）。「紅證明有病」與「綠證明沒病」不能是同一條斷言在同一個
# 版本下同時成立——§1 釘後者，2a 釘前者。
#
# ---- 2026-09-29 修的兩個既有缺陷（使用者裁示在本分支一起修）----------------
#
# 1. **這支測試自己的 FAIL 不算數。** must_red_naming／must_green 只 printf
#    `FAIL`、return 1，沒有呼叫 bad()／injfail——畫面上兩行 FAIL，摘要行與
#    exit code 卻是綠（`passed 3 / failed 0`、exit 0）。CI 只看 exit code，
#    所以那兩條守衛等於不存在。修法：失敗分別計入 fail／injfail（成功計數點
#    不動），走既有的 exit 路徑。證據：拿掉修 2 後重跑，同一份程式現在會回
#    `passed 3 / failed 3`、rc 3（OUT-test-callsite-guard-fix.md §3a）。
# 2. **審計把 workflow 的 description: 文字當成呼叫。**
#    `.github/workflows/refresh-authorized-keys.yml` 的 input `description:`
#    裡有一句含 `dispatch_refresh_and_wait` 的說明，被文字掃描當成呼叫端，
#    報 `undeclared-callsite`（2026-09-27 `12d3a2b` 起；一直沒被發現，正是
#    因為缺陷 1 讓 §1a 的紅不算數）。修法在 helper：YAML 只掃 `run:` 純量的
#    內容（2e 釘「run: 裡的呼叫仍抓到」、2g 釘「description: 裡的文字不抓」）。
#
# 全離線：不連網、不連池子。所有注入都在 $SANDBOX 的整樹複本上做，不碰真的檔案。
# bash 3.2 相容。
#
# Run: scripts/tests/test-callsite-lists.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"
HELPER="scripts/tests/helpers/callsite-audit.py"
SUBJ="scripts/lib/refresh-wait.sh"
SUBJ_FUNC="dispatch_refresh_and_wait"
MISSING_CALLER="ops-scripts/register-provider.sh"   # 正對照用：從檔頭拿掉這行 → 必須紅且指名

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 required" >&2; exit 1
fi
if [[ ! -f "$HELPER" ]]; then
    echo "ERROR: ${HELPER} missing" >&2; exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-callsites.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

pass=0; fail=0; injpass=0; injfail=0
ok()   { pass=$((pass+1));   printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1));   printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# 整樹複本（去掉 .git）。注入全在這裡做。
TREE="$SANDBOX/tree"
mkdir -p "$TREE"
tar -cf - --exclude='.git' . 2>/dev/null | (cd "$TREE" && tar -xf - 2>/dev/null) \
    || { echo "ERROR: could not copy the tree into the sandbox" >&2; exit 1; }
[[ -f "$TREE/$SUBJ" ]] || { echo "ERROR: sandbox copy lacks ${SUBJ}" >&2; exit 1; }

audit() { python3 "$TREE/$HELPER" "$TREE" "$@"; }

# 斷言：跑審計，必須紅，且輸出必須指名 needle
# 2026-09-29 修：這兩個 helper 原先只 `printf FAIL` 就 return 1，**沒有把失敗
# 算進計數**——畫面上有 FAIL，摘要行與 exit code 卻是綠（CI 只看 exit code，
# 那些守衛等於不存在）。現在失敗會分別計入 injfail／fail，走既有的 exit 路徑。
# 計數語意（維持原本的成功計數點，只補上失敗）：
#   * 成功：must_red_naming 由呼叫端 `&& inj_ok` 記 injpass；must_green 的成功
#     與以前一樣不計數（§1a／复位那兩條本來就不在 passed 裡，形狀不變）。
#   * 失敗：must_red_naming → injfail；must_green → fail。
#     （2g 是 must_green，所以它的失敗走 fail 而不是 injfail——語意上是「這條
#     守衛斷言不成立」，兩者都進 exit code。）
must_red_naming() {   # must_red_naming <標籤> <needle> [更多 needle…]
    local label="$1"; shift
    local out rc n
    out="$(audit 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        injfail=$((injfail+1))
        printf '  FAIL  %s\n        預期紅，實際綠（輸出 [%s]）\n' "$label" "$(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
        return 1
    fi
    for n in "$@"; do
        if ! printf '%s' "$out" | grep -qF "$n"; then
            injfail=$((injfail+1))
            printf '  FAIL  %s\n        紅了但沒有指名「%s」（輸出 [%s]）\n' "$label" "$n" \
                "$(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"
            return 1
        fi
    done
    printf '  ok    %s\n' "$label"
    return 0
}
must_green() {   # must_green <標籤>
    local label="$1" out rc
    out="$(audit 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        fail=$((fail+1))
        printf '  FAIL  %s\n        預期綠，實際紅：[%s]\n' "$label" "$(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"
        return 1
    fi
    printf '  ok    %s\n' "$label"
    return 0
}

echo "=== 0. 先決條件 ==="
ok "0a. helper 與被審計的檔案都在（helper ${HELPER}／主體 ${SUBJ}）"

echo
echo "=== 1. 現況：檔頭與掃描一致 → 綠 ==="
must_green "1a. 工作樹現況 → 綠（檔頭列的呼叫端與掃描到的一致）"

echo
echo "=== 2. 注入：證明紅與綠都不是偶然 ==="
# 复位必須是**整棵树**的复位，不是只還原 subject 檔。
# 2026-09-26 第一版只還原 subject，於是 2e 對 workflow 的注入一路留到 2f，
# 2f 的輸出裡混著上一個注入的殘留——「紅了但指名的不是我要的」。注入之間互相
# 污染，測試的失敗模式就會變成「上一條注入沒清乾淨」。
SNAP_SUBJ="$SANDBOX/subject.orig"
SNAP_WF="$SANDBOX/delete-worker.orig"
cp "$TREE/$SUBJ" "$SNAP_SUBJ"
cp "$TREE/.github/workflows/delete-worker.yml" "$SNAP_WF"
reset_subject() {
    cp "$SNAP_SUBJ" "$TREE/$SUBJ"
    cp "$SNAP_WF" "$TREE/.github/workflows/delete-worker.yml"
    rm -f "$TREE"/scripts/lib/zz-*.sh
    return 0
}

# 2a 正對照：從檔頭拿掉第三項 → 紅，指名。
#     2026-09-26 之前這一條是反方向——檔頭缺那行時，§1 的紅證明「少列會紅」。
#     缺陷已修，§1 變成綠；於是正對照搬到這裡：如果以後那一行又被弄掉（或從沒
#     補上），這條會紅，且指名是誰少列了。must_green 在同一個版本下只有一種紅
#     法時不夠用——§1 釘「現在是對的」，這裡釘「弄壞會被發現」。
reset_subject
python3 - "$TREE/$SUBJ" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "#   - ops-scripts/register-provider.sh (mlp register provider)\n"
assert s.count(old) == 1, "needle count != 1"
open(p, "w", encoding="utf-8").write(s.replace(old, "", 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "2a. 注入腳本失敗（needle 落空）——harness 問題"
else
    must_red_naming "2a. 從檔頭拿掉 ${MISSING_CALLER} 那行 → 紅且指名它" \
        "undeclared-callsite ${MISSING_CALLER}" \
        && inj_ok "2a. 少列既有呼叫端被抓到——§1 的綠不是因為判準壞掉"
fi

# 2b：檔頭多列一個不存在的呼叫端 → 紅，指名「列了但掃不到」。
reset_subject
python3 - "$TREE/$SUBJ" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "#   - ops-scripts/register-client (mlp register client)\n"
assert s.count(old) == 1, "needle count != 1"
open(p, "w", encoding="utf-8").write(
    s.replace(old, old + "#   - ops-scripts/does-not-exist (never existed)\n", 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "2b. 注入腳本失敗——harness 問題"
else
    must_red_naming "2b. 檔頭多列一個不存在的呼叫端 → 紅，指名 declared-but-absent" \
        "declared-but-absent ops-scripts/does-not-exist" \
        && inj_ok "2b. 多列的假呼叫端被抓到——不是只有「少列」會紅"
fi

# 2c：刪掉檔頭清單裡的一項 → 紅，指名那一項「實際有、沒列」。
reset_subject
python3 - "$TREE/$SUBJ" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "#   - ops-scripts/register-client (mlp register client)\n"
assert s.count(old) == 1, "needle count != 1"
open(p, "w", encoding="utf-8").write(s.replace(old, "", 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "2c. 注入腳本失敗——harness 問題"
else
    must_red_naming "2c. 刪掉一項 → 紅，指名那一項 undeclared-callsite" \
        "undeclared-callsite ops-scripts/register-client" \
        && inj_ok "2c. 少列的既有呼叫端被抓到（不是只有新冒出來的會紅）"
fi

# 2d：**間接**呼叫端（呼叫被包在另一個函式裡）→ 紅，指名。
#     這一條是掃描完整性的證明：工單點名「間接呼叫」不能漏。樹上現成的
#     scripts/create-worker.sh 就是這種形狀（薄包裝 create_worker_dispatch_
#     refresh_and_wait），所以先確認它本來就在實際集合裡。
reset_subject
# 放進一個**全新的檔案**：放進已經被宣告的檔案不會產生差額（它本來就在實際
# 集合裡），於是這一條會「紅了但沒指名」——那正是測試必須分辨的兩種結果。
python3 - "$TREE/scripts/lib/zz-indirect-injection.sh" <<'PY'
import sys
p = sys.argv[1]
open(p, "w", encoding="utf-8").write(
    "#!/usr/bin/env bash\n"
    "# INJECTED: 間接呼叫端（呼叫被包在另一個函式裡）\n"
    "zz_indirect_wrapper() {\n"
    "    dispatch_refresh_and_wait 300\n"
    "}\n")
PY
if [[ $? -ne 0 ]]; then
    inj_bad "2d. 注入腳本失敗——harness 問題"
else
    must_red_naming "2d. 間接呼叫（包在函式裡、且在新檔案裡）也會被抓到" \
        "undeclared-callsite scripts/lib/zz-indirect-injection.sh" \
        && inj_ok "2d. 間接呼叫端被掃到——掃描不是只認最上層的呼叫，也不是只看既有檔案"
fi

# 2e：workflow 的 run: 區塊裡的呼叫 → 紅，指名。
reset_subject
python3 - "$TREE/.github/workflows/delete-worker.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "jobs:\n"
assert s.count(old) >= 1, "no jobs: key"
s = s.replace("      - name: Checkout\n",
              "      - name: INJECTED direct refresh\n"
              "        shell: bash\n"
              "        run: |\n"
              "          GH_REPO=x dispatch_refresh_and_wait 300\n"
              "      - name: Checkout\n", 1)
open(p, "w", encoding="utf-8").write(s)
PY
if [[ $? -ne 0 ]]; then
    inj_bad "2e. 注入腳本失敗（workflow 形狀變了）——harness 問題"
else
    must_red_naming "2e. workflow run: 區塊裡的呼叫也會被抓到" \
        "undeclared-callsite .github/workflows/delete-worker.yml" \
        && inj_ok "2e. workflow 裡的呼叫端被掃到——CI 路徑不會漏（修 2 沒有放掉真呼叫）"
fi

# 2g：**純量資料裡的函式名不是呼叫**（2026-09-29 修 2 的正對照）。
#     把同一個函式名放進 `description:`（workflow input 的說明文字）→
#     審計必須**不**紅。這是修 2 的兩面之一：2e 證明 run: 裡的呼叫仍被抓到，
#     2g 證明 description: 裡的文字不再被當成呼叫。少了這條，修 2 可能只是
#     把整份 YAML 排除掉——那樣 2e 也會紅，看不出差別。
reset_subject
python3 - "$TREE/.github/workflows/delete-worker.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "      port:\n        description: Worker's Gateway port (from Create Worker's output). Either this or name.\n"
assert s.count(old) == 1, "description needle count != 1: %d" % s.count(old)
s = s.replace(old, old +
              "      doc_only:\n"
              "        description: 'Documentation: dispatch_refresh_and_wait is described here.'\n"
              "        required: false\n"
              "        default: ''\n"
              "        type: string\n", 1)
open(p, "w", encoding="utf-8").write(s)
PY
if [[ $? -ne 0 ]]; then
    inj_bad "2g. 注入腳本失敗（workflow 形狀變了）——harness 問題"
else
    must_green "2g. 函式名寫在 description:（資料）→ 不紅（修 2：純量資料不是呼叫）" \
        && inj_ok "2g. description 裡的函式名不再誤報——修 2 只排資料，沒排真呼叫（2e 對照）"
fi

# 2f：**解析器壞掉不會長得像真實的不一致。**
#     把檔頭清單的續行縮排改平，解析器就會在第一項之後停住，declared 只剩 1 項。
#     那會產生兩筆「undeclared-callsite」——於是壞解析器與真實不一致**看起來
#     一樣**。這一條要求守衛把它分辨出來：解析器少收項時要報「宣告解析下來比
#     應行的少」，而不是把差額說成「實際有、文件沒列」。
#     2026-09-26 的第一版就是沒有這個分辨：indent_of 量行首（註解行的行首永遠
#     是 '#'，於是每個縮排都是 0），續行判定永遠不成立，清單在第一項後停住。
reset_subject
python3 - "$TREE/$SUBJ" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "#     create_worker_build_run_cmd's caller)"
assert s.count(old) == 1, "needle count != 1"
open(p, "w", encoding="utf-8").write(
    s.replace(old, "#   create_worker_build_run_cmd's caller)", 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "2f. 注入腳本失敗——harness 問題"
else
    out="$(audit 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        inj_bad "2f. 續行被打平之後守衛仍然綠——解析器對清單形狀太敏感"
    elif printf '%s' "$out" | grep -q 'DECLARATION-TRUNCATED'; then
        inj_ok "2f. 清單被截斷時報的是 DECLARATION-TRUNCATED（宣告解析不下來），不是「實際有、文件沒列」"
    else
        inj_bad "2f. 壞掉的解析器與真實不一致無法分辨（輸出 [$(printf '%s' "$out" | tr '\n' ' ' | head -c 260)]）"
    fi
fi

reset_subject
must_green "（复位後）工作樹現況 → 綠（檔頭與掃描一致，注入沒有殘留）"

echo
echo "=== 3. 通用性：這個判準覆蓋得多少 ==="
# 這一段是資訊，不是通過／失敗：它回答「repo 裡還有多少檔案在檔頭列呼叫端」。
verbose="$(audit --verbose 2>&1)"
n_declared="$(printf '%s' "$verbose" | sed -n 's/^CHECKED \([0-9]*\) declaration.*/\1/p')"
backlog="$(printf '%s' "$verbose" | sed -n 's/^BACKLOG \([0-9]*\) header.*/\1/p')"
printf '        可解析的結構化宣告：%s 處\n' "${n_declared:-?}"
printf '        檔頭提到 consumer/caller 但散文式、機器讀不出來：%s 個檔案\n' "${backlog:-?}"
printf '        → 通用性的上限由「宣告端格式」決定，不是掃描器；格式該長什麼樣是\n'
printf '          使用者的決定，所以這個工具不去改那些檔頭的格式。\n'
if [[ "${n_declared:-0}" -ge 1 ]]; then
    ok "3a. 掃描＋解析在樹上找得到至少一處可解析的宣告（${n_declared}）"
else
    bad "3a. 一處可解析的宣告都找不到——判準形狀可能已經過期"
fi
if printf '%s' "$verbose" | grep -q "^  scripts/lib/ssh.sh$"; then
    ok "3b. 落後清單裡確實有 scripts/lib/ssh.sh（散文式宣告，範圍外但可見）"
else
    bad "3b. 落後清單的形狀變了——輸出一眼看不懂就沒有用"
fi

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' \
    "$pass" "$fail" "$injpass" "$injfail"
[[ "$fail" -ne 0 ]] && exit "$fail"
[[ "$injfail" -ne 0 ]] && exit 2
exit 0
