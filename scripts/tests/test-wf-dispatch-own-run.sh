#!/usr/bin/env bash
# test-wf-dispatch-own-run.sh — `wf_dispatch` 要認得出**自己那一次** run（不綁做法）。
#
# 在防什麼：
#   `wf_dispatch`（ops-scripts/mlp）dispatch create／delete／rotate 之後要跟那次
#   run。現在的碼靠 before/after 差集推歸屬；它自己的註解承認「窗內恰好一筆」
#   是必要不是充分——別人的 run 先落進窗、我們的還沒出現時，差集也是一筆，
#   而那筆不是我們的。rotate 是破壞性的：跟錯人 = 報錯結論。
#
# 不綁做法（D2b 兩條候選路線，使用者尚未裁示）：
#   A. nonce：workflow 加選填輸入＋`run-name:`，呼叫端產生 nonce、比對 displayTitle
#   B. run id：`gh workflow run`（v2.87+，送 return_run_details）在 stdout 印出
#      run 的 html_url，呼叫端直接取 id；拿不到才退回
#   所以假 gh 兩種契約都給：
#   - `gh workflow run`：「新版」模式 stdout 印一行
#     `https://github.com/<owner>/<repo>/actions/runs/<id>`，「舊版」模式什麼都不印。
#     長相照 cli/cli v2.101.0 pkg/cmd/workflow/run/run.go:369-391（非 TTY 分支
#     只 Fprintln(HtmlURL)）與 run_test.go:536（wantOut
#     "https://github.com/OWNER/REPO/actions/runs/6789\n"）、:541（204 → 空）。
#     wf_dispatch 捕 stdout 時不是 TTY，所以只模擬非 TTY 那一種。
#   - `gh run list`：run 帶 displayTitle。「args」模式下，我們那次的標題是
#     `<workflow 檔名去 .yml> <每個 -f/-F 的值，依序>`（模擬 run-name 已生效、
#     把 dispatch 傳進去的值內插進去）；「plain」模式下只是 workflow 的 name。
#   - 外部 run（同一支 workflow、同樣的使用者參數、**不同或空的關聯值**）可以
#     排在 dispatch 之後第幾次「看」才出現，比我們早、同時、或晚。
#   要求「認到自己」的情境一律同時打開兩個頻道（新版＋args），所以 A 只靠標題、
#   B 只靠 stdout 都能綠；關掉其中一個頻道的情境（6）只要求「不認錯」，
#   兩個都關（3）要求「說不知道」。
#
# 時鐘：假 gh 的時鐘＝「第一次 dispatch 之後，run list／run view 被呼叫的次數」
#   （跨呼叫端共用）。run 在時鐘 >= appear 時出現在 list，>= done 時 completed。
#   用呼叫次數而不是 sleep 次數，是為了不綁「先 sleep 再看」或「先看再 sleep」。
#
# 結束碼約定（照 wf_dispatch 現在的檔頭）：0＝我們那次成功；1＝dispatch 失敗或
#   我們那次失敗；3＝dispatch 已送出但認不出是哪一次（「不知道」，不可折成 0 或 1）。
#
# 情境：
#   1. 外部同名 run 在我們 dispatch 後先出現並成功；我們的晚到且失敗 → rc 1、不跟外部那筆
#      1b. 反過來（外部失敗、我們成功）→ rc 0
#   2. 兩個呼叫端幾乎同時 dispatch（第二個的 run 先出現）→ 各自認到自己
#   3. 兩個頻道都關（舊版＋plain）：外部先出、我們後出 → rc 3、說認不出、不跟任何一筆
#      3b. 同上但窗裡只多出我們那一筆 → 仍 rc 3（「恰好一筆」不是證據，不猜）
#   4. 正常路徑：rc 0、印出我們的 run URL、只 dispatch 一次、-f 參數原樣轉給 gh
#      4b. 我們失敗 → rc 1；4c. dispatch 被拒 → rc 1；4d. 我們跑得久（先 in_progress）→ 等到完才下結論
#   5. 外部 run 比我們新（id 較大）且與我們同一輪出現 → 不認「最新那筆」
#      5b. 外部 run 在我們之後才出現、先完成 → 仍等我們那筆
#   6. 只剩一個頻道（新版＋plain、舊版＋args），情境 1 的時間線 → 可以說不知道，但不准跟外部那筆
#
# 正對照：
#   0a–0c 直接呼叫假 gh，證明兩種契約與外部 run 真的會被吐出來；
#   1 之後的（資訊）列出被測物 dispatch 後呼叫 run list 幾次、外部 run 在幾次回應裡；
#   I1–I5 用「已知錯的」最小實作（覆寫 wf_dispatch）跑同一批判定，必須被判紅——
#   證明綠不是因為假 gh 沒吐資料、也不是因為判定寫鬆了。
#
# 全離線：gh／sleep 走 PATH stub。mlp 以「剝掉尾端 standalone main」的副本
# source，放在沙盒裡一棵 symlink 回 repo `scripts/` 的樹下，讓 mlp 的
# `source ${REPO_ROOT}/scripts/lib/ssh.sh` 仍然成立。
# bash 3.2 相容（測試本體不用陣列、不用 ${var,,}、無 mapfile）。
#
# Run: scripts/tests/test-wf-dispatch-own-run.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

MLP="ops-scripts/mlp"

if [[ ! -f "$MLP" ]]; then
    echo "test-wf-dispatch-own-run: ${MLP} is missing; every case below will FAIL" >&2
fi
for tool in jq python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found on PATH" >&2; exit 1; }
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-wf-own-run.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
STATE="$SANDBOX/state"
TREE="$SANDBOX/tree"
mkdir -p "$SHIMS" "$HOME_DIR" "$TREE/ops-scripts"
ln -s "$REPO_ROOT/scripts" "$TREE/scripts"

