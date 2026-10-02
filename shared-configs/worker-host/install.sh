#!/usr/bin/env bash
# shared-configs/worker-host/install.sh — docs/LAYOUT.md §1
#
# 這個單位不安裝任何檔案（沒有 files/）。它存在是為了帶著 worker-host 能力的
# 判準：--check 的回傳碼是「能力成立嗎」，不是「檔案齊全嗎」（D2）。
#
# 兩個 why：
# 1. 不 sudo -u——sudo 會重置 PATH，而 PATH 是 docker 從哪裡來的線索。
# 2. 「新鮮群組」必須由呼叫端保證：usermod 之後當前 session 的群組不會更新，
#    所以 register-provider 要用 sudo -n -u <user> 包住本單位（D8）。

set -uo pipefail

log() {
    local level="$1"; shift
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$level" == "INFO" ]]; then
        printf '[%s] %s %s\n' "$ts" "$level" "$*"
    else
        printf '[%s] %s %s\n' "$ts" "$level" "$*" >&2
    fi
}

usage() {
    echo "usage: install.sh [--key <FILE_CRYPTO_KEY>] [--home <dir>] [--user <name>] [--check]" >&2
}

KEY=""
HOME_DIR="${HOME}"
TARGET_USER="$(whoami)"
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) [[ $# -ge 2 ]] || { usage; exit 2; }; KEY="$2"; shift 2 ;;
        --home) [[ $# -ge 2 ]] || { usage; exit 2; }; HOME_DIR="$2"; shift 2 ;;
        --user) [[ $# -ge 2 ]] || { usage; exit 2; }; TARGET_USER="$2"; shift 2 ;;
        --check) CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log ERROR "unknown argument: $1"; usage; exit 2 ;;
    esac
done

CAP_RC_OK=0
CAP_RC_NO=1
CAP_RC_UNKNOWN=2

params_runtime() {
    jq -r '.runtime // empty' <<< "${MLP_CAPABILITY_PARAMS:-{\}}" 2>/dev/null
}

# docker 群組有沒有這個使用者——用 getent 讀，不要直接讀 /etc/group：
# 直接讀檔在測試裡假不了，而這正是要區分「1」與「2」的那一半。
group_has_user() {
    local line
    line="$(getent group docker 2>/dev/null)" || return 1
    local members="${line#*:}"
    members="${members#*:}"
    members="${members#*:}"
    local m
    for m in ${members//,/ }; do
        [ "$m" = "$1" ] && return 0
    done
    return 1
}

# 這個 process 的群組有沒有 docker。用 id -nG（名單，不是 gid）比對群組名。
process_in_group() {
    local groups
    groups="$(id -nG 2>/dev/null)" || return 1
    local g
    for g in $groups; do
        [ "$g" = "$1" ] && return 0
    done
    return 1
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    runtime="$(params_runtime)"
    if [[ "$runtime" != "docker" ]]; then
        log INFO "worker-host: runtime=${runtime:-<none>} 不是 docker —— 能力不成立"
        exit "$CAP_RC_NO"
    fi
    if docker info >/dev/null 2>&1; then
        log INFO "worker-host: docker 可用（${TARGET_USER}）"
        exit "$CAP_RC_OK"
    fi
    # docker 失敗。分不清「本來就不在群組」與「群組變更還沒在這個 session 生效」
    # 的話，宣告會每 30 分鐘抖一次——所以寧可回 2 保留舊值。
    if group_has_user "$TARGET_USER" && ! process_in_group docker; then
        log INFO "worker-host: ${TARGET_USER} 在 /etc/group 的 docker 群組裡，但這個 session 的群組還沒有 —— 無法確認"
        exit "$CAP_RC_UNKNOWN"
    fi
    log INFO "worker-host: docker 不可用（${TARGET_USER} 不在 docker 群組）"
    exit "$CAP_RC_NO"
fi

log INFO "worker-host installs nothing — capability check only (--check)"
exit 0
