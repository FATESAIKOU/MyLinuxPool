#!/usr/bin/env bash
# provider/register.sh — spec: docs/POOL_RUNTIME_SPEC.md §4
# RegisterProvider: run once, by hand, on a brand-new provider machine.
# Idempotent — safe to re-run (e.g. after a GH_POOL_TOKEN rotation).

set -euo pipefail

REPO="FATESAIKOU/MyLinuxPool"
STATE_DIR="${HOME}/.mylinuxpool"
REPO_DIR="${STATE_DIR}/repo"
BIN_DIR="${STATE_DIR}/bin"
SSH_DIR="${HOME}/.ssh"
PRIVATE_KEY="${SSH_DIR}/id_pool"

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
    echo "usage: register.sh --name <node-name> --gateway-port <port> [--role provider] [--branch <name>] [--no-sudo]" >&2
    echo "  --branch defaults to 'master'; point it at a dev branch while pool/ is still unmerged" >&2
    echo "  --no-sudo: no root anywhere — user-level jq/gh install, skip sudoers/poweroff support" >&2
    echo "             (use when the account's sudo password is unknown/unavailable, e.g. fh-proxy)" >&2
}

NAME=""
GATEWAY_PORT=""
ROLE="provider"
BRANCH="master"
NO_SUDO=0
LOCAL_BIN="${HOME}/.local/bin"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            NAME="$2"; shift 2 ;;
        --gateway-port)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            GATEWAY_PORT="$2"; shift 2 ;;
        --role)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            ROLE="$2"; shift 2 ;;
        --branch)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            BRANCH="$2"; shift 2 ;;
        --no-sudo)
            NO_SUDO=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            log ERROR "unknown argument: $1"
            usage
            exit 2 ;;
    esac
done

if [[ -z "$NAME" || -z "$GATEWAY_PORT" ]]; then
    usage
    exit 2
fi

if ! [[ "$GATEWAY_PORT" =~ ^[0-9]+$ ]]; then
    log ERROR "--gateway-port must be a positive integer, got '${GATEWAY_PORT}'"
    exit 2
fi

if [[ -z "${FILE_CRYPTO_KEY:-}" || -z "${GH_POOL_TOKEN:-}" ]]; then
    log ERROR "FILE_CRYPTO_KEY and GH_POOL_TOKEN must both be set in the environment"
    exit 2
fi

VAR_NAME="NODE_$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"

arch_suffix() {
    case "$(uname -m)" in
        x86_64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) uname -m ;;
    esac
}

# Idempotently make sure ~/.local/bin is on PATH for future interactive
# shells. This is purely for human convenience (running gh/jq by hand) —
# pool-tunnel.service gets its own PATH via step8_systemd, since systemd
# --user services don't source ~/.bashrc.
ensure_local_bin_in_path() {
    mkdir -p "$LOCAL_BIN"
    local line='export PATH="$HOME/.local/bin:$PATH"'
    local rcfile="${HOME}/.bashrc"
    if ! grep -qF "$line" "$rcfile" 2>/dev/null; then
        printf '\n# added by MyLinuxPool provider/register.sh --no-sudo\n%s\n' "$line" >> "$rcfile"
        log INFO "added ~/.local/bin to PATH in ${rcfile} (new shells only; current one is patched below)"
    fi
    case ":$PATH:" in
        *":${LOCAL_BIN}:"*) ;;
        *) export PATH="${LOCAL_BIN}:${PATH}" ;;
    esac
}

# Static jq binary from GitHub releases — no root needed, no package manager.
install_user_jq() {
    if command -v jq >/dev/null 2>&1; then
        log INFO "jq already present"
        return 0
    fi
    local arch url
    arch="$(arch_suffix)"
    url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-${arch}"
    log INFO "installing jq to ${LOCAL_BIN} (user-level, from ${url})"
    curl -fsSL "$url" -o "${LOCAL_BIN}/jq"
    chmod +x "${LOCAL_BIN}/jq"
    log INFO "installed jq to ${LOCAL_BIN}/jq"
}

