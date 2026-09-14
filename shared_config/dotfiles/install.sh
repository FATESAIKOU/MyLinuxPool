#!/usr/bin/env bash
# shared_config/dotfiles/install.sh — docs/LAYOUT.md §1
# No key, no root: plain file copies into <home>.

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

check_installed() {
    [[ -f "${HOME_DIR}/.bashrc" && -f "${HOME_DIR}/.vimrc" && -f "${HOME_DIR}/.tmux.conf" ]]
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if check_installed; then
        log INFO "dotfiles already installed"
        exit 0
    fi
    log INFO "dotfiles not fully installed"
    exit 1
fi

cp -f "${FILES_DIR}/bashrc" "${HOME_DIR}/.bashrc"
cp -f "${FILES_DIR}/vimrc" "${HOME_DIR}/.vimrc"
cp -f "${FILES_DIR}/tmux.conf" "${HOME_DIR}/.tmux.conf"
chown "${TARGET_USER}:${TARGET_USER}" "${HOME_DIR}/.bashrc" "${HOME_DIR}/.vimrc" "${HOME_DIR}/.tmux.conf" 2>/dev/null || true

log INFO "installed dotfiles to ${HOME_DIR}"