# 一次呼叫最多跑幾秒（假 sleep 是 no-op，正常情況一秒內結束；卡住＝判定失敗，
# 不讓整支測試掛死）。
WD_SECS="${WD_SECS:-20}"

pass=0; fail=0; injpass=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }
info() { printf '  (資訊) %s\n' "$1"; }

# ---- 假 gh -----------------------------------------------------------------
# 狀態檔（$FAKE_STATE）：
#   mode      new|legacy        workflow run 印不印 run URL
#   title     args|plain        我們那次的 displayTitle 帶不帶 dispatch 的值
#   dispatch_rc                 非 0 → dispatch 被拒
#   barrier   N                 workflow run 回來前，等到總 dispatch 數 >= N
#   wfname                      workflow 的 name（plain 標題、name 欄位）
#   ext       id appear done conclusion title     既有／外部 run（appear -1＝一直都在）
#   slots     seq id appear done conclusion       第 seq 次 dispatch 會建出的 run
#   bound     seq id appear done conclusion title caller   已 dispatch 的
#   log       caller clock verb detail
cat > "$SHIMS/gh" <<'FAKE'
#!/usr/bin/env bash
S="${FAKE_STATE:?}"
CALLER="${FAKE_CALLER:-A}"
TAB="$(printf '\t')"
LOCKED=0
lock() {
    local n=0
    until mkdir "$S/lock" 2>/dev/null; do
        n=$((n+1))
        if [ "$n" -gt 3000 ]; then echo "fake gh: lock stuck" >&2; exit 97; fi
        /bin/sleep 0.01
    done
    LOCKED=1
}
unlock() { if [ "$LOCKED" = 1 ]; then rmdir "$S/lock" 2>/dev/null; LOCKED=0; fi; }
trap unlock EXIT
logl() { printf '%s\t%s\t%s\n' "$CALLER" "$(cat "$S/clock")" "$*" >> "$S/log"; }
# tick：第一次 dispatch 之後的每一次「看」推進時鐘一格。呼叫端要持有鎖。
tick() {
    local c d
    c="$(cat "$S/clock")"; d="$(cat "$S/dispatches")"
    if [ "$d" -ge 1 ]; then c=$((c+1)); printf '%s' "$c" > "$S/clock"; fi
    printf '%s' "$c"
}
# emit <json> <fields> <jq> <is_array>：照真 gh 的順序——先 --json 投影，再 --jq（raw）。
emit() {
    local json="$1" fields="$2" filter="$3" arr="$4"
    if [ -n "$fields" ]; then
        if [ "$arr" = 1 ]; then json="$(printf '%s' "$json" | jq -c "[.[] | {${fields}}]")"
        else json="$(printf '%s' "$json" | jq -c "{${fields}}")"; fi
    fi
    if [ -n "$filter" ]; then printf '%s' "$json" | jq -r "$filter"
    else printf '%s\n' "$json"; fi
}
REPO_ARG="OWNER/REPO"; JSONF=""; JQF=""; LIMIT=20; WF=""
parse_common() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo|-R) REPO_ARG="${2:-}"; shift 2 ;;
            --repo=*) REPO_ARG="${1#--repo=}"; shift ;;
            --json) JSONF="${2:-}"; shift 2 ;;
            --json=*) JSONF="${1#--json=}"; shift ;;
            --jq|-q) JQF="${2:-}"; shift 2 ;;
            --jq=*) JQF="${1#--jq=}"; shift ;;
            --limit|-L) LIMIT="${2:-20}"; shift 2 ;;
            --limit=*) LIMIT="${1#--limit=}"; shift ;;
            --workflow|-w) WF="${2:-}"; shift 2 ;;
            --workflow=*) WF="${1#--workflow=}"; shift ;;
            *) shift ;;
        esac
    done
}
# status_of <clock> <appear> <done> <conclusion> → "status<TAB>conclusion"
status_of() {
    if [ "$1" -ge "$3" ]; then printf 'completed\t%s' "$4"
    elif [ "$1" -ge "$2" ]; then printf 'in_progress\t'
    else printf 'queued\t'; fi
}
v1="${1:-}"; v2="${2:-}"
shift 2 2>/dev/null || shift $#
case "$v1 $v2" in
  "workflow run")
    wf="${1:-}"; [ $# -gt 0 ] && shift
    values=""; argv="$*"
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo|-R) REPO_ARG="${2:-}"; shift 2 ;;
            --repo=*) REPO_ARG="${1#--repo=}"; shift ;;
            -f|-F|--raw-field|--field) values="${values} ${2#*=}"; shift 2 ;;
            --raw-field=*|--field=*) kv="${1#*=}"; values="${values} ${kv#*=}"; shift ;;
            -r|--ref) shift 2 ;;
            *) shift ;;
        esac
    done
    lock
    if [ "$(cat "$S/dispatch_rc")" != "0" ]; then
        logl "DISPATCH-REJECTED ${wf} ${argv}"
        unlock
        echo "could not create workflow dispatch event: HTTP 500 (fake)" >&2
        exit 1
    fi
    seq=$(( $(cat "$S/dispatches") + 1 ))
    line="$(awk -F'\t' -v s="$seq" '$1==s {print; exit}' "$S/slots")"
    if [ -n "$line" ]; then
        id="$(printf '%s' "$line" | cut -f2)"; appear="$(printf '%s' "$line" | cut -f3)"
        done_at="$(printf '%s' "$line" | cut -f4)"; concl="$(printf '%s' "$line" | cut -f5)"
    else
        id=$((9900+seq)); appear=999999; done_at=999999; concl=""
        logl "EXTRA-DISPATCH seq=${seq}"
    fi
    if [ "$(cat "$S/title")" = "args" ]; then title="${wf%.yml}${values}"
    else title="$(cat "$S/wfname")"; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$seq" "$id" "$appear" "$done_at" "$concl" "$title" "$CALLER" >> "$S/bound"
    printf '%s' "$seq" > "$S/dispatches"
    logl "DISPATCH seq=${seq} id=${id} ${wf} ${argv}"
    unlock
    b="$(cat "$S/barrier" 2>/dev/null || echo 0)"
    if [ "$b" -gt 0 ]; then
        n=0
        while [ "$(cat "$S/dispatches")" -lt "$b" ] && [ "$n" -lt 500 ]; do /bin/sleep 0.01; n=$((n+1)); done
    fi
    if [ "$(cat "$S/mode")" = "new" ]; then
        printf 'https://github.com/%s/actions/runs/%s\n' "$REPO_ARG" "$id"
    fi
    exit 0 ;;
  "run list")
    parse_common "$@"
    if [ -z "$JSONF" ]; then echo "fake gh: run list without --json is not modelled" >&2; exit 64; fi
    lock
    c="$(tick)"
    rows="$S/rows.$$"; : > "$rows"
    while IFS="$TAB" read -r id appear done_at concl title; do
        [ -n "$id" ] || continue
        [ "$c" -ge "$appear" ] || continue
        printf '%s\t%s\t%s\n' "$id" "$(status_of "$c" "$appear" "$done_at" "$concl")" "$title" >> "$rows"
    done < "$S/ext"
    while IFS="$TAB" read -r _seq id appear done_at concl title _caller; do
        [ -n "$id" ] || continue
        [ "$c" -ge "$appear" ] || continue
        printf '%s\t%s\t%s\n' "$id" "$(status_of "$c" "$appear" "$done_at" "$concl")" "$title" >> "$rows"
    done < "$S/bound"
    json="$(jq -Rsc --arg repo "$REPO_ARG" --arg wfn "$(cat "$S/wfname")" --argjson lim "$LIMIT" '
        split("\n") | map(select(length > 0) | split("\t")
          | {databaseId: (.[0] | tonumber), status: .[1], conclusion: .[2],
             displayTitle: .[3], name: $wfn, workflowName: $wfn,
             event: "workflow_dispatch", headBranch: "master",
             createdAt: ("2026-09-27T01:00:00Z"),
             url: ("https://github.com/" + $repo + "/actions/runs/" + .[0])})
        | sort_by(-.databaseId) | .[:$lim]' < "$rows")"
    rm -f "$rows"
    logl "LIST wf=${WF} served=$(printf '%s' "$json" | jq -r '[.[].databaseId] | map(tostring) | join(",")')"
    unlock
    emit "$json" "$JSONF" "$JQF" 1
    exit 0 ;;
  "run view")
    rid="${1:-}"; [ $# -gt 0 ] && shift
    parse_common "$@"
    lock
    c="$(tick)"
    found=""
    while IFS="$TAB" read -r id appear done_at concl title; do
        if [ "$id" = "$rid" ] && [ "$c" -ge "$appear" ]; then found="${appear}${TAB}${done_at}${TAB}${concl}${TAB}${title}"; break; fi
    done < "$S/ext"
    if [ -z "$found" ]; then
        while IFS="$TAB" read -r _seq id appear done_at concl title _caller; do
            # 我們 dispatch 出來的 run 一建立就查得到（API 已回 id），只是還在 queued。
            if [ "$id" = "$rid" ]; then found="${appear}${TAB}${done_at}${TAB}${concl}${TAB}${title}"; break; fi
        done < "$S/bound"
    fi
    if [ -z "$found" ]; then
        logl "VIEW-MISS ${rid}"; unlock
        echo "could not find any workflow run with ID ${rid}" >&2
        exit 1
    fi
    appear="$(printf '%s' "$found" | cut -f1)"; done_at="$(printf '%s' "$found" | cut -f2)"
    concl="$(printf '%s' "$found" | cut -f3)"; title="$(printf '%s' "$found" | cut -f4)"
    sc="$(status_of "$c" "$appear" "$done_at" "$concl")"
    st="$(printf '%s' "$sc" | cut -f1)"; cc="$(printf '%s' "$sc" | cut -f2)"
    logl "VIEW ${rid} ${st}"
    unlock
    json="$(jq -nc --arg id "$rid" --arg st "$st" --arg cc "$cc" --arg t "$title" --arg repo "$REPO_ARG" '
        {databaseId: ($id | tonumber), status: $st, conclusion: $cc, displayTitle: $t,
         url: ("https://github.com/" + $repo + "/actions/runs/" + $id),
         jobs: [{name: "job", steps: [{number: 1, name: ("step of run " + $id), status: $st, conclusion: $cc}]}]}')"
    emit "$json" "$JSONF" "$JQF" 0
    exit 0 ;;
esac
lock; logl "UNSUPPORTED ${v1} ${v2} $*"; unlock
echo "fake gh: '${v1} ${v2}' is not modelled by this test" >&2
exit 64
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIMS/sleep"
chmod +x "$SHIMS/gh" "$SHIMS/sleep"

# ---- 被測物：剝掉尾端 standalone main 的 mlp 副本 ---------------------------
python3 - "$REPO_ROOT/$MLP" "$TREE/ops-scripts/mlp-lib.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
out = re.sub(
    r'\nif \[\[ "\$\{BASH_SOURCE\[0\]\}" == "\$\{0\}" \]\]; then\n    main "\$@"\nfi\n?\Z',
    '\n', src)
assert 'main "$@"' not in out, "standalone main call not stripped"
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
LIB="$TREE/ops-scripts/mlp-lib.sh"

# ---- 夾具 -------------------------------------------------------------------
WF="delete-worker.yml"
WFNAME="Delete Worker"
ARGVAL="mlp-w1"                  # 我們（和外部同名 run）傳的使用者參數
SAME="delete-worker ${ARGVAL}"   # 外部同名 run 的標題前綴（run-name 已生效時）

# reset <mode> <title>
reset() {
    rm -rf "$STATE"; mkdir -p "$STATE"
    printf '%s' "$1" > "$STATE/mode"
    printf '%s' "$2" > "$STATE/title"
    printf '0' > "$STATE/dispatch_rc"
    printf '0' > "$STATE/barrier"
    printf '0' > "$STATE/clock"
    printf '0' > "$STATE/dispatches"
    printf '%s' "$WFNAME" > "$STATE/wfname"
    : > "$STATE/ext"; : > "$STATE/slots"; : > "$STATE/bound"; : > "$STATE/log"
    # 每個情境都有的背景：早就完成的同名 run 與一筆 UI 發動的 run。
    add_ext 100 -1 -1 success "${SAME} "
    add_ext 101 -1 -1 success "$WFNAME"
}
# add_ext <id> <appear> <done> <conclusion> <title>
add_ext() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$STATE/ext"; }
# add_ours <seq> <id> <appear> <done> <conclusion>
add_ours() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$STATE/slots"; }

# start_one <lib> <caller>：背景跑 wf_dispatch。rc 由子程序自己的 EXIT trap
# 寫進 $SANDBOX/<caller>.rc（die 走 exit 也收得到），pid 記在 <caller>.pid。
start_one() {
    local lib="$1" who="$2"
    : > "$SANDBOX/$who.out"; : > "$SANDBOX/$who.err"; rm -f "$SANDBOX/$who.rc"
    LIB_UNDER_TEST="$lib" FAKE_STATE="$STATE" FAKE_CALLER="$who" \
    PATH="$SHIMS:$PATH" HOME="$HOME_DIR" POOL_REPO=testowner/testrepo \
    OUT="$SANDBOX/$who.out" ERR="$SANDBOX/$who.err" RCF="$SANDBOX/$who.rc" \
    WF="$WF" ARGVAL="$ARGVAL" \
    bash -c '
        source "$LIB_UNDER_TEST" >/dev/null 2>&1
        trap '\''printf "%s" "$?" > "$RCF"'\'' EXIT
        REPO=testowner/testrepo
        wf_dispatch "$WF" "delete-worker (${ARGVAL})" -f name="$ARGVAL" >"$OUT" 2>"$ERR"
    ' </dev/null >/dev/null 2>&1 &
    printf '%s' "$!" > "$SANDBOX/$who.pid"
}
# wait_callers <caller>...：等到每個呼叫端都寫出 rc；超過 WD_SECS 就 kill -9
# 還沒寫的，rc 記 TIMEOUT（卡住＝判定失敗，不讓整支測試掛死）。
wait_callers() {
    local t=0 missing w
    while :; do
        missing=0
        for w in "$@"; do [ -s "$SANDBOX/$w.rc" ] || missing=1; done
        [ "$missing" -eq 0 ] && break
        if [ "$t" -ge $((WD_SECS * 20)) ]; then
            for w in "$@"; do
                if [ ! -s "$SANDBOX/$w.rc" ]; then
                    kill -9 "$(cat "$SANDBOX/$w.pid")" 2>/dev/null
                    printf 'TIMEOUT' > "$SANDBOX/$w.rc"
                fi
            done
            break
        fi
        /bin/sleep 0.05; t=$((t+1))
    done
    for w in "$@"; do wait "$(cat "$SANDBOX/$w.pid")" 2>/dev/null; done
    return 0
}
# run_wf <lib>：單一呼叫端（A）。
run_wf() {
    start_one "$1" A
    wait_callers A
}

# 讀結果
rc_of()    { cat "$SANDBOX/$1.rc" 2>/dev/null; }
out_of()   { cat "$SANDBOX/$1.out" "$SANDBOX/$1.err" 2>/dev/null; }
views_of() { awk -F'\t' -v w="$1" '$1==w && $3 ~ /^VIEW / {split($3,a," "); print a[2]}' "$STATE/log" | sort -u | tr '\n' ' '; }
viewed()   { awk -F'\t' -v w="$1" -v id="$2" '$1==w && $3 ~ ("^VIEW " id " ") {f=1} END {exit !f}' "$STATE/log"; }
said()     { out_of "$1" | grep -qF "$2"; }
dispatch_count() { awk -F'\t' -v w="$1" '$1==w && $3 ~ /^DISPATCH / {n++} END {print n+0}' "$STATE/log"; }
lists_after_dispatch() { awk -F'\t' -v w="$1" '$1==w && $2>0 && $3 ~ /^LIST / {n++} END {print n+0}' "$STATE/log"; }
lists_serving() { awk -F'\t' -v w="$1" -v id="$2" '$1==w && $3 ~ /^LIST / && ("," $3 ",") ~ ("[=,]" id ",") {n++} END {print n+0}' "$STATE/log"; }
# 「認不出」的說法（不綁措辭，只要求它說出來）。
said_unknown() { out_of "$1" | grep -qiE "(cannot|can't|could not|couldn't|unable to)( be)? (tell|identif|single)"; }
got_of() {
    printf 'RC=%s VIEWS=[%s] DISPATCHES=%s OUT=[%s]' "$(rc_of "$1")" "$(views_of "$1")" \
        "$(dispatch_count "$1")" "$(out_of "$1" | tr '\n' '|' | head -c 400)"
}

# ---- 判定（每條都回 0/1，訊息放在 $WHY；被測物與「已知錯的實作」共用） ------------
# 一個判定＝一個情境：安排夾具、跑、判。

s1_timeline() {  # $1 mode $2 title $3 ext-conclusion $4 our-conclusion
    reset "$1" "$2"
    add_ext 205 1 1 "$3" "${SAME} "     # 外部同名 run：dispatch 後第一次看就在、已完成
    add_ours 1 206 3 3 "$4"             # 我們的：第三次看才出現
}
check_s1() {
    s1_timeline new args success failure; run_wf "$1"
    WHY="$(got_of A)"
    [ "$(rc_of A)" = 1 ] && ! viewed A 205 && said A "actions/runs/206"
}
check_s1b() {
    s1_timeline new args failure success; run_wf "$1"
    WHY="$(got_of A)"
    [ "$(rc_of A)" = 0 ] && ! viewed A 205 && said A "actions/runs/206"
}
check_s2() {
    reset new args
    printf '2' > "$STATE/barrier"
    add_ours 1 301 5 5 success    # 先 dispatch 的那個：run 晚出現、成功
    add_ours 2 302 2 2 failure    # 後 dispatch 的那個：run 先出現、失敗
    local c1 c2 okc=1
    start_one "$1" X; start_one "$1" Y
    wait_callers X Y
    c1="$(awk -F'\t' '$1==1 {print $7}' "$STATE/bound")"
    c2="$(awk -F'\t' '$1==2 {print $7}' "$STATE/bound")"
    WHY="seq1=${c1:-?}(301,success) seq2=${c2:-?}(302,failure) | X: $(got_of X) | Y: $(got_of Y)"
    [ -n "$c1" ] && [ -n "$c2" ] && [ "$c1" != "$c2" ] || return 1
    [ "$(rc_of "$c1")" = 0 ] && said "$c1" "actions/runs/301" && ! viewed "$c1" 302 || okc=0
    [ "$(rc_of "$c2")" = 1 ] && said "$c2" "actions/runs/302" && ! viewed "$c2" 301 || okc=0
    [ "$(dispatch_count X)" = 1 ] && [ "$(dispatch_count Y)" = 1 ] || okc=0
    [ "$okc" = 1 ]
}
check_s3() {
    reset legacy plain
    add_ext 405 1 1 success "$WFNAME"   # 外部（UI 發動）先出現
    add_ours 1 406 3 3 success          # 我們的後出現；標題不帶我們的值
    run_wf "$1"
    WHY="$(got_of A)"
    [ "$(rc_of A)" = 3 ] && [ -z "$(views_of A | tr -d ' ')" ] && said_unknown A && ! said A "run finished"
}
check_s3b() {
    reset legacy plain
    add_ours 1 406 1 1 success          # 窗裡只多出這一筆（剛好是我們的，但沒有任何證據）
    run_wf "$1"
    WHY="$(got_of A)"
    [ "$(rc_of A)" = 3 ] && [ -z "$(views_of A | tr -d ' ')" ] && said_unknown A
}
check_s4() {
    reset new args
    add_ours 1 506 1 1 success
    run_wf "$1"
    WHY="$(got_of A) | dispatch argv: $(awk -F'\t' '$3 ~ /^DISPATCH / {print $3}' "$STATE/log" | head -n 1)"
    [ "$(rc_of A)" = 0 ] && said A "actions/runs/506" && [ "$(dispatch_count A)" = 1 ] \
      && awk -F'\t' '$3 ~ /^DISPATCH / {print $3}' "$STATE/log" | grep -qE -- "(-f|-F|--raw-field|--field)[ =]name=${ARGVAL}( |\$)" \
      && { local v; v="$(views_of A | tr -d ' ')"; [ -z "$v" ] || [ "$v" = 506 ]; }
}
check_s4b() {
    reset new args
    add_ours 1 506 1 1 failure
    run_wf "$1"
    WHY="$(got_of A)"
    [ "$(rc_of A)" = 1 ] && said A "actions/runs/506" && ! said A "run finished: success"
}
check_s4c() {
    reset new args
    printf '1' > "$STATE/dispatch_rc"
    add_ours 1 506 1 1 success
    run_wf "$1"
    WHY="$(got_of A)"
    [ "$(rc_of A)" = 1 ] && [ -z "$(views_of A | tr -d ' ')" ] && ! said A "run finished"
}
check_s4d() {
    reset new args
    add_ours 1 506 1 9 failure         # 出現後一直 in_progress，第 9 次看才 completed
    run_wf "$1"
    WHY="$(got_of A)"
    [ "$(rc_of A)" = 1 ] && said A "actions/runs/506"
}
check_s5() {
    reset new args
    add_ours 1 606 1 1 failure
    add_ext 607 1 1 success "${SAME} 4f1c2a9e0b7d3e55"   # 別人（帶自己的關聯值）、比我們新、同一輪出現
    run_wf "$1"
    WHY="$(got_of A)"
    [ "$(rc_of A)" = 1 ] && ! viewed A 607 && said A "actions/runs/606"
}
check_s5b() {
    reset new args
    add_ours 1 606 1 8 failure                     # 我們先出現但跑得久
    add_ext 607 2 2 success "${SAME} "              # 外部晚出現、先完成
    run_wf "$1"
    WHY="$(got_of A)"
    [ "$(rc_of A)" = 1 ] && ! viewed A 607 && said A "actions/runs/606"
}
check_s6() {  # $2 mode $3 title
    s1_timeline "$2" "$3" success failure; run_wf "$1"
    WHY="$(got_of A)"
    ! viewed A 205 || return 1
    case "$(rc_of A)" in
        3) said_unknown A ;;
        1) said A "actions/runs/206" ;;
        *) return 1 ;;
    esac
}

