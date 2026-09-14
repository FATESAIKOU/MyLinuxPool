#!/usr/bin/env bash
# shared_config/ssh-tunnel-client/install.sh — docs/LAYOUT.md §1
#
# Installs the shared sshproxy PRIVATE key that a provider's/worker's
# pool-tunnel authenticates the reverse tunnel with, at the fixed path
# pool-tunnel itself expects: <home>/.ssh/id_pool (matches PRIVATE_KEY in
# pool-tunnel/pool-resolve — this path is not configurable independently).
# All providers/workers share this one key on purpose (spec §4).
#
# This is the "dials out" half of the sshproxy identity — the Gateway,
# which gets DIALED, needs the matching authorized_keys instead, not this
# private key. See shared_config/ssh-tunnel-server for that (2026-09-15:
# these two used to be one "ssh-tunnel" unit that quietly installed the
# wrong half of the identity depending which end you asked — this split
# undoes that).
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

SSH_DIR="${HOME_DIR}/.ssh"
TARGET="${SSH_DIR}/id_pool"

check_installed() {
    [[ -f "$TARGET" ]]
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if check_installed; then
        log INFO "ssh-tunnel-client already installed at ${TARGET}"
        exit 0
    fi
    log INFO "ssh-tunnel-client not installed"
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

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$TARGET" ]]; then
    log INFO "${TARGET} already present, skipping decrypt"
else
    "$DECRYPT" "$KEY" < "${FILES_DIR}/id_rsa.crypted" > "$TARGET"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$TARGET"
        log ERROR "decryptStdin.sh failed (exit ${rc}) while decrypting id_rsa.crypted — wrong --key, or the encrypted file is corrupted"
        exit 1
    fi
    log INFO "decrypted shared sshproxy key to ${TARGET}"
fi
chmod 600 "$TARGET"
chown "${TARGET_USER}:${TARGET_USER}" "$TARGET" 2>/dev/null || true

log INFO "ssh-tunnel-client installed to ${TARGET}"
