#!/usr/bin/env bash
# shared_config/ssh-admin/install.sh — docs/LAYOUT.md §1
# fatesaikou's own ssh identity — used on the Gateway only (a provider
# reaches Actions the other way around: SSH_KEY_ACTIONS' public half goes
# into the PROVIDER's authorized_keys, which is a narrower operation
# ops-script/register-provider.sh does itself, not this unit — this unit
# is fatesaikou's FULL identity, private key included, and that must never
# land on a provider).
#
# needs_key=true, needs_root=false: plain file installs into <home>/.ssh.

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

check_installed() {
    [[ -f "${SSH_DIR}/id_rsa" && -f "${SSH_DIR}/id_rsa.pub" && -f "${SSH_DIR}/authorized_keys" ]]
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if check_installed; then
        log INFO "ssh-admin already installed"
        exit 0
    fi
    log INFO "ssh-admin not fully installed"
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

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "${SSH_DIR}/id_rsa" ]]; then
    log INFO "${SSH_DIR}/id_rsa already present, skipping decrypt"
else
    "$DECRYPT" "$KEY" < "${FILES_DIR}/id_rsa.crypted" > "${SSH_DIR}/id_rsa"
    log INFO "decrypted id_rsa to ${SSH_DIR}/id_rsa"
fi
chmod 600 "${SSH_DIR}/id_rsa"

if [[ -f "${SSH_DIR}/id_rsa.pub" ]]; then
    log INFO "${SSH_DIR}/id_rsa.pub already present, skipping decrypt"
else
    "$DECRYPT" "$KEY" < "${FILES_DIR}/id_rsa.pub.crypted" > "${SSH_DIR}/id_rsa.pub"
    log INFO "decrypted id_rsa.pub to ${SSH_DIR}/id_rsa.pub"
fi
chmod 644 "${SSH_DIR}/id_rsa.pub"

if [[ -f "${SSH_DIR}/authorized_keys" ]]; then
    log INFO "${SSH_DIR}/authorized_keys already present, skipping decrypt"
else
    "$DECRYPT" "$KEY" < "${FILES_DIR}/authorized_keys.crypted" > "${SSH_DIR}/authorized_keys"
    log INFO "decrypted authorized_keys to ${SSH_DIR}/authorized_keys"
fi
chmod 644 "${SSH_DIR}/authorized_keys"

chown -R "${TARGET_USER}:${TARGET_USER}" "$SSH_DIR" 2>/dev/null || true

log INFO "ssh-admin installed to ${SSH_DIR}"