# ---- 0. 先決條件與正對照（直接打假 gh） --------------------------------------
echo "=== 0. 先決條件與正對照 ==="
if [[ -f "$LIB" ]] && ! grep -q 'main "\$@"' "$LIB" && grep -q '^wf_dispatch() {' "$LIB"; then
    ok "0. 剝尾 standalone main 的 mlp 副本可 source，wf_dispatch 在"
else
    bad "0. mlp 副本沒做好或 wf_dispatch 不存在——後面所有斷言都不可信"
fi

fgh() { FAKE_STATE="$STATE" FAKE_CALLER=probe PATH="$SHIMS:$PATH" gh "$@"; }
reset new args; add_ours 1 701 1 1 success
o="$(fgh workflow run "$WF" --repo testowner/testrepo -f name="$ARGVAL" 2>&1)"; r=$?
if [[ "$r" -eq 0 && "$o" == "https://github.com/testowner/testrepo/actions/runs/701" ]]; then
    ok "0a. 假 gh 新版模式：workflow run 的 stdout 恰好一行 run URL（照 cli/cli run_test.go:536 的長相）"
else
    bad "0a. 假 gh 新版模式輸出不對（rc=${r} got [${o}]）"
fi
reset legacy args; add_ours 1 701 1 1 success
o="$(fgh workflow run "$WF" --repo testowner/testrepo -f name="$ARGVAL" 2>&1)"; r=$?
if [[ "$r" -eq 0 && -z "$o" ]]; then
    ok "0b. 假 gh 舊版模式：workflow run 成功但 stdout 空（照 run_test.go:541 的 204 案例）"
