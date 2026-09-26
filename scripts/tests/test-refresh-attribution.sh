#!/usr/bin/env bash
# test-refresh-attribution.sh — 為 refresh 的「認領自己那次 run」寫的行為測試
#
# 在防什麼（第三個歸屬實例）：
#   scripts/lib/refresh-wait.sh 的 dispatch_refresh_and_wait：
#   1. gh workflow run refresh-authorized-keys.yml 發動 dispatch
#   2. GitHub API 回 204，不回傳建立了哪次 run id
#   3. 它用 gh run list --limit 1 抓最新一筆，等它 completed 並讀取 conclusion
#   外部程序頻繁觸發 refresh（歷史兩天 294 次，384/384 成功）。
#   若最新一筆是別人的，函式驗的是別人的結果，最常見的後果是「假綠」：
#   自己那次失敗或還沒跑完，函式卻回傳 0。
#
# 行為測試設計（不綁定 impl 實作細節）：
#   - 假 gh workflow run：記下所有接收參數，並以 displayTitle 包含這些參數建立「我們的」run
#   - 假 gh run list / run view / api：回傳 arranged runs（含 databaseId、status、conclusion、displayTitle、createdAt）
#   - 正對照：驗證假 gh 確實攔截到 dispatch 與 run list 呼叫
#   - 情境 A：別人較新且 success，我們 failure → 預期回非 0（防假綠）
#   - 情境 B：別人較新且 failure，我們 success → 預期回 0（防誤報失敗）
#   - 情境 C：列表永無帶我們參數的那筆 → 預期回非 0 且訊息指出認不出，不得回報某一筆的結果
#
# 相容性：macOS bash 3.2 相容，中文字元前一律使用 ${var}。
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"
if [[ ! -f "${REPO_ROOT}/scripts/lib/refresh-wait.sh" ]]; then
    echo "ERROR: ${REPO_ROOT}/scripts/lib/refresh-wait.sh missing" >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || {
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-refresh-attr.XXXXXX")"
trap 'rm -rf "${SANDBOX}"' EXIT INT TERM
SHIMS="${SANDBOX}/shims"
STATE="${SANDBOX}/state"
mkdir -p "${SHIMS}" "${STATE}"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

# 假 sleep：立即結束，不浪費等待時間
printf '#!/usr/bin/env bash\nexit 0\n' > "${SHIMS}/sleep"
chmod +x "${SHIMS}/sleep"

# 假 gh：記錄命令列參數、支援 workflow run、run list、run view、api
cat > "${SHIMS}/gh" << 'FAKE_GH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"

_filter_json() {
    local json="$1"; shift
    local json_fields="" jq_filter="" limit="" prev=""
    for a in "$@"; do
        if [[ "${prev}" == "--json" ]]; then json_fields="$a"; fi
        if [[ "${prev}" == "--jq" ]]; then jq_filter="$a"; fi
        if [[ "${prev}" == "--limit" ]]; then limit="$a"; fi
        prev="$a"
    done
    if [[ -n "${limit}" && "${json}" =~ ^\[ ]]; then
        json="$(printf '%s' "${json}" | jq -c --argjson limit "${limit}" '.[0:$limit]')"
    fi
    if [[ -n "${jq_filter}" ]]; then
        printf '%s' "${json}" | jq -r "${jq_filter}"
    elif [[ -n "${json_fields}" ]]; then
        printf '%s' "${json}" | jq -c --arg fields "${json_fields}" '
            ($fields | split(",")) as $keys |
            def pick: with_entries(select(.key as $k | $keys | index($k)));
            if type == "array" then map(pick) else pick end
        '
    else
        printf '%s\n' "${json}"
    fi
}

cmd="${1:-}"
sub="${2:-}"

case "${cmd} ${sub}" in
  "workflow run")
    printf '.' >> "${FAKE_STATE}/dispatch.count"
    printf '%s\n' "$*" > "${FAKE_STATE}/last_dispatch_args"
    if [[ "${FAKE_DISPATCH_RC:-0}" -ne 0 ]]; then
        exit "${FAKE_DISPATCH_RC}"
    fi
    if [[ "${FAKE_CREATE_OUR_RUN:-1}" == "1" ]]; then
        jq -n \
          --argjson id "${OUR_RUN_ID:-100}" \
          --arg status "${OUR_STATUS:-completed}" \
          --arg conclusion "${OUR_CONCLUSION:-failure}" \
          --arg title "refresh-authorized-keys: $*" \
          --arg created "${OUR_CREATED_AT:-2026-09-26T12:00:00Z}" \
          '{databaseId: $id, status: $status, conclusion: $conclusion, displayTitle: $title, createdAt: $created}' \
          > "${FAKE_STATE}/our_run.json"
    fi
    exit 0
    ;;
  "run list")
    printf '.' >> "${FAKE_STATE}/run_list.count"
    others="[]"
    [[ -f "${FAKE_STATE}/other_runs.json" ]] && others="$(cat "${FAKE_STATE}/other_runs.json")"
    if [[ -f "${FAKE_STATE}/our_run.json" ]]; then
        runs="$(jq -n --argjson others "${others}" --slurpfile our "${FAKE_STATE}/our_run.json" \
          '($others + $our) | sort_by(.createdAt) | reverse')"
    else
        runs="${others}"
    fi
    shift 2
    _filter_json "${runs}" "$@"
    exit 0
    ;;
  "run view")
    printf '.' >> "${FAKE_STATE}/run_view.count"
    run_id="${3:-}"
    shift 3
    others="[]"
    [[ -f "${FAKE_STATE}/other_runs.json" ]] && others="$(cat "${FAKE_STATE}/other_runs.json")"
    if [[ -f "${FAKE_STATE}/our_run.json" ]]; then
        runs="$(jq -n --argjson others "${others}" --slurpfile our "${FAKE_STATE}/our_run.json" \
          '($others + $our)')"
    else
        runs="${others}"
    fi
    target="$(printf '%s' "${runs}" | jq -c --arg id "${run_id}" '.[] | select(.databaseId == ($id | tonumber))')"
    if [[ -z "${target}" ]]; then
        echo "run ${run_id} not found" >&2
        exit 1
    fi
    _filter_json "${target}" "$@"
    exit 0
    ;;
  api\ *)
    printf '.' >> "${FAKE_STATE}/api.count"
    others="[]"
    [[ -f "${FAKE_STATE}/other_runs.json" ]] && others="$(cat "${FAKE_STATE}/other_runs.json")"
    if [[ -f "${FAKE_STATE}/our_run.json" ]]; then
        runs="$(jq -n --argjson others "${others}" --slurpfile our "${FAKE_STATE}/our_run.json" \
          '($others + $our) | sort_by(.createdAt) | reverse')"
    else
        runs="${others}"
    fi
    envelope="$(printf '%s' "${runs}" | jq -c '{total_count: length, workflow_runs: .}')"
    shift 1
    _filter_json "${envelope}" "$@"
    exit 0
    ;;
  *)
    echo "unknown fake gh command: $*" >&2
    exit 1
    ;;
