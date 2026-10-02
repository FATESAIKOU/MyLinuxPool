#!/usr/bin/env bash
# shared-configs/pool-runtime/install.sh — docs/LAYOUT.md §1
#
# Installs pool-resolve/pool-tunnel/pool-status/pool-port-alloc,
# pool-sync and tunnel-identity.sh to <home>/.mylinuxpool/bin/ (the
# canonical location — POOL_RUNTIME_SPEC.md §0's state-dir layout, and
# what pool-tunnel.service's ExecStart=%h/... already hardcodes) and the
# systemd user units (pool-tunnel.service, pool-sync.service,
# pool-sync.timer) to <home>/.config/systemd/user/. No root needed
# anywhere in this unit.
#
# tunnel-identity.sh is the SINGLE source of the tunnel identity path —
# pool-tunnel / pool-status / pool-sync source it at runtime, so it MUST
# ship next to them or those consumers die at startup (RUNBOOK §7.12,
# third incident).
#
# This install.sh only gets the FILES in place. Enabling/starting the
# systemd services, and `loginctl enable-linger`, are role-specific
# decisions (a provider runs pool-tunnel + pool-sync.timer as persistent
# services; the Gateway never runs them at all — it only needs the tools
# for ad-hoc use) and stay the caller's job
# (ops-scripts/register-provider.sh / the provider profile's
# systemd_user_services).
#
# --check compares CONTENT, not just existence: an old, stale or tampered
# bin/ must be reported as drift so pool-sync can converge it (task D —
# the whole point of the sync is repairing exactly that).

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
# tunnel-identity.sh is sourced by pool-tunnel / pool-status / pool-sync,
# so it MUST ship with them: without it every one of them dies at source
# time and the machine loses its tunnel (2026-09-16 — the test caught
# this before it reached a provider, which is the only reason it did not).
BINARIES="pool-resolve pool-tunnel pool-status pool-port-alloc pool-sync"
# Sourced, not executed — so it ships WITHOUT the executable bit
# (ops-scripts/preflight: only things nothing sources must be +x).
LIBS="tunnel-identity.sh"
UNITS="pool-tunnel.service pool-sync.service pool-sync.timer"

# file_matches <installed-path> <repo-source>
#   0 = byte-identical, 1 = missing or differs, 2 = repo source missing
file_matches() {
    local installed="$1" source="$2"
    [[ -f "$source" ]] || return 2
    [[ -f "$installed" ]] || return 1
    cmp -s "$installed" "$source"
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

check_installed() {
    local f
    for f in $BINARIES; do
        file_matches "${BIN_DIR}/${f}" "${FILES_DIR}/${f}" || return 1
    done
    # Sourced libraries count too: a missing tunnel-identity.sh kills
    # pool-tunnel at source time, so --check must call that drift.
    for f in $LIBS; do
        file_matches "${BIN_DIR}/${f}" "${FILES_DIR}/${f}" || return 1
    done
    for f in $UNITS; do
        file_matches "${UNIT_DIR}/${f}" "${FILES_DIR}/${f}" || return 1
    done
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
for f in $BINARIES; do
    install_file "${FILES_DIR}/${f}" "${BIN_DIR}/${f}" 755 || {
        log ERROR "could not install ${f}"; exit 1; }
done
# tunnel-identity.sh ships WITHOUT the executable bit (see $LIBS above).
install_file "${FILES_DIR}/tunnel-identity.sh" "${BIN_DIR}/tunnel-identity.sh" 644 || {
    log ERROR "could not install tunnel-identity.sh"; exit 1; }

mkdir -p "$UNIT_DIR"
for f in $UNITS; do
    install_file "${FILES_DIR}/${f}" "${UNIT_DIR}/${f}" 644 || {
        log ERROR "could not install ${f}"; exit 1; }
done

chown -R "${TARGET_USER}:${TARGET_USER}" "${HOME_DIR}/.mylinuxpool" 2>/dev/null || true
chown -R "${TARGET_USER}:${TARGET_USER}" "$UNIT_DIR" 2>/dev/null || true

log INFO "installed pool-runtime to ${BIN_DIR} (+ systemd unit at ${UNIT_DIR})"