else
    bad "0b. 假 gh 舊版模式輸出不對（rc=${r} got [${o}]）"
fi
# 0c：外部 run 真的會被吐出來——dispatch 前看不到、dispatch 後照排程出現，
#     標題帶同樣的使用者參數；--json 投影與 --jq 照真 gh 的順序套用。
s1_timeline new args success failure
o0="$(fgh run list --workflow="$WF" --repo testowner/testrepo --limit 30 --json databaseId --jq '.[].databaseId' | tr '\n' ' ')"
fgh workflow run "$WF" --repo testowner/testrepo -f name="$ARGVAL" -f dispatch_id=abc123 >/dev/null
o1="$(fgh run list --workflow="$WF" --repo testowner/testrepo --limit 30 --json databaseId,displayTitle,status,conclusion)"
fgh run list --workflow="$WF" --repo testowner/testrepo --json databaseId >/dev/null
o3="$(fgh run list --workflow="$WF" --repo testowner/testrepo --limit 30 --json databaseId,displayTitle --jq '.[] | select(.displayTitle | contains("abc123")) | .databaseId')"
t205="$(printf '%s' "$o1" | jq -r '.[] | select(.databaseId==205) | .displayTitle + "|" + .status + "|" + .conclusion')"
keys="$(printf '%s' "$o1" | jq -r '.[0] | keys | join(",")')"
if [[ "$o0" == "101 100 " && "$t205" == "${SAME} |completed|success" \
   && "$o3" == "206" && "$keys" == "conclusion,databaseId,displayTitle,status" ]]; then
    ok "0c. 外部 run 205 dispatch 前不在、之後照排程出現（標題 [${SAME} ]、completed/success）；我們的 206 在第 3 次看時以 [delete-worker ${ARGVAL} abc123] 出現；--json 只回要的欄位"
