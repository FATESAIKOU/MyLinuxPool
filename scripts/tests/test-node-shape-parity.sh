#!/usr/bin/env bash
# test-node-shape-parity.sh — register-provider.sh 與 register-repair-host
# 寫的 NODE_<NAME> 必須是同一個連線形狀（design D4；
# OUT-review-repair-t4.md §3、發現 4）。
#
# 為什麼要有：register-repair-host 的 build_node_json 自己承認「沒有共用函式
# 覆蓋兩邊——若改 hops 形狀，兩邊一起改」（見它的檔頭與 header D4 那段）。
# 那只是一句註解，沒有任何機制。兩份 NODE_* 的連線欄位
# （name/role/user/key_secret/gateway_port/hops）今天靠人記得同步；漂移的
# 症狀是執行期才出現（例如 hops 少一段 key_secret → 跳板認證在真機上失敗），
# 不會有任何 build 告訴你。review §3 用同一組輸入把兩邊的 jq 程式手動核對過
# 一次、結論是「相同」；這支測試把那次手動核對變成每次跑都驗的機械守衛。
#
# 兩邊怎麼餵同一組輸入：
#   * register-provider.sh：剝掉尾行 main 後 source（跟
#     test-capability-flags.sh 的 rp_source 手法一樣），直接呼叫
#     step5_register_var——不跑 main，不碰其餘 step（sudoers／systemd／
#     capabilities…）。self_user 由 $USER 決定，這裡設成跟 repair 的
#     profile.json 的 login_user（repair）一樣，才是「同一組輸入」。
#   * register-repair-host：procedural、沒有 main 可剝，直接跑真檔的完整
#     流程；假 gh 記錄它送出的 NODE_<NAME>。假 gh 的設計照
#     test-register-repair-host.sh。
#
# 比什麼：{name, role, user, key_secret, gateway_port, hops} 六個欄位必須
# 逐位元組相同。capabilities 刻意不比——register-provider 預設
# worker-host、repair-host 是 {}，那是 D6 的設計差異，不是漂移；§4 只確認
# 「差異長得是預期的樣子」，不當成 mismatch。
#
# 正對照（§3）：比對器不能只是「永遠回真」——人為改一個欄位，必須看得出差異。
#
# 注入（§5）：改 register-repair-host 的 hops 形狀（第二個 hop 拿掉
# key_secret，一個真實可能發生的「順手清掉一個看起來多餘的欄位」），用同一組
# 輸入重跑突變版，證明這支測試真的會因為 hops 漂移而變紅。
#
# 這支測試看不到什麼：
#   * 不驗 register-provider.sh 的其餘 step（sudoers／systemd／
#     capabilities／authorized_keys／pool-sync）——那些跟「NODE 形狀」無關，
#     其他測試已經覆蓋。
#   * 不驗 tunnel_public_key／registered_with 這兩個 repair-host 專有欄位
#     （spec 沒要求 register-provider 也有）。
#   * 全離線；不連 GitHub、不碰真機。
#
# 相容：bash 3.2（不用 ${var,,}、不用陣列的進階操作）。
#
# Run: scripts/tests/test-node-shape-parity.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

RP="ops-scripts/register-provider.sh"
RH="ops-scripts/register-repair-host"

for f in "$RP" "$RH"; do
    [[ -f "$f" ]] || { echo "ERROR: ${f} missing" >&2; exit 1; }
done
for tool in jq python3 ssh-keygen base64; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: ${tool} not found on PATH" >&2; exit 1; }
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-node-shape-parity.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
mkdir -p "$SHIMS" "$HOME_DIR" "$SANDBOX/rp"

pass=0; fail=0; injpass=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

TOOL_DIRS="$(dirname "$(command -v jq)"):$(dirname "$(command -v ssh-keygen)"):$(dirname "$(command -v base64)")"
SAME_NAME="fam-a"
SAME_PORT="2260"
SAME_USER="repair"

echo "=== 0. 先決條件與 harness ==="
# ---- register-provider.sh 載入器（同 test-capability-flags.sh 的手法） ------
cp -p "$REPO_ROOT/$RP" "$SANDBOX/rp/rp-full.sh"
sed -e '$d' "$SANDBOX/rp/rp-full.sh" > "$SANDBOX/rp/rp.sh"
if diff <(sed -e '$d' "$REPO_ROOT/$RP") "$SANDBOX/rp/rp.sh" >/dev/null 2>&1 \
&& tail -1 "$SANDBOX/rp/rp-full.sh" | grep -qx 'main' \
&& ! tail -1 "$SANDBOX/rp/rp.sh" | grep -qx 'main'; then
    ok "0a. 剝尾 main 的 register-provider.sh 副本與真檔只差一行（載入保真）"
else
    bad "0a. 剝尾 main 失敗——後面的比對全不可信"
