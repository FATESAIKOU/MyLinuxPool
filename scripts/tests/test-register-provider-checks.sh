#!/usr/bin/env bash
# test-register-provider-checks.sh — 登錄新機器時真線炸出來的五個修正的護欄。
#
# 在防什麼（每條都是正式流程上炸過一次的）：
#   手寫清單漏網：preflight 只掃八個檔，第九個呼叫點住在沒人列的檔案裡等著。
#   護欄要求掃全 repo——列舉沿用 preflight 自己的 git ls-files 寫法，不另立清單。
#   函式歸屬錯認：檢查器把 step9_verify() 的問題報成 enable_linger()，
#   修錯地方比沒修更糟（數字開頭的函式名被舊正則跳過）。
#   curl 當網路探針：沒裝 curl 時 exit 127 被吞掉報成「沒有網路」，查錯方向；
#   且連線檢查跑在裝 curl 之前，「加進 pkgs」根本救不到。改走 bash /dev/tcp，
#   零依賴—— presence 與否行為一致才是「不依賴」的證明。
#   no-sudo 硬依賴黑洞：jq/gh 下載要 curl，而 no-sudo 不能 apt 裝它；
#   不在入口檢查就死在下載深處，訊息莫名其妙。
#   docker 假驗證（最重要）：id -nG 只看今世（目前 session 的群組），
#   群組變更只對新登入生效——群組在、socket 照樣不通時它照樣通過，
#   正是「壞掉時不會給出不同答案的問題」。護欄要求真的對 daemon 講到話。
#   sudo 分支（真實登錄走的路）：usermod 通＋新群組驗證通則過；
#   驗證不通指去查 daemon（不叫人重跑 usermod）；usermod 敗／sudo 不可用
#   即退。驗證必須是 sudo -u 該使用者而非 root——拿掉 -u 會讓 root 永遠
#   連上 socket，退化完全隱形（輸出看不出來），只剩 argv 記帳能抓。
#
# 手法：preflight 與檢查器直接跑真的檔案（純函式性；preflight 跑在沙箱 git
#   repo 裡，列舉與 git 行為都是真的）。register-provider.sh 不真的執行：
#   尾行 main 剝掉後的副本再 source（diff 證明只差尾行），頂層參數用 set --
#   餵，頂層驗證用 env 過；要測的 step 在子 shell 跑（它們用 exit 結束）。
#   全離線：curl 不在 PATH（或換成記帳 stub）、git/docker/dpkg/id/docker
#   全是 PATH stub，/dev/tcp 探測在無網路沙箱自然失敗。
#
# 注入（每條先證明會紅：突變版語法檢查先過＋needle 命中數剛好 1＋實際 got 值；
#   命中 2 次比 0 次更陰險——註解裡的同字串不會改變行為，命中數斷言擋的就是它）。
#
# 相容：只用 bash 3.2 就有的語法；測試本體不用陣列。
#
# Run: scripts/tests/test-register-provider-checks.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

RP="ops-scripts/register-provider.sh"
PREFLIGHT="ops-scripts/preflight"
AUDIT="scripts/tests/helpers/ssh-port-audit.py"

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required but not found on PATH" >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required but not found on PATH" >&2
    exit 1
fi
for f in "$RP" "$PREFLIGHT" "$AUDIT"; do
    if [[ ! -f "$f" ]]; then
        echo "test-register-provider-checks: ${f} is missing; dependent cases will FAIL" >&2
    fi
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-regprov-checks.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/home" "$SANDBOX/rd0" "$SANDBOX/rd1"

pass=0; fail=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- PATH 工具箱 -----------------------------------------------------------
# rd0：無 curl（curl 缺席情境）。rd1：rd0 加記帳 curl（curl 存在情境）。
# 其餘真工具用 symlink（source 期全 PATH，執行期只給受限 PATH）。
for t in date sleep bash grep jq tr mktemp whoami mkdir uname rm cat wc; do
    bin="$(command -v "$t" 2>/dev/null || true)"
    if [[ -n "$bin" ]]; then
        ln -sf "$bin" "$SANDBOX/rd0/$t"
    fi
done
cat > "$SANDBOX/rd0/systemctl" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat > "$SANDBOX/rd0/git" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat > "$SANDBOX/rd0/docker" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
  printf '%s\n' "${DOCKER_INFO_MSG:-Cannot connect to the Docker daemon}" >&2
  exit "${DOCKER_INFO_RC:-1}"
fi
exit 0
FAKE
cat > "$SANDBOX/rd0/dpkg" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat > "$SANDBOX/rd0/id" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == "-nG" ]]; then
  printf '%s\n' "${FAKE_GROUPS:-staff docker everyone}"
  exit 0
fi
exec /usr/bin/id "$@"
FAKE
# sudo：記帳（argv 一行一個＋CALL-EOL），行為全由 env 控。
#   -n true（ensure_sudo 探針）→ SUDO_N_TRUE_RC；-v → SUDO_V_RC，
#   預設失敗——絕不在 TTY 與否之間給出不同答案（否則量測看天）。
#   usermod → SUDO_USERMOD_RC；docker info 有 -u → SUDO_U_INFO_RC，
#   無 -u（即 root 身分）→ SUDO_ROOT_INFO_RC。-u 有無是第 5 條注入的關鍵，
#   所以 stub 必須分得出來，不能只看退出碼。
cat > "$SANDBOX/rd0/sudo" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a" >> "${SUDO_LOG:-/dev/null}"; done
printf 'CALL-EOL\n' >> "${SUDO_LOG:-/dev/null}"
if [[ "$*" == "-n true" ]]; then exit "${SUDO_N_TRUE_RC:-0}"; fi
if [[ "$*" == "-v" ]]; then exit "${SUDO_V_RC:-1}"; fi
case "$*" in
  *-n*usermod*) exit "${SUDO_USERMOD_RC:-0}" ;;
esac
has_u=0; has_info=0
for a in "$@"; do
  [[ "$a" == "-u" ]] && has_u=1
  [[ "$a" == "info" ]] && has_info=1
done
if [[ "$has_info" == "1" ]]; then
  if [[ "$has_u" == "1" ]]; then exit "${SUDO_U_INFO_RC:-0}"; fi
  exit "${SUDO_ROOT_INFO_RC:-0}"
