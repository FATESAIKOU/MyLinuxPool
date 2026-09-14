#!/usr/bin/env bash
# shared-configs/standalonescripts/install.sh — docs/LAYOUT.md §1
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
DECRYPT="${REPO_ROOT}/scripts/lib/crypto.sh"

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

# Content, not existence. "The file is there" was true on a machine whose
# authorized_keys had one of ten declared keys (RUNBOOK §7.6); the same
# blindness applies to every decrypted file this unit installs.
#   same_as_declared <declared.crypted> <installed-path>
#     0 = matches, 1 = differs, 2 = cannot tell (decrypt failed)
same_as_declared() {
    local crypted="$1" installed="$2" tmp rc
    [[ -f "$installed" ]] || return 1
    tmp="$(mktemp)"
    "$DECRYPT" decrypt "$KEY" < "$crypted" > "$tmp" 2>/dev/null
    rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$tmp"
        log ERROR "cannot verify $(basename "$installed"): ${crypted##*/} would not decrypt (wrong --key?)"
        return 2
    fi
    if cmp -s "$tmp" "$installed"; then rm -f "$tmp"; return 0; fi
    rm -f "$tmp"
    return 1
}

check_installed() {
    local f rc=0
    for f in dlpw uppw; do
        if [[ ! -x "${TARGET_DIR}/${f}" ]]; then
            log ERROR "${TARGET_DIR}/${f} missing or not executable"; rc=1; continue
        fi
        same_as_declared "${FILES_DIR}/${f}.crypted" "${TARGET_DIR}/${f}"
        case $? in
            0) ;;
            2) rc=1 ;;
            *) log ERROR "${TARGET_DIR}/${f} differs from the declared version"; rc=1 ;;
        esac
    done
    return "$rc"
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
    log ERROR "this unit depends on scripts/lib/crypto.sh — deploy shared-configs/ together with scripts/, not shared-configs/ alone"
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
        "$DECRYPT" decrypt "$KEY" < "${FILES_DIR}/${f}.crypted" > "${TARGET_DIR}/${f}"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            rm -f "${TARGET_DIR}/${f}"
            log ERROR "crypto.sh failed (exit ${rc}) while decrypting ${f}.crypted — wrong --key, or the encrypted file is corrupted"
            exit 1
        fi
        log INFO "decrypted ${f} to ${TARGET_DIR}/${f}"
    fi
    chmod +x "${TARGET_DIR}/${f}"
done
chown -R "${TARGET_USER}:${TARGET_USER}" "$TARGET_DIR" 2>/dev/null || true

log INFO "standalonescripts installed to ${TARGET_DIR}"
