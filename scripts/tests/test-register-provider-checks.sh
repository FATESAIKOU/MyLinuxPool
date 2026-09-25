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
python3 - "$PCREPO/extra-pool-ssh.sh" <<'PY'
import sys
at, dl = '@', '$'
lines = [
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
if printf '%s' "$pc_out" | grep -q 'extra-pool-ssh.sh:6' \
&& printf '%s' "$pc_out" | grep -q 'step9_verify()'; then
    ok "1a. 全 repo 掃描抓到清單外的漏網（extra-pool-ssh.sh:6，歸屬 step9_verify）"
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
INJ1="$SANDBOX/preflight-8list.sh"
python3 - "$REPO_ROOT/$PREFLIGHT" "$INJ1" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
enum_pat = 'git ls-files | grep -E'
assert src.count(enum_pat) == 1, "orig enumeration count != 1"
old = ('shell_files=()\n'
       'while IFS= read -r f; do\n'
       '    shell_files+=("$f")\n'
       'done < <(git ls-files | grep -E %s)\n' % ("'\\.sh$|^ops-scripts/(mlp|verify-profile|preflight)$|/files/pool-'",))
new = ('shell_files=(scripts/rotate-gateway.sh scripts/create-worker.sh .github/actions/push-state/run.sh shared-configs/pool-runtime/files/pool-tunnel shared-configs/pool-runtime/files/pool-status ops-scripts/mlp ops-scripts/verify-profile scripts/lib/ssh.sh)\n')
assert src.count(old) == 1, "8list needle count != 1"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "1. 注入腳本失敗（被測物形狀變了）——harness 問題"
elif ! bash -n "$INJ1" 2>/dev/null; then
    inj_bad "1. 注入版語法錯誤——harness 問題"
elif [[ "$(grep -c 'git ls-files | grep -E' "$INJ1")" -ne 0 ]]; then
    inj_bad "1. 突變後還有列舉殘留（期望 0）——harness 問題"
else
    cp "$INJ1" "$PCREPO/ops-scripts/preflight"
    git -C "$PCREPO" add -A
    inj_out="$(bash "$PCREPO/ops-scripts/preflight" 2>&1)"
    cp -p "$REPO_ROOT/$PREFLIGHT" "$PCREPO/ops-scripts/preflight"
    if printf '%s' "$inj_out" | grep -q 'extra-pool-ssh.sh'; then
        inj_bad "1. 改回八檔清單後漏網仍被抓到——掃描範圍沒被量到"
    else
        if printf '%s' "$inj_out" | grep -q '都指定了埠'; then
            inj_ok "1. 改回八檔清單後漏網消失（回報乾淨）——1a 會紅"
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

echo
printf 'passed %d / failed %d / injection-fail %d\n' "$pass" "$fail" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