# gh's release tarball, extracted to ~/.local/bin — no root, no apt repo.
# Needs jq (installed just above) to read the "latest" tag off the API.
install_user_gh() {
    if command -v gh >/dev/null 2>&1; then
        log INFO "gh already present"
        return 0
    fi

    local arch version url tmp_dir
    arch="$(arch_suffix)"
    version="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name // empty')"
    version="${version#v}"
    if [[ -z "$version" ]]; then
        log ERROR "could not determine latest gh release version from the GitHub API"
        exit 1
    fi

    url="https://github.com/cli/cli/releases/download/v${version}/gh_${version}_linux_${arch}.tar.gz"
    log INFO "installing gh ${version} to ${LOCAL_BIN} (user-level, from ${url})"
    tmp_dir="$(mktemp -d)"
    curl -fsSL "$url" -o "${tmp_dir}/gh.tar.gz"
    tar -xzf "${tmp_dir}/gh.tar.gz" -C "$tmp_dir"
    cp -f "${tmp_dir}/gh_${version}_linux_${arch}/bin/gh" "${LOCAL_BIN}/gh"
    chmod +x "${LOCAL_BIN}/gh"
    rm -rf "$tmp_dir"
    log INFO "installed gh ${version} to ${LOCAL_BIN}/gh"
}

# ---- step 1: preflight -----------------------------------------------------
step1_preflight() {
    log INFO "step 1/9: preflight checks"

    command -v bash >/dev/null 2>&1 || { log ERROR "bash not found"; exit 1; }

    if ! systemctl --user status >/dev/null 2>&1; then
        log ERROR "'systemctl --user' is not usable on this host"
        exit 1
    fi

    if ! curl -fsS --max-time 5 https://github.com >/dev/null 2>&1; then
        log ERROR "no network connectivity to github.com"
        exit 1
    fi

    if [[ "$NO_SUDO" -eq 1 ]]; then
        step1_preflight_no_sudo
    else
        step1_preflight_sudo
    fi
}

