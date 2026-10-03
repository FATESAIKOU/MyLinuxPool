#!/usr/bin/env bash
# scripts/lib/capability.sh — 共用 runner（D3）。判準只寫這一份，其他元件只呼叫。單位現場查 shared-configs/*/unit.json，不建快取。
# 三個函式：capability_plan <profile>（每行「鍵⇥單位⇥參數⇥0|1|2」，單位欄沒有就是「-」）／capability_check <鍵> <參數>（跑該單位 --check，原樣回傳 0/1/2，D2 三態）／capability_declaration <profile> <現有>（0 納入、1 不納入、2 保留現有值）。

# 找 repo 根：優先環境變數（測試沙箱用），否則從自己的路徑推。
capability_repo_root() {
    if [ -n "${MLP_REPO_ROOT:-}" ]; then printf '%s' "$MLP_REPO_ROOT"; return 0; fi
    if [ -n "${REPO_ROOT:-}" ]; then printf '%s' "$REPO_ROOT"; return 0; fi
    local here="${BASH_SOURCE[0]}"
    ( cd "$(dirname "$here")/../.." 2>/dev/null && pwd )
}

capability_unit_for() {
    local key="${1:-}" uj
    local root
    root="$(capability_repo_root)"
    for uj in "$root"/shared-configs/*/unit.json; do
        [ -f "$uj" ] || continue
        if [ "$(jq -r '.capability // empty' "$uj" 2>/dev/null)" = "$key" ]; then
            basename "$(dirname "$uj")"
            return 0
        fi
    done
    return 1
}

capability_check() {
    local key="${1:-}" params="${2:-{\}}"
    local root unit
    root="$(capability_repo_root)"
    if ! unit="$(capability_unit_for "$key")"; then        # 沒有單位實作這個鍵：無法確認，不是「不成立」。
        printf 'mlp: no unit implements capability %s\n' "$key" >&2
        return 2
    fi
    [[ -f "$root/shared-configs/$unit/install.sh" ]] || return 2
    MLP_CAPABILITY_PARAMS="$params" \
        bash "$root/shared-configs/$unit/install.sh" --check >/dev/null 2>&1
}

capability_plan() {
    local profile="${1:-}" root key params unit rc
    root="$(capability_repo_root)"
    [ -f "$profile" ] || return 2
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        params="$(jq -c --arg k "$key" '.capabilities[$k] // {}' "$profile" 2>/dev/null)"
        if unit="$(capability_unit_for "$key")"; then
            capability_check "$key" "$params" >/dev/null 2>&1
            rc="$?"
        else
            unit="-"   # sentinel：沒有單位實作這個鍵。消費端要靠它分辨，不要用空字串
            rc=2
        fi
        printf '%s\t%s\t%s\t%s\n' "$key" "$unit" "$params" "$rc"
    done < <(jq -r '(.capabilities // {}) | keys_unsorted[]' "$profile" 2>/dev/null)
    # 單位實作了、但沒有人宣告的鍵——漂移看得見，否則 pool-sync 會安裝一個
    # 沒有能力可驗的單位（或反過來，宣告了一個沒單位的鍵而沒人發現）。
    local ukey
    for ukey in $(capability_all_keys "$root"); do
        if jq -e --arg k "$ukey" '(.capabilities // {}) | has($k)' "$profile" >/dev/null 2>&1; then
            continue
        fi
        unit="$(capability_unit_for "$ukey")" || unit="-"
        printf '%s\t%s\t{}\t2\n' "$ukey" "$unit"
    done
}

capability_all_keys() {
    local root="${1:-}" uj k
    root="${root:-$(capability_repo_root)}"
    for uj in "$root"/shared-configs/*/unit.json; do
        [ -f "$uj" ] || continue
        k="$(jq -r '.capability // empty' "$uj" 2>/dev/null)"
        [ -n "$k" ] && printf '%s\n' "$k"
    done | sort -u
}

capability_declaration() {
    local profile="${1:-}" existing="${2:-{\}}"
    local root key params unit rc
    root="$(capability_repo_root)"
    [ -f "$profile" ] || return 2
    existing="${existing:-{\}}"
    jq -e . >/dev/null 2>&1 <<< "$existing" || existing='{}'

    # jq 讀空字串會沒有輸入、也沒有輸出，acc 會一直是空的——所以從 {} 起步。
    local acc='{}'
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        params="$(jq -c --arg k "$key" '.capabilities[$k] // {}' "$profile" 2>/dev/null)"
        if unit="$(capability_unit_for "$key")"; then
            capability_check "$key" "$params" >/dev/null 2>&1
            rc="$?"
        else
            rc=2
        fi
        # 每個鍵一行到 stderr：呼叫端要靠它分 WARN(1)／INFO(2)，而 pool-sync
        # 不該為了拿狀態再呼叫一次 capability_plan（那會把 --check 跑兩遍，
        # 兩次結果可能不一樣，API 也多打一倍）。
        printf 'capability %s: rc=%s\n' "$key" "$rc" >&2
        case "$rc" in
            0) acc="$(jq -c --arg k "$key" --argjson v "$params" '. + {($k): $v}' <<< "$acc")" ;;
            2) acc="$(jq -c --arg k "$key" --argjson e "$existing" \
                        'if ($e | has($k)) then . + {($k): $e[$k]} else . end' <<< "$acc")" ;;
            *) : ;;
        esac
    done < <(jq -r '(.capabilities // {}) | keys_unsorted[]' "$profile" 2>/dev/null)
    printf '%s\n' "$acc"
}

# CLI：bash capability.sh --check <鍵>　（參數與 repo 根走環境變數）
# 給需要換一個 process 來驗證的呼叫端用（register-provider 的 sudo -u）——
# 那種情況沒辦法 source，source 會把對方的 shell 也換掉。
if [[ "${1:-}" == "--check" && -n "${2:-}" ]]; then
    capability_check "$2" "${MLP_CAPABILITY_PARAMS:-{\}}"
    exit "$?"
fi
