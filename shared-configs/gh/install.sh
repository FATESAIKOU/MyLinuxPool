#!/usr/bin/env bash
# shared-configs/gh/install.sh — docs/LAYOUT.md §1
#
# needs_key=false: this unit has no files/ at all, so --key is accepted
# (interface parity) but unused. The token-file/credential-helper part of
# this unit is instead driven by GH_POOL_TOKEN in the environment — that
# is a DIFFERENT secret from --key's FILE_CRYPTO_KEY, and --key is
# reserved for that one purpose across every unit, so it would be
# misleading to overload it here. When GH_POOL_TOKEN isn't set (the
# Gateway's own case — it deliberately holds no GitHub credential, spec
# §10.2b), this unit just installs the `gh` binary and stops there.
#
# needs_root=true: apt-installing `gh` needs root, but ONLY when `gh` isn't
# already on PATH — the root check is gated on that (see below), not
# unconditional, so a caller that already has `gh` some other way (e.g.
# ops-scripts/register-provider.sh's own --no-sudo tarball bootstrap, run before this
# unit ever gets called) can still call this unit as a normal user to get
# the token file + git credential helper set up.

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

if [[ "$CHECK_ONLY" -eq 1 ]]; then
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

if [[ -z "${GH_POOL_TOKEN:-}" ]]; then
    log INFO "GH_POOL_TOKEN not set — installing the gh binary only (no token file/credential helper)"
    exit 0
fi

# `gh auth login --with-token` insists on a `read:org` scope our PAT
# doesn't have and none of our operations need — gh honors a bare
# GH_TOKEN env var (which pool-resolve loads from this file) with no
# login step at all.
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
# .gitconfig) fixes that without depending on any `gh auth login` state,
# and re-running this replaces whatever helper (or none) was there before.
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
