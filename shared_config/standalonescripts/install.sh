#!/usr/bin/env bash
# shared_config/standalonescripts/install.sh — docs/LAYOUT.md §1
#
# dlpw/uppw need rclone at RUNTIME (LAYOUT.md's own §"為什麼要這樣改" #3:
# this dependency used to be implicit and undocumented). This unit only
# places the two scripts — it does not install rclone itself; the profile
# that lists this unit must also list the rclone unit. The soft check
# below just warns if rclone isn't there yet, it doesn't block install.
#
# needs_key=true, needs_root=false.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FILES_DIR="${SCRIPT_DIR}/files"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DECRYPT="${REPO_ROOT}/scripts/decryptStdin.sh"

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

TARGET_DIR="${HOME_DIR}/testSH"

check_installed() {
    [[ -x "${TARGET_DIR}/dlpw" && -x "${TARGET_DIR}/uppw" ]]
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if check_installed; then
        log INFO "standalonescripts already installed"
        exit 0
    fi
    log INFO "standalonescripts not fully installed"
    exit 1
fi

if [[ -z "$KEY" ]]; then
    if [[ ! -t 0 ]]; then
        KEY="$(cat)"
    fi
    if [[ -z "$KEY" ]]; then
        log ERROR "--key <FILE_CRYPTO_KEY> required (or pipe it via stdin)"
        exit 2
    fi
fi

# Confirm we actually have the ability to decrypt before doing anything
# that depends on it — an absent tool must fail as "can't check this",
# never get misread as "checked, and it's wrong" (2026-09-15: exactly that
# mixup, on ssh-tunnel-server, reported a data-integrity violation for
# what was really a missing scripts/ directory).
if [[ ! -x "$DECRYPT" ]]; then
    log ERROR "${DECRYPT} not found or not executable"
    log ERROR "this unit depends on scripts/decryptStdin.sh — deploy shared_config/ together with scripts/, not shared_config/ alone"
    exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
    log WARN "rclone is not on PATH yet — dlpw/uppw will be installed but won't work until the rclone unit is also installed"
fi

mkdir -p "$TARGET_DIR"
for f in dlpw uppw; do
    if [[ -f "${TARGET_DIR}/${f}" ]]; then
        log INFO "${TARGET_DIR}/${f} already present, skipping decrypt"
    else
        "$DECRYPT" "$KEY" < "${FILES_DIR}/${f}.crypted" > "${TARGET_DIR}/${f}"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            rm -f "${TARGET_DIR}/${f}"
            log ERROR "decryptStdin.sh failed (exit ${rc}) while decrypting ${f}.crypted — wrong --key, or the encrypted file is corrupted"
            exit 1
        fi
        log INFO "decrypted ${f} to ${TARGET_DIR}/${f}"
    fi
    chmod +x "${TARGET_DIR}/${f}"
done
chown -R "${TARGET_USER}:${TARGET_USER}" "$TARGET_DIR" 2>/dev/null || true

log INFO "standalonescripts installed to ${TARGET_DIR}"
