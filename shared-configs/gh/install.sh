#!/usr/bin/env bash
# shared-configs/gh/install.sh — docs/LAYOUT.md §1
#
# needs_key=false: this unit has no files/, so --key is accepted (interface
# parity) but unused — the token is driven by GH_POOL_TOKEN in the environment
# instead (a different secret from --key's FILE_CRYPTO_KEY, which stays
# reserved for that one purpose across every unit). Without GH_POOL_TOKEN this
# unit just installs the `gh` binary (the Gateway's case: it deliberately
# holds no GitHub credential, spec §10.2b).
#
# needs_root=true: only for apt-installing `gh`, and only when `gh` isn't
# already on PATH — so a caller that already has `gh` another way (e.g.
# register-provider's --no-sudo tarball bootstrap) can still run this as a
# normal user.

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

TOKEN_FILE="${HOME_DIR}/.mylinuxpool/gh_token"

check_installed() {
    command -v gh >/dev/null 2>&1
}

# --- github 能力（D2／D5）-------------------------------------------------
# --check 的回傳碼是「能力成立嗎」：0 成立、1 確定不成立、2 無法確認。
# 形狀與權限在這裡判斷（不在 mlp）：malformed 是宣告本身壞掉 → 1 且不打 API；
# 非 read 的權限沒有定義好的驗證方式 → 2，不能報 pass 也不能報成確定不成立。
# token 走 pool-sync 的 ~/.mylinuxpool/gh_token 慣例——宣告要能驗證同一份憑證。
cap_check() {
    local params="${MLP_CAPABILITY_PARAMS:-{\}}"
    local schema_err
    schema_err="$(jq -r '
        if type != "object" then "capability value must be an object"
        elif (has("repos") | not) then ""
        elif (.repos | type) != "object" then ".repos must be an object"
        elif [.repos[] | select(type != "array")] | length > 0 then "every .repos value must be an array"
        elif [.repos[][] | select(. != "read" and . != "write" and . != "trigger-actions")] | length > 0
          then "permission values must be read/write/trigger-actions"
        else "" end' 2>/dev/null <<< "$params")"
    if [[ -n "$schema_err" ]]; then
        log ERROR "github: malformed declaration — ${schema_err}"
        return 1
    fi
    if [[ "$(jq -r '[((.repos // {}) | .[])[] | select(. != "read")] | length' 2>/dev/null <<< "$params")" != "0" ]]; then
        log INFO "github: write/trigger-actions have no defined verification"
        return 2
    fi

    local token
    token="$(cat "$TOKEN_FILE" 2>/dev/null)" || token=""
    [ -n "$token" ] || token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    # 沒有憑證就確定讀不到（私有庫），不是「無法確認」。
    if [ -z "$token" ]; then
        log INFO "github: 沒有憑證（${TOKEN_FILE}）—— 能力不成立"
        return 1
    fi
    local rc=0 repo out code one
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        # --include 讓失敗時也有狀態碼可讀。拿不到狀態碼才比對文字（403 與 rate
        # limit 共用同一個狀態碼，文字反而分得開）：無權存取／404 → 1；限流 → 2。
        out="$(GH_TOKEN="$token" gh api --include "repos/${repo}" --jq .full_name 2>&1)"
        if [ $? -eq 0 ]; then
            log INFO "github: ${repo} 可讀"
            continue
        fi
        code="$(printf '%s\n' "$out" | grep -oE '^HTTP/[0-9.]+ [0-9]{3}' | tail -1 | grep -oE '[0-9]{3}$')"
        one=2
        case "$code" in
            401|403|404) one=1 ;;
            # 能走到這裡就代表 gh 非 0 退出，沒有理由判成成立。
            2*)          one=2 ;;
        esac
        if [ -z "$code" ]; then
            case "$out" in
                *"rate limit"*|*"Rate limit"*|*"secondary rate"*) one=2 ;;
                *403*|*"Resource not accessible"*|*"Not Found"*|*404*) one=1 ;;
            esac
        fi
        # 1 一旦出現就不被 2 蓋掉。
        [ "$one" -eq 1 ] && rc=1 || { [ "$rc" -eq 0 ] && rc="$one"; }
        log INFO "github: ${repo} → ${one}（code=${code:-none} ${out}）"
    done < <(jq -r '(.repos // {}) | keys_unsorted[]' <<< "$params" 2>/dev/null)
    return "$rc"
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if [ -n "${MLP_CAPABILITY_PARAMS+x}" ]; then
        cap_check
        exit "$?"
    fi
    if check_installed; then
        log INFO "gh already installed"
        exit 0
    fi
    log INFO "gh not installed"
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    if [[ "$(id -u)" -ne 0 ]]; then
        log ERROR "gh is not installed and apt-installing it needs root — run as root, or install gh some other way first (e.g. the caller's own no-root bootstrap) and re-run this unit"
        exit 1
    fi
    log INFO "installing gh via apt"
    apt-get update -y
    apt-get install -y gh
else
    log INFO "gh already present"
fi

# 生產觸發條件：Gateway 上 100% 走此路（provision-gateway 的 rotate/repair
# 呼叫不帶 GH_POOL_TOKEN，Gateway 依 spec §10.2b 刻意不持有 GitHub 憑證）；
# provider 上不觸發。退場條件是 Gateway 政策改變、開始持有憑證。
if [[ -z "${GH_POOL_TOKEN:-}" ]]; then
    log INFO "GH_POOL_TOKEN not set — installing the gh binary only (no token file/credential helper)"
    exit 0
fi

# `gh auth login --with-token` insists on a `read:org` scope our PAT
# doesn't have and none of our operations need — gh honors a bare GH_TOKEN
# env var (which pool-resolve loads from this file) with no login step.
mkdir -p "$(dirname "$TOKEN_FILE")"
need_write=1
if [[ -f "$TOKEN_FILE" ]] && [[ "$(cat "$TOKEN_FILE")" == "$GH_POOL_TOKEN" ]]; then
    need_write=0
fi
if [[ "$need_write" -eq 1 ]]; then
    printf '%s' "$GH_POOL_TOKEN" > "$TOKEN_FILE"
    log INFO "wrote ${TOKEN_FILE}"
else
    log INFO "${TOKEN_FILE} already up to date"
fi
chmod 600 "$TOKEN_FILE"
chown "${TARGET_USER}:${TARGET_USER}" "$TOKEN_FILE" 2>/dev/null || true

# Plain `git` (fetch/pull/clone) doesn't consult GH_TOKEN at all — it has
# its own, separate credential story. A global credential helper that
# reads the token FILE at invocation time (not a value baked into
# .gitconfig) fixes that without depending on any `gh auth login` state.
GITCONFIG="${HOME_DIR}/.gitconfig"
cred_helper="!f() { echo username=x-access-token; echo \"password=\$(cat ${TOKEN_FILE} 2>/dev/null)\"; }; f"
current_helper="$(git config --file "$GITCONFIG" --get credential.https://github.com.helper 2>/dev/null || true)"
if [[ "$current_helper" == "$cred_helper" ]]; then
    log INFO "git credential helper for github.com already configured"
else
    git config --file "$GITCONFIG" credential.https://github.com.helper "$cred_helper"
    chown "${TARGET_USER}:${TARGET_USER}" "$GITCONFIG" 2>/dev/null || true
    log INFO "configured git credential helper for github.com to read ${TOKEN_FILE}"
fi

log INFO "gh installed and configured"