else
    bad "0c. 假 gh 的 run list 排程或投影不對（before=[${o0}] 205=[${t205}] match=[${o3}] keys=[${keys}]）"
fi

# ---- 1–6. 被測物 ---------------------------------------------------------------
echo "=== 1. 外部同名 run 先出現並成功完成 → 不能拿它當自己的 ==="
if check_s1 "$LIB"; then ok "1. rc 1（我們那次失敗）、沒有 follow 外部 205、印出 actions/runs/206"
else bad "1. 認錯人或結論不是我們那次的（got [${WHY}]）"; fi
n_l="$(lists_after_dispatch A)"; n_s="$(lists_serving A 205)"
if [[ "$n_l" -gt 0 ]]; then
    if [[ "$n_s" -gt 0 ]]; then
        info "被測物 dispatch 後呼叫 run list ${n_l} 次，其中 ${n_s} 次的回應含外部 205——外部 run 確實送到它眼前"
    else
        bad "1-pc. 被測物有看 run list（${n_l} 次）卻從沒拿到 205——假 gh 的排程沒生效，1 的綠不可信"
    fi
else
    info "被測物 dispatch 後沒有呼叫 run list（run id 路線的形狀）；外部 run 的可見性由 0c 與 I1–I3 證明"
fi
if check_s1b "$LIB"; then ok "1b. 反過來（外部失敗、我們成功）：rc 0、沒有 follow 205"
else bad "1b. 外部的失敗被算到我們頭上（got [${WHY}]）"; fi