step1_preflight_sudo() {
    local pkgs=()
    command -v rclone >/dev/null 2>&1 || pkgs+=(rclone)
    command -v git >/dev/null 2>&1 || pkgs+=(git)
    command -v gh >/dev/null 2>&1 || pkgs+=(gh)
    command -v docker >/dev/null 2>&1 || pkgs+=(docker.io)
    dpkg -s openssh-server >/dev/null 2>&1 || pkgs+=(openssh-server)

    if (( ${#pkgs[@]} > 0 )); then
        log INFO "installing missing packages: ${pkgs[*]}"
        sudo apt-get update -y
        sudo apt-get install -y "${pkgs[@]}"
    else
        log INFO "all required packages already present"
    fi
}

# --no-sudo: only jq/gh have a viable no-root install path (a static
# binary / a plain tarball). git, docker and openssh-server genuinely need
# root to install on Ubuntu — if they're missing here, fail loudly with
# instructions rather than pretend registration can proceed without them.
# rclone is skipped outright: providers never call it, only the Gateway's
# dlpw/uppw do.
step1_preflight_no_sudo() {
    log INFO "--no-sudo: user-level installs only, no apt/sudo will be used"

    ensure_local_bin_in_path

    local missing_root_pkg=0
    if ! command -v git >/dev/null 2>&1; then
        log ERROR "git is missing; --no-sudo cannot install it without root"
        missing_root_pkg=1
    fi
    if ! command -v docker >/dev/null 2>&1; then
        log ERROR "docker is missing; --no-sudo cannot install it without root"
        missing_root_pkg=1
    fi
    if ! dpkg -s openssh-server >/dev/null 2>&1; then
        log ERROR "openssh-server is missing; --no-sudo cannot install it without root"
        missing_root_pkg=1
    fi
    if [[ "$missing_root_pkg" -eq 1 ]]; then
        log ERROR "ask an admin to install the missing package(s) above (e.g. sudo apt-get install <pkg>), then re-run with --no-sudo"
        exit 1
    fi

    if command -v rclone >/dev/null 2>&1; then
        log INFO "rclone already present"
    else
        log INFO "skipping rclone: providers don't need it (only the Gateway's dlpw/uppw do)"
    fi

    install_user_jq
    install_user_gh
}

# ---- step 2: gh auth --------------------------------------------------------
step2_gh_auth() {
    log INFO "step 2/9: gh auth login"

    if gh auth status >/dev/null 2>&1; then
        log INFO "gh already authenticated, skipping"
        return 0
    fi

    # GH_POOL_TOKEN goes in over stdin, never as a CLI argument (spec §7).
    printf '%s' "$GH_POOL_TOKEN" | gh auth login --with-token
    log INFO "gh auth login completed"
}

# ---- step 3: fetch runtime ---------------------------------------------------
step3_fetch_runtime() {
    log INFO "step 3/9: fetch runtime (clone/pull repo, install pool/bin)"

    mkdir -p "$STATE_DIR"

    if [[ -d "${REPO_DIR}/.git" ]]; then
        local current_branch
        current_branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
        if [[ "$current_branch" != "$BRANCH" ]]; then
            log INFO "repo at ${REPO_DIR} is on '${current_branch}', switching to '${BRANCH}'"
            git -C "$REPO_DIR" fetch origin "$BRANCH"
            git -C "$REPO_DIR" checkout "$BRANCH"
        fi
        log INFO "repo already present at ${REPO_DIR}, pulling latest ${BRANCH}"
        git -C "$REPO_DIR" pull --ff-only
    else
        log INFO "cloning repo into ${REPO_DIR} (branch ${BRANCH})"
        gh repo clone "$REPO" "$REPO_DIR" -- --branch "$BRANCH"
    fi

    mkdir -p "$BIN_DIR"
    cp -f "${REPO_DIR}"/pool/bin/* "${BIN_DIR}/"
    chmod +x "${BIN_DIR}"/*
    log INFO "installed pool/bin/* into ${BIN_DIR}"
}

# ---- step 4: shared sshproxy key --------------------------------------------
step4_key() {
    log INFO "step 4/9: sshproxy private key"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    if [[ -f "$PRIVATE_KEY" ]]; then
        log INFO "${PRIVATE_KEY} already present, skipping decrypt"
        chmod 600 "$PRIVATE_KEY"
        return 0
    fi

    local crypted="${REPO_DIR}/static_secret_files/home/sshproxy/.ssh/id_rsa.crypted"
    if [[ ! -f "$crypted" ]]; then
        log ERROR "encrypted shared key not found at ${crypted}"
        exit 1
    fi

    # decryptStdin.sh's interface takes the key as argv[1] (existing repo
    # convention, see RUNBOOK.md §3.3) — not something this script invents.
    "${REPO_DIR}/scripts/decryptStdin.sh" "$FILE_CRYPTO_KEY" \
        < "$crypted" > "$PRIVATE_KEY"
    chmod 600 "$PRIVATE_KEY"
    log INFO "decrypted shared sshproxy key to ${PRIVATE_KEY}"
}

# ---- step 5: local identity --------------------------------------------------
step5_config() {
    log INFO "step 5/9: write local identity config"
    mkdir -p "$STATE_DIR"
    printf 'NODE_NAME=%s\n' "$NAME" > "${STATE_DIR}/config"
    log INFO "wrote NODE_NAME=${NAME} to ${STATE_DIR}/config"
}

# ---- step 6: register NODE_<NAME> var (deep-merge, never clobber) ----------
step6_register_var() {
    log INFO "step 6/9: register ${VAR_NAME} (merge with existing if present)"

    # `gh variable get` doesn't exist on gh 2.45.0 (fh-l's apt version) —
    # `gh api` has always existed and is equivalent.
    local existing_json
    if existing_json="$(gh api "repos/${REPO}/actions/variables/${VAR_NAME}" --jq .value 2>/dev/null)" \
        && printf '%s' "$existing_json" | jq empty >/dev/null 2>&1; then
        log INFO "existing ${VAR_NAME} found, deep-merging"
    else
        existing_json='{}'
        log INFO "no existing ${VAR_NAME}, creating new"
    fi

    local self_user key_secret hops_json merged
    self_user="${USER:-$(whoami)}"
    key_secret="SSH_KEY_$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"

    hops_json="$(jq -n \
        --argjson port "$GATEWAY_PORT" \
        --arg user "$self_user" \
        --arg key_secret "$key_secret" \
        '[{via: "gateway"}, {host: "127.0.0.1", port: $port, user: $user, key_secret: $key_secret}]')"

    # $existing merged with the fresh connectivity fields on top; anything
    # this script doesn't own (e.g. "power") passes through untouched, and
    # "capabilities" is only defaulted the first time, never overwritten.
    merged="$(jq -n \
        --argjson existing "$existing_json" \
        --arg name "$NAME" \
        --arg role "$ROLE" \
        --arg user "$self_user" \
        --arg key_secret "$key_secret" \
        --argjson gateway_port "$GATEWAY_PORT" \
        --argjson hops "$hops_json" \
        '$existing * {
            name: $name,
            role: $role,
            user: $user,
            key_secret: $key_secret,
            gateway_port: $gateway_port,
            hops: $hops,
            capabilities: ($existing.capabilities // ["docker", "worker-host"])
        }')"

    # No --body-file on gh 2.45.0 — `gh variable set` reads the body from
    # stdin when --body/-b is omitted, which works on old and new gh alike.
    printf '%s' "$merged" | gh variable set "$VAR_NAME" --repo "$REPO"
    log INFO "wrote ${VAR_NAME}"
}

# ---- step 7: narrow sudoers rule ---------------------------------------------
step7_sudoers() {
    log INFO "step 7/9: sudoers rule for poweroff/ethtool (needs your sudo password)"

    if [[ "$NO_SUDO" -eq 1 ]]; then
        log INFO "--no-sudo: skipping sudoers rule — this host cannot do 'sudo systemctl poweroff' remotely"
        log INFO "Shutdown-Fh-l-style power control doesn't apply here; an always-on provider like fh-proxy doesn't need it anyway"
        return 0
    fi

    local target="/etc/sudoers.d/mylinuxpool"
    local rule="$(whoami) ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/sbin/ethtool"

    if [[ -f "$target" ]] && sudo grep -qF "$rule" "$target" 2>/dev/null; then
        log INFO "sudoers rule already present, skipping"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "$rule" > "$tmp"

    if ! sudo visudo -c -f "$tmp" >/dev/null 2>&1; then
        log ERROR "generated sudoers rule failed 'visudo -c' validation, aborting without touching ${target}"
        rm -f "$tmp"
        exit 1
    fi

    sudo install -o root -g root -m 440 "$tmp" "$target"
    rm -f "$tmp"
    log INFO "installed ${target}"
}

# ---- step 8: systemd user service + linger -----------------------------------

# systemd --user services get a minimal default PATH that does not include
# ~/.local/bin — under --no-sudo, pool-resolve/pool-tunnel would silently
# fail to find jq/gh there. Patch the *installed* unit only, idempotently;
# the copy in the repo is left untouched.
patch_unit_path_for_no_sudo() {
    local unit_dst="$1"
    local path_line="Environment=PATH=${LOCAL_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    if grep -qF "$path_line" "$unit_dst"; then
        return 0
    fi

    awk -v line="$path_line" '
        {print}
        /^\[Service\]/ && !added {print line; added=1}
    ' "$unit_dst" > "${unit_dst}.tmp" && mv "${unit_dst}.tmp" "$unit_dst"
    log INFO "added ~/.local/bin to pool-tunnel.service's PATH (--no-sudo)"
}

# `loginctl enable-linger` normally needs root. Under --no-sudo we try it
# bare first (some newer systemd/polkit setups let a user linger themselves)
# and only fail loudly if that doesn't work — we don't silently pretend it
# succeeded, since without linger the tunnel dies the moment you log out.
enable_linger() {
    local who linger
    who="$(whoami)"
    linger="$(loginctl show-user "$who" -p Linger --value 2>/dev/null || echo "")"
    if [[ "$linger" == "yes" ]]; then
        log INFO "linger already enabled"
        return 0
    fi

    if [[ "$NO_SUDO" -eq 1 ]]; then
        if loginctl enable-linger "$who" >/dev/null 2>&1; then
            log INFO "enabled linger for ${who} (no root needed on this host's systemd)"
            return 0
        fi
        log ERROR "could not enable linger for ${who} without root"
        log ERROR "this one step still needs an admin to run once: sudo loginctl enable-linger ${who}"
        log ERROR "without it, pool-tunnel stops the moment you log out of this session"
        exit 1
    fi

    sudo loginctl enable-linger "$who"
    log INFO "enabled linger for ${who}"
}

step8_systemd() {
    log INFO "step 8/9: install pool-tunnel.service and enable linger"

    local unit_src="${REPO_DIR}/pool/systemd/pool-tunnel.service"
    local unit_dst_dir="${HOME}/.config/systemd/user"
    local unit_dst="${unit_dst_dir}/pool-tunnel.service"

    mkdir -p "$unit_dst_dir"
    cp -f "$unit_src" "$unit_dst"

    if [[ "$NO_SUDO" -eq 1 ]]; then
        patch_unit_path_for_no_sudo "$unit_dst"
    fi

    systemctl --user daemon-reload
    systemctl --user enable --now pool-tunnel.service

    enable_linger
}

# ---- step 9: verify from the Gateway side ------------------------------------
step9_verify() {
    log INFO "step 9/9: verifying tunnel from the gateway side"

    local gw_json gw_ip gw_user
    gw_json="$("${BIN_DIR}/pool-resolve" gateway)" || {
        log ERROR "pool-resolve gateway failed, cannot verify"
        exit 1
    }
    gw_ip="$(printf '%s' "$gw_json" | jq -r '.ip')"
    gw_user="$(printf '%s' "$gw_json" | jq -r '.tunnel_user')"

    local tries=0 max_tries=30 ok=0 banner
    while (( tries < max_tries )); do
        banner="$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 \
            -i "$PRIVATE_KEY" "${gw_user}@${gw_ip}" \
            "timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/${GATEWAY_PORT} && head -c 4 <&3' 2>/dev/null" \
            2>/dev/null || true)"
        if [[ "$banner" == SSH-* ]]; then
            ok=1
            break
        fi
        tries=$((tries + 1))
        sleep 2
    done

    if [[ "$ok" -ne 1 ]]; then
        log ERROR "could not read an SSH banner on gateway 127.0.0.1:${GATEWAY_PORT} after ${max_tries} tries"
        log ERROR "diagnose with: systemctl --user status pool-tunnel; journalctl --user -u pool-tunnel -n 50 --no-pager"
        exit 1
    fi

    log INFO "verified: gateway sees an SSH banner on 127.0.0.1:${GATEWAY_PORT}"
}

main() {
    step1_preflight
    step2_gh_auth
    step3_fetch_runtime
    step4_key
    step5_config
    step6_register_var
    step7_sudoers
    step8_systemd
    step9_verify
    log INFO "registration complete for node '${NAME}' (gateway_port=${GATEWAY_PORT})"
}

main