fi
exit 0
FAKE
chmod +x "$SANDBOX/rd0/systemctl" "$SANDBOX/rd0/git" "$SANDBOX/rd0/docker" "$SANDBOX/rd0/dpkg" "$SANDBOX/rd0/id" "$SANDBOX/rd0/sudo"
mkdir -p "$SANDBOX/rd1"
cp -RP "$SANDBOX/rd0/"* "$SANDBOX/rd1/" 2>/dev/null
cat > "$SANDBOX/rd1/curl" <<'FAKE'
#!/usr/bin/env bash
printf 'CURL %s\n' "$*" >> "${CURL_LOG:-/dev/null}"
exit "${CURL_RC:-0}"
FAKE
chmod +x "$SANDBOX/rd1/curl"

# ---- register-provider.sh 載入器 --------------------------------------------
# 尾行 main 會直接開跑，剝掉再 source；diff 證明只差那一行。
RP_STRIP="$SANDBOX/rp.sh"
sed -e '$d' "$REPO_ROOT/$RP" > "$RP_STRIP"
if diff <(sed -e '$d' "$REPO_ROOT/$RP") "$RP_STRIP" >/dev/null 2>&1 \
&& tail -1 "$REPO_ROOT/$RP" | grep -qx 'main' \
&& ! tail -1 "$RP_STRIP" | grep -qx 'main'; then
    ok "harness. 剝尾 main 的副本與真檔只差一行（載入保真）"
else
    bad "harness. 剝尾 main 失敗——後面全不可信"
fi

echo "=== 0. 先決條件 ==="
missing=0
for fn in step1_preflight step1_preflight_no_sudo step7_5_docker_group tcp_probe; do
    if grep -qE "^${fn}\\(\\)" "$RP"; then
        :
    else
        bad "0. ${fn} 不存在——實作還沒落地？"
        missing=1
    fi
done
if [[ "$missing" -eq 0 ]]; then
    ok "0. 四個函式都在（step1、no-sudo、docker、tcp_probe）"
fi

echo "=== 1. preflight 掃全 repo（沙箱 git 跑真檔） ==="
# 沙箱 repo：真 preflight＋真檢查器＋幾個真 shell＋一個 planted 漏網。
# planted 模仿 :714 的形狀（變數目標、無 -p），函式名一併考歸屬。
PCREPO="$SANDBOX/pcrepo"
mkdir -p "$PCREPO/ops-scripts" "$PCREPO/scripts/tests/helpers" "$PCREPO/scripts" "$PCREPO/scripts/lib" "$PCREPO/shared-configs/pool-runtime/files" "$PCREPO/.github/actions/push-state"
cp -p "$REPO_ROOT/$PREFLIGHT" "$PCREPO/ops-scripts/preflight"
cp -p "$REPO_ROOT/$AUDIT" "$PCREPO/scripts/tests/helpers/ssh-port-audit.py"
chmod +x "$PCREPO/scripts/tests/helpers/ssh-port-audit.py"
for f in scripts/rotate-gateway.sh scripts/create-worker.sh .github/actions/push-state/run.sh shared-configs/pool-runtime/files/pool-tunnel shared-configs/pool-runtime/files/pool-status ops-scripts/mlp ops-scripts/verify-profile scripts/lib/ssh.sh; do
    cp -p "$REPO_ROOT/$f" "$PCREPO/$f"
done
# planted 漏網的觸發字串（ssh＋變數目標）只能在執行期組出來：
# 字面寫在這裡會被 preflight 自己的 ssh-port 掃描掃到（本檔亦在掃描範圍），
# 正是 test-workers-d-path.sh 檔頭記的那一坑。
#
# 2026-09-26：加了一行 shell shebang。preflight 的列舉改成「第一行是 shell
# shebang」之後，這個 planted 檔沒有 shebang 就不會被掃到，1a 會紅——而它
# 紅的原因是夾具自己不再合法，不是被測物有問題。加上 shebang 之後 1a 證的
# 是本來就該證的那件事：「列舉是照內容掃整個 repo，不是照某個檔名清單」，
# 因為沒有人把 extra-pool-ssh.sh 寫進任何清單。shebang 在第 1 行，所以
# 稽核器報的行號從 6 變 7，下面兩處 needle 跟著改。
python3 - "$PCREPO/extra-pool-ssh.sh" <<'PY'
import sys
at, dl = '@', '$'
lines = [
    '#!/usr/bin/env bash',
    'enable_linger() {',
    '    log INFO "linger probe"',
    '}',
    '',
    'step9_verify() {',
    '    banner="$(' + 'ssh' + ' -o StrictHostKeyChecking=accept-new -o BatchMode=yes "' + dl + '{gw_user}' + at + dl + '{gw_ip}" "true" 2>/dev/null || true)"',
    '    if [[ "$banner" == SSH-* ]]; then',
    '        log INFO "tunnel banner seen"',
    '    fi',
    '}',
    '',
]
open(sys.argv[1], 'w', encoding='utf-8').write('\n'.join(lines))
PY
git -C "$PCREPO" init -q
git -C "$PCREPO" add -A
pc_out="$(bash "$PCREPO/ops-scripts/preflight" 2>&1)"
pc_rc=$?
if printf '%s' "$pc_out" | grep -q 'extra-pool-ssh.sh:7' \
&& printf '%s' "$pc_out" | grep -q 'step9_verify()'; then
    ok "1a. 全 repo 掃描抓到清單外的漏網（extra-pool-ssh.sh:7，歸屬 step9_verify）"
else
    bad "1a. 漏網沒被抓到（rc=$pc_rc out [$(printf '%s' "$pc_out" | tr '\n' ' ' | head -c 300)])"
fi
# 真 repo 現在應該零誤報（:714 已修）：直接跑真檢查器驗證。
real_out="$(python3 "$REPO_ROOT/$AUDIT" \
    scripts/rotate-gateway.sh scripts/create-worker.sh \
    .github/actions/push-state/run.sh \
    shared-configs/pool-runtime/files/pool-tunnel \
    shared-configs/pool-runtime/files/pool-status \
    ops-scripts/mlp ops-scripts/verify-profile scripts/lib/ssh.sh \
    ops-scripts/register-provider.sh 2>&1)"
if [[ $? -eq 0 && -z "$real_out" ]]; then
    ok "1b. 真 repo 九檔全掃零 findings（:714 已修且無誤報）"
else
    bad "1b. 真 repo 有 findings（out [$real_out]）"