echo "=== 2. 兩個呼叫端幾乎同時 dispatch → 各自認到自己 ==="
if check_s2 "$LIB"; then ok "2. 先 dispatch 的認到 301（rc 0）、後 dispatch 的認到 302（rc 1），各只 dispatch 一次、互不 follow"
else bad "2. 兩個呼叫端沒有各自認到自己（got [${WHY}]）"; fi

echo "=== 3. 認不出（新版輸出關、標題不含我們的值）→ rc 3、說認不出、不猜 ==="
if check_s3 "$LIB"; then ok "3. rc 3、輸出說認不出、零 run view、沒有 'run finished'"
else bad "3. 認不出時猜了或折疊了（got [${WHY}]）"; fi
if check_s3b "$LIB"; then ok "3b. 窗裡只多出一筆也不認（恰好一筆不是證據）：rc 3、零 run view"
else bad "3b. 沒有任何歸屬證據卻認領了唯一那筆（got [${WHY}]）"; fi

echo "=== 4. 正常路徑與結束碼約定 ==="
if check_s4 "$LIB"; then ok "4. rc 0、印出 actions/runs/506、只 dispatch 一次、-f name=${ARGVAL} 原樣轉給 gh、只 follow 506"
else bad "4. 正常路徑壞了（got [${WHY}]）"; fi
if check_s4b "$LIB"; then ok "4b. 我們那次失敗：rc 1、印出 506"
else bad "4b. 我們那次失敗時的結論不對（got [${WHY}]）"; fi
if check_s4c "$LIB"; then ok "4c. dispatch 被拒：rc 1、零 run view"
else bad "4c. dispatch 被拒時的處理不對（got [${WHY}]）"; fi
if check_s4d "$LIB"; then ok "4d. 我們的 run 先 in_progress 很久：等到 completed 才下結論（rc 1）"
else bad "4d. 沒等到我們那次完成就下結論（got [${WHY}]）"; fi