fi
if grep -qE '^step5_register_var\(\)' "$RP"; then
    ok "0b. register-provider.sh 有 step5_register_var"
else
    bad "0b. register-provider.sh 沒有 step5_register_var——介面變了？"
fi
if grep -qE '^build_node_json\(\)' "$RH"; then
    ok "0c. register-repair-host 有 build_node_json"
else
    bad "0c. register-repair-host 沒有 build_node_json——介面變了？"
fi

# ---- 假 gh：兩邊都用得到（獨立複製一份，不共用 test-register-repair-host.sh 的檔）--
#   register-provider 的 step5：GET 單一 var（--jq .value），沒找到就 404；
#   variable set 記 stdin。
#   register-repair-host 的完整流程：分頁列出 actions/variables、variable set、
#   workflow run／run list／run view（refresh-wait.sh 的等待迴圈）。
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
if [[ ! -t 0 ]]; then cat > "${GH_STDIN:-/dev/null}"; fi
jqf="" prev=""
for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqf="$a"
    prev="$a"
done
_emit() {
    if [[ -n "$jqf" ]]; then printf '%s' "$1" | jq -r "$jqf"
    else printf '%s\n' "$1"; fi
}
_envelope() {
    jq -n --rawfile vars "${NODE_VARS_FILE:-/dev/null}" '
        {total_count: ($vars | split("\n") | map(select(length>0)) | length),
         variables: ($vars | split("\n") | map(select(length>0))
                     | map(. as $v | ($v | fromjson | .name | ascii_upcase | gsub("-"; "_")) as $n
                            | {name: ("NODE_" + $n), value: $v}))}'
}
case "${1:-}" in
  api)
    path=""
    for a in "$@"; do
        case "$a" in *actions/variables*) path="$a" ;; esac
    done
    case "$path" in
      *"/actions/variables")
          _emit "$(_envelope)" ;;
      *"/actions/variables/"*)
          nm="${path##*/}"
          hit="$(_envelope | jq -c --arg n "$nm" '[.variables[] | select(.name == $n)] | first // empty')"
          if [[ -z "$hit" ]]; then
              echo "gh: Not Found (HTTP 404)" >&2
              exit 1
          fi
          _emit "$hit" ;;
      *) printf '{}' ;;
    esac
    ;;
  variable)
    if [[ "${2:-}" == "set" ]]; then
        cp "${GH_STDIN:-/dev/null}" "${GH_SET_FILE:-/dev/null}" 2>/dev/null || true
    fi
    ;;
  workflow)
    if [[ "${2:-}" == "run" ]]; then
        printf 'DISPATCH %s\n' "$*" >> "${GH_LOG:-/dev/null}"
        printf '%s' "$*" > "${GH_DISPATCH_ARGS:-/dev/null}"
    fi
    ;;
  run)
    case "${2:-}" in
      list)
        _t=""
        [[ -f "${GH_DISPATCH_ARGS:-/nonexistent}" ]] \
            && _t="refresh-authorized-keys: $(cat "${GH_DISPATCH_ARGS}")"
        _emit "$(jq -c -n --arg t "$_t" \
            '[{databaseId:999,status:"completed",conclusion:"success",displayTitle:$t}]')" ;;
      view) _emit '{"status":"completed","conclusion":"success"}' ;;
    esac
    ;;
esac
exit 0
FAKE
chmod +x "$SHIMS/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIMS/sleep"
chmod +x "$SHIMS/sleep"

echo "=== 1. 兩邊各自成功寫出 NODE_<NAME>（同一組輸入） ==="
# ---- register-provider.sh：一個空 fixture（沒有 NODE_FAM_A）→ single-var GET
#      404 → existing_json='{}'，走「全新登錄」那條路。
: > "$SANDBOX/rp-vars.txt"
RP_SET="$SANDBOX/rp-set.json"
: > "$SANDBOX/rp-gh.log"; : > "$SANDBOX/rp-stdin.txt"; : > "$RP_SET"
RP_OUT="$(NODE_VARS_FILE="$SANDBOX/rp-vars.txt" GH_LOG="$SANDBOX/rp-gh.log" \
    GH_STDIN="$SANDBOX/rp-stdin.txt" GH_SET_FILE="$RP_SET" \
    USER="$SAME_USER" PATH="$SHIMS:$TOOL_DIRS:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME_DIR" \
    GH_POOL_TOKEN=dummy RPSRC="$SANDBOX/rp/rp.sh" \
    bash -c '
        set -- --name fam-a --gateway-port 2260
        source "$RPSRC" >/dev/null 2>&1
        step5_register_var
    ' </dev/null 2>&1)"
RP_RC=$?
if [[ "$RP_RC" -eq 0 && -s "$RP_SET" ]] && jq empty "$RP_SET" >/dev/null 2>&1; then
    ok "1a. register-provider.sh 的 step5_register_var 成功寫出 NODE_<NAME>"
