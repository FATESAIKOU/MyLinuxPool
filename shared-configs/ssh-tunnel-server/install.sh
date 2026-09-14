#!/usr/bin/env bash
# shared-configs/ssh-tunnel-server/install.sh — docs/LAYOUT.md §1
#
# Installs sshproxy's authorized_keys on the machine that gets DIALED INTO
# by every provider's/worker's reverse tunnel — the Gateway. This is the
# other half of the sshproxy identity from shared-configs/ssh-tunnel-client
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
HOME_DIR="${HOME}"
TARGET_USER="$(whoami)"
CHECK_ONLY=0
PRUNE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) [[ $# -ge 2 ]] || { usage; exit 2; }; KEY="$2"; shift 2 ;;
        --home) [[ $# -ge 2 ]] || { usage; exit 2; }; HOME_DIR="$2"; shift 2 ;;
        --user) [[ $# -ge 2 ]] || { usage; exit 2; }; TARGET_USER="$2"; shift 2 ;;
        --check) CHECK_ONLY=1; shift ;;
        --prune) PRUNE=1; shift ;;
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

# Confirm we actually have the ability to decrypt before doing anything
# that depends on it — an absent tool must fail as "can't check this",
# never get misread as "checked, and it's wrong". 2026-09-15 incident:
# shared-configs/ was deployed without scripts/ alongside it, so this unit
# hit "scripts/lib/crypto.sh: No such file or directory" and — before
# this check existed — reported that as "invariant violated:
# id_rsa.pub.crypted's key is not present in authorized_keys.crypted".
# Those are not the same failure: one means "the environment can't run
# this check", the other means "the data is actually broken" — and
# whoever reads the second message goes and edits files that were never
# wrong. Same lesson as the sudo-probe-misattributed-to-visudo and the
# fake-listener-passing-as-a-healthy-tunnel incidents: confirm you have
# the ability to check before reporting a verdict.
if [[ ! -x "$DECRYPT" ]]; then
    log ERROR "${DECRYPT} not found or not executable"
    log ERROR "this unit depends on scripts/lib/crypto.sh — deploy shared-configs/ together with scripts/, not shared-configs/ alone"
    exit 1
fi

# Both decrypted to memory (never written to disk) purely to check the
# invariant below — authorized_keys is the only one of the two that's an
# actual install target. Each decrypt's own exit code is checked BEFORE
# the invariant comparison runs: a decrypt failure (wrong --key, or a
# corrupted .crypted file) must be reported as "couldn't verify", not
# blended into the same failure path as "verified, and it's wrong".
pubkey_content="$("$DECRYPT" decrypt "$KEY" < "${FILES_DIR}/id_rsa.pub.crypted")"
pubkey_rc=$?
authorized_keys_content="$("$DECRYPT" decrypt "$KEY" < "${FILES_DIR}/authorized_keys.crypted")"
authorized_keys_rc=$?

if [[ $pubkey_rc -ne 0 || $authorized_keys_rc -ne 0 ]]; then
    log ERROR "cannot verify invariant: crypto.sh failed (id_rsa.pub.crypted exit ${pubkey_rc}, authorized_keys.crypted exit ${authorized_keys_rc})"
    log ERROR "this means the --key is wrong or a .crypted file is corrupted — NOT that the invariant is violated. Fix the decrypt failure first, then re-run to actually check the invariant."
    exit 1
fi

pubkey_fields="$(printf '%s' "$pubkey_content" | awk '{print $1, $2}')"
if ! printf '%s\n' "$authorized_keys_content" | awk '{print $1, $2}' | grep -qxF "$pubkey_fields"; then
    log ERROR "invariant violated: id_rsa.pub.crypted's key is not present in authorized_keys.crypted"
    log ERROR "these two files must be updated together whenever the shared sshproxy key is regenerated (spec §4) — every provider/worker would otherwise fail to tunnel in with 'Permission denied (publickey,password)'"
    exit 1
fi
log INFO "invariant OK: sshproxy's public key is present in authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Same trap as ssh-admin had: cloud-init creates sshproxy with an
# authorized_keys of its own, so "skip if present" meant the declared list
# was never applied — invisible today only because cloud-init happens to
# seed the same key. Union, so growing the declared list converges and no
# working identity is ever dropped by an install.
merged="$(mktemp)"
if [[ "${PRUNE:-0}" -eq 1 ]]; then
    printf '%s\n' "$authorized_keys_content" > "$merged"
    if ! awk '$2 != ""' "$merged" | grep -q .; then
        rm -f "$merged"
        log ERROR "--prune refused: the declared authorized_keys is empty"
        exit 1
    fi
    dropped="$(comm -23 \
        <(awk '$2 != "" { print $2 }' "$TARGET" 2>/dev/null | sort -u) \
        <(awk '$2 != "" { print $2 }' "$merged" | sort -u) | wc -l | tr -d ' ')"
    log WARN "--prune: removing ${dropped} key(s) not in the declared list"
else
    cat "$TARGET" 2>/dev/null > "$merged"
    printf '%s\n' "$authorized_keys_content" >> "$merged"
fi
awk '$2 != "" && !seen[$2]++' "$merged" > "$TARGET"
rm -f "$merged"
log INFO "authorized_keys now holds $(awk '$2 != ""' "$TARGET" | wc -l | tr -d ' ') key(s)" 
chmod 644 "$TARGET"
chown "${TARGET_USER}:${TARGET_USER}" "$TARGET" 2>/dev/null || true

log INFO "ssh-tunnel-server installed to ${TARGET}"
