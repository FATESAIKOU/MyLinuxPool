#!/usr/bin/env bash
# shared_config/pool-runtime/install.sh — docs/LAYOUT.md §1
#
# Installs pool-resolve/pool-tunnel/pool-wol/pool-status/pool-port-alloc to
# <home>/.mylinuxpool/bin/ (the canonical location — POOL_RUNTIME_SPEC.md
# §0's state-dir layout, and what pool-tunnel.service's ExecStart=%h/...
# already hardcodes) and the systemd user unit to
# <home>/.config/systemd/user/. No root needed anywhere in this unit.
#
# This install.sh only gets the FILES in place. Enabling/starting the
# systemd service, and `loginctl enable-linger`, are role-specific
# decisions (a provider runs pool-tunnel as a persistent service; the
# Gateway never runs it at all — it only needs the tools for ad-hoc use)
# and stay the caller's job (ops-script/register-provider.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FILES_DIR="${SCRIPT_DIR}/files"

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
# --key is accepted (interface must be identical across every unit) but
# unused: this unit has no .crypted files.

BIN_DIR="${HOME_DIR}/.mylinuxpool/bin"
UNIT_DIR="${HOME_DIR}/.config/systemd/user"
BINARIES="pool-resolve pool-tunnel pool-wol pool-status pool-port-alloc"

check_installed() {
    local f
    for f in $BINARIES; do
        [[ -x "${BIN_DIR}/${f}" ]] || return 1
    done
    [[ -f "${UNIT_DIR}/pool-tunnel.service" ]] || return 1
    return 0
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if check_installed; then
        log INFO "pool-runtime already installed at ${BIN_DIR}"
        exit 0
    fi
    log INFO "pool-runtime not fully installed at ${BIN_DIR}"
    exit 1
fi

mkdir -p "$BIN_DIR"
cp -f "${FILES_DIR}"/pool-resolve "${FILES_DIR}"/pool-tunnel "${FILES_DIR}"/pool-wol \
      "${FILES_DIR}"/pool-status "${FILES_DIR}"/pool-port-alloc "${BIN_DIR}/"
chmod +x "${BIN_DIR}"/pool-resolve "${BIN_DIR}"/pool-tunnel "${BIN_DIR}"/pool-wol \
         "${BIN_DIR}"/pool-status "${BIN_DIR}"/pool-port-alloc

mkdir -p "$UNIT_DIR"
cp -f "${FILES_DIR}/pool-tunnel.service" "${UNIT_DIR}/pool-tunnel.service"

chown -R "${TARGET_USER}:${TARGET_USER}" "${HOME_DIR}/.mylinuxpool" 2>/dev/null || true
chown -R "${TARGET_USER}:${TARGET_USER}" "$UNIT_DIR" 2>/dev/null || true

log INFO "installed pool-runtime to ${BIN_DIR} (+ systemd unit at ${UNIT_DIR})"
