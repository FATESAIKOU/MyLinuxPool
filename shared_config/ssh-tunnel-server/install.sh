#!/usr/bin/env bash
# shared_config/ssh-tunnel-server/install.sh — docs/LAYOUT.md §1
#
# Installs sshproxy's authorized_keys on the machine that gets DIALED INTO
# by every provider's/worker's reverse tunnel — the Gateway. This is the
# other half of the sshproxy identity from shared_config/ssh-tunnel-client
# (which installs the matching PRIVATE key on providers/workers): a
# machine that receives the tunnel needs the public side authorized, never
# the private key itself. (2026-09-15: these two used to be one
# "ssh-tunnel" unit that installed the private key everywhere, including
# onto the Gateway — semantically wrong there, since the Gateway never
# dials out. This split undoes that.)
#
# Enforces the invariant from spec §4 (hit for real on 2026-09-13): the
# shared private key's public half (id_rsa.pub.crypted) MUST appear in
# this same bundle's authorized_keys.crypted, or every provider fails to
# tunnel in with "Permission denied (publickey,password)". Whoever
# regenerates this shared key pair must update both files together — this
# check catches it here, at install time, instead of at 2am during an
# incident.
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
TARGET="${SSH_DIR}/authorized_keys"

check_installed() {
    [[ -f "$TARGET" ]]
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if check_installed; then
        log INFO "ssh-tunnel-server already installed at ${TARGET}"
        exit 0
    fi
    log INFO "ssh-tunnel-server not installed"
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

# Both decrypted to memory (never written to disk) purely to check the
# invariant below — authorized_keys is the only one of the two that's an
# actual install target.
pubkey_content="$("$DECRYPT" "$KEY" < "${FILES_DIR}/id_rsa.pub.crypted")"
authorized_keys_content="$("$DECRYPT" "$KEY" < "${FILES_DIR}/authorized_keys.crypted")"

pubkey_fields="$(printf '%s' "$pubkey_content" | awk '{print $1, $2}')"
if ! printf '%s\n' "$authorized_keys_content" | awk '{print $1, $2}' | grep -qxF "$pubkey_fields"; then
    log ERROR "invariant violated: id_rsa.pub.crypted's key is not present in authorized_keys.crypted"
    log ERROR "these two files must be updated together whenever the shared sshproxy key is regenerated (spec §4) — every provider/worker would otherwise fail to tunnel in with 'Permission denied (publickey,password)'"
    exit 1
fi
log INFO "invariant OK: sshproxy's public key is present in authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$TARGET" ]]; then
    log INFO "${TARGET} already present, skipping write"
else
    printf '%s\n' "$authorized_keys_content" > "$TARGET"
    log INFO "installed authorized_keys to ${TARGET}"
fi
chmod 644 "$TARGET"
chown "${TARGET_USER}:${TARGET_USER}" "$TARGET" 2>/dev/null || true

log INFO "ssh-tunnel-server installed to ${TARGET}"
