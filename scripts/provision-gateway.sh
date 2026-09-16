#!/usr/bin/env bash
# scripts/provision-gateway.sh — spec: docs/POOL_RUNTIME_SPEC.md §9.2, docs/LAYOUT.md
#
# Runs on a freshly cloud-init'd Gateway, as root, driven by Actions AFTER
# shared-configs/ has already been scp'd to
# /home/fatesaikou/.mylinuxpool/repo/shared-configs (see rotate-gateway.yml's
# bundle-deploy step — it no longer decrypts/flattens files itself; that
# now happens per-unit, right here, so each unit's install.sh can find its
# own co-located files/). Idempotent — safe to re-run.
#
# FILE_CRYPTO_KEY arrives on STDIN, read exactly once at startup (the
# caller pipes it: `printf '%s' "$key" | ssh host 'sudo env ... bash <this>'`).
# It is never written to disk or logged here. Units that need the key get
# it on their own stdin via `printf '%s' ... | "$install" ...` — never as
# `--key <value>`, which would land the value in this process's argv
# (readable by every user via ps). Why stdin and not an environment
# variable: env is visible in /proc/PID/environ to the same user and root
# only — already better than argv — but stdin leaves nothing behind at
# all, not even a process-memory-adjacent artifact. POOL_TRUSTED_IPS is
# not a secret and stays an environment variable.

set -euo pipefail

REPO_DIR="/home/fatesaikou/.mylinuxpool/repo"
SHARED_CONFIG_DIR="${REPO_DIR}/shared-configs"
WORKERS_DIR="/home/fatesaikou/.mylinuxpool/workers.d"
SSHD_CONF="/etc/ssh/sshd_config.d/10-mylinuxpool.conf"
FAIL2BAN_CONF="/etc/fail2ban/jail.d/mylinuxpool-ignore.conf"

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
    log ERROR "provision-gateway.sh must run as root"
    exit 1
fi

# The key arrives on stdin, read ONCE up front — `$(cat)` consumes the
# whole stream, so reading it again later (in a loop, say) would get
# nothing. This must be the FIRST stdin read in the script.
FILE_CRYPTO_KEY="$(cat)"
if [[ -z "$FILE_CRYPTO_KEY" ]]; then
    log ERROR "no FILE_CRYPTO_KEY on stdin — the caller must pipe it (see RUNBOOK.md §9)"
    exit 2
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

# Reap sessions whose peer has vanished. Without this, sshd's default
# (ClientAliveInterval 0, plus TCP keepalive that waits ~2 hours) means a
# provider that loses its network without closing the connection leaves a
# session holding its forwarded port open indefinitely. When the machine
# comes back, `-R 127.0.0.1:<port>` is refused by the port its own dead
# session still owns, ExitOnForwardFailure kills the attempt, and the node
# retries forever against a port nothing will release.
#
# Seen for real on 2026-09-14: a physical network cut left three ports
# held by dead sessions; only the provider whose old session happened to
# close cleanly came back. 15s x 3 puts the ceiling at ~45 seconds, well
# inside pool-tunnel's own retry backoff.
ClientAliveInterval 15
ClientAliveCountMax 3
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
        log ERROR "cloud-init must finish installing fail2ban before provision-gateway.sh runs — see rotate-gateway.yml's cloud-init wait step"
        exit 1
    fi

    # Don't assume the directory survived cloud-init's package install —
    # provision-gateway.sh has been run against a still-provisioning box before.
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

# ---- step 3: install shared_config units -------------------------------------
# Each unit's own install.sh owns its files' ownership/permissions now —
# this replaces the old blanket "chown -R the whole home dir" sweep that
# used to live here (spec §9.2's original step 3), which is exactly the
# "installed elsewhere, disconnected from the files" problem LAYOUT.md's
# rationale describes.
#
# No sshproxy unit any more: KEY-DESIGN §8 deleted the static encrypted
# bundles (ssh-tunnel-server) — sshproxy's authorized_keys is assembled
# from the repo variables and installed by refresh/rotate, never by a
# unit.
step3_install_shared_config() {
    log INFO "step 3/6: install shared_config units"

    if [[ ! -d "$SHARED_CONFIG_DIR" ]]; then
        log ERROR "${SHARED_CONFIG_DIR} not found — did the bundle deploy step scp shared-configs/ here?"
        exit 1
    fi

    if [[ -z "$FILE_CRYPTO_KEY" ]]; then
        log ERROR "FILE_CRYPTO_KEY is empty — it must arrive on stdin, piped by the caller (see RUNBOOK.md §9)"
        exit 2
    fi

    local unit home target_user install

    for unit in pool-runtime rclone standalonescripts dotfiles gh; do
        home="/home/fatesaikou"
        target_user="fatesaikou"
        install="${SHARED_CONFIG_DIR}/${unit}/install.sh"
        if [[ ! -x "$install" ]]; then
            log ERROR "${install} missing or not executable"
            exit 1
        fi
        log INFO "installing unit '${unit}' for ${target_user}"
        # Key on the unit's stdin, never --key: a value on argv is visible
        # to every user via ps (RUNBOOK.md §9).
        printf '%s' "$FILE_CRYPTO_KEY" | "$install" --home "$home" --user "$target_user"
    done
}

# ---- step 4: remaining runtime packages --------------------------------------
# Everything else (rclone, gh) is now a shared_config unit and installs
# itself; docker.io has no unit of its own yet, so it's still installed
# directly here.
step4_install_runtime() {
    log INFO "step 4/6: install remaining runtime (docker.io)"

    if command -v docker >/dev/null 2>&1; then
        log INFO "docker already present"
        return 0
    fi

    log INFO "installing docker.io"
    apt-get update -y
    apt-get install -y docker.io
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

    if ! "${SHARED_CONFIG_DIR}/pool-runtime/install.sh" --check --home /home/fatesaikou --user fatesaikou; then
        log ERROR "pool-runtime unit failed its own --check"
        exit 1
    fi

    log INFO "all checks passed: sshd config valid, fail2ban active, nc/flock/ss/jq present, pool-runtime installed"
}

main() {
    step1_sshd_harden
    step2_fail2ban_ignoreip
    step3_install_shared_config
    step4_install_runtime
    step5_workers_dir
    step6_verify
    log INFO "provisioning complete"
}

main