esac
FAKE_GH
chmod +x "${SHIMS}/gh"

run_dispatch() {
    local timeout_sec="${1:-5}"
    : > "${STATE}/dispatch.count"
    : > "${STATE}/run_list.count"
    : > "${STATE}/run_view.count"
    : > "${STATE}/api.count"
    : > "${SANDBOX}/gh-argv.log"
    : > "${SANDBOX}/sub.out"
    : > "${SANDBOX}/sub.err"
    : > "${SANDBOX}/sub.rc"

    PATH="${SHIMS}:${PATH}" FAKE_STATE="${STATE}" GH_LOG="${SANDBOX}/gh-argv.log" \
    GH_REPO="testowner/testrepo" POOL_REFRESH_POLL_INTERVAL=0 \
    OUR_RUN_ID="${OUR_RUN_ID:-100}" \
    OUR_STATUS="${OUR_STATUS:-completed}" \
    OUR_CONCLUSION="${OUR_CONCLUSION:-failure}" \
    OUR_CREATED_AT="${OUR_CREATED_AT:-2026-09-26T12:00:00Z}" \
    FAKE_CREATE_OUR_RUN="${FAKE_CREATE_OUR_RUN:-1}" \
    /bin/bash -c '
        source "'"${REPO_ROOT}"'/scripts/lib/log.sh"
        source "'"${REPO_ROOT}"'/scripts/lib/refresh-wait.sh"
        ( dispatch_refresh_and_wait "'"${timeout_sec}"'" >"'"${SANDBOX}"'/sub.out" 2>"'"${SANDBOX}"'/sub.err" )
        printf "%s" "$?" > "'"${SANDBOX}"'/sub.rc"
    ' </dev/null >/dev/null 2>&1
    SUB_RC="$(cat "${SANDBOX}/sub.rc" 2>/dev/null)"
    SUB_OUT="$(cat "${SANDBOX}/sub.out" 2>/dev/null)"
    SUB_ERR="$(cat "${SANDBOX}/sub.err" 2>/dev/null)"
    SUB_GOT="RC=${SUB_RC} OUT=[${SUB_OUT}] ERR=[${SUB_ERR}]"
}

echo "=== 0. 正對照（Positive Control）==="
# 基準執行：只有我們的 run（100, success），驗證假 gh 確實攔截並記錄呼叫
echo "[]" > "${STATE}/other_runs.json"
OUR_RUN_ID=100 OUR_STATUS=completed OUR_CONCLUSION=success FAKE_CREATE_OUR_RUN=1 run_dispatch 5

DISP_CNT="$(cat "${STATE}/dispatch.count" 2>/dev/null | wc -c | tr -d ' ')"
LIST_CNT="$(cat "${STATE}/run_list.count" 2>/dev/null | wc -c | tr -d ' ')"
VIEW_CNT="$(cat "${STATE}/run_view.count" 2>/dev/null | wc -c | tr -d ' ')"
API_CNT="$(cat "${STATE}/api.count" 2>/dev/null | wc -c | tr -d ' ')"
LAST_ARGS="$(cat "${STATE}/last_dispatch_args" 2>/dev/null)"

