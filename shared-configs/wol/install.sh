#!/usr/bin/env bash
# shared-configs/wol/install.sh — docs/LAYOUT.md §1
#
# 安裝 pool-wol，並帶著 wol 能力的判準。從 pool-runtime 拆出來（D7）：
# pool-runtime 的 --check 是 cmp -s，兩個單位都帶 pool-wol 會互相覆蓋。
#
# --check **不送封包**。pool-wol 的 CLI 只有 `pool-wol <MAC> <target-ip>...`，
# 送出去回 0 只代表封包送出去了，不代表這台機器有 wol 的能力——用它當判準會
# 對每一台 provider 都回 0，等於沒有判準。
#

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

# install_file <source> <target> <mode>
#   換檔取代原地覆寫：bash 邊執行邊讀腳本，cp -f 會改寫正在執行的那個 inode（D10）。
#   同目錄暫存 → chmod → mv -f（同檔案系統的 rename 是原子的）；失敗不留暫存檔。
install_file() {
    local src="$1" dst="$2" mode="$3" dir tmp
    dir="${dst%/*}"
    tmp="$(mktemp "${dir}/.${dst##*/}.XXXXXX")" || return 1
    if ! cp "$src" "$tmp" || ! chmod "$mode" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

# 這一版 pool-wol 支援的 method。改 pool-wol 的時候要一起改這裡——
# 這是「不送封包」換來的唯一成本：宣告說支援哪個 method，是這份清單決定的。
SUPPORTED_METHODS="unicast"

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FILES_DIR="${SCRIPT_DIR}/files"
BIN_DIR="${HOME_DIR}/.mylinuxpool/bin"
WOL_BIN="${BIN_DIR}/pool-wol"

CAP_RC_OK=0
CAP_RC_NO=1
CAP_RC_UNKNOWN=2

params_methods() {
    jq -r '.methods // [] | if type == "array" then .[] else empty end' \
        <<< "${MLP_CAPABILITY_PARAMS:-{\}}" 2>/dev/null
}

supports_method() {
    local want="$1" have
    for have in $SUPPORTED_METHODS; do
        [ "$have" = "$want" ] && return 0
    done
    return 1
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if [[ ! -f "$WOL_BIN" ]]; then
        log INFO "wol: ${WOL_BIN} 不存在"
        exit "$CAP_RC_NO"
    fi
    if [[ ! -x "$WOL_BIN" ]]; then
        log INFO "wol: ${WOL_BIN} 不可執行"
        exit "$CAP_RC_NO"
    fi
    # 與本單位的檔案不同＝裝的是別版（或是別的東西）。回 1 而不是 2：這一版
    # 確定沒有被裝好，是「確定不成立」；回 2 會讓宣告停在舊值，把一個已經壞掉的
    # 狀態藏起來。
    if ! cmp -s "$WOL_BIN" "${FILES_DIR}/pool-wol"; then
        log INFO "wol: 已安裝的 pool-wol 與本單位的 files/pool-wol 不同 —— 裝的不是這一版"
        exit "$CAP_RC_NO"
    fi
    missing=""
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        supports_method "$m" || missing="${missing} ${m}"
    done < <(params_methods)
    if [ -n "$missing" ]; then
        log INFO "wol: 這一版不支援${missing}（本版支援：${SUPPORTED_METHODS}）"
        exit "$CAP_RC_NO"
    fi
    log INFO "wol: pool-wol 已安裝、可執行、支援 [${SUPPORTED_METHODS}]"
    exit "$CAP_RC_OK"
fi

mkdir -p "$BIN_DIR"
install_file "${FILES_DIR}/pool-wol" "$WOL_BIN" 755 || {
    log ERROR "could not install ${WOL_BIN}"; exit 1; }
chown "${TARGET_USER}:${TARGET_USER}" "$WOL_BIN" 2>/dev/null || true
log INFO "installed ${WOL_BIN}"
