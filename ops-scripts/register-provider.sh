#!/usr/bin/env bash
# ops-scripts/register-provider.sh — spec: docs/POOL_RUNTIME_SPEC.md §4
# RegisterProvider: run once, by hand, on a brand-new provider machine.
# Idempotent — safe to re-run (e.g. after a GH_POOL_TOKEN rotation).

set -euo pipefail

REPO="FATESAIKOU/MyLinuxPool"
STATE_DIR="${HOME}/.mylinuxpool"
# The repo is cloned into a TEMPORARY directory and deleted on every exit
# path (see the trap below): declarations live on GitHub alone, and a
# provider keeps only derived artifacts (REDESIGN N7 / task E). Do not
# point this back at a persistent path — the old persistent clone was the
# second copy of truth that silently drifted out of date.
REPO_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mlp-register.XXXXXX" 2>/dev/null)" || {
    echo "register-provider: could not create temporary working directory" >&2
    exit 1
}
# Every exit path — success, failure, interrupt — removes the temp clone.
# The credential helper's token FILE is untouched (that is the provider's
# credential, not a declaration).
trap 'rm -rf "$REPO_DIR"' EXIT INT TERM
BIN_DIR="${STATE_DIR}/bin"
SSH_DIR="${HOME}/.ssh"
# Which file holds the tunnel key is NOT decided here — tunnel-identity.sh
# is the one definition (RUNBOOK §7.12). This used to say
# "${SSH_DIR}/id_pool", the shared key deleted in KEY-DESIGN §8, so step 9
# verified with a key that no longer existed and always failed.
# TUNNEL_KEY is resolved in step 6.5, once the repo clone exists.
GH_TOKEN_FILE="${STATE_DIR}/gh_token"

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

# FILE_CRYPTO_KEY is deliberately NOT required: since KEY-DESIGN §8 the
# provider profile installs only pool-runtime and gh, both needs_key=false.
# Registering a machine, like adding a person, no longer touches that key —
# it now guards nothing but the Gateway's rclone/dotfiles/standalonescripts.
if [[ -z "${GH_POOL_TOKEN:-}" ]]; then
    log ERROR "GH_POOL_TOKEN must be set in the environment"
    exit 2
fi

VAR_NAME="NODE_$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"

# --no-sudo selects the matching provider profile — it's the one axis
# these two variants actually differ on today (see profiles/provider/*/
# profile.json: same shared_config units either way, no-sudo just
# declares an empty sudoers_rules). Which units to install, and which
# non-unit things (systemd --user services, linger, sudoers) this role
# needs, are read from that profile from here on — not hardcoded per step
# (2026-09-15: profiles/provider/ didn't exist at all before this; every
# provider's actual requirements only lived as inline logic in this file).
PROFILE_NAME="default"
[[ "$NO_SUDO" -eq 1 ]] && PROFILE_NAME="no-sudo"
PROFILE_JSON="${REPO_DIR}/profiles/provider/${PROFILE_NAME}/profile.json"

arch_suffix() {
    case "$(uname -m)" in
        x86_64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) uname -m ;;
    esac
}

# Confirms sudo actually works BEFORE any real sudo call, so a later
# failure is never misattributed to whatever that call happened to be
# (2026-09-14 incident: `sudo visudo` failed for lack of a usable
# credential, but the error pointed at visudo itself). `-n` never
# prompts, so a cached ticket is detected instantly with no risk of
# hanging; only when that's absent, and only if stdin is a real TTY
# sudo could actually prompt on, do we let it try once interactively.
ensure_sudo() {
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    if [[ -t 0 ]] && sudo -v; then
        return 0
    fi
    return 1
}

