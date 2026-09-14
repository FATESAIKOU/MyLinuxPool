#!/usr/bin/env bash
# shared_config/rclone/install.sh — docs/LAYOUT.md §1
# needs_root=true: this unit apt-installs the rclone binary, so the caller
# must already be root (checked below, skipped for --check).

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

TARGET="${HOME_DIR}/.config/rclone/rclone.conf"

check_installed() {
    command -v rclone >/dev/null 2>&1 || return 1
    [[ -f "$TARGET" ]] || return 1
    return 0
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if check_installed; then
        log INFO "rclone already installed"
        exit 0
    fi
    log INFO "rclone not fully installed"
    exit 1
fi

# needs_key=true: --key, or the key piped on stdin, is required from here on.
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

if [[ "$(id -u)" -ne 0 ]]; then
    log ERROR "this unit needs_root=true — run as root"
    exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
    log INFO "installing rclone via apt"
    apt-get update -y
    apt-get install -y rclone
else
    log INFO "rclone binary already present"
fi

mkdir -p "$(dirname "$TARGET")"
if [[ -f "$TARGET" ]]; then
    log INFO "${TARGET} already present, skipping decrypt"
else
    "$DECRYPT" "$KEY" < "${FILES_DIR}/rclone.conf.crypted" > "$TARGET"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$TARGET"
        log ERROR "decryptStdin.sh failed (exit ${rc}) while decrypting rclone.conf.crypted — wrong --key, or the encrypted file is corrupted"
        exit 1
    fi
    log INFO "decrypted rclone.conf to ${TARGET}"
fi
chmod 600 "$TARGET"
chown -R "${TARGET_USER}:${TARGET_USER}" "$(dirname "$TARGET")" 2>/dev/null || true

log INFO "rclone installed and configured"
