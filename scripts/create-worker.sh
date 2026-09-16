#!/usr/bin/env bash
# scripts/create-worker.sh — business logic for the Create Worker flow
# (spec: docs/POOL_RUNTIME_SPEC.md §10.4, docs/ARCHITECTURE.md §5).
#
# A function library, sourced by .github/workflows/create-worker.yml.
# Every remote command still goes through .github/actions/pool-ssh (which
# itself uses scripts/lib/ssh.sh) — this file only builds the command
# STRINGS and does the pure decision-making; it never runs anything on a
# remote node itself, and never calls gh / references ${{ }} / touches
# $GITHUB_OUTPUT (docs/LAYOUT.md §3).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/profile.sh
source "${SCRIPT_DIR}/lib/profile.sh"

# A copy of this file may be sourced from an injected location where the
# relative lib/ paths no longer resolve (e.g. a test that sed-mutates the
# file and sources it from a temp dir). Without this fallback, log() would
# be undefined and an ERROR call would hit macOS's /usr/bin/log with the
# level word as a subcommand ("Unknown subcommand 'ERROR'"). Only defines
# when the lib source above actually provided nothing.
declare -F log >/dev/null 2>&1 || log() { printf '[%s] %s\n' "$1" "${*:2}" >&2; }

# create_worker_validate_name <value> <field-name>
#   image/name feed straight into remote command text and file paths
#   elsewhere — constrain the character set at this one boundary so every
#   later use is safe by construction (no quotes, `$`, `/`, etc.).
create_worker_validate_name() {
    local value="$1" field="$2"
    if [[ -n "$value" ]] && ! [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log ERROR "'${field}' must match ^[A-Za-z0-9._-]+\$, got '${value}'"
        return 1
    fi
}

# create_worker_compute_identity <provider> <image> <run_id> <name_input>
#   Prints name=/image_tag=/container= lines.
create_worker_compute_identity() {
    local provider="$1" image="$2" run_id="$3" name_input="$4"
    local name="$name_input"
    [[ -n "$name" ]] || name="${provider}-${image}-${run_id}"
    printf 'name=%s\n' "$name"
    printf 'image_tag=mlp-worker-%s\n' "$image"
    printf 'container=mlp-%s\n' "$name"
}

# create_worker_mint_tunnel_key
#   Generates a fresh ed25519 key pair for a worker (KEY-DESIGN §3.3:
#   workers get a NEW key on every create — the container dies with it,
#   no key reuse). Runs on the Actions runner, never on a provider.
#
#   Output, exactly two lines on stdout:
#     line 1: the PRIVATE key, base64-encoded, ONE line
#     line 2: the PUBLIC key, one full line (type, blob, optional
#             comment — callers may overwrite the comment)
#
#   The key material is generated in a temp dir that is removed on every
#   exit path; the private key only ever leaves as base64 on stdout — it
#   is never written to a persistent file and never logged. Base64 is
#   used (rather than raw key bytes) so the caller can carry it through
#   a single step-output boundary without mangling newlines.
#
#   THE BASE64 MUST BE A SINGLE LINE, AND THIS IS A SECURITY ISSUE, NOT
#   COSMETIC: GNU coreutils base64 wraps output at 76 columns, so on Linux
#   (the Actions runner) the private key's base64 spans several lines and
#   "line 2" is a private-key fragment, not the public key. macOS base64
#   does NOT wrap, so tests running on macOS never see the difference —
#   this is the second time this exact Linux/macOS wrap difference has
#   caused a real incident (same shape as refresh_build_install_cmd's
#   `| base64 | tr -d '\n'` fix days ago). We do NOT use -w0: it is GNU
#   coreutils-only and macOS base64 does not accept it. Instead the output
#   is tr'd flat and a self-check asserts line 2 is a real public key
#   BEFORE anything leaves the function — a "private key published as a
#   public key" error must be caught here, not by a careful caller.
create_worker_mint_tunnel_key() {
    local tmp rc line1 line2
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/mlp-worker-key.XXXXXX")" || return 1
    if ! ssh-keygen -t ed25519 -N "" -f "$tmp/id" >/dev/null 2>&1; then
        rm -rf "$tmp"
        log ERROR "ssh-keygen failed — cannot mint a worker tunnel key"
        return 1
    fi

    # tr -d '\n' then a newline: guarantees exactly one line on Linux
    # (which wraps) and macOS (which does not) alike.
    line1="$(base64 < "$tmp/id" | tr -d '\n')"
    rc=$?
    line2="$(cat "${tmp}/id.pub" 2>/dev/null)"
    rc=$((rc || $?))
    rm -rf "$tmp"

    # Self-check: the private-key line MUST be a single line, and line 2
    # MUST be a public key line, never a private-key fragment. The
    # wrapped-base64 failure mode puts a PRIVATE-key fragment on stdout's
    # line 2 while the `line2` variable (read from id.pub directly) still
    # looks fine — so check the base64 line for embedded newlines too,
    # not just line2's shape. Any violation aborts before a caller can
    # publish a fragment.
    if [[ $rc -ne 0 || -z "$line1" || -z "$line2" ]]; then
        log ERROR "could not read the minted key material — nothing was output"
        return 1
    fi
    if [[ "$line1" == *$'\n'* ]]; then
        log ERROR "minted output self-check failed: the private-key line is wrapped (Linux base64 folds at 76 cols) — line 2 would be a private-key fragment; aborting"
        return 1
    fi
    if ! [[ "$line2" =~ ^ssh-[a-z0-9-]+[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
        log ERROR "minted output self-check failed: line 2 is not a public key (a private-key fragment must never be published) — aborting"
        return 1
    fi

    printf '%s\n%s\n' "$line1" "$line2"
    return 0
}

# dispatch_refresh_and_wait lives in scripts/lib/refresh-wait.sh — the
# SINGLE implementation of "dispatch refresh-authorized-keys.yml and wait
# for it to actually complete" (RUNBOOK §7.12, fourth incident: the same
# wait logic existed in create-worker.sh and register-client, only one of
# them fixed). create_worker_dispatch_refresh_and_wait below is kept as a
# thin alias so existing callers/tests keep working.
# shellcheck source=lib/refresh-wait.sh
source "${SCRIPT_DIR}/lib/refresh-wait.sh"

# create_worker_dispatch_refresh_and_wait [<timeout_seconds>]
#   Thin alias of dispatch_refresh_and_wait (scripts/lib/refresh-wait.sh).
#   Dispatches refresh-authorized-keys.yml and waits until the run is
#   ACTUALLY completed. Returns 0 iff the run finished with conclusion ==
#   "success"; non-zero on dispatch failure, timeout, or a non-success
#   conclusion — with timeout and failure messages distinguishable.
#   GH_REPO comes from the calling workflow's env (docs/LAYOUT.md §3:
#   the workflow is the thin caller).
create_worker_dispatch_refresh_and_wait() {
    dispatch_refresh_and_wait "$@"
}

# create_worker_missing_secrets <profile_json> <all_secrets_json>
#   Prints the name of every profile-declared secret NOT present in
#   all_secrets_json, one per line. No values are ever printed — only
#   presence is checked (a %q-quoted secret value must never cross a
#   step-output boundary; see create_worker_build_run_cmd for where the
#   actual values get used, in the same step that has them).
create_worker_missing_secrets() {
    local profile_json="$1" all_secrets_json="$2"
    local container_var secret_name val
    while IFS=$'\t' read -r container_var secret_name; do
        [[ -z "$container_var" ]] && continue
        val="$(jq -r --arg n "$secret_name" '.[$n] // empty' <<<"$all_secrets_json")"
        [[ -z "$val" ]] && printf '%s\n' "$secret_name"
    done < <(profile_secrets "$profile_json")
}

# create_worker_build_claim_cmd <port_lo> <port_hi> <provider> <image>
#   Prints the command to run on the Gateway to claim a worker port.
#   pool-port-alloc is installed at ~/.mylinuxpool/bin/ there
#   (shared-configs/pool-runtime's install.sh, called from
#   provision-gateway.sh) — called directly rather than shipping the
#   script's own text over as a `bash -c` string: under `-c`,
#   $BASH_SOURCE isn't a real path, which broke pool-port-alloc's own
#   SCRIPT_DIR-relative lookup of pool-resolve (2026-09-14 incident). The
#   Gateway holds no GitHub credential of its own (spec §10.2b), so the
#   (non-secret) port range is handed in via POOL_WORKER_PORT_RANGE
#   instead of letting pool-port-alloc call pool-resolve/gh remotely —
#   it can't, there either.
create_worker_build_claim_cmd() {
    local port_lo="$1" port_hi="$2" provider="$3" image="$4"
    local range_q provider_q image_q
    range_q="$(printf '%q' "${port_lo} ${port_hi}")"
    provider_q="$(printf '%q' "$provider")"
    image_q="$(printf '%q' "$image")"
    printf 'POOL_WORKER_PORT_RANGE=%s ~/.mylinuxpool/bin/pool-port-alloc --claim %s %s\n' \
        "$range_q" "$provider_q" "$image_q"
}

# create_worker_build_run_cmd <container> <image_tag> <port> <gw_host> \
#     <tunnel_user> <node_name> <worker_key> <authorized_keys_content> \
#     <profile_json> <all_secrets_json>
#   Prints the assembled `docker run ...` command line to stdout.
#
#   Everything that touches a secret VALUE happens in here — worker_key,
#   and every profile-declared secret from all_secrets_json — precisely
#   so no already-%q-quoted secret ever has to cross a step-output
#   boundary: a %q-quoted value handed across `${{ steps.X.outputs.Y }}`
#   gets re-interpreted as literal shell source by whatever step reads it
#   (GH Actions substitutes that text before bash parses it), which would
#   mangle anything containing real escapes (a multi-line key, say) and
#   can corrupt $GITHUB_OUTPUT itself. Only the caller's OWN step may
#   call this function — its stdout must never be echoed back through a
#   second step boundary un-consumed.
#
#   WORKER_AUTHORIZED_KEYS is the assembled login list for the worker's
#   `worker` account (the same list every machine takes from CLIENT_* via
#   authkeys_assemble — KEY-DESIGN §3.2, no static encrypted bundles since
#   §8). It is the interactive-login list, never something derived from
#   the tunnel identity — sshproxy is the tunnel identity, not an
#   interactive-login one (2026-09-14 incident: workers came up with only
#   that key authorized, so the tunnel worked but nobody could actually
#   log in).
create_worker_build_run_cmd() {
    local container="$1" image_tag="$2" port="$3" gw_host="$4"
    local tunnel_user="$5" node_name="$6" worker_key="$7"
    local authorized_keys_content="$8" profile_json="${9}" all_secrets_json="${10}"

    if [[ -z "$authorized_keys_content" ]]; then
        log ERROR "the assembled client list is empty — refusing to start a worker nobody can log into"
        return 1
    fi

    local container_q image_q port_q host_q tunnel_user_q node_name_q worker_key_q
    container_q="$(printf '%q' "$container")"
    image_q="$(printf '%q' "$image_tag")"
    port_q="$(printf '%q' "$port")"
    host_q="$(printf '%q' "$gw_host")"
    tunnel_user_q="$(printf '%q' "$tunnel_user")"
    node_name_q="$(printf '%q' "$node_name")"
    worker_key_q="$(printf '%q' "$worker_key")"

    # The client list travels as base64: `base64` on a Linux runner wraps
    # at 76 columns and `-w0` is GNU-only, so the newlines come off with
    # tr — a wrapped value silently truncates at the first line when it
    # lands in a single-line context (RUNBOOK §7.13).
    local ak_b64
    ak_b64="$(printf '%s\n' "$authorized_keys_content" | base64 | tr -d '\n')"

    local cmd
    # Create the mount sources first. Docker creates a missing bind-mount
    # source itself, as root — and then the provider's pool-tunnel, which
    # runs as the user, cannot write the file the worker is waiting for.
    cmd="mkdir -p \$HOME/.mylinuxpool/gateway \$HOME/.mylinuxpool/clients; "
    # Who may log in arrives as a FILE the provider keeps current, not as
    # an env var frozen at creation time. pool-sync rewrites it from the
    # CLIENT_* vars every tick, so revoking a client actually reaches the
    # workers already running here. Seeded now so the mount is correct
    # from the container's first second, before the next sync tick.
    cmd+="printf '%s' ${ak_b64} | base64 -d > \$HOME/.mylinuxpool/clients/authorized_keys; "
    cmd+="chmod 600 \$HOME/.mylinuxpool/clients/authorized_keys; "
    cmd+="docker rm -f ${container_q} >/dev/null 2>&1; docker run -d --restart unless-stopped --name ${container_q}"
    # The provider's own pool-tunnel publishes the Gateway it is currently
    # attached to into ~/.mylinuxpool/gateway/. Mount that directory
    # read-only and point the container at it, so the worker follows a
    # rotate instead of freezing at the address it was started with — and
    # still carries no GitHub credential of its own.
    #
    # The DIRECTORY is mounted, not the file: publish_gateway writes a temp
    # file and renames it, which replaces the inode. A file bind-mount
    # would keep pointing at the old one and the worker would never see an
    # update.
    #
    # HOST/USER are still passed as a fallback for the first moments before
    # the file exists, and for a provider running an older pool-runtime.
    cmd+=" -v \$HOME/.mylinuxpool/gateway:/run/mlp-gateway:ro"
    cmd+=" -v \$HOME/.mylinuxpool/clients:/run/mlp-clients:ro"
    cmd+=" -e POOL_GATEWAY_FILE=/run/mlp-gateway/gateway.json"
    cmd+=" -e POOL_GATEWAY_PORT=${port_q} -e POOL_GATEWAY_HOST=${host_q} -e POOL_GATEWAY_USER=${tunnel_user_q}"
    cmd+=" -e POOL_NODE_NAME=${node_name_q}"
    cmd+=" -e WORKER_KEY=${worker_key_q}"

    local container_var secret_name val literal_val
    while IFS=$'\t' read -r container_var secret_name; do
        [[ -z "$container_var" ]] && continue
        val="$(jq -r --arg n "$secret_name" '.[$n] // empty' <<<"$all_secrets_json")"
        cmd+=" -e $(printf '%q' "${container_var}=${val}")"
    done < <(profile_secrets "$profile_json")

    while IFS=$'\t' read -r container_var literal_val; do
        [[ -z "$container_var" ]] && continue
        cmd+=" -e $(printf '%q' "${container_var}=${literal_val}")"
    done < <(profile_env "$profile_json")

    cmd+=" ${image_q}"
    printf '%s\n' "$cmd"
}

# create_worker_verify_reachable <gw_user> <gw_ip> <port> [max_tries]
#   A bare SSH banner only proves *something* is listening and speaking
#   SSH — it doesn't prove anyone can actually get in (2026-09-14
#   incident: this reported success on a worker whose authorized_keys
#   held only the tunnel identity, so the banner was real but every human
#   login failed). Same lesson as pool-tunnel's own health check upgrade
#   from `nc -z` to reading the banner (spec §3.2) — verify all the way to
#   the thing that's actually being relied on: a real authenticated
#   connection through the Gateway, running a command. Assumes the
#   caller's ssh-agent already holds whatever identity is needed.
create_worker_verify_reachable() {
    local gw_user="$1" gw_ip="$2" port="$3" max_tries="${4:-30}"
    local i out
    for (( i = 1; i <= max_tries; i++ )); do
        if out="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
                -J "${gw_user}@${gw_ip}" -p "$port" worker@127.0.0.1 whoami 2>&1)"; then
            if [[ "$out" == "worker" ]]; then
                log INFO "authenticated ok (whoami=${out}) after ${i} attempt(s)"
                return 0
            fi
            log INFO "connected but got unexpected output from whoami: ${out}"
        fi
        sleep 2
    done
    log ERROR "could not authenticate as worker@127.0.0.1:${port} via ${gw_user}@${gw_ip} after ${max_tries} attempts"
    return 1
}