# Idempotently make sure ~/.local/bin is on PATH for future interactive
# shells. This is purely for human convenience (running gh/jq by hand) —
# the systemd --user services carry their own PATH in their DECLARED unit
# files (files/pool-tunnel.service, files/pool-sync.service), because they
# don't source ~/.bashrc and because anything this script patched into an
# installed unit afterwards would be reverted by pool-sync (RUNBOOK §7.11).
ensure_local_bin_in_path() {
    mkdir -p "$LOCAL_BIN"
    local line='export PATH="$HOME/.local/bin:$PATH"'
    local rcfile="${HOME}/.bashrc"
    if ! grep -qF "$line" "$rcfile" 2>/dev/null; then
        printf '\n# added by MyLinuxPool ops-scripts/register-provider.sh --no-sudo\n%s\n' "$line" >> "$rcfile"
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

# tcp_probe <host> <port> <timeout_secs> — connectivity check.
#   Returns 0 reachable, 1 unreachable, 3 cannot-even-check. Uses curl when
#   present (it honors proxies, raw TCP cannot), else bash's own /dev/tcp
#   bounded by timeout. Never a package this script installs later: curl is
#   only USED when already present (its absence changes nothing — the old
#   check ran bare curl, which exited 127 when missing and got misreported
#   as "no network"), and where curl is absent timeout is guaranteed
#   (coreutils is Essential; macOS always ships curl, so the bare /dev/tcp
#   branch only runs where timeout exists). Tool-missing (3) and
#   network-down (1) are different answers by construction.
tcp_probe() {
    local host="$1" port="$2" limit="$3"
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time "$limit" "https://${host}" >/dev/null 2>&1
        return $?
    fi
    if command -v timeout >/dev/null 2>&1; then
        if timeout "$limit" bash -c 'exec 3<>/dev/tcp/"$0"/"$1"' "$host" "$port" >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    return 3
}

# ---- step 1: preflight -----------------------------------------------------
step1_preflight() {
    log INFO "step 1/9: preflight checks"

    command -v bash >/dev/null 2>&1 || { log ERROR "bash not found"; exit 1; }

    if ! systemctl --user status >/dev/null 2>&1; then
        log ERROR "'systemctl --user' is not usable on this host"
        exit 1
    fi

    local probe_rc=0
    tcp_probe github.com 443 5 || probe_rc=$?
    if [[ "$probe_rc" -eq 3 ]]; then
        log ERROR "cannot check connectivity: neither curl nor timeout is available on this machine"
        exit 1
    elif [[ "$probe_rc" -ne 0 ]]; then
        log ERROR "no network connectivity to github.com:443"
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
    command -v curl >/dev/null 2>&1 || pkgs+=(curl)
    command -v docker >/dev/null 2>&1 || pkgs+=(docker.io)
    dpkg -s openssh-server >/dev/null 2>&1 || pkgs+=(openssh-server)

    if (( ${#pkgs[@]} == 0 )); then
        log INFO "all required packages already present"
        return 0
    fi

    log INFO "installing missing packages: ${pkgs[*]}"

    if ! ensure_sudo; then
        log ERROR "sudo needs a password but this environment can't provide one (no TTY / no askpass)"
        log ERROR "re-run this from a session with a real TTY, or install manually: sudo apt-get install ${pkgs[*]}"
        exit 1
    fi

    sudo -n apt-get update -y
    sudo -n apt-get install -y "${pkgs[@]}"
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
    # curl is a hard dependency of the user-level jq/gh installs below
    # (install_user_jq/install_user_gh download over HTTPS) — check it here
    # next to git/docker, or a curl-less machine dies inside a download
    # with a message about nothing.
    if ! command -v curl >/dev/null 2>&1; then
        log ERROR "curl is missing; --no-sudo cannot install it without root"
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

# ---- step 2: store gh token --------------------------------------------------
# This duplicates part of shared-configs/gh/install.sh on purpose instead of
# calling it: that unit lives inside REPO_DIR, and REPO_DIR is a temp
# clone that doesn't exist yet on a brand-new provider — `gh repo clone`
# in step 3 needs this very token first. Chicken-and-egg, so this
# bootstrap step stays inline.
#
# `gh auth login --with-token` insists on a `read:org` scope our PAT
# doesn't have and none of our operations (gh api read, gh variable set,
# gh repo clone) need — it just fails with "missing required scope
# 'read:org'". gh honors a bare GH_TOKEN env var with no login step at
# all, so we drop the token in a file for pool-resolve to pick up later
# and export it for the rest of this run.
step2_store_token() {
    log INFO "step 2/9: store gh token + git credential helper"

    mkdir -p "$STATE_DIR"

    local need_write=1
    if [[ -f "$GH_TOKEN_FILE" ]] && [[ "$(cat "$GH_TOKEN_FILE")" == "$GH_POOL_TOKEN" ]]; then
        need_write=0
    fi

    if [[ "$need_write" -eq 1 ]]; then
        printf '%s' "$GH_POOL_TOKEN" > "$GH_TOKEN_FILE"
        log INFO "wrote ${GH_TOKEN_FILE}"
    else
        log INFO "${GH_TOKEN_FILE} already up to date, skipping"
    fi
    chmod 600 "$GH_TOKEN_FILE"

    export GH_TOKEN="$GH_POOL_TOKEN"

    # `gh` reading GH_TOKEN covers pool-resolve, but plain `git` (the
    # shallow clone in step 3) has its own, separate credential story —
    # it doesn't consult GH_TOKEN at all. Without this, git falls back to
    # an interactive username/password prompt, which fails immediately
    # over ssh/non-interactively ("could not read Username ... No such
    # device").
    # 2026-09-14 incident: fh-l happened to keep working across this
    # change only because a *stale* `gh auth login` state was still sitting
    # in ~/.config/gh/hosts.yml from before we switched off it — fh-proxy,
    # registered after the switch, had nothing and failed outright. A
    # global credential helper that reads the token FILE at invocation
    # time (not a static value baked into ~/.gitconfig) fixes both: it
    # doesn't depend on any login state, and re-running this replaces
    # whatever helper (or none) was there before, so a stale machine like
    # fh-l converges to the same setup as a fresh one.
    local cred_helper='!f() { echo username=x-access-token; echo "password=$(cat $HOME/.mylinuxpool/gh_token 2>/dev/null)"; }; f'
    local current_helper
    current_helper="$(git config --global --get credential.https://github.com.helper 2>/dev/null || true)"
    if [[ "$current_helper" == "$cred_helper" ]]; then
        log INFO "git credential helper for github.com already configured"
    else
        git config --global credential.https://github.com.helper "$cred_helper"
        log INFO "configured git credential helper for github.com to read ${GH_TOKEN_FILE}"
    fi
}

# ---- step 3: fetch runtime ---------------------------------------------------
# The repo has to be cloned unconditionally (the profile we're about to
# read lives in it) — but WHICH shared_config units get installed after
# that comes entirely from profiles/provider/<name>/profile.json's
# "shared_config" array, not a list hardcoded here. This is also why "gh"
# is safe to call generically now even though step 2 above handles gh's
# token/credential-helper as an unavoidable inline bootstrap (repo doesn't
# exist yet at step 2) — by this point the repo exists, gh is already on
# PATH (step 1), and re-running the gh unit here is just an idempotent
# no-op confirming the profile's declaration actually holds.
#
# Task E: the clone is always fresh and always shallow, into the temp
# REPO_DIR — never a persistent ~/.mylinuxpool/repo. The old "already
# present, pull" branch is gone because there is nothing to pull: the
# clone dies with the trap at the end of this run.
step3_fetch_runtime() {
    log INFO "step 3/9: fetch runtime (shallow clone into temp ${REPO_DIR}, install profile-declared units)"

    # BIN_DIR is what pool-runtime's own install.sh derives as
    # <home>/.mylinuxpool/bin — kept as our own constant too since step9
    # invokes pool-resolve directly.
    mkdir -p "$STATE_DIR"

    log INFO "cloning ${REPO} into temp ${REPO_DIR} (branch ${BRANCH}, depth 1)"
    gh repo clone "$REPO" "$REPO_DIR" -- --depth 1 --branch "$BRANCH" \
        || { log ERROR "gh repo clone failed — check network and GH_POOL_TOKEN"; exit 1; }

    # Migration: an old run left a persistent clone at ~/.mylinuxpool/repo
    # that this script used to keep pulling forever. It is a second,
    # frozen copy of the declarations — remove it, since truth lives on
    # GitHub alone now.
    if [[ -d "${STATE_DIR}/repo" ]]; then
        rm -rf "${STATE_DIR}/repo"
        log INFO "removed the old persistent clone at ${STATE_DIR}/repo — declarations now live on GitHub alone"
    fi

    if [[ ! -f "$PROFILE_JSON" ]]; then
        log ERROR "no such profile: ${PROFILE_JSON}"
        log ERROR "profiles/provider/{default,no-sudo} should exist on branch '${BRANCH}' — wrong --branch for a dev branch that hasn't merged this yet?"
        exit 1
    fi

    local units unit install
    units="$(jq -r '.shared_config[]' "$PROFILE_JSON")" || {
        log ERROR "could not read .shared_config from ${PROFILE_JSON}"
        exit 1
    }

    for unit in $units; do
        install="${REPO_DIR}/shared-configs/${unit}/install.sh"
        if [[ ! -x "$install" ]]; then
            log ERROR "${install} missing or not executable (declared in ${PROFILE_JSON})"
            exit 1
        fi
        log INFO "installing unit '${unit}' from temp clone ${REPO_DIR} (profiles/provider/${PROFILE_NAME})"
        # No key is piped: every unit a provider installs is
        # needs_key=false since KEY-DESIGN §8 deleted the two that were not.
        # Should a key-bearing unit ever return to this profile, feed it on
        # the unit's STDIN — never --key, because argv is visible to every
        # user via ps (RUNBOOK.md §9).
        "$install" --home "$HOME" --user "$(whoami)" < /dev/null
    done
}

# ---- step 4: local identity --------------------------------------------------
step4_config() {
    log INFO "step 4/9: write local identity config"
    mkdir -p "$STATE_DIR"
    printf 'NODE_NAME=%s\n' "$NAME" > "${STATE_DIR}/config"
    log INFO "wrote NODE_NAME=${NAME} to ${STATE_DIR}/config"
}

# ---- step 5: register NODE_<NAME> var (deep-merge, never clobber) ----------
step5_register_var() {
    log INFO "step 5/9: register ${VAR_NAME} (merge with existing if present)"

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
    # key_secret names an IDENTITY, not a destination — Actions uses the
    # same one key (SSH_KEY_ACTIONS) for management access to every node
    # in the cluster, so every machine's hop points at it too. A per-
    # machine SSH_KEY_<NAME> secret was the 2026-09 design mistake that
    # broke create-worker's 2-hop chains (never provisioned past Gateway's
    # own single hop) — don't reintroduce it.
    key_secret="SSH_KEY_ACTIONS"

    hops_json="$(jq -n \
        --argjson port "$GATEWAY_PORT" \
        --arg user "$self_user" \
        --arg key_secret "$key_secret" \
        '[{via: "gateway"}, {host: "127.0.0.1", port: $port, user: $user, key_secret: $key_secret}]')"

    # capabilities: key -> object, always an object and never null
    # (CAPABILITY-DESIGN.md §1). A pre-existing value is only checked, never
    # rewritten: an object (including unknown keys this script doesn't know)
    # passes through untouched; a legacy array or any non-object is refused
    # here instead of being blended into the new format — migration is a
    # deliberate, reviewable step (`mlp migrate-capabilities`), not a
    # side effect of re-registering.
    if printf '%s' "$existing_json" | jq -e 'has("capabilities")' >/dev/null 2>&1; then
        if ! printf '%s' "$existing_json" | jq -e '.capabilities | type == "object"' >/dev/null 2>&1; then
            log ERROR "${VAR_NAME}.capabilities is not an object — the new contract is key:object (CAPABILITY-DESIGN.md §1)"
            log ERROR "refusing to blend formats; migrate first: mlp migrate-capabilities --real"
            exit 1
        fi
    fi

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
            capabilities: ($existing.capabilities // {"worker-host": {"runtime": "docker"}})
        }')"

    # No --body-file on gh 2.45.0 — `gh variable set` reads the body from
    # stdin when --body/-b is omitted, which works on old and new gh alike.
    printf '%s' "$merged" | gh variable set "$VAR_NAME" --repo "$REPO"
    log INFO "wrote ${VAR_NAME}"
}

# ---- step 6: sudoers rules (profile-declared) --------------------------------
# Which rules (if any) this host gets comes from profiles/provider/<name>/
# profile.json's "sudoers_rules" array, not a NO_SUDO-gated hardcoded
# rule. default declares the poweroff/ethtool rule; no-sudo declares an
# empty list — a host that can't apply sudo rules remotely (no password,
# no TTY to prompt on) simply has a profile that asks for none, so this
# step is a correct, declared no-op there rather than a special case.
step6_sudoers() {
    log INFO "step 6/9: sudoers rules (declared in ${PROFILE_JSON})"

    local rules
    rules="$(jq -r '.sudoers_rules[]?' "$PROFILE_JSON")"
    if [[ -z "$rules" ]]; then
        log INFO "profile '${PROFILE_NAME}' declares no sudoers_rules — skipping (needs your sudo password otherwise)"
        return 0
    fi

    if ! ensure_sudo; then
        log ERROR "sudo needs a password but this environment can't provide one (no TTY / no askpass)"
        log ERROR "re-run this from a session with a real TTY, or use a profile ('--no-sudo') that declares no sudoers_rules"
        exit 1
    fi

    local target="/etc/sudoers.d/mylinuxpool"
    local who
    who="$(whoami)"
    local tmp
    tmp="$(mktemp)"
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        printf '%s %s\n' "$who" "$rule" >> "$tmp"
    done <<< "$rules"

    if [[ -f "$target" ]] && sudo -n diff -q "$tmp" "$target" >/dev/null 2>&1; then
        log INFO "sudoers rules already up to date, skipping"
        rm -f "$tmp"
        return 0
    fi

    # Now that ensure_sudo confirmed sudo actually works, -n makes every
    # call below fail fast on its own merits — no more auth prompts to
    # get misattributed to whatever command happened to trigger them.
    local visudo_out
    if ! visudo_out="$(sudo -n visudo -c -f "$tmp" 2>&1)"; then
        log ERROR "generated sudoers rule(s) failed 'visudo -c' validation, aborting without touching ${target}"
        log ERROR "visudo output: ${visudo_out}"
        rm -f "$tmp"
        exit 1
    fi

    sudo -n install -o root -g root -m 440 "$tmp" "$target"
    rm -f "$tmp"
    log INFO "installed ${target}"
}

# ---- step 7: systemd user service + linger -----------------------------------

# NOTE (2026-09-15): there is deliberately NO post-install patching of
# installed unit files here anymore. pool-sync enforces that installed
# units match the repo's declared files exactly, so any "install, then
# modify what got installed" approach is silently reverted on the next
# sync — this happened for the ~/.local/bin PATH line under --no-sudo.
# The PATH fix belongs in the declaration itself
# (shared-configs/pool-runtime/files/pool-tunnel.service), never in a
# post-install rewrite of ~/.config/systemd/user/.

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

    if ! ensure_sudo; then
        log ERROR "sudo needs a password but this environment can't provide one (no TTY / no askpass)"
        log ERROR "re-run this from a session with a real TTY, or enable linger yourself: sudo loginctl enable-linger ${who}"
        exit 1
    fi

    sudo -n loginctl enable-linger "$who"
    log INFO "enabled linger for ${who}"
}

# ---- step 6.5: this machine's own tunnel identity ---------------------------
# Without this, registering a NEW provider cannot work: step 7 starts
# pool-tunnel, which looks for ~/.ssh/id_tunnel; a brand-new machine has
# none, so the tunnel never comes up and step 9 fails. The key WAS minted
# eventually — by pool-sync, whose timer step 9.5 enables — but step 9
# exits first, so that never happened. (RUNBOOK §7.12, seventh incident:
# the mint-and-publish rule lived only inside pool-sync.)
#
# Deliberately BEFORE step 7 (which starts the tunnel) and before step 9
# (which verifies it), and the refresh is WAITED ON: the Gateway must
# already authorize this key when the tunnel dials, or step 9 would be
# racing a workflow. pool-sync fires the same refresh without waiting,
# because there the tunnel is already up on a key the Gateway knows.
step6_5_tunnel_identity() {
    log INFO "step 6.5/9: mint and publish this machine's tunnel identity"

    # shellcheck source=../scripts/lib/tunnel-key.sh
    TUNNEL_KEY_REPO_DIR="$REPO_DIR" . "${REPO_DIR}/scripts/lib/tunnel-key.sh"
    # shellcheck source=../scripts/lib/refresh-wait.sh
    . "${REPO_DIR}/scripts/lib/refresh-wait.sh"

    tunnel_key_ensure_published "$NAME" "$VAR_NAME" "$REPO" || {
        log ERROR "could not establish this machine's tunnel identity — aborting"
        log ERROR "registering without one would leave a machine that can never dial the Gateway"
        exit 1
    }

    GH_REPO="$REPO" dispatch_refresh_and_wait 300 || {
        log ERROR "the Gateway did not accept the new tunnel key (refresh failed) — aborting"
        exit 1
    }
}

step7_systemd() {
    log INFO "step 7/9: enable profile-declared systemd --user services + linger"

    # Whichever unit was installed in step 3 already placed each service's
    # unit file under ~/.config/systemd/user/ — nothing to copy here,
    # just enable/start whatever profiles/provider/<name>/profile.json's
    # "systemd_user_services" lists (a role-specific decision units
    # deliberately leave to their caller, not something a unit does
    # itself).
    #
    # pool-sync.timer is deliberately NOT enabled here: enabling it with
    # --now fires it immediately, and the first sync can restart
    # pool-tunnel mid-run. Verify the freshly built tunnel FIRST (step 8),
    # then enable the thing that may restart it (step 8.5).
    local services
    services="$(jq -r '.systemd_user_services[]?' "$PROFILE_JSON")"

    if [[ -z "$services" ]]; then
        log INFO "profile '${PROFILE_NAME}' declares no systemd_user_services — skipping"
    else
        local svc unit_dst
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            [[ "$svc" == "pool-sync.timer" ]] && continue
            unit_dst="${HOME}/.config/systemd/user/${svc}"
            if [[ ! -f "$unit_dst" ]]; then
                log ERROR "${unit_dst} not found — one of step 3's units should have placed it (check which shared_config unit provides ${svc})"
                exit 1
            fi
            systemctl --user daemon-reload
            systemctl --user enable --now "$svc"
            log INFO "enabled systemd --user service ${svc}"
        done <<< "$services"
    fi

    local want_linger
    want_linger="$(jq -r '.linger // false' "$PROFILE_JSON")"
    if [[ "$want_linger" == "true" ]]; then
        enable_linger
    else
        log INFO "profile '${PROFILE_NAME}' does not declare linger — skipping"
    fi
}

# ---- step 7.5: docker group membership + real verification ------------------
# worker-host's verification under the capability contract
# (CAPABILITY-DESIGN.md §2): the criterion below is the whole of it — a real
# `docker info` as the user, never `id -nG`. This is the one implementation;
# `mlp verify-capabilities` shares the criterion for the "any time" case.
#
# step5 declares worker-host, but nothing ever verified the declaration —
# the third provider proved it: create-worker's image build failed with
# permission denied on docker.sock because nobody ever put the user in the
# docker group (the older two had it done by hand). So both halves live
# here: make membership true, then PROVE the daemon answers. The proof runs
# docker info as the user with freshly resolved groups (sudo -u re-resolves
# them, so no re-login is needed to test); `id -nG | grep docker` is NOT the
# proof — group changes apply to new logins only, so the current session's
# groups answer a different question than "can this user reach the daemon",
# exactly the kind of check that passes while broken.
step7_5_docker_group() {
    log INFO "step 7.5/9: docker group membership + daemon verification"
    local who
    who="$(whoami)"

    if [[ "$NO_SUDO" -eq 1 ]]; then
        # No root anywhere: cannot usermod. Verify what the current session
        # can actually do; on failure the admin runs usermod and this
        # idempotent script is re-run from a fresh login.
        if docker info >/dev/null 2>&1; then
            log INFO "docker daemon reachable as ${who}"
            return 0
        fi
        log ERROR "cannot talk to the docker daemon as ${who}"
        log ERROR "ask an admin to run: sudo usermod -aG docker ${who} — then log back in (fresh groups) and re-run registration"
        exit 1
    fi

    if ! ensure_sudo; then
        log ERROR "sudo needs a password but this environment can't provide one (no TTY / no askpass)"
        log ERROR "re-run this from a session with a real TTY, or add ${who} to the docker group yourself: sudo usermod -aG docker ${who}"
        exit 1
    fi

    # Idempotent: already-a-member is a silent no-op, so no "check first"
    # branch whose own answer could be stale.
    sudo -n usermod -aG docker "$who" || {
        log ERROR "could not add ${who} to the docker group"
        exit 1
    }
    log INFO "ensured ${who} in docker group"

    if sudo -n -u "$who" docker info >/dev/null 2>&1; then
        log INFO "docker daemon reachable as ${who} with fresh groups"
        return 0
    fi
    log ERROR "docker daemon still unreachable as ${who} with fresh groups — membership is set, so check the daemon/socket on this host"
    exit 1
}

# step7_5_capabilities — walk the DECLARED capabilities (read back from the
#   variable step5 just wrote) and run each key's verification. This is the
#   contract wiring (CAPABILITY-DESIGN.md §2/§4): a declaration that nothing
#   verifies can be silently false, which is the whole reason this design
#   exists. worker-host dispatches to step7_5_docker_group — the ONE
#   implementation of the docker check; a key with no defined verification
#   is reported, not passed and not failed (nothing here can judge it).
#   Name deliberately avoids "verify": main's step order is asserted by
#   test-register-provider-tempclone.sh, which looks for the tunnel verify
#   (step9_verify) as the first function matching that word.
step7_5_capabilities() {
    local caps key value runtime
    caps="$(gh api "repos/${REPO}/actions/variables/${VAR_NAME}" --jq .value 2>/dev/null \
        | jq -c '.capabilities // {}' 2>/dev/null || true)"
    [[ -n "$caps" ]] || caps='{}'

    if [[ "$(printf '%s' "$caps" | jq 'length' 2>/dev/null)" == "0" ]]; then
        log INFO "no capabilities declared — nothing to verify"
        return 0
    fi

    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || continue
        case "$key" in
            worker-host)
                runtime="$(printf '%s' "$value" | jq -r '.runtime // empty')"
                if [[ "$runtime" != "docker" ]]; then
                    log WARN "worker-host.runtime is '${runtime:-<missing>}' — no verification is defined for it; not verified"
                    continue
                fi
                step7_5_docker_group
                ;;
            *)
                log WARN "capability '${key}' has no verification defined — not verified (CAPABILITY-DESIGN.md §2)"
                ;;
        esac
    done < <(printf '%s' "$caps" | jq -r 'to_entries[] | [.key, (.value | tojson)] | @tsv')
}

# ---- step 8: write this machine's authorized_keys from CLIENT_* ----------
# KEY-DESIGN §8 removed ssh-admin (the old static-bundle unit); the login
# list now comes from the CLIENT_* variables alone. A FRESH provider must
# get Actions' public key onto this machine BEFORE the tunnel verify runs
# — otherwise Actions cannot reach it through the Gateway and registration
# fails, waiting up to 30 minutes for the first pool-sync tick.
#
# The assembly + install is ONE shared implementation,
# refresh_sync_local_authorized_keys (scripts/refresh-authkeys.sh) — the
# same function pool-sync calls every 30 minutes, so there is never a
# second copy of this rule that could drift out of sync with its guards
# (RUNBOOK §7.12). Unlike pool-sync, this step is FATAL on failure: a
# provider whose login list cannot be assembled is a provider Actions
# cannot get into, and silently skipping would register it anyway.
step8_authorized_keys() {
    log INFO "step 8/9: assemble and write this machine's authorized_keys from CLIENT_*"

    # refresh-authkeys.sh / authkeys.sh are business logic in the temp
    # clone step 3 fetched; they must be present or the registration
    # cannot proceed.
    if [[ ! -f "${REPO_DIR}/scripts/refresh-authkeys.sh" \
          || ! -f "${REPO_DIR}/scripts/lib/authkeys.sh" ]]; then
        log ERROR "scripts/refresh-authkeys.sh or scripts/lib/authkeys.sh missing in the fetched repo — cannot assemble authorized_keys"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "${REPO_DIR}/scripts/refresh-authkeys.sh"
    # shellcheck source=/dev/null
    source "${REPO_DIR}/scripts/lib/authkeys.sh"

    local vars_json
    vars_json="$(gh api "repos/${REPO}/actions/variables?per_page=100" --paginate 2>/dev/null || true)"
    if [[ -z "$vars_json" ]]; then
        log ERROR "cannot read GitHub variables — a provider without a login list is a provider Actions cannot reach; aborting"
        exit 1
    fi

    refresh_sync_local_authorized_keys "$vars_json" "${SSH_DIR}/authorized_keys" || {
        log ERROR "could not assemble/install authorized_keys — aborting (a provider Actions cannot get into is not a valid outcome)"
        exit 1
    }
    log INFO "this machine's authorized_keys now matches the CLIENT_* declarations"
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
    # NODE_GATEWAY.port is the one place that says which port the Gateway
    # listens on (22 is long closed); without -p this ssh always fails and,
    # under set -e, takes step 9.5 down with step 9.
    gw_port="$(printf '%s' "$gw_json" | jq -r '.port // 22')"

    local tries=0 max_tries=30 ok=0 banner
    while (( tries < max_tries )); do
        banner="$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 \
            -p "$gw_port" -i "$TUNNEL_KEY" "${gw_user}@${gw_ip}" \
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

# ---- step 9.5: enable pool-sync.timer ----------------------------------------
# Deliberately AFTER step9_verify: enabling with --now fires the sync
# immediately, and a first sync that detects drift would restart
# pool-tunnel while step 9 is still verifying it. With the post-install
# patching gone (see step 7's note) the first sync has nothing to drift on,
# but ordering verify → enable keeps the race impossible regardless.
step95_enable_pool_sync() {
    local services
    services="$(jq -r '.systemd_user_services[]?' "$PROFILE_JSON")"

    if ! printf '%s\n' "$services" | grep -qF 'pool-sync.timer'; then
        log INFO "profile '${PROFILE_NAME}' does not declare pool-sync.timer — nothing to enable"
        return 0
    fi

    local unit_dst="${HOME}/.config/systemd/user/pool-sync.timer"
    if [[ ! -f "$unit_dst" ]]; then
        log ERROR "${unit_dst} not found — one of step 3's units should have placed it (check which shared_config unit provides pool-sync.timer)"
        exit 1
    fi
    systemctl --user daemon-reload
    systemctl --user enable --now pool-sync.timer
    log INFO "enabled systemd --user timer pool-sync.timer (after tunnel verification)"
}

main() {
    step1_preflight
    step2_store_token
    step3_fetch_runtime
    step4_config
    step5_register_var
    step6_sudoers
    step6_5_tunnel_identity
    step7_systemd
    step7_5_capabilities
    step8_authorized_keys
    step9_verify
    step95_enable_pool_sync
    log INFO "registration complete for node '${NAME}' (gateway_port=${GATEWAY_PORT})"
}

main
