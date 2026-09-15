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
    # Retired-key drift detection (REDESIGN N2/D3): this unit used to
    # deploy files/id_rsa.crypted as an identity key, so a leftover of
    # THAT key on a machine is residue attributable to this unit and
    # worth a WARN. Any other id_rsa is the machine's own business and
    # stays silent — warning about it was a false alarm on every provider
    # (their id_rsa predates this unit: fh-l's 2b61545dd6a2 and fh-proxy's
    # 7b8d8b8ecb4b are neither the retired key's 255867521c45).
    #
    # Comparison is on the public halves derived with ssh-keygen -y via a
    # temp 600 copy (ssh-keygen refuses world-readable private keys, and
    # the machine's own key must not be chmod'ed). Only type+blob is
    # compared, so a different comment cannot fool it.
    #
    # This stays WARN-level, and a decrypt/derive failure here silently
    # skips the notice instead of failing --check: the notice is
    # advisory, and verifying authorized_keys must not hinge on being
    # able to read some unrelated private key (wrong --key, corrupt
    # .crypted, or an id_rsa that isn't even a real key).
    if [[ -f "${SSH_DIR}/id_rsa" ]]; then
        local machine_pub="" retired_pub="" kt rc
        kt="$(mktemp)"
        cp -f "${SSH_DIR}/id_rsa" "$kt" 2>/dev/null
        chmod 600 "$kt"
        machine_pub="$(ssh-keygen -y -f "$kt" 2>/dev/null || true)"
        rm -f "$kt"
        kt="$(mktemp)"
        rc=0
        "$DECRYPT" decrypt "$KEY" < "${FILES_DIR}/id_rsa.crypted" > "$kt" 2>/dev/null || rc=1
        if [[ $rc -eq 0 ]]; then
            chmod 600 "$kt"
            retired_pub="$(ssh-keygen -y -f "$kt" 2>/dev/null || true)"
        fi
        rm -f "$kt"
        if [[ -n "$machine_pub" && -n "$retired_pub" \
              && "$(printf '%s' "$machine_pub" | awk '{print $1, $2}')" == "$(printf '%s' "$retired_pub" | awk '{print $1, $2}')" ]]; then
            log WARN "drift: ${SSH_DIR}/id_rsa is the identity key this unit retired (REDESIGN N2/D3) — delete it manually if no longer needed."
        fi
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
    if [[ "$extra" -gt 0 ]]; then
        # The security-relevant direction: a key the declaration does not
        # know about can log in — someone (or some old process) granted
        # access behind the declaration's back, and that is exactly what
        # must surface, not be waved through as a WARN. List WHO (comment)
        # plus the fingerprint prefix of each offender so the decision to
        # prune or to declare is easy.
        #
        # Timing: tightening now is safe — on all three live machines
        # authorized_keys currently equals the declaration exactly, so no
        # red lights need cleaning up first. Waiting any longer just
        # accumulates machine-specific keys to triage.
        local blob line comment fp fpfile
        while IFS= read -r blob; do
            [[ -n "$blob" ]] || continue
            line="$(grep -F "$blob" "${SSH_DIR}/authorized_keys" 2>/dev/null | head -1)"
            comment="$(awk '{$1=""; $2=""; sub(/^  */, ""); print}' <<<"$line")"
            fpfile="$(mktemp)"
            printf '%s\n' "$line" > "$fpfile"
            fp="$(ssh-keygen -lf "$fpfile" 2>/dev/null | awk '{print $2}' | sed 's/^SHA256://' | cut -c1-16)"
            rm -f "$fpfile"
            printf '  undeclared key: comment=%q fingerprint=SHA256:%s\n' "$comment" "${fp:-<unavailable>}" >&2
        done < <(comm -13 <(key_blobs "$declared") <(key_blobs "${SSH_DIR}/authorized_keys"))
        log ERROR "authorized_keys has ${extra} undeclared key(s) — remove them or add them to files/authorized_keys.crypted"
        rm -f "$declared"
        return 1
    fi
    if [[ "$missing" -gt 0 ]]; then
        log ERROR "authorized_keys is missing ${missing} declared key(s)"
        rm -f "$declared"
        return 1
    fi
    rm -f "$declared"
    return 0
}

# The key is read before ANY branch — --check needs it too (check_installed
# decrypts authorized_keys.crypted to compare content, and the retired-key
# drift probe decrypts id_rsa.crypted). Production callers feed it on
# stdin (RUNBOOK.md §9); --key remains accepted for backward compat.
if [[ -z "$KEY" ]]; then
    if [[ ! -t 0 ]]; then
        KEY="$(cat)"
    fi
    if [[ -z "$KEY" ]]; then
        log ERROR "--key <FILE_CRYPTO_KEY> required (or pipe it via stdin)"
        exit 2
    fi
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if check_installed; then
        log INFO "ssh-admin already installed"
        exit 0
    fi
    log INFO "ssh-admin not fully installed"
    exit 1
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