echo "=== 5. 外部 run 比我們新、或在我們之後才出現 → 不認最新那筆 ==="
if check_s5 "$LIB"; then ok "5. 外部 607 比我們新且同輪出現：rc 1、沒有 follow 607"
else bad "5. 認了最新那筆或沒認出自己（got [${WHY}]）"; fi
if check_s5b "$LIB"; then ok "5b. 外部 607 晚出現、先完成：仍等我們的 606（rc 1）"
else bad "5b. 被晚到先完成的外部 run 帶走（got [${WHY}]）"; fi

echo "=== 6. 只剩一個頻道 → 可以說不知道，但不准跟外部那筆 ==="
if check_s6 "$LIB" new plain; then ok "6a. 新版輸出＋標題不帶值：rc ∈ {1 且印 206, 3 且說認不出}、沒有 follow 205（got rc $(rc_of A)）"
else bad "6a. 只有 stdout 頻道時認錯或折疊（got [${WHY}]）"; fi
if check_s6 "$LIB" legacy args; then ok "6b. 舊版輸出＋標題帶值：rc ∈ {1 且印 206, 3 且說認不出}、沒有 follow 205（got rc $(rc_of A)）"
else bad "6b. 只有標題頻道時認錯或折疊（got [${WHY}]）"; fi