fi
# 注入 1：列舉改回八個檔名硬清單 → planted 漏網不再被抓到。
#   needle 是收斂後的共用 shell_files 塊（全檔唯一）；突變後同形賦硬清單，
#   後續 if／傳陣列沿用不動。列舉出現次數：原檔 1、突變後 0——
#   孿生列舉已不存在，!= 0 即有人又立第二份，正是原檢查要抓的事。
#
# 2026-09-26 兩處跟著 preflight 的列舉改寫（見 preflight 檔頭）：
#   1. needle 的列舉文字從 `git ls-files | grep -E '<檔名規則>'` 換成
#      `git ls-files | is_shell_script`。這是預期的失效——針打空會讓本測試
#      報 harness 問題，而那正是它該做的（形狀變了就出聲，不要靜靜地測
#      別的東西）。
#   2. 判斷「漏網被抓到」的 needle 從 `extra-pool-ssh.sh` 收緊成
#      `extra-pool-ssh.sh:7`。preflight 現在多了一條交叉檢查，訊息裡也會出現
#      這個檔名——但語意相反：稽核報 `檔名:行號` 是「抓到了」，交叉檢查報
#      「沒被稽核：檔名」是「抓不到」。用沒有行號的檔名當 needle 會讓這個
#      注入一直 inj_bad。帶行號才能分辨兩者，這也順手讓 needle 更精確。
INJ1="$SANDBOX/preflight-8list.sh"
python3 - "$REPO_ROOT/$PREFLIGHT" "$INJ1" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
enum_pat = 'git ls-files | is_shell_script'
assert src.count(enum_pat) == 1, "orig enumeration count != 1"
old = ('shell_files=()\n'
       'while IFS= read -r f; do\n'
       '    shell_files+=("$f")\n'
       'done < <(%s)\n' % (enum_pat,))
new = ('shell_files=(scripts/rotate-gateway.sh scripts/create-worker.sh .github/actions/push-state/run.sh shared-configs/pool-runtime/files/pool-tunnel shared-configs/pool-runtime/files/pool-status ops-scripts/mlp ops-scripts/verify-profile scripts/lib/ssh.sh)\n')
assert src.count(old) == 1, "8list needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "1. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ1" 2>/dev/null; then
    inj_bad "1. 注入版語法錯誤——harness 問題"
elif [[ "$(grep -c 'git ls-files | is_shell_script' "$INJ1")" -ne 0 ]]; then
    inj_bad "1. 突變後還有列舉殘留（期望 0）——harness 問題"
else
    cp "$INJ1" "$PCREPO/ops-scripts/preflight"
    git -C "$PCREPO" add -A
    inj_out="$(bash "$PCREPO/ops-scripts/preflight" 2>&1)"
    cp -p "$REPO_ROOT/$PREFLIGHT" "$PCREPO/ops-scripts/preflight"
    if printf '%s' "$inj_out" | grep -q 'extra-pool-ssh.sh:7'; then
        inj_bad "1. 改回八檔清單後漏網仍被抓到——掃描範圍沒被量到"
    else
        if printf '%s' "$inj_out" | grep -q '都指定了埠'; then
            inj_ok "1. 改回八檔清單後漏網消失（回報乾淨）——1a 會紅"
            # 附加證據（不是原注入的目標）：那條交叉檢查也把同一個漏網
            # 點名了，方向相反但同一個病灶。抓不到就只是少了這一條。
            if printf '%s' "$inj_out" | grep -q '沒被稽核：extra-pool-ssh.sh'; then
                inj_ok "1b. 同一個漏網也被交叉檢查點名（『沒被稽核』）——列舉範圍被量到了兩次"
            fi
        else
            inj_bad "1. 行為變了但不是預期的乾淨（out [$(printf '%s' "$inj_out" | tr '\n' ' ' | head -c 200)]）——harness 問題"
        fi
    fi
fi

echo "=== 2. 檢查器函式歸屬（跑真檢查器） ==="
ATTR_FIX="$SANDBOX/attr-fixture.sh"
cp "$PCREPO/extra-pool-ssh.sh" "$ATTR_FIX"
attr_out="$(python3 "$REPO_ROOT/$AUDIT" "$ATTR_FIX" 2>&1)"
if printf '%s' "$attr_out" | grep -q 'step9_verify()'; then
    ok "2a. 數字函式名正確歸屬（step9_verify，非 enable_linger）"
else
    bad "2a. 歸屬錯誤（got [$attr_out]）"
fi
# 注入 2：退回舊歸屬正則 → :714 行被報成 enable_linger()。
INJ2="$SANDBOX/audit-oldfn.py"
python3 - "$REPO_ROOT/$AUDIT" "$INJ2" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "m = re.match(r'^([a-z_][a-z0-9_]*)\\(\\) \\{', src[k])"
assert src.count(old) == 1, "oldfn needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, "m = re.match(r'^([a-z_]+)\\(\\) \\{', src[k])", 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "2. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! python3 -m py_compile "$INJ2" 2>/dev/null; then
    inj_bad "2. 注入版語法錯誤——harness 問題"
else
    inj_attr="$(python3 "$INJ2" "$ATTR_FIX" 2>&1)"
    if printf '%s' "$inj_attr" | grep -q 'step9_verify()'; then
        inj_bad "2. 退回舊正則後歸屬仍對——歸屬沒被量到"
    else
        if printf '%s' "$inj_attr" | grep -q 'enable_linger()'; then
            inj_ok "2. 退回舊正則後報成 enable_linger()（got [$inj_attr]）——2a 會紅"
        else
            inj_bad "2. 行為變了但不是預期的錯認（got [$inj_attr]）——harness 問題"
        fi
    fi
fi

echo "=== 3. 連線檢查：tcp_probe 回 0 通／1 不通／3 無法測 ==="
# tcp_probe 用 curl（若有，順便吃代理）否則 /dev/tcp＋timeout，
# 兩者皆無回 3。工具缺席與網路不通必須是不同的答案。
# 單元直打 tcp_probe（RUNPATH 受限：rd0 無 curl 無 timeout → 3 可測）。
got="$(RPSRC="$RP_STRIP" RUNPATH="$SANDBOX/rd1" CURL_RC=7 HOME="$SANDBOX/home3u" PATH="/usr/bin:/bin" \
  bash -c '
    mkdir -p "$HOME"
    set -- --name t --gateway-port 1
    GH_POOL_TOKEN=dummy HOME="$HOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
    PATH="$RUNPATH"
    rc=0; tcp_probe github.com 443 5 >/dev/null 2>&1 || rc=$?
    printf "RC=%s" "$rc"' 2>&1)"
