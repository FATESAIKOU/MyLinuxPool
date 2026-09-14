#!/usr/bin/env bash
# gateway/provision.sh — spec: docs/POOL_RUNTIME_SPEC.md §9.2
# Runs on a freshly cloud-init'd Gateway, as root, driven by Actions after
# the bundle (static_normal_files + decrypted static_secret_files) has
# already been scp'd into place. Idempotent — safe to re-run.

set -euo pipefail

WORKERS_DIR="/home/fatesaikou/pool/workers.d"
SSHD_CONF="/etc/ssh/sshd_config.d/10-mylinuxpool.conf"
FAIL2BAN_CONF="/etc/fail2ban/jail.d/mylinuxpool-ignore.conf"
BUNDLE_USERS=(fatesaikou sshproxy)

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

if [[ "$(id -u)" -ne 0 ]]; then
    log ERROR "provision.sh must run as root"
    exit 1
fi

# ---- step 1: sshd hardening --------------------------------------------------
# The current (pre-rotate) Gateway is still PasswordAuthentication yes —
# that's an existing weakness this rewrite is meant to close, not carry
# forward.
step1_sshd_harden() {
    log INFO "step 1/6: sshd hardening (key-only auth)"

    local desired
    desired="$(cat <<'EOF'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
EOF
)"

    if [[ -f "$SSHD_CONF" ]] && [[ "$(cat "$SSHD_CONF")" == "$desired" ]]; then
        log INFO "${SSHD_CONF} already up to date, skipping"
        return 0
    fi

    printf '%s\n' "$desired" > "$SSHD_CONF"

    if ! sshd -t; then
        log ERROR "sshd -t failed after writing ${SSHD_CONF}, reverting"
        rm -f "$SSHD_CONF"
        exit 1
    fi

    # Ubuntu 24.04 ships ssh.socket by default; ssh.service only shows up
    # once something connects. Reload is best-effort — a config this
    # already-validated takes effect on the next socket-activated spawn
    # regardless.
    systemctl reload ssh 2>/dev/null || log WARN "could not reload ssh.service (likely socket-activated and not yet running) — new config still applies on next connection"

    log INFO "wrote ${SSHD_CONF}"
}

# ---- step 2: fail2ban ignoreip -----------------------------------------------
# DO NOT SKIP OR SIMPLIFY THIS STEP. The 2026-09-13 incident (RUNBOOK.md
# §7.1) was fail2ban silently banning the home IP for 45 minutes — the
# ignoreip rule only existed on the machine that got rotated away.
# Without this step every rotate reintroduces the same lockout.
step2_fail2ban_ignoreip() {
    log INFO "step 2/6: fail2ban ignoreip (critical — see RUNBOOK.md §7.1, do not skip)"

    if [[ -z "${POOL_TRUSTED_IPS:-}" ]]; then
        log ERROR "POOL_TRUSTED_IPS is not set in the environment"
        log ERROR "refusing to provision without it — this is exactly the gap that caused the 45-minute lockout"
        exit 2
    fi

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        log ERROR "fail2ban is not installed — writing an ignoreip rule for it would be meaningless"
        log ERROR "this is exactly the gap that caused the 2026-09-13 45-minute lockout: no fail2ban means no ignoreip means no rescue path if the home IP gets banned"
        log ERROR "cloud-init must finish installing fail2ban before provision.sh runs — see rotate-gateway.yml's cloud-init wait step"
        exit 1
    fi

    # Don't assume the directory survived cloud-init's package install —
    # provision.sh has been run against a still-provisioning box before.
    mkdir -p "$(dirname "$FAIL2BAN_CONF")"

    local desired
    desired="$(printf '[DEFAULT]\nignoreip = %s\n' "$POOL_TRUSTED_IPS")"

    if [[ -f "$FAIL2BAN_CONF" ]] && [[ "$(cat "$FAIL2BAN_CONF")" == "$desired" ]]; then
        log INFO "${FAIL2BAN_CONF} already up to date, skipping"
        return 0
    fi

    printf '%s' "$desired" > "$FAIL2BAN_CONF"
    systemctl restart fail2ban
    log INFO "wrote ${FAIL2BAN_CONF} and restarted fail2ban"
}

# ---- step 3: fix ownership/permissions on the scp'd bundle -------------------
# The current Gateway has /home/sshproxy/.ssh/id_rsa at 644 — a
# world-readable private key. Root-owned scp drops files owned by root
# with whatever mode the sender had; both must be corrected here, every
# time, for both bundle users.
fix_user_perms() {
    local user="$1" home
    home="$(getent passwd "$user" | cut -d: -f6 || true)"

    if [[ -z "$home" || ! -d "$home" ]]; then
        log WARN "user '${user}' has no home directory yet, skipping permission fixup"
        return 0
    fi

    chown -R "${user}:${user}" "$home"

    if [[ -d "${home}/.ssh" ]]; then
        chmod 700 "${home}/.ssh"

        # Private keys: id_rsa, id_pool, id_ed25519, ... but never *.pub.
        find "${home}/.ssh" -maxdepth 1 -type f \
            \( -name 'id_rsa' -o -name 'id_pool' -o -name 'id_*' \) ! -name '*.pub' \
            -exec chmod 600 {} +

        find "${home}/.ssh" -maxdepth 1 -type f \
            \( -name '*.pub' -o -name 'authorized_keys' \) \
            -exec chmod 644 {} +
    fi

    log INFO "fixed ownership/permissions under ${home}"
}

step3_fix_permissions() {
    log INFO "step 3/6: fix bundle file ownership/permissions"
    local user
    for user in "${BUNDLE_USERS[@]}"; do
        fix_user_perms "$user"
    done
}

# ---- step 4: install runtime --------------------------------------------------
step4_install_runtime() {
    log INFO "step 4/6: install runtime (docker.io, rclone, gh)"

    local pkgs=()
    command -v docker >/dev/null 2>&1 || pkgs+=(docker.io)
    command -v rclone >/dev/null 2>&1 || pkgs+=(rclone)
    # gh via apt is fine here — the Gateway never runs pool-resolve, so its
    # version isn't constrained the way a provider's is.
    command -v gh >/dev/null 2>&1 || pkgs+=(gh)

    if (( ${#pkgs[@]} > 0 )); then
        log INFO "installing missing packages: ${pkgs[*]}"
        apt-get update -y
        apt-get install -y "${pkgs[@]}"
    else
        log INFO "all runtime packages already present"
    fi
}

# ---- step 5: worker port ledger directory ------------------------------------
step5_workers_dir() {
    log INFO "step 5/6: create ${WORKERS_DIR}"
    mkdir -p "$WORKERS_DIR"
    chown -R fatesaikou:fatesaikou "$(dirname "$WORKERS_DIR")"
    log INFO "ensured ${WORKERS_DIR}"
}

# ---- step 6: verify -----------------------------------------------------------
step6_verify() {
    log INFO "step 6/6: verify"

    if ! sshd -t; then
        log ERROR "sshd -t failed"
        exit 1
    fi

    if ! systemctl is-active --quiet fail2ban; then
        log ERROR "fail2ban is not active"
        exit 1
    fi

    local missing=() bin
    for bin in nc flock ss jq; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if (( ${#missing[@]} > 0 )); then
        log ERROR "missing required tools: ${missing[*]}"
        exit 1
    fi

    log INFO "all checks passed: sshd config valid, fail2ban active, nc/flock/ss/jq present"
}

main() {
    step1_sshd_harden
    step2_fail2ban_ignoreip
    step3_fix_permissions
    step4_install_runtime
    step5_workers_dir
    step6_verify
    log INFO "provisioning complete"
}

main