# 正對照只要求「有發動＋有用列表管道輪詢」；結論可來自 run view 或直接來自
# run list（--json conclusion），所以不強制 VIEW_CNT>0；列表管道可以是
# run list 或 api（gh api .../actions/runs，假 gh 兩者都有模擬）。
if [[ "${DISP_CNT}" -gt 0 ]] && [[ "${LIST_CNT}" -gt 0 || "${API_CNT}" -gt 0 ]] \
   && [[ "${LAST_ARGS}" == *"refresh-authorized-keys.yml"* ]]; then
    ok "0a. 正對照：假 gh 確實攔截 workflow run(${DISP_CNT})、列表(${LIST_CNT} list/${API_CNT} api)、run view(${VIEW_CNT})"
else
    bad "0a. 正對照失敗：假 gh 未接上（disp=${DISP_CNT}, list=${LIST_CNT}, api=${API_CNT}, view=${VIEW_CNT}）"
fi

if [[ "${SUB_RC}" == "0" ]] && [[ "${SUB_OUT}" == *"refresh workflow 100 succeeded"* ]]; then
    ok "0b. 基準線（單筆正常情境）：只有我們的 run 且 success 時回 0（回歸保護）"
else
    bad "0b. 基準線失敗：單筆正常情況未成功（got [${SUB_GOT}]）"
fi

echo "=== 1. 情境 A：別人的 run 比較新、success；我們的 failure（假綠缺陷）==="
# 安排：別人 200（12:01, success），我們 100（12:00, failure）
cat > "${STATE}/other_runs.json" << 'JSON'
[
  {
    "databaseId": 200,
    "status": "completed",
    "conclusion": "success",
    "displayTitle": "refresh authorized keys (external)",
    "createdAt": "2026-09-26T12:01:00Z"
  }
]
JSON
OUR_RUN_ID=100 OUR_STATUS=completed OUR_CONCLUSION=failure FAKE_CREATE_OUR_RUN=1 run_dispatch 5
if [[ "${SUB_RC}" != "0" ]]; then
    ok "1. 情境 A：回非 0（正確識別出自己那次 failure，未被別人的 success 遮蔽）"
else
    bad "1. 情境 A（假綠）：預期回非 0，但目前回 0 且認領別人的 200（got [${SUB_GOT}]）"
fi

echo "=== 2. 情境 B：別人的 run 比較新、failure；我們的 success（誤報失敗）==="
# 安排：別人 200（12:01, failure），我們 100（12:00, success）
cat > "${STATE}/other_runs.json" << 'JSON'
[
  {
    "databaseId": 200,
    "status": "completed",
    "conclusion": "failure",
    "displayTitle": "refresh authorized keys (external)",
    "createdAt": "2026-09-26T12:01:00Z"
  }
]
JSON
OUR_RUN_ID=100 OUR_STATUS=completed OUR_CONCLUSION=success FAKE_CREATE_OUR_RUN=1 run_dispatch 5
if [[ "${SUB_RC}" == "0" ]]; then
    ok "2. 情境 B：回 0（正確識別出自己那次 success，未被別人的 failure 誤判）"
else
    bad "2. 情境 B（誤報失敗）：預期回 0，但目前回 ${SUB_RC} 且回報別人的 200（got [${SUB_GOT}]）"
fi

echo "=== 3. 情境 C：列表永無帶我們參數的那筆（認不出歸屬）==="
# 安排：列表中只有別人的 run（201, success），我們那次未出現在列表中
cat > "${STATE}/other_runs.json" << 'JSON'
[
  {
    "databaseId": 201,
    "status": "completed",
    "conclusion": "success",
    "displayTitle": "refresh authorized keys (manual UI dispatch)",
    "createdAt": "2026-09-26T12:01:00Z"
  }
]
JSON
rm -f "${STATE}/our_run.json"
FAKE_CREATE_OUR_RUN=0 run_dispatch 5

# 預期：回非 0，訊息指出認不出，且不可回報 201 的結果
if [[ "${SUB_RC}" != "0" ]] \
   && ! printf '%s' "${SUB_GOT}" | grep -qF 'refresh workflow 201' \
   && printf '%s' "${SUB_GOT}" | grep -qiE 'cannot tell|could not be identified|unknown|unrecognized|認不出|找不到'; then
    ok "3. 情境 C：回非 0 且明確表示認不出（未退回猜測或誤報他人 run 結果）"
else
    bad "3. 情境 C（認不出）：預期回非 0 且訊息宣告認不出，但目前回 ${SUB_RC} 且回報 201（got [${SUB_GOT}]）"
fi

echo
printf 'passed %d / failed %d\n' "${pass}" "${fail}"
if [[ "${fail}" -ne 0 ]]; then
    exit "${fail}"
fi
exit 0