else
    bad "1a. step5_register_var 失敗或沒寫出可解析的 JSON（rc=${RP_RC} out [${RP_OUT:0:200}]）"
fi

# ---- register-repair-host：真檔完整流程，真 ssh-keygen 產登入金鑰。
LOGIN_KEY="$SANDBOX/login_key"
ssh-keygen -t ed25519 -N "" -C "parity-test" -f "$LOGIN_KEY" >/dev/null 2>&1
NODE_OTHER='{"name":"other","role":"provider","gateway_port":2299,"capabilities":{}}'
printf '%s\n' "$NODE_OTHER" > "$SANDBOX/rh-vars.txt"
RH_OUTDIR="$SANDBOX/rh-boot"
mkdir -p "$RH_OUTDIR"
RH_SET="$SANDBOX/rh-set.json"
: > "$SANDBOX/rh-gh.log"; : > "$SANDBOX/rh-stdin.txt"; : > "$RH_SET"
RH_OUT="$(env -i \
    HOME="$HOME_DIR" \
    PATH="$SHIMS:$TOOL_DIRS:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_REPO="testowner/testrepo" \
    GH_LOG="$SANDBOX/rh-gh.log" \
    GH_STDIN="$SANDBOX/rh-stdin.txt" \
    GH_SET_FILE="$RH_SET" \
    GH_DISPATCH_ARGS="$SANDBOX/rh-dispatch-args" \
    NODE_VARS_FILE="$SANDBOX/rh-vars.txt" \
    POOL_REFRESH_POLL_INTERVAL=0 \
    TMPDIR="$SANDBOX" \
    bash "$REPO_ROOT/$RH" \
        --name "$SAME_NAME" --gateway-port "$SAME_PORT" \
        --login-key "$LOGIN_KEY.pub" --output-dir "$RH_OUTDIR" </dev/null 2>&1)"
RH_RC=$?
if [[ "$RH_RC" -eq 0 && -s "$RH_SET" ]] && jq empty "$RH_SET" >/dev/null 2>&1; then
    ok "1b. register-repair-host 成功寫出 NODE_<NAME>"
else
    bad "1b. register-repair-host 失敗或沒寫出可解析的 JSON（rc=${RH_RC} out [${RH_OUT:0:300}]）"
fi

echo "=== 2. 六個連線欄位必須逐位元組相同 ==="
SHAPE_JQ='{name, role, user, key_secret, gateway_port, hops}'
RP_SHAPE="$(jq -S -c "$SHAPE_JQ" "$RP_SET" 2>/dev/null)"
RH_SHAPE="$(jq -S -c "$SHAPE_JQ" "$RH_SET" 2>/dev/null)"
if [[ -n "$RP_SHAPE" && "$RP_SHAPE" == "$RH_SHAPE" ]]; then
    ok "2a. PARITY: {name,role,user,key_secret,gateway_port,hops} 相同（同一組輸入：name=${SAME_NAME} port=${SAME_PORT} user=${SAME_USER}）"
else
    bad "2a. 形狀不一致 —— register-provider [${RP_SHAPE:0:200}] register-repair-host [${RH_SHAPE:0:200}]"
fi

echo "=== 3. 正對照：比對器餵不同輸入時要能抓到差異 ==="
# 不改任何腳本——只把其中一份輸出的 name 換成別的字，證明「2a 說相同」不是
# 比對器本身壞掉、永遠回真。
DIFFERENT="$(printf '%s' "$RH_SHAPE" | jq -c '.name = "not-the-same"' 2>/dev/null)"
if [[ -n "$RP_SHAPE" && -n "$DIFFERENT" && "$RP_SHAPE" != "$DIFFERENT" ]]; then
    ok "3a. 正對照：人為改一個欄位後，比對器（字串相等）確實看得出差異"
else
    bad "3a. 正對照失敗：改了欄位比對器仍說相同——2a 的『相同』不可信"
fi

echo "=== 4. capabilities 刻意不同（D6 的設計，不是漂移）；不在 parity 範圍內 ==="
RP_CAP="$(jq -c '.capabilities' "$RP_SET" 2>/dev/null)"
RH_CAP="$(jq -c '.capabilities' "$RH_SET" 2>/dev/null)"
if [[ "$RP_CAP" == '{"worker-host":{"runtime":"docker"}}' && "$RH_CAP" == '{}' ]]; then
    ok "4a. capabilities 如預期不同（register-provider worker-host / repair-host {}）——D6 的設計差異，不是漏比對"
else
    bad "4a. capabilities 不是預期的形狀（register-provider [$RP_CAP] repair-host [$RH_CAP]）"
fi