# ---- I. 注入：已知錯的最小實作必須被判紅 ------------------------------------
# 每個 mutant ＝ mlp 副本＋尾端覆寫 wf_dispatch。覆寫版自帶 follow（不依賴
# mlp 內部函式名），所以 mlp 之後怎麼改都不影響這些對照。
echo "=== I. 注入：已知錯的實作，判定必須轉紅 ==="
FOLLOW_SNIPPET='
_naive_follow() {
    local id="$1" j st
    echo "  https://github.com/${REPO}/actions/runs/${id}"
    while :; do
        j="$(gh run view "$id" --repo "$REPO" --json status,conclusion 2>/dev/null)" || continue
        st="$(printf "%s" "$j" | jq -r .status)"
        if [ "$st" = completed ]; then
            [ "$(printf "%s" "$j" | jq -r .conclusion)" = success ] && { echo "run finished: success"; return 0; }
            echo "run finished: failure"; return 1
        fi
    done
}'
mk_mutant() {  # mk_mutant <name> <wf_dispatch body>
    { cat "$LIB"; printf '%s\n' "$FOLLOW_SNIPPET"; printf '%s\n' "$2"; } > "$TREE/ops-scripts/mutant-$1.sh"
    bash -n "$TREE/ops-scripts/mutant-$1.sh" 2>/dev/null && printf '%s' "$TREE/ops-scripts/mutant-$1.sh"
}
# I1：舊形狀——dispatch 後認第一筆與 baseline 不同的 run（最新那筆）。
M1="$(mk_mutant first-new '
wf_dispatch() {
    local wf="$1"; shift 2
    local before after id i
    before="$(gh run list --workflow="$wf" --repo "$REPO" --limit 30 --json databaseId --jq ".[].databaseId")"
    gh workflow run "$wf" --repo "$REPO" "$@" >/dev/null 2>&1 || return 1
    for i in $(seq 1 20); do
        after="$(gh run list --workflow="$wf" --repo "$REPO" --limit 30 --json databaseId --jq ".[].databaseId")"
        id="$(comm -13 <(printf "%s\n" "$before" | sort) <(printf "%s\n" "$after" | sort) | sort -rn | head -n 1)"
        [ -n "$id" ] && { _naive_follow "$id"; return $?; }
    done
    return 1
}')"
# I2：A 路線做錯——標題只比對使用者參數，沒有專屬的關聯值。
M2="$(mk_mutant title-args-only '
wf_dispatch() {
    local wf="$1"; shift 2
    local id i vals="" a
    for a in "$@"; do case "$a" in *=*) vals="${vals} ${a#*=}" ;; esac; done
    gh workflow run "$wf" --repo "$REPO" "$@" >/dev/null 2>&1 || return 1
    for i in $(seq 1 20); do
        # 取標題含使用者參數、且比背景 run（100/101）新的最新一筆
        id="$(gh run list --workflow="$wf" --repo "$REPO" --limit 30 --json databaseId,displayTitle \
              --jq ".[] | select(.displayTitle | contains(\"${vals# }\")) | .databaseId" | awk "\$1 > 101" | head -n 1)"
        [ -n "$id" ] && { _naive_follow "$id"; return $?; }
    done
    echo "cannot tell which run is ours"; return 3
}')"
# I3：B 路線做錯——stdout 沒有 URL 時退回差集猜（OUT-d2b-routes §2 的 (c)）。
M3="$(mk_mutant runid-diff-fallback '
wf_dispatch() {
    local wf="$1"; shift 2
    local out id before after i
    before="$(gh run list --workflow="$wf" --repo "$REPO" --limit 30 --json databaseId --jq ".[].databaseId")"
    out="$(gh workflow run "$wf" --repo "$REPO" "$@" 2>/dev/null)" || return 1
    id="$(printf "%s\n" "$out" | sed -n "s#.*/actions/runs/\([0-9][0-9]*\)\$#\1#p" | head -n 1)"
    [ -n "$id" ] && { _naive_follow "$id"; return $?; }
    for i in $(seq 1 20); do
        after="$(gh run list --workflow="$wf" --repo "$REPO" --limit 30 --json databaseId --jq ".[].databaseId")"
        id="$(comm -13 <(printf "%s\n" "$before" | sort) <(printf "%s\n" "$after" | sort) | head -n 1)"
        [ -n "$id" ] && { _naive_follow "$id"; return $?; }
    done
    return 1
}')"
# I4：B 路線做對了認領，但把「不知道」折成「失敗」（rc 3 → 1）。
M4="$(mk_mutant fold-unknown '
wf_dispatch() {
    local wf="$1"; shift 2
    local out id
    out="$(gh workflow run "$wf" --repo "$REPO" "$@" 2>/dev/null)" || return 1
    id="$(printf "%s\n" "$out" | sed -n "s#.*/actions/runs/\([0-9][0-9]*\)\$#\1#p" | head -n 1)"
    [ -n "$id" ] && { _naive_follow "$id"; return $?; }
    echo "cannot tell which run is ours"; return 1
}')"
# I5：B 路線做對了認領，但不等 completed（第一次看就用當下的 conclusion 下結論）。
M5="$(mk_mutant no-wait '
wf_dispatch() {
    local wf="$1"; shift 2
    local out id c
    out="$(gh workflow run "$wf" --repo "$REPO" "$@" 2>/dev/null)" || return 1
    id="$(printf "%s\n" "$out" | sed -n "s#.*/actions/runs/\([0-9][0-9]*\)\$#\1#p" | head -n 1)"
    [ -n "$id" ] || { echo "cannot tell which run is ours"; return 3; }
    echo "  https://github.com/${REPO}/actions/runs/${id}"
    c="$(gh run view "$id" --repo "$REPO" --json conclusion --jq .conclusion)"
    [ "$c" = failure ] && return 1
    return 0
}')"

# expect_red <label> <mutant> <check> [args]：mutant 必須讓 check 失敗。
expect_red() {
    local label="$1" m="$2" chk="$3"; shift 3
    if [[ -z "$m" ]]; then inj_bad "${label}：mutant 沒建出來（語法錯）——harness 問題"; return; fi
    if "$chk" "$m" "$@"; then
        inj_bad "${label}：已知錯的實作竟然過了 ${chk}——判定太鬆（got [${WHY}]）"
    else
        inj_ok "${label}：${chk} 轉紅（got [$(printf '%s' "$WHY" | head -c 220)]）"
    fi
}
expect_red "I1a 認第一筆新 run" "$M1" check_s1
n_s="$(lists_serving A 205)"
if [[ "$n_s" -gt 0 ]] && viewed A 205; then
    inj_ok "I1-pc 同一夾具下，會看 run list 的實作拿到了 205（${n_s} 次）並 follow 了它——外部 run 看得見、也騙得倒人"
else
    inj_bad "I1-pc 外部 205 沒被送到或沒騙倒 I1（served ${n_s}）——1 的綠可能只是假 gh 沒吐資料"
fi
expect_red "I1b 認第一筆新 run（兩個呼叫端）" "$M1" check_s2
expect_red "I1c 認最新那筆" "$M1" check_s5
expect_red "I2 標題只比對使用者參數" "$M2" check_s1
expect_red "I3a stdout 沒 URL 就退回差集" "$M3" check_s3
expect_red "I3b stdout 沒 URL 就退回差集（恰好一筆）" "$M3" check_s3b
expect_red "I3c stdout 沒 URL 就退回差集（只剩標題頻道）" "$M3" check_s6 legacy args
expect_red "I4 不知道折成失敗" "$M4" check_s3
expect_red "I5 不等 completed" "$M5" check_s4d
# 反向對照：I4／I5 在它們沒做錯的地方要綠——證明判定不是對任何非 mlp 的實作都紅。
if check_s1 "$M4"; then inj_ok "I4-neg 同一個 mutant 在情境 1（新版＋args）綠——判定只抓它做錯的那件事"
else inj_bad "I4-neg I4 在情境 1 也紅（got [${WHY}]）——判定可能綁了 mlp 的措辭或內部"; fi
if check_s4 "$M5"; then inj_ok "I5-neg 同一個 mutant 在情境 4 綠（run 一出現就 completed 時不等也對）"
else inj_bad "I5-neg I5 在情境 4 也紅（got [${WHY}]）——判定可能綁了 mlp 的措辭或內部"; fi

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' "$pass" "$fail" "$injpass" "$injfail"
if [[ "$fail" -ne 0 ]]; then exit 1; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
