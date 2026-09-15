#!/usr/bin/env bash
# shared-configs/ssh-admin/install.sh — docs/LAYOUT.md §1
# Who may log in as fatesaikou: installs authorized_keys from
# files/authorized_keys.crypted. That is the whole job.
#
# Declared by the gateway AND provider profiles, and the same decrypted
# bundle is injected into worker containers as WORKER_AUTHORIZED_KEYS
# (create-worker.yml) — so all three kinds of machine take "who may log
# in" from this one list. Until 2026-09-16 a provider got only the
# mylinuxpool-actions line, extracted by a special case in
# register-provider.sh; your own key was on those machines by accident,
# not by declaration.
#
# It does NOT install an identity key. The id_rsa / id_rsa.pub this unit
# used to deploy are used by no automation (REDESIGN.md N2/D3) and are no
# longer installed; files/id_rsa*.crypted stay in the repo only as backup.
# An id_rsa left on a machine is drift — --check reports it as a WARN, and
# install never deletes it: removing a private key is deliberate, manual.
#
# needs_key=true, needs_root=false: plain file installs into <home>/.ssh.

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
    echo "usage: install.sh [--key <FILE_CRYPTO_KEY>] [--home <dir>] [--user <name>] [--check] [--prune]" >&2
    echo "  --prune: make authorized_keys EXACTLY the declared list, removing anything else." >&2
    echo "           Revoking access is deliberate, so it never happens without this flag." >&2
}

KEY=""
PRUNE=0
HOME_DIR="${HOME}"
TARGET_USER="$(whoami)"
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) [[ $# -ge 2 ]] || { usage; exit 2; }; KEY="$2"; shift 2 ;;
        --home) [[ $# -ge 2 ]] || { usage; exit 2; }; HOME_DIR="$2"; shift 2 ;;
        --user) [[ $# -ge 2 ]] || { usage; exit 2; }; TARGET_USER="$2"; shift 2 ;;
        --prune) PRUNE=1; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log ERROR "unknown argument: $1"; usage; exit 2 ;;
    esac
done

SSH_DIR="${HOME_DIR}/.ssh"

# Key material only — "ssh-rsa AAAAB3... comment" keys on the AAAAB3 part,
# so a re-typed comment isn't mistaken for a different key.
key_blobs() { awk '{ if ($2 != "") print $2 }' "$1" 2>/dev/null | sort -u; }

check_installed() {
    # This unit installs authorized_keys only; an id_rsa here is an
    # identity this unit no longer deploys (REDESIGN.md N2/D3), so it
    # counts as drift and is reported as a WARN — never a failure, and
    # never deleted by install (removal is deliberate).
    if [[ -f "${SSH_DIR}/id_rsa" ]]; then
        log WARN "drift: ${SSH_DIR}/id_rsa is present but this unit no longer installs it (removed from deployment — REDESIGN N2/D3). Delete it manually if no longer needed."
    fi

    [[ -f "${SSH_DIR}/authorized_keys" ]] || return 1
    local declared missing extra
    declared="$(mktemp)"
    if ! "$DECRYPT" decrypt "$KEY" < "${FILES_DIR}/authorized_keys.crypted" > "$declared" 2>/dev/null; then
        rm -f "$declared"
        log ERROR "cannot verify: authorized_keys.crypted would not decrypt (wrong --key?)"
        return 1
    fi

    missing="$(comm -23 <(key_blobs "$declared") <(key_blobs "${SSH_DIR}/authorized_keys") | wc -l | tr -d ' ')"
    extra="$(comm -13 <(key_blobs "$declared") <(key_blobs "${SSH_DIR}/authorized_keys") | wc -l | tr -d ' ')"
    rm -f "$declared"

    [[ "$extra" -gt 0 ]] && log WARN "authorized_keys has ${extra} key(s) not declared by this unit"
    if [[ "$missing" -gt 0 ]]; then
        log ERROR "authorized_keys is missing ${missing} declared key(s)"
        return 1
    fi
    return 0
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

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# The authorized_keys install (below) is the whole job of this unit.
# The old identity-key deploy is gone; if the machine still has an
# id_rsa, say so (like --check does) but leave it alone — removing a
# private key is deliberate, so it only happens by hand (REDESIGN N2/D3).

if [[ -f "${SSH_DIR}/id_rsa" ]]; then
    log WARN "drift: ${SSH_DIR}/id_rsa is present but this unit no longer installs it (removed from deployment — REDESIGN N2/D3). Delete it manually if no longer needed."
fi

# "Skip if the file exists" looked idempotent and was actually a silent
# no-op: cloud-init creates the account with its own authorized_keys, so
# every fresh Gateway kept exactly cloud-init's key and none of the
# declared ones. provision still reported success.
#
# Union rather than replace: an install must never be able to lock out an
# identity that is currently working, including one this unit doesn't know
# about. Revoking a key is a separate, deliberate act — `--check` reports
# undeclared keys so they stay visible.
declared_ak="$(mktemp)"
"$DECRYPT" decrypt "$KEY" < "${FILES_DIR}/authorized_keys.crypted" > "$declared_ak"
rc=$?
if [[ $rc -ne 0 ]]; then
    rm -f "$declared_ak"
    log ERROR "crypto.sh failed (exit ${rc}) while decrypting authorized_keys.crypted — wrong --key, or the encrypted file is corrupted"
    exit 1
fi

if [[ "$PRUNE" -eq 1 ]]; then
    # Refuse to write an empty file: that is a lockout, not a revocation.
    if ! awk '$2 != ""' "$declared_ak" | grep -q .; then
        rm -f "$declared_ak"
        log ERROR "--prune refused: the declared authorized_keys is empty"
        exit 1
    fi
    dropped="$(comm -23 \
        <(awk '$2 != "" { print $2 }' "${SSH_DIR}/authorized_keys" 2>/dev/null | sort -u) \
        <(awk '$2 != "" { print $2 }' "$declared_ak" | sort -u) | wc -l | tr -d ' ')"
    awk '$2 != "" && !seen[$2]++' "$declared_ak" > "${SSH_DIR}/authorized_keys"
    log WARN "--prune: removed ${dropped} key(s) not in the declared list"
    merged_ak="$declared_ak"
else
merged_ak="$(mktemp)"
# Existing lines first so their comments win; dedupe on the key blob.
cat "${SSH_DIR}/authorized_keys" 2>/dev/null > "$merged_ak"
cat "$declared_ak" >> "$merged_ak"
awk '$2 != "" && !seen[$2]++' "$merged_ak" > "${SSH_DIR}/authorized_keys"
fi
log INFO "authorized_keys now holds $(awk '$2 != ""' "${SSH_DIR}/authorized_keys" | wc -l | tr -d ' ') key(s) (declared: $(awk '$2 != ""' "$declared_ak" | wc -l | tr -d ' '))"
rm -f "$declared_ak" "$merged_ak" 2>/dev/null || true
chmod 644 "${SSH_DIR}/authorized_keys"

chown -R "${TARGET_USER}:${TARGET_USER}" "$SSH_DIR" 2>/dev/null || true

log INFO "ssh-admin installed to ${SSH_DIR}"