echo "=== 5. 注入：hops 形狀漂移必須讓守衛變紅 ==="
# 把 register-repair-host 的第二個 hop 拿掉 key_secret（真實可能發生的
# hops 漂移：例如有人「順手」清掉一個看起來多餘的欄位），用同一組輸入重跑
# 突變版，證明這支測試真的會因為 hops 形狀不一致而紅——不是擺著好看的斷言。
# 突變版要能自己解析出 REPO_ROOT（register-repair-host 靠自身路徑
# SCRIPT_DIR/.. 找 profiles/、scripts/lib/），所以在沙盒裡搭一個最小的
# 「假 repo」骨架，只放它會讀到的那幾個檔案。
INJ_REPO="$SANDBOX/inj-repo"
mkdir -p "$INJ_REPO/ops-scripts" "$INJ_REPO/profiles/provider/repair" \
    "$INJ_REPO/scripts/lib" "$INJ_REPO/shared-configs/pool-runtime/files"
cp "$REPO_ROOT/profiles/provider/repair/profile.json" "$INJ_REPO/profiles/provider/repair/"
cp "$REPO_ROOT/profiles/provider/repair/user-data.tmpl" "$INJ_REPO/profiles/provider/repair/"
cp "$REPO_ROOT/scripts/lib/refresh-wait.sh" "$INJ_REPO/scripts/lib/"
cp "$REPO_ROOT/shared-configs/pool-runtime/files/tunnel-identity.sh" \
    "$INJ_REPO/shared-configs/pool-runtime/files/"
INJ_RH="$INJ_REPO/ops-scripts/register-repair-host"
python3 - "$REPO_ROOT/$RH" "$INJ_RH" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '''            hops: [{via: "gateway"},
                   {host: "127.0.0.1", port: $gateway_port, user: $user, key_secret: $key_secret}],
'''
new = '''            hops: [{via: "gateway"},
                   {host: "127.0.0.1", port: $gateway_port, user: $user}],
'''
assert src.count(old) == 1, "needle count != 1: %d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
if [[ $? -ne 0 ]]; then
    inj_bad "5. 注入腳本失敗（needle 落空）——harness 問題"
else
    chmod +x "$INJ_RH"
    if ! bash -n "$INJ_RH" 2>/dev/null; then
        inj_bad "5. 突變版語法錯——harness 問題"
    else
        INJ_OUTDIR="$SANDBOX/rh-inj-boot"
        mkdir -p "$INJ_OUTDIR"
        INJ_SET="$SANDBOX/rh-inj-set.json"
        : > "$SANDBOX/rh-inj-gh.log"; : > "$SANDBOX/rh-inj-stdin.txt"; : > "$INJ_SET"
        INJ_OUT="$(env -i \
            HOME="$HOME_DIR" \
            PATH="$SHIMS:$TOOL_DIRS:/usr/bin:/bin:/usr/sbin:/sbin" \
            GH_REPO="testowner/testrepo" \
            GH_LOG="$SANDBOX/rh-inj-gh.log" \
            GH_STDIN="$SANDBOX/rh-inj-stdin.txt" \
            GH_SET_FILE="$INJ_SET" \
            GH_DISPATCH_ARGS="$SANDBOX/rh-inj-dispatch-args" \
            NODE_VARS_FILE="$SANDBOX/rh-vars.txt" \
            POOL_REFRESH_POLL_INTERVAL=0 \
            TMPDIR="$SANDBOX" \
            bash "$INJ_RH" \
                --name "$SAME_NAME" --gateway-port "$SAME_PORT" \
                --login-key "$LOGIN_KEY.pub" --output-dir "$INJ_OUTDIR" </dev/null 2>&1)"
        INJ_RC=$?
        if [[ "$INJ_RC" -ne 0 || ! -s "$INJ_SET" ]] || ! jq empty "$INJ_SET" >/dev/null 2>&1; then
            inj_bad "5. 注入後的 register-repair-host 沒能正常跑完（rc=${INJ_RC} out [${INJ_OUT:0:300}]）——harness 問題"
        else
            INJ_SHAPE="$(jq -S -c "$SHAPE_JQ" "$INJ_SET" 2>/dev/null)"
            if [[ -n "$INJ_SHAPE" && "$INJ_SHAPE" != "$RP_SHAPE" ]]; then
                inj_ok "5. 拿掉第二個 hop 的 key_secret 後，形狀比對不再相同（register-repair-host [${INJ_SHAPE:0:200}]）——2a 會紅"
            else
                inj_bad "5. 拿掉 key_secret 後比對器仍說相同——注入沒生效或比對器看不見 hops 的變化"
            fi
        fi
    fi
fi

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' \
    "$pass" "$fail" "$injpass" "$injfail"
[[ "$fail" -ne 0 ]] && exit 1
[[ "$injfail" -ne 0 ]] && exit 2
exit 0