if [[ "$got" == "RC=7" ]]; then
    ok "3a. curl 在場即委派（回 curl 的答案 7，不自己猜）"
else
    bad "3a. 不對（got [$got]）"
fi
got="$(RPSRC="$RP_STRIP" RUNPATH="$SANDBOX/rd0" HOME="$SANDBOX/home3v" PATH="/usr/bin:/bin" \
  bash -c '
    mkdir -p "$HOME"
    set -- --name t --gateway-port 1
    GH_POOL_TOKEN=dummy HOME="$HOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
    PATH="$RUNPATH"
    rc=0; tcp_probe github.com 443 5 >/dev/null 2>&1 || rc=$?
    printf "RC=%s" "$rc"' 2>&1)"
if [[ "$got" == "RC=3" ]]; then
    ok "3b. 兩工具皆無 → 回 3（無法測，不是網路不通）"
else
    bad "3b. 不對（got [$got]）"
fi
# 3c：step1 在兩工具皆無時報「無法測」，不是「沒有網路」。
got="$(TESTHOME="$SANDBOX/home3a" RPSRC="$RP_STRIP" RUNPATH="$SANDBOX/rd0" HOME="$SANDBOX/home3a" PATH="/usr/bin:/bin" \
  bash -c '
    mkdir -p "$TESTHOME"
    set -- --name t --gateway-port 1
    GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
    step1_preflight_sudo() { return 0; }
    step1_preflight_no_sudo() { return 0; }
    PATH="$RUNPATH"
    rc=0; ( step1_preflight >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
    printf "RC=%s ERRTXT=%s" "$rc" "$(cat "$TESTHOME/err" 2>/dev/null | tr "\n" " ")"' 2>&1)"
if [[ "$got" == "RC=1 "* ]] && printf '%s' "$got" | grep -qF 'cannot check connectivity: neither curl nor timeout'; then
    ok "3c. 無工具時 step1 說無法測（工具缺席≠網路不通）"
else
    bad "3c. 不對（got [$got]）"
fi
# 3d：curl 說不通（stub 回 1）→ 精確的 :443 訊息。
got="$(TESTHOME="$SANDBOX/home3b" RPSRC="$RP_STRIP" RUNPATH="$SANDBOX/rd1" CURL_RC=1 HOME="$SANDBOX/home3b" PATH="/usr/bin:/bin" \
  bash -c '
    mkdir -p "$TESTHOME"
    set -- --name t --gateway-port 1
    GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
    step1_preflight_sudo() { return 0; }
    step1_preflight_no_sudo() { return 0; }
    PATH="$RUNPATH"
    rc=0; ( step1_preflight >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
    printf "RC=%s ERRTXT=%s" "$rc" "$(cat "$TESTHOME/err" 2>/dev/null | tr "\n" " ")"' 2>&1)"
if [[ "$got" == "RC=1 "* ]] && printf '%s' "$got" | grep -qF 'no network connectivity to github.com:443'; then
    ok "3d. 網路不通報 :443（與無法測不同句）"
else
    bad "3d. 不對（got [$got]）"
fi
# 3e：curl 說通（stub 回 0）→ 過 :214（分流覆寫保證後面不亂跑）。
got="$(TESTHOME="$SANDBOX/home3e" RPSRC="$RP_STRIP" RUNPATH="$SANDBOX/rd1" CURL_RC=0 HOME="$SANDBOX/home3e" PATH="/usr/bin:/bin" \
  bash -c '
    mkdir -p "$TESTHOME"
    set -- --name t --gateway-port 1
    GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
    step1_preflight_sudo() { return 0; }
    step1_preflight_no_sudo() { return 0; }
    PATH="$RUNPATH"
    rc=0; ( step1_preflight >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
    printf "RC=%s" "$rc"' 2>&1)"
if [[ "$got" == "RC=0" ]]; then
    ok "3e. curl 說通即過 :214（代理情境仍走得動）"
else
    bad "3e. 不對（got [$got]）"
fi
# 注入 3：改回裸 curl → 無 curl 報舊訊息（無 :443、無「無法測」分類）。
INJ3="$SANDBOX/rp-curl.sh"
python3 - "$REPO_ROOT/$RP" "$INJ3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    local probe_rc=0\n'
       '    tcp_probe github.com 443 5 || probe_rc=$?\n'
       '    if [[ "$probe_rc" -eq 3 ]]; then\n'
       '        log ERROR "cannot check connectivity: neither curl nor timeout is available on this machine"\n'
       '        exit 1\n'
       '    elif [[ "$probe_rc" -ne 0 ]]; then\n'
       '        log ERROR "no network connectivity to github.com:443"\n'
       '        exit 1\n'
       '    fi')
new = ('    if ! curl -fsS --max-time 5 https://github.com >/dev/null 2>&1; then\n'
       '        log ERROR "no network connectivity to github.com"\n'
       '        exit 1\n'
       '    fi')
assert src.count(old) == 1, "curlback needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "3. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ3" 2>/dev/null; then
    inj_bad "3. 注入版語法錯誤——harness 問題"
else
    sed -e '$d' "$INJ3" > "$SANDBOX/rp-curl-src.sh"
    got="$(TESTHOME="$SANDBOX/home3i" RPSRC="$SANDBOX/rp-curl-src.sh" RUNPATH="$SANDBOX/rd0" HOME="$SANDBOX/home3i" PATH="/usr/bin:/bin" \
      bash -c '
        mkdir -p "$TESTHOME"
        set -- --name t --gateway-port 1
        GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
        step1_preflight_sudo() { return 0; }
        step1_preflight_no_sudo() { return 0; }
        PATH="$RUNPATH"
        rc=0; ( step1_preflight >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
        printf "RC=%s ERRTXT=%s" "$rc" "$(cat "$TESTHOME/err" 2>/dev/null | tr "\n" " ")"' 2>&1)"
    if printf '%s' "$got" | grep -qF 'cannot check connectivity' \
    || printf '%s' "$got" | grep -qF 'github.com:443'; then
        inj_bad "3. 改回 curl 後 3c/3d 仍綠——探針沒被量到"
    else
        if [[ "$got" == "RC=1 "* ]] && printf '%s' "$got" | grep -qF 'no network connectivity to github.com'; then
            inj_ok "3. 改回 curl 後無 curl 報舊訊息（got [$got]）——3c 會紅"
        else
            inj_bad "3. 行為變了但不是預期的舊訊息（got [$got]）——harness 問題"
        fi
    fi
fi

echo "=== 4. no-sudo 路徑先檢查 curl（早退，不死下載裡） ==="
got="$(TESTHOME="$SANDBOX/home4" RPSRC="$RP_STRIP" RUNPATH="$SANDBOX/rd0" HOME="$SANDBOX/home4" PATH="/usr/bin:/bin" \
  bash -c '
    mkdir -p "$TESTHOME"
    set -- --name t --gateway-port 1
    GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
    NO_SUDO=1
    PATH="$RUNPATH"
    rc=0; ( step1_preflight_no_sudo >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
    printf "RC=%s ERRTXT=%s" "$rc" "$(cat "$TESTHOME/err" 2>/dev/null | tr "\n" " ")"' 2>&1)"
if [[ "$got" == "RC=1 "* ]] && printf '%s' "$got" | grep -qF 'curl is missing; --no-sudo cannot install it without root' \
&& ! printf '%s' "$got" | grep -qF 'could not determine'; then
    ok "4a. 無 curl 早退（點名 curl），沒死在下載深處"
else
    bad "4a. 不對（got [$got]）"
fi
# 注入 4：拿掉 no-sudo 的 curl 檢查 → 死在 gh 下載深處。
INJ4="$SANDBOX/rp-nocurlcheck.sh"
python3 - "$REPO_ROOT/$RP" "$INJ4" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ('    if ! command -v curl >/dev/null 2>&1; then\n'
       '        log ERROR "curl is missing; --no-sudo cannot install it without root"\n'
       '        missing_root_pkg=1\n'
       '    fi\n')
assert src.count(old) == 1, "nocurlcheck needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, '', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "4. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ4" 2>/dev/null; then
    inj_bad "4. 注入版語法錯誤——harness 問題"
else
    sed -e '$d' "$INJ4" > "$SANDBOX/rp-nocurlcheck-src.sh"
    got="$(TESTHOME="$SANDBOX/home4i" RPSRC="$SANDBOX/rp-nocurlcheck-src.sh" RUNPATH="$SANDBOX/rd0" HOME="$SANDBOX/home4i" PATH="/usr/bin:/bin" \
      bash -c '
        mkdir -p "$TESTHOME"
        set -- --name t --gateway-port 1
        GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
        NO_SUDO=1
        PATH="$RUNPATH"
        rc=0; ( step1_preflight_no_sudo >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
        printf "RC=%s ERRTXT=%s" "$rc" "$(cat "$TESTHOME/err" 2>/dev/null | tr "\n" " ")"' 2>&1)"
    if printf '%s' "$got" | grep -qF 'curl is missing; --no-sudo'; then
        inj_bad "4. 拿掉檢查後 4a 仍綠——入口檢查沒被量到"
    else
        if printf '%s' "$got" | grep -qF 'could not determine'; then
            inj_ok "4. 拿掉檢查後死在 gh 下載深處（got [$got]）——4a 會紅"
        else
            inj_bad "4. 行為變了但不是預期的深死（got [$got]）——harness 問題"
        fi
    fi
fi

echo "=== 5. docker 真驗證（群組在、daemon 不通必須失敗） ==="
# 夾具：id 說有 docker 群組，docker info 說連不上 daemon。
got="$(TESTHOME="$SANDBOX/home5" RPSRC="$RP_STRIP" RUNPATH="$SANDBOX/rd0" DOCKER_INFO_RC=1 HOME="$SANDBOX/home5" PATH="/usr/bin:/bin" \
  bash -c '
    mkdir -p "$TESTHOME"
    set -- --name t --gateway-port 1
    GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
    NO_SUDO=1
    PATH="$RUNPATH"
    rc=0; ( step7_5_docker_group >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
    printf "RC=%s ERRTXT=%s" "$rc" "$(cat "$TESTHOME/err" 2>/dev/null | tr "\n" " ")"' 2>&1)"
if [[ "$got" == "RC=1 "* ]] && printf '%s' "$got" | grep -qF 'cannot talk to the docker daemon' \
&& printf '%s' "$got" | grep -qF 'usermod'; then
    ok "5a. 真驗證失敗（daemon 不通），指路 usermod"
else
    bad "5a. 不對（got [$got]）"
fi
# 對照：同夾具下 id -nG 版本會通過——正是被擋掉的那種謊言。
if PATH="$SANDBOX/rd0:/usr/bin:/bin" FAKE_GROUPS='staff docker everyone' \
    id -nG 2>/dev/null | grep -qw docker; then
    ok "5b. 同夾具 id -nG 照樣通過（謊言成立，真驗證才擋得住）"
else
    bad "5b. 對照組沒成立——夾具無效"
fi
# 注入 5：換成 id -nG grep docker → 群組在即放行，daemon 再不通也擋不住。
INJ5="$SANDBOX/rp-idgroup.sh"
python3 - "$REPO_ROOT/$RP" "$INJ5" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '    if docker info >/dev/null 2>&1; then'
assert src.count(old) == 1, "idgroup needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, '    if id -nG 2>/dev/null | grep -qw docker; then', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "5. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ5" 2>/dev/null; then
    inj_bad "5. 注入版語法錯誤——harness 問題"
else
    sed -e '$d' "$INJ5" > "$SANDBOX/rp-idgroup-src.sh"
    got="$(TESTHOME="$SANDBOX/home5i" RPSRC="$SANDBOX/rp-idgroup-src.sh" RUNPATH="$SANDBOX/rd0" DOCKER_INFO_RC=1 HOME="$SANDBOX/home5i" PATH="/usr/bin:/bin" \
      bash -c '
        mkdir -p "$TESTHOME"
        set -- --name t --gateway-port 1
        GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
        NO_SUDO=1
        PATH="$RUNPATH"
        rc=0; ( step7_5_docker_group >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
        printf "RC=%s OUTTXT=%s" "$rc" "$(cat "$TESTHOME/out" 2>/dev/null | tr "\n" " ")"' 2>&1)"
    if [[ "$got" == "RC=1 "* ]]; then
        inj_bad "5. 換成 id 群組後 5a 仍綠——真驗證沒被量到"
    else
        if [[ "$got" == "RC=0 "* ]]; then
            inj_ok "5. 換成 id 群組後 daemon 不通照樣放行（got [$got]）——5a 會紅"
        else
            inj_bad "5. 行為變了但不是預期的放行（got [$got]）——harness 問題"
        fi
    fi
fi

echo "=== 6. docker 真驗證 sudo 分支（真實登錄走的路） ==="
# no-sudo 分支（§5）只驗當前 session；sudo 分支先 usermod 再用
# sudo -u 新群組驗一次。qa 指出既有夾具有真 whoami、無 sudo stub，
# 測這條會打到真 sudo——所以 sudo 全 stub 化（記帳＋-u 分辨，
# -v 預設失敗，不隨 TTY 變卦）。
WHOAMI="$(whoami)"
# 6a：usermod 通＋新群組 docker info 通 → 過，指名 fresh groups，
#   且 argv 證明帶了 -u（不是 root 身分）。
got="$(TESTHOME="$SANDBOX/home6a" RPSRC="$RP_STRIP" RUNPATH="$SANDBOX/rd0" SUDO_N_TRUE_RC=0 SUDO_USERMOD_RC=0 SUDO_U_INFO_RC=0 SUDO_LOG="$SANDBOX/sudo6a.log" HOME="$SANDBOX/home6a" PATH="/usr/bin:/bin" \
  bash -c '
    mkdir -p "$TESTHOME"
    set -- --name t --gateway-port 1
    GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
    NO_SUDO=0
    PATH="$RUNPATH"
    : > "$SUDO_LOG"
    rc=0; ( step7_5_docker_group >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
    printf "RC=%s OUTTXT=%s ERRTXT=%s" "$rc" "$(cat "$TESTHOME/out" 2>/dev/null | tr "\n" " ")" "$(cat "$TESTHOME/err" 2>/dev/null | tr "\n" " ")"' 2>&1)"
if [[ "$got" == "RC=0 "* ]] && printf '%s' "$got" | grep -qF 'fresh groups' \
&& tr '\n' ' ' < "$SANDBOX/sudo6a.log" 2>/dev/null | grep -qF -- "-u ${WHOAMI} docker info"; then
    ok "6a. sudo 分支全通（新群組驗證帶 -u，非 root 身分）"
else
    bad "6a. 不對（got [$got]）"
fi
# 6b：usermod 通＋新群組 docker info 不通 → exit 1，說「群組已設、查 daemon」，
#   不可以叫人再跑一次 usermod（方向錯了也是缺陷）。
got="$(TESTHOME="$SANDBOX/home6b" RPSRC="$RP_STRIP" RUNPATH="$SANDBOX/rd0" SUDO_N_TRUE_RC=0 SUDO_USERMOD_RC=0 SUDO_U_INFO_RC=1 HOME="$SANDBOX/home6b" PATH="/usr/bin:/bin" \
  bash -c '
    mkdir -p "$TESTHOME"
    set -- --name t --gateway-port 1
    GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
    NO_SUDO=0
    PATH="$RUNPATH"
    rc=0; ( step7_5_docker_group >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
    printf "RC=%s ERRTXT=%s" "$rc" "$(cat "$TESTHOME/err" 2>/dev/null | tr "\n" " ")"' 2>&1)"
if [[ "$got" == "RC=1 "* ]] && printf '%s' "$got" | grep -qF 'still unreachable' \
&& printf '%s' "$got" | grep -qF 'membership is set' \
&& ! printf '%s' "$got" | grep -qF 'log back in'; then
    ok "6b. 新群組不通指去查 daemon（不叫人重跑 usermod）"
else
    bad "6b. 不對（got [$got]）"
fi
# 6c：usermod 本身失敗 → exit 1。
got="$(TESTHOME="$SANDBOX/home6c" RPSRC="$RP_STRIP" RUNPATH="$SANDBOX/rd0" SUDO_N_TRUE_RC=0 SUDO_USERMOD_RC=1 HOME="$SANDBOX/home6c" PATH="/usr/bin:/bin" \
  bash -c '
    mkdir -p "$TESTHOME"
    set -- --name t --gateway-port 1
    GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
    NO_SUDO=0
    PATH="$RUNPATH"
    rc=0; ( step7_5_docker_group >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
    printf "RC=%s ERRTXT=%s" "$rc" "$(cat "$TESTHOME/err" 2>/dev/null | tr "\n" " ")"' 2>&1)"
if [[ "$got" == "RC=1 "* ]] && printf '%s' "$got" | grep -qF 'could not add'; then
    ok "6c. usermod 失敗即 exit 1"
else
    bad "6c. 不對（got [$got]）"
fi
# 6d：ensure_sudo 不過 → exit 1 並指路。
got="$(TESTHOME="$SANDBOX/home6d" RPSRC="$RP_STRIP" RUNPATH="$SANDBOX/rd0" SUDO_N_TRUE_RC=1 HOME="$SANDBOX/home6d" PATH="/usr/bin:/bin" \
  bash -c '
    mkdir -p "$TESTHOME"
    set -- --name t --gateway-port 1
    GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
    NO_SUDO=0
    PATH="$RUNPATH"
    rc=0; ( step7_5_docker_group >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
    printf "RC=%s ERRTXT=%s" "$rc" "$(cat "$TESTHOME/err" 2>/dev/null | tr "\n" " ")"' 2>&1)"
if [[ "$got" == "RC=1 "* ]] && printf '%s' "$got" | grep -qF 'sudo needs a password'; then
    ok "6d. sudo 不可用即 exit 1 並指路"
else
    bad "6d. 不對（got [$got]）"
fi
# 注入 6：拿掉驗證的 -u "$who" → 以 root 跑 docker info。
#   夾具「該使用者連不上、root 連得上」：正確碼走 -u 必敗（RC=1），
#   突變版走 root 身分必過（RC=0）——退化完全隱形，輸出看不出來，
#   只有 argv 記帳（6a 的 -u 斷言）與本條能抓。
INJ6="$SANDBOX/rp-norootcheck.sh"
python3 - "$REPO_ROOT/$RP" "$INJ6" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '    if sudo -n -u "$who" docker info >/dev/null 2>&1; then'
assert src.count(old) == 1, "nou needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, '    if sudo -n docker info >/dev/null 2>&1; then', 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "6. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ6" 2>/dev/null; then
    inj_bad "6. 注入版語法錯誤——harness 問題"
else
    sed -e '$d' "$INJ6" > "$SANDBOX/rp-norootcheck-src.sh"
    got="$(TESTHOME="$SANDBOX/home6i" RPSRC="$SANDBOX/rp-norootcheck-src.sh" RUNPATH="$SANDBOX/rd0" SUDO_N_TRUE_RC=0 SUDO_USERMOD_RC=0 SUDO_U_INFO_RC=1 SUDO_ROOT_INFO_RC=0 HOME="$SANDBOX/home6i" PATH="/usr/bin:/bin" \
      bash -c '
        mkdir -p "$TESTHOME"
        set -- --name t --gateway-port 1
        GH_POOL_TOKEN=dummy HOME="$TESTHOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
        NO_SUDO=0
        PATH="$RUNPATH"
        rc=0; ( step7_5_docker_group >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
        printf "RC=%s OUTTXT=%s" "$rc" "$(cat "$TESTHOME/out" 2>/dev/null | tr "\n" " ")"' 2>&1)"
    if [[ "$got" == "RC=1 "* ]]; then
        inj_bad "6. 拿掉 -u 後 6a 仍綠——使用者身分沒被量到"
    else
        if [[ "$got" == "RC=0 "* ]]; then
            inj_ok "6. 拿掉 -u 後 root 身分放行（got [$got]）——6a 會紅"
        else
            inj_bad "6. 行為變了但不是預期的放行（got [$got]）——harness 問題"
        fi
    fi
fi


echo "=== 7. 金鑰已發布時重跑註冊：仍然成功、仍然派 refresh（issue #7 tasks 1.4）==="
# 為什麼要有這格：openspec D1 決定用**輸出變數**（TUNNEL_KEY_CHANGED）回報
# 「有沒有寫入」，**回傳碼照舊**。若改成用回傳碼區分，
# `tunnel_key_ensure_published ... || exit 1` 就會在「已經發布過」的機器上把整個
# 註冊打斷：一台已經有可用隧道身分的 provider，再註冊一次卻失敗。
# 而 register-provider 這條路**必須**無條件 dispatch：它是「剛建立」這條路上
# 唯一保證 Gateway 會授權新鑰的地方（pool-sync 只在有寫入時派，而這裡沒有寫入）。
# 所以這格把兩個後果一起釘住：exit 0、以及 dispatch 確實有發生。
#
# 手法：直接打 step6_5_tunnel_identity（它用 exit 結束，跑在子殼層）。
#
# **兩個必須避開的地雷（第一版都踩到了）**：
#   1. register-provider.sh:9 自己有 `STATE_DIR="${HOME}/.mylinuxpool"`。我的假 gh
#      一開始也用 STATE_DIR 當它的記帳目錄 → 被頂層初始化蓋掉，nonce 與 run 列表
#      寫到別處（或寫不進去），於是等待端永遠認不出自己那次，一路輪詢到
#      `dispatch_refresh_and_wait 300` 的 300 秒 deadline。**症狀是整支測試卡住，
#      不是紅燈**——那種失敗形狀最難查，所以這裡用自己的變數名 RP14_STATE。
#   2. register-provider.sh:22 有 `trap 'rm -rf "$REPO_DIR"' EXIT INT TERM`。
#      被測物結束時會**把我放進去的那份 lib 刪掉**，所以每次呼叫都要現做一份。
RP14_LIB_SRC="$SANDBOX/rp14-lib"
mkdir -p "$RP14_LIB_SRC/scripts/lib" "$SANDBOX/home14/.ssh"
cp -p "$REPO_ROOT/scripts/lib/tunnel-key.sh" "$RP14_LIB_SRC/scripts/lib/tunnel-key.sh"
cp -p "$REPO_ROOT/scripts/lib/refresh-wait.sh" "$RP14_LIB_SRC/scripts/lib/refresh-wait.sh"
# 本機的隧道金鑰（已存在 → 不會重產）
ssh-keygen -t ed25519 -N "" -C "mlp-tunnel-t" -f "$SANDBOX/home14/.ssh/id_tunnel" >/dev/null 2>&1
RP14_PUB="$(tr -d '\r\n' < "$SANDBOX/home14/.ssh/id_tunnel.pub" 2>/dev/null)"

RP14_STUB="$SANDBOX/rp14-stub"
mkdir -p "$RP14_STUB"
# **必須真的套用 --jq / --json**（照 test-refresh-attribution.sh 的形狀）：等待端把
# 「哪一筆是我們的」整個交給 gh 的 --jq。第一版直接 cat 原始 JSON，row 變成整份
# 陣列字串，同樣一路輪詢到 300 秒。
cat > "$RP14_STUB/gh" <<'FAKE_GH14'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "${RP14_LOG:-/dev/null}"
_fields=""; _filter=""; _prev=""
for a in "$@"; do
    [[ "$_prev" == "--json" ]] && _fields="$a"
    [[ "$_prev" == "--jq" ]] && _filter="$a"
    _prev="$a"
done
case "${1:-} ${2:-}" in
    "workflow run")
        for a in "$@"; do
            case "$a" in nonce=*) printf '%s' "${a#nonce=}" > "${RP14_STATE}/nonce" ;; esac
        done
        # 立刻放一筆「我們的 run」進列表：標題含本次 nonce（run-name 內插的形狀）、
        # completed/success —— 等待端因此第一次查詢就收工，不會碰到 300 秒 deadline。
        n="$(cat "${RP14_STATE}/nonce" 2>/dev/null)"
        printf '[{"databaseId":321,"status":"completed","conclusion":"success","displayTitle":"refresh-authorized-keys workflow_dispatch %s"}]' "$n" \
            > "${RP14_STATE}/runs.json"
        exit 0 ;;
    "run list")
        json="$(cat "${RP14_STATE}/runs.json" 2>/dev/null)"
        [[ -n "$_fields" && "$json" == \[* ]] && json="$(printf '%s' "$json" | jq -c "[.[] | {${_fields}}]")"
        if [[ -n "$_filter" ]]; then printf '%s' "$json" | jq -r "$_filter"
        else printf '%s\n' "$json"; fi
        exit 0 ;;
    "api repos/"*)
        # var 已經含 tunnel_public_key（＝「已經發布過」）
        printf '%s\n' "$RP14_VAR_JSON"; exit 0 ;;
esac
exit 0
FAKE_GH14
printf '#!/usr/bin/env bash\nexit 0\n' > "$RP14_STUB/sleep"
chmod +x "$RP14_STUB/gh" "$RP14_STUB/sleep"

# rp14_run <前綴> <var json> [被測的 register-provider 副本]
#   每號一次現做一份 REPO_DIR（陷阱會刪掉它），回 0 就代表沒踩到 300 秒 deadline。
rp14_run() {
    local pfx="$1" varjson="$2" src="${3:-$RP_STRIP}"
    local rd="$SANDBOX/$pfx-rd" st="$SANDBOX/$pfx-state"
    rm -rf "$rd" "$st"
    mkdir -p "$rd/scripts/lib" "$rd/stub" "$st" "$SANDBOX/home14"
    cp -p "$RP14_LIB_SRC/scripts/lib/tunnel-key.sh" "$rd/scripts/lib/tunnel-key.sh"
    cp -p "$RP14_LIB_SRC/scripts/lib/refresh-wait.sh" "$rd/scripts/lib/refresh-wait.sh"
    cp -p "$RP14_STUB/gh" "$RP14_STUB/sleep" "$rd/stub/"
    : > "$SANDBOX/$pfx-gh.log"
    # 有 timeout 保險：萬一又是 300 秒輪詢，這裡會得到 124 而不是讓整支測試卡住。
    timeout -k 5 60 env RP14_LOG="$SANDBOX/$pfx-gh.log" RP14_STATE="$st" \
        RP14_VAR_JSON="$varjson" RPSRC="$src" TESTHOME="$SANDBOX/home14" \
        HOME="$SANDBOX/home14" PATH="/usr/bin:/bin" \
      bash -c '
        set -- --name t --gateway-port 1
        GH_POOL_TOKEN=dummy HOME="$HOME" PATH="$PATH" source "$RPSRC" >/dev/null 2>&1
        NAME="t"; VAR_NAME="NODE_T"; REPO="testowner/testrepo"
        REPO_DIR="'"$rd"'"          # 必須在 source 之後設：頂層初始化會蓋掉環境變數
        PATH="'"$rd"'/stub:/usr/bin:/bin"
        rc=0; ( step6_5_tunnel_identity >"$TESTHOME/out" 2>"$TESTHOME/err" ) || rc=$?
        printf "RC=%s" "$rc"' 2>&1
}
rp14_dispatch() { grep -c 'workflow run' "$SANDBOX/$1-gh.log" 2>/dev/null || true; }

RP14_SAME="$(jq -c -n --arg pk "$RP14_PUB" '{name:"t",role:"provider",tunnel_public_key:$pk}')"
RP14_EMPTY="$(jq -c -n '{name:"t",role:"provider"}')"

if [[ -z "$RP14_PUB" ]]; then
    bad "7a. 金鑰已發布時重跑仍成功（前提不成立：產不出本機公鑰，ssh-keygen 不可用？）"
    bad "7b. 金鑰已發布時仍派 dispatch（前提不成立）"
    bad "7c. 對照組：var 沒有這把鑰（前提不成立）"
else
    got="$(rp14_run rp14same "$RP14_SAME")"
    if [[ "$got" == "RC=0" ]]; then
        ok "7a. 金鑰已經發布過時重跑註冊仍然成功（D1 的回傳碼語意沒變）"
    else
        bad "7a. 金鑰已發布就失敗（got [$got]）——回傳碼若被拿來表達「沒寫入」，這台機器永遠註冊不了第二次"
    fi
    if [[ "$(rp14_dispatch rp14same)" == "1" ]]; then
        ok "7b. 而且**仍然**派了一次 refresh（register-provider 不因「沒寫入」而跳過 dispatch）"
    else
        bad "7b. 金鑰已發布就沒有 dispatch（$(rp14_dispatch rp14same) 次）——新鑰不會被 Gateway 授權"
    fi
    # 7c. 對照組：var 裡沒有這把鑰（真的會寫入）時也要成功、也要 dispatch。
    #     它同時是 7b 的正對照——證明「派了 1 次」是量出來的，不是假 gh 沒接上。
    got="$(rp14_run rp14new "$RP14_EMPTY")"
    if [[ "$got" == "RC=0" ]] && [[ "$(rp14_dispatch rp14new)" == "1" ]] \
       && grep -q 'variable set' "$SANDBOX/rp14new-gh.log" 2>/dev/null; then
        ok "7c. 對照組：var 沒有這把鑰 → 有寫入、也派 1 次、rc 0（證明 7b 的計數會動）"
    else
        bad "7c. 對照組不對（got [$got]；dispatch $(rp14_dispatch rp14new) 次；gh.log [$(tr '\n' '|' < "$SANDBOX/rp14new-gh.log" 2>/dev/null)]）"
    fi
fi

# 7-inj. 把「無條件 dispatch」改成「只在 TUNNEL_KEY_CHANGED=1 時 dispatch」
#       ——那正是 issue #7 修 pool-sync 時很可能順手套到 register-provider 的改法。
#       7b 必須轉紅：證明 7b 量的真的是「有沒有派」這件事。
RP14_SRC2="$SANDBOX/rp14-src-changed.sh"
python3 - "$REPO_ROOT/$RP" "$RP14_SRC2" <<'PYI14'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '    GH_REPO="$REPO" dispatch_refresh_and_wait 300 || {'
new = ('    if [[ "${TUNNEL_KEY_CHANGED:-0}" != "1" ]]; then\n'
       '        return 0\n'
       '    fi\n'
       '    GH_REPO="$REPO" dispatch_refresh_and_wait 300 || {')
assert src.count(old) == 1, "dispatch needle count=%d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PYI14
if [[ $? -ne 0 ]]; then
    inj_bad "7-inj. 突變腳本失敗（register-provider 的 dispatch 呼叫點形狀變了）——harness 問題"
elif ! bash -n "$RP14_SRC2" 2>/dev/null; then
    inj_bad "7-inj. 突變版語法錯誤——harness 問題"
else
    sed -e '$d' "$RP14_SRC2" > "$SANDBOX/rp14-strip.sh"
    got="$(rp14_run rp14i "$RP14_SAME" "$SANDBOX/rp14-strip.sh")"
    n_disp="$(rp14_dispatch rp14i)"
    if [[ "$got" == "RC=0" && "$n_disp" == "0" ]]; then
        inj_ok "7-inj. 改成「只在有寫入時 dispatch」之後：rc 0 但 dispatch ${n_disp} 次——7b 會紅"
    else
        inj_bad "7-inj. 突變沒產生預期的形狀（rc [$got]、dispatch ${n_disp} 次）——harness 問題"
    fi
fi

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
